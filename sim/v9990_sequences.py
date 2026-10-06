"""V9990 port sequences, run on openMSX (test_v9990_model_openmsx.py) and on
the RTL (tests/test_v9990_io.py), both compared with v9990_model.

Ops: ("out", port, value), ("in", port), ("block", port, data), ("delay",
n) as in openmsx_oracle.z80_program; ports are 60h-6Fh.  A display mode
change (R#6) takes effect at the next line, so the sequences wait after it
(MODE_DELAY) before using the new address mapping.
"""

VRAM, PAL, CMD, RDATA, RSEL, STAT, INTF, SYS = (0x60 + n for n in range(8))


# More than one line (2736 clocks, 228 Z80 T-states) in 13 T-state counts.
MODE_DELAY = [("delay", 30)]


def sel(reg, noinc_w=False, noinc_r=False):
    return [("out", RSEL, reg | (0x80 if noinc_w else 0) | (0x40 if noinc_r else 0))]


def set_regs(reg, values):
    """Write consecutive registers from reg (register select auto-increment)."""
    return sel(reg) + [("out", RDATA, v) for v in values]


def write_addr(addr, noinc=False):
    return set_regs(0, [addr & 0xFF, (addr >> 8) & 0xFF, ((addr >> 16) & 7) | (0x80 if noinc else 0)])


def read_addr(addr, noinc=False):
    return set_regs(3, [addr & 0xFF, (addr >> 8) & 0xFF, ((addr >> 16) & 7) | (0x80 if noinc else 0)])


def reads(port, n):
    return [("in", port)] * n


def seq_basic():
    ops = []
    # VRAM in P1 (R#6 = 0): write, read back across a bank boundary.
    ops += write_addr(0x3FFFC) + [("block", VRAM, list(range(0x10, 0x18)))]
    ops += read_addr(0x3FFFC) + reads(VRAM, 8)
    ops += write_addr(0x00100) + [("block", VRAM, [0xA5, 0x5A, 0x01, 0xFE])]
    ops += read_addr(0x000FE) + reads(VRAM, 8)
    # Palette: pointer to entry 2, write a few colors, read them back.
    ops += set_regs(14, [8]) + [("block", PAL, [0xFF, 0xFF, 0xFF, 0x81, 0x42, 0x23, 0x12, 0x34, 0x56])]
    ops += set_regs(14, [8]) + reads(PAL, 12)
    ops += set_regs(14, [11]) + reads(PAL, 3)               # pointer at the 4th byte
    # Registers: readable ones back, write-only ones as FFh.
    ops += set_regs(6, [0x00, 0x00, 0x00, 0x05, 0x34, 0x02, 0x08])
    ops += set_regs(15, [0x21, 0x35, 0x12, 0x01, 0x07, 0x02, 0x44, 0x81, 0x03, 0x04, 0x8F, 0x55, 0x77])
    ops += sel(0) + reads(RDATA, 64)
    ops += sel(53) + reads(RDATA, 4)
    # Status, interrupt flags.
    ops += reads(STAT, 2) + reads(INTF, 1) + [("out", INTF, 0xFF)] + reads(INTF, 1)
    # Unused / write-only ports.
    ops += [("in", 0x60 + p) for p in (4, 7, 8, 9, 10, 11, 12, 13, 14, 15)]
    return ops


def seq_masks():
    """All registers written with FFh, then with 00h, read back."""
    ops = sel(0) + [("out", RDATA, 0xFF)] * 32 + sel(0) + reads(RDATA, 32)
    ops += sel(6) + [("out", RDATA, 0x00)] * 23 + sel(6) + reads(RDATA, 23)
    return ops


def seq_maps():
    """VRAM address mapping in P1, P2 and the bitmap modes."""
    ops = []
    pattern = list(range(0x20, 0x30))
    for mode, addrs in ((0x00, (0x00000, 0x3FFF8, 0x7FFF8)),
                        (0x40, (0x00000, 0x77FF8, 0x78000, 0x7BFF8, 0x7C000, 0x7FFF8)),
                        (0x80, (0x00008, 0x3FFF8, 0x7FFF0)),
                        (0xC0, (0x00010, 0x40010))):
        ops += set_regs(6, [mode]) + MODE_DELAY
        for k, a in enumerate(addrs):
            ops += write_addr(a) + [("block", VRAM, [b ^ (mode + k) for b in pattern])]
        ops += read_addr(addrs[0]) + reads(VRAM, 20)
    # Read the data back in another mode (P1 sees the physical layout).
    ops += set_regs(6, [0x00]) + MODE_DELAY + read_addr(0x00000) + reads(VRAM, 8)
    ops += read_addr(0x40000) + reads(VRAM, 8)
    return ops


