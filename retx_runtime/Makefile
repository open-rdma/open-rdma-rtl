include $(abspath ../shared/make/modules.mk)
PYTHON ?= python3

.PHONY: test test-long clean
test:
	PYTHONPATH="$(FLOW_PYTHONPATH):$(CURDIR)$${PYTHONPATH:+:$${PYTHONPATH}}" \
		$(PYTHON) -m unittest discover -s tests -v
test-long: test
clean:
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
