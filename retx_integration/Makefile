BSC ?= bsc
PYTHON ?= python3
SIM ?= verilator

BUILD_DIR := build
VERILOG_DIR := $(BUILD_DIR)/verilog
TOP := mkTestRetxTop
TOP_FILE := tb/TestRetxTop.bsv
BSC_PATH := +:$(abspath src):$(abspath tb):$(abspath ../m9/src):$(abspath ../m10/src):$(abspath ../m11/src)
BSC_FLAGS := -u -check-assert -warn-action-shadowing -warn-method-urgency -show-schedule

.PHONY: preflight compile verilog test test-long clean

preflight:
	$(PYTHON) scripts/preflight.py

compile: preflight
	mkdir -p $(BUILD_DIR)/bsc
	$(BSC) $(BSC_FLAGS) -sim -p $(BSC_PATH) \
		-bdir $(BUILD_DIR)/bsc -simdir $(BUILD_DIR)/bsc -info-dir $(BUILD_DIR)/bsc \
		-g $(TOP) $(TOP_FILE)

verilog: preflight
	mkdir -p $(VERILOG_DIR)
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(VERILOG_DIR) -vdir $(VERILOG_DIR) -info-dir $(VERILOG_DIR) \
		-g $(TOP) $(TOP_FILE)

test: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		$(PYTHON) cocotb/sim_runner.py

test-long: test

clean:
	rm -rf $(BUILD_DIR)
