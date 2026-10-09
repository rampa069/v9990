"""Build the V9990 simulation with NVC and run cocotb test modules."""

import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

SIM_DIR = Path(__file__).resolve().parent
RTL_DIR = SIM_DIR.parent / "rtl"
BUILD_DIR = SIM_DIR / "sim_build"
TOPLEVEL = "v9990_tb"

# Analysis order matters: each unit after the ones it instantiates.
RTL_SOURCES = [
    "v9990_pkg.vhd",
    "v9990_vram_bram.vhd",
    "v9990_cpu.vhd",
    "v9990_raster.vhd",
    "v9990_bitmap.vhd",
    "v9990_pattern.vhd",
    "v9990_sprites.vhd",
    "v9990_cmd.vhd",
    "v9990_core.vhd",
]
TB_SOURCES = ["tb/v9990_tb.vhd"]
BUILD_ARGS = ["--std=2008"]

# The cocotb runner passes sys.path to the simulator as PYTHONPATH; make the
# helper modules in sim/ importable from the tests.
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))


def build():
    runner = get_runner("nvc")
    sources = [RTL_DIR / s for s in RTL_SOURCES] + [SIM_DIR / s for s in TB_SOURCES]
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=BUILD_DIR,
        build_args=BUILD_ARGS,
        always=True,
    )
    return runner


def test(runner, test_module, testcase=None):
    """Run one cocotb test module; returns the results XML path."""
    capture_dir = BUILD_DIR / "frames" / test_module
    capture_dir.mkdir(parents=True, exist_ok=True)
    return runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module=test_module,
        testcase=testcase,
        test_dir=SIM_DIR / "tests",
        build_dir=BUILD_DIR,
        parameters={"CAPTURE_DIR": str(capture_dir)},
        extra_env={"V9990_CAPTURE_DIR": str(capture_dir)},
        # The IEEE packages warn about 'U' operands before reset.
        test_args=["--ieee-warnings=off"],
        results_xml=str(BUILD_DIR / f"results_{test_module}.xml"),
        log_file=BUILD_DIR / f"{test_module}.log",
    )
