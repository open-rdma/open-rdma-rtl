"""DMA Engine DUT access and concurrent external-memory scenarios."""

from __future__ import annotations

from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Callable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, with_timeout
from cocotb.utils import get_sim_time

from openrdma_flow_tb.cocotb_bsv import PipeIn, PipeOut
from model.dma import (
    BurstSpec,
    DmaChunkReq,
    DmaCompletionBeat,
    DmaMessage,
    DmaMessageDone,
    DmaPayloadBeat,
    DmaReadRequest,
    DmaScoreboard,
    all_bursts,
    completion_beats,
    expected_done,
    expected_payload,
)

StallPolicy = int | Callable[[], int]

# 本 target 的 model clock 固定为 2 ns；BFM 只在此处换算 cycle。
MODEL_CLOCK_PS = 2_000


@dataclass
class DmaScenarioMetrics:
    """记录性能测试需要的真实 handshake 时间。"""

    request_issue_ps: list[int] = field(default_factory=list)
    payload_accept_ps: list[int] = field(default_factory=list)
    payload_valid_bytes: list[int] = field(default_factory=list)


def _cycle() -> int:
    return int(get_sim_time("ps")) // MODEL_CLOCK_PS


def _stall_cycles(policy: StallPolicy) -> int:
    return max(0, int(policy() if callable(policy) else policy))


async def _wait_stall(clock, policy: StallPolicy) -> None:
    for _ in range(_stall_cycles(policy)):
        await RisingEdge(clock)


class DmaTB:
    def __init__(self, dut) -> None:
        self.dut = dut
        self.clock = dut.CLK
        self.resetn = dut.RST_N
        # 所有 ActionMethod 在 reset 前构造，确保 Icarus 的 EN 始终被驱动为 0。
        self.chunk = PipeIn(dut, "chunkPipeIn", self.clock)
        self.dma_request = PipeOut(dut, "dmaReadReqPipeOut", self.clock)
        self.completion = PipeIn(dut, "dmaCompletionPipeIn", self.clock)
        self.payload = PipeOut(dut, "payloadPipeOut", self.clock)
        self.done = PipeOut(dut, "messageDonePipeOut", self.clock)

    async def reset(self) -> None:
        cocotb.start_soon(Clock(self.clock, 2, unit="ns").start())
        self.resetn.value = 0
        for _ in range(4):
            await RisingEdge(self.clock)
        self.resetn.value = 1
        for _ in range(4):
            await RisingEdge(self.clock)

    async def put_chunk(self, chunk: DmaChunkReq) -> None:
        await self.chunk.enq(chunk.pack())

    async def put_message(self, message: DmaMessage) -> None:
        for chunk in message.chunks:
            await self.put_chunk(chunk)

    async def _get(self, pipe: PipeOut, struct_type):
        while not await pipe.not_empty():
            await RisingEdge(self.clock)
        value = struct_type.unpack(await pipe.first())
        await pipe.deq()
        return value

    async def get_request(self) -> DmaReadRequest:
        return await self._get(self.dma_request, DmaReadRequest)

    async def put_completion(self, completion: DmaCompletionBeat) -> None:
        await self.completion.enq(completion.pack())

    async def get_payload(self) -> DmaPayloadBeat:
        return await self._get(self.payload, DmaPayloadBeat)

    async def get_done(self) -> DmaMessageDone:
        return await self._get(self.done, DmaMessageDone)


