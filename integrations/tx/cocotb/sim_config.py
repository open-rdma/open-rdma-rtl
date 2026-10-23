"""TX integration 与 m0 chain 仿真目标。"""
TARGETS = {
    "integration": {
        "hdl_toplevel": "mkTestDmaPhaseAIntegration",
        "short_modules": ("tests.test_end_to_end",), "long_modules": ("tests.test_long",),
        "negative_modules": ("tests.test_protocol_assertions",),
        "suite_env": "DMA_PHASEA_SUITE", "verilog_dir": "build/integration/verilog",
        "cocotb_dir": "build/integration/cocotb", "negative_case_env": "DMA_PHASEA_NEGATIVE_CASE",
        "negative_sentinel_prefix": "DMA_PHASEA_ASSERTION_DID_NOT_FIRE_",
        "negative_cases": {
            "context_tag_mismatch": "DMA_PHASEA_CONTEXT_TAG_MISMATCH",
            "last_length_mismatch": "DMA_PHASEA_LAST_LENGTH_MISMATCH",
            "missing_last_flag": "DMA_PHASEA_MISSING_LAST_FLAG",
            "chunk_sequence": "DMA_PHASEA_CHUNK_SEQUENCE",
        },
    },
    "m0chain": {
        "hdl_toplevel": "mkTestM0Chain",
        "short_modules": ("tests.test_m0_chain",), "long_modules": ("tests.test_m0_chain_long",),
        "verilog_dir": "build/m0chain/verilog", "cocotb_dir": "build/m0chain/cocotb",
    },
}
