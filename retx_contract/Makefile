BSC ?= bsc
PYTHON ?= python3
SIM ?= verilator
SUITE ?= short

BUILD_DIR := build
VERILOG_DIR := $(BUILD_DIR)/verilog
TOP := mkRetxContractTb
TOP_FILE := tb/RetxContractTb.bsv
BSC_PATH := +:$(abspath src):$(abspath tb)
BSC_FLAGS := -u -check-assert -warn-action-shadowing -warn-method-urgency -show-schedule

.PHONY: generate compile verilog test test-long clean

generate:
	$(PYTHON) tools/generate.py

compile: generate
	mkdir -p $(BUILD_DIR)/bsc
	$(BSC) $(BSC_FLAGS) -sim -p $(BSC_PATH) \
		-bdir $(BUILD_DIR)/bsc -simdir $(BUILD_DIR)/bsc -info-dir $(BUILD_DIR)/bsc \
		-g $(TOP) $(TOP_FILE)

verilog: generate
	mkdir -p $(VERILOG_DIR)
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(VERILOG_DIR) -vdir $(VERILOG_DIR) -info-dir $(VERILOG_DIR) \
		-g $(TOP) $(TOP_FILE)

test: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		$(PYTHON) cocotb/sim_runner.py --suite $(SUITE)

test-long: test

clean:
	rm -rf $(BUILD_DIR) src/RetxTypes.bsv tb/RetxContractTb.bsv python/retx_codec.py golden/vectors.json manifest.json
