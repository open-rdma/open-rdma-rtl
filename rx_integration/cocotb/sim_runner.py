#!/usr/bin/env python3
"""Cocotb launcher for the RX integration suites."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

from cocotb_tools.runner import get_runner


@dataclass(frozen=True)
class TargetConfig:
    hdl_toplevel: str
    test_modules: tuple[str, ...]


TARGETS = {
    "rx_top": TargetConfig(
        hdl_toplevel="mkTestRxTop",
        test_modules=("tests.test_rx_top",),
    ),
    "tx_rx_loopback": TargetConfig(
        hdl_toplevel="mkTestTxRxLoopback",
        test_modules=("tests.test_tx_rx_loopback",),
    ),
}

ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = ROOT / "cocotb"


def bsc_verilog_library() -> Path:
    executable = shutil.which(os.getenv("BSC", "bsc"))
    if executable is None:
        raise RuntimeError("configured BSC is not executable")
    library = Path(executable).resolve().parent.parent / "lib" / "Verilog"
    if not library.is_dir():
        raise RuntimeError(f"cannot locate BSC Verilog library: {library}")
    return library


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--suite", choices=("short", "long"), default="short")
    args = parser.parse_args()

    target = TARGETS[args.target]
    simulator = os.getenv("SIM", "verilator")
    library = bsc_verilog_library()
    primitive_names = (
        "FIFO1.v",
        "FIFO2.v",
        "SizedFIFO.v",
        "RevertReg.v",
        "RegFile.v",
        "BRAM2.v",
    )
    primitives = [library / name for name in primitive_names if (library / name).is_file()]
    verilog_dir = ROOT / "build" / args.target / "verilog"
    top_source = verilog_dir / f"{target.hdl_toplevel}.v"
    generated = sorted(verilog_dir.glob("*.v"))
    if not top_source.is_file():
        raise RuntimeError(f"missing generated top-level Verilog: {top_source}")

    build_dir = ROOT / "build" / args.target / "cocotb" / simulator
    build_args = ["--Wno-fatal", "--timing"] if simulator == "verilator" else []
    extra_env = dict(os.environ)
    extra_env["RX_MVP_SUITE"] = args.suite
    runner = get_runner(simulator)

    original_path = sys.path.copy()
    try:
        sys.path[:0] = [str(COCOTB_ROOT), str(COCOTB_ROOT / "lib")]
        runner.build(
            sources=[*primitives, *generated],
            hdl_toplevel=target.hdl_toplevel,
            build_args=build_args,
            build_dir=build_dir,
            always=True,
            timescale=("1ns", "1ps"),
            waves=False,
        )
        runner.test(
            test_module=target.test_modules,
            hdl_toplevel=target.hdl_toplevel,
            build_dir=build_dir,
            test_dir=build_dir,
            extra_env=extra_env,
            results_xml=f"results-{args.target}-{args.suite}.xml",
            waves=False,
        )
    finally:
        sys.path[:] = original_path


if __name__ == "__main__":
    main()