async def run_dma_scenario(
    tb: DmaTB,
    messages: list[DmaMessage],
    *,
    completion_order: str = "in_order",
    rng=None,
    message_stall: StallPolicy = 0,
    request_stall: StallPolicy = 0,
    completion_stall: StallPolicy = 0,
    request_latency_cycles: int = 0,
    prime_outstanding: int = 0,
    payload_stall: StallPolicy = 0,
    done_stall: StallPolicy = 0,
    metrics: DmaScenarioMetrics | None = None,
    timeout_cycles: int | None = None,
    event: str = "dma",
) -> list[DmaReadRequest]:
    """并发运行 chunk/request/completion/payload/done 五条协程。"""

    if request_latency_cycles < 0:
        raise ValueError("request_latency_cycles 不能为负数")
    if not 0 <= prime_outstanding <= 8:
        raise ValueError("prime_outstanding 必须位于 0..8")

    expected_bursts = all_bursts(messages)
    expected_payloads = expected_payload(messages)
    expected_dones = expected_done(messages)
    total_requests = len(expected_bursts)
    total_completions = len(expected_payloads)

    pending_requests: list[tuple[DmaReadRequest, int]] = []
    collected_requests: list[DmaReadRequest] = []
    live_slots: dict[int, int] = {}
    last_payload_accept_count: dict[int, int] = {}

    async def drive_messages() -> None:
        for message in messages:
            for chunk in message.chunks:
                await _wait_stall(tb.clock, message_stall)
                await tb.put_chunk(chunk)

    async def collect_requests() -> None:
        for index, expected in enumerate(expected_bursts):
            await _wait_stall(tb.clock, request_stall)
            actual = await tb.get_request()
            DmaScoreboard.compare_request(expected, actual, index)
            tag = int(actual.tag)
            slot = tag & 0x7
            if slot in live_slots:
                raise AssertionError(
                    f"{event}: slot {slot} reused before completion: "
                    f"old={live_slots[slot]:#x} new={tag:#x}"
                )
            live_slots[slot] = tag
            collected_requests.append(actual)
            issue_cycle = _cycle()
            pending_requests.append(
                (actual, issue_cycle + request_latency_cycles)
            )
            if metrics is not None:
                metrics.request_issue_ps.append(int(get_sim_time("ps")))

    async def drive_completions() -> None:
        active: OrderedDict[int, tuple[deque[DmaCompletionBeat], int]] = OrderedDict()
        sent = 0
        prime_target = prime_outstanding or (
            1 if completion_order == "in_order" else min(8, total_requests)
        )
        primed = prime_target <= 1
        rr_index = 0
        while sent < total_completions:
            while pending_requests:
                request, ready_cycle = pending_requests.pop(0)
                active[int(request.tag)] = (
                    deque(completion_beats(request)), ready_cycle
                )

            if not primed:
                if len(active) >= min(prime_target, total_requests) or (
                    len(collected_requests) == total_requests
                ):
                    primed = True
                else:
                    await RisingEdge(tb.clock)
                    continue

            ready_tags = [
                tag for tag, (_, ready_cycle) in active.items()
                if _cycle() >= ready_cycle
            ]
            if not ready_tags:
                await RisingEdge(tb.clock)
                continue

            if completion_order == "in_order":
                tag = ready_tags[0]
            elif completion_order == "reverse":
                tag = ready_tags[-1]
            elif completion_order == "head_last":
                tag = ready_tags[-1] if len(ready_tags) > 1 else ready_tags[0]
            elif completion_order == "round_robin":
                tag = ready_tags[rr_index % len(ready_tags)]
                rr_index += 1
            elif completion_order == "random":
                if rng is None:
                    raise ValueError("random completion order requires rng")
                tag = rng.choice(ready_tags)
            else:
                raise ValueError(f"unknown completion order: {completion_order}")

            beats, _ = active[tag]
            completion = beats.popleft()
            await _wait_stall(tb.clock, completion_stall)
            await tb.put_completion(completion)
            sent += 1
            if not beats:
                del active[tag]
                slot = tag & 0x7
                if live_slots.pop(slot, None) != tag:
                    raise AssertionError(f"{event}: live slot tracking lost tag {tag:#x}")

    async def collect_payloads() -> None:
        for index, expected in enumerate(expected_payloads):
            await _wait_stall(tb.clock, payload_stall)
            actual = await tb.get_payload()
            DmaScoreboard.compare_struct(expected, actual, f"{event}.payload", index)
            if metrics is not None:
                metrics.payload_accept_ps.append(int(get_sim_time("ps")))
                metrics.payload_valid_bytes.append(int(actual.keep).bit_count())
            if int(actual.last):
                wqe_tag = int(actual.wqeTag)
                last_payload_accept_count[wqe_tag] = (
                    last_payload_accept_count.get(wqe_tag, 0) + 1
                )

    async def collect_dones() -> None:
        for index, expected in enumerate(expected_dones):
            await _wait_stall(tb.clock, done_stall)
            while not await tb.done.not_empty():
                await RisingEdge(tb.clock)
            actual = DmaMessageDone.unpack(await tb.done.first())
            # 给同一 clock edge 上的 payload collector 一个 delta 后再判断因果。
            await Timer(1, unit="ps")
            wqe_tag = int(actual.wqeTag)
            if last_payload_accept_count.get(wqe_tag, 0) == 0:
                raise AssertionError(
                    f"{event}: done became visible before last payload deq: "
                    f"wqeTag={wqe_tag:#x}"
                )
            last_payload_accept_count[wqe_tag] -= 1
            await tb.done.deq()
            DmaScoreboard.compare_struct(expected, actual, f"{event}.done", index)

    tasks = [
        cocotb.start_soon(drive_messages()),
        cocotb.start_soon(collect_requests()),
        cocotb.start_soon(drive_completions()),
        cocotb.start_soon(collect_payloads()),
        cocotb.start_soon(collect_dones()),
    ]
    if timeout_cycles is None:
        timeout_cycles = 2000 + 30 * (len(messages) + total_requests + total_completions)

    async def wait_all() -> None:
        for task in tasks:
            await task

    await with_timeout(wait_all(), timeout_cycles * 2, "ns")

    if live_slots or pending_requests:
        raise AssertionError(f"{event}: scenario ended with live DMA transactions")
    for _ in range(16):
        await RisingEdge(tb.clock)
        if await tb.dma_request.not_empty():
            raise AssertionError(f"{event}: unexpected trailing DMA request")
        if await tb.payload.not_empty():
            raise AssertionError(f"{event}: unexpected trailing payload")
        if await tb.done.not_empty():
            raise AssertionError(f"{event}: unexpected trailing done")
    return collected_requests
