# 通用 BSV 编译和 cocotb 执行规则；叶子 Makefile 只声明目标配置。
BSC ?= bsc
PYTHON ?= python3
SIM ?= verilator
SUITE ?= short
WAVES ?= 0

BUILD_DIR ?= build
BSC_DIR ?= $(BUILD_DIR)/bsc
VERILOG_DIR ?= $(BUILD_DIR)/verilog
BSC_FLAGS ?= -u -check-assert -warn-action-shadowing -warn-method-urgency -show-schedule
SIM_CONFIG ?= $(CURDIR)/cocotb/sim_config.py
SIM_TARGET ?= default
DEFINE_STANDARD_TESTS ?= 1
CLEAN_DIRS ?= $(BUILD_DIR)

.PHONY: preflight compile verilog run clean

preflight:
	$(MAKE) -C $(FLOW_ROOT) preflight PYTHON=$(PYTHON) BSC=$(BSC)

compile: preflight
	rm -rf $(BSC_DIR)
	mkdir -p $(BSC_DIR)
	$(BSC) $(BSC_FLAGS) -sim -p $(BSC_PATH) \
		-bdir $(BSC_DIR) -simdir $(BSC_DIR) -info-dir $(BSC_DIR) \
		-g $(TOP) $(TOP_FILE)

verilog: preflight
	rm -rf $(VERILOG_DIR)
	mkdir -p $(VERILOG_DIR)
	$(BSC) $(BSC_FLAGS) -verilog -p $(BSC_PATH) \
		-bdir $(VERILOG_DIR) -vdir $(VERILOG_DIR) -info-dir $(VERILOG_DIR) \
		-g $(TOP) $(TOP_FILE)

run: verilog
	TMPDIR=/tmp TMP=/tmp TEMP=/tmp SIM=$(SIM) BSC=$(BSC) WAVES=$(WAVES) \
		FLOW_ROOT=$(FLOW_ROOT) RETX_GENERATED_DIR=$(RETX_GENERATED_DIR) \
		PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) -m openrdma_flow_tb.sim.runner \
			--project-root $(CURDIR) --config $(SIM_CONFIG) \
			--target $(SIM_TARGET) --suite $(SUITE)

ifeq ($(DEFINE_STANDARD_TESTS),1)
.PHONY: test test-long
test:
	$(MAKE) run SUITE=$(SUITE) SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC) WAVES=$(WAVES)

test-long:
	$(MAKE) run SUITE=long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC) WAVES=$(WAVES)
endif

clean:
	rm -rf $(CLEAN_DIRS)
