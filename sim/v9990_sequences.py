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
