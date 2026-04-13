#!/usr/bin/env python
import itertools
import gc
import logging
import os
import threading

import time

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer, NullTrigger
from cocotb.regression import TestFactory
from cocotb.clock import Clock
from cocotb.queue import Queue

from test_framework.mock_host import UserspaceDriverServer, open_shared_mem_to_hw_simulator, EthPacketTcp


from test_framework.common import gen_rtl_file_list, copy_mem_file_to_sim_build_dir
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

        self.inst_id = os.environ.get("BLUERDMA_SIMULATOR_INST_ID", "")
        if self.inst_id not in ["1", "2"]:
            raise SystemError(
                "must set BLUERDMA_SIMULATOR_INST_ID environment var as 1 or 2")

        self.shared_mem = open_shared_mem_to_hw_simulator(
            256*1024*1024, f"/bluesim{self.inst_id}")

        self.csr_write_req_queue = Queue()
        self.csr_read_req_queue = Queue()
        self.csr_read_resp_queue = Queue()
        self.csr_read_lock = threading.Lock()

        self.rpc_server = UserspaceDriverServer(
            "0.0.0.0", 7700 + int(self.inst_id), self._csr_write_cb, self._csr_read_cb)
        # self.rpc_server.run()

        if self.inst_id == "1":
            pcie_proxy_port = 7003
        else:
            pcie_proxy_port = 7004

        is_test_100g = False
        if is_test_100g:
            channel_cnt = 1
            self.pcie_bfm = SimplePcieBehaviorModel(
                dut,
                ["dmaMasterPipeIfc"],
                ["dmaSlavePipeIfc"],
                self.shared_mem.buf
            )

            self.eth_bfm = SimpleEthBehaviorModel(
                dut,
                ["qpEthDataStreamIfc_dataPipeOut"],
                ["qpEthDataStreamIfc_dataPipeIn"],
            )
        else:
            channel_cnt = 4
            self.pcie_bfm = SimplePcieBehaviorModelProxy(
                dut,
                ["dmaMasterPipeIfcVec_0",
                 "dmaMasterPipeIfcVec_1",
                 "dmaMasterPipeIfcVec_2",
                 "dmaMasterPipeIfcVec_3"],
                [
                    "dmaSlavePipeIfc"
                ],
                self.shared_mem.buf,
                tcp_port=pcie_proxy_port
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

        cocotb.start_soon(self._forward_csr_write_task())
        cocotb.start_soon(self._forward_csr_read_req_task())

        self.eth_packet_rpc = EthPacketTcp(self.inst_id)

    async def start_eth_packet_rpc(self):
        async def _tx_task(self):
            while True:
                tx_beat = await self.eth_bfm.get_tx_packet()
                self.log.info(f"eth packet rpc tx beat is going to send: {tx_beat}")
                self.eth_packet_rpc.send_packet(tx_beat)
                self.log.info(
                    f"eth packet rpc tx beat: {tx_beat}")

        async def _rx_task(self):
            while True:
                rx_beat = self.eth_packet_rpc.recv_packet()
                if rx_beat is not None:
                    await self.eth_bfm.inject_rx_packet(rx_beat)
                    self.log.info(
                        f"eth packet rpc rx beat: {rx_beat}")
                await Timer(1, units='ns')

        cocotb.start_soon(_tx_task(self))
        cocotb.start_soon(_rx_task(self))

    def clean_up(self):
        self.rpc_server.stop()

        # need to ensure no reference to shared_mem, if not, the shared memory resource can not be released.
        self.pcie_bfm = None
        shared_mem = self.shared_mem
        self.shared_mem = None
        gc.collect()
        shared_mem.close()

    def _csr_write_cb(self, addr, value):
        self.log.info(f"write CSR, addr={hex(addr)}, value={hex(value)}\n\n")
        self.csr_write_req_queue.put_nowait((addr, value))
        self.log.info(
            f"get mem addr @ 0x3e01000={self.shared_mem.buf[0x3e01000]}")

    def _csr_read_cb(self, addr):
        with self.csr_read_lock:
            self.csr_read_req_queue.put_nowait(addr)
            while self.csr_read_resp_queue.empty():
                time.sleep(0)
            ret = self.csr_read_resp_queue.get_nowait()
            self.log.info(f"_csr_read_cb: {addr, ret}")
            return ret

    async def _forward_csr_write_task(self):
        while True:
            addr, value = await self.csr_write_req_queue.get()
            await RisingEdge(self.clock)  # ← 添加：等待时钟边沿 
            await self.pcie_bfm.host_write_blocking(addr, value)
            self.log.info(f"_forward_csr_write_task: {addr, value}")

    async def _forward_csr_read_req_task(self):
        while True:
            addr = await self.csr_read_req_queue.get()
            await RisingEdge(self.clock)  # ← 添加：等待时钟边沿 
            val = await self.pcie_bfm.host_read_blocking(addr)
            await self.csr_read_resp_queue.put(val)

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

    cocotb.start_soon(Clock(tb.clock, 2, "ns").start())

    cocotb.start_soon(tb.start_eth_packet_rpc())

    await NullTrigger()
    await tb.gen_reset()

    tb.rpc_server.run()
    # FIX: Increased wait time from 15us to 150us to allow:
    # - User-space driver (BluerdmaCore) to connect via UDP
    # - RDMA operations (QP creation, memory registration, data transfer) to complete
    # - DMA operations to finish processing
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
        compile_args=["--no-timing", "--Wno-WIDTHTRUNC", "--Wno-CASEINCOMPLETE", "--Wno-INITIALDLY", "-Wno-STMTDLY", "--autoflush" ],
        make_args=[f"-j{os.cpu_count() or 4}"],

        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        timescale="1ns/1ps",
        sim_build=sim_build,
        waves=True,
    )


if __name__ == "__main__":
    test_top_without_hard_ip()
