"""Retx seam: M9 facts -> M10 Report -> M11 abstract retry outputs (no runtime/M3 loop)."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from openrdma_flow_tb.retx.bfm import call_config as call_cfg, recv, reset, send
from openrdma_flow_tb.retx.layouts import pack, unpack

from openrdma_flow.retx.codec import decode, validate_report  # noqa: E402

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
    "hole": [("psn", 24), ("record_handle", 32), ("request_id", 16),
             ("packet_index", 18), ("packet_count", 18), ("message_offset", 25),
             ("payload_length", 13), ("remote_addr", 64), ("remote_key", 32),
             ("opcode", 8), ("pmtu", 3), ("slot_id", 18), ("wire_profile", 2),
             ("ev_profile", 2), ("mrc_msn", 16), ("msn_valid", 1),
             ("is_first", 1), ("is_last", 1), ("reserved0", 26)],
    "retry": [("retry_request_id", 32), ("host_session_id", 32), ("qpn", 24),
              ("trigger_reason", 8), ("qp_epoch", 16), ("retry_attempt", 8),
              ("flags", 8), ("psn", 24), ("reserved0", 8), ("record_handle", 32),
              ("report_generation", 32), ("expected_request_id", 16),
              ("expected_packet_index", 24), ("reserved1", 24), ("entry_crc32", 32)],
    "grant": [("ok", 1), ("reason", 8), ("replayHandle", 32)],
    "fetch": [("fetchId", 16), ("replayHandle", 32), ("offset", 25),
              ("length", 13), ("token", 32)],
    "beat": [("fetchId", 16), ("data", 1024), ("keep", 128), ("sop", 1),
             ("eop", 1), ("valid", 1), ("last", 1)],
    "m3desc": [("qpn", 24), ("qpEpoch", 16), ("requestId", 16), ("psn", 24),
               ("packetIndex", 18), ("packetCount", 18), ("pmtu", 3), ("opcode", 8),
               ("remoteAddr", 64), ("remoteKey", 32), ("messageOffset", 25),
               ("payloadLength", 13), ("first", 1), ("last", 1), ("wireProfile", 2),
               ("evProfile", 2), ("mrcMsn", 16)],
    "result": [("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
               ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("status", 8),
               ("reason", 8), ("fetchId", 16), ("reportGeneration", 32),
               ("egressSequence", 32), ("resultSequence", 8)],
}














@cocotb.test()
async def test_joint_recovery_loop(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    dut.configure_hostSession.value = 0x1234
    dut.configure_nicSession.value = 0x0BAD
    dut.EN_configure.value = 1
    await RisingEdge(dut.CLK)
    dut.EN_configure.value = 0
    await RisingEdge(dut.CLK)
    await call_cfg(dut, "configureQpAt", 0,
                   pack(W["qp"], dict(qpn=0, qpEpoch=1, initialPsn=100, enable=1)))

    await send(dut, "wqeRegisterIn", pack(W["wqe"], dict(
        qpn=0, qpEpoch=1, requestId=42, psnBase=100, psnCount=4,
        packetCount=4, pmtu=2, messageLength=1024, remoteAddr=0x1122,
        remoteKey=0xCAFE, opcode=0x0A, slotId=1)))
    handle = (await recv(dut, "wqeRegisterRespOut")) & 0xFFFFFFFF

    replays = []
    for idx in range(4):
        await send(dut, "packetReserveIn", pack(W["reserve"], dict(
            qpn=0, qpEpoch=1, psn=100 + idx, requestId=42,
            packetIndex=idx, packetCount=4, recordHandle=handle)))
        g = unpack(W["grant"], await recv(dut, "packetGrantOut"))
        assert g["ok"] == 1
        replays.append(g["replayHandle"])
        await send(dut, "sentEventIn", pack(W["sent"], dict(
            qpn=0, qpEpoch=1, psn=100 + idx, packetIndex=idx,
            recordHandle=handle, replayHandle=g["replayHandle"])))

    # ACK 100, SACK 102; 101 and 103 are holes.
    await send(dut, "feedbackIn", pack(W["feedback"], dict(
        qpn=0, qpEpoch=1, kind=2, ackPsn=100, sackBase=101,
        sackBitmap=0b010, sackValidBits=3, nakValid=0, triggerPsn=102)))
    await send(dut, "snapshotReqIn", pack(W["snapreq"], dict(
        qpn=0, qpEpoch=1, onDemand=0, requestId=1)))

    raw_hdr = await recv(dut, "reportHeaderOut")
    REPORT_FIELDS = [("version", 8), ("flags", 8), ("byte_length", 16),
                     ("qpn", 24), ("reserved0", 8), ("qp_epoch", 16),
                     ("sack_valid_bits", 16), ("report_generation", 32),
                     ("scoreboard_generation", 32), ("nic_session_id", 32),
                     ("ack_psn", 24), ("sack_base", 24), ("outstanding_base", 24),
                     ("nak_psn", 24), ("outstanding_count", 16),
                     ("ooo_count", 16), ("hole_count", 16),
                     ("hole_entries_included", 8), ("nak_valid_and_code", 8),
                     ("sack_bitmap", 128), ("crc32", 32)]
    header = unpack(REPORT_FIELDS, raw_hdr)
    header["byte_length"] = 64 + 40 * header["hole_entries_included"]
    header = validate_report(header)
    assert header["qpn"] == 0 and header["hole_count"] == 2, header
    holes = [unpack(W["hole"], await recv(dut, "reportEntryOut")) for _ in range(2)]
    assert [h["psn"] for h in holes] == [101, 103], holes
    notif = await recv(dut, "notificationOut")
    assert notif != 0

    target = holes[0]
    await send(dut, "retryIn", pack(W["retry"], dict(
        retry_request_id=1, host_session_id=0x1234, qpn=0, trigger_reason=2,
        qp_epoch=1, retry_attempt=0, psn=target["psn"],
        record_handle=target["record_handle"],
        report_generation=header["report_generation"],
        expected_request_id=target["request_id"],
        expected_packet_index=target["packet_index"])))
    r0 = unpack(W["result"], await recv(dut, "resultOut"))
    assert r0["status"] == 1 and r0["resultSequence"] == 0, r0
    fetch = unpack(W["fetch"], await recv(dut, "fetchReqOut"))
    assert fetch["token"] == handle
    await send(dut, "fetchBeatIn", pack(W["beat"], dict(
        fetchId=fetch["fetchId"], data=0xAA, keep=(1 << 64) - 1,
        sop=1, eop=1, valid=1, last=1)))
    desc = unpack(W["m3desc"], await recv(dut, "m3DescOut"))
    assert desc["psn"] == target["psn"]
    m3raw = await recv(dut, "m3BeatOut")
    assert (m3raw >> 1) & 1 == 1  # MSB-first: eop bit0, sop bit1
    r1 = unpack(W["result"], await recv(dut, "resultOut"))
    assert r1["status"] == 2 and r1["resultSequence"] == 1, r1
