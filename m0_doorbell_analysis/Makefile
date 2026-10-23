# M0 doorbell analysis：GDRP submission 到 physical DMA chunk。
include $(abspath ../shared/make/modules.mk)

TOP := mkTestTxMvp
TOP_FILE := tb/TestTxMvp.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
