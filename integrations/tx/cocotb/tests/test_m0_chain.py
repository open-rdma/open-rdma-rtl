"""End-to-end M0 -> M3 chain tests on mkTestM0Chain (short suite).

Every test drives real GDRP submissions plus the four M0 table configuration
servers, then scores DmaEngine requests, DmaMessageDone, TxCommit and the
four channel frame streams against the M0 reference model + Phase-A
packetizer/M3 encapsulator expectations. Lengths and PSNs are NEVER read back
from the DUT; the expectation is derived purely from the configuration and the
submission order.

All local offsets are 4 KiB aligned so every DMA burst starts on a 128-byte
window boundary; the unaligned-window case is covered by the mvp tx unit
suite, and the DmaEngine never has to arbitrate two requests over one
completion window in this chain test.
"""

import random

import cocotb

from m0_chain_bfm import (
    MODEL_CLOCK_PS,
    M0ChainScenarioMetrics,
    M0ChainTB,
    M0Submission,
    configure_mr,
    configure_pte,
    configure_qp,
    configure_slot,
    run_m0_chain_scenario,
)
from m0_chain_model import (
    M0RefModel,
    MrEntry,
    PayloadSlot,
    PteEntry,
    QpEntry,
    make_local_lkey,
)
from openrdma_flow_tb.tx.model.m3 import MacIpConfig

CFG = MacIpConfig(
    srcMac=0x020000000001,
    dstMac=0x020000000002,
    srcIp=0x0A000001,
    dstIp=0x0A000002,
)

VIRT_BASE = 0x0000_0000_1000_0000
REMOTE_BASE = 0x0000_2000_0000_0000
MEM_BASE = 0x0000_0080_0000_0000
REMOTE_KEY = 0x5566_7788
KEY_PART = 7
MR_INDEX = 0
PAGE = 4096

PMTU_LIMITS = {0: (256, 28), 1: (512, 28), 2: (1024, 28), 3: (2048, 28), 4: (4096, 28)}


async def bring_up(
    tb: M0ChainTB,
    model: M0RefModel,
    *,
    qps: dict[int, int],
    slots: dict[int, tuple[int, int]],
    psn_starts: dict[int, int] | None = None,
) -> None:
    """Configure one 4 KiB-page MR (pgtOffset 0) plus the given QPs and slots."""
    page_bytes = 1 << 12
    span = max(offset + max_len for offset, max_len in slots.values())
    pte_count = (span + page_bytes - 1) // page_bytes
    assert pte_count <= 128
    mr = MrEntry(
        valid=1,
        keyPart=KEY_PART,
        allowLocalRead=1,
        baseVa=VIRT_BASE,
        length=span,
        pgtOffset=0,
        pageShift=12,
    )
    await configure_mr(tb, model, MR_INDEX, mr)
    for index in range(pte_count):
        pte = PteEntry(valid=1, physicalPageBase=MEM_BASE + index * page_bytes)
        await configure_pte(tb, model, index, pte)
    for qpn, pmtu in qps.items():
        initial = (psn_starts or {}).get(qpn, 0)
        qp = QpEntry(valid=1, pmtu=pmtu, initialPsn=initial)
        await configure_qp(tb, model, qpn, qp)
    for slot_id, (offset, max_len) in slots.items():
        assert offset % page_bytes == 0
        slot = PayloadSlot(
            valid=1,
            allowWriteRelaxed=1,
            localLkey=make_local_lkey(mr_index=MR_INDEX, key_part=KEY_PART),
            localOffset=offset,
            remoteBase=REMOTE_BASE + slot_id * 0x1_0000_0000,
            maxLen=max_len,
            remoteKey=REMOTE_KEY,
        )
        await configure_slot(tb, model, slot_id, slot)


def specs(
    qpn: int,
    slot_id: int,
    lengths: list[int],
    *,
    debug_seed: int = 0,
) -> list[M0Submission]:
    return [
        M0Submission(
            qpn=qpn,
            slot_id=slot_id,
            length=length,
            debug_seq=(debug_seed + index) & 0xF,
        )
        for index, length in enumerate(lengths)
    ]


