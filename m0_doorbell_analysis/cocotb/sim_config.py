"""M0 decoded submission 与 raw Doorbell ingress 仿真目标。"""

TARGETS = {
    "default": {
        "hdl_toplevel": "mkTestTxMvp",
        "short_modules": (
            "tests.tx.test_config",
            "tests.tx.test_tx",
            "tests.tx.test_backpressure",
            "tests.tx.test_randomized",
        ),
        "long_modules": ("tests.tx.test_randomized",),
        "long_env": {"TX_MVP_REQUEST_COUNT": "4096"},
        "verilog_dir": "build/verilog",
        "cocotb_dir": "build/cocotb",
    },
    "decoder": {
        "hdl_toplevel": "mkTestDoorbellDecoder",
        "short_modules": ("tests.doorbell.test_decoder",),
        "negative_modules": ("tests.doorbell.test_protocol_assertions",),
        "verilog_dir": "build/decoder/verilog",
        "cocotb_dir": "build/decoder/cocotb",
        "negative_case_env": "M0_DOORBELL_NEGATIVE_CASE",
        "negative_sentinel_prefix": "M0_DOORBELL_ASSERTION_DID_NOT_FIRE_",
        "negative_cases": {
            "below_window": "M0_DOORBELL_INVALID_ADDRESS",
            "at_upper_bound": "M0_DOORBELL_INVALID_ADDRESS",
            "unaligned_plus_one": "M0_DOORBELL_UNALIGNED_ADDRESS",
            "unaligned_plus_two": "M0_DOORBELL_UNALIGNED_ADDRESS",
            "unaligned_plus_four": "M0_DOORBELL_UNALIGNED_ADDRESS",
            "store_size_4": "M0_DOORBELL_INVALID_STORE_SIZE",
            "store_size_16": "M0_DOORBELL_INVALID_STORE_SIZE",
            "partial_low": "M0_DOORBELL_PARTIAL_STORE",
            "partial_high": "M0_DOORBELL_PARTIAL_STORE",
            "invalid_while_output_blocked": "M0_DOORBELL_INVALID_ADDRESS",
        },
    },
    "doorbell": {
        "hdl_toplevel": "mkTestDoorbellTxMvp",
        "short_modules": ("tests.doorbell.test_tx",),
        "verilog_dir": "build/doorbell/verilog",
        "cocotb_dir": "build/doorbell/cocotb",
    },
}
