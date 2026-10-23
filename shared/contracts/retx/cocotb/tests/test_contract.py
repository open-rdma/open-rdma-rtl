"""Retx ABI v1 contract tests: BSV/Python byte equality and field validation."""
from __future__ import annotations

import json
import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from openrdma_flow.retx.codec import (SCHEMA, decode, encode, validate_report,
                        validate_retry_batch)

GENERATED_ROOT = Path(os.environ["RETX_GENERATED_DIR"])
VECTORS = json.loads((GENERATED_ROOT / "golden" / "vectors.json").read_text())

CASES = {
    "ReportHeader": ("report", "setReportHeader", "getReportHeader"),
    "HoleEntry": ("hole", "setHoleEntry", "getHoleEntry"),
    "RetryBatchHeader": ("retry_header", "setRetryBatchHeader", "getRetryBatchHeader"),
    "RetryEntry": ("retry_entry", "setRetryEntry", "getRetryEntry"),
    "RetryResult": ("result", "setRetryResult", "getRetryResult"),
    "OnDemandRequest": ("ondemand", "setOnDemandRequest", "getOnDemandRequest"),
    "Notification": ("notification", "setNotification", "getNotification"),
    "RingCredit": ("credit", "setRingCredit", "getRingCredit"),
}


def defaults(name: str) -> dict:
    return {f: 0 for f, _, _ in SCHEMA[name]["fields"]}


async def reset(dut) -> None:
    dut.RST_N.value = 0
    await RisingEdge(dut.CLK)
    await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    await RisingEdge(dut.CLK)


async def drive(dut, setter: str, value: int) -> None:
    getattr(dut, f"{setter}_v").value = value
    getattr(dut, f"EN_{setter}").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{setter}").value = 0
    await RisingEdge(dut.CLK)


@cocotb.test()
async def test_known_vectors_roundtrip(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    for bsv_name, (key, setter, getter) in CASES.items():
        values = defaults(bsv_name)
        values.update(VECTORS["objects"].get(bsv_name, {}).get("fields", {}) or {})
        data = encode(bsv_name, values)
        await drive(dut, setter, int.from_bytes(data, "little"))
        out = int(getattr(dut, getter).value)
        assert out == int.from_bytes(data, "little"), bsv_name
        back = decode(bsv_name, out.to_bytes(len(data), "little"))
        for field, _, _ in SCHEMA[bsv_name]["fields"]:
            if field.startswith("reserved") or field.endswith("crc32"):
                continue
            assert back[field] == values.get(field, 0), (bsv_name, field)


@cocotb.test()
async def test_random_fields_match_python(dut):
    cocotb.start_soon(Clock(dut.CLK, 2, unit="ns").start())
    await reset(dut)
    rng = random.Random(20261022)
    for bsv_name, (_, setter, getter) in CASES.items():
        for _ in range(8):
            values = defaults(bsv_name)
            for field, width, _ in SCHEMA[bsv_name]["fields"]:
                if field.startswith("reserved") or field in {
                        "crc32", "header_crc32", "entry_crc32"}:
                    continue
                values[field] = rng.randrange(1 << width)
            if bsv_name == "ReportHeader":
                values["byte_length"] = 64 + 40 * (values["hole_entries_included"] % 17)
            elif bsv_name == "RetryBatchHeader":
                values["byte_length"] = 16 + 40 * (values["entry_count"] % 9)
            data = encode(bsv_name, values)
            await drive(dut, setter, int.from_bytes(data, "little"))
            out = int(getattr(dut, getter).value)
            assert out == int.from_bytes(data, "little"), (bsv_name, values)


@cocotb.test()
async def test_crc_rejects_corruption(dut):
    values = dict(VECTORS["objects"]["ReportHeader"]["fields"])
    data = bytearray(encode("ReportHeader", values))
    data[20] ^= 0x01
    try:
        decode("ReportHeader", bytes(data))
    except ValueError as exc:
        assert "crc" in str(exc)
    else:
        raise AssertionError("corrupted report accepted")


@cocotb.test()
async def test_report_coverage_and_truncation(dut):
    base = dict(VECTORS["objects"]["ReportHeader"]["fields"])
    bad = dict(base, sack_valid_bits=16)
    try:
        validate_report(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("wide valid_bits accepted")

    bad = dict(base, sack_bitmap=1 << 15)
    try:
        validate_report(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("out-of-coverage bitmap accepted")

    trunc = dict(base, hole_count=2, hole_entries_included=1)
    out = validate_report(trunc)
    assert out["flags"] & (1 << 4), "TRUNCATED flag not set"


@cocotb.test()
async def test_retry_batch_rejects_duplicate(dut):
    entry = dict(VECTORS["objects"]["RetryEntry"]["fields"])
    header = dict(VECTORS["objects"]["RetryBatchHeader"]["fields"],
                  entry_count=2, byte_length=96)
    try:
        validate_retry_batch(header, [entry, dict(entry)])
    except ValueError as exc:
        assert "duplicate" in str(exc)
    else:
        raise AssertionError("duplicate request identity accepted")


@cocotb.test()
async def test_golden_vectors_are_stable(dut):
    for name, item in VECTORS["objects"].items():
        values = defaults(name)
        values.update(item["fields"])
        data = encode(name, values)
        back = decode(name, data)
        for field, _, _ in SCHEMA[name]["fields"]:
            if field.startswith("reserved") or field.endswith("crc32"):
                continue
            assert back[field] == values.get(field, 0), (name, field)
        assert encode(name, back) == data, name
