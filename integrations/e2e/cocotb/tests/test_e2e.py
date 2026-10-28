"""完整 TX -> RX -> Retx 数据链路测试。

覆盖两条路径：

1. ``test_normal_tx_rx_path``：无丢包，报文只经过 M2 -> M3 -> RxTop，
   CPU 定期取 report 但不需要发起任何重传。
2. ``test_cpu_driven_retry_keeps_main_dataflow``：链路误码导致一个 packet
   丢失；RX 的 SACK 反馈驱动 M9 scoreboard，CPU 通过 report 发现 hole，
   下发 RetryEntry；M11 经 replay store 取回 payload，从 M3 的
   TRAFFIC_RETRY 入口插回主数据流，最终两条 message 都完成。

CPU 侧使用 production codec + ``retx_runtime`` 的 SACK-hole 策略，测试只
负责扮演 host driver 和 wire model。
"""

from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, with_timeout

from openrdma_flow_tb.cocotb_bsv import ActionMethod, PipeIn, PipeOut
from openrdma_flow_tb.rx.bfm.common import pipe_get, pipe_put, reset_dut
from openrdma_flow_tb.rx.model.types import (
    RxCompletion,
    RxDmaCompletion,
    RxDmaPayloadBeat,
    RxDmaWriteRequest,
    RxError,
    RxFeedback,
    RxNetworkConfig,
    RxQpConfig,
    RxWireBeat,
)
from openrdma_flow_tb.tx.model.m2 import (
    WIRE_LEGACY_PRIVATE,
    MessageContext,
    message_beats,
    packet_lengths,
    packetize,
)
from openrdma_flow_tb.tx.model.m3 import (
    CfgResp,
    EthPacket,
    MacIpConfig,
    MrcSourceProfileConfig,
    MrcTxCfgReq,
    TxCommit,
    TxEgressEvent,
)

from e2e_cpu import E2eCpu
from e2e_layouts import pack_named, unpack_named

QPN = 7
DEST_QPN = 7
EPOCH = 1
INITIAL_PSN = 0x000100
RKEY = 0x1234_5678
VIRT_BASE = 0x1000
PHYS_BASE = 0x8000
REGION_BYTES = 0x10000
HOST_SESSION = 0x1234
NIC_SESSION = 0x0BAD

PMTU = 0
MSG_A_LEN = 1500
MSG_A_ADDR = 0x2000
MSG_B_LEN = 900
MSG_B_ADDR = 0x3000
DROP_PACKET_INDEX = 1

CFG = MacIpConfig(
    srcMac=0x020000000001,
    dstMac=0x020000000002,
    srcIp=0x0A000001,
    dstIp=0x0A000002,
)
RX_NETWORK = RxNetworkConfig(
    localMac=0x020000000002,
    localIp=0x0A000002,
    peerMac=0x020000000001,
    peerIp=0x0A000001,
)

_LONG = 4_000_000  # cycles; background consumers must not time out between events


def payload_bytes(length: int, seed: int) -> bytes:
    return bytes(((index * 37 + seed * 11 + 5) & 0xFF) for index in range(length))


def make_context(request_id: int, start_psn: int, length: int, addr: int) -> MessageContext:
    return MessageContext(
        requestId=request_id,
        qpn=QPN,
        destQpn=DEST_QPN,
        slotId=request_id,
        debugSeq=request_id & 0xF,
        pmtu=PMTU,
        startPsn=start_psn,
        psnCount=len(packet_lengths(length, PMTU, WIRE_LEGACY_PRIVATE)),
        remoteAddr=addr,
        remoteKey=RKEY,
        len=length,
        wireProfile=WIRE_LEGACY_PRIVATE,
        evProfileId=0,
        mrcMsn=0,
        mrcMsnValid=0,
    )


