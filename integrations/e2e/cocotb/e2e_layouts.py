"""E2E retx host-ABI port layouts (BSV struct declaration order, first field MSB)."""

from openrdma_flow_tb.retx.layouts import pack, unpack

QP = [("qpn", 24), ("qpEpoch", 16), ("initialPsn", 24), ("enable", 1)]

SNAPREQ = [("qpn", 24), ("qpEpoch", 16), ("onDemand", 1), ("requestId", 32)]

REPORT = [
    ("version", 8), ("flags", 8), ("byte_length", 16), ("qpn", 24),
    ("reserved0", 8), ("qp_epoch", 16), ("sack_valid_bits", 16),
    ("report_generation", 32), ("scoreboard_generation", 32),
    ("nic_session_id", 32), ("ack_psn", 24), ("sack_base", 24),
    ("outstanding_base", 24), ("nak_psn", 24), ("outstanding_count", 16),
    ("ooo_count", 16), ("hole_count", 16), ("hole_entries_included", 8),
    ("nak_valid_and_code", 8), ("sack_bitmap", 128), ("crc32", 32),
]

HOLE = [
    ("psn", 24), ("record_handle", 32), ("request_id", 16),
    ("packet_index", 18), ("packet_count", 18), ("message_offset", 25),
    ("payload_length", 13), ("remote_addr", 64), ("remote_key", 32),
    ("opcode", 8), ("pmtu", 3), ("slot_id", 18), ("wire_profile", 2),
    ("ev_profile", 2), ("mrc_msn", 16), ("msn_valid", 1),
    ("is_first", 1), ("is_last", 1), ("reserved0", 26),
]

NOTIFICATION = [
    ("txnId", 32), ("ringSlot", 8), ("reportByteLength", 16), ("qpn", 24),
    ("qpEpoch", 16), ("reportGeneration", 32), ("nicSessionId", 32),
    ("hostSessionId", 32),
]

RETRY = [
    ("retry_request_id", 32), ("host_session_id", 32), ("qpn", 24),
    ("trigger_reason", 8), ("qp_epoch", 16), ("retry_attempt", 8),
    ("flags", 8), ("psn", 24), ("reserved0", 8), ("record_handle", 32),
    ("report_generation", 32), ("expected_request_id", 16),
    ("expected_packet_index", 24), ("reserved1", 24), ("entry_crc32", 32),
]

RESULT = [
    ("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
    ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("status", 8),
    ("reason", 8), ("fetchId", 16), ("reportGeneration", 32),
    ("egressSequence", 32), ("resultSequence", 8),
]

RELEASE = [("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32)]


def pack_named(name: str, values: dict[str, int]) -> int:
    return pack(LAYOUTS[name], values)


def unpack_named(name: str, packed: int) -> dict[str, int]:
    return unpack(LAYOUTS[name], packed)


LAYOUTS = {
    "qp": QP,
    "snapreq": SNAPREQ,
    "report": REPORT,
    "hole": HOLE,
    "notification": NOTIFICATION,
    "retry": RETRY,
    "result": RESULT,
    "release": RELEASE,
}
