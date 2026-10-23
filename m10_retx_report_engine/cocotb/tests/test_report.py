"""m10 RetxReportEngine tests."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from openrdma_flow_tb.retx.bfm import recv, reset, send
from openrdma_flow_tb.retx.layouts import pack, unpack

from openrdma_flow.retx.codec import decode, encode, validate_report  # noqa: E402

W = {
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
    "notif": [("txnId", 32), ("ringSlot", 8), ("reportByteLength", 16),
              ("qpn", 24), ("qpEpoch", 16), ("reportGeneration", 32),
              ("nicSessionId", 32), ("hostSessionId", 32)],
    "ondemand": [("requestId", 32), ("qpn", 24), ("qpEpoch", 16),
                 ("hostSessionId", 32), ("nicSessionId", 32),
                 ("lastSeenReportGeneration", 32), ("reason", 8)],
}
REPORT_FIELDS = [("version", 8), ("flags", 8), ("byte_length", 16), ("qpn", 24),
                 ("reserved0", 8), ("qp_epoch", 16), ("sack_valid_bits", 16),
                 ("report_generation", 32), ("scoreboard_generation", 32),
                 ("nic_session_id", 32), ("ack_psn", 24), ("sack_base", 24),
                 ("outstanding_base", 24), ("nak_psn", 24),
                 ("outstanding_count", 16), ("ooo_count", 16), ("hole_count", 16),
                 ("hole_entries_included", 8), ("nak_valid_and_code", 8),
                 ("sack_bitmap", 128), ("crc32", 32)]












@cocotb.test()
async def test_report_assembly(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    dut.configure_nicSession.value = 0x0BADF00D
    dut.configure_hostSession.value = 0x1234
    dut.EN_configure.value = 1
    await RisingEdge(dut.CLK)
    dut.EN_configure.value = 0
    await RisingEdge(dut.CLK)

    hdr = pack(W["snaphdr"], dict(
        qpn=0x44, qpEpoch=1, scoreboardGeneration=5, ackPsn=10,
        sackBase=11, outstandingCount=2, holeCount=1, sackValidBits=2,
        nakValid=0, oooCount=1, bitmap=0, entryCount=1))
    await send(dut, "snapshotIn", hdr)
    hole = pack(W["hole"], dict(
        psn=11, record_handle=7, request_id=42, packet_index=1,
        packet_count=2, message_offset=64, payload_length=32,
        remote_addr=0x1122334455667788, remote_key=0xCAFEBABE,
        opcode=0x0A, pmtu=1, slot_id=2))
    await send(dut, "entryIn", hole)
    raw = await recv(dut, "reportHeaderOut")
    rh = unpack(REPORT_FIELDS, raw)
    assert rh["version"] == 1 and rh["qpn"] == 0x44
    assert rh["byte_length"] == 104 and rh["hole_count"] == 1
    assert rh["report_generation"] == 1
    assert rh["nic_session_id"] == 0x0BADF00D
    # Encode via the ABI codec and validate cross-language layout.
    values = {k: v for k, v in rh.items()}
    values["crc32"] = 0
    data = encode("ReportHeader", dict(validate_report(values), crc32=0))
    assert decode("ReportHeader", data)["qpn"] == 0x44
    out_hole = unpack(W["hole"], await recv(dut, "reportEntryOut"))
    assert out_hole["psn"] == 11 and out_hole["record_handle"] == 7
    notif = unpack(W["notif"], await recv(dut, "notificationOut"))
    assert notif["qpn"] == 0x44 and notif["reportGeneration"] == 1
    assert notif["reportByteLength"] == 104


@cocotb.test()
async def test_on_demand_echo(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    req = pack(W["ondemand"], dict(requestId=3, qpn=0x55, qp_epoch=2,
                                   host_session_id=1, nic_session_id=2,
                                   last_seen_report_generation=4, reason=2))
    await send(dut, "onDemandIn", req)
    echo = unpack(W["ondemand"], await recv(dut, "onDemandOut"))
    assert echo["requestId"] == 3 and echo["qpn"] == 0x55
