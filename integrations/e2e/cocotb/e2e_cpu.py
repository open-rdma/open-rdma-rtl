"""CPU-side retx controller used by the E2E cocotb test.

The NIC exposes the retx host ABI (notification + report header/entries,
retry requests, results).  This class plays the host CPU:

    notification + report body + hole entries
        -> ingest_report()            (validate ABI, cache scoreboard)
        -> plan_retries()             (SACK-hole policy)
        -> RetryEntry host bytes      (back into the NIC)

It deliberately uses the production ``openrdma_flow.retx.codec`` and the
reference ``retx_runtime`` policy instead of re-implementing either.
"""

from __future__ import annotations

from typing import Any

from openrdma_flow.retx.codec import decode, encode

from e2e_layouts import pack_named
from runtime import Runtime


class E2eCpu:
    def __init__(self, host_session_id: int, nic_session_id: int) -> None:
        self.runtime = Runtime(
            host_session_id=host_session_id, nic_session_id=nic_session_id
        )

    def ingest(
        self,
        header: dict[str, int],
        holes: list[dict[str, int]],
        notification: dict[str, int],
    ) -> list[dict[str, Any]]:
        """Absorb one report and return retry requests the NIC may execute."""
        report_bytes = encode("ReportHeader", header)
        # Validate the transaction exactly as a driver would before caching it.
        decode("ReportHeader", report_bytes)
        notif = {
            "version": 1,
            "qpn": notification["qpn"],
            "qp_epoch": notification["qpEpoch"],
            "report_generation": notification["reportGeneration"],
            "report_byte_length": notification["reportByteLength"],
            "nic_session_id": notification["nicSessionId"],
        }
        if not self.runtime.ingest_report(notif, report_bytes, holes):
            raise AssertionError(f"CPU rejected report: {header!r} {notif!r}")
        return self.runtime.plan_retries(header["qpn"])

    @staticmethod
    def retry_bits(request: dict[str, Any]) -> tuple[int, dict[str, int]]:
        """Encode a CPU retry request into the NIC's struct-packed port value."""
        values = {
            "retry_request_id": int(request["retry_request_id"]),
            "host_session_id": int(request["host_session_id"]),
            "qpn": int(request["qpn"]),
            "trigger_reason": int(request["trigger_reason"]),
            "qp_epoch": int(request["qp_epoch"]),
            "retry_attempt": int(request["retry_attempt"]),
            "psn": int(request["psn"]),
            "record_handle": int(request["record_handle"]),
            "report_generation": int(request["report_generation"]),
            "expected_request_id": int(request["expected_request_id"]),
            "expected_packet_index": int(request["expected_packet_index"]),
        }
        # Transaction boundary: the codec adds entry_crc32; decode proves the
        # host blobs round-trip before they are packed onto the NIC port.
        entry = decode("RetryEntry", encode("RetryEntry", values))
        return pack_named("retry", entry), entry
