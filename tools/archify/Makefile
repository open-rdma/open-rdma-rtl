# 从 active BSV 源码重新生成 .archify/ 接口图。
TOOLS := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
FLOW_ROOT := $(abspath $(TOOLS)/../..)
ARCH := $(FLOW_ROOT)/.archify
PY ?= python3

.PHONY: all ports preview check clean
all: ports preview
ports:
	mkdir -p $(ARCH)
	OPENRDMA_FLOW_ROOT=$(FLOW_ROOT) $(PY) $(TOOLS)/extract.py $(ARCH)/inventory.json
	$(PY) $(TOOLS)/gen.py $(ARCH)/inventory.json $(ARCH)/ports.html
preview:
	$(PY) $(TOOLS)/preview.py $(ARCH)/ports.html $(ARCH)/ports.preview.png
check:
	mkdir -p $(ARCH)
	OPENRDMA_FLOW_ROOT=$(FLOW_ROOT) $(PY) $(TOOLS)/extract.py $(ARCH)/inventory.json
clean:
	rm -f $(ARCH)/inventory.json
