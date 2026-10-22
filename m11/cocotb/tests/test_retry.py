"""m11 RetxRetryEngine tests."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

RETRY = [("retry_request_id", 32), ("host_session_id", 32), ("qpn", 24),
         ("trigger_reason", 8), ("qp_epoch", 16), ("retry_attempt", 8),
         ("flags", 8), ("psn", 24), ("reserved0", 8), ("record_handle", 32),
         ("report_generation", 32), ("expected_request_id", 16),
         ("expected_packet_index", 24), ("reserved1", 24), ("entry_crc32", 32)]
ADMREQ = [("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
          ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32),
          ("expectedRequestId", 16), ("expectedPacketIndex", 18),
          ("reportGeneration", 32), ("triggerReason", 4), ("retryAttempt", 8)]
GRANT = [("ok", 1), ("status", 4), ("reason", 8), ("recordHandle", 32),
         ("replayHandle", 32), ("requestId", 16), ("packetIndex", 18),
         ("packetCount", 18), ("psn", 24), ("opcode", 8), ("pmtu", 3),
         ("remoteAddr", 64), ("remoteKey", 32), ("messageOffset", 25),
         ("payloadLength", 13), ("first", 1), ("last", 1),
         ("wireProfile", 2), ("evProfile", 2), ("mrcMsn", 16)]
FETCH = [("fetchId", 16), ("replayHandle", 32), ("offset", 25),
         ("length", 13), ("token", 32)]
BEAT = [("fetchId", 16), ("data", 1024), ("keep", 128), ("sop", 1),
        ("eop", 1), ("valid", 1), ("last", 1)]
M3DESC = [("qpn", 24), ("qpEpoch", 16), ("requestId", 16), ("psn", 24),
          ("packetIndex", 18), ("packetCount", 18), ("pmtu", 3), ("opcode", 8),
          ("remoteAddr", 64), ("remoteKey", 32), ("messageOffset", 25),
          ("payloadLength", 13), ("first", 1), ("last", 1), ("wireProfile", 2),
          ("evProfile", 2), ("mrcMsn", 16)]
M3BEAT = [("requestId", 16), ("psn", 24), ("data", 1024), ("keep", 128),
          ("sop", 1), ("eop", 1)]
RESULT = [("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
          ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("status", 8),
          ("reason", 8), ("fetchId", 16), ("reportGeneration", 32),
          ("egressSequence", 32), ("resultSequence", 8)]


def pack(fields, values):
    acc = 0
    for name, width in fields:
        acc = (acc << width) | (values.get(name, 0) & ((1 << width) - 1))
    return acc


def unpack(fields, acc):
    out = {}
    for name, width in reversed(fields):
        out[name] = acc & ((1 << width) - 1)
        acc >>= width
    return out


async def reset(dut):
    dut.RST_N.value = 0
    await RisingEdge(dut.CLK)
    await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    await RisingEdge(dut.CLK)


async def send(dut, port, value):
    getattr(dut, f"{port}_enq_value").value = value
    getattr(dut, f"EN_{port}_enq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_enq").value = 0
    await RisingEdge(dut.CLK)


async def recv(dut, port):
    for _ in range(200):
        if int(getattr(dut, f"{port}_notEmpty").value) == 1:
            break
        await RisingEdge(dut.CLK)
    else:
        raise AssertionError(f"{port} not ready")
    value = int(getattr(dut, f"{port}_first").value)
    getattr(dut, f"EN_{port}_deq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_deq").value = 0
    await RisingEdge(dut.CLK)
    return value


def retry_entry(**kw):
    base = dict(retry_request_id=5, host_session_id=0x1234, qpn=0x11,
                trigger_reason=2, qp_epoch=1, retry_attempt=0, flags=0,
                psn=101, record_handle=7, report_generation=11,
                expected_request_id=42, expected_packet_index=1)
    base.update(kw)
    return pack(RETRY, base)


@cocotb.test()
async def test_admit_fetch_sent(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    dut.configure_hostSession.value = 0x1234
    dut.configure_nicSession.value = 0x0BAD
    dut.EN_configure.value = 1
    await RisingEdge(dut.CLK)
    dut.EN_configure.value = 0
    await RisingEdge(dut.CLK)

    await send(dut, "retryIn", retry_entry())
    adm = unpack(ADMREQ, await recv(dut, "admissionReqOut"))
    assert adm["qpn"] == 0x11 and adm["psn"] == 101 and adm["nicSessionId"] == 0x0BAD
    g = pack(GRANT, dict(ok=1, status=1, replayHandle=0x99, recordHandle=7, requestId=42,
                         packetIndex=1, packetCount=2, psn=101, opcode=0x0A,
                         pmtu=1, remoteAddr=0x1122, remoteKey=0xCAFE,
                         messageOffset=64, payloadLength=32, first=0, last=0))
    await send(dut, "admissionGrantIn", g)
    r0 = unpack(RESULT, await recv(dut, "resultOut"))
    assert r0["status"] == 1 and r0["resultSequence"] == 0, r0
    fetch = unpack(FETCH, await recv(dut, "fetchReqOut"))
    assert fetch["replayHandle"] == 0x99 and fetch["token"] == 7
    beat = pack(BEAT, dict(fetchId=fetch["fetchId"], data=0xAA, keep=(1 << 32) - 1,
                           sop=1, eop=1, valid=1, last=1))
    await send(dut, "fetchBeatIn", beat)
    desc = unpack(M3DESC, await recv(dut, "m3DescOut"))
    assert desc["qpn"] == 0x11 and desc["psn"] == 101 and desc["remoteAddr"] == 0x1122
    mb = unpack(M3BEAT, await recv(dut, "m3BeatOut"))
    assert mb["sop"] == 1 and mb["eop"] == 1 and mb["data"] == 0xAA
    r1 = unpack(RESULT, await recv(dut, "resultOut"))
    assert r1["status"] == 2 and r1["resultSequence"] == 1, r1


@cocotb.test()
async def test_admission_denied_is_terminal(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    await send(dut, "retryIn", retry_entry(qpn=0x22, psn=200))
    await recv(dut, "admissionReqOut")
    await send(dut, "admissionGrantIn", pack(GRANT, dict(ok=0, status=3, reason=1)))
    r = unpack(RESULT, await recv(dut, "resultOut"))
    assert r["status"] == 3 and r["reason"] == 1 and r["resultSequence"] == 0
    assert int(dut.busy.value) == 0
