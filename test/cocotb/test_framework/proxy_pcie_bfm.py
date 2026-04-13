
from collections import deque, OrderedDict
from abc import ABC
import logging
import math
import json
import time
import threading
import queue  # Python 标准库的线程安全队列

import asyncio
import os

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ReadWrite, ReadOnly, Edge, NextTimeStep
from cocotb.queue import Queue
import cocotb.triggers
from .tcpConnectionManager import *


from .common import BluespecPipeOut, BluespecPipeInNrWithQueue, BluespecPipeIn, BlueRdmaDtldStreamMemAccessMeta

if os.environ["BLUERDMA_DATA_BUS_WIDTH"] == "256":
    from .common import BlueRdmaDataStream256 as BlueRdmaDataStream
    DATA_BUS_BYTE_WIDTH = 32
else:
    from .common import BlueRdmaDataStream512 as BlueRdmaDataStream
    DATA_BUS_BYTE_WIDTH = 64


class SimplePcieBehaviorModelProxy(object):
    def __init__(self, dut, requester_ifc_base_names, completer_ifc_base_names, mem=None, read_delay_time_ns=50, write_meta_to_data_delay_ns=50,tcp_port=7003):
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

        # 移除共享内存，改用TCP访问
        # self.mem = mem or [0] * (1 << 25)

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

        # TCP connection manager init
        self.tcpConnection = TcpConnectionManager("1", "127.0.0.1", tcp_port)
        self.requester_send_queue = queue.Queue()  # 使用线程安全的标准库Queue
        # 使用线程安全的标准库Queue，无限缓冲区长度
        self.requester_read_queue = [queue.Queue() for _ in range(self.requester_channel_cnt)]

        # TCP工作线程相关
        self.request_counter = [0] * self.requester_channel_cnt
        self.stop_tcp_threads = False

        # 启动TCP工作线程
        self.tcp_sender_thread = threading.Thread(target=self._tcp_sender_thread, daemon=True)
        self.tcp_receiver_thread = threading.Thread(target=self._tcp_receiver_thread, daemon=True)
        self.tcp_sender_thread.start()
        self.tcp_receiver_thread.start()

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
                self.log.info(
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

                    self.log.info(
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

                            # 移除直接内存访问，改为TCP请求
                            # for byte_idx in range(write_data.byte_num()):
                            #     if byte_idx >= skip_byte_cnt:
                            #         self.mem[cur_write_addr] = data & 0xff
                            #         cur_write_addr += 1
                            #     data >>= 8

                            # 生成写数据字节数组
                            write_bytes = []
                            temp_data = data
                            for byte_idx in range(write_data.byte_num()):
                                if byte_idx >= skip_byte_cnt:
                                    write_bytes.append(temp_data & 0xff)
                                    cur_write_addr += 1
                                temp_data >>= 8

                            # 生成TCP写请求
                            if write_bytes:  # 只有在有有效数据时才发送
                                request = {
                                    "type": "mem_write",
                                    "channel_id": channel_idx,
                                    "address": old_write_addr + skip_byte_cnt,
                                    "data": write_bytes,
                                    "length": len(write_bytes)
                                }

                                # 放入发送队列，由工作线程处理
                                self.requester_send_queue.put(request)  # 标准库Queue使用put而非put_nowait

                                self.log.info(
                                    f"pcie bfm send tcp write request: channel={channel_idx} addr={hex(old_write_addr + skip_byte_cnt)}, length={len(write_bytes)}")
                            else:
                                self.log.info(
                                    f"pcie bfm skip empty write: addr={hex(old_write_addr)}")

                            total_len += (write_data.byte_num() - skip_byte_cnt)
                            # self.log.info(
                            #     f"pcie bfm write host mem. write_addr = {hex(old_write_addr)}, write_data={write_data}", )

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
                    # data = 0  # 移除未使用变量

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
                    # 移除直接内存访问，改为TCP请求
                    # for byte_idx in range(byte_num):
                    #     data |= (self.mem[cur_read_addr] << (byte_idx * 8))
                    #     cur_read_addr += 1

                    # 需要更新 cur_read_addr
                    cur_read_addr += byte_num
                    # 生成TCP读请求
                    request = {
                        "type": "mem_read",
                        "channel_id": channel_idx,
                        "address": old_read_addr,
                        "length": byte_num,
                        "start_byte_index": start_byte_index,
                        "is_first": is_first,
                        "is_last": is_last,
                        "request_id": f"req_{channel_idx}_{self.request_counter[channel_idx]}"
                    }

                    # 放入发送队列，由工作线程处理
                    self.requester_send_queue.put(request)  # 标准库Queue使用put而非put_nowait
                    self.request_counter[channel_idx] += 1

                    #放入延迟队列
                    self.read_delay_queues[channel_idx].append(
                        (request, read_req_arrive_time, old_read_addr)
                    )

                    self.log.info(
                        f"→ Send TCP read request: request_id={request['request_id']} "
                        f"channel={channel_idx} addr={hex(old_read_addr)} length={byte_num} "
                        f"is_first={is_first} is_last={is_last}")

                    # 不再直接构造读数据，等待TCP响应后在延迟响应协程中处理
                    # if (is_first):
                    #     data <<= (start_byte_index * 8)

                    # read_data = BlueRdmaDataStream(
                    #     data=data.to_bytes(
                    #         DATA_BUS_BYTE_WIDTH, byteorder="little"),
                    #     byte_num=byte_num,
                    #     start_byte_index=start_byte_index,
                    #     is_first=is_first,
                    #     is_last=is_last
                    # )

                    # self.read_delay_queues[channel_idx].append(
                    #     (read_data.pack(), read_req_arrive_time, old_read_addr))

                    # self.log.info(
                    #     f"pcie bfm sample read data and put into delay queue, channel={channel_idx} addr={hex(old_read_addr)}, read_data={read_data}")

                    is_first = False
                    bytes_left -= byte_num

                    if (is_last):
                        break
                    await RisingEdge(self.clock)  # wait for next beat

            await RisingEdge(self.clock)  # wait for next read req

    async def _forward_delayed_requester_read_resp(self, channel_idx):
        while True:
            # 1. 首先检查延迟队列（保持原有延迟逻辑）
            if len(self.read_delay_queues[channel_idx]) > 0:
                if await self.requester_read_data_pipes[channel_idx].not_full():
                    cur_time = cocotb.utils.get_sim_time("ns")
                    origin_read_req, beat_read_time, old_read_addr = self.read_delay_queues[
                        channel_idx][0]
                    if cur_time - beat_read_time >= self.read_delay_time_ns:
                        # 从tcp响应队列中获取对应响应，阻塞获取
                        cur_real_time = time.time()
                        last_log_time = cur_real_time

                        # 使用阻塞方式获取响应（带超时）
                        response = None
                        while response is None:
                            try:
                                # 每5秒超时一次，用于打印日志
                                response = self.requester_read_queue[channel_idx].get(timeout=5.0)
                            except queue.Empty:
                                current_time = time.time()
                                expected_id = origin_read_req.get("request_id", "N/A")
                                self.log.warning(
                                    f"⏳ Still waiting for TCP read response: "
                                    f"channel={channel_idx} addr={hex(old_read_addr)} "
                                    f"expected_request_id={expected_id} elapsed={current_time - cur_real_time:.1f}s")
                                last_log_time = current_time
                                # 继续等待

                        # 验证 request_id 匹配
                        expected_id = origin_read_req.get("request_id")
                        actual_id = response.get("request_id")

                        if expected_id != actual_id:
                            self.log.error(
                                f"❌ Request ID mismatch! channel={channel_idx} "
                                f"addr={hex(old_read_addr)} "
                                f"expected={expected_id}, actual={actual_id}")
                            # 严重错误，直接抛出异常
                            raise ValueError(f"Request ID mismatch: expected={expected_id}, actual={actual_id}")

                        self.log.info(f"✅ Got TCP read response: request_id={actual_id} channel={channel_idx} addr={hex(old_read_addr)}")

                        # 获取响应数据和元信息
                        data_bytes = response["data"]
                        start_byte_index = response.get("start_byte_index", 0)
                        is_first = response.get("is_first", True)
                        byte_num = len(data_bytes)

                        # 转换为整数进行对齐处理
                        data = int.from_bytes(bytes(data_bytes), byteorder="little")

                        # 如果是第一个beat，需要左移对齐（参考原始代码）
                        if is_first:
                            data <<= (start_byte_index * 8)

                        # 转换为BlueRdmaDataStream对象
                        read_data = BlueRdmaDataStream(
                            data=data.to_bytes(DATA_BUS_BYTE_WIDTH, byteorder="little"),
                            byte_num=byte_num,
                            start_byte_index=start_byte_index,
                            is_first=is_first,
                            is_last=response.get("is_last", True)
                        )

                        # 从延迟队列移除已处理的请求
                        self.read_delay_queues[channel_idx].popleft()

                        # 转发packed格式到DUT
                        await self.requester_read_data_pipes[channel_idx].enq(read_data.pack())

                        self.log.debug(
                            f"✓ Forwarded read beat to DUT: request_id={actual_id} "
                            f"channel={channel_idx} addr={hex(old_read_addr)} "
                            f"delay={cur_time - beat_read_time}ns")

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

    def _tcp_sender_thread(self):
        """TCP发送工作线程"""
        while not self.stop_tcp_threads:
            try:
                # 从单一发送队列获取请求（阻塞，带超时）
                request = self.requester_send_queue.get(timeout=0.1)

                # 发送TCP请求（添加换行符以匹配receive_line协议）
                if self.tcpConnection.is_connected():
                    self.tcpConnection.send_data((json.dumps(request) + '\n').encode("utf-8"))
                    self.log.debug(f"TCP发送请求: {request['type']} channel={request['channel_id']} addr=0x{request['address']:08x}")
                else:
                    self.log.warning("TCP未连接，丢弃请求")
            except queue.Empty:
                # 队列为空是正常情况，继续等待
                continue
            except Exception as e:
                self.log.error(f"TCP发送错误: {type(e).__name__}: {e}")
                # 记录详细信息用于调试
                if 'request' in locals():
                    self.log.error(f"失败的请求: {request}")

    def _tcp_receiver_thread(self):
        """TCP接收工作线程（带超时和详细错误处理）"""
        consecutive_errors = 0
        max_consecutive_errors = 100

        while not self.stop_tcp_threads:
            try:
                # 接收TCP响应（带1秒超时）
                response_data = self.tcpConnection.receive_line(timeout=1.0)

                if response_data:
                    # 解码并去除首尾空白
                    line = response_data.decode().strip()

                    # 忽略心跳包（空行）
                    if not line:
                        self.log.debug("Received heartbeat (empty line)")
                        continue

                    # 重置错误计数器
                    consecutive_errors = 0

                    self.log.debug(f"TCP接收数据: {line}")
                    response = json.loads(line)
                    channel_id = response.get("channel_id")

                    if channel_id is not None and 0 <= channel_id < len(self.requester_read_queue):
                        # 放入对应通道的接收队列（非阻塞，标准库Queue无限缓冲区不会满）
                        self.requester_read_queue[channel_id].put(response)
                        self.log.debug(f"TCP接收响应: {response['type']} channel={channel_id}")
                    else:
                        self.log.error(f"无效的channel_id: {channel_id}, 完整响应: {response}")
                else:
                    # receive_line 超时返回 None，这是正常情况
                    pass

            except json.JSONDecodeError as e:
                consecutive_errors += 1
                self.log.error(f"JSON解析错误: {e}, 原始数据: {response_data if 'response_data' in locals() else 'N/A'}")
            except Exception as e:
                consecutive_errors += 1
                self.log.error(f"TCP接收错误: {type(e).__name__}: {e}")
                if 'response_data' in locals():
                    self.log.error(f"失败的响应数据: {response_data}")

            # 如果连续错误过多，可能是连接断开，短暂休眠后重试
            if consecutive_errors >= max_consecutive_errors:
                self.log.warning(f"连续{consecutive_errors}次接收错误，休眠1秒后继续...")
                time.sleep(1.0)
                consecutive_errors = 0
            else:
                time.sleep(0.001)  # 避免CPU占用过高

    def close(self):
        """清理TCP线程和连接"""
        self.log.info("正在关闭TCP连接和线程...")
        self.stop_tcp_threads = True

        # 等待线程结束
        if hasattr(self, 'tcp_sender_thread'):
            self.tcp_sender_thread.join(timeout=1)
        if hasattr(self, 'tcp_receiver_thread'):
            self.tcp_receiver_thread.join(timeout=1)

        # 关闭TCP连接
        if hasattr(self, 'tcpConnection'):
            self.tcpConnection.close()

        self.log.info("TCP连接和线程已关闭")
