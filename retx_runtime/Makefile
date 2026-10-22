PYTHON ?= python3

.PHONY: test test-long clean

test:
	$(PYTHON) -m unittest discover -s tests -v

test-long: test

clean:
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
