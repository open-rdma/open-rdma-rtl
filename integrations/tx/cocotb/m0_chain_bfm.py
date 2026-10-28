"""BFM and concurrent scoreboard for the end-to-end M0 -> M3 chain.

Drives mkTestM0Chain (mvp TxMvp -> M0MessageAdapter glue ->
mkDmaPhaseAIntegration) from GDRP submissions plus the four M0 table config
servers, services the DMA request tap with a deterministic memory image, and
scores every observable output -- DmaEngine requests, DmaMessageDone,
TxCommit, and the four channel frame streams -- against a specification that
is derived exclusively from the submissions and table configurations
(M0RefModel in m0_chain_model), never from the DUT.

There is intentionally no negative test suite for the m0chain target: the
glue's assertions (M0CHAIN_*) are cross-checks that fire only when M0 drifts
from the Phase-A packetizer contract, which cannot be provoked from the test
boundary by a "valid-looking" input. Invalid inputs are rejected upstream by
M0's own dynamic asserts (unit-tested in the mvp tx suite).
"""

from __future__ import annotations

from collections import OrderedDict, deque
from dataclasses import dataclass, field

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import RisingEdge, with_timeout
from cocotb.utils import get_sim_time
from openrdma_flow_tb.cocotb_bsv import PipeIn, PipeOut

from openrdma_flow_tb.tx.bfm.m3 import (
    collect_commit, collect_egress, collect_frame, configure, pipe_get,
)
from openrdma_flow_tb.tx.model.dma_phasea import (
    DmaMessageDone,
    DmaReadRequest,
    completion_beats,
    data_byte,
)
from m0_chain_model import (
    DecodedGdrpSubmission,
    MrCfgReq,
    PgtCfgReq,
    QpCfgReq,
    SlotCfgReq,
    TxCfgResp,
    TxDmaReadRequest,
    make_token,
    packet_count,
)
from openrdma_flow_tb.tx.model.m2 import MessageContext, WIRE_LEGACY_PRIVATE, packetize
from openrdma_flow_tb.tx.model.m3 import MacIpConfig, expected_frame

# pipe_get's default budget is 20_000 cycles (~40 us at the 2 ns clock), which
# a single large message legitimately exceeds: the tracker's DmaMessageDone
# for a 2 MiB message fires only after the whole payload has traversed
# compactor -> M2 -> M3 (~100+ us of pipeline latency, message-serial by
# construction).  The per-get cap below (8 ms) stays far under every test's
# own timeout, so a genuine stall still fails fast -- but a slow-but-valid
# message no longer trips it.
_GET_CYCLES = 4_000_000
# 这些 target 的 model clock 固定为 2 ns；BFM 只在此处换算 cycle。
MODEL_CLOCK_PS = 2_000


async def _pipe_get(pipe, clock) -> int:
    return await pipe_get(pipe, clock, cycles=_GET_CYCLES)


@dataclass(frozen=True)
class M0Submission:
    qpn: int
    slot_id: int
    length: int
    debug_seq: int = 0


@dataclass
class M0ChainScenarioMetrics:
    """记录 M0→M3 性能窗口的真实 handshake 时间。"""

    submission_accept_ps: list[int] = field(default_factory=list)
    dma_request_issue_ps: list[int] = field(default_factory=list)
    tx_commit_ps: list[int] = field(default_factory=list)
    frame_eof_ps: list[int] = field(default_factory=list)
    frame_payload_bytes: list[int] = field(default_factory=list)
    frame_channels: list[int] = field(default_factory=list)


def _cycle() -> int:
    return int(get_sim_time("ps")) // MODEL_CLOCK_PS


@dataclass(frozen=True)
class EngineChunkSpec:
    """Expected DmaReadRequest fields for one chunk (1:1 with an M0 burst)."""

    wqe_tag: int
    chunk_seq: int
    physical_addr: int
    length: int
    message_offset: int
    is_first: int
    is_last: int


@dataclass(frozen=True)
class ExpectedMessage:
    context: MessageContext
    payload: bytes
    chunks: tuple[EngineChunkSpec, ...]

    @property
    def packets(self):
        return packetize(self.context, self.payload)


