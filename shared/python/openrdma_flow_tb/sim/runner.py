"""所有 OpenRDMA-flow cocotb 目标共用的仿真启动器。"""
from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import sys
from pathlib import Path
from types import ModuleType

from cocotb_tools.runner import get_runner

PRIMITIVES = (
    "FIFO1.v",
    "FIFO2.v",
    "SizedFIFO.v",
    "RevertReg.v",
    "RegFile.v",
    "BRAM2.v",
)


def load_config(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("openrdma_flow_sim_config", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载仿真配置: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bsc_verilog_library() -> Path:
    executable = shutil.which(os.getenv("BSC", "bsc"))
    if executable is None:
        raise RuntimeError("配置的 BSC 不可执行")
    library = Path(executable).resolve().parent.parent / "lib" / "Verilog"
    if not library.is_dir():
        raise RuntimeError(f"无法定位 BSC Verilog 库: {library}")
    return library


def enabled(value: str | None) -> bool:
    return value is not None and value.lower() not in {"", "0", "false", "no"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--suite", choices=("short", "long", "negative"), default="short")
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    config_module = load_config(args.config.resolve())
    targets = config_module.TARGETS
    if args.target not in targets:
        raise RuntimeError(f"未知仿真目标 {args.target}; 可用目标: {', '.join(targets)}")
    target = targets[args.target]

    module_key = f"{args.suite}_modules"
    modules = tuple(target.get(module_key, ()))
    if not modules:
        raise RuntimeError(f"目标 {args.target} 未实现 {args.suite} suite")

    simulator = os.getenv("SIM", "verilator")
    library = bsc_verilog_library()
    primitive_names = tuple(target.get("primitives", PRIMITIVES))
    primitives = [library / name for name in primitive_names if (library / name).is_file()]
    verilog_dir = project_root / target.get("verilog_dir", "build/verilog")
    hdl_toplevel = target["hdl_toplevel"]
    top_source = verilog_dir / f"{hdl_toplevel}.v"
    if not top_source.is_file():
        raise RuntimeError(f"缺少生成的顶层 Verilog: {top_source}")

    build_leaf = simulator
    negative_case_env = target.get("negative_case_env")
    if args.suite == "negative" and negative_case_env:
        build_leaf = f"{simulator}-negative-{os.environ.get(negative_case_env, 'unset')}"
    cocotb_dir = project_root / target.get("cocotb_dir", "build/cocotb") / build_leaf
    waves = enabled(os.getenv("WAVES")) or bool(target.get("waves", False))
    build_args = ["--Wno-fatal", "--timing"] if simulator == "verilator" else []

    extra_env = dict(os.environ)
    suite_env = target.get("suite_env")
    if suite_env:
        extra_env[suite_env] = args.suite
    if args.suite == "long":
        for name, value in target.get("long_env", {}).items():
            extra_env.setdefault(name, value)

    cocotb_root = project_root / "cocotb"
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(cocotb_root))
        runner = get_runner(simulator)
        runner.build(
            sources=[*primitives, *sorted(verilog_dir.glob("*.v"))],
            hdl_toplevel=hdl_toplevel,
            build_args=build_args,
            build_dir=cocotb_dir,
            always=True,
            timescale=("1ns", "1ps"),
            waves=waves,
        )
        case = os.environ.get(negative_case_env, "all") if negative_case_env else "all"
        result_name = (
            f"results-{args.target}-{args.suite}-{case}.xml"
            if args.suite == "negative"
            else f"results-{args.target}-{args.suite}.xml"
        )
        runner.test(
            test_module=modules,
            hdl_toplevel=hdl_toplevel,
            build_dir=cocotb_dir,
            test_dir=cocotb_dir,
            extra_env=extra_env,
            results_xml=result_name,
            waves=waves,
        )
    finally:
        sys.path[:] = original_path


if __name__ == "__main__":
    main()
