# Retx ABI schema、生成器和跨语言 contract test。
include $(abspath ../../make/modules.mk)

TOP := mkRetxContractTb
TOP_FILE := $(RETX_GENERATED_TB)/RetxContractTb.bsv
BSC_PATH := $(RETX_GENERATED_TB):$(RETX_GENERATED_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

.PHONY: generate check-generated
generate:
	PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" $(PYTHON) tools/generate.py
check-generated:
	PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" $(PYTHON) tools/generate.py --check