def seq_noinc():
    """No-increment bits: R#2 / R#5 bit 7, register select bits 7 / 6,
    R#13 bit 4 (palette read)."""
    ops = []
    ops += write_addr(0x01234, noinc=True) + [("block", VRAM, [1, 2, 3, 4])]
    ops += read_addr(0x01234, noinc=True) + reads(VRAM, 3)
    ops += read_addr(0x01233) + reads(VRAM, 3)
    ops += sel(0) + reads(RDATA, 6)
    ops += sel(15, noinc_w=True) + [("out", RDATA, v) for v in (1, 2, 3)]
    ops += sel(15, noinc_r=True) + reads(RDATA, 3)
    ops += sel(15) + reads(RDATA, 3)
    ops += sel(0x3F) + reads(RDATA, 3)                       # select wraps (bit 6 cleared)
    ops += sel(0xBE) + reads(RDATA, 4)
    ops += set_regs(13, [0x10]) + set_regs(14, [4]) + reads(PAL, 3)
    ops += set_regs(13, [0x00, 4]) + reads(PAL, 3)
    return ops


def seq_srs():
    """System reset state (P#7 SRS): writes ignored or written as 0, reads
    without side effects."""
    ops = []
    ops += set_regs(6, [0x80, 0x02, 0x40, 0x07]) + MODE_DELAY + set_regs(15, [0x11, 0x22])
    ops += write_addr(0x00200) + [("block", VRAM, [9, 8, 7, 6])]
    ops += read_addr(0x00200)
    ops += set_regs(14, [4]) + [("out", SYS, 0x03)]        # SRS (and MCS)
    ops += reads(STAT, 1) + sel(6) + reads(RDATA, 4)
    ops += reads(VRAM, 3) + reads(PAL, 3)
    ops += [("out", VRAM, 0x55), ("out", PAL, 0x1F), ("out", RSEL, 0x0F), ("out", RDATA, 0x33)]
    ops += [("out", SYS, 0x00)]                             # leave SRS
    ops += sel(0) + reads(RDATA, 32) + reads(STAT, 1)
    ops += set_regs(14, [0]) + reads(PAL, 4)
    ops += read_addr(0x00200) + reads(VRAM, 4)
    return ops


SEQUENCES = {
    "basic": seq_basic,
    "masks": seq_masks,
    "maps": seq_maps,
    "noinc": seq_noinc,
    "srs": seq_srs,
}


# -- Command engine ------------------------------------------------------------

import random as _random

STOP, LMMC, LMMV, LMCM, LMMM, CMMC, CMMK, CMMM, BMXL, BMLX, BMLL, LINE, SRCH, POINT, PSET, ADVN = range(16)

# Command modes: R#6, R#13 (image width 256 / 512 for P1 / P2).
CMD_MODES = {
    "p1": (0x00, 0x00),
    "p2": (0x40, 0x00),
    "b2": (0x80, 0x00),          # B1, 2 bpp, 256 wide
    "b4": (0x85, 0x00),          # B1, 4 bpp, 512 wide
    "b8": (0x86, 0x40),          # B1, 8 bpp (BD8), 512 wide
    "b16": (0x87, 0x00),         # B1, 16 bpp, 512 wide
}


def cmd(op, sx=0, sy=0, dx=0, dy=0, nx=0, ny=0, arg=0, log=0x0C, wm=0xFFFF, fc=0, bc=0):
    """Set R#32-R#51 and start the command (R#52)."""
    vals = [sx & 0xFF, sx >> 8, sy & 0xFF, sy >> 8, dx & 0xFF, dx >> 8, dy & 0xFF, dy >> 8,
            nx & 0xFF, nx >> 8, ny & 0xFF, ny >> 8, arg, log, wm & 0xFF, wm >> 8,
            fc & 0xFF, fc >> 8, bc & 0xFF, bc >> 8, op << 4]
    return sel(32) + [("block", RDATA, vals)]


WAIT_CE = [("poll", STAT, 0x01, 0)]


def _fill(seed, start, n):
    """Pseudo-random bytes written from logical start (P#0, 256 per block)."""
    rnd = _random.Random(seed)
    ops = write_addr(start)
    data = [rnd.randrange(256) for _ in range(n)]
    for k in range(0, n, 256):
        ops.append(("block", VRAM, data[k:k + 256]))
    return ops


