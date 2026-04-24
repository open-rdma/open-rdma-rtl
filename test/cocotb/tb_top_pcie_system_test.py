#!/usr/bin/env python
"""
tb_top_pcie_system_test.py
==========================
Cocotb testbench for a lightweight wrapper around mkBsvTop.

The outer DUT only contains:
  - rtile_reset_output_buffer
  - mkBsvTop (instance name: u_bsv_top)

RTilePcieDevice drives the wrapper top-level PCIe raw interface and reset
source.  The wrapper exposes the buffered reset signals so the test can observe
the real reset chain instead of mirroring RST_N_partitionReset in Python.
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
        self.outer_dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        # outer_dut.CLK is driven by RTilePcieDevice and fed into u_bsv_top.
        self.clock = self.outer_dut.CLK
        self.resetn = self.outer_dut.RST_N_buffered_long

        # Root Complex (PCIe host side)
        self.rc = BsvRootComplex()

        # BsvTopTestBed: wraps RTilePcieDevice + RC + TCP CSR server.
        # The PCIe model drives the wrapper top-level clock/reset and raw buses.
        self.pcie_tb = BsvTopTestBed(
            self.outer_dut,
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

    async def setup(self):
        """
        Enumerate PCIe bus, start CSR TCP server, wait for reset release.
        Must be awaited at the start of every test coroutine.
        """
        # Connect the simulated device to the RC first.  Delay enumeration until
        # the wrapper reset chain has fully released.
        self.pcie_tb.prepare()

        # Wait for the real reset chain to release:
        # short buffered reset first, then the long reset seen by mkBsvTop.
        if not self.outer_dut.RST_N_partitionReset.value:
            await RisingEdge(self.outer_dut.RST_N_partitionReset)
        self.log.info("dut.RST_N_partitionReset released")

        if not self.resetn.value:
            await RisingEdge(self.resetn)
        self.log.info("dut.RST_N_buffered_long released")

        # reset_tree_wrapper.py inserts a 3-stage register chain at the boundary
        # of each partition module, so partition-internal logic exits reset
        # 3 cycles after RST_N_partitionReset goes high.
        for _ in range(3):
            await RisingEdge(self.clock)
        self.log.info("partition reset propagated — DUT fully out of reset")

        # With the DUT now out of reset, it is safe to enumerate the PCIe bus
        # and expose BAR0/CSR services to the userspace driver.
        await self.pcie_tb.enumerate_and_start()

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
    dut_name  = os.getenv("COCOTB_DUT") or "top_mkBsvTopWithResetBuffer"
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