class E2eTB:
    def __init__(self, dut) -> None:
        self.dut = dut
        self.clock = dut.CLK

        self.tx_context = PipeIn(dut, "txContextIn", self.clock)
        self.tx_payload = PipeIn(dut, "txPayloadIn", self.clock)
        self.tx_config = PipeIn(dut, "txConfigIn", self.clock)
        self.tx_config_out = PipeOut(dut, "txConfigOut", self.clock)
        self.tx_source_route = PipeIn(dut, "txSourceRouteConfigIn", self.clock)
        self.channels = [PipeOut(dut, f"txChannel{index}Out", self.clock) for index in range(4)]
        self.tx_commit = PipeOut(dut, "txCommitOut", self.clock)
        self.tx_egress = PipeOut(dut, "txEgressOut", self.clock)

        self.rx_lanes = [PipeIn(dut, f"rxLane{index}", self.clock) for index in range(4)]
        self.dma_requests = [PipeOut(dut, f"rxDmaRequest{index}", self.clock) for index in range(4)]
        self.dma_payloads = [PipeOut(dut, f"rxDmaPayload{index}", self.clock) for index in range(4)]
        self.dma_completions = [PipeIn(dut, f"rxDmaCompletion{index}", self.clock) for index in range(4)]
        self.cqe = PipeOut(dut, "rxCompletionOut", self.clock)
        self.rx_errors = PipeOut(dut, "rxErrorsOut", self.clock)
        self.rx_feedback = PipeOut(dut, "rxFeedbackObsOut", self.clock)
        self.rx_tx_feedback = PipeOut(dut, "rxTxFeedbackOut", self.clock)
        self.rx_ecn = PipeOut(dut, "rxEcnOut", self.clock)
        self.rx_credit = PipeOut(dut, "rxOrderedCreditOut", self.clock)

        self.report_header = PipeOut(dut, "retxReportHeaderOut", self.clock)
        self.report_entry = PipeOut(dut, "retxReportEntryOut", self.clock)
        self.notification = PipeOut(dut, "retxNotificationOut", self.clock)
        self.snapshot_req = PipeIn(dut, "retxSnapshotReqIn", self.clock)
        self.retry_in = PipeIn(dut, "retxRetryIn", self.clock)
        self.retx_result = PipeOut(dut, "retxResultOut", self.clock)
        self.retx_release = PipeOut(dut, "retxReleaseOut", self.clock)
        self.on_demand_in = PipeIn(dut, "retxOnDemandIn", self.clock)
        self.on_demand_out = PipeOut(dut, "retxOnDemandOut", self.clock)

        self.configure_epoch = ActionMethod(dut, "configureEpoch", self.clock)
        self.configure_network = ActionMethod(dut, "configureNetwork", self.clock)
        self.configure_qp0 = ActionMethod(dut, "configureQp0", self.clock)
        self.start = ActionMethod(dut, "start", self.clock)
        self.configure_retx = ActionMethod(dut, "configureRetx", self.clock)
        self.configure_retx_qp0 = ActionMethod(dut, "configureRetxQp0", self.clock)
        self.set_retx_epoch = ActionMethod(dut, "setRetxEpoch", self.clock)

        self.commits: list[TxCommit] = []
        self.egress: list[TxEgressEvent] = []
        self.feedback: list[RxFeedback] = []
        self.cqes: list[RxCompletion] = []
        self.errors: list[RxError] = []
        self.retx_results = []
        self.retx_releases = []
        self.dma_writes: list[tuple[RxDmaWriteRequest, bytes]] = []
        self.frames: list[tuple[int, object]] = []
        self.delivered: list[tuple[int, object]] = []
        self.dropped: list[object] = []
        self._tasks: list = []
        self._drop = None

    # -- bring-up -----------------------------------------------------------
    async def initialize(self) -> None:
        await self.configure_epoch(value=EPOCH)
        await self.configure_network(cfg=RX_NETWORK.pack())
        await self.configure_qp0(cfg=RxQpConfig(
            valid=1,
            qpn=QPN,
            initialPsn=INITIAL_PSN,
            pmtu=PMTU,
            rkey=RKEY,
            virtualBase=VIRT_BASE,
            physicalBase=PHYS_BASE,
            regionBytes=REGION_BYTES,
            remoteWrite=1,
        ).pack())
        await self.start()
        await self.configure_retx(
            hostSession=HOST_SESSION, nicSession=NIC_SESSION
        )
        await self.configure_retx_qp0(cfg=pack_named("qp", dict(
            qpn=QPN, qpEpoch=EPOCH, initialPsn=INITIAL_PSN, enable=1
        )))
        await self.set_retx_epoch(epoch=EPOCH)
        await self.configure_tx()

    async def configure_tx(self) -> None:
        await self.tx_config.enq(MrcTxCfgReq(
            cfg=CFG, channelEnable=0xF, maxHighBurst=4
        ).pack())
        response = CfgResp.unpack(await pipe_get(
            self.tx_config_out, self.clock, cycles=_LONG
        ))
        assert int(response.success) == 1
        await pipe_put(self.tx_source_route, self.clock, MrcSourceProfileConfig(
            mrcMask=0,
            firstProfileId=0,
            retryProfileId=0,
            orderedProfileId=0,
            controlProfileId=0,
        ).pack(), cycles=_LONG)

    # -- background models --------------------------------------------------
    def start_background(self, drop=None) -> None:
        self._drop = drop
        for channel in range(4):
            self._tasks.append(cocotb.start_soon(self._route_channel(channel)))
        for lane in range(4):
            self._tasks.append(cocotb.start_soon(self._service_dma_lane(lane)))
        self._tasks.append(cocotb.start_soon(self._drain_outputs()))

    def stop_background(self) -> None:
        for task in self._tasks:
            task.cancel()
        self._tasks.clear()

    async def _route_channel(self, channel: int) -> None:
        while True:
            frame = await self._capture_frame(channel)
            self.frames.append((channel, frame))
            if self._drop is not None and self._drop(frame):
                self.dropped.append(frame)
                continue
            await self._send_frame(channel, frame.data)
            self.delivered.append((channel, frame))

    async def _capture_frame(self, channel: int):
        data = bytearray()
        first = None
        while True:
            word = EthPacket.unpack(await pipe_get(
                self.channels[channel], self.clock, cycles=_LONG
            ))
            valid = int(word.be).bit_count()
            assert int(word.be) == (1 << valid) - 1
            if first is None:
                assert int(word.sof) == 1
                first = word
            else:
                assert int(word.sof) == 0
            data += int(word.data).to_bytes(32, "little")[:valid]
            if int(word.eof):
                return _Frame(
                    data=bytes(data),
                    request_id=int(first.requestId),
                    psn=int(first.psn),
                    traffic_class=int(first.trafficClass),
                    is_first=int(first.isFirst),
                    is_last=int(first.isLast),
                )

    async def _send_frame(self, lane: int, frame: bytes) -> None:
        for offset in range(0, len(frame), 32):
            chunk = frame[offset : offset + 32]
            await pipe_put(
                self.rx_lanes[lane], self.clock,
                RxWireBeat(
                    data=int.from_bytes(chunk.ljust(32, b"\x00"), "little"),
                    be=(1 << len(chunk)) - 1,
                    sof=int(offset == 0),
                    eof=int(offset + len(chunk) == len(frame)),
                ),
                cycles=_LONG,
            )

    async def _service_dma_lane(self, lane: int) -> None:
        while True:
            while not await self.dma_requests[lane].not_empty():
                await RisingEdge(self.clock)
            request = RxDmaWriteRequest.unpack(
                await self.dma_requests[lane].first()
            )
            await self.dma_requests[lane].deq()
            data = bytearray()
            while len(data) < int(request.bytes):
                beat = RxDmaPayloadBeat.unpack(await pipe_get(
                    self.dma_payloads[lane], self.clock, cycles=_LONG
                ))
                assert int(beat.epoch) == int(request.epoch)
                valid = int(beat.be).bit_count()
                assert int(beat.be) == (1 << valid) - 1
                data += int(beat.data).to_bytes(32, "little")[:valid]
            self.dma_writes.append((request, bytes(data)))
            await pipe_put(
                self.dma_completions[lane], self.clock,
                RxDmaCompletion(
                    globalSeq=int(request.globalSeq),
                    epoch=int(request.epoch),
                    lane=lane,
                    success=1,
                ).pack(),
                cycles=_LONG,
            )

    async def _drain_outputs(self) -> None:
        while True:
            if await self.tx_commit.not_empty():
                self.commits.append(TxCommit.unpack(await pipe_get(
                    self.tx_commit, self.clock, cycles=_LONG
                )))
            if await self.tx_egress.not_empty():
                self.egress.append(TxEgressEvent.unpack(await pipe_get(
                    self.tx_egress, self.clock, cycles=_LONG
                )))
            if await self.rx_feedback.not_empty():
                self.feedback.append(RxFeedback.unpack(await pipe_get(
                    self.rx_feedback, self.clock, cycles=_LONG
                )))
            if await self.cqe.not_empty():
                self.cqes.append(RxCompletion.unpack(await pipe_get(
                    self.cqe, self.clock, cycles=_LONG
                )))
            if await self.rx_errors.not_empty():
                self.errors.append(RxError.unpack(await pipe_get(
                    self.rx_errors, self.clock, cycles=_LONG
                )))
            if await self.retx_result.not_empty():
                self.retx_results.append(unpack_named(
                    "result", await pipe_get(self.retx_result, self.clock, cycles=_LONG)
                ))
            if await self.retx_release.not_empty():
                raw = await pipe_get(self.retx_release, self.clock, cycles=_LONG)
                self.retx_releases.append(unpack_named("release", raw))
            # 未被本测试使用的 RX 边带输出必须持续排空，否则内部 FIFO 会反压。
            for auxiliary in (
                self.rx_tx_feedback, self.rx_ecn, self.rx_credit,
                self.on_demand_out,
            ):
                if await auxiliary.not_empty():
                    await pipe_get(auxiliary, self.clock, cycles=_LONG)
            await RisingEdge(self.clock)

    # -- stimulus -----------------------------------------------------------
    async def feed_message(self, context: MessageContext, payload: bytes, *, beats=None) -> None:
        await pipe_put(self.tx_context, self.clock, context.pack(), cycles=_LONG)
        for beat in (beats if beats is not None else message_beats(
            payload, int(context.requestId)
        )):
            await pipe_put(self.tx_payload, self.clock, beat.pack(), cycles=_LONG)

    async def feed_beats(self, beats) -> None:
        for beat in beats:
            await pipe_put(self.tx_payload, self.clock, beat.pack(), cycles=_LONG)

    async def wait_for(self, predicate, description: str, cycles: int = 200_000) -> None:
        async def poll():
            for _ in range(cycles):
                if predicate():
                    return
                await RisingEdge(self.clock)
            raise AssertionError(f"timeout waiting for {description}")

        await with_timeout(poll(), cycles * 2, "ns")

    async def poll_report(self, expected_holes: int | None = None):
        header = None
        holes = []
        notification = {}
        for _ in range(8):
            await pipe_put(
                self.snapshot_req, self.clock,
                pack_named("snapreq", dict(
                    qpn=QPN, qpEpoch=EPOCH, onDemand=1,
                    requestId=0x100 + len(self.feedback),
                )),
                cycles=_LONG,
            )
            header = unpack_named("report", await pipe_get(
                self.report_header, self.clock, cycles=_LONG
            ))
            holes = [
                unpack_named("hole", await pipe_get(
                    self.report_entry, self.clock, cycles=_LONG
                ))
                for _ in range(int(header["hole_entries_included"]))
            ]
            notification = unpack_named("notification", await pipe_get(
                self.notification, self.clock, cycles=_LONG
            ))
            if expected_holes is None or int(header["hole_count"]) == expected_holes:
                return header, holes, notification
            for _ in range(200):
                await RisingEdge(self.clock)
        raise AssertionError(
            f"report did not reach {expected_holes} holes: {header!r}"
        )


