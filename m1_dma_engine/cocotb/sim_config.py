"""M1 DMA 与 compactor 仿真目标。"""
TARGETS = {
    "dma": {
        "hdl_toplevel": "mkTestDmaEngine",
        "short_modules": ("tests.dma.test_dma", "tests.dma.test_reorder", "tests.dma.test_backpressure", "tests.dma.test_randomized"),
        "long_modules": ("tests.dma.test_long",),
        "negative_modules": ("tests.dma.test_protocol_assertions",),
        "long_env": {"DMA_MVP_MESSAGE_COUNT": "512"},
        "suite_env": "DMA_MVP_SUITE",
        "verilog_dir": "build/dma/verilog",
        "cocotb_dir": "build/dma/cocotb",
        "negative_case_env": "DMA_NEGATIVE_CASE",
        "negative_sentinel_prefix": "DMA_ASSERTION_DID_NOT_FIRE_",
        "negative_cases": {
            "unknown_tag": "DMA_ASSERT_UNKNOWN_TAG", "zero_keep": "DMA_ASSERT_ZERO_KEEP",
            "noncontiguous_keep": "DMA_ASSERT_NONCONTIGUOUS_KEEP", "early_last": "DMA_ASSERT_BURST_LAST",
            "late_last": "DMA_ASSERT_BURST_LAST", "over_completion": "DMA_ASSERT_OVER_COMPLETION",
            "late_completion": "DMA_ASSERT_UNKNOWN_TAG", "duplicate_message_id": "DMA_ASSERT_DUPLICATE_WQE_TAG",
            "duplicate_message_id_stalled_last": "DMA_ASSERT_DUPLICATE_WQE_TAG",
            "address_overflow": "DMA_ASSERT_CHUNK_ADDRESS_OVERFLOW", "zero_chunk": "DMA_ASSERT_ZERO_CHUNK",
            "chunk_too_large": "DMA_ASSERT_CHUNK_TOO_LARGE", "chunk_crosses_4k": "DMA_ASSERT_CHUNK_CROSSES_4K",
            "missing_first": "DMA_ASSERT_MISSING_CHUNK_FIRST", "chunk_sequence": "DMA_ASSERT_CHUNK_SEQUENCE",
            "chunk_tag_changed": "DMA_ASSERT_CHUNK_TAG_CHANGED",
        },
    },
    "compactor": {
        "hdl_toplevel": "mkTestDmaPayloadCompactor",
        "short_modules": ("tests.test_compactor",),
        "long_modules": ("tests.test_compactor",),
        "verilog_dir": "build/compactor/verilog",
        "cocotb_dir": "build/compactor/cocotb",
    },
}
