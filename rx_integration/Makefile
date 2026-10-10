# RX integration: RxTop and the current TX M2/M3 to RX loopback.
BSC ?= bsc
PYTHON ?= python3
SIM ?= verilator
TARGET ?= rx_top
SUITE ?= short

BUILD_DIR := build/$(TARGET)
INT_SRC := src
INT_TB := tb
RX_M4_SRC := ../m4/src
RX_M5_SRC := ../m5/src
RX_M6_SRC := ../m6/src
RX_M7_SRC := ../m7/src
RX_M8_SRC := ../m8/src
TX_M2_SRC := ../m2/src
TX_M3_SRC := ../m3/src

TOP_rx_top := mkTestRxTop
TOP_FILE_rx_top := $(INT_TB)/TestRxTop.bsv
TOP_tx_rx_loopback := mkTestTxRxLoopback
TOP_FILE_tx_rx_loopback := $(INT_TB)/TestTxRxLoopback.bsv
TOP := $(TOP_$(TARGET))
TOP_FILE := $(TOP_FILE_$(TARGET))

RX_BSC_PATH := $(abspath $(RX_M4_SRC)):$(abspath $(RX_M5_SRC)):$(abspath $(RX_M6_SRC)):$(abspath $(RX_M7_SRC)):$(abspath $(RX_M8_SRC))
BSC_PATH_rx_top := +:$(abspath $(INT_TB)):$(abspath $(INT_SRC)):$(RX_BSC_PATH)
BSC_PATH_tx_rx_loopback := +:$(abspath $(INT_TB)):$(abspath $(INT_SRC)):$(abspath $(TX_M2_SRC)):$(abspath $(TX_M3_SRC)):$(RX_BSC_PATH)
BSC_PATH := $(BSC_PATH_$(TARGET))
BSC_FLAGS := -u -check-assert -warn-action-shadowing -warn-method-urgency -show-schedule

PRODUCTION_TOP := mkRxTop
PRODUCTION_FILE := $(INT_SRC)/RxTop.bsv
PRODUCTION_DIR := build/production/verilog

ifeq ($(strip $(TOP)),)
$(error Unsupported TARGET '$(TARGET)'; implemented targets: rx_top tx_rx_loopback)
endif

.PHONY: preflight compile verilog run test test-rx-top test-tx-rx-loopback \
	test-long test-rx-top-long test-tx-rx-loopback-long production-verilog clean

preflight:
	@cmp -s $(TX_M2_SRC)/CommonTypes.bsv $(TX_M3_SRC)/CommonTypes.bsv || { echo "CommonTypes.bsv (TX m2 vs m3) diverged"; exit 2; }
	@cmp -s $(TX_M2_SRC)/TxTypes.bsv $(TX_M3_SRC)/TxTypes.bsv || { echo "TxTypes.bsv (TX m2 vs m3) diverged"; exit 2; }
	@for d in $(RX_M4_SRC) $(RX_M5_SRC) $(RX_M6_SRC) $(RX_M7_SRC) $(RX_M8_SRC); do \
		cmp -s $(TX_M2_SRC)/CommonTypes.bsv $$d/CommonTypes.bsv || { echo "CommonTypes.bsv (TX m2 vs $$d) diverged"; exit 2; }; \
		cmp -s $(TX_M2_SRC)/TxTypes.bsv $$d/TxTypes.bsv || { echo "TxTypes.bsv (TX m2 vs $$d) diverged"; exit 2; }; \
		cmp -s $(RX_M4_SRC)/RxTypes.bsv $$d/RxTypes.bsv || { echo "RxTypes.bsv (RX m4 vs $$d) diverged"; exit 2; }; \
	done
	@for d in ../m4 ../m5 ../m6 ../m7 ../m8; do \
		for f in model/rx_types.py bfm/common.py lib/cocotb_bsv/__init__.py lib/cocotb_bsv/methods.py lib/cocotb_bsv/packing.py lib/cocotb_bsv/pipes.py lib/cocotb_bsv/timing.py; do \
			cmp -s cocotb/$$f $$d/cocotb/$$f || { echo "$$f (integration vs $$d) diverged"; exit 2; }; \
		done; \
	done
	@for d in ../m4 ../m5 ../m6; do \
		cmp -s cocotb/model/wire.py $$d/cocotb/model/wire.py || { echo "model/wire.py (integration vs $$d) diverged"; exit 2; }; \
	done
	@for f in model/common.py model/m2.py; do \
		cmp -s cocotb/$$f ../m2/cocotb/$$f || { echo "$$f (RX integration vs TX m2) diverged"; exit 2; }; \
		cmp -s cocotb/$$f ../m3/cocotb/$$f || { echo "$$f (RX integration vs TX m3) diverged"; exit 2; }; \
	done
	@cmp -s cocotb/model/m3.py ../m3/cocotb/model/m3.py || { echo "model/m3.py (RX integration vs TX m3) diverged"; exit 2; }
	@echo "RX preflight OK: BSV contracts and Python mirrors are byte-identical"

compile: preflight
	mkdir -p $(BUILD_DIR)/bsc
	$(BSC) $(BSC_FLAGS) -sim -p $(BSC_PATH) \
		-bdir $(BUILD_DIR)/bsc -simdir $(BUILD_DIR)/bsc \
		-info-dir $(BUILD_DIR)/bsc -g $(TOP) $(TOP_FILE)

verilog: preflight
	mkdir -p $(BUILD_DIR)/verilog
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(BUILD_DIR)/verilog -vdir $(BUILD_DIR)/verilog \
		-info-dir $(BUILD_DIR)/verilog -g $(TOP) $(TOP_FILE)

run: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) \
		$(PYTHON) cocotb/sim_runner.py --target $(TARGET) --suite $(SUITE)

test: test-rx-top test-tx-rx-loopback

test-rx-top:
	$(MAKE) run TARGET=rx_top SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-tx-rx-loopback:
	$(MAKE) run TARGET=tx_rx_loopback SUITE=short SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-long: test-rx-top-long test-tx-rx-loopback-long

test-rx-top-long:
	$(MAKE) run TARGET=rx_top SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-tx-rx-loopback-long:
	$(MAKE) run TARGET=tx_rx_loopback SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

production-verilog: preflight
	rm -rf $(PRODUCTION_DIR)
	mkdir -p $(PRODUCTION_DIR)
	$(BSC) $(BSC_FLAGS) -elab -verilog -remove-dollar -p $(BSC_PATH_rx_top) \
		-bdir $(PRODUCTION_DIR) -vdir $(PRODUCTION_DIR) \
		-info-dir $(PRODUCTION_DIR) -g $(PRODUCTION_TOP) $(PRODUCTION_FILE)

clean:
	rm -rf build
