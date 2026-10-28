"""Retx ABI v1 schema — single authority for BSV/Python/golden generation.

Field bit offsets are LSB-based within the little-endian host transaction:
byte 0 is the least significant byte, bit 0 is byte 0 bit 0.
"""

OBJECTS = {
    "ReportHeader": {
        "size": 64,
        "fields": [
            ("version", 8, 0),
            ("flags", 8, 8),
            ("byte_length", 16, 16),
            ("qpn", 24, 32),
            ("reserved0", 8, 56),
            ("qp_epoch", 16, 64),
            ("sack_valid_bits", 16, 80),
            ("report_generation", 32, 96),
            ("scoreboard_generation", 32, 128),
            ("nic_session_id", 32, 160),
            ("ack_psn", 24, 192),
            ("sack_base", 24, 216),
            ("outstanding_base", 24, 240),
            ("nak_psn", 24, 264),
            ("outstanding_count", 16, 288),
            ("ooo_count", 16, 304),
            ("hole_count", 16, 320),
            ("hole_entries_included", 8, 336),
            ("nak_valid_and_code", 8, 344),
            ("sack_bitmap", 128, 352),
            ("crc32", 32, 480),
        ],
    },
    "HoleEntry": {
        "size": 40,
        "fields": [
            ("psn", 24, 0),
            ("record_handle", 32, 24),
            ("request_id", 16, 56),
            ("packet_index", 18, 72),
            ("packet_count", 18, 90),
            ("message_offset", 25, 108),
            ("payload_length", 13, 133),
            ("remote_addr", 64, 146),
            ("remote_key", 32, 210),
            ("opcode", 8, 242),
            ("pmtu", 3, 250),
            ("slot_id", 18, 253),
            ("wire_profile", 2, 271),
            ("ev_profile", 2, 273),
            ("mrc_msn", 16, 275),
            ("msn_valid", 1, 291),
            ("is_first", 1, 292),
            ("is_last", 1, 293),
            ("reserved0", 26, 294),
        ],
    },
    "RetryBatchHeader": {
        "size": 16,
        "fields": [
            ("version", 8, 0),
            ("flags", 8, 8),
            ("byte_length", 16, 16),
            ("nic_session_id", 32, 32),
            ("entry_count", 8, 64),
            ("reserved0", 24, 72),
            ("header_crc32", 32, 96),
        ],
    },
    "RetryEntry": {
        "size": 40,
        "fields": [
            ("retry_request_id", 32, 0),
            ("host_session_id", 32, 32),
            ("qpn", 24, 64),
            ("trigger_reason", 8, 88),
            ("qp_epoch", 16, 96),
            ("retry_attempt", 8, 112),
            ("flags", 8, 120),
            ("psn", 24, 128),
            ("reserved0", 8, 152),
            ("record_handle", 32, 160),
            ("report_generation", 32, 192),
            ("expected_request_id", 16, 224),
            ("expected_packet_index", 24, 240),
            ("reserved1", 24, 264),
            ("entry_crc32", 32, 288),
        ],
    },
    "RetryResult": {
        "size": 40,
        "fields": [
            ("version", 8, 0),
            ("status", 8, 8),
            ("byte_length", 16, 16),
            ("retry_request_id", 32, 32),
            ("host_session_id", 32, 64),
            ("nic_session_id", 32, 96),
            ("qpn", 24, 128),
            ("reason_code", 8, 152),
            ("qp_epoch", 16, 160),
            ("fetch_id", 16, 176),
            ("psn", 24, 192),
            ("result_sequence", 8, 216),
            ("report_generation", 32, 224),
            ("egress_sequence", 32, 256),
            ("crc32", 32, 288),
        ],
    },
    "OnDemandRequest": {
        "size": 32,
        "fields": [
            ("version", 8, 0),
            ("reason", 8, 8),
            ("byte_length", 16, 16),
            ("request_id", 32, 32),
            ("qpn", 24, 64),
            ("flags", 8, 88),
            ("qp_epoch", 16, 96),
            ("reserved0", 16, 112),
            ("host_session_id", 32, 128),
            ("nic_session_id", 32, 160),
            ("last_seen_report_generation", 32, 192),
            ("crc32", 32, 224),
        ],
    },
    "Notification": {
        "size": 32,
        "fields": [
            ("version", 8, 0),
            ("flags", 8, 8),
            ("byte_length", 16, 16),
            ("ring_slot", 8, 32),
            ("reserved0", 8, 40),
            ("report_byte_length", 16, 48),
            ("qpn", 24, 64),
            ("reserved1", 8, 88),
            ("qp_epoch", 16, 96),
            ("reserved2", 16, 112),
            ("report_generation", 32, 128),
            ("nic_session_id", 32, 160),
            ("host_session_id", 32, 192),
            ("crc32", 32, 224),
        ],
    },
    "RingCredit": {
        "size": 16,
        "fields": [
            ("version", 8, 0),
            ("ring_id", 8, 8),
            ("slot", 8, 16),
            ("flags", 8, 24),
            ("consumer_sequence", 32, 32),
            ("object_identity", 32, 64),
            ("crc32", 32, 96),
        ],
    },
    "NegotiationRequest": {
        "size": 80,
        "fields": [
            ("version", 8, 0),
            ("roles", 8, 8),
            ("byte_length", 16, 16),
            ("host_session_id", 32, 32),
            ("nic_session_id", 32, 64),
            ("required_caps", 32, 96),
            ("optional_caps", 32, 128),
            ("max_qp", 16, 160),
            ("window", 16, 176),
            ("max_report_bytes", 16, 192),
            ("result_ring_depth", 8, 208),
            ("report_ring_depth", 8, 216),
            ("notification_ring_depth", 8, 224),
            ("ondemand_ring_depth", 8, 232),
            ("retry_ring_depth", 8, 240),
            ("max_batch_entries", 8, 248),
            ("replay_slots", 16, 256),
            ("active_contexts", 8, 272),
            ("retry_limit", 8, 280),
            ("timeout_ns", 32, 288),
            ("stale_ns", 32, 320),
            ("sack_hole_threshold", 16, 352),
            ("reserved0", 16, 368),
            ("schema_hash", 128, 384),
            ("reserved1", 96, 512),
            ("crc32", 32, 608),
        ],
    },
    "NegotiationResponse": {
        "size": 80,
        "fields": [
            ("version", 8, 0),
            ("result", 8, 8),
            ("byte_length", 16, 16),
            ("host_session_id", 32, 32),
            ("nic_session_id", 32, 64),
            ("supported_caps", 32, 96),
            ("max_qp", 16, 128),
            ("window", 16, 144),
            ("max_report_bytes", 16, 160),
            ("result_ring_depth", 8, 176),
            ("report_ring_depth", 8, 184),
            ("notification_ring_depth", 8, 192),
            ("ondemand_ring_depth", 8, 200),
            ("retry_ring_depth", 8, 208),
            ("max_batch_entries", 8, 216),
            ("replay_slots", 16, 224),
            ("active_contexts", 8, 240),
            ("retry_limit", 8, 248),
            ("timeout_ns", 32, 256),
            ("stale_ns", 32, 288),
            ("sack_hole_threshold", 16, 320),
            ("reserved0", 16, 336),
            ("schema_hash", 128, 352),
            ("reserved1", 128, 480),
            ("crc32", 32, 608),
        ],
    },
}

