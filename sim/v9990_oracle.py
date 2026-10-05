"""openMSX with the GFX9000 extension (V9990) as an oracle.

Same setup as openmsx_oracle (Docker image on F18A_OPENMSX_HOST): the Z80
runs a port sequence (openmsx_oracle.z80_program) from the H.TIMI hook, then
the V9990 registers, palette and VRAM are dumped through the debugger.

    from v9990_oracle import run_io
    reads, vram, regs, palette = run_io([("out", 0x64, 0), ("in", 0x63)])
"""

import subprocess
import tempfile
from pathlib import Path

from openmsx_oracle import HOST, IMAGE, PROG_ADDR, READS_ADDR, REMOTE_DIR, z80_program

DEVICE = "Sunrise GFX9000"


def run_io(ops, machine="C-BIOS_MSX2"):
    """Run a sequence of port accesses (ports 60h-6Fh) in openMSX.

    The V9990 starts as after power-on (openMSX: registers 0, VRAM 00h / FFh
    every 512 bytes, palette 9Fh 1Fh 1Fh 00h).  Returns (reads, vram, regs,
    palette): the IN results, the 512 KB physical VRAM, the 64 registers and
    the 256 palette bytes.
    """
    code, n_reads = z80_program(list(ops))
    tcl = ["set throttle on", "set maxframeskip 0", "proc doit {} {",
           "  debug break",
           "  vdpreg 1 [expr {[vdpreg 1] | 0x20}]",
           "  set f [open /work/prog.bin rb]; fconfigure $f -translation binary",
           f"  debug write_block memory {PROG_ADDR} [read $f]; close $f",
           f"  poke 0xFD9F 0xC3; poke 0xFDA0 {PROG_ADDR & 0xFF}; poke 0xFDA1 {PROG_ADDR >> 8}",
           "  debug cont",
           "  after time 1 { dump }", "}",
           "proc dump {} {",
           "  set f [open /work/reads.bin wb]; fconfigure $f -translation binary",
           f"  puts -nonewline $f [debug read_block memory {READS_ADDR} {max(n_reads, 1)}]; close $f",
           "  set f [open /work/regs.bin wb]; fconfigure $f -translation binary",
           f"  puts -nonewline $f [debug read_block {{{DEVICE} regs}} 0 64]; close $f",
           "  set f [open /work/palette.bin wb]; fconfigure $f -translation binary",
           f"  puts -nonewline $f [debug read_block {{{DEVICE} palette}} 0 256]; close $f",
           "  set f [open /work/vram.bin wb]; fconfigure $f -translation binary",
           f"  puts -nonewline $f [debug read_block {{{DEVICE} VRAM}} 0 524288]; close $f",
           "  exit", "}", "after time 2 { doit }"]
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        (workdir / "run.tcl").write_text("\n".join(tcl) + "\n")
        (workdir / "prog.bin").write_bytes(code)
        remote = f"{REMOTE_DIR}/run9990"
        subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, f"rm -rf {remote} && mkdir -p {remote}"], check=True)
        subprocess.run(["scp", "-q", f"{workdir}/run.tcl", f"{workdir}/prog.bin", f"{HOST}:{remote}/"], check=True)
        cmd = (f"cd {remote} && docker run --rm -v $PWD:/work {IMAGE} sh -c "
               f"'xvfb-run -a -s \"-screen 0 1024x768x24\" timeout 300 "
               f"openmsx -machine {machine} -ext gfx9000 -script /work/run.tcl >/work/openmsx.log 2>&1'")
        subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, cmd], check=True)
        for f in ("reads.bin", "regs.bin", "palette.bin", "vram.bin"):
            subprocess.run(["scp", "-q", f"{HOST}:{remote}/{f}", f"{workdir}/"], check=True)
        reads = list((workdir / "reads.bin").read_bytes()[:n_reads])
        regs = list((workdir / "regs.bin").read_bytes())
        palette = (workdir / "palette.bin").read_bytes()
        vram = (workdir / "vram.bin").read_bytes()
    return reads, vram, regs, palette


# -- Display scenes -----------------------------------------------------------

import numpy as np
from dataclasses import dataclass, field

from PIL import Image

import v9990_model as vm

# Screenshot geometry (V9990SDLRasterizer): 320 x 240 window of 8 clocks per
# pixel from clock 256 and line 15 (NTSC, normal modes); taken double size
# (640 x 480, 4 clocks per pixel, lines doubled).
SHOT_X0 = 256
SHOT_CLOCKS = 4
SHOT_Y0 = 15


