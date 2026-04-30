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
    run_cocotb_simulation,
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

    module = os.path.splitext(os.path.basename(__file__))[0]
    # Run Verilator compilation
    # Note: This will compile and run a minimal empty test to validate the compilation
    run_cocotb_simulation(
        tests_dir=tests_dir,
        module=module,
        dut_name=dut,
        rtl_dirs=rtl_dirs,
    )

    print(f"\nCompilation completed successfully!")


# Minimal cocotb test that immediately exits (required by cocotb_test)
import cocotb

@cocotb.test()
async def compile_only_test(dut):
    """Empty test that immediately completes after compilation."""
    dut._log.info("Compilation completed. Exiting immediately.")
    # Test completes immediately without any simulation


if __name__ == "__main__":
    compile_verilator()
