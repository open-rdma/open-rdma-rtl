# M11 RetxRetryEngine。
include $(abspath ../shared/make/modules.mk)

TOP := mkTestM11
TOP_FILE := tb/TestM11.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(RETX_GENERATED_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
