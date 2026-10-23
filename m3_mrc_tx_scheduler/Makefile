# M3：四通道 MRC TX scheduler 与 wire encapsulation。
include $(abspath ../shared/make/modules.mk)

YOSYS ?= yosys
TOP := mkTestM3
TOP_FILE := tb/TestM3.bsv
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):+
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := default

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

STANDALONE_DIR := build/standalone-verilog
YOSYS_DIR := build/yosys
M3_TOP := mkFourChannelTxScheduler
M3_FILE := src/MrcTxScheduler.bsv
BSC_ROOT := $(shell dirname $$(dirname $$(readlink -f $$(command -v $(BSC)))))
BSC_VERILOG_LIB := $(BSC_ROOT)/lib/Verilog
YOSYS_LOGIC_LIBS := $(BSC_VERILOG_LIB)/FIFO1.v $(BSC_VERILOG_LIB)/FIFO2.v \
	$(BSC_VERILOG_LIB)/SizedFIFO.v $(BSC_VERILOG_LIB)/RegFile.v

.PHONY: standalone-verilog bram-check yosys
standalone-verilog: preflight
	rm -rf $(STANDALONE_DIR)
	mkdir -p $(STANDALONE_DIR)
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(STANDALONE_DIR) -vdir $(STANDALONE_DIR) -info-dir $(STANDALONE_DIR) \
		-g $(M3_TOP) $(M3_FILE)

bram-check:
	mkdir -p $(YOSYS_DIR)
	$(YOSYS) -l $(YOSYS_DIR)/bram-check.log -p 'read_verilog -sv $(BSC_VERILOG_LIB)/BRAM2.v; chparam -set ADDR_WIDTH 6 -set DATA_WIDTH 1024 -set MEMSIZE 64 -set PIPELINED 0 BRAM2; hierarchy -check -top BRAM2; proc; memory_collect; check; stat'

yosys: standalone-verilog bram-check
	mkdir -p $(YOSYS_DIR)
	/usr/bin/time -f 'elapsed_seconds=%e\nmax_rss_kb=%M' -o $(YOSYS_DIR)/resources.txt \
		$(YOSYS) -l $(YOSYS_DIR)/synth.log -p 'read_verilog -lib -sv $(BSC_VERILOG_LIB)/BRAM2.v; read_verilog -sv $(YOSYS_LOGIC_LIBS) $(STANDALONE_DIR)/$(M3_TOP).v; hierarchy -check -top $(M3_TOP); synth -top $(M3_TOP) -noabc; check; stat; write_verilog -noattr -noexpr $(YOSYS_DIR)/$(M3_TOP)-netlist.v'
