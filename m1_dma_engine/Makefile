# M1：DmaEngine 与 DmaPayloadCompactor。
include $(abspath ../shared/make/modules.mk)

IVERILOG ?= iverilog
VERILATOR ?= verilator
QUARTUS_SH ?= quartus_sh
QUARTUS_FAMILY ?= Agilex 7
QUARTUS_DEVICE ?= AGIB027R31B1E2VR0
TARGET ?= dma

BUILD_DIR := build/$(TARGET)
TOP_dma := mkTestDmaEngine
TOP_FILE_dma := tb/TestDmaEngine.bsv
TOP_compactor := mkTestDmaPayloadCompactor
TOP_FILE_compactor := tb/TestDmaPayloadCompactor.bsv
TOP := $(TOP_$(TARGET))
TOP_FILE := $(TOP_FILE_$(TARGET))
BSC_PATH := $(abspath tb):$(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):+
CLEAN_DIRS := build
SIM_CONFIG := $(CURDIR)/cocotb/sim_config.py
SIM_TARGET := $(TARGET)

ifeq ($(strip $(TOP)),)
$(error 不支持 TARGET '$(TARGET)'；可用值：dma compactor)
endif

include $(SHARED_MAKE_DIR)/bsv-cocotb.mk

PRODUCTION_TOP := mkDmaEngine
PRODUCTION_FILE := src/DmaEngine.bsv
PRODUCTION_BSC_PATH := $(abspath src):$(SHARED_COMMON_BSV):$(SHARED_TX_BSV):+
PRODUCTION_BSC_DIR := build/production/bsc
QUARTUS_BUNDLE_DIR := build/quartus
QUARTUS_CHECK_DIR := build/quartus-check
QUARTUS_SYNTH_DIR := build/quartus-synth

.PHONY: production-verilog quartus-rtl check-quartus-rtl quartus-synth test-negative

production-verilog: preflight
	rm -rf $(PRODUCTION_BSC_DIR)
	mkdir -p $(PRODUCTION_BSC_DIR)
	$(BSC) $(BSC_FLAGS) -elab -verilog -remove-dollar -p $(PRODUCTION_BSC_PATH) \
		-bdir $(PRODUCTION_BSC_DIR) -vdir $(PRODUCTION_BSC_DIR) \
		-info-dir $(PRODUCTION_BSC_DIR) -g $(PRODUCTION_TOP) $(PRODUCTION_FILE)

quartus-rtl: production-verilog
	$(PYTHON) tools/export_quartus_rtl.py --bsc $(BSC) \
		--collector tools/listVlogFiles.tcl --bdir $(PRODUCTION_BSC_DIR) \
		--vdir $(PRODUCTION_BSC_DIR) --top $(PRODUCTION_TOP) --output $(QUARTUS_BUNDLE_DIR)

check-quartus-rtl: quartus-rtl
	rm -rf $(QUARTUS_CHECK_DIR)
	mkdir -p $(QUARTUS_CHECK_DIR)
	cd $(QUARTUS_BUNDLE_DIR) && $(IVERILOG) -g2012 -s $(PRODUCTION_TOP) \
		-o $(abspath $(QUARTUS_CHECK_DIR))/$(PRODUCTION_TOP).vvp -f dma_engine.f
	cd $(QUARTUS_BUNDLE_DIR) && $(VERILATOR) --lint-only --Wno-fatal \
		--top-module $(PRODUCTION_TOP) -f dma_engine.f

quartus-synth: quartus-rtl
	rm -rf $(QUARTUS_SYNTH_DIR)
	mkdir -p $(QUARTUS_SYNTH_DIR)
	$(QUARTUS_SH) -t tools/quartus_synth.tcl $(abspath $(QUARTUS_BUNDLE_DIR)) \
		$(abspath $(QUARTUS_SYNTH_DIR)) $(PRODUCTION_TOP) "$(QUARTUS_FAMILY)" $(QUARTUS_DEVICE)

test-negative: verilog
	@test "$(TARGET)" = "dma" || { echo "test-negative 要求 TARGET=dma"; exit 2; }
	@test "$(SIM)" = "icarus" || { echo "test-negative 要求 SIM=icarus"; exit 2; }
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) -m openrdma_flow_tb.sim.expected_fatal \
			--project-root $(CURDIR) --config $(SIM_CONFIG) --target dma