class _Frame:
    __slots__ = ("data", "request_id", "psn", "traffic_class", "is_first", "is_last")

    def __init__(self, *, data, request_id, psn, traffic_class, is_first, is_last):
        self.data = data
        self.request_id = request_id
        self.psn = psn
        self.traffic_class = traffic_class
        self.is_first = is_first
        self.is_last = is_last


def _reassembled(writes, base: int, length: int) -> bytes:
    chunks = sorted(
        (int(request.addr), data)
        for request, data in writes
        if base <= int(request.addr) < base + length
    )
    assert sum(len(data) for _, data in chunks) == length, chunks
    cursor = base
    out = bytearray()
    for address, data in chunks:
        assert address == cursor, (address, cursor)
        out += data
        cursor += len(data)
    return bytes(out)


async def _run_retry_scenario(dut) -> None:
    tb = E2eTB(dut)
    await reset_dut(dut)
    await tb.initialize()

    payload_a = payload_bytes(MSG_A_LEN, 1)
    payload_b = payload_bytes(MSG_B_LEN, 2)
    context_a = make_context(1, INITIAL_PSN, MSG_A_LEN, MSG_A_ADDR)
    context_b = make_context(2, INITIAL_PSN + 7, MSG_B_LEN, MSG_B_ADDR)
    packets_a = packetize(context_a, payload_a)
    packets_b = packetize(context_b, payload_b)
    drop_psn = int(packets_a[DROP_PACKET_INDEX].descriptor.psn)

    tb.start_background(
        drop=lambda frame: (
            frame.request_id == 1
            and frame.traffic_class == 0
            and frame.psn == drop_psn
        )
    )
    try:
        await tb.feed_message(context_a, payload_a)
        last_a_psn = int(packets_a[-1].descriptor.psn)
        await tb.wait_for(
            lambda: any(int(item.triggerPsn) == last_a_psn for item in tb.feedback),
            "RX SACK for the last A packet",
        )
        for _ in range(100):
            await RisingEdge(tb.clock)

        header, holes, notification = await tb.poll_report(expected_holes=1)
        assert [int(hole["psn"]) for hole in holes] == [drop_psn], holes
        hole = holes[0]
        tb.dut._log.info(
            f"wire model dropped PSN {drop_psn:#x}; RX report generation "
            f"{header['report_generation']} exposes hole psn={hole['psn']:#x} "
            f"packet_index={hole['packet_index']} "
            f"offset={hole['message_offset']} len={hole['payload_length']}"
        )
        assert int(hole["packet_index"]) == DROP_PACKET_INDEX
        assert int(hole["payload_length"]) == int(
            packets_a[DROP_PACKET_INDEX].descriptor.payloadLength
        )
        assert int(hole["message_offset"]) == int(
            packets_a[DROP_PACKET_INDEX].descriptor.messageOffset
        )

        cpu = E2eCpu(HOST_SESSION, NIC_SESSION)
        requests = cpu.ingest(header, holes, notification)
        assert [int(request["psn"]) for request in requests] == [drop_psn], requests
        tb.dut._log.info(
            f"CPU SACK-hole policy emitted RetryEntry "
            f"#{requests[0]['retry_request_id']} for psn={requests[0]['psn']:#x}"
        )

        # 主数据流 B 先发出两个 packet，确认 retry 不在 B 的边界之外插入；
        # 随后暂停 B 的 payload 输入，让 retry 在 packet 边界完成，再恢复 B。
        beats_b = message_beats(payload_b, int(context_b.requestId))
        await tb.feed_message(context_b, payload_b, beats=beats_b[:2])
        await tb.wait_for(
            lambda: any(
                int(commit.requestId) == 2 and int(commit.packetIndex) == 0
                for commit in tb.commits
            ),
            "first B commit",
        )
        await tb.feed_beats(beats_b[2:4])
        await tb.wait_for(
            lambda: any(
                int(commit.requestId) == 2 and int(commit.packetIndex) == 1
                for commit in tb.commits
            ),
            "second B commit",
        )

        retry_bits, _entry = cpu.retry_bits(requests[0])
        await pipe_put(tb.retry_in, tb.clock, retry_bits, cycles=_LONG)

        await tb.wait_for(
            lambda: any(
                int(commit.requestId) == 1
                and int(commit.trafficClass) == 1
                and int(commit.psn) == drop_psn
                for commit in tb.commits
            ),
            "retry TxCommit",
        )
        await tb.wait_for(
            lambda: any(
                int(result["psn"]) == drop_psn and int(result["status"]) == 2
                for result in tb.retx_results
            ),
            "retry SENT result",
        )
        # retry 完成后主数据流继续传输剩余 packet。
        await tb.feed_beats(beats_b[4:])

        await tb.wait_for(lambda: len(tb.cqes) >= 2, "two CQEs")
        await tb.wait_for(
            lambda: any(int(release["psn"]) == drop_psn for release in tb.retx_releases),
            "retx record release for the retried packet",
        )

        assert tb.errors == [], tb.errors
        assert len(tb.dropped) == 1 and int(tb.dropped[0].psn) == drop_psn
        retry_frames = [
            frame for _, frame in tb.delivered
            if frame.request_id == 1 and frame.traffic_class == 1
        ]
        assert len(retry_frames) == 1 and int(retry_frames[0].psn) == drop_psn

        # 主数据流没有被 retry 打断：B 的 4 个 commit 保持顺序，retry commit
        # 严格插在 B 的首尾 commit 之间。
        b_commits = [
            (index, commit) for index, commit in enumerate(tb.commits)
            if int(commit.requestId) == 2
        ]
        retry_commits = [
            (index, commit) for index, commit in enumerate(tb.commits)
            if int(commit.requestId) == 1 and int(commit.trafficClass) == 1
        ]
        assert len(b_commits) == len(packets_b), [c[1] for c in b_commits]
        assert [int(commit.packetIndex) for _, commit in b_commits] == list(
            range(len(packets_b))
        )
        assert len(retry_commits) == 1
        assert b_commits[0][0] < retry_commits[0][0] < b_commits[-1][0], (
            [index for index, _ in tb.commits],
        )
        tb.dut._log.info(
            f"M3 interleave: B commits at {[index for index, _ in b_commits]}, "
            f"retry commit at {retry_commits[0][0]} (trafficClass=RETRY)"
        )

        assert _reassembled(tb.dma_writes, PHYS_BASE + (MSG_A_ADDR - VIRT_BASE), MSG_A_LEN) == payload_a
        assert _reassembled(tb.dma_writes, PHYS_BASE + (MSG_B_ADDR - VIRT_BASE), MSG_B_LEN) == payload_b

        completions = {
            (int(cqe.lastPsn), int(cqe.bytes), int(cqe.success)) for cqe in tb.cqes
        }
        assert (int(packets_a[-1].descriptor.psn), MSG_A_LEN, 1) in completions
        assert (int(packets_b[-1].descriptor.psn), MSG_B_LEN, 1) in completions
        tb.dut._log.info(
            f"both messages completed: A bytes={MSG_A_LEN} lastPsn="
            f"{int(packets_a[-1].descriptor.psn):#x}, B bytes={MSG_B_LEN} "
            f"lastPsn={int(packets_b[-1].descriptor.psn):#x}; DMA payloads verified"
        )

        # 链路恢复后 CPU 再取一次 report：hole 已清零。
        final_header, final_holes, final_notification = await tb.poll_report(
            expected_holes=0
        )
        assert final_holes == []
        assert cpu.ingest(final_header, final_holes, final_notification) == []
    finally:
        tb.stop_background()


