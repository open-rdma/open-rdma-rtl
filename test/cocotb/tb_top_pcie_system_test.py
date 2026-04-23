#!/usr/bin/env python
"""
tb_top_pcie_system_test.py
==========================
Cocotb testbench for mkBsvTop — the full BSV top module including the
Intel R-Tile PCIe hard IP interface.

Key differences from tb_top_for_system_test.py
-----------------------------------------------
* DUT       : mkBsvTop  (not mkBsvTopWithoutHardIpInstance)
* Clock     : driven by RTilePcieDevice via coreclkout_hip = dut.CLK
              → do NOT call Clock(dut.CLK, …) here
* Reset     : RTilePcieDevice drives dut.RST_N (reset_status_n);
              dut.RST_N_partitionReset is released simultaneously with RST_N
              by _partition_reset_task (see note on reset timing below)
* DMA / PCIe: BsvTopTestBed  (RTilePcieDevice + RootComplex BAR MMIO)
              replaces SimplePcieBehaviorModelProxy + shared memory
* CSR access: TCP JSON server on port 7701 → RC BAR MMIO (via BsvTopTestBed)

Reset timing note
-----------------
In hardware, RST_N_partitionReset (short, 4-cycle buffer) is released 3 cycles
before RST_N (long, 7-cycle buffer).  Each partition module (mkSqGroup,
mkRqGroup, mkBsvTopOnlyHardIp) is wrapped by reset_tree_wrapper.py, which adds
a 3-stage register chain, so partition-internal logic exits reset at
  T(RST_N_partitionReset_high) + 3 == T(RST_N_high)
i.e. at the same cycle as the rest of the chip.

In simulation RTilePcieDevice drives RST_N and we cannot predict its rising
edge, so _partition_reset_task releases RST_N_partitionReset simultaneously
with RST_N.  The 3-cycle wrapper delay still applies, meaning partition
internals exit reset 3 cycles AFTER RST_N goes high.  setup() compensates by
waiting those 3 extra clock cycles before declaring the DUT ready.
"""

import gc
import logging
import os
import threading

import time

import cocotb_test.simulator

import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotbext.pcie.core.rc import RootComplex

from test_framework.bsv_rtile_glue import BsvRootComplex, BsvTopTestBed
from test_framework.common import cocotb_extra_env, gen_rtl_file_list, copy_mem_file_to_sim_build_dir
from test_framework.eth_bfm import SimpleEthBehaviorModel


