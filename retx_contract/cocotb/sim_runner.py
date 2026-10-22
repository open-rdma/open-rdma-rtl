#!/usr/bin/env python3
"""Cocotb launcher for the Retx ABI contract suite."""
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = ROOT / "cocotb"
MODULES = ("tests.test_contract",)


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
    parser.parse_args()
    simulator = os.getenv("SIM", "verilator")
    library = bsc_verilog_library()
    names = ("FIFO1.v", "FIFO2.v", "SizedFIFO.v", "RevertReg.v", "RegFile.v", "BRAM2.v")
    primitives = [library / n for n in names if (library / n).is_file()]
    verilog_dir = ROOT / "build" / "verilog"
    sources = [*primitives, *sorted(verilog_dir.glob("*.v"))]
    if not (verilog_dir / "mkRetxContractTb.v").is_file():
        raise RuntimeError("missing generated mkRetxContractTb.v")
    build_dir = ROOT / "build" / "cocotb" / simulator
    build_args = ["--Wno-fatal", "--timing"] if simulator == "verilator" else []
    runner = get_runner(simulator)
    original = sys.path.copy()
    try:
        sys.path[:0] = [str(COCOTB_ROOT), str(ROOT / "python")]
        runner.build(sources=sources, hdl_toplevel="mkRetxContractTb",
                     build_args=build_args, build_dir=build_dir, always=True,
                     timescale=("1ns", "1ps"), waves=False)
        runner.test(test_module=MODULES, hdl_toplevel="mkRetxContractTb",
                    build_dir=build_dir, test_dir=build_dir,
                    extra_env=dict(os.environ), results_xml="results-short.xml",
                    waves=False)
    finally:
        sys.path[:] = original


if __name__ == "__main__":
    main()
