"""Generated Retx ABI v1 codec. Do not edit."""
from __future__ import annotations

import binascii

SCHEMA = {'ReportHeader': {'size': 64, 'fields': [('version', 8, 0), ('flags', 8, 8), ('byte_length', 16, 16), ('qpn', 24, 32), ('reserved0', 8, 56), ('qp_epoch', 16, 64), ('sack_valid_bits', 16, 80), ('report_generation', 32, 96), ('scoreboard_generation', 32, 128), ('nic_session_id', 32, 160), ('ack_psn', 24, 192), ('sack_base', 24, 216), ('outstanding_base', 24, 240), ('nak_psn', 24, 264), ('outstanding_count', 16, 288), ('ooo_count', 16, 304), ('hole_count', 16, 320), ('hole_entries_included', 8, 336), ('nak_valid_and_code', 8, 344), ('sack_bitmap', 128, 352), ('crc32', 32, 480)]}, 'HoleEntry': {'size': 40, 'fields': [('psn', 24, 0), ('record_handle', 32, 24), ('request_id', 16, 56), ('packet_index', 18, 72), ('packet_count', 18, 90), ('message_offset', 25, 108), ('payload_length', 13, 133), ('remote_addr', 64, 146), ('remote_key', 32, 210), ('opcode', 8, 242), ('pmtu', 3, 250), ('slot_id', 18, 253), ('wire_profile', 2, 271), ('ev_profile', 2, 273), ('mrc_msn', 16, 275), ('msn_valid', 1, 291), ('is_first', 1, 292), ('is_last', 1, 293), ('reserved0', 26, 294)]}, 'RetryBatchHeader': {'size': 16, 'fields': [('version', 8, 0), ('flags', 8, 8), ('byte_length', 16, 16), ('nic_session_id', 32, 32), ('entry_count', 8, 64), ('reserved0', 24, 72), ('header_crc32', 32, 96)]}, 'RetryEntry': {'size': 40, 'fields': [('retry_request_id', 32, 0), ('host_session_id', 32, 32), ('qpn', 24, 64), ('trigger_reason', 8, 88), ('qp_epoch', 16, 96), ('retry_attempt', 8, 112), ('flags', 8, 120), ('psn', 24, 128), ('reserved0', 8, 152), ('record_handle', 32, 160), ('report_generation', 32, 192), ('expected_request_id', 16, 224), ('expected_packet_index', 24, 240), ('reserved1', 24, 264), ('entry_crc32', 32, 288)]}, 'RetryResult': {'size': 40, 'fields': [('version', 8, 0), ('status', 8, 8), ('byte_length', 16, 16), ('retry_request_id', 32, 32), ('host_session_id', 32, 64), ('nic_session_id', 32, 96), ('qpn', 24, 128), ('reason_code', 8, 152), ('qp_epoch', 16, 160), ('fetch_id', 16, 176), ('psn', 24, 192), ('result_sequence', 8, 216), ('report_generation', 32, 224), ('egress_sequence', 32, 256), ('crc32', 32, 288)]}, 'OnDemandRequest': {'size': 32, 'fields': [('version', 8, 0), ('reason', 8, 8), ('byte_length', 16, 16), ('request_id', 32, 32), ('qpn', 24, 64), ('flags', 8, 88), ('qp_epoch', 16, 96), ('reserved0', 16, 112), ('host_session_id', 32, 128), ('nic_session_id', 32, 160), ('last_seen_report_generation', 32, 192), ('crc32', 32, 224)]}, 'Notification': {'size': 32, 'fields': [('version', 8, 0), ('flags', 8, 8), ('byte_length', 16, 16), ('ring_slot', 8, 32), ('reserved0', 8, 40), ('report_byte_length', 16, 48), ('qpn', 24, 64), ('reserved1', 8, 88), ('qp_epoch', 16, 96), ('reserved2', 16, 112), ('report_generation', 32, 128), ('nic_session_id', 32, 160), ('host_session_id', 32, 192), ('crc32', 32, 224)]}, 'RingCredit': {'size': 16, 'fields': [('version', 8, 0), ('ring_id', 8, 8), ('slot', 8, 16), ('flags', 8, 24), ('consumer_sequence', 32, 32), ('object_identity', 32, 64), ('crc32', 32, 96)]}, 'NegotiationRequest': {'size': 80, 'fields': [('version', 8, 0), ('roles', 8, 8), ('byte_length', 16, 16), ('host_session_id', 32, 32), ('nic_session_id', 32, 64), ('required_caps', 32, 96), ('optional_caps', 32, 128), ('max_qp', 16, 160), ('window', 16, 176), ('max_report_bytes', 16, 192), ('result_ring_depth', 8, 208), ('report_ring_depth', 8, 216), ('notification_ring_depth', 8, 224), ('ondemand_ring_depth', 8, 232), ('retry_ring_depth', 8, 240), ('max_batch_entries', 8, 248), ('replay_slots', 16, 256), ('active_contexts', 8, 272), ('retry_limit', 8, 280), ('timeout_ns', 32, 288), ('stale_ns', 32, 320), ('sack_hole_threshold', 16, 352), ('reserved0', 16, 368), ('schema_hash', 128, 384), ('reserved1', 96, 512), ('crc32', 32, 608)]}, 'NegotiationResponse': {'size': 80, 'fields': [('version', 8, 0), ('result', 8, 8), ('byte_length', 16, 16), ('host_session_id', 32, 32), ('nic_session_id', 32, 64), ('supported_caps', 32, 96), ('max_qp', 16, 128), ('window', 16, 144), ('max_report_bytes', 16, 160), ('result_ring_depth', 8, 176), ('report_ring_depth', 8, 184), ('notification_ring_depth', 8, 192), ('ondemand_ring_depth', 8, 200), ('retry_ring_depth', 8, 208), ('max_batch_entries', 8, 216), ('replay_slots', 16, 224), ('active_contexts', 8, 240), ('retry_limit', 8, 248), ('timeout_ns', 32, 256), ('stale_ns', 32, 288), ('sack_hole_threshold', 16, 320), ('reserved0', 16, 336), ('schema_hash', 128, 352), ('reserved1', 128, 480), ('crc32', 32, 608)]}}
CRC_FIELDS = {'ReportHeader': 'crc32', 'RetryBatchHeader': 'header_crc32', 'RetryEntry': 'entry_crc32', 'RetryResult': 'crc32', 'OnDemandRequest': 'crc32', 'Notification': 'crc32', 'RingCredit': 'crc32', 'NegotiationRequest': 'crc32', 'NegotiationResponse': 'crc32'}


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _encode_raw(name: str, values: dict) -> bytearray:
    spec = SCHEMA[name]
    packed = 0
    for field, width, offset in spec["fields"]:
        value = int(values.get(field, 0))
        if value < 0 or value >= (1 << width):
            raise ValueError(f"{name}.{field} out of range")
        packed |= value << offset
    return bytearray(packed.to_bytes(spec["size"], "little"))


