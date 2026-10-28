# 完整 TX-RX-Retx 数据通路集成目标。
include $(abspath ../../shared/make/modules.mk)

TOP := mkTestE2e
TOP_FILE := tb/TestE2e.bsv
E2E_MODULE_PATH := $(M2_DIR)/src:$(M3_DIR)/src
RX_MODULE_PATH := $(M4_DIR)/src:$(M5_DIR)/src:$(M6_DIR)/src:$(M7_DIR)/src:$(M8_DIR)/src
RETX_MODULE_PATH := $(M9_DIR)/src:$(M10_DIR)/src:$(M11_DIR)/src
BSC_PATH := $(abspath tb):$(abspath src):$(RX_INTEGRATION_DIR)/src:$(RETX_INTEGRATION_DIR)/src:$(E2E_MODULE_PATH):$(RX_MODULE_PATH):$(RETX_MODULE_PATH):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):$(SHARED_RX_BSV):$(RETX_GENERATED_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := e2e

# CPU 侧参考 runtime 直接参与 cocotb 测试的 retry 决策。
FLOW_PYTHONPATH := $(FLOW_PYTHONPATH):$(RETX_RUNTIME_DIR)

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
