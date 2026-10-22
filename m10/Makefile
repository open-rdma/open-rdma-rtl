# M3 (MrcTxScheduler): four-channel MRC TX scheduler + Ethernet encapsulator.
# Self-contained: types live in src/; standalone-verilog and yosys targets
# synthesize mkFourChannelTxScheduler from this folder alone.
#
# Usage:
#   make test                # short suite, SIM=verilator
#   make test SIM=icarus
#   make yosys               # yosys synthesis + BRAM2 resource check
# Use PYTHON pointing at a cocotb 2 interpreter (e.g. the cocotb2 conda env).
BSC ?= bsc
YOSYS ?= yosys
PYTHON ?= python3
SIM ?= verilator
SUITE ?= short

BUILD_DIR := build
VERILOG_DIR := $(BUILD_DIR)/verilog
BSC_DIR := $(BUILD_DIR)/bsc
STANDALONE_DIR := $(BUILD_DIR)/standalone-verilog
YOSYS_DIR := $(BUILD_DIR)/yosys
TOP := mkTestM10
TOP_FILE := tb/TestM10.bsv
M3_TOP := mkRetxReportEngine
M3_FILE := src/RetxReportEngine.bsv
BSC_PATH := +:$(abspath src):$(abspath tb)
BSC_FLAGS := -u -check-assert -warn-action-shadowing -warn-method-urgency -show-schedule
BSC_ROOT := $(shell dirname $$(dirname $$(readlink -f $$(command -v $(BSC)))))
BSC_VERILOG_LIB := $(BSC_ROOT)/lib/Verilog
YOSYS_LOGIC_LIBS := $(BSC_VERILOG_LIB)/FIFO1.v \
	$(BSC_VERILOG_LIB)/FIFO2.v $(BSC_VERILOG_LIB)/SizedFIFO.v \
	$(BSC_VERILOG_LIB)/RegFile.v

.PHONY: compile verilog test test-long clean

compile:
	mkdir -p $(BSC_DIR)
	$(BSC) $(BSC_FLAGS) -sim -p $(BSC_PATH) \
		-bdir $(BSC_DIR) -simdir $(BSC_DIR) -info-dir $(BSC_DIR) \
		-g $(TOP) $(TOP_FILE)

verilog:
	mkdir -p $(VERILOG_DIR)
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(VERILOG_DIR) -vdir $(VERILOG_DIR) -info-dir $(VERILOG_DIR) \
		-g $(TOP) $(TOP_FILE)

test: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		$(PYTHON) cocotb/sim_runner.py --suite $(SUITE)

test-long: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		$(PYTHON) cocotb/sim_runner.py --suite long

clean:
	rm -rf $(BUILD_DIR)
