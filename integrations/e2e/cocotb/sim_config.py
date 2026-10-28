"""完整 TX-RX-Retx 数据通路仿真目标。"""
TARGETS = {
    "e2e": {
        "hdl_toplevel": "mkTestE2e",
        "short_modules": ("tests.test_e2e",),
        "long_modules": ("tests.test_e2e",),
        "suite_env": "E2E_SUITE",
        "verilog_dir": "build/verilog",
        "cocotb_dir": "build/cocotb",
    },
}
