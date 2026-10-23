# TX 跨模块集成：DmaPhaseA 与完整 M0 chain。
include $(abspath ../../shared/make/modules.mk)

TARGET ?= integration
BUILD_DIR := build/$(TARGET)
TOP_integration := mkTestDmaPhaseAIntegration
TOP_FILE_integration := tb/TestDmaPhaseAIntegration.bsv
TOP_m0chain := mkTestM0Chain
TOP_FILE_m0chain := tb/TestM0Chain.bsv
TOP := $(TOP_$(TARGET))
TOP_FILE := $(TOP_FILE_$(TARGET))
BSC_PATH := $(abspath tb):$(abspath src):$(M0_DIR)/src:$(M1_DIR)/src:$(M2_DIR)/src:$(M3_DIR)/src:$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):+
CLEAN_DIRS := build
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := $(TARGET)
DEFINE_STANDARD_TESTS := 0

ifeq ($(strip $(TOP)),)
$(error 不支持 TARGET '$(TARGET)'；可用值：integration m0chain)
endif

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

.PHONY: test test-integration test-m0chain test-long test-m0chain-long test-negative
test: test-integration test-m0chain
test-integration:
	$(MAKE) run TARGET=integration SIM_TARGET=integration SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-m0chain:
	$(MAKE) run TARGET=m0chain SIM_TARGET=m0chain SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-long:
	$(MAKE) run TARGET=integration SIM_TARGET=integration SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-m0chain-long:
	$(MAKE) run TARGET=m0chain SIM_TARGET=m0chain SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-negative: verilog
	@test "$(TARGET)" = "integration" || { echo "test-negative 要求 TARGET=integration"; exit 2; }
	@test "$(SIM)" = "icarus" || { echo "test-negative 要求 SIM=icarus"; exit 2; }
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) -m openrdma_flow_tb.sim.expected_fatal \
			--project-root $(CURDIR) --config $(SIM_CONFIG) --target integration