@cocotb.test(timeout_time=3_000_000, timeout_unit="ns")
async def header_aware_psn_boundaries_pmtu256_and_512(dut):
    """Messages straddling the first/continuation packet payload limits.

    RoCEv2 first packets carry BTH+RETH (28 B overhead), continuations BTH
    (12 B). At pmtu 256 the limits are 228/244 bytes; at pmtu 512 they are
    484/500. The M0 PSN grant must match the packetizer's own count exactly
    (the glue cross-checks this in RTL), and every frame on the wire must
    carry the resulting PSNs, RETH address and RKEY.
    """
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 0, 1: 1},
        slots={0: (0x0, 0x2000), 1: (0x1000, 0x2000)},
        psn_starts={0: 0x100, 1: 0x800000},
    )

    messages = []
    for index, (pmtu256_len, pmtu512_len) in enumerate(
        zip(
            [1, 227, 228, 229, 230, 471, 472, 473, 700],
            [483, 484, 485, 984, 985, 1500],
            strict=False,
        )
    ):
        messages.append(M0Submission(0, 0, pmtu256_len, debug_seq=(2 * index) & 0xF))
        messages.append(M0Submission(1, 1, pmtu512_len, debug_seq=(2 * index + 1) & 0xF))
    messages.append(M0Submission(0, 0, 256, debug_seq=0xF))

    await run_m0_chain_scenario(tb, model, messages, CFG)


@cocotb.test(timeout_time=3_000_000, timeout_unit="ns")
async def physical_page_boundaries_and_multi_chunk_messages(dut):
    """Messages spanning physical pages and 4 KiB boundary splits.

    Lengths 4095/4096/4097 force a page-crossing burst pattern; larger
    lengths exercise the per-message request stream through the
    synchronizer and DmaEngine's out-of-order completion reassembly.
    """
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 2, 1: 3},
        slots={0: (0x0, 0x8000), 1: (0x1000, 0x8000)},
        psn_starts={0: 0x1000, 1: 0xABCDEF},
    )

    messages = specs(0, 0, [1024, 3071, 4095, 4096, 4097, 4196, 8192, 0x7FFF])
    messages += specs(
        1, 1, [1, 1500, 2020, 2021, 3000, 4000], debug_seed=3
    )
    await run_m0_chain_scenario(tb, model, messages, CFG)


@cocotb.test(timeout_time=4_000_000, timeout_unit="ns")
async def interleaved_multi_qp_independent_psn_with_wrap(dut):
    """Four QPs with independent PSN state, interleaved submissions.

    qpn0's initial PSN is near the 24-bit wrap so the granted window crosses
    0xFFFFFF; the frame BTH PSN must still match the packetizer expectation.
    """
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 0, 1: 1, 2: 2, 3: 4},
        slots={
            0: (0x0, 0x4000),
            1: (0x1000, 0x4000),
            2: (0x2000, 0x4000),
            3: (0x3000, 0x4000),
        },
        psn_starts={0: 0xFFFFFE, 1: 0x123400, 2: 0x0, 3: 0x7FFFFF},
    )

    messages = []
    base = {0: 500, 1: 484, 2: 996, 3: 4068}  # per-qpn message lengths
    order = [0, 3, 1, 2, 0, 1, 2, 3, 0, 2, 1, 3]
    for index, qpn in enumerate(order):
        length = base[qpn] + (index % 3)
        messages.append(
            M0Submission(qpn, qpn, length, debug_seq=(7 * index) & 0xF)
        )
    # qpn0 wrap: 500 bytes at pmtu 256 = 3 PSNs starting at 0xFFFFFE.
    messages.append(M0Submission(0, 0, 500, debug_seq=0))

    await run_m0_chain_scenario(tb, model, messages, CFG)


async def _channel_mask_case(dut, mask: int) -> None:
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 0},
        slots={0: (0x0, 0x4000)},
        psn_starts={0: 0x555555},
    )
    messages = specs(0, 0, [100, 1100, 2000, 300, 1500, 2500], debug_seed=1)
    await run_m0_chain_scenario(tb, model, messages, CFG, channel_enable=mask)