class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        # dut.CLK is driven by RTilePcieDevice — do not drive it here.
        self.clock  = dut.CLK
        self.resetn = dut.RST_N

        # Root Complex (PCIe host side)
        self.rc = BsvRootComplex()

        # BsvTopTestBed: wraps RTilePcieDevice + RC + TCP CSR server.
        # RTilePcieDevice will drive dut.CLK (500 MHz) and dut.RST_N.
        self.pcie_tb = BsvTopTestBed(
            dut,
            self.rc,
            csr_listen_addr="0.0.0.0",
            csr_listen_port=7701,
        )

        # Ethernet BFM (loopback or cross-card)
        # self.eth_bfm = SimpleEthBehaviorModel(
        #     dut,
        #     [
        #         "qpEthDataStreamIfcVec_0_dataPipeOut",
        #         "qpEthDataStreamIfcVec_1_dataPipeOut",
        #         "qpEthDataStreamIfcVec_2_dataPipeOut",
        #         "qpEthDataStreamIfcVec_3_dataPipeOut",
        #     ],
        #     [
        #         "qpEthDataStreamIfcVec_0_dataPipeIn",
        #         "qpEthDataStreamIfcVec_1_dataPipeIn",
        #         "qpEthDataStreamIfcVec_2_dataPipeIn",
        #         "qpEthDataStreamIfcVec_3_dataPipeIn",
        #     ],
        # )

        # Mirror dut.RST_N → dut.RST_N_partitionReset
        # RST_N is driven by RTilePcieDevice; we follow it here.
        cocotb.start_soon(self._partition_reset_task())

    async def setup(self):
        """
        Enumerate PCIe bus, start CSR TCP server, wait for reset release.
        Must be awaited at the start of every test coroutine.
        """
        # setup() connects dev to rc, enumerates, acquires BAR, starts TCP server
        await self.pcie_tb.setup()

        # Wait for RTilePcieDevice to release reset (de-assert → 1)
        await RisingEdge(self.resetn)
        self.log.info("dut.RST_N released")

        # RST_N_partitionReset was released simultaneously with RST_N (see
        # _partition_reset_task).  reset_tree_wrapper.py inserts a 3-stage
        # register chain at the boundary of each partition module, so
        # partition-internal logic (mkSqGroup, mkRqGroup, mkBsvTopOnlyHardIp)
        # exits reset 3 cycles after RST_N_partitionReset goes high.  Wait
        # those 3 cycles before sending any traffic.
        for _ in range(3):
            await RisingEdge(self.clock)
        self.log.info("partition reset propagated — DUT fully out of reset")

    # async def start_single_card_loop_back(self):
    #     """Forward every Ethernet TX packet back as RX (single-card loopback)."""
    #     async def _loop_back_task():
    #         while True:
    #             tx_beat = await self.eth_bfm.get_tx_packet()
    #             await self.eth_bfm.inject_rx_packet(tx_beat)
    #             self.log.debug(f"eth loopback beat: {tx_beat}")

    #     cocotb.start_soon(_loop_back_task())

    def clean_up(self):
        """Stop the TCP CSR server. Call at end of each test."""
        self.pcie_tb.stop()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _partition_reset_task(self):
        """
        Assert and release dut.RST_N_partitionReset in sync with dut.RST_N.

        In hardware RST_N_partitionReset is a 4-cycle-buffered version of the
        rtile reset and goes high 3 cycles before RST_N (7-cycle buffer).
        Here we release both simultaneously because RTilePcieDevice controls
        RST_N and we cannot predict its rising edge.  The 3-cycle discrepancy
        is absorbed by the 3 extra clock cycles that setup() waits after
        RisingEdge(resetn).
        """
        if not hasattr(self.dut, "RST_N_partitionReset"):
            return

        self.dut.RST_N_partitionReset.value = 0
        self.log.info("RST_N_partitionReset asserted")

        # Release simultaneously with RST_N; setup() waits 3 more cycles for
        # the reset_tree_wrapper 3-stage pipeline to drain.
        await RisingEdge(self.resetn)

        self.dut.RST_N_partitionReset.value = 1
        self.log.info("RST_N_partitionReset released")

    async def _wait_for_ftile_clk(self):
        """
        dut.CLK_ftileClk is the Ethernet tile clock domain.
        Drive it at a suitable frequency if the DUT needs it.
        The simplest approach for an initial test: tie it to dut.CLK.
        Override in a subclass if independent ftile clock is needed.
        """
        pass


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

@cocotb.test(timeout_time=6_000_000, timeout_unit="ns")
async def small_desc_fp_test(dut):
    """
    Basic system-level test: single-card Ethernet loopback with PCIe DMA.
    The real RDMA userspace driver is expected to connect via TCP on port 7701.
    """
    tb = TB(dut)

    # Drive the ftile Ethernet clock (CLK_ftileClk).
    # For a basic PCIe-only test, tie it to dut.CLK so the BSV scheduler
    # doesn't stall waiting for the clock domain.
    # Replace with a separate Clock() if ftile Ethernet is under test.
    from cocotb.clock import Clock
    cocotb.start_soon(Clock(dut.CLK_ftileClk, 3, "ns").start())  # ~333 MHz

    # await tb.start_single_card_loop_back()

    # Enumerate PCIe, start CSR server, wait for reset release
    await tb.setup()

    # Run until the external driver disconnects or the timeout fires
    await Timer(15_000_000, units="ns")

    tb.clean_up()


# ---------------------------------------------------------------------------
# pytest entry point
# ---------------------------------------------------------------------------

def test_bsv_top_pcie():
    rtl_dirs  = os.getenv("COCOTB_VERILOG_DIR") or ""
    dut_name  = os.getenv("COCOTB_DUT") or "mkBsvTop"
    tests_dir = os.path.dirname(__file__)
    module    = os.path.splitext(os.path.basename(__file__))[0]

    verilog_sources = gen_rtl_file_list(rtl_dirs)

    sim_build = os.path.join(tests_dir, "sim_build", dut_name)
    copy_mem_file_to_sim_build_dir(rtl_dirs, sim_build)

    cocotb_test.simulator.run(
        "verilator",
        compile_args=[
            "--no-timing",
            "--Wno-WIDTHTRUNC",
            "--Wno-WIDTHEXPAND",
            "--Wno-CASEINCOMPLETE",
            "--Wno-INITIALDLY",
            "-Wno-STMTDLY",
            "--autoflush",
        ],
        make_args=[f"-j{os.cpu_count() or 4}"],
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=dut_name,
        module=module,
        extra_env=cocotb_extra_env(),
        timescale="1ns/1ps",
        sim_build=sim_build,
        waves=True,
    )


if __name__ == "__main__":
    test_bsv_top_pcie()
