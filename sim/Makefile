# V9990 simulation (NVC + cocotb).  Run `make setup` once.

PYTHON ?= ../.venv/bin/python
T ?=

.PHONY: setup test test-quick test-openmsx clean

setup:
	python3 -m venv ../.venv
	../.venv/bin/pip install -r requirements.txt

test:
	$(PYTHON) -m pytest -v test_v9990.py -k "test_module$(if $(T), and $(T))"

# One test of each area: I/O, timing, display, commands.
QUICK = test_v9990_io.py::io_basic test_v9990_timing.py::line_and_frame \
        test_v9990_display.py::render_b1_bp4 test_v9990_cmd.py::cmd_b4

test-quick:
	V9990_QUICK="$(QUICK)" $(PYTHON) -m pytest -v test_v9990.py -k test_quick

# The reference model against openMSX (needs the oracle host, see openmsx_host.py).
test-openmsx:
	V9990_OPENMSX=1 $(PYTHON) -m pytest -v test_v9990_model_openmsx.py

clean:
	rm -rf sim_build __pycache__ tests/__pycache__ .pytest_cache
