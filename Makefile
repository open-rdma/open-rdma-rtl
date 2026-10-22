# Convenience wrapper: run every suite. Each module folder keeps its own
# self-contained Makefile; this file only dispatches into them.
PYTHON ?= python3
SIM ?= verilator
BSC ?= bsc

RX_MODULES := m4 m5 m6 m7 m8
RX_INTEGRATION := rx_integration
RETX_MODULES := m9 m10 m11
RETX_INTEGRATION := retx_integration

.PHONY: test test-all test-long test-m0chain test-negative \
	preflight-rx compile-rx verilog-rx test-rx test-rx-long \
	production-rx-verilog clean-rx clean \
	test-retx-contract test-retx-units test-retx-integration test-retx test-retx-all clean-retx

test-all:
	$(MAKE) -C m0 test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m1 test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m1 test TARGET=compactor SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m2 test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m3 test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-rx SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C integration test-integration SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C integration test-m0chain SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-retx SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test: test-all

test-long:
	$(MAKE) -C m0 test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m1 test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m2 test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C m3 test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) test-rx-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C integration test-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C integration test-m0chain-long SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-negative:
	$(MAKE) -C m1 test-negative SIM=icarus PYTHON=$(PYTHON) BSC=$(BSC)
	$(MAKE) -C integration test-negative SIM=icarus PYTHON=$(PYTHON) BSC=$(BSC)

preflight-rx:
	$(MAKE) -C $(RX_INTEGRATION) preflight BSC=$(BSC)

compile-rx: preflight-rx
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module compile BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION) compile TARGET=rx_top BSC=$(BSC) PYTHON=$(PYTHON)
	$(MAKE) -C $(RX_INTEGRATION) compile TARGET=tx_rx_loopback BSC=$(BSC) PYTHON=$(PYTHON)

verilog-rx: preflight-rx
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module verilog BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION) verilog TARGET=rx_top BSC=$(BSC) PYTHON=$(PYTHON)
	$(MAKE) -C $(RX_INTEGRATION) verilog TARGET=tx_rx_loopback BSC=$(BSC) PYTHON=$(PYTHON)

test-rx: preflight-rx
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module test SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION) test SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON)

test-rx-long: preflight-rx
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module test-long SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON); \
	done
	$(MAKE) -C $(RX_INTEGRATION) test-long SIM=$(SIM) BSC=$(BSC) PYTHON=$(PYTHON)

production-rx-verilog: preflight-rx
	$(MAKE) -C $(RX_INTEGRATION) production-verilog BSC=$(BSC) PYTHON=$(PYTHON)

clean-rx:
	@set -e; for module in $(RX_MODULES); do \
		$(MAKE) -C $$module clean; \
	done
	$(MAKE) -C $(RX_INTEGRATION) clean

test-retx-contract:
	$(MAKE) -C retx_contract test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-retx-units:
	@set -e; for module in $(RETX_MODULES); do \
		$(MAKE) -C $$module test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC); \
	done
	$(MAKE) -C retx_runtime test PYTHON=$(PYTHON)

test-retx-integration:
	$(MAKE) -C $(RETX_INTEGRATION) test SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

test-retx: test-retx-contract test-retx-units test-retx-integration

test-retx-all: test-retx
	$(MAKE) test-all SIM=$(SIM) PYTHON=$(PYTHON) BSC=$(BSC)

clean-retx:
	$(MAKE) -C retx_contract clean
	@set -e; for module in $(RETX_MODULES); do $(MAKE) -C $$module clean; done
	$(MAKE) -C retx_runtime clean
	$(MAKE) -C $(RETX_INTEGRATION) clean

clean:
	$(MAKE) -C m0 clean
	$(MAKE) -C m1 clean
	$(MAKE) -C m2 clean
	$(MAKE) -C m3 clean
	$(MAKE) clean-rx
	$(MAKE) -C integration clean
