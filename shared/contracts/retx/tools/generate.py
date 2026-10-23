#!/usr/bin/env python3
"""Deterministic generator for Retx ABI v1 artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

CONTRACT_ROOT = Path(__file__).resolve().parent.parent


def find_flow_root(start: Path) -> Path:
    for candidate in (start, *start.parents):
        if (candidate / "shared/make/modules.mk").is_file():
            return candidate
    raise RuntimeError("无法定位 OpenRDMA-flow 根目录")


FLOW_ROOT = find_flow_root(CONTRACT_ROOT)
GENERATED_ROOT = FLOW_ROOT / "shared/generated/retx"
sys.path.insert(0, str(CONTRACT_ROOT))

from schema import INTERNAL_TYPES, OBJECTS, validate, validate_internal  # noqa: E402


def bsv_types() -> str:
    lines = ["package RetxTypes;", "", "// 由 shared/contracts/retx/tools/generate.py 生成，禁止手工修改。", ""]
    for name, spec in OBJECTS.items():
        lines.append(f"typedef struct {{")
        for field, width, _ in spec["fields"]:
            lines.append(f"    Bit#({width}) {field};")
        lines.append(f"}} Retx{name} deriving(Bits, Eq, FShow);")
        lines.append("")
    for name, spec in OBJECTS.items():
        total = spec["size"] * 8
        lines.append(f"function Bit#({total}) retxPack{name}(Retx{name} x);")
        expr = []
        for field, width, offset in spec["fields"]:
            shift = f" << {offset}" if offset else ""
            expr.append(f"zeroExtend(x.{field}){shift}")
        lines.append("    return " + "\n        | ".join(expr) + ";")
        lines.append("endfunction")
        lines.append("")
        lines.append(f"function Retx{name} retxUnpack{name}(Bit#({total}) v);")
        lines.append(f"    Retx{name} x = unpack(0);")
        for field, width, offset in spec["fields"]:
            shift = f" >> {offset}" if offset else ""
            lines.append(f"    x.{field} = truncate(v{shift});")
        lines.append("    return x;")
        lines.append("endfunction")
        lines.append("")
    lines.append("// Internal seam types (BSV-only; no host byte layout).")
    for name, fields in INTERNAL_TYPES.items():
        lines.append("typedef struct {")
        for field, width in fields:
            lines.append(f"    Bit#({width}) {field};")
        lines.append(f"}} Retx{name} deriving(Bits, Eq, FShow);")
        lines.append("")
    lines.append("endpackage")
    return "\n".join(lines) + "\n"


def bsv_tb() -> str:
    lines = ["package RetxContractTb;", "", 'import RetxTypes::*;', ""]
    lines.append("interface RetxContractTbIfc;")
    for name, spec in OBJECTS.items():
        total = spec["size"] * 8
        lines.append(f"    method Action set{name}(Bit#({total}) v);")
        lines.append(f"    method Bit#({total}) get{name};")
    lines.append("endinterface")
    lines.append("")
    lines.append("(* synthesize *)")
    lines.append("module mkRetxContractTb(RetxContractTbIfc);")
    for name, spec in OBJECTS.items():
        total = spec["size"] * 8
        lines.append(f"    Reg#(Bit#({total})) {name[0].lower() + name[1:]}Reg <- mkReg(0);")
    for name, spec in OBJECTS.items():
        total = spec["size"] * 8
        reg = name[0].lower() + name[1:] + "Reg"
        lines.append(f"    method Action set{name}(Bit#({total}) v);")
        lines.append(f"        {reg} <= v;")
        lines.append("    endmethod")
        lines.append(f"    method Bit#({total}) get{name} = retxPack{name}(retxUnpack{name}({reg}));")
    lines.append("endmodule")
    lines.append("")
    lines.append("endpackage")
    return "\n".join(lines) + "\n"


PY_HEADER = '''"""由 Retx ABI v1 schema 生成，禁止手工修改。"""
from __future__ import annotations

import binascii

SCHEMA = {schema}
CRC_FIELDS = {crc_fields}


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _encode_raw(name: str, values: dict) -> bytearray:
    spec = SCHEMA[name]
    packed = 0
    for field, width, offset in spec["fields"]:
        value = int(values.get(field, 0))
        if value < 0 or value >= (1 << width):
            raise ValueError(f"{{name}}.{{field}} out of range")
        packed |= value << offset
    return bytearray(packed.to_bytes(spec["size"], "little"))


def encode(name: str, values: dict) -> bytes:
    spec = SCHEMA[name]
    crc_field = CRC_FIELDS.get(name)
    if not crc_field:
        return bytes(_encode_raw(name, values))
    data = _encode_raw(name, dict(values, **{{crc_field: 0}}))
    field, width, offset = next(f for f in spec["fields"] if f[0] == crc_field)
    crc = _crc32(bytes(data))
    raw = int.from_bytes(data, "little")
    raw |= crc << offset
    return raw.to_bytes(spec["size"], "little")


def decode(name: str, data: bytes, check_crc: bool = True) -> dict:
    spec = SCHEMA[name]
    if len(data) != spec["size"]:
        raise ValueError(f"{{name}} length {{len(data)}} != {{spec['size']}}")
    raw = int.from_bytes(data, "little")
    values = {{}}
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
                raise ValueError(f"{{name}} crc mismatch")
    return values


def _require_zero(name: str, values: dict) -> None:
    for field, width, _ in SCHEMA[name]["fields"]:
        if field.startswith("reserved") and values.get(field, 0) != 0:
            raise ValueError(f"{{name}}.{{field}} must be zero")


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
'''

PY_FOOTER = '''

def field_width(name: str, field: str) -> int:
    return next(w for f, w, _ in SCHEMA[name]["fields"] if f == field)
'''


def py_codec() -> str:
    crc_fields = {}
    for name, spec in OBJECTS.items():
        for field, width, _ in spec["fields"]:
            if field in {"crc32", "header_crc32", "entry_crc32"}:
                crc_fields[name] = field
    # Emit plain Python literals (repr of nested dict is deterministic here).
    schema_src = repr(OBJECTS)
    return PY_HEADER.format(schema=schema_src, crc_fields=repr(crc_fields)) + PY_FOOTER


def vectors() -> dict:
    return {
        "report": {
            "version": 1, "flags": 3, "byte_length": 104, "qpn": 0x123456,
            "qp_epoch": 7, "sack_valid_bits": 4, "report_generation": 11,
            "scoreboard_generation": 9, "nic_session_id": 0x0BADF00D,
            "ack_psn": 100, "sack_base": 101, "outstanding_base": 101,
            "nak_psn": 0, "outstanding_count": 4, "ooo_count": 3,
            "hole_count": 1, "hole_entries_included": 1,
            "nak_valid_and_code": 0, "sack_bitmap": 0b1010,
        },
        "hole": {
            "psn": 101, "record_handle": 0x00000007, "request_id": 42,
            "packet_index": 1, "packet_count": 4, "message_offset": 512,
            "payload_length": 256, "remote_addr": 0x1122334455667788,
            "remote_key": 0xCAFEBABE, "opcode": 0x0A, "pmtu": 2,
            "slot_id": 3, "wire_profile": 0, "ev_profile": 0,
            "mrc_msn": 0, "msn_valid": 0, "is_first": 0, "is_last": 0,
        },
        "retry_header": {
            "version": 1, "flags": 1, "byte_length": 56,
            "nic_session_id": 0x0BADF00D, "entry_count": 1,
        },
        "retry_entry": {
            "retry_request_id": 5, "host_session_id": 0x1234, "qpn": 0x123456,
            "trigger_reason": 2, "qp_epoch": 7, "retry_attempt": 0,
            "psn": 101, "record_handle": 7, "report_generation": 11,
            "expected_request_id": 42, "expected_packet_index": 1,
        },
        "result": {
            "version": 1, "status": 2, "byte_length": 40,
            "retry_request_id": 5, "host_session_id": 0x1234,
            "nic_session_id": 0x0BADF00D, "qpn": 0x123456,
            "reason_code": 0, "qp_epoch": 7, "fetch_id": 3, "psn": 101,
            "result_sequence": 1, "report_generation": 11, "egress_sequence": 9,
        },
        "ondemand": {
            "version": 1, "reason": 2, "byte_length": 32, "request_id": 8,
            "qpn": 0x123456, "qp_epoch": 7, "host_session_id": 0x1234,
            "nic_session_id": 0x0BADF00D, "last_seen_report_generation": 10,
        },
        "notification": {
            "version": 1, "byte_length": 32, "ring_slot": 3,
            "report_byte_length": 104, "qpn": 0x123456, "qp_epoch": 7,
            "report_generation": 11, "nic_session_id": 0x0BADF00D,
            "host_session_id": 0x1234,
        },
        "credit": {
            "version": 1, "ring_id": 1, "slot": 3, "consumer_sequence": 11,
            "object_identity": 0x0099,
        },
    }


def golden() -> dict:
    vec = vectors()
    out = {"schema_version": 1, "objects": {}}
    checks = {
        "ReportHeader": vec["report"], "HoleEntry": vec["hole"],
        "RetryBatchHeader": vec["retry_header"], "RetryEntry": vec["retry_entry"],
        "RetryResult": vec["result"], "OnDemandRequest": vec["ondemand"],
        "Notification": vec["notification"], "RingCredit": vec["credit"],
    }
    for name, values in checks.items():
        # Fill required length fields from schema defaults when absent.
        if name == "ReportHeader":
            values = dict(values, byte_length=64 + 40 * values["hole_entries_included"])
        out["objects"][name] = {"fields": values}
    return out


def generated_outputs() -> dict[Path, str]:
    vec = golden()
    return {
        GENERATED_ROOT / "bsv/RetxTypes.bsv": bsv_types(),
        GENERATED_ROOT / "tb/RetxContractTb.bsv": bsv_tb(),
        GENERATED_ROOT / "python/openrdma_flow/__init__.py":
            '"""OpenRDMA-flow production Python 包。"""\n',
        GENERATED_ROOT / "python/openrdma_flow/retx/__init__.py":
            '"""Retx ABI codec。"""\n',
        GENERATED_ROOT / "python/openrdma_flow/retx/codec.py": py_codec(),
        GENERATED_ROOT / "golden/vectors.json":
            json.dumps(vec, indent=2, sort_keys=True) + "\n",
    }


def manifest_text(outputs: dict[Path, str]) -> str:
    files = {
        str((CONTRACT_ROOT / "schema.py").relative_to(FLOW_ROOT)):
            hashlib.sha256((CONTRACT_ROOT / "schema.py").read_bytes()).hexdigest(),
        str(Path(__file__).resolve().relative_to(FLOW_ROOT)):
            hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    for output, content in outputs.items():
        files[str(output.relative_to(FLOW_ROOT))] = hashlib.sha256(
            content.encode("utf-8")
        ).hexdigest()
    return json.dumps(
        {"schema_version": 1, "files": files}, indent=2, sort_keys=True
    ) + "\n"


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def check(path: Path, expected: str) -> str | None:
    if not path.is_file():
        return f"缺少生成物 {path.relative_to(FLOW_ROOT)}"
    if path.read_text(encoding="utf-8") != expected:
        return f"生成物漂移 {path.relative_to(FLOW_ROOT)}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    validate()
    validate_internal()
    outputs = generated_outputs()
    manifest_path = GENERATED_ROOT / "manifest.json"
    manifest = manifest_text(outputs)

    if args.check:
        errors = [error for path, content in outputs.items()
                  if (error := check(path, content))]
        if error := check(manifest_path, manifest):
            errors.append(error)
        if errors:
            for error in errors:
                print(error)
            return 2
        print("Retx 生成物校验通过")
        return 0

    for output, content in outputs.items():
        write(output, content)
    write(manifest_path, manifest_text(outputs))
    print("Retx 生成物已更新")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
