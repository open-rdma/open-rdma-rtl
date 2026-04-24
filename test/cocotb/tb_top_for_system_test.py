#!/usr/bin/env python
import itertools
import gc
import logging
import os

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.regression import TestFactory
from cocotb.clock import Clock
from cocotb.queue import Queue

from test_framework.mock_host import UserspaceDriverServer, open_shared_mem_to_hw_simulator


from test_framework.common import cocotb_extra_env, gen_rtl_file_list, copy_mem_file_to_sim_build_dir
from test_framework.eth_bfm import SimpleEthBehaviorModel
from test_framework.pcie_bfm import SimplePcieBehaviorModel
from test_framework.proxy_pcie_bfm import SimplePcieBehaviorModelProxy
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        self.clock = dut.CLK
        self.resetn = dut.RST_N

        self.shared_mem = open_shared_mem_to_hw_simulator(256*1024*1024)

        self.csr_req_queue = Queue()

        self.rpc_server = UserspaceDriverServer(
            "0.0.0.0", 7701, self._csr_write_cb, self._csr_read_cb)
        # self.rpc_server.run()

        self.pcie_bfm = SimplePcieBehaviorModelProxy(
            dut,
            ["dmaMasterPipeIfcVec_0",
             "dmaMasterPipeIfcVec_1",
             "dmaMasterPipeIfcVec_2",
             "dmaMasterPipeIfcVec_3"],
            [
                "dmaSlavePipeIfc"
            ],
            self.shared_mem.buf
        )

        self.eth_bfm = SimpleEthBehaviorModel(
            dut,
            [
                "qpEthDataStreamIfcVec_0_dataPipeOut",
                "qpEthDataStreamIfcVec_1_dataPipeOut",
                "qpEthDataStreamIfcVec_2_dataPipeOut",
                "qpEthDataStreamIfcVec_3_dataPipeOut",
            ],
            [
                "qpEthDataStreamIfcVec_0_dataPipeIn",
                "qpEthDataStreamIfcVec_1_dataPipeIn",
                "qpEthDataStreamIfcVec_2_dataPipeIn",
                "qpEthDataStreamIfcVec_3_dataPipeIn",
            ],
        )

        cocotb.start_soon(self._csr_dispatch_task())

    async def start_single_card_loop_back(self):
        async def _loop_back_task(self):
            while True:
                tx_beat = await self.eth_bfm.get_tx_packet()
                await self.eth_bfm.inject_rx_packet(tx_beat)
                self.log.debug(
                    f"single_card_loop_back forward beat: {tx_beat}")

        cocotb.start_soon(_loop_back_task(self))

    def clean_up(self):
        self.rpc_server.stop()

        # need to ensure no reference to shared_mem, if not, the shared memory resource can not be released.
        self.pcie_bfm = None
        shared_mem = self.shared_mem
        self.shared_mem = None
        gc.collect()
        shared_mem.close()

    # TODO 这一段逻辑在很多文件中重复了，可以考虑抽象成一个公共的基类或者工具函数
    def _csr_write_cb(self, addr, value):
        self.log.info(f"write CSR, addr={hex(addr)}, value={hex(value)}\n\n")
        self.csr_req_queue.put_nowait(("write", addr, value, None))
        self.log.info(
            f"get mem addr @ 0x3e01000={self.shared_mem.buf[0x3e01000]}")

    def _csr_read_cb(self, addr):
        import queue as _stdlib_queue
        response_queue = _stdlib_queue.Queue(maxsize=1)
        self.csr_req_queue.put_nowait(("read", addr, None, response_queue))
        while True:
            try:
                return response_queue.get(timeout=5.0)
            except _stdlib_queue.Empty:
                self.log.warning("CSR read still waiting after 5.0s: addr=%s", hex(addr))

    async def _csr_dispatch_task(self):
        while True:
            op, addr, value, response_queue = await self.csr_req_queue.get()
            await RisingEdge(self.clock)

            if op == "write":
                await self.pcie_bfm.host_write_blocking(addr, value)
                self.log.info(f"_csr_dispatch_task write: {(addr, value)}")
            elif op == "read":
                val = await self.pcie_bfm.host_read_blocking(addr)
                response_queue.put_nowait(val)
                self.log.info(f"_csr_dispatch_task read: {(addr, val)}")
            else:
                raise RuntimeError(f"Unknown CSR op: {op}")

    async def put_rx_data(self, packet_data):
        await self.eth_bfm.inject_rx_packet(packet_data)

    async def gen_reset(self):
        self.resetn.value = 0
        if hasattr(self.dut, "RST_N_partitionReset"):
            self.dut.RST_N_partitionReset.value = 0
            self.log.info("also assert RST_N_partitionReset")
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        if hasattr(self.dut, "RST_N_partitionReset"):
            self.dut.RST_N_partitionReset.value = 1
            self.log.info("also release RST_N_partitionReset")
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        self.resetn.value = 1
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        await RisingEdge(self.clock)
        self.log.info("Generated DMA RST_N")


@ cocotb.test(timeout_time=6000000, timeout_unit="ns")
async def small_desc_fp_test(dut):

    tb = TB(dut)
    await cocotb.start(Clock(tb.clock, 2, "ns").start())

    await cocotb.start(tb.start_single_card_loop_back())

    await tb.gen_reset()
    tb.rpc_server.run()

    await Timer(15000000, units='ns')
    tb.clean_up()


def test_top_without_hard_ip():
    rtl_dirs = os.getenv("COCOTB_VERILOG_DIR") or ""
    dut = os.getenv("COCOTB_DUT") or ""
    tests_dir = os.path.dirname(__file__)
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = gen_rtl_file_list(rtl_dirs)

    sim_build = os.path.join(tests_dir, "sim_build", dut)
    copy_mem_file_to_sim_build_dir(rtl_dirs, sim_build)

    cocotb_test.simulator.run(
        # 需要编译，但是可以大幅加速运行速度
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
        toplevel=toplevel,
        module=module,
        extra_env=cocotb_extra_env(),
        timescale="1ns/1ps",
        sim_build=sim_build,
        waves=True,
    )


if __name__ == "__main__":
    test_top_without_hard_ip()
