#!/usr/bin/env python3
"""校验 shared Python 唯一来源和 import 实际落点。"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path


def module_origin(name: str) -> Path:
    spec = importlib.util.find_spec(name)
    if spec is None or spec.origin is None:
        raise RuntimeError(f"无法解析 Python module: {name}")
    return Path(spec.origin).resolve()


def main() -> int:
    root = Path(__file__).resolve().parent.parent.parent
    expected = {
        "openrdma_flow_tb.cocotb_bsv": root / "shared/python/openrdma_flow_tb/cocotb_bsv/__init__.py",
        "openrdma_flow_tb.common": root / "shared/python/openrdma_flow_tb/common.py",
        "openrdma_flow_tb.tx.model.m2": root / "shared/python/openrdma_flow_tb/tx/model/m2.py",
        "openrdma_flow_tb.tx.model.m3": root / "shared/python/openrdma_flow_tb/tx/model/m3.py",
        "openrdma_flow_tb.tx.model.dma_phasea": root / "shared/python/openrdma_flow_tb/tx/model/dma_phasea.py",
        "openrdma_flow_tb.tx.bfm.m2": root / "shared/python/openrdma_flow_tb/tx/bfm/m2.py",
        "openrdma_flow_tb.tx.bfm.m3": root / "shared/python/openrdma_flow_tb/tx/bfm/m3.py",
        "openrdma_flow_tb.rx.model.types": root / "shared/python/openrdma_flow_tb/rx/model/types.py",
        "openrdma_flow_tb.rx.model.wire": root / "shared/python/openrdma_flow_tb/rx/model/wire.py",
        "openrdma_flow_tb.rx.bfm.common": root / "shared/python/openrdma_flow_tb/rx/bfm/common.py",
        "openrdma_flow_tb.retx.layouts": root / "shared/python/openrdma_flow_tb/retx/layouts.py",
        "openrdma_flow_tb.retx.bfm": root / "shared/python/openrdma_flow_tb/retx/bfm.py",
        "openrdma_flow_tb.sim.runner": root / "shared/python/openrdma_flow_tb/sim/runner.py",
        "openrdma_flow_tb.sim.expected_fatal": root / "shared/python/openrdma_flow_tb/sim/expected_fatal.py",
        "openrdma_flow.retx.codec": root / "shared/generated/retx/python/openrdma_flow/retx/codec.py",
    }
    errors: list[str] = []
    for module, path in expected.items():
        try:
            actual = module_origin(module)
        except RuntimeError as exc:
            errors.append(str(exc))
            continue
        if actual != path.resolve():
            errors.append(f"{module} 来自 {actual}，期望 {path}")

    excluded = {"reference", "build", "_bmad-output", ".archify"}
    forbidden_import = re.compile(
        r"^(?:from|import) (?:cocotb_bsv|model\.(?:common|m2|m3|rx_types|wire)|"
        r"bfm\.(?:m2|m3|common)|dma_phasea_model|retx_codec)(?:\s|\.|$)",
        re.MULTILINE,
    )
    for path in root.rglob("*.py"):
        relative = path.relative_to(root)
        if any(part in excluded for part in relative.parts):
            continue
        if forbidden_import.search(path.read_text(encoding="utf-8")):
            errors.append(f"遗留 bare import: {relative}")

    legacy_mirrors = []
    for path in root.glob("m*_*/cocotb/lib/cocotb_bsv"):
        if any(path.glob("*.py")):
            legacy_mirrors.append(path)
    for path in root.glob("integrations/*/cocotb/lib/cocotb_bsv"):
        if any(path.glob("*.py")):
            legacy_mirrors.append(path)
    errors.extend(f"遗留 cocotb_bsv 镜像: {p.relative_to(root)}" for p in legacy_mirrors)

    mirror_names = {"common.py", "m2.py", "m3.py", "rx_types.py", "wire.py"}
    for pattern in ("m*_*/cocotb/model", "m*_*/cocotb/bfm", "integrations/*/cocotb/model", "integrations/*/cocotb/bfm"):
        for directory in root.glob(pattern):
            for path in directory.glob("*.py"):
                if path.name in mirror_names:
                    errors.append(f"遗留 Python shared 镜像: {path.relative_to(root)}")

    if errors:
        print("Python shared import 门禁失败")
        for error in errors:
            print(f"  - {error}")
        return 2
    print("Python shared import 门禁通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
