"""M3 MRC TX scheduler 仿真目标。"""
TARGETS = {"default": {
    "hdl_toplevel": "mkTestM3",
    "short_modules": ("tests.m3.test_scheduler", "tests.m3.test_mrc"),
    "long_modules": ("tests.m3.test_mrc_long",),
}}
