"""m9 RetxStateManager unit tests."""
from __future__ import annotations

import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT.parent / "retx_contract" / "python"))

W = {
    "qp": [("qpn", 24), ("qpEpoch", 16), ("initialPsn", 24), ("enable", 1)],
    "wqe": [("qpn", 24), ("qpEpoch", 16), ("requestId", 16), ("psnBase", 24),
            ("psnCount", 18), ("packetCount", 18), ("pmtu", 3),
            ("messageLength", 25), ("remoteAddr", 64), ("remoteKey", 32),
            ("opcode", 8), ("slotId", 18), ("wireProfile", 2), ("evProfile", 2),
            ("mrcMsn", 16), ("msnValid", 1)],
    "reserve": [("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("requestId", 16),
                ("packetIndex", 18), ("packetCount", 18), ("recordHandle", 32),
                ("replayHandle", 32)],
    "sent": [("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("packetIndex", 18),
             ("recordHandle", 32), ("replayHandle", 32), ("commitToken", 32)],
    "feedback": [("qpn", 24), ("qpEpoch", 16), ("kind", 2), ("ackPsn", 24),
                 ("sackBase", 24), ("sackBitmap", 128), ("sackValidBits", 16),
                 ("nakValid", 1), ("nakCode", 7), ("nakPsn", 24),
                 ("oooCount", 16), ("triggerPsn", 24)],
    "snapreq": [("qpn", 24), ("qpEpoch", 16), ("onDemand", 1), ("requestId", 32)],
    "snaphdr": [("qpn", 24), ("qpEpoch", 16), ("scoreboardGeneration", 32),
                ("ackPsn", 24), ("sackBase", 24), ("outstandingCount", 16),
                ("holeCount", 16), ("sackValidBits", 16), ("nakValid", 1),
                ("nakCode", 7), ("nakPsn", 24), ("oooCount", 16),
                ("bitmap", 128), ("flags", 8), ("entryCount", 8)],
    "hole": [("psn", 24), ("record_handle", 32), ("request_id", 16),
             ("packet_index", 18), ("packet_count", 18), ("message_offset", 25),
             ("payload_length", 13), ("remote_addr", 64), ("remote_key", 32),
             ("opcode", 8), ("pmtu", 3), ("slot_id", 18), ("wire_profile", 2),
             ("ev_profile", 2), ("mrc_msn", 16), ("msn_valid", 1),
             ("is_first", 1), ("is_last", 1), ("reserved0", 26)],
    "admission": [("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
                  ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32),
                  ("expectedRequestId", 16), ("expectedPacketIndex", 18),
                  ("reportGeneration", 32), ("triggerReason", 4), ("retryAttempt", 8)],
    "grant": [("ok", 1), ("reason", 8), ("replayHandle", 32)],
    "admgrant": [("ok", 1), ("status", 4), ("reason", 8), ("recordHandle", 32),
                 ("replayHandle", 32), ("requestId", 16), ("packetIndex", 18),
                 ("packetCount", 18), ("psn", 24), ("opcode", 8), ("pmtu", 3),
                 ("remoteAddr", 64), ("remoteKey", 32), ("messageOffset", 25),
                 ("payloadLength", 13), ("first", 1), ("last", 1),
                 ("wireProfile", 2), ("evProfile", 2), ("mrcMsn", 16)],
    "terminate": [("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32)],
}


def pack(kind_name: str, **values) -> int:
    acc = 0
    for name, width in W[kind_name]:
        v = values.get(name, 0)
        assert 0 <= v < (1 << width), (kind_name, name, v)
        acc = (acc << width) | v
    return acc


def unpack(kind: str, acc: int) -> dict:
    out = {}
    for name, width in reversed(W[kind]):
        out[name] = acc & ((1 << width) - 1)
        acc >>= width
    return out


async def reset(dut):
    dut.RST_N.value = 0
    await RisingEdge(dut.CLK)
    await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    await RisingEdge(dut.CLK)


async def call(dut, name: str, value: int = 0):
    if value:
        getattr(dut, f"{name}_value").value = value
    getattr(dut, f"EN_{name}").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{name}").value = 0
    await RisingEdge(dut.CLK)


async def call_cfg(dut, name: str, idx: int, cfg: int):
    getattr(dut, f"{name}_idx").value = idx
    getattr(dut, f"{name}_cfg").value = cfg
    getattr(dut, f"EN_{name}").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{name}").value = 0
    await RisingEdge(dut.CLK)


async def send(dut, port: str, value: int):
    getattr(dut, f"{port}_enq_value").value = value
    getattr(dut, f"EN_{port}_enq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_enq").value = 0
    await RisingEdge(dut.CLK)


async def recv(dut, port: str) -> int:
    for _ in range(200):
        if int(getattr(dut, f"{port}_notEmpty").value) == 1:
            break
        await RisingEdge(dut.CLK)
    else:
        raise AssertionError(f"{port} never became non-empty")
    value = int(getattr(dut, f"{port}_first").value)
    getattr(dut, f"EN_{port}_deq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_deq").value = 0
    await RisingEdge(dut.CLK)
    return value


@cocotb.test()
async def test_lifecycle_and_snapshot(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    cfg = pack("qp", qpn=0x11, qpEpoch=1, initialPsn=100, enable=1)
    await call_cfg(dut, "configureQpAt", 0, cfg)
    await send(dut, "wqeRegisterIn", pack(
        "wqe", qpn=0x11, qpEpoch=1, requestId=42, psnBase=100, psnCount=4,
        packetCount=4, pmtu=2, messageLength=1024, remoteAddr=0x1122334455667788,
        remoteKey=0xCAFEBABE, opcode=0x0A, slotId=3, msnValid=0))
    resp = unpack("wqe", 0)  # placeholder
    raw = await recv(dut, "wqeRegisterRespOut")
    handle = raw & 0xFFFFFFFF
    dut._log.info(f"wqe raw={raw:#x} handle={handle:#x} ack={int(dut.debugAckQp.value):#x}")
    assert (raw >> 32) & 1 == 1
    await send(dut, "packetReserveIn", pack(
        "reserve", qpn=0x11, qpEpoch=1, psn=100, requestId=42,
        packetIndex=0, packetCount=4, recordHandle=handle))
    graw = await recv(dut, "packetGrantOut")
    grant = unpack("grant", graw)
    dut._log.info(f"grant raw={graw:#x} {grant} ack={int(dut.debugAckQp.value):#x}")
    assert grant["ok"] == 1 and grant["replayHandle"] != 0, grant
    await send(dut, "sentEventIn", pack(
        "sent", qpn=0x11, qpEpoch=1, psn=100, packetIndex=0,
        recordHandle=handle, replayHandle=grant["replayHandle"]))
    await send(dut, "snapshotReqIn", pack(
        "snapreq", qpn=0x11, qpEpoch=1, onDemand=0, requestId=1))
    hdr = unpack("snaphdr", await recv(dut, "snapshotHdrOut"))
    assert hdr["qpn"] == 0x11 and hdr["holeCount"] == 1, hdr
    hole = unpack("hole", await recv(dut, "snapshotEntryOut"))
    assert hole["psn"] == 100 and hole["remote_addr"] == 0x1122334455667788
    await send(dut, "feedbackIn", pack(
        "feedback", qpn=0x11, qpEpoch=1, kind=1, ackPsn=100, sackBase=101,
        sackBitmap=0, sackValidBits=0, nakValid=0))
    rel = unpack("terminate", await recv(dut, "releaseOut"))
    assert rel["psn"] == 100 and rel["recordHandle"] == handle
    await send(dut, "snapshotReqIn", pack(
        "snapreq", qpn=0x11, qpEpoch=1, onDemand=1, requestId=2))
    hdr2 = unpack("snaphdr", await recv(dut, "snapshotHdrOut"))
    assert hdr2["holeCount"] == 0, hdr2


@cocotb.test()
async def test_admission_rejects_stale(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    cfg = pack("qp", qpn=0x22, qpEpoch=2, initialPsn=200, enable=1)
    await call_cfg(dut, "configureQpAt", 1, cfg)
    await send(dut, "wqeRegisterIn", pack(
        "wqe", qpn=0x22, qpEpoch=2, requestId=7, psnBase=200, psnCount=1,
        packetCount=1, pmtu=1, opcode=0x0A))
    raw = await recv(dut, "wqeRegisterRespOut")
    handle = raw & 0xFFFFFFFF
    await send(dut, "packetReserveIn", pack(
        "reserve", qpn=0x22, qpEpoch=2, psn=200, requestId=7,
        packetIndex=0, packetCount=1, recordHandle=handle))
    assert unpack("grant", await recv(dut, "packetGrantOut"))["ok"] == 1
    # PSN is reserved but not SENT yet -> stale.
    await send(dut, "admissionReqIn", pack(
        "admission", retryRequestId=1, hostSessionId=1, nicSessionId=1,
        qpn=0x22, qpEpoch=2, psn=200, recordHandle=handle,
        expectedRequestId=7, expectedPacketIndex=0))
    g = unpack("admgrant", await recv(dut, "admissionGrantOut"))
    assert g["ok"] == 0 and g["status"] == 3, g


@cocotb.test()
async def test_sack_marks_entry(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    cfg = pack("qp", qpn=0x33, qpEpoch=3, initialPsn=300, enable=1)
    await call_cfg(dut, "configureQpAt", 2, cfg)
    await send(dut, "wqeRegisterIn", pack(
        "wqe", qpn=0x33, qpEpoch=3, requestId=9, psnBase=300, psnCount=2,
        packetCount=2, pmtu=1, opcode=0x0A))
    raw = await recv(dut, "wqeRegisterRespOut")
    handle = raw & 0xFFFFFFFF
    for psn, idx in ((300, 0), (301, 1)):
        await send(dut, "packetReserveIn", pack(
            "reserve", qpn=0x33, qpEpoch=3, psn=psn, requestId=9,
            packetIndex=idx, packetCount=2, recordHandle=handle))
        g = unpack("grant", await recv(dut, "packetGrantOut"))
        await send(dut, "sentEventIn", pack(
            "sent", qpn=0x33, qpEpoch=3, psn=psn, packetIndex=idx,
            recordHandle=handle, replayHandle=g["replayHandle"]))
    # SACK PSN 301 while 300 remains a hole.
    await send(dut, "feedbackIn", pack(
        "feedback", qpn=0x33, qpEpoch=3, kind=2, ackPsn=299, sackBase=300,
        sackBitmap=0b10, sackValidBits=2, nakValid=0))
    await send(dut, "snapshotReqIn", pack(
        "snapreq", qpn=0x33, qpEpoch=3, onDemand=0, requestId=3))
    hdr = unpack("snaphdr", await recv(dut, "snapshotHdrOut"))
    assert hdr["holeCount"] == 1, hdr
    assert hdr["bitmap"] & 0b10, hdr
    hole = unpack("hole", await recv(dut, "snapshotEntryOut"))
    assert hole["psn"] == 300, hole
