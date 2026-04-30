#!/usr/bin/env python
import itertools
import gc
import logging
import os

import pytest

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.regression import TestFactory
from cocotb.clock import Clock
from cocotb.queue import Queue

from test_framework.mock_host import UserspaceDriverServer, open_shared_mem_to_hw_simulator, EthSwitchTcp


from test_framework.common import run_cocotb_simulation
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
        print(f"Simulator instance ID: {self.inst_id}")
        # if self.inst_id not in ["1", "2"]:
        #     raise SystemError(
        #         "must set BLUERDMA_SIMULATOR_INST_ID environment var as 1 or 2")

        self.shared_mem = open_shared_mem_to_hw_simulator(
            256*1024*1024, f"/bluesim{self.inst_id}")

        self.csr_req_queue = Queue()

        self.rpc_server = UserspaceDriverServer(
            "0.0.0.0", 7700 + int(self.inst_id), self._csr_write_cb, self._csr_read_cb)
        # self.rpc_server.run()

        # if self.inst_id == "1":
        #     pcie_proxy_port = 7003
        # else:
        #     pcie_proxy_port = 7004
        pcie_proxy_port = 7002 + int(self.inst_id)

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

        cocotb.start_soon(self._csr_dispatch_task())

        self.eth_packet_rpc = EthSwitchTcp(self.inst_id)

    async def start_eth_packet_rpc(self):
        async def _tx_task(self):
            while True:
                self.log.info("Waiting for packet from DUT to send via RPC...")
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
        self.eth_packet_rpc.close()

        # need to ensure no reference to shared_mem, if not, the shared memory resource can not be released.
        self.pcie_bfm = None
        shared_mem = self.shared_mem
        self.shared_mem = None
        gc.collect()
        shared_mem.close()

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
                ret = response_queue.get(timeout=5.0)
                self.log.info(f"_csr_read_cb: {addr, ret}")
                return ret
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

    await cocotb.start(tb.start_eth_packet_rpc())

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
    dut = os.getenv("COCOTB_DUT") or "mkBsvTopWithoutHardIpInstance"
    tests_dir = os.path.dirname(__file__)
    module = os.path.splitext(os.path.basename(__file__))[0]
    run_cocotb_simulation(
        tests_dir=tests_dir,
        module=module,
        dut_name=dut,
        rtl_dirs=rtl_dirs,
    )


if __name__ == "__main__":
    test_top_without_hard_ip()
