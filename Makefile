# OpenRDMA-flow 根调度入口；目录映射只定义在 shared/make/modules.mk。
include $(abspath shared/make/modules.mk)

PYTHON ?= python3
SIM ?= verilator
BSC ?= bsc

TX_MODULES := $(M0_DIR) $(M1_DIR) $(M2_DIR) $(M3_DIR)
RX_MODULES := $(M4_DIR) $(M5_DIR) $(M6_DIR) $(M7_DIR) $(M8_DIR)
RETX_MODULES := $(M9_DIR) $(M10_DIR) $(M11_DIR)
ALL_MODULES := $(TX_MODULES) $(RX_MODULES) $(RETX_MODULES)
ALL_INTEGRATIONS := $(TX_INTEGRATION_DIR) $(RX_INTEGRATION_DIR) $(RETX_INTEGRATION_DIR) $(E2E_INTEGRATION_DIR)

.PHONY: preflight generate-retx test test-all test-long test-negative \
	compile-rx verilog-rx test-rx test-rx-long production-rx-verilog \
	test-retx-contract test-retx-units test-retx-integration test-retx \
	test-retx-all test-e2e clean-rx clean-retx clean

preflight:
	FLOW_ROOT=$(FLOW_ROOT) RETX_GENERATED_DIR=$(RETX_GENERATED_DIR) \
		PYTHONPATH="$(FLOW_PYTHONPATH)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) shared/tools/preflight.py

generate-retx:
	$(MAKE) -C $(RETX_CONTRACT_DIR) generate PYTHON=$(PYTHON)

test-all: preflight
	$(MAKE) -C $(M0_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M1_DIR) test TARGET=dma SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M1_DIR) test TARGET=compactor SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M2_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M3_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-rx SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(TX_INTEGRATION_DIR) test-integration SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(TX_INTEGRATION_DIR) test-m0chain SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-retx SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-e2e SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test: test-all

test-long: preflight
	$(MAKE) -C $(M0_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M1_DIR) test-long TARGET=dma SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M1_DIR) test-long TARGET=compactor SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M2_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(M3_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-rx-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(TX_INTEGRATION_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(TX_INTEGRATION_DIR) test-m0chain-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(RETX_CONTRACT_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	@set -e; for module in $(RETX_MODULES); do \
		$(MAKE) -C $$module test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC); \
	done
	$(MAKE) -C $(RETX_RUNTIME_DIR) test-long PYTHON=$(PYTHON)
	$(MAKE) -C $(RETX_INTEGRATION_DIR) test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-e2e SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-negative: preflight
	$(MAKE) -C $(M1_DIR) test-negative TARGET=dma SIM=icarus PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C $(TX_INTEGRATION_DIR) test-negative TARGET=integration SIM=icarus PYTHON=$(PYTHON) BSC=$(BSC)

compile-rx: preflight
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module compile BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION_DIR) compile TARGET=rx_top BSC=$(BSC) PYTHON=$(PYTHON)
	$(MAKE) -C $(RX_INTEGRATION_DIR) compile TARGET=tx_rx_loopback BSC=$(BSC) PYTHON=$(PYTHON)

verilog-rx: preflight
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module verilog BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION_DIR) verilog TARGET=rx_top BSC=$(BSC) PYTHON=$(PYTHON)
	$(MAKE) -C $(RX_INTEGRATION_DIR) verilog TARGET=tx_rx_loopback BSC=$(BSC) PYTHON=$(PYTHON)

test-rx: preflight
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module test SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION_DIR) test SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON)

test-rx-long: preflight
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module test-long SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION_DIR) test-long SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON)

production-rx-verilog: preflight
	$(MAKE) -C $(RX_INTEGRATION_DIR) production-verilog BSC=$(BSC) PYTHON=$(PYTHON)

test-retx-contract:
	$(MAKE) -C $(RETX_CONTRACT_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-retx-units:
	@set -e; for module in $(RETX_MODULES); do \
		$(MAKE) -C $$module test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC); \
	done
	$(MAKE) -C $(RETX_RUNTIME_DIR) test PYTHON=$(PYTHON)

test-retx-integration:
	$(MAKE) -C $(RETX_INTEGRATION_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-retx: preflight test-retx-contract test-retx-units test-retx-integration

test-e2e:
	$(MAKE) -C $(E2E_INTEGRATION_DIR) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-retx-all: test-all

clean-rx:
	@set -e; for module in $(RX_MODULES); do $(MAKE) -C $$module clean; done
	$(MAKE) -C $(RX_INTEGRATION_DIR) clean

clean-retx:
	@set -e; for module in $(RETX_MODULES); do $(MAKE) -C $$module clean; done
	$(MAKE) -C $(RETX_CONTRACT_DIR) clean
	$(MAKE) -C $(RETX_RUNTIME_DIR) clean
	$(MAKE) -C $(RETX_INTEGRATION_DIR) clean

clean:
	@set -e; for module in $(ALL_MODULES); do $(MAKE) -C $$module clean; done
	@set -e; for integration in $(ALL_INTEGRATIONS); do $(MAKE) -C $$integration clean; done
	$(MAKE) -C $(RETX_CONTRACT_DIR) clean
	$(MAKE) -C $(RETX_RUNTIME_DIR) clean