def seq_cmd(mode, seed=1):
    r6, r13 = CMD_MODES[mode]
    rnd = _random.Random(seed)
    ops = set_regs(6, [r6]) + set_regs(13, [r13]) + MODE_DELAY
    ops += _fill(seed, 0, 1024) + _fill(seed + 1, 0x40000, 512)
    fc = rnd.randrange(65536)
    bc = rnd.randrange(65536)
    # A varied background for the logical operations: stripes of colors
    # (LMMV), crossed by an XOR.
    for k in range(6):
        ops += cmd(LMMV, dx=0, dy=20 + 20 * k, nx=0, ny=20, fc=rnd.randrange(65536)) + WAIT_CE
    ops += cmd(LMMV, dx=7, dy=10, nx=150, ny=120, log=0x06, fc=rnd.randrange(65536)) + WAIT_CE
    # Block commands, both directions, logical operations with TP, masks.
    ops += cmd(LMMV, dx=13, dy=20, nx=9, ny=4, fc=fc) + WAIT_CE
    ops += cmd(LMMV, dx=40, dy=30, nx=7, ny=3, arg=DIX_ | DIY_, log=0x16, wm=0xF0F3, fc=fc ^ 0x5A5A) + WAIT_CE
    ops += cmd(LMMM, sx=3, sy=1, dx=60, dy=40, nx=11, ny=5) + WAIT_CE
    ops += cmd(LMMM, sx=21, sy=2, dx=90, dy=50, nx=10, ny=4, arg=DIX_, log=0x1A, wm=0x3CFF) + WAIT_CE
    ops += cmd(LMMM, sx=30, sy=3, dx=130, dy=60, nx=6, ny=6, arg=DIY_, log=0x13) + WAIT_CE
    ops += cmd(CMMM, sx=0x12, sy=0x00, dx=5, dy=70, nx=13, ny=5, fc=fc, bc=bc, log=0x1C) + WAIT_CE
    # Transparency (TP): a source with color 0 pixels, copied with TP.
    ops += cmd(LMMV, dx=20, dy=140, nx=30, ny=5, fc=0x0000, log=0x1C) + WAIT_CE
    ops += cmd(LMMV, dx=0, dy=150, nx=16, ny=4, fc=0x0000) + WAIT_CE
    ops += cmd(LMMV, dx=5, dy=150, nx=5, ny=4, fc=fc | 0x0101) + WAIT_CE
    ops += cmd(LMMM, sx=0, sy=150, dx=40, dy=30, nx=16, ny=4, log=0x1C) + WAIT_CE
    ops += cmd(LMMM, sx=0, sy=150, dx=60, dy=31, nx=16, ny=4, log=0x13) + WAIT_CE
    ops += cmd(BMXL, sx=0x40, sy=0x01, dx=7, dy=80, nx=9, ny=3) + WAIT_CE
    ops += cmd(BMLX, sx=2, sy=1, dx=0x20, dy=0x30, nx=9, ny=3) + WAIT_CE
    ops += cmd(BMLL, sx=0x05, sy=0x00, dx=0x77, dy=0x31, nx=37, ny=0, log=0x16, wm=0xFFF0) + WAIT_CE
    # Lines: x major, y major, the four directions, one out of the image.
    for k, (arg, nx, ny) in enumerate(((0, 30, 7), (MAJ_, 25, 9), (DIX_ | DIY_, 20, 5),
                                       (MAJ_ | DIY_, 12, 11), (DIX_, 40, 3))):
        ops += cmd(LINE, dx=100 + 10 * k, dy=100 + 3 * k, nx=nx, ny=ny, arg=arg, fc=fc + k) + WAIT_CE
    # PSET (no move), POINT.
    ops += cmd(PSET, dx=17, dy=90, fc=fc, log=0x0C) + WAIT_CE
    ops += cmd(PSET, dx=18, dy=90, fc=fc, log=0x1E, wm=0x0FF0) + WAIT_CE
    ops += cmd(POINT, sx=17, sy=90) + [("tr_in_p", CMD, STAT, 2 if mode == "b16" else 1)] + WAIT_CE
    ops += cmd(POINT, sx=5, sy=1) + [("tr_in_p", CMD, STAT, 2 if mode == "b16" else 1)] + WAIT_CE
    # CPU transfers: LMMC, CMMC, LMCM.
    data = [rnd.randrange(256) for _ in range(24)]
    n = {"b16": 24, "b8": 12, "b2": 3}.get(mode, 6)
    ops += cmd(LMMC, dx=33, dy=110, nx=4, ny=3, log=0x0C) + [("tr_out_p", CMD, STAT, data[:n])] + WAIT_CE
    ops += cmd(CMMC, dx=50, dy=120, nx=10, ny=2, fc=fc, bc=bc) + [("tr_out_p", CMD, STAT, data[:3])] + WAIT_CE
    if mode != "b16":                       # openMSX: LMCM reads nothing in 16 bpp
        m = {"b8": 8, "b2": 2}.get(mode, 4)
        ops += cmd(LMCM, sx=3, sy=1, nx=4, ny=2) + [("tr_in_p", CMD, STAT, m)] + WAIT_CE
    # Search: found / not found, both directions; border x and status.
    ops += cmd(SRCH, sx=0, sy=20, fc=fc) + WAIT_CE + sel(53) + reads(RDATA, 2) + reads(STAT, 1)
    ops += cmd(SRCH, sx=13, sy=20, fc=fc, arg=NEQ_) + WAIT_CE + sel(53) + reads(RDATA, 2) + reads(STAT, 1)
    ops += cmd(SRCH, sx=200, sy=110, fc=0xFFFF, arg=DIX_) + WAIT_CE + sel(53) + reads(RDATA, 2) + reads(STAT, 1)
    ops += reads(INTF, 1)
    return ops


