"""M4 RX packet buffer 仿真目标。"""
TARGETS = {"default": {"hdl_toplevel": "mkTestRxPacketBuffer", "short_modules": ("tests.m4.test_packet_buffer",), "long_modules": ("tests.m4.test_packet_buffer",), "suite_env": "RX_MVP_SUITE"}}