@cocotb.test(timeout_time=2_000_000, timeout_unit="ns")
async def channel_enable_mask_0101(dut):
    await _channel_mask_case(dut, 0b0101)


@cocotb.test(timeout_time=2_000_000, timeout_unit="ns")
async def channel_enable_mask_1010(dut):
    await _channel_mask_case(dut, 0b1010)


@cocotb.test(timeout_time=5_000_000, timeout_unit="ns")
async def randomized_fixed_seed_m0_to_m3(dut):
    """Deterministic pseudo-random submissions across four QPs/slots."""
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 0, 1: 1, 2: 2, 3: 3},
        slots={
            0: (0x0, 0x8000),
            1: (0x1000, 0x8000),
            2: (0x2000, 0x8000),
            3: (0x3000, 0x8000),
        },
        psn_starts={0: 0x100, 1: 0x123400, 2: 0xFFFF00, 3: 0x800000},
    )
    rng = random.Random(20260903)
    messages = []
    for index in range(24):
        qpn = rng.randrange(4)
        pmtu = {0: 0, 1: 1, 2: 2, 3: 3}[qpn]
        first_limit = {0: 228, 1: 484, 2: 996, 3: 2020}[pmtu]
        continuation_limit = {0: 244, 1: 500, 2: 1012, 3: 2036}[pmtu]
        if rng.random() < 0.4:
            length = rng.choice(
                [
                    first_limit - 1,
                    first_limit,
                    first_limit + 1,
                    first_limit + continuation_limit,
                    first_limit + continuation_limit + 1,
                ]
            )
        else:
            length = rng.randint(1, 0x8000)
        messages.append(
            M0Submission(qpn, qpn, length, debug_seq=(3 * index) & 0xF)
        )
    await run_m0_chain_scenario(tb, model, messages, CFG)


def _steady_timestamp_gbps(
    timestamps_ps: list[int],
    payload_bytes: int = 1024,
    warmup_events: int = 16,
    drain_events: int = 16,
) -> float:
    ordered = sorted(timestamps_ps)
    end = len(ordered) - drain_events - 1
    assert end > warmup_events
    duration_ps = ordered[end] - ordered[warmup_events]
    assert duration_ps > 0
    return (end - warmup_events) * payload_bytes * 8 * 1000 / duration_ps


def _cycle_gap_summary(timestamps_ps: list[int]) -> dict[int, int]:
    ordered = sorted(timestamps_ps)
    result: dict[int, int] = {}
    for first, second in zip(ordered, ordered[1:]):
        gap = (second - first) // MODEL_CLOCK_PS
        result[gap] = result.get(gap, 0) + 1
    return result


def _full_window_gbps(metrics: M0ChainScenarioMetrics) -> float:
    """与归档 E04 边界一致：首个 submission 接受到最后 frame EOF。"""
    payload = sum(metrics.frame_payload_bytes)
    duration_ps = max(metrics.frame_eof_ps) - min(metrics.submission_accept_ps)
    assert duration_ps > 0
    return payload * 8 * 1000 / duration_ps


def _steady_frame_gbps(
    metrics: M0ChainScenarioMetrics,
    warmup_frames: int = 16,
    drain_frames: int = 16,
) -> float:
    events = sorted(zip(
        metrics.frame_eof_ps, metrics.frame_payload_bytes, strict=True
    ))
    end = len(events) - drain_frames - 1
    assert end > warmup_frames
    duration_ps = events[end][0] - events[warmup_frames][0]
    transferred = sum(
        payload_bytes
        for _, payload_bytes in events[warmup_frames + 1 : end + 1]
    )
    assert duration_ps > 0
    return transferred * 8 * 1000 / duration_ps


