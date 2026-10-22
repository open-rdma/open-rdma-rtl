#!/usr/bin/env python3
"""retx_integration preflight: fail before any BSC/Python compile on drift."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def check_same(name: str, authority: Path, copies: list[Path]) -> list[str]:
    errors = []
    if not authority.is_file():
        return [f"{name}: missing authority {authority}"]
    base = authority.read_bytes()
    for copy in copies:
        if not copy.is_file():
            errors.append(f"{name}: missing copy {copy}")
        elif copy.read_bytes() != base:
            errors.append(f"{name}: {copy} diverged from {authority}")
    return errors


def main() -> int:
    errors: list[str] = []
    retx_auth = ROOT / "retx_contract" / "src" / "RetxTypes.bsv"
    common_auth = ROOT / "m0" / "src" / "CommonTypes.bsv"
    errors += check_same("RetxTypes", retx_auth, [
        ROOT / d / "src" / "RetxTypes.bsv" for d in ("m9", "m10", "m11")])
    errors += check_same("CommonTypes", common_auth, [
        ROOT / d / "src" / "CommonTypes.bsv" for d in ("m9", "m10", "m11")])

    manifest_path = ROOT / "retx_contract" / "manifest.json"
    if not manifest_path.is_file():
        errors.append("manifest.json missing")
    else:
        manifest = json.loads(manifest_path.read_text())
        for rel, expected in manifest["files"].items():
            path = ROOT / "retx_contract" / rel
            if not path.is_file():
                errors.append(f"manifest: missing {rel}")
                continue
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != expected:
                errors.append(f"manifest: {rel} hash mismatch")

    if errors:
        print("retx_integration preflight FAILED")
        for err in errors:
            print(f"  - {err}")
        return 2
    print("retx_integration preflight OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