def encode(name: str, values: dict) -> bytes:
    spec = SCHEMA[name]
    crc_field = CRC_FIELDS.get(name)
    if not crc_field:
        return bytes(_encode_raw(name, values))
    data = _encode_raw(name, dict(values, **{crc_field: 0}))
    field, width, offset = next(f for f in spec["fields"] if f[0] == crc_field)
    crc = _crc32(bytes(data))
    raw = int.from_bytes(data, "little")
    raw |= crc << offset
    return raw.to_bytes(spec["size"], "little")


def decode(name: str, data: bytes, check_crc: bool = True) -> dict:
    spec = SCHEMA[name]
    if len(data) != spec["size"]:
        raise ValueError(f"{name} length {len(data)} != {spec['size']}")
    raw = int.from_bytes(data, "little")
    values = {}
    for field, width, offset in spec["fields"]:
        values[field] = (raw >> offset) & ((1 << width) - 1)
    if check_crc:
        crc_field = CRC_FIELDS.get(name)
        if crc_field:
            field, width, offset = next(f for f in spec["fields"] if f[0] == crc_field)
            expected = values[crc_field]
            zeroed = bytearray(data)
            raw_zero = int.from_bytes(zeroed, "little") & ~(((1 << width) - 1) << offset)
            zeroed = bytearray(raw_zero.to_bytes(spec["size"], "little"))
            if _crc32(bytes(zeroed)) != expected:
                raise ValueError(f"{name} crc mismatch")
    return values


def _require_zero(name: str, values: dict) -> None:
    for field, width, _ in SCHEMA[name]["fields"]:
        if field.startswith("reserved") and values.get(field, 0) != 0:
            raise ValueError(f"{name}.{field} must be zero")


def validate_report(values: dict) -> dict:
    _require_zero("ReportHeader", values)
    if values["version"] != 1:
        raise ValueError("unsupported ABI version")
    n = values["hole_entries_included"]
    if values["byte_length"] != 64 + 40 * n or n > 16:
        raise ValueError("bad report byte_length")
    if values["sack_valid_bits"] != min(16, values["outstanding_count"]):
        raise ValueError("sack_valid_bits must equal min(16, outstanding_count)")
    if values["hole_count"] > values["outstanding_count"] or values["hole_count"] > 16:
        raise ValueError("hole_count exceeds outstanding_count")
    if values["sack_base"] != (values["ack_psn"] + 1) & 0xFFFFFF:
        raise ValueError("sack_base must follow ack_psn")
    if values["outstanding_base"] != values["sack_base"]:
        raise ValueError("outstanding_base must equal sack_base")
    valid_bits = values["sack_valid_bits"]
    if values["sack_bitmap"] >> valid_bits:
        raise ValueError("bitmap bits outside coverage must be zero")
    if n != values["hole_count"]:
        flags = values["flags"] | (1 << 4)
        values = dict(values, flags=flags)
    if values["nak_valid_and_code"] == 0:
        if values["nak_psn"] != 0:
            raise ValueError("nak_psn must be zero when nak_valid=0")
    return values


def validate_retry_entry(values: dict) -> None:
    _require_zero("RetryEntry", values)
    if values["retry_attempt"] > 2:
        raise ValueError("retry_attempt exceeds limit")
    if values["trigger_reason"] & 0xF0:
        raise ValueError("trigger_reason high bits must be zero")
    if values["expected_packet_index"] >> 18:
        raise ValueError("expected_packet_index high bits must be zero")


def validate_retry_batch(header: dict, entries: list[dict]) -> None:
    _require_zero("RetryBatchHeader", header)
    n = header["entry_count"]
    if not 1 <= n <= 8 or len(entries) != n:
        raise ValueError("bad retry batch entry count")
    if header["byte_length"] != 16 + 40 * n:
        raise ValueError("bad retry batch byte_length")
    seen = set()
    for entry in entries:
        validate_retry_entry(entry)
        key = (entry["host_session_id"], entry["retry_request_id"])
        if key in seen:
            raise ValueError("duplicate request identity in batch")
        seen.add(key)


def field_width(name: str, field: str) -> int:
    return next(w for f, w, _ in SCHEMA[name]["fields"] if f == field)
