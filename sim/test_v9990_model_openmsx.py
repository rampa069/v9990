"""Check the V9990 reference model against openMSX (GFX9000 extension).

Needs the openMSX oracle host (see openmsx_host.py); skipped unless
V9990_OPENMSX=1:

    V9990_OPENMSX=1 ../.venv/bin/python -m pytest -v test_v9990_model_openmsx.py
"""

import os

import pytest

import v9990_model as vm
import v9990_sequences

pytestmark = pytest.mark.skipif(os.environ.get("V9990_OPENMSX") != "1",
                                reason="set V9990_OPENMSX=1 to run against openMSX")

# Bits of a read that depend on its exact time, per port: P#5 VR / HR / EO,
# P#6 the line and frame interrupt flags (not modelled yet).
TIMING_BITS = {0x65: vm.STATUS_TIMING, 0x66: 0x03}


def run_model(ops, after=None):
    """Run a sequence on the model: the reads (port, value) and the model.
    after: a model whose VRAM and palette the chip keeps (a reset does not
    clear them)."""
    model = vm.V9990()
    if after is not None:
        model.vram[:] = after.vram
        model.palette[:] = after.palette
    reads = []
    for op in ops:
        if op[0] == "out":
            model.write(op[1], op[2])
        elif op[0] == "block":
            for v in op[2]:
                model.write(op[1], v)
        elif op[0] == "in":
            reads.append((op[1], model.read(op[1])))
        elif op[0] == "tr_out_p":
            for v in op[3]:
                model.write(op[1], v)
        elif op[0] == "tr_in_p":
            for _ in range(op[3]):
                reads.append((op[1], model.read(op[1])))
        # "delay": nothing to do
    return reads, model


def compare(reads, exp_reads, regs, palette, vram, model, who):
    assert len(reads) == len(exp_reads)
    for k, (got, (port, exp)) in enumerate(zip(reads, exp_reads)):
        mask = 0xFF & ~TIMING_BITS.get(port, 0)
        assert got & mask == exp & mask, f"read {k} port {port:02x}: {who} {got:02x} model {exp:02x}"
    for r in range(32):
        assert regs[r] == model.regs[r], f"R#{r}: {who} {regs[r]:02x} model {model.regs[r]:02x}"
    assert bytes(palette) == bytes(model.palette), f"palette: {who} {bytes(palette).hex()} model {model.palette.hex()}"
    bad = [a for a in range(vm.VRAM_SIZE) if vram[a] != model.vram[a]]
    assert not bad, f"VRAM: {len(bad)} bytes differ, first {bad[0]:05x}: {who} {vram[bad[0]]:02x} model {model.vram[bad[0]]:02x}"


ALL_SEQUENCES = {**v9990_sequences.SEQUENCES, **v9990_sequences.SEQUENCES_CMD}


@pytest.mark.parametrize("seq", list(ALL_SEQUENCES))
def test_io(seq):
    import v9990_oracle as oracle
    ops = ALL_SEQUENCES[seq]()
    o_reads, o_vram, o_regs, o_pal = oracle.run_io(ops)
    m_reads, model = run_model(ops)
    compare(o_reads, m_reads, o_regs, o_pal, o_vram, model, "openMSX")


# -- Display scenes ------------------------------------------------------------

import numpy as np

import v9990_scenes


def expected_shot(vram, regs, palette, mcs):
    """The model's picture in the screenshot geometry (480, 640, 3) as
    openMSX 8-bit values, and a mask of the pixels it covers exactly (one
    display pixel per screenshot pixel, or two for B7, averaged)."""
    import v9990_oracle as oracle
    left, right, top, bottom, _ = vm.geometry(regs, mcs)
    mode = vm.display_mode(regs, mcs)
    bm = vm.Pattern(vram, regs, palette) if mode in ("P1", "P2") else vm.Bitmap(vram, regs, palette, mcs)
    pclk = vm.PIXEL_CLOCKS[mode]
    border = vm.pal_rgb(palette, regs[15] & 63)
    exp = np.zeros((240, 640, 3), dtype=np.float64)
    for k in range(240):
        line = oracle.SHOT_Y0 + k
        cols = [border] * 640
        if top <= line < bottom:
            row = bm.line(line - top)
            for j in range(640):
                t = oracle.SHOT_X0 + oracle.SHOT_CLOCKS * j
                if left <= t < right:
                    px = [row[(tt - left) // pclk] for tt in range(t, t + oracle.SHOT_CLOCKS, pclk)]
                    exp[k, j] = np.mean(oracle.to_shot(np.array(px)), axis=0)
                    continue
        for j in range(640):
            t = oracle.SHOT_X0 + oracle.SHOT_CLOCKS * j
            if not (top <= line < bottom and left <= t < right):
                exp[k, j] = oracle.to_shot(np.array(border))
    return np.repeat(exp, 2, axis=0)


def compare_shot(name, got, exp):
    """Assert an openMSX screenshot matches the model's (within one level);
    if not, both go to /tmp/v9990_<name>_openmsx.png and _model.png."""
    diff = np.abs(got - exp).max(axis=2) > 1.0
    if diff.any():
        ys, xs = np.nonzero(diff)
        from PIL import Image
        Image.fromarray(got.astype(np.uint8)).save(f"/tmp/v9990_{name}_openmsx.png")
        Image.fromarray(exp.astype(np.uint8)).save(f"/tmp/v9990_{name}_model.png")
        y, x = ys[0], xs[0]
        raise AssertionError(f"{name}: {diff.sum()} pixels differ, first at row {y} col {x}: "
                             f"openMSX {got[y, x]} model {exp[y, x]}")


@pytest.fixture(scope="module")
def shots():
    import v9990_oracle as oracle
    scenes = [oracle.Scene(n, *make()) for n, make in v9990_scenes.SCENES.items()]
    oracle.dac()
    return oracle.run_scenes(scenes)


@pytest.mark.parametrize("name", list(v9990_scenes.SCENES))
def test_scene(shots, name):
    vram, regs, pal, mcs = v9990_scenes.SCENES[name]()
    exp = expected_shot(vram, regs, pal, mcs)
    compare_shot(name, shots[name], exp)


# -- Traces of real software ---------------------------------------------------

import v9990_trace


@pytest.fixture(scope="module")
def trace_shots():
    """openMSX showing the t1 state of each trace (loaded like a scene)."""
    import v9990_oracle as oracle
    oracle.dac()
    states = {d.name: v9990_trace.load_state(d, "t1") for d in v9990_trace.traces()}
    return states, oracle.run_scenes([oracle.Scene(f"trace_{n}", s.vram, s.regs[:29], s.palette)
                                      for n, s in states.items()])


@pytest.mark.parametrize("name", [d.name for d in v9990_trace.traces()])
def test_trace(trace_shots, name):
    states, shots = trace_shots
    s = states[name]
    exp = expected_shot(s.vram, s.regs, s.palette, False)
    compare_shot(f"trace_{name}", shots[f"trace_{name}"], exp)