class M0ChainTB:
    def __init__(self, dut) -> None:
        self.dut = dut
        self.clock = dut.CLK
        self.resetn = dut.RST_N
        self.submission = PipeIn(dut, "submissionPipeIn", self.clock)
        self.slot_cfg_req = PipeIn(dut, "slotCfgReqPipeIn", self.clock)
        self.slot_cfg_resp = PipeOut(dut, "slotCfgRespPipeOut", self.clock)
        self.qp_cfg_req = PipeIn(dut, "qpCfgReqPipeIn", self.clock)
        self.qp_cfg_resp = PipeOut(dut, "qpCfgRespPipeOut", self.clock)
        self.mr_cfg_req = PipeIn(dut, "mrCfgReqPipeIn", self.clock)
        self.mr_cfg_resp = PipeOut(dut, "mrCfgRespPipeOut", self.clock)
        self.pgt_cfg_req = PipeIn(dut, "pgtCfgReqPipeIn", self.clock)
        self.pgt_cfg_resp = PipeOut(dut, "pgtCfgRespPipeOut", self.clock)
        self.dma_request = PipeOut(dut, "dmaReadReqPipeOut", self.clock)
        self.completion = PipeIn(dut, "dmaCompletionPipeIn", self.clock)
        self.channels = [
            PipeOut(dut, f"channel{index}PipeOut", self.clock)
            for index in range(4)
        ]
        self.commits = PipeOut(dut, "txCommitPipeOut", self.clock)
        self.egress = PipeOut(dut, "txEgressPipeOut", self.clock)
        self.done = PipeOut(dut, "dmaMessageDonePipeOut", self.clock)
        self.config = PipeIn(dut, "configPipeIn", self.clock)
        self.config_response = PipeOut(dut, "configRespPipeOut", self.clock)
        # TxEgressEvent backpressures the encoder until it is drained, so the
        # chain keeps a background consumer even when it does not inspect it.

    async def reset(self) -> None:
        cocotb.start_soon(Clock(self.clock, 2, unit="ns").start())
        self.resetn.value = 0
        for _ in range(4):
            await RisingEdge(self.clock)
        self.resetn.value = 1
        for _ in range(4):
            await RisingEdge(self.clock)
        self._drain = cocotb.start_soon(self._drain_egress())

    async def _drain_egress(self) -> None:
        while True:
            await collect_egress(self)


async def _configure(req: PipeIn, resp: PipeOut, packed: int, clock) -> None:
    await req.enq(packed)
    response = TxCfgResp.unpack(await _pipe_get(resp, clock))
    assert int(response.success) == 1


async def configure_slot(tb: M0ChainTB, model, index: int, entry) -> None:
    await _configure(tb.slot_cfg_req, tb.slot_cfg_resp, SlotCfgReq(index=index, entry=entry).pack(), tb.clock)
    model.configure_slot(index, entry)


async def configure_qp(tb: M0ChainTB, model, index: int, entry) -> None:
    await _configure(tb.qp_cfg_req, tb.qp_cfg_resp, QpCfgReq(index=index, entry=entry).pack(), tb.clock)
    model.configure_qp(index, entry)


async def configure_mr(tb: M0ChainTB, model, index: int, entry) -> None:
    await _configure(tb.mr_cfg_req, tb.mr_cfg_resp, MrCfgReq(index=index, entry=entry).pack(), tb.clock)
    model.configure_mr(index, entry)


async def configure_pte(tb: M0ChainTB, model, index: int, entry) -> None:
    await _configure(tb.pgt_cfg_req, tb.pgt_cfg_resp, PgtCfgReq(index=index, entry=entry).pack(), tb.clock)
    model.configure_pte(index, entry)


def spec_context(first: TxDmaReadRequest) -> MessageContext:
    assert int(first.isFirst) == 1
    qpn = int(first.qpn)
    return MessageContext(
        requestId=int(first.requestId),
        qpn=qpn,
        destQpn=qpn,  # M0 is a self-loop WRITE; the adapter forwards qpn.
        slotId=int(first.slotId),
        debugSeq=int(first.debugSeq),
        pmtu=int(first.pmtu),
        startPsn=int(first.startPsn),
        psnCount=int(first.psnCount),
        remoteAddr=int(first.remoteAddr),
        remoteKey=int(first.remoteKey),
        len=int(first.messageLength),
        wireProfile=WIRE_LEGACY_PRIVATE,
        evProfileId=0,
        mrcMsn=0,
        mrcMsnValid=0,
    )


def payload_of(requests: tuple[TxDmaReadRequest, ...]) -> bytes:
    """Deterministic memory image: byte(addr) == data_byte(addr)."""
    return bytes(
        data_byte(address)
        for request in requests
        for address in range(
            int(request.physicalAddr), int(request.physicalAddr) + int(request.len)
        )
    )


def engine_specs(requests: tuple[TxDmaReadRequest, ...]) -> tuple[EngineChunkSpec, ...]:
    offset = 0
    result = []
    for index, request in enumerate(requests):
        result.append(
            EngineChunkSpec(
                wqe_tag=int(request.requestId),
                chunk_seq=int(request.dmaSeq),
                physical_addr=int(request.physicalAddr),
                length=int(request.len),
                message_offset=offset,
                is_first=int(request.isFirst),
                is_last=int(request.isLast),
            )
        )
        offset += int(request.len)
    return tuple(result)


