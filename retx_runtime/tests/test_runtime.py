"""retx_runtime reference tests (stdlib unittest)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT.parent / "retx_contract" / "python"))

from retx_codec import encode  # noqa: E402
from runtime import Runtime, TIMEOUT_NS  # noqa: E402


def report(**kw):
    values = dict(
        version=1, flags=3, byte_length=104, qpn=0, qp_epoch=1,
        sack_valid_bits=4, report_generation=1, scoreboard_generation=7,
        nic_session_id=0x0BAD, ack_psn=100, sack_base=101,
        outstanding_base=101, nak_psn=0, outstanding_count=4, ooo_count=2,
        hole_count=2, hole_entries_included=2, nak_valid_and_code=0,
        sack_bitmap=0b1010)
    values.update(kw)
    values["byte_length"] = 64 + 40 * values["hole_entries_included"]
    return values, encode("ReportHeader", values)


def notification(values, byte_length=None):
    return dict(version=1, qpn=values["qpn"], qp_epoch=values["qp_epoch"],
                report_generation=values["report_generation"],
                report_byte_length=byte_length or values["byte_length"],
                nic_session_id=values["nic_session_id"])


def hole(psn, packet_index=0):
    return dict(psn=psn, record_handle=7, request_id=42,
                packet_index=packet_index, packet_count=4,
                message_offset=packet_index * 256, payload_length=256,
                remote_addr=0x1122, remote_key=0xCAFE, opcode=0x0A,
                pmtu=2, slot_id=1, wire_profile=0, ev_profile=0,
                mrc_msn=0, msn_valid=0, is_first=0, is_last=0)


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(host_session_id=0x1234, nic_session_id=0x0BAD)

    def ingest(self, values, data):
        for psn in (101, 103):
            self.rt.attach_hole(0, values["report_generation"], hole(psn))
        self.assertTrue(self.rt.ingest_notification(notification(values), data))

    def test_sack_hole_threshold(self):
        values, data = report(sack_bitmap=0b1010)
        self.ingest(values, data)
        self.assertEqual(self.rt.decisions(0), [])
        values, data = report(report_generation=2, sack_bitmap=0b1110)
        self.ingest(values, data)
        decisions = self.rt.decisions(0)
        self.assertEqual([d["psn"] for d in decisions], [101])
        self.assertEqual(decisions[0]["trigger_reason"], 2)

    def test_nak_sequence_gap(self):
        values, data = report(nak_valid_and_code=0x81, nak_psn=101,
                              report_generation=3)
        self.ingest(values, data)
        decisions = self.rt.decisions(0)
        self.assertEqual([(d["psn"], d["trigger_reason"]) for d in decisions],
                         [(101, 1)])

    def test_timeout_emits_request_and_dedups(self):
        values, data = report(report_generation=4, sack_bitmap=0)
        self.ingest(values, data)
        self.rt.now_ns += TIMEOUT_NS
        first = self.rt.service()
        self.assertEqual(len(first), 2)
        self.assertEqual([r["psn"] for r in first], [101, 103])
        self.rt.now_ns += 1
        self.assertEqual(self.rt.service(), [])

    def test_retry_later_backoff_and_limit(self):
        values, data = report(report_generation=5, sack_bitmap=0)
        self.ingest(values, data)
        self.rt.now_ns += TIMEOUT_NS
        req = self.rt.service()[0]
        result = dict(host_session_id=0x1234, nic_session_id=0x0BAD,
                      retry_request_id=req["retry_request_id"], status=4)
        self.rt.on_result(result)
        pending = next(iter(self.rt.pending.values()))
        self.assertEqual(pending.attempt, 1)
        self.assertEqual(pending.state, "pending")
        self.assertGreater(pending.next_attempt_at, self.rt.now_ns)

    def test_generation_gap_triggers_refresh(self):
        values, data = report(report_generation=1)
        self.ingest(values, data)
        values, data = report(report_generation=3)
        self.rt.attach_hole(0, 3, hole(101))
        self.assertTrue(self.rt.ingest_notification(notification(values), data))
        self.assertTrue(self.rt.caches[0].needs_refresh)
        self.rt.service()
        self.assertTrue(self.rt.ondemand_requests)


if __name__ == "__main__":
    unittest.main()
