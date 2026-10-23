"""在隔离仿真进程中执行 expected-fatal 用例。"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from openrdma_flow_tb.sim.runner import load_config


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    target = load_config(args.config.resolve()).TARGETS[args.target]
    cases = target.get("negative_cases", {})
    case_env = target["negative_case_env"]
    sentinel_prefix = target["negative_sentinel_prefix"]
    failures: list[str] = []

    for case, marker in cases.items():
        env = dict(os.environ)
        env[case_env] = case
        env.pop("COCOTB_TEST_FILTER", None)
        completed = subprocess.run(
            [
                sys.executable,
                "-m",
                "openrdma_flow_tb.sim.runner",
                "--project-root",
                str(project_root),
                "--config",
                str(args.config.resolve()),
                "--target",
                args.target,
                "--suite",
                "negative",
            ],
            cwd=project_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        sentinel = f"{sentinel_prefix}{case}"
        if marker not in completed.stdout or sentinel in completed.stdout:
            failures.append(case)
            print(f"失败 {case}: 未观察到期望标记 {marker}")
            print(completed.stdout)
        else:
            print(f"通过 {case}: {marker}")

    if failures:
        print(f"expected-fatal 失败: {', '.join(failures)}")
        return 1
    print(f"全部 {len(cases)} 个 expected-fatal 用例通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