def expect_message(
    model, spec: M0Submission
) -> ExpectedMessage:
    """Ask the M0 reference model for a submission and derive every expectation."""
    token = make_token(slot_id=spec.slot_id, length=spec.length, debug_seq=spec.debug_seq)
    requests = tuple(model.submit(qpn=spec.qpn, token=token))
    assert requests, "reference model produced no requests"
    context = spec_context(requests[0])
    payload = payload_of(requests)
    assert len(payload) == spec.length == int(context.len)
    assert int(context.psnCount) == packet_count(spec.length, int(context.pmtu))
    assert len(requests) == int(requests[-1].dmaSeq) + 1
    assert int(requests[-1].isLast) == 1
    return ExpectedMessage(
        context=context, payload=payload, chunks=engine_specs(requests)
    )


def _compare_request(expected: EngineChunkSpec, actual: DmaReadRequest, index: int) -> None:
    values = {
        "wqeTag": expected.wqe_tag,
        "chunkSeq": expected.chunk_seq,
        "physAddr": expected.physical_addr,
        "len": expected.length,
        "messageOffset": expected.message_offset,
        "isFirst": expected.is_first,
        "isLast": expected.is_last,
    }
    for field, expected_value in values.items():
        actual_value = int(getattr(actual, field))
        assert actual_value == expected_value, (
            f"request[{index}].{field}: expected={expected_value:#x} "
            f"actual={actual_value:#x}"
        )


def _compare_frame(expected, actual: object, index: int) -> None:
    assert actual == expected, (
        f"frame[{index}] mismatch\n"
        f"expected={expected!r}\nactual={actual!r}"
    )


