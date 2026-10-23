#!/usr/bin/env python3
"""OpenRDMA-flow active tree 的统一静态门禁。"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


EXCLUDED_PARTS = {"reference", "build", "_bmad-output", ".archify", ".git"}
EXPECTED_PACKAGES = {
    "CommonTypes": "shared/bsv/common/CommonTypes.bsv",
    "TxTypes": "shared/bsv/tx/TxTypes.bsv",
    "RxTypes": "shared/bsv/rx/RxTypes.bsv",
    "RetxTypes": "shared/generated/retx/bsv/RetxTypes.bsv",
}
OLD_DIRS = [*(f"m{i}" for i in range(12)), "integration", "rx_integration", "retx_integration", "retx_contract"]


def active(path: Path, root: Path) -> bool:
    return not any(part in EXCLUDED_PARTS for part in path.relative_to(root).parts)


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> list[str]:
    completed = subprocess.run(
        command, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    if completed.returncode == 0:
        return []
    return [completed.stdout.strip() or f"命令失败: {' '.join(command)}"]


def main() -> int:
    root = Path(__file__).resolve().parent.parent.parent
    errors: list[str] = []

    for directory in OLD_DIRS:
        if (root / directory).exists():
            errors.append(f"遗留旧目录: {directory}")

    declarations: dict[str, list[Path]] = {name: [] for name in EXPECTED_PACKAGES}
    package_re = re.compile(r"^package\s+(\w+)\s*;", re.MULTILINE)
    for path in root.rglob("*.bsv"):
        if not active(path, root):
            continue
        match = package_re.search(path.read_text(encoding="utf-8"))
        if match and match.group(1) in declarations:
            declarations[match.group(1)].append(path.relative_to(root))
    for package, expected in EXPECTED_PACKAGES.items():
        found = declarations[package]
        if found != [Path(expected)]:
            errors.append(f"{package} 定义应唯一位于 {expected}，实际为 {[str(p) for p in found]}")

    for module in root.glob("m*_*"):
        for name in ("CommonTypes.bsv", "TxTypes.bsv", "RxTypes.bsv", "RetxTypes.bsv"):
            if (module / "src" / name).exists():
                errors.append(f"模块内遗留类型镜像: {(module / 'src' / name).relative_to(root)}")

    import_check = root / "shared/tools/check_imports.py"
    errors += run([sys.executable, str(import_check)], cwd=root)
    generator = root / "shared/contracts/retx/tools/generate.py"
    errors += run([sys.executable, str(generator), "--check"], cwd=root)

    registry = root / "shared/make/modules.mk"
    for match in re.finditer(r"^M\d+_DIR_NAME := (.+)$", registry.read_text(encoding="utf-8"), re.MULTILINE):
        if not (root / match.group(1).strip()).is_dir():
            errors.append(f"registry 指向不存在的目录: {match.group(1).strip()}")
    for name in ("tx", "rx", "retx"):
        if not (root / "integrations" / name).is_dir():
            errors.append(f"缺少 integration 目录: integrations/{name}")

    baseline = root / "reference/rx-mvp-legacy/upstream/BASELINE.sha256"
    if not baseline.is_file():
        errors.append("缺少归档校验清单 reference/rx-mvp-legacy/upstream/BASELINE.sha256")
    else:
        errors += run(["sha256sum", "-c", baseline.name], cwd=baseline.parent)

    if errors:
        print("OpenRDMA-flow preflight 失败")
        for error in errors:
            print(f"  - {error}")
        return 2
    print("OpenRDMA-flow preflight 通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
