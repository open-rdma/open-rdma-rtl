# M0 doorbell analysis：GDRP submission 到 physical DMA chunk。
include $(abspath ../shared/make/modules.mk)

TARGET ?= default
BUILD_DIR := $(if $(filter default,$(TARGET)),build,build/$(TARGET))
TOP_default := mkTestTxMvp
TOP_FILE_default := tb/TestTxMvp.bsv
TOP_decoder := mkTestDoorbellDecoder
TOP_FILE_decoder := tb/TestDoorbellDecoder.bsv
TOP_doorbell := mkTestDoorbellTxMvp
TOP_FILE_doorbell := tb/TestDoorbellTxMvp.bsv
TOP := $(TOP_$(TARGET))
TOP_FILE := $(TOP_FILE_$(TARGET))
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):+
CLEAN_DIRS := build
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := $(TARGET)
DEFINE_STANDARD_TESTS := 0

ifeq ($(strip $(TOP)),)
$(error 不支持 TARGET '$(TARGET)'；可用值：default decoder doorbell)
endif

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

.PHONY: test test-decoded test-decoder test-doorbell test-long test-negative

ifeq ($(SUITE),long)
test: test-long
else
test: test-decoded test-decoder test-doorbell
endif

test-decoded:
	$(MAKE) run TARGET=default SIM_TARGET=default SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-decoder:
	$(MAKE) run TARGET=decoder SIM_TARGET=decoder SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-doorbell:
	$(MAKE) run TARGET=doorbell SIM_TARGET=doorbell SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-long:
	$(MAKE) run TARGET=default SIM_TARGET=default SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-negative: verilog
	@test "$(TARGET)" = "decoder" || { echo "test-negative 要求 TARGET=decoder"; exit 2; }
	@test "$(SIM)" = "icarus" || { echo "test-negative 要求 SIM=icarus"; exit 2; }
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) -m openrdma_flow_tb.sim.expected_fatal \
			--project-root $(CURDIR) --config $(SIM_CONFIG) --target decoder
