#!/usr/bin/env python3
"""Cocotb launcher for the RX M7 DMA Placement unit suite."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = ROOT / "cocotb"
HDL_TOPLEVEL = "mkTestRxDmaPlacement"
TEST_MODULES = ("tests.m7.test_dma_placement",)


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
    parser.add_argument("--suite", choices=("short", "long"), default="short")
    args = parser.parse_args()

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
    verilog_dir = ROOT / "build" / "verilog"
    top_source = verilog_dir / f"{HDL_TOPLEVEL}.v"
    generated = sorted(verilog_dir.glob("*.v"))
    if not top_source.is_file():
        raise RuntimeError(f"missing generated top-level Verilog: {top_source}")

    build_dir = ROOT / "build" / "cocotb" / simulator
    build_args = ["--Wno-fatal", "--timing"] if simulator == "verilator" else []
    extra_env = dict(os.environ)
    extra_env["RX_MVP_SUITE"] = args.suite
    cocotb_runner = get_runner(simulator)

    original_path = sys.path.copy()
    try:
        sys.path[:0] = [str(COCOTB_ROOT), str(COCOTB_ROOT / "lib")]
        cocotb_runner.build(
            sources=[*primitives, *generated],
            hdl_toplevel=HDL_TOPLEVEL,
            build_args=build_args,
            build_dir=build_dir,
            always=True,
            timescale=("1ns", "1ps"),
            waves=False,
        )
        cocotb_runner.test(
            test_module=TEST_MODULES,
            hdl_toplevel=HDL_TOPLEVEL,
            build_dir=build_dir,
            test_dir=build_dir,
            extra_env=extra_env,
            results_xml=f"results-{args.suite}.xml",
            waves=False,
        )
    finally:
        sys.path[:] = original_path


if __name__ == "__main__":
    main()
