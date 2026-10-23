"""M5 RX packet parser 仿真目标。"""
TARGETS = {"default": {"hdl_toplevel": "mkTestRxPacketParser", "short_modules": ("tests.m5.test_packet_parser",), "long_modules": ("tests.m5.test_packet_parser",), "suite_env": "RX_MVP_SUITE"}}
