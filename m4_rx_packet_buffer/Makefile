# M4 RX PacketBuffer。
include $(abspath ../shared/make/modules.mk)

TOP := mkTestRxPacketBuffer
TOP_FILE := tb/TestRxPacketBuffer.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):$(SHARED_RX_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk
