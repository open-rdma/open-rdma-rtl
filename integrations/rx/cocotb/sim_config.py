"""RX top 与 TX-RX loopback 仿真目标。"""
TARGETS = {
    "rx_top": {"hdl_toplevel": "mkTestRxTop", "short_modules": ("tests.test_rx_top",), "long_modules": ("tests.test_rx_top",), "suite_env": "RX_MVP_SUITE", "verilog_dir": "build/rx_top/verilog", "cocotb_dir": "build/rx_top/cocotb"},
    "tx_rx_loopback": {"hdl_toplevel": "mkTestTxRxLoopback", "short_modules": ("tests.test_tx_rx_loopback",), "long_modules": ("tests.test_tx_rx_loopback",), "suite_env": "RX_MVP_SUITE", "verilog_dir": "build/tx_rx_loopback/verilog", "cocotb_dir": "build/tx_rx_loopback/cocotb"},
}
