# M7 RX DMA Placement。
include $(abspath ../shared/make/modules.mk)

TOP := mkTestRxDmaPlacement
TOP_FILE := tb/TestRxDmaPlacement.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):$(SHARED_RX_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
