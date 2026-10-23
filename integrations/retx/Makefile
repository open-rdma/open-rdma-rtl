# Retx seam integration：当前只连接 M9、M10、M11。
include $(abspath ../../shared/make/modules.mk)

TOP := mkTestRetxTop
TOP_FILE := tb/TestRetxTop.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(M9_DIR)/src:$(M10_DIR)/src:$(M11_DIR)/src:$(SHARED_COMMON_BSV):$(RETX_GENERATED_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
