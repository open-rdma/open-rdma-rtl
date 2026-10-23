# RX 跨模块集成：RxTop 与 TX-RX loopback。
include $(abspath ../../shared/make/modules.mk)

TARGET ?= rx_top
BUILD_DIR := build/$(TARGET)
TOP_rx_top := mkTestRxTop
TOP_FILE_rx_top := tb/TestRxTop.bsv
TOP_tx_rx_loopback := mkTestTxRxLoopback
TOP_FILE_tx_rx_loopback := tb/TestTxRxLoopback.bsv
TOP := $(TOP_$(TARGET))
TOP_FILE := $(TOP_FILE_$(TARGET))
RX_MODULE_PATH := $(M4_DIR)/src:$(M5_DIR)/src:$(M6_DIR)/src:$(M7_DIR)/src:$(M8_DIR)/src
BSC_PATH_rx_top := $(abspath tb):$(abspath src):$(RX_MODULE_PATH):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):$(SHARED_RX_BSV):+
BSC_PATH_tx_rx_loopback := $(abspath tb):$(abspath src):$(M2_DIR)/src:$(M3_DIR)/src:$(RX_MODULE_PATH):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):$(SHARED_RX_BSV):+
BSC_PATH := $(BSC_PATH_$(TARGET))
CLEAN_DIRS := build
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := $(TARGET)
DEFINE_STANDARD_TESTS := 0

ifeq ($(strip $(TOP)),)
$(error 不支持 TARGET '$(TARGET)'；可用值：rx_top tx_rx_loopback)
endif

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

PRODUCTION_TOP := mkRxTop
PRODUCTION_FILE := src/RxTop.bsv
PRODUCTION_DIR := build/production/verilog

.PHONY: test test-rx-top test-tx-rx-loopback test-long test-rx-top-long test-tx-rx-loopback-long production-verilog
test: test-rx-top test-tx-rx-loopback
test-rx-top:
	$(MAKE) run TARGET=rx_top SIM_TARGET=rx_top SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-tx-rx-loopback:
	$(MAKE) run TARGET=tx_rx_loopback SIM_TARGET=tx_rx_loopback SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-long: test-rx-top-long test-tx-rx-loopback-long
test-rx-top-long:
	$(MAKE) run TARGET=rx_top SIM_TARGET=rx_top SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
test-tx-rx-loopback-long:
	$(MAKE) run TARGET=tx_rx_loopback SIM_TARGET=tx_rx_loopback SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
production-verilog: preflight
	rm -rf $(PRODUCTION_DIR)
	mkdir -p $(PRODUCTION_DIR)
	$(BSC) $(BSC_FLAGS) -elab -verilog -remove-dollar -p $(BSC_PATH_rx_top) \
		-bdir $(PRODUCTION_DIR) -vdir $(PRODUCTION_DIR) -info-dir $(PRODUCTION_DIR) \
		-g $(PRODUCTION_TOP) $(PRODUCTION_FILE)
