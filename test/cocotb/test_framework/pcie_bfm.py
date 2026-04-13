
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


class SimplePcieBehaviorModel(object):
    def __init__(self, dut, requester_ifc_base_names, completer_ifc_base_names, mem=None, read_delay_time_ns=800, write_meta_to_data_delay_ns=300):
        self.dut = dut

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)

        self.clock = dut.CLK
        self.resetn = dut.RST_N

        self.read_delay_time_ns = read_delay_time_ns
        self.write_meta_to_data_delay_ns = write_meta_to_data_delay_ns

        self.requester_write_meta_pipes = []
        self.requester_write_data_pipes = []
        self.requester_read_meta_pipes = []
        self.requester_read_data_pipes = []

        for base_name in requester_ifc_base_names:
            self.requester_write_meta_pipes.append(BluespecPipeOut(
                dut, f"{base_name}_writePipeIfc_writeMetaPipeOut", self.clock))
            self.requester_write_data_pipes.append(BluespecPipeOut(
                dut, f"{base_name}_writePipeIfc_writeDataPipeOut", self.clock))
            self.requester_read_meta_pipes.append(BluespecPipeOut(
                dut, f"{base_name}_readPipeIfc_readMetaPipeOut", self.clock))
            self.requester_read_data_pipes.append(BluespecPipeInNrWithQueue(
                dut, f"{base_name}_readPipeIfc_readDataPipeIn", self.clock))

        self.requester_channel_cnt = len(requester_ifc_base_names)
        self.requester_pending_write_metas = [
            [] for _ in range(self.requester_channel_cnt)]

        self.read_delay_queues = [
            deque() for _ in range(self.requester_channel_cnt)
        ]

        self.completer_write_meta_pipes = []
        self.completer_write_data_pipes = []
        self.completer_read_meta_pipes = []
        self.completer_read_data_pipes = []
        for base_name in completer_ifc_base_names:
            self.completer_write_meta_pipes.append(BluespecPipeIn(
                dut, f"{base_name}_writePipeIfc_writeMetaPipeIn", self.clock))
            self.completer_write_data_pipes.append(BluespecPipeIn(
                dut, f"{base_name}_writePipeIfc_writeDataPipeIn", self.clock))
            self.completer_read_meta_pipes.append(BluespecPipeIn(
                dut, f"{base_name}_readPipeIfc_readMetaPipeIn", self.clock))
            self.completer_read_data_pipes.append(BluespecPipeOut(
                dut, f"{base_name}_readPipeIfc_readDataPipeOut", self.clock))

        self.completer_channel_cnt = len(completer_ifc_base_names)

        self.completer_inflight_read_enevts = [
            [] for _ in range(self.completer_channel_cnt)]
        self.completer_inflight_read_resps = [
            [] for _ in range(self.completer_channel_cnt)]

        self.mem = mem or [0] * (1 << 25)

        for channel_idx in range(self.requester_channel_cnt):
            cocotb.start_soon(
                self._handle_requester_write_req_meta(channel_idx))
            cocotb.start_soon(
                self._handle_requester_write_req_data(channel_idx))
            cocotb.start_soon(self._handle_requester_read_req(channel_idx))
            cocotb.start_soon(
                self._forward_delayed_requester_read_resp(channel_idx))

        for channel_idx in range(self.completer_channel_cnt):
            cocotb.start_soon(self._handle_completer_read_resp(channel_idx))

    async def _handle_requester_write_req_meta(self, channel_idx):
        # loop to handle each request
        while True:
            cur_time = cocotb.utils.get_sim_time("ns")
            if await self.requester_write_meta_pipes[channel_idx].not_empty():
                write_meta_raw = await self.requester_write_meta_pipes[channel_idx].first()
                await self.requester_write_meta_pipes[channel_idx].deq()
                write_meta = BlueRdmaDtldStreamMemAccessMeta.unpack(
                    write_meta_raw)
                cur_write_addr = write_meta.addr()

                self.requester_pending_write_metas[channel_idx].append(
                    (cur_time, write_meta))
                self.log.debug(
                    f"put write request to delay queue cur_write_addr={hex(cur_write_addr)}, total_len={hex(write_meta.total_len())}")

            await RisingEdge(self.clock)  # wait for next write req

    async def _handle_requester_write_req_data(self, channel_idx):
        # loop to handle each request
        while True:
            cur_time = cocotb.utils.get_sim_time("ns")
            if len(self.requester_pending_write_metas[channel_idx]) != 0:
                enq_time, write_meta = self.requester_pending_write_metas[channel_idx][0]
                if cur_time - enq_time >= self.write_meta_to_data_delay_ns:

                    self.requester_pending_write_metas[channel_idx].pop(0)
                    cur_write_addr = write_meta.addr()
                    total_len = 0

                    self.log.debug(
                        f"get write request from delay queue cur_write_addr={hex(cur_write_addr)}, total_len={hex(write_meta.total_len())}")
                    # loop to handle each beat in a request
                    while True:
                        if await self.requester_write_data_pipes[channel_idx].not_empty():
                            write_data_raw = await self.requester_write_data_pipes[channel_idx].first()
                            await self.requester_write_data_pipes[channel_idx].deq()
                            write_data = BlueRdmaDataStream.unpack(
                                write_data_raw)

                            data = write_data.data()
                            if (write_data.is_first()):
                                data >>= (write_data.start_byte_index() * 8)

                            old_write_addr = cur_write_addr
                            # since pcie stream is aligned to 4 byte, each beat's first 3 byte may be invalid
                            skip_byte_cnt = cur_write_addr % 4
                            for byte_idx in range(write_data.byte_num()):
                                if byte_idx >= skip_byte_cnt:
                                    self.mem[cur_write_addr] = data & 0xff
                                    cur_write_addr += 1
                                data >>= 8

                            total_len += (write_data.byte_num() -
                                          skip_byte_cnt)
                            self.log.debug(
                                f"pcie bfm write host mem. write_addr = {hex(old_write_addr)}, write_data={write_data}", )

                            if (write_data.is_last()):
                                print(
                                    f"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx, {total_len}, {write_meta.total_len()}")
                                assert total_len == write_meta.total_len()
                                break
                        await RisingEdge(self.clock)  # wait for next beat

            await RisingEdge(self.clock)  # wait for next write req

    async def _handle_requester_read_req(self, channel_idx):
        # loop to handle each request
        while True:
            if await self.requester_read_meta_pipes[channel_idx].not_empty():
                read_meta_raw = await self.requester_read_meta_pipes[channel_idx].first()
                await self.requester_read_meta_pipes[channel_idx].deq()
                read_meta = BlueRdmaDtldStreamMemAccessMeta.unpack(
                    read_meta_raw)

                cur_read_addr = read_meta.addr()
                bytes_left = read_meta.total_len()
                is_first = True
                self.log.debug(
                    f"pcie bfm got read request: cur_read_addr={hex(cur_read_addr)}, bytes_left={hex(bytes_left)}")
                read_req_arrive_time = cocotb.utils.get_sim_time("ns")
                # loop to handle each beat in a request
                while True:

                    data = 0

                    if is_first:
                        start_byte_index = cur_read_addr & 0x03
                    else:
                        start_byte_index = 0

                    if bytes_left + start_byte_index <= DATA_BUS_BYTE_WIDTH:
                        is_last = True
                        byte_num = bytes_left
                    else:
                        is_last = False
                        byte_num = DATA_BUS_BYTE_WIDTH - start_byte_index

                    old_read_addr = cur_read_addr
                    for byte_idx in range(byte_num):
                        data |= (self.mem[cur_read_addr] << (byte_idx * 8))
                        cur_read_addr += 1

                    if (is_first):
                        data <<= (start_byte_index * 8)

                    read_data = BlueRdmaDataStream(
                        data=data.to_bytes(
                            DATA_BUS_BYTE_WIDTH, byteorder="little"),
                        byte_num=byte_num,
                        start_byte_index=start_byte_index,
                        is_first=is_first,
                        is_last=is_last
                    )

                    self.read_delay_queues[channel_idx].append(
                        (read_data.pack(), read_req_arrive_time, old_read_addr))

                    self.log.debug(
                        f"pcie bfm sample read data and put into delay queue, channel={channel_idx} addr={hex(old_read_addr)}, read_data={read_data}")

                    is_first = False
                    bytes_left -= byte_num

                    if (is_last):
                        break
                    await RisingEdge(self.clock)  # wait for next beat

            await RisingEdge(self.clock)  # wait for next read req

    async def _forward_delayed_requester_read_resp(self, channel_idx):
        while True:
            if len(self.read_delay_queues[channel_idx]) > 0:
                if await self.requester_read_data_pipes[channel_idx].not_full():
                    cur_time = cocotb.utils.get_sim_time("ns")
                    beat_to_forward, beat_read_time, old_read_addr = self.read_delay_queues[
                        channel_idx][0]
                    if cur_time - beat_read_time >= self.read_delay_time_ns:
                        self.read_delay_queues[channel_idx].popleft()
                        await self.requester_read_data_pipes[channel_idx].enq(beat_to_forward)
                        self.log.debug(
                            f"pcie bfm read, put delayed read beat, channel={channel_idx} addr={hex(old_read_addr)}")
            await RisingEdge(self.clock)  # wait for next read req

    async def _handle_completer_read_resp(self, channel_idx):
        while True:
            if (await self.completer_read_data_pipes[channel_idx].not_empty()):
                raw_resp = await self.completer_read_data_pipes[channel_idx].first()
                await self.completer_read_data_pipes[channel_idx].deq()
                resp = BlueRdmaDataStream.unpack(raw_resp)

                assert resp.is_first() == True
                assert resp.is_last() == True
                assert resp.byte_num() == 4
                assert resp.start_byte_index() == 0
                beat_data = resp.data() & 0xFFFFFFFF
                self.completer_inflight_read_resps[channel_idx].append(
                    beat_data)
                evt = self.completer_inflight_read_enevts[channel_idx].pop(0)
                evt.set()
            await RisingEdge(self.clock)

    async def host_read_blocking(self, addr):
        read_meta = BlueRdmaDtldStreamMemAccessMeta(
            addr=addr,
            total_len=4
        )
        while not (await self.completer_read_meta_pipes[0].not_full()):
            await cocotb.triggers.Timer(2, "ns")
        await self.completer_read_meta_pipes[0].enq(read_meta.pack())
        evt = cocotb.triggers.Event()
        self.completer_inflight_read_enevts[0].append(evt)
        await evt.wait()
        resp = self.completer_inflight_read_resps[0].pop(0)
        return resp

    async def host_write_blocking(self, addr, value):
        write_meta = BlueRdmaDtldStreamMemAccessMeta(
            addr=addr,
            total_len=4
        )
        write_data = BlueRdmaDataStream(
            data=value.to_bytes(DATA_BUS_BYTE_WIDTH, byteorder="little"),
            byte_num=4,
            start_byte_index=0,
            is_first=True,
            is_last=True
        )
        while not (await self.completer_write_meta_pipes[0].not_full()) and (await self.completer_write_data_pipes[0].not_full()):
            await cocotb.triggers.Timer(2, "ns")
        await self.completer_write_meta_pipes[0].enq(write_meta.pack())
        await self.completer_write_data_pipes[0].enq(write_data.pack())
        await RisingEdge(self.clock)