@cocotb.test(timeout_time=2_000_000, timeout_unit="ns")
async def test_cpu_driven_retry_keeps_main_dataflow(dut):
    """误码丢包 -> CPU report/retry -> M3 插入重传 -> 两条 message 完成。"""
    await _run_retry_scenario(dut)


async def _run_normal_scenario(dut) -> None:
    tb = E2eTB(dut)
    await reset_dut(dut)
    await tb.initialize()
    payload = payload_bytes(MSG_A_LEN, 3)
    context = make_context(1, INITIAL_PSN, MSG_A_LEN, MSG_A_ADDR)
    packets = packetize(context, payload)

    tb.start_background()
    try:
        await tb.feed_message(context, payload)
        last_psn = int(packets[-1].descriptor.psn)
        await tb.wait_for(
            lambda: any(int(item.triggerPsn) == last_psn for item in tb.feedback),
            "RX SACK for the last packet",
        )
        await tb.wait_for(lambda: len(tb.cqes) >= 1, "CQE")
        assert tb.errors == [], tb.errors
        for _ in range(100):
            await RisingEdge(tb.clock)

        header, holes, notification = await tb.poll_report(expected_holes=0)
        assert holes == []
        cpu = E2eCpu(HOST_SESSION, NIC_SESSION)
        assert cpu.ingest(header, holes, notification) == []
        tb.dut._log.info(
            f"normal path: report generation {header['report_generation']} "
            f"has no holes; no retry result emitted"
        )
        assert not [
            result for result in tb.retx_results
            if int(result["status"]) in (1, 2)
        ]
        assert not [
            frame for _, frame in tb.delivered if frame.traffic_class == 1
        ]
        assert _reassembled(
            tb.dma_writes, PHYS_BASE + (MSG_A_ADDR - VIRT_BASE), MSG_A_LEN
        ) == payload
        assert (int(packets[-1].descriptor.psn), MSG_A_LEN, 1) in {
            (int(cqe.lastPsn), int(cqe.bytes), int(cqe.success)) for cqe in tb.cqes
        }
    finally:
        tb.stop_background()


@cocotb.test(timeout_time=1_000_000, timeout_unit="ns")
async def test_normal_tx_rx_path(dut):
    """无重传时，报文只走 TX -> RX 并正确完成。"""
    await _run_normal_scenario(dut)