@dataclass
class Scene:
    name: str
    vram: bytes                     # physical, 512 KB
    regs: list                      # R#0-R#28
    palette: bytes = field(default_factory=lambda: bytes([0x9F, 0x1F, 0x1F, 0] * 64))
    mcs: bool = False


def _tcl_scene(i, s, vram_file, pal_file):
    regs = list(s.regs) + [0] * (64 - len(s.regs))
    lines = [f"proc scene{i} {{}} {{", "  debug break", "  set ::videosource GFX9000",
             f"  debug write ioports 0x67 {1 if s.mcs else 0}",
             f"  set f [open /work/{vram_file} rb]; fconfigure $f -translation binary",
             f"  debug write_block {{{DEVICE} VRAM}} 0 [read $f]; close $f",
             f"  set f [open /work/{pal_file} rb]; fconfigure $f -translation binary",
             f"  debug write_block {{{DEVICE} palette}} 0 [read $f]; close $f"]
    for r in list(range(6, 29)):
        if r == 8:
            continue
        lines.append(f"  debug write {{{DEVICE} regs}} {r} {regs[r]}")
    lines.append(f"  debug write {{{DEVICE} regs}} 8 {regs[8]}")
    lines.append("  debug cont")
    lines.append(f"  after time 0.3 {{ screenshot -raw -doublesize -prefix /work/{s.name}__; scene{i + 1} }}")
    lines.append("}")
    return "\n".join(lines)


def run_scenes(scenes):
    """Screenshots (480, 640, 3) of the scenes, one openMSX session."""
    tcl = ["set throttle on", "set maxframeskip 0"]
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        for i, s in enumerate(scenes):
            (workdir / f"{s.name}.vram").write_bytes(bytes(s.vram))
            (workdir / f"{s.name}.pal").write_bytes(bytes(s.palette))
            tcl.append(_tcl_scene(i, s, f"{s.name}.vram", f"{s.name}.pal"))
        tcl.append(f"proc scene{len(scenes)} {{}} {{ exit }}")
        tcl.append("after time 2 { scene0 }")
        (workdir / "run.tcl").write_text("\n".join(tcl) + "\n")
        remote = f"{REMOTE_DIR}/run9990"
        subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, f"rm -rf {remote} && mkdir -p {remote}"], check=True)
        subprocess.run(["scp", "-q", "-r", f"{workdir}/.", f"{HOST}:{remote}/"], check=True)
        cmd = (f"cd {remote} && docker run --rm -v $PWD:/work {IMAGE} sh -c "
               f"'xvfb-run -a -s \"-screen 0 1024x768x24\" timeout 600 "
               f"openmsx -machine C-BIOS_MSX2 -ext gfx9000 -script /work/run.tcl >/work/openmsx.log 2>&1'")
        subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, cmd], check=True)
        subprocess.run(["scp", "-q", f"{HOST}:{remote}/*.png", f"{workdir}/"], check=True)
        shots = {}
        for s in scenes:
            png = next(workdir.glob(f"{s.name}__*.png"))
            shots[s.name] = np.asarray(Image.open(png).convert("RGB")).astype(np.int32)
    return shots


_DAC = None


def dac():
    """openMSX 5-bit level -> 8-bit value, per channel (a BD16 ramp)."""
    global _DAC
    if _DAC is None:
        regs = [0] * 29
        regs[6], regs[8] = 0x83, 0x80                       # B1, 16 bpp, display on
        vram = vm.power_on_vram()
        for y in range(212):
            ch = y // 70
            for x in range(256):
                lvl = x // 8
                c = lvl << (5, 10, 0)[ch] if ch < 3 else 0  # R, G, B ramps
                for k, v in enumerate((c & 0xFF, c >> 8)):
                    vram[vm.vram_phys(2 * (x + 256 * y) + k, 0x80)] = v
        shot = run_scenes([Scene("dac", vram, regs)])["dac"]
        left, _, top, _, _ = vm.geometry(regs)
        _DAC = []
        for ch in range(3):
            row = 2 * (top - SHOT_Y0 + ch * 70 + 30)
            levels = []
            for lvl in range(32):
                col = (left + (lvl * 8 + 4) * 8 - SHOT_X0) // SHOT_CLOCKS
                levels.append(int(shot[row, col, ch]))
            _DAC.append(levels)
    return _DAC


def to_shot(rgb5):
    """Model colors (..., 3) of 5-bit levels to openMSX 8-bit values."""
    d = dac()
    out = np.zeros(np.shape(rgb5), dtype=np.int32)
    for ch in range(3):
        out[..., ch] = np.asarray(d[ch])[np.asarray(rgb5)[..., ch]]
    return out
