# M2 PacketAssembly：message 按 PMTU 分片。
include $(abspath ../shared/make/modules.mk)

TOP := mkTestM2
TOP_FILE := tb/TestM2.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