# Parent TxTypes width map that generated RetxTypes must stay compatible with.
PARENT_WIDTHS = {
    "qpn": 24,
    "psn": 24,
    "slot_id": 18,
    "packet_index": 18,
    "packet_count": 18,
    "message_offset": 25,
    "payload_length": 13,
    "pmtu": 3,
    "wire_profile": 2,
    "ev_profile": 2,
    "mrc_msn": 16,
}

# Object-scoped parent widths (host request IDs are wider than the wire request id).
OBJECT_WIDTHS = {
    ("HoleEntry", "request_id"): 16,
    ("RetryEntry", "expected_request_id"): 16,
}

CRC32_OBJECTS = {"crc32", "header_crc32", "entry_crc32"}

# BSV-only seam types shared across m9/m10/m11/integration. Widths in bits.
INTERNAL_TYPES = {
    "QpConfigHw": [("qpn", 24), ("qpEpoch", 16), ("initialPsn", 24), ("enable", 1)],
    "WqeRegisterHw": [
        ("qpn", 24), ("destQpn", 24), ("qpEpoch", 16), ("requestId", 16),
        ("psnBase", 24), ("psnCount", 18), ("packetCount", 18), ("pmtu", 3),
        ("messageLength", 25), ("remoteAddr", 64), ("remoteKey", 32),
        ("opcode", 8), ("slotId", 18), ("wireProfile", 2), ("evProfile", 2),
        ("mrcMsn", 16), ("msnValid", 1),
    ],
    "WqeRegisterRespHw": [("ok", 1), ("recordHandle", 32)],
    "PacketReserveHw": [
        ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("requestId", 16),
        ("packetIndex", 18), ("packetCount", 18), ("messageOffset", 25),
        ("payloadLength", 13), ("messageLength", 25), ("opcode", 8),
        ("first", 1), ("last", 1), ("recordHandle", 32), ("replayHandle", 32),
    ],
    "PacketGrantHw": [("ok", 1), ("reason", 8), ("replayHandle", 32)],
    "SentEventHw": [
        ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("packetIndex", 18),
        ("recordHandle", 32), ("replayHandle", 32), ("commitToken", 32),
    ],
    "FeedbackEventHw": [
        ("qpn", 24), ("qpEpoch", 16), ("kind", 2), ("ackPsn", 24),
        ("sackBase", 24), ("sackBitmap", 128), ("sackValidBits", 16),
        ("nakValid", 1), ("nakCode", 7), ("nakPsn", 24), ("oooCount", 16),
        ("triggerPsn", 24),
    ],
    "RecordTerminateHw": [
        ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32),
    ],
    "SnapshotReqHw": [
        ("qpn", 24), ("qpEpoch", 16), ("onDemand", 1), ("requestId", 32),
    ],
    "SnapshotHdrHw": [
        ("qpn", 24), ("qpEpoch", 16), ("scoreboardGeneration", 32),
        ("ackPsn", 24), ("sackBase", 24), ("outstandingCount", 16),
        ("holeCount", 16), ("sackValidBits", 16), ("nakValid", 1),
        ("nakCode", 7), ("nakPsn", 24), ("oooCount", 16),
        ("bitmap", 128), ("flags", 8), ("entryCount", 8),
    ],
    "AdmissionReqHw": [
        ("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
        ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("recordHandle", 32),
        ("expectedRequestId", 16), ("expectedPacketIndex", 18),
        ("reportGeneration", 32), ("triggerReason", 4), ("retryAttempt", 8),
    ],
    "AdmissionGrantHw": [
        ("ok", 1), ("status", 4), ("reason", 8), ("recordHandle", 32),
        ("replayHandle", 32), ("requestId", 16), ("packetIndex", 18),
        ("packetCount", 18), ("psn", 24), ("destQpn", 24), ("opcode", 8),
        ("pmtu", 3), ("remoteAddr", 64), ("remoteKey", 32),
        ("messageOffset", 25), ("payloadLength", 13), ("messageLength", 25),
        ("first", 1), ("last", 1), ("wireProfile", 2), ("evProfile", 2),
        ("mrcMsn", 16),
    ],
    "FetchReqHw": [
        ("fetchId", 16), ("replayHandle", 32), ("offset", 25),
        ("length", 13), ("token", 32),
    ],
    "FetchBeatHw": [
        ("fetchId", 16), ("data", 1024), ("keep", 128), ("sop", 1),
        ("eop", 1), ("valid", 1), ("last", 1),
    ],
    "RetryResultHw": [
        ("retryRequestId", 32), ("hostSessionId", 32), ("nicSessionId", 32),
        ("qpn", 24), ("qpEpoch", 16), ("psn", 24), ("status", 8),
        ("reason", 8), ("fetchId", 16), ("reportGeneration", 32),
        ("egressSequence", 32), ("resultSequence", 8),
    ],
    "RingCreditHw": [
        ("ringId", 8), ("slot", 8), ("consumerSequence", 32),
        ("objectIdentity", 32),
    ],
    "ReportTriggerHw": [
        ("qpn", 24), ("qpEpoch", 16), ("onDemand", 1), ("requestId", 32),
        ("triggerPsn", 24),
    ],
    "ReportWriteHdrHw": [
        ("txnId", 32), ("kind", 8), ("byteLength", 16), ("ringSlot", 8),
        ("reportGeneration", 32), ("qpn", 24), ("qpEpoch", 16),
        ("nicSessionId", 32), ("hostSessionId", 32),
    ],
    "OnDemandReqHw": [
        ("requestId", 32), ("qpn", 24), ("qpEpoch", 16),
        ("hostSessionId", 32), ("nicSessionId", 32),
        ("lastSeenReportGeneration", 32), ("reason", 8),
    ],
    "NotificationHw": [
        ("txnId", 32), ("ringSlot", 8), ("reportByteLength", 16),
        ("qpn", 24), ("qpEpoch", 16), ("reportGeneration", 32),
        ("nicSessionId", 32), ("hostSessionId", 32),
    ],
    "ReportBeatHw": [
        ("data", 512), ("keep", 64), ("sop", 1), ("eop", 1), ("beatIndex", 8),
    ],
    "ReplayDescHw": [
        ("qpn", 24), ("qpEpoch", 16), ("requestId", 16), ("psn", 24),
        ("packetIndex", 18), ("packetCount", 18), ("pmtu", 3), ("opcode", 8),
        ("remoteAddr", 64), ("remoteKey", 32), ("messageOffset", 25),
        ("payloadLength", 13), ("first", 1), ("last", 1), ("wireProfile", 2),
        ("evProfile", 2), ("mrcMsn", 16), ("replayHandle", 32),
    ],
    "ReplayBeatHw": [
        ("replayHandle", 32), ("data", 1024), ("keep", 128), ("sop", 1),
        ("eop", 1), ("last", 1), ("beatIndex", 8),
    ],
    "M3DescHw": [
        ("qpn", 24), ("destQpn", 24), ("qpEpoch", 16), ("requestId", 16),
        ("psn", 24), ("packetIndex", 18), ("packetCount", 18), ("pmtu", 3),
        ("opcode", 8), ("remoteAddr", 64), ("remoteKey", 32),
        ("messageOffset", 25), ("payloadLength", 13), ("messageLength", 25),
        ("first", 1), ("last", 1), ("wireProfile", 2),
        ("evProfile", 2), ("mrcMsn", 16),
    ],
    "M3BeatHw": [
        ("requestId", 16), ("psn", 24), ("data", 1024), ("keep", 128),
        ("sop", 1), ("eop", 1),
    ],
}


