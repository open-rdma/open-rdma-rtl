"""Retx Python reference runtime: Report cache, loss policy, deadlines, requests.

This is a simulation/reference implementation, not a production driver.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from openrdma_flow.retx.codec import (decode, encode, validate_report)

QP_COUNT = 4
WINDOW = 16
SACK_THRESHOLD = 3
TIMEOUT_NS = 64_000
STALE_NS = 64_000
RETRY_LIMIT = 3
BACKOFF_BASE_NS = 64_000
BACKOFF_CAP_NS = 512_000
SCAN_QP_BUDGET = 4
SCAN_BIT_BUDGET = 64
SCAN_REQUEST_BUDGET = 8
ONDEMAND_INTERVAL_NS = 64_000


def serial_le(a: int, b: int, width: int = 24) -> bool:
    return ((b - a) & ((1 << width) - 1)) < (1 << (width - 1))


@dataclass
class QpCache:
    report: dict[str, Any] | None = None
    received_at: int = 0
    needs_refresh: bool = False
    last_refresh_request: int | None = None


@dataclass
class PendingRetry:
    key: tuple[int, int, int]
    report_generation: int
    trigger: int
    attempt: int = 0
    state: str = "pending"  # pending | submitted | stale-awaiting | terminal
    request_id: int | None = None
    next_attempt_at: int = 0


@dataclass
class Runtime:
    host_session_id: int
    nic_session_id: int = 0
    now_ns: int = 0
    caches: dict[int, QpCache] = field(default_factory=dict)
    deadlines: dict[int, int] = field(default_factory=dict)
    deadline_armed: dict[int, bool] = field(default_factory=dict)
    pending: dict[tuple[int, int, int], PendingRetry] = field(default_factory=dict)
    next_request_id: int = 1
    ondemand_requests: list[dict[str, Any]] = field(default_factory=list)
    retry_requests: list[dict[str, Any]] = field(default_factory=list)
    results_seen: set[tuple[int, int, int]] = field(default_factory=set)
    early_results: dict[tuple[int, int, int], dict[str, Any]] = field(default_factory=dict)
    stats: dict[str, int] = field(default_factory=dict)
    qp_cursor: int = 0

    # -- Report ingestion ---------------------------------------------------
    def ingest_notification(self, notification: dict[str, Any], report_bytes: bytes) -> bool:
        if notification["version"] != 1:
            self._count("bad_notification")
            return False
        if notification["nic_session_id"] != self.nic_session_id:
            self._count("stale_session_report")
            return False
        qpn = notification["qpn"]
        if qpn not in self.caches:
            # QPN values are arbitrary; NIC slots are what is capped.
            if len(self.caches) >= QP_COUNT:
                self._count("too_many_contexts")
                return False
            self.caches[qpn] = QpCache()
        try:
            values = decode("ReportHeader", report_bytes)
            values = validate_report(values)
        except ValueError:
            self._count("bad_report")
            return False
        if (values["qpn"] != qpn
                or values["qp_epoch"] != notification["qp_epoch"]
                or values["report_generation"] != notification["report_generation"]
                or values["byte_length"] != notification["report_byte_length"]):
            self._count("identity_mismatch")
            return False
        cache = self.caches[qpn]
        if cache.report is not None:
            if values["qp_epoch"] != cache.report["qp_epoch"]:
                cache.report = None
                self._drop_qp_work(qpn)
            elif not self._generation_newer(values["report_generation"],
                                            cache.report["report_generation"]):
                self._count("duplicate_report")
                return False
            else:
                old = cache.report["report_generation"]
        needs_refresh = bool(values["flags"] & ((1 << 4) | (1 << 5) | (1 << 6)))
        if cache.report is not None and values["qp_epoch"] == cache.report["qp_epoch"]:
            if values["report_generation"] > cache.report["report_generation"] + 1:
                self._count("generation_gap")
                needs_refresh = True
        cache.report = values
        cache.received_at = self.now_ns
        cache.needs_refresh = needs_refresh
        self._rearm_or_cancel(qpn, values)
        self._count("reports_accepted")
        return True

    def _generation_newer(self, new: int, old: int) -> bool:
        return new != old and ((new - old) & 0xFFFFFFFF) < 0x80000000

    # -- Host CPU report path ----------------------------------------------
    def ingest_report(
        self,
        notification: dict[str, Any],
        report_bytes: bytes,
        holes: list[dict[str, Any]] | None = None,
    ) -> bool:
        """Ingest a NIC notification plus report body, as the CPU would.

        Hole entries travel beside the header in the ABI; attach them to the
        report generation so later retry requests can carry the packet
        metadata the NIC needs for admission and replay fetch.
        """
        for entry in holes or []:
            self.attach_hole(
                notification["qpn"], notification["report_generation"], entry
            )
        return self.ingest_notification(notification, report_bytes)

    def plan_retries(self, qpn: int) -> list[dict[str, Any]]:
        """Turn the cached report's holes into ready retry requests.

        The loss policy (SACK hole threshold, NAK, timeout) stays in
        ``decisions``/``service``; this is the report-driven fast path a CPU
        uses right after ingesting a fresh report.
        """
        for decision in self.decisions(qpn):
            self._queue(decision)
        return self._assemble_requests()

    def _rearm_or_cancel(self, qpn: int, values: dict[str, Any]) -> None:
        if values["outstanding_count"] == 0:
            self.deadlines.pop(qpn, None)
            self.deadline_armed[qpn] = False
            return
        self.deadlines[qpn] = self.now_ns + TIMEOUT_NS
        self.deadline_armed[qpn] = True

    # -- Loss policy --------------------------------------------------------
    def decisions(self, qpn: int) -> list[dict[str, Any]]:
        cache = self.caches[qpn]
        report = cache.report
        if report is None or cache.needs_refresh:
            return []
        if self.now_ns - cache.received_at > STALE_NS:
            cache.needs_refresh = True
            return []
        out: list[dict[str, Any]] = []
        if report["nak_valid_and_code"] & 0x80:
            code = report["nak_valid_and_code"] & 0x7F
            psn = report["nak_psn"]
            if code == 1 and self._psn_outstanding(report, psn):
                out.append(self._decision(qpn, report, psn, 1))
            elif code not in (0, 1):
                self._count("terminal_nak")
            return out
        base = report["sack_base"]
        bitmap = report["sack_bitmap"]
        valid = report["sack_valid_bits"]
        for offset in range(min(valid, report["outstanding_count"])):
            if (bitmap >> offset) & 1:
                continue
            psn = (base + offset) & 0xFFFFFF
            count = 0
            for j in range(offset + 1, valid):
                if (bitmap >> j) & 1:
                    count += 1
            if count >= SACK_THRESHOLD:
                out.append(self._decision(qpn, report, psn, 2))
        return out

    def _psn_outstanding(self, report: dict[str, Any], psn: int) -> bool:
        base = report["sack_base"]
        off = (psn - base) & 0xFFFFFF
        return 0 <= off < min(report["sack_valid_bits"], report["outstanding_count"])

    def _decision(self, qpn: int, report: dict[str, Any], psn: int, trigger: int) -> dict[str, Any]:
        return {
            "qpn": qpn, "qp_epoch": report["qp_epoch"], "psn": psn,
            "report_generation": report["report_generation"],
            "trigger_reason": trigger,
        }

    # -- Deadlines ----------------------------------------------------------
    def service(self) -> list[dict[str, Any]]:
        """Advance virtual time services: expire deadlines and emit requests."""
        emitted: list[dict[str, Any]] = []
        checked_qps = 0
        bit_budget = SCAN_BIT_BUDGET
        keys = sorted(self.caches)
        if not keys:
            return emitted
        start = self.qp_cursor % len(keys)
        for step in range(min(QP_COUNT, len(keys))):
            if checked_qps >= SCAN_QP_BUDGET:
                break
            qpn = keys[(start + step) % len(keys)]
            checked_qps += 1
            cache = self.caches[qpn]
            if cache.needs_refresh:
                self._request_refresh(qpn, reason=3 if cache.report else 1)
                continue
            if not self.deadline_armed.get(qpn):
                continue
            if self.now_ns < self.deadlines.get(qpn, 0):
                continue
            if cache.report is None or self.now_ns - cache.received_at > STALE_NS:
                cache.needs_refresh = True
                self._request_refresh(qpn, reason=2)
                continue
            decisions = self.decisions(qpn)
            if not decisions:
                decisions = self._timeout_decisions(qpn)
            for decision in decisions:
                if bit_budget <= 0:
                    break
                bit_budget -= 1
                self._queue(decision)
        self.qp_cursor = (start + 1) % len(keys)
        emitted = self._assemble_requests()
        return emitted

    def _timeout_decisions(self, qpn: int) -> list[dict[str, Any]]:
        report = self.caches[qpn].report
        if report is None:
            return []
        store = getattr(self, "_hole_store", {})
        out = []
        base = report["sack_base"]
        for offset in range(min(report["sack_valid_bits"], report["outstanding_count"])):
            if (report["sack_bitmap"] >> offset) & 1:
                continue
            psn = (base + offset) & 0xFFFFFF
            if (qpn, report["report_generation"], psn) in store:
                out.append(self._decision(qpn, report, psn, 3))
        return out

    def _queue(self, decision: dict[str, Any]) -> None:
        key = (decision["qpn"], decision["qp_epoch"], decision["psn"])
        if key in self.pending and self.pending[key].state not in ("terminal",):
            return
        self.pending[key] = PendingRetry(
            key=key, report_generation=decision["report_generation"],
            trigger=decision["trigger_reason"], next_attempt_at=self.now_ns)

    def _assemble_requests(self) -> list[dict[str, Any]]:
        ready = [p for p in self.pending.values()
                 if p.state == "pending" and p.next_attempt_at <= self.now_ns]
        ready.sort(key=lambda p: (p.key[0], p.key[2]))
        out: list[dict[str, Any]] = []
        for pending in ready[:SCAN_REQUEST_BUDGET]:
            qpn, epoch, psn = pending.key
            cache = self.caches[qpn].report
            if cache is None:
                continue
            hole = self._hole(cache, qpn, psn)
            if hole is None:
                pending.state = "terminal"
                continue
            rid = self.next_request_id
            self.next_request_id += 1
            pending.request_id = rid
            pending.state = "submitted"
            entry = {
                "retry_request_id": rid,
                "host_session_id": self.host_session_id,
                "qpn": qpn,
                "trigger_reason": pending.trigger,
                "qp_epoch": epoch,
                "retry_attempt": pending.attempt,
                "psn": psn,
                "record_handle": hole["record_handle"],
                "report_generation": pending.report_generation,
                "expected_request_id": hole["request_id"],
                "expected_packet_index": hole["packet_index"],
            }
            out.append(entry)
            self.retry_requests.append(entry)
        if out:
            self.stats["requests_emitted"] = self.stats.get("requests_emitted", 0) + len(out)
        return out

    def _hole(self, report: dict[str, Any], qpn: int, psn: int) -> dict[str, Any] | None:
        # Hole metadata is carried in Report entries; the cache keeps only the
        # header in this reference model, so tests inject metadata via reports.
        return self._holes.get((qpn, report["report_generation"], psn))

    _holes: dict[tuple[int, int, int], dict[str, Any]] = field(default_factory=dict)

    def attach_hole(self, qpn: int, generation: int, entry: dict[str, Any]) -> None:
        if not hasattr(self, "_hole_store"):
            self._hole_store = {}
        self._hole_store[(qpn, generation, entry["psn"])] = entry

    def _hole(self, report, qpn, psn):  # type: ignore[no-redef]
        store = getattr(self, "_hole_store", {})
        return store.get((qpn, report["report_generation"], psn))

    # -- On-demand ----------------------------------------------------------
    def _request_refresh(self, qpn: int, reason: int) -> None:
        cache = self.caches[qpn]
        if (cache.last_refresh_request is not None
                and self.now_ns - cache.last_refresh_request < ONDEMAND_INTERVAL_NS):
            return
        qpn_epoch = cache.report["qp_epoch"] if cache.report else 0
        req = {
            "request_id": self.next_request_id,
            "qpn": qpn, "qp_epoch": qpn_epoch,
            "host_session_id": self.host_session_id,
            "nic_session_id": self.nic_session_id,
            "last_seen_report_generation": cache.report["report_generation"] if cache.report else 0,
            "reason": reason,
        }
        self.next_request_id += 1
        cache.last_refresh_request = self.now_ns
        self.ondemand_requests.append(req)
        self._count("ondemand_requests")

    # -- Results ------------------------------------------------------------
    def on_result(self, result: dict[str, Any]) -> None:
        key = (result["host_session_id"], result["nic_session_id"],
               result["retry_request_id"])
        if result["host_session_id"] != self.host_session_id:
            self._count("stale_result")
            return
        if key in self.results_seen:
            self._count("duplicate_result")
            return
        self.results_seen.add(key)
        pending = next((p for p in self.pending.values()
                        if p.request_id == result["retry_request_id"]), None)
        if pending is None:
            self._count("orphan_result")
            return
        status = result["status"] & 0x7F
        terminal = bool(result["status"] & 0x80) or status != 1
        if status == 1:
            return
        if status == 2:
            pending.state = "terminal"
        elif status in (3, 6):
            pending.state = "terminal"
        elif status in (4, 5):
            pending.attempt += 1
            if pending.attempt >= RETRY_LIMIT:
                pending.state = "terminal"
            else:
                pending.state = "pending"
                pending.next_attempt_at = self.now_ns + self._backoff(pending.attempt)
        if terminal:
            self._count("results_terminal")

    def _backoff(self, attempt: int) -> int:
        return min(BACKOFF_BASE_NS << attempt, BACKOFF_CAP_NS)

    def _drop_qp_work(self, qpn: int) -> None:
        for key in list(self.pending):
            if key[0] == qpn:
                del self.pending[key]
        self.deadlines.pop(qpn, None)
        self.deadline_armed[qpn] = False

    def _count(self, name: str) -> None:
        self.stats[name] = self.stats.get(name, 0) + 1

    # -- ABI helpers --------------------------------------------------------
    def build_retry_batch(self, entries: list[dict[str, Any]]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        header = {
            "version": 1, "flags": 1, "byte_length": 16 + 40 * len(entries),
            "nic_session_id": self.nic_session_id,
            "entry_count": len(entries),
        }
        return header, entries