async def run_m0_chain_scenario(
    tb: M0ChainTB,
    model,
    specs: list[M0Submission],
    cfg: MacIpConfig,
    *,
    channel_enable: int = 0xF,
    completion_order: str = "reverse",
    request_latency_cycles: int = 0,
    prime_outstanding: int = 8,
    serial_dma: bool = False,
    metrics: M0ChainScenarioMetrics | None = None,
    timeout_ns: int = 3_000_000,
) -> None:
    if request_latency_cycles < 0:
        raise ValueError("request_latency_cycles 不能为负数")
    if not 1 <= prime_outstanding <= 8:
        raise ValueError("prime_outstanding 必须位于 1..8")
    if completion_order not in {"in_order", "reverse", "round_robin"}:
        raise ValueError(f"不支持的 completion_order：{completion_order}")

    await configure(tb, cfg, channel_enable=channel_enable)

    expected = [expect_message(model, spec) for spec in specs]
    chunk_records = [
        (message_id, chunk)
        for message_id, message in enumerate(expected)
        for chunk in message.chunks
    ]
    packet_records = [
        (message_id, packet)
        for message_id, message in enumerate(expected)
        for packet in message.packets
    ]
    expected_packets = [packet for _, packet in packet_records]
    expected_frames = [
        expected_frame(packet.descriptor, packet.payload, cfg)
        for packet in expected_packets
    ]
    if metrics is not None:
        metrics.submission_accept_ps.clear()
        metrics.dma_request_issue_ps.clear()
        metrics.tx_commit_ps = [0] * len(expected_packets)
        metrics.frame_eof_ps = [0] * len(expected_frames)
        metrics.frame_payload_bytes = [
            len(packet.payload) for packet in expected_packets
        ]
        metrics.frame_channels = [-1] * len(expected_frames)

    async def produce() -> None:
        for spec in specs:
            token = make_token(
                slot_id=spec.slot_id, length=spec.length, debug_seq=spec.debug_seq
            )
            submission = DecodedGdrpSubmission(qpn=spec.qpn, token=token)
            await tb.submission.enq(submission.pack())
            if metrics is not None:
                metrics.submission_accept_ps.append(int(get_sim_time("ps")))

    pending_dma: list[tuple[DmaReadRequest, int, int]] = []
    requests_collected = 0

    async def collect_dma_requests() -> None:
        nonlocal requests_collected
        for request_index, (message_id, chunk) in enumerate(chunk_records):
            actual = DmaReadRequest.unpack(
                await _pipe_get(tb.dma_request, tb.clock)
            )
            _compare_request(chunk, actual, request_index)
            pending_dma.append(
                (actual, message_id, _cycle() + request_latency_cycles)
            )
            requests_collected += 1
            if metrics is not None:
                metrics.dma_request_issue_ps.append(int(get_sim_time("ps")))

    async def drive_dma_completions() -> None:
        active: OrderedDict[
            int, tuple[DmaReadRequest, int, deque, int]
        ] = OrderedDict()
        completed = 0
        primed = False
        rr_index = 0
        total_requests = len(chunk_records)
        while completed < total_requests:
            while pending_dma:
                request, message_id, ready_cycle = pending_dma.pop(0)
                active[int(request.tag)] = (
                    request,
                    message_id,
                    deque(completion_beats(request)),
                    ready_cycle,
                )

            if not primed:
                if len(active) >= min(prime_outstanding, total_requests) or (
                    requests_collected == total_requests
                ):
                    primed = True
                else:
                    await RisingEdge(tb.clock)
                    continue

            ready_tags = [
                tag for tag, (_, _, _, ready_cycle) in active.items()
                if _cycle() >= ready_cycle
            ]
            if not ready_tags:
                await RisingEdge(tb.clock)
                continue

            if completion_order == "in_order":
                tag = ready_tags[0]
            elif completion_order == "reverse":
                tag = ready_tags[-1]
            else:
                tag = ready_tags[rr_index % len(ready_tags)]
                rr_index += 1

            request, message_id, beats, ready_cycle = active[tag]
            await tb.completion.enq(beats.popleft().pack())
            if not beats:
                del active[tag]
                completed += 1

    async def service_dma_serial() -> None:
        """归档评测的模型：一次只发一个 request，收完再发下一个。"""
        for request_index, (_, chunk) in enumerate(chunk_records):
            actual = DmaReadRequest.unpack(
                await _pipe_get(tb.dma_request, tb.clock)
            )
            _compare_request(chunk, actual, request_index)
            if metrics is not None:
                metrics.dma_request_issue_ps.append(int(get_sim_time("ps")))
            for _ in range(request_latency_cycles):
                await RisingEdge(tb.clock)
            for beat in completion_beats(actual):
                await tb.completion.enq(beat.pack())

    async def collect_dones() -> None:
        for index, message in enumerate(expected):
            actual = DmaMessageDone.unpack(await _pipe_get(tb.done, tb.clock))
            assert int(actual.wqeTag) == int(message.context.requestId), index
            assert int(actual.length) == len(message.payload), index
            assert int(actual.chunkCount) == len(message.chunks), index

    async def collect_tx() -> None:
        queues = [Queue() for _ in range(4)]

        async def channel_worker(channel: int) -> None:
            while True:
                item = await queues[channel].get()
                if item is None:
                    return
                index, expected = item
                actual = await collect_frame(tb, channel)
                if metrics is not None:
                    metrics.frame_eof_ps[index] = int(get_sim_time("ps"))
                    metrics.frame_channels[index] = channel
                _compare_frame(expected, actual, index)

        workers = [cocotb.start_soon(channel_worker(channel)) for channel in range(4)]
        for index, packet in enumerate(expected_packets):
            commit = await collect_commit(tb)
            if metrics is not None:
                metrics.tx_commit_ps[index] = int(get_sim_time("ps"))
            descriptor = packet.descriptor
            assert int(commit.requestId) == int(descriptor.requestId), index
            assert int(commit.qpn) == int(descriptor.qpn), index
            assert int(commit.psn) == int(descriptor.psn), index
            assert int(commit.packetIndex) == int(descriptor.packetIndex), index
            assert int(commit.trafficClass) == int(descriptor.trafficClass), index
            channel = int(commit.channel)
            assert channel_enable & (1 << channel), index
            await queues[channel].put((index, expected_frames[index]))

        for queue in queues:
            await queue.put(None)
        for worker in workers:
            await worker

    if serial_dma:
        tasks = [
            cocotb.start_soon(produce()),
            cocotb.start_soon(service_dma_serial()),
            cocotb.start_soon(collect_dones()),
            cocotb.start_soon(collect_tx()),
        ]
    else:
        tasks = [
            cocotb.start_soon(produce()),
            cocotb.start_soon(collect_dma_requests()),
            cocotb.start_soon(drive_dma_completions()),
            cocotb.start_soon(collect_dones()),
            cocotb.start_soon(collect_tx()),
        ]

    async def wait_all() -> None:
        for task in tasks:
            await task

    await with_timeout(wait_all(), timeout_ns, "ns")

    if metrics is not None:
        assert len(metrics.submission_accept_ps) == len(specs)
        assert len(metrics.dma_request_issue_ps) == len(chunk_records)
        assert all(metrics.tx_commit_ps), "存在未记录时间的 TxCommit"
        assert all(metrics.frame_eof_ps), "存在未记录 EOF 时间的 frame"
        assert all(channel >= 0 for channel in metrics.frame_channels)

    for _ in range(16):
        await RisingEdge(tb.clock)
        assert not await tb.dma_request.not_empty(), "trailing DMA request"
        assert not await tb.done.not_empty(), "trailing DMA done"
        assert not await tb.commits.not_empty(), "trailing TxCommit"
        for channel in tb.channels:
            assert not await channel.not_empty(), "trailing EthPacket"
