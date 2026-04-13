#!/usr/bin/env python
"""
Verilator compilation script for RDMA RTL (without hard IP).
This script only compiles the design with Verilator and does not run tests.
"""
import os
import sys
import cocotb_test.simulator
from test_framework.common import (
    cocotb_extra_env,
    copy_mem_file_to_sim_build_dir,
    gen_rtl_file_list,
)


def compile_verilator():
    """
    Compile the RTL design using Verilator.

    Environment variables required:
    - COCOTB_VERILOG_DIR: Colon-separated paths to RTL directories
    - COCOTB_DUT: Top-level module name
    """
    rtl_dirs = os.getenv("COCOTB_VERILOG_DIR")
    dut = os.getenv("COCOTB_DUT")

    if not rtl_dirs:
        print("Error: COCOTB_VERILOG_DIR environment variable is not set")
        sys.exit(1)
    if not dut:
        print("Error: COCOTB_DUT environment variable is not set")
        sys.exit(1)

    tests_dir = os.path.dirname(__file__)
    sim_build = os.path.join(tests_dir, "sim_build", dut)

    print(f"Compiling {dut} with Verilator...")
    print(f"RTL directories: {rtl_dirs}")
    print(f"Build directory: {sim_build}")

    # Generate RTL file list
    verilog_sources = gen_rtl_file_list(rtl_dirs)
    print(f"Found {len(verilog_sources)} RTL files")

    # Copy memory initialization files to build directory
    copy_mem_file_to_sim_build_dir(rtl_dirs, sim_build)

    # Run Verilator compilation
    # Note: This will compile and run a minimal empty test to validate the compilation
    cocotb_test.simulator.run(
        simulator="verilator",
        compile_args=[
            "--no-timing",
            "--Wno-WIDTHTRUNC",
            "--Wno-CASEINCOMPLETE",
            "--Wno-INITIALDLY",
            "-Wno-STMTDLY",
            "--autoflush"
        ],
        make_args=[f"-j{os.cpu_count() or 4}"],
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=dut,
        module=os.path.splitext(os.path.basename(__file__))[0],
        extra_env=cocotb_extra_env(),
        timescale="1ns/1ps",
        sim_build=sim_build,
        waves=True,
    )

    print(f"\nCompilation completed successfully!")
    print(f"Build artifacts location: {sim_build}")


# Minimal cocotb test that immediately exits (required by cocotb_test)
import cocotb

@cocotb.test()
async def compile_only_test(dut):
    """Empty test that immediately completes after compilation."""
    dut._log.info("Compilation completed. Exiting immediately.")
    # Test completes immediately without any simulation


if __name__ == "__main__":
    compile_verilator()
