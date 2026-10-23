"""M0 doorbell analysis 仿真目标。"""
TARGETS = {"default": {
    "hdl_toplevel": "mkTestTxMvp",
    "short_modules": ("tests.tx.test_config", "tests.tx.test_tx", "tests.tx.test_backpressure", "tests.tx.test_randomized"),
    "long_modules": ("tests.tx.test_randomized",),
    "long_env": {"TX_MVP_REQUEST_COUNT": "4096"},
}}
