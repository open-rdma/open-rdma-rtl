

from collections import deque, OrderedDict
from abc import ABC
import logging
import math

import asyncio
import os

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ReadWrite, ReadOnly, Edge, NextTimeStep
from cocotb.queue import Queue
import cocotb.triggers

from .common import BluespecPipeOut, BluespecPipeInNrWithQueue, BluespecPipeIn, BlueRdmaDtldStreamMemAccessMeta

if os.environ["BLUERDMA_DATA_BUS_WIDTH"] == "256":
    from .common import BlueRdmaDataStream256 as BlueRdmaDataStream
    DATA_BUS_BYTE_WIDTH = 32
else:
    from .common import BlueRdmaDataStream512 as BlueRdmaDataStream
    DATA_BUS_BYTE_WIDTH = 64


class SimpleEthBehaviorModel(object):
    def __init__(self, dut, tx_ifc_base_names, rx_ifc_base_names):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)

        self.clock = dut.CLK
        self.resetn = dut.RST_N

        self.txChannels = []
        self.rxChannels = []
        for idx in range(len(tx_ifc_base_names)):
            self.txChannels.append(BluespecPipeOut(
                dut, tx_ifc_base_names[idx], self.clock))
        for idx in range(len(rx_ifc_base_names)):
            self.rxChannels.append(BluespecPipeIn(
                dut, rx_ifc_base_names[idx], self.clock))

        self.main_rx_queue = Queue()
        self.main_tx_queue = Queue()

        for idx in range(len(tx_ifc_base_names)):
            cocotb.start_soon(self._handle_dut_tx_task(idx))
        for idx in range(len(rx_ifc_base_names)):
            cocotb.start_soon(self._handle_dut_rx_task(idx))

    async def get_tx_packet(self):
        return await self.main_tx_queue.get()

    async def inject_rx_packet(self, packet):
        await self.main_rx_queue.put(packet)

    async def _handle_dut_tx_task(self, idx):
        packet_data = b""
        is_in_stream=False
        while True:
            if await self.txChannels[idx].not_empty():
                ds_raw = await self.txChannels[idx].first()
                await self.txChannels[idx].deq()
                ds = BlueRdmaDataStream.unpack(ds_raw)
                # self.log.debug(f"eth bfm channel {idx} got beat, ds={ds}")

                if ds.is_first():
                    assert is_in_stream==False,"eth bfm channel {idx} got wrong stream"
                    is_in_stream=True

                if ds.is_last():
                    assert is_in_stream==True,"eth bfm channel {idx} got wrong stream"
                    is_in_stream=False

                ds_data_as_bytes = ds.data().to_bytes(DATA_BUS_BYTE_WIDTH, byteorder="little")
                packet_data += ds_data_as_bytes[:ds.byte_num()]

                if ds.is_last():
                    await self.main_tx_queue.put(packet_data)
                    self.log.info(
                        f"eth bfm channel {idx} got full packet, data={packet_data}")
                    packet_data = b""
            await RisingEdge(self.clock)

    async def _handle_dut_rx_task(self, idx):
        while True:
            packet_to_send = await self.main_rx_queue.get()
            send_pos = 0
            while send_pos < len(packet_to_send):
                if await self.rxChannels[idx].not_full():
                    data = packet_to_send[send_pos:send_pos +
                                          DATA_BUS_BYTE_WIDTH]
                    is_first = send_pos == 0
                    send_pos += DATA_BUS_BYTE_WIDTH
                    is_last = send_pos >= len(packet_to_send)

                    ds = BlueRdmaDataStream(
                        data=data,
                        byte_num=len(data),
                        start_byte_index=0,
                        is_first=is_first,
                        is_last=is_last
                    )
                    await self.rxChannels[idx].enq(ds.pack())
                    self.log.info(
                        f"inject rx beat to dut, channel={idx} ds={ds}")
                await RisingEdge(self.clock)
