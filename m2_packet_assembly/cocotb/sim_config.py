"""M2 packet assembly 仿真目标。"""
TARGETS = {"default": {
    "hdl_toplevel": "mkTestM2",
    "short_modules": ("tests.m2.test_packetizer",),
    "long_modules": ("tests.m2.test_packetizer_long",),
}}