def validate_internal() -> None:
    for name, fields in INTERNAL_TYPES.items():
        seen = set()
        for field, width in fields:
            assert field not in seen, (name, field)
            assert width > 0, (name, field)
            seen.add(field)



def crc_field_name(name: str) -> str | None:
    for f, width, _ in OBJECTS[name]["fields"]:
        if f in CRC32_OBJECTS:
            return f
    return None


def validate() -> None:
    for name, spec in OBJECTS.items():
        occupied = 0
        total_bits = spec["size"] * 8
        for field, width, offset in spec["fields"]:
            assert offset >= 0 and width > 0, (name, field)
            assert offset + width <= total_bits, (name, field, offset + width, total_bits)
            mask = ((1 << width) - 1) << offset
            assert occupied & mask == 0, (name, field, "overlap")
            occupied |= mask
            if field in PARENT_WIDTHS:
                assert width == PARENT_WIDTHS[field], (name, field, width, PARENT_WIDTHS[field])
            if (name, field) in OBJECT_WIDTHS:
                assert width == OBJECT_WIDTHS[(name, field)], (name, field, width)
        assert total_bits % 8 == 0, (name, spec["size"])
    assert crc_field_name("ReportHeader") == "crc32"
    assert crc_field_name("RetryBatchHeader") == "header_crc32"
    assert crc_field_name("RetryEntry") == "entry_crc32"
