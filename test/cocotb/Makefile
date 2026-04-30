SHELL := /bin/bash

# User-configurable inputs
FLOW ?= default
TOP_BSV_SRC_FILE ?= ../src/Top.bsv
INST_ID ?= 1
PYTHON ?= python3

# Base paths
ROOT_DIR := $(abspath ../../)
BACKEND_DIR := $(ROOT_DIR)/backend
SRC_DIR := $(ROOT_DIR)/src
TB_DIR := $(abspath .)
VBUILD_DIR := $(BACKEND_DIR)/build
GENERATED_VSRC_DIR := $(BACKEND_DIR)/verilog

# Derived RTL paths
PCIE_WRAPPER_DIR := $(TB_DIR)/verilog
QUARTUS_RTL_DIR := $(BACKEND_DIR)/quartus/rtl
PCIE_RESET_RTL := $(QUARTUS_RTL_DIR)/rtile_reset_output_buffer.v
COMMON_VERILOG_DIR = $(SRC_DIR)/verilog:$(GENERATED_VSRC_DIR)
PCIE_VERILOG_DIR = $(PCIE_WRAPPER_DIR):$(PCIE_RESET_RTL):$(COMMON_VERILOG_DIR)

include $(ROOT_DIR)/Makefile.base

# Test entrypoints
LOOPBACK_TB_FILE := tb_top_for_system_test.py
TWO_CARD_TB_FILE := tb_top_for_system_test_two_card.py
MULTI_NODE_TB_FILE := tb_top_for_system_test_multi_node.py
PCIE_TB_FILE := tb_top_pcie_system_test.py

# Flow model
ifeq ($(FLOW),pcie)
FLOW_NAME := pcie
BSV_BUILD_TOP := mkBsvTop
SIM_TOP := top_mkBsvTopWithResetBuffer
TB_FILE ?= $(PCIE_TB_FILE)
SIM_VERILOG_DIR := $(PCIE_VERILOG_DIR)
PREPARE_TARGET := $(PCIE_WRAPPER_DIR)/$(SIM_TOP).v
else
FLOW_NAME := default
BSV_BUILD_TOP := mkBsvTopWithoutHardIpInstance
SIM_TOP := mkBsvTopWithoutHardIpInstance
TB_FILE ?= tb_top_without_hard_ip.py
SIM_VERILOG_DIR := $(COMMON_VERILOG_DIR)
PREPARE_TARGET := $(GENERATED_VSRC_DIR)/$(SIM_TOP).v
endif

# Legacy compatibility: TOP_MODULE was the original single-line cocotb test
# selector before the flow model was introduced. Keep it and the older
# commented examples below for reference when comparing prior test entrypoints.
TOP_MODULE ?= $(BSV_BUILD_TOP)
COMPILE_VERILOG_DIR = $(SIM_VERILOG_DIR)

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

BACKEND_TOP_V := $(GENERATED_VSRC_DIR)/$(BSV_BUILD_TOP).v
SIM_TOP_V := $(PREPARE_TARGET)
VLOG_FILE = $(TB_DIR)/$(BSV_BUILD_TOP).v

DATE = $(shell date "+%Y%m%d")
LOG_FILE = $(TB_DIR)/log/$(DATE)_$(SIM_TOP).log

#
# Cocotb Makefile intentionally acts like a thin wrapper around backend/Makefile:
# always forward "verilog" to backend and let backend own the real .bsv
# dependency graph and incrementality.
#
verilog:
	$(MAKE) -C $(BACKEND_DIR) TARGETFILE=$(TOP_BSV_SRC_FILE) BSV_TOP_MODULE=$(BSV_BUILD_TOP) IS_COMPILE_FOR_SIM=True verilog
	test -f $(BACKEND_TOP_V)

prepare: verilog $(SIM_TOP_V)
	grep -q '^`timescale 1ns/1ps' $(SIM_TOP_V) || sed -i '1i `timescale 1ns/1ps' $(SIM_TOP_V)

run: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail; \
	COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) COCOTB_DUT=$(SIM_TOP) BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TB_FILE) 2>&1 | tee $(LOG_FILE)


#在这里
# iverilog
# cocotb (python3)
run_system_test_server_loopback: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) COCOTB_DUT=$(SIM_TOP) BLUERDMA_SIMULATOR_INST_ID=1 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(LOOPBACK_TB_FILE) 2>&1 | tee $(LOG_FILE).loopback

run_system_test_server_1: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) COCOTB_DUT=$(SIM_TOP) BLUERDMA_SIMULATOR_INST_ID=1 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TWO_CARD_TB_FILE) 2>&1 | tee $(LOG_FILE).1

run_system_test_server_2: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) COCOTB_DUT=$(SIM_TOP) BLUERDMA_SIMULATOR_INST_ID=2 BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(TWO_CARD_TB_FILE) 2>&1 | tee $(LOG_FILE).2

run_system_test_multi_node: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) COCOTB_DUT=$(SIM_TOP) BLUERDMA_SIMULATOR_INST_ID=$(INST_ID) BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) python3 $(MULTI_NODE_TB_FILE) 2>&1 | tee $(LOG_FILE).$(INST_ID)

run_pcie_system_test: prepare
	cd $(TB_DIR)
	mkdir -p log

	set -o pipefail ; \
	sudo env \
		PATH="$(PATH)" \
		HOME="$(HOME)" \
		LD_LIBRARY_PATH="$(LD_LIBRARY_PATH)" \
		COCOTB_VERILOG_DIR=$(SIM_VERILOG_DIR) \
		COCOTB_DUT=$(SIM_TOP) \
		BLUERDMA_SIMULATOR_INST_ID=1 \
		BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) \
		BLUERDMA_SIM_BACKEND=$(BLUERDMA_SIM_BACKEND) \
		python3 $(PCIE_TB_FILE) 2>&1 | tee $(LOG_FILE)

# Compile Verilator without running full tests
# Usage: make compile_verilator [TOP_MODULE=<module_name>] [BLUERDMA_DATA_BUS_WIDTH=<width>]
compile_verilator: verilog
	@echo "==============================================="
	@echo "Compiling Verilator for $(SIM_TOP)"
	@echo "Data bus width: $(BLUERDMA_DATA_BUS_WIDTH)"
	@echo "==============================================="
	cd $(TB_DIR) && \
	COCOTB_VERILOG_DIR=$(COMPILE_VERILOG_DIR) \
	COCOTB_DUT=$(SIM_TOP) \
	BLUERDMA_DATA_BUS_WIDTH=$(BLUERDMA_DATA_BUS_WIDTH) \
	$(PYTHON) compile_verilator.py



cocotb:clean verilog prepare run

clean:
	$(MAKE) -C $(BACKEND_DIR) clean
	cd $(TB_DIR) && rm -rf $(VLOG_FILE) __pycache__ .pytest_cache sim_build *.log 
	
.PHONY: verilog prepare run run_system_test_server_loopback run_system_test_server_1 run_system_test_server_2 run_system_test_multi_node run_pcie_system_test clean compile_verilator cocotb
