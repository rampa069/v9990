"""pytest entry point: builds the simulation once and runs the cocotb modules.

    make test                         # everything
    make test T=test_v9990_cmd        # one module
"""

import os

import pytest
from cocotb_tools.check_results import get_results

import runner

MODULES = [
    "test_v9990_io",
    "test_v9990_timing",
    "test_v9990_display",
    "test_v9990_cmd",
    "test_v9990_trace",
]

_built = {}


def sim():
    if "runner" not in _built:
        _built["runner"] = runner.build()
    return _built["runner"]


def _check(xml, module):
    try:
        _, failed = get_results(xml)
    except SystemExit:
        failed = "some"
    assert not failed, f"{failed} cocotb test(s) failed in {module}, see sim/sim_build/{module}.log"


@pytest.mark.parametrize("module", MODULES)
def test_module(module):
    _check(runner.test(sim(), module), module)


def _quick_cases():
    """V9990_QUICK: "module.py::test ..." pairs, grouped per module."""
    groups = {}
    for item in os.environ.get("V9990_QUICK", "").split():
        mod, case = item.split("::")
        groups.setdefault(mod.removesuffix(".py"), []).append(case)
    return list(groups.items())


@pytest.mark.parametrize("module,cases", _quick_cases(), ids=[m for m, _ in _quick_cases()])
def test_quick(module, cases):
    _check(runner.test(sim(), module, testcase=cases), module)