@cocotb.test(timeout_time=20_000_000, timeout_unit="ns")
async def sustained_m0_to_m3_rate_hides_bounded_dma_latency(dut):
    """四通道 TX 应达到 400 Gb/s，并用 outstanding request 隐藏短 latency。"""
    tb = M0ChainTB(dut)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 4, 1: 4, 2: 4, 3: 4},
        slots={
            0: (0x0, 0x4000),
            1: (0x1000, 0x4000),
            2: (0x2000, 0x4000),
            3: (0x3000, 0x4000),
        },
    )

    for case_index, (latency_cycles, minimum_gbps) in enumerate(
        ((0, 400.0), (20, 400.0), (100, 240.0))
    ):
        messages = [
            M0Submission(
                qpn=index & 3,
                slot_id=index & 3,
                length=1024,
                debug_seq=(case_index + index) & 0xF,
            )
            for index in range(128)
        ]
        metrics = M0ChainScenarioMetrics()
        await run_m0_chain_scenario(
            tb,
            model,
            messages,
            CFG,
            completion_order="in_order",
            request_latency_cycles=latency_cycles,
            prime_outstanding=8,
            metrics=metrics,
            timeout_ns=10_000_000,
        )
        rate = _steady_frame_gbps(metrics)
        submission_rate = _steady_timestamp_gbps(
            metrics.submission_accept_ps
        )
        dma_request_rate = _steady_timestamp_gbps(
            metrics.dma_request_issue_ps
        )
        commit_rate = _steady_timestamp_gbps(metrics.tx_commit_ps)
        dut._log.info(
            "M0→M3 稳态：latency=%d cycles，submission=%.3f，"
            "DMA request=%.3f，TxCommit=%.3f，frame EOF=%.3f Gb/s，"
            "full-window=%.3f Gb/s",
            latency_cycles,
            submission_rate,
            dma_request_rate,
            commit_rate,
            rate,
            _full_window_gbps(metrics),
        )
        dut._log.info(
            "周期间隔直方图：DMA request=%s，TxCommit=%s，frame EOF=%s",
            _cycle_gap_summary(metrics.dma_request_issue_ps),
            _cycle_gap_summary(metrics.tx_commit_ps),
            _cycle_gap_summary(metrics.frame_eof_ps),
        )
        assert rate >= minimum_gbps, (
            f"latency={latency_cycles}：{rate:.3f} Gb/s < {minimum_gbps:.3f} Gb/s"
        )

    # 归档评测的串行 DMA 模型在同一 RTL 上的基线，用于区分“模型效应”和 RTL 修改。
    # 使用与归档 32-message stress 行相同的批次规模。
    for serial_latency in (0, 20, 100):
        serial_metrics = M0ChainScenarioMetrics()
        serial_messages = [
            M0Submission(
                qpn=index & 3, slot_id=index & 3, length=1024, debug_seq=index & 0xF
            )
            for index in range(32)
        ]
        await run_m0_chain_scenario(
            tb,
            model,
            serial_messages,
            CFG,
            completion_order="in_order",
            request_latency_cycles=serial_latency,
            serial_dma=True,
            metrics=serial_metrics,
            timeout_ns=10_000_000,
        )
        dut._log.info(
            "串行 DMA 基线：latency=%d cycles，frame EOF=%.3f Gb/s，"
            "full-window=%.3f Gb/s",
            serial_latency,
            _steady_frame_gbps(
                serial_metrics, warmup_frames=4, drain_frames=4
            ),
            _full_window_gbps(serial_metrics),
        )

    # 其它消息尺寸只记录数据正确的稳态速率，不设 400 Gb/s 门限。
    for size in (64, 4096, 16384):
        sweep_metrics = M0ChainScenarioMetrics()
        sweep_messages = [
            M0Submission(qpn=index & 3, slot_id=index & 3, length=size, debug_seq=index & 0xF)
            for index in range(64)
        ]
        await run_m0_chain_scenario(
            tb,
            model,
            sweep_messages,
            CFG,
            completion_order="in_order",
            prime_outstanding=8,
            metrics=sweep_metrics,
            timeout_ns=10_000_000,
        )
        dut._log.info(
            "消息尺寸 %d B：frame EOF=%.3f Gb/s",
            size,
            _steady_frame_gbps(
                sweep_metrics,
                warmup_frames=8,
                drain_frames=8,
            ),
        )
