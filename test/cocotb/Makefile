SHELL := /bin/bash

ROOT_DIR = $(abspath ../../)
BACKEND_DIR = $(ROOT_DIR)/backend
SRC_DIR = $(ROOT_DIR)/src
TB_DIR = $(abspath ./)
PCIE_WRAPPER_DIR = $(TB_DIR)/verilog
QUARTUS_RTL_DIR = $(BACKEND_DIR)/quartus/rtl
include $(ROOT_DIR)/Makefile.base
VBUILD_DIR = $(BACKEND_DIR)/build
GENERATED_VSRC_DIR = $(BACKEND_DIR)/verilog

# System test configuration - use same Top.bsv for all modes
TOP_BSV_SRC_FILE = ../src/Top.bsv
TOP_MODULE = mkBsvTopWithoutHardIpInstance

# Test file configuration
LOOPBACK_TB_FILE = tb_top_for_system_test.py
TWO_CARD_TB_FILE = tb_top_for_system_test_two_card.py
MULTI_NODE_TB_FILE = tb_top_for_system_test_multi_node.py
PCIE_TB_FILE = tb_top_pcie_system_test.py
PCIE_TOP_MODULE = top_mkBsvTopWithResetBuffer

INST_ID ?= 1

PYTHON ?= python3

# TOP_BSV_SRC_FILE ?= ../test/TestRTilePcieAdaptor.bsv
# TOP_MODULE ?= mkTestRTilePcieByCocotbTest
# TB_FILE = tb_simple_root_complex.py

# TOP_BSV_SRC_FILE ?= ../test/TestFTileMacAdaptor.bsv
# TOP_MODULE ?= mkTestFtileMacCocotbLoopBackTest
# TB_FILE = tb_ftile_mac_loopback.py

# TOP_BSV_SRC_FILE ?= ../test/TestPayloadGenAndCon.bsv
# TOP_MODULE ?= mkTestCocotbPayloadGenAndCon
# TB_FILE = tb_payload_con_and_gen.py

# TOP_BSV_SRC_FILE ?= ../test/TestPacketGenAndParse.bsv
# TOP_MODULE ?= mkTestCocotbPacketGenAndParse
# TB_FILE = tb_packet_gen_and_parse.py

# TOP_BSV_SRC_FILE ?= ../test/TestPsnContinousChecker.bsv
# TOP_MODULE ?= mkTestCocotbPsnPerMergeAndStorage
# TB_FILE = tb_psn_per_merge_and_storage.py

# TOP_BSV_SRC_FILE ?= ../src/Top.bsv
# TOP_MODULE ?= mkBsvTopWithoutHardIpInstance
# TB_FILE = tb_top_without_hard_ip.py

# TOP_BSV_SRC_FILE ?= ../test/TestPipeIoAdaptor.bsv
# TOP_MODULE ?= mkTestB
# TB_FILE = tb_tmp.py

# TOP_BSV_SRC_FILE ?= ../src/Top100G.bsv
# TOP_MODULE ?= mkBsvTopWithoutHardIpInstance
# TB_FILE = tb_top_without_hard_ip.py

# TOP_BSV_SRC_FILE ?= ../src/Top100G.bsv
# TOP_MODULE ?= mkBsvTop
# TB_FILE = tb_100g_with_bdma.py

TOP_FILE = $(TOP_MODULE).v
VLOG_FILE = $(TB_DIR)/$(TOP_FILE)


DATE = $(shell date "+%Y%m%d")
LOG_FILE = $(TB_DIR)/log/$(DATE)_$(TOP_MODULE).log

verilog:
	cd $(BACKEND_DIR) && make TARGETFILE=${TOP_BSV_SRC_FILE} BSV_TOP_MODULE=${TOP_MODULE} IS_COMPILE_FOR_SIM=True verilog

prepare:
	sed -i '1i `timescale 1ns/1ps' $(GENERATED_VSRC_DIR)/$(TOP_FILE)

run:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail; \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) COCOTB_DUT=$(TOP_MODULE) BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TB_FILE) 2>&1 | tee $(LOG_FILE)


#在这里
# iverilog
# cocotb (python3)
run_system_test_server_loopback:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) COCOTB_DUT=$(TOP_MODULE) BLUERDMA_SIMULATOR_INST_ID=1 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(LOOPBACK_TB_FILE) 2>&1 | tee $(LOG_FILE).loopback

run_system_test_server_1:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) COCOTB_DUT=$(TOP_MODULE) BLUERDMA_SIMULATOR_INST_ID=1 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TWO_CARD_TB_FILE) 2>&1 | tee $(LOG_FILE).1

run_system_test_server_2:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) COCOTB_DUT=$(TOP_MODULE) BLUERDMA_SIMULATOR_INST_ID=2 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TWO_CARD_TB_FILE) 2>&1 | tee $(LOG_FILE).2

run_system_test_multi_node:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) COCOTB_DUT=$(TOP_MODULE) BLUERDMA_SIMULATOR_INST_ID=$(INST_ID) BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(MULTI_NODE_TB_FILE) 2>&1 | tee $(LOG_FILE).$(INST_ID)

PCIE_LOG_FILE = $(TB_DIR)/log/$(DATE)_$(PCIE_TOP_MODULE).log

run_pcie_system_test:
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	sudo env \
		PATH="$(PATH)" \
		HOME="$(HOME)" \
		LD_LIBRARY_PATH="$(LD_LIBRARY_PATH)" \
		COCOTB_VERILOG_DIR=$(PCIE_WRAPPER_DIR):$(QUARTUS_RTL_DIR):$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) \
		COCOTB_DUT=$(PCIE_TOP_MODULE) \
		BLUERDMA_SIMULATOR_INST_ID=1 \
		BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) \
		python3 $(PCIE_TB_FILE) 2>&1 | tee $(PCIE_LOG_FILE)

# Compile Verilator without running full tests
# Usage: make compile_verilator [TOP_MODULE=<module_name>] [BLUERDMA_DATA_BUS_WIDTH=<width>]
compile_verilator:
	@echo "==============================================="
	@echo "Compiling Verilator for $(TOP_MODULE)"
	@echo "Data bus width: $(BLUERDMA_DATA_BUS_WIDTH)"
	@echo "==============================================="
	cd $(TB_DIR) && \
	COCOTB_VERILOG_DIR=$(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR) \
	COCOTB_DUT=$(TOP_MODULE) \
	BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) \
	$(PYTHON) compile_verilator.py



cocotb:clean verilog prepare run

clean:
	cd $(BACKEND_DIR) && make clean
	cd $(TB_DIR) && rm -rf $(VLOG_FILE) __pycache__ .pytest_cache sim_build *.log 
	
