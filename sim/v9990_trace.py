"""Traces of real software, captured in openMSX (GFX9000) by
openmsx/capture.tcl: the V9990 state (VRAM, registers, palette and the
selected register) when a command is started at t0, the port accesses from
there and the state at the first command started some time later (t1).

The game data stays out of git: each trace is a directory under
../tmp/traces (or V9990_TRACES) with t0_* and t1_* (vram.bin, regs.bin,
palette.bin, regsel.txt) and accesses.log ("pp vv" writes, "pp r" reads).
"""

import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np

import v9990_model as vm

TRACES = Path(os.environ.get("V9990_TRACES", Path(__file__).resolve().parent.parent / "tmp" / "traces"))
FILES = ("vram.bin", "regs.bin", "palette.bin", "regsel.txt")


@dataclass
class State:
    vram: bytearray
    regs: list
    palette: bytearray
    regsel: int


def complete(d):
    return all((d / f"{t}_{f}").exists() for t in ("t0", "t1") for f in FILES) and (d / "accesses.log").exists()


def traces():
    """The trace directories found."""
    return sorted(d for d in TRACES.glob("*") if d.is_dir() and complete(d)) if TRACES.is_dir() else []


def load_state(d, tag):
    return State(bytearray((d / f"{tag}_vram.bin").read_bytes()), list((d / f"{tag}_regs.bin").read_bytes()),
                 bytearray((d / f"{tag}_palette.bin").read_bytes()), int((d / f"{tag}_regsel.txt").read_text()))


def load_ops(d):
    """The accesses as v9990_sequences ops: ("out", port, value), ("in", port)."""
    ops = []
    for line in (d / "accesses.log").read_text().split("\n"):
        if line:
            p, v = line.split()
            ops.append(("in", int(p, 16)) if v == "r" else ("out", int(p, 16), int(v, 16)))
    return ops


def model_from(state, mcs=False):
    """A model with the chip state of a snapshot."""
    m = vm.V9990()
    m.vram[:] = state.vram
    m.palette[:] = state.palette
    m.regs[:] = state.regs
    name, width = vm.cmd_mode(m.regs)
    for r in range(32, 52):
        m.cmd.set_reg(r, m.regs[r], name, width)
    m.read_buffer = m._vram_read(m._addr(3))
    m.regsel = state.regsel
    m.status = 4 if mcs else 0
    return m


def with_ce_waits(ops, regsel):
    """The ops with a CE = 0 wait before every write to a command register
    (R#32-R#52): the game polls CE itself, at its own speed."""
    out = []
    for op in ops:
        if op[0] == "out" and op[1] == 0x64:
            regsel = op[2]
        elif op[1] == 0x63:
            if op[0] == "out":
                if 32 <= regsel & 0x3F <= 52:
                    out.append(("poll", 0x65, 0x01, 0))
                if not regsel & 0x80:
                    regsel = (regsel & 0xC0) | ((regsel + 1) & 0x3F)
            elif not regsel & 0x40:
                regsel = ((regsel + 1) & ~0x40) & 0xFF
        out.append(op)
    return out


def replay_model(state, ops):
    m = model_from(state)
    for op in ops:
        if op[0] == "out":
            m.write(op[1], op[2])
        elif op[0] == "in":
            m.read(op[1])
    m.cmd.sync()
    return m


def picture(vram, regs, palette):
    """The display area as (lines, pixels, 3) 8-bit RGB (no sprites)."""
    _, _, top, bottom, _ = vm.geometry(regs)
    mode = vm.display_mode(regs)
    bm = vm.Pattern(vram, regs, palette) if mode in ("P1", "P2") else vm.Bitmap(vram, regs, palette)
    return np.array([[[(c << 3) | (c >> 2) for c in p] for p in bm.line(y)] for y in range(bottom - top)],
                    dtype=np.uint8)