DIX_, DIY_, NEQ_, MAJ_ = 0x04, 0x08, 0x02, 0x01

SEQUENCES_CMD = {f"cmd_{m}": (lambda m=m: seq_cmd(m, seed=sum(m.encode()))) for m in CMD_MODES}


def seq_cmd_edge(mode, seed=7):
    """Corner cases: transfers in reverse directions with partial bytes,
    LMCM ending inside a byte, NX = 0 (2048), P1 x >= 512 (layer B), a
    line leaving the image."""
    r6, r13 = CMD_MODES[mode]
    rnd = _random.Random(seed)
    ops = set_regs(6, [r6]) + set_regs(13, [r13]) + MODE_DELAY
    ops += _fill(seed, 0, 768)
    for k in range(4):
        ops += cmd(LMMV, dx=0, dy=40 + 10 * k, nx=0, ny=10, fc=rnd.randrange(65536)) + WAIT_CE
    data = [rnd.randrange(256) for _ in range(40)]
    n16 = mode == "b16"
    # Bytes the commands take: pixels / pixels per byte, rounded up (per
    # line for LMMC, which restarts a byte on each line only when it ends).
    ppb = {"b2": 4, "b8": 1, "b16": 0}.get(mode, 2)

    def nbytes(npx):
        return 2 * npx if ppb == 0 else -(-npx // ppb)
    ops += cmd(LMMC, dx=60, dy=60, nx=5, ny=3, arg=DIX_ | DIY_) + [("tr_out_p", CMD, STAT, data[:nbytes(15)])] + WAIT_CE
    ops += cmd(CMMC, dx=90, dy=45, nx=11, ny=2, arg=DIX_, fc=0x1234, bc=0xFEDC) + [("tr_out_p", CMD, STAT, data[:3])] + WAIT_CE
    if not n16:
        ops += cmd(LMCM, sx=9, sy=1, nx=3, ny=1, arg=DIX_) + [("tr_in_p", CMD, STAT, nbytes(3))] + WAIT_CE
    ops += cmd(BMXL, sx=0x10, sy=0x00, dx=120, dy=50, nx=7, ny=2, arg=DIX_ | DIY_) + WAIT_CE
    ops += cmd(BMLX, sx=30, sy=2, dx=0x80, dy=0x20, nx=7, ny=2, arg=DIX_) + WAIT_CE
    ops += cmd(LMMM, sx=200, sy=1, dx=10, dy=70, nx=0, ny=2, log=0x1C) + WAIT_CE
    if mode == "p1":
        ops += cmd(LMMV, dx=600, dy=45, nx=20, ny=4, fc=0x7531) + WAIT_CE
        ops += cmd(LMMM, sx=601, sy=46, dx=20, dy=48, nx=9, ny=2) + WAIT_CE
    ops += cmd(LINE, dx=240, dy=60, nx=40, ny=10, fc=0x2345) + WAIT_CE
    ops += cmd(LINE, dx=5, dy=80, nx=30, ny=6, arg=DIX_ | MAJ_, fc=0x6789) + WAIT_CE
    ops += cmd(SRCH, sx=3, sy=45, fc=0, arg=DIX_) + WAIT_CE + sel(53) + reads(RDATA, 2) + reads(STAT, 1)
    ops += cmd(BMLL, sx=0x00, sy=0x01, dx=0x40, dy=0x22, nx=0x30, ny=0x01) + WAIT_CE
    ops += reads(INTF, 1)
    return ops


SEQUENCES_CMD.update({f"edge_{m}": (lambda m=m: seq_cmd_edge(m, seed=sum(m.encode()) + 1)) for m in ("p1", "p2", "b2", "b8", "b16")})
