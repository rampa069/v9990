"""V9990 display scenes: physical VRAM, registers R#0-R#28, palette, MCS.
Shown by openMSX (test_v9990_model_openmsx.py) and by the RTL
(tests/test_v9990_display.py), both compared with v9990_model."""

import random

import v9990_model as vm


def _palette(seed):
    rnd = random.Random(seed)
    pal = bytearray()
    for _ in range(64):
        pal += bytes([rnd.randrange(32), rnd.randrange(32), rnd.randrange(32), 0])
    return pal


def _fill(vram, start, n, seed):
    """Pseudo-random logical bytes (bitmap layout) from start."""
    rnd = random.Random(seed)
    for a in range(start, start + n):
        vram[vm.vram_phys(a & 0x7FFFF, 0x80)] = rnd.randrange(256)


def _regs(r6, r13=0, **kw):
    regs = [0] * 29
    regs[6], regs[8], regs[13], regs[15] = r6, 0x80 | 0x40, r13, 3   # display on, cursors off
    for k, v in kw.items():
        regs[int(k[1:])] = v
    return regs


def bitmap(name, r6, r13=0, seed=1, **kw):
    vram = vm.power_on_vram()
    _fill(vram, 0, 0x80000, seed)
    return vram, _regs(r6, r13, **kw), _palette(seed + 100), False


def cursors():
    vram, regs, pal, mcs = bitmap("cursors", 0x81, 0x00, seed=7)
    regs[8] = 0x80                                      # cursors on
    regs[28] = 0x05                                     # sprite palette offset 20
    rd = bytearray(16)
    # Cursor 0: line 40, x 30, color 2; cursor 1: line 50, x 200 + 256, EOR.
    attrs = [(40, 0, 30, 0x80), (50, 0, 200, 0x21)]
    for k, (y, yh, x, attr) in enumerate(attrs):
        base = 0x7FE00 + 8 * k
        for off, v in ((0, y), (2, yh), (4, x), (6, attr)):
            vram[vm.vram_phys(base + off, 0x80)] = v
    for k, pat in enumerate((0x7FF00, 0x7FF80)):
        for line in range(32):
            for b in range(4):
                vram[vm.vram_phys(pat + 4 * line + b, 0x80)] = (0xF0 >> (line & 3)) ^ (0x55 * b) & 0xFF
    return vram, regs, pal, mcs


SCENES = {
    "b1_bp4": lambda: bitmap("b1_bp4", 0x81, 0x04, seed=1),
    "b1_bp2": lambda: bitmap("b1_bp2", 0x80, 0x05, seed=2),
    "b3_bp6": lambda: bitmap("b3_bp6", 0x96, 0x00, seed=3),
    "b1_bd8": lambda: bitmap("b1_bd8", 0x82, 0x40, seed=4),
    "b1_bd16": lambda: bitmap("b1_bd16", 0x83, 0x00, seed=5),
    "b1_yjk": lambda: bitmap("b1_yjk", 0x82, 0x80, seed=6),
    "b1_yuv": lambda: bitmap("b1_yuv", 0x82, 0xC0, seed=8),
    "b3_scroll": lambda: bitmap("b3_scroll", 0x99, 0x08, seed=9, r17=0x2C, r18=0x81, r19=5, r20=0x47),
    "b1_roll": lambda: bitmap("b1_roll", 0x81, 0x00, seed=10, r17=0xF0, r18=0x40, r19=3, r20=0x02),
    "b7_bp4": lambda: bitmap("b7_bp4", 0xA5, 0x04, seed=11),
    "b7_bp2": lambda: bitmap("b7_bp2", 0xA4, 0x06, seed=12),
    "cursors": cursors,
}


def pattern(name, r6, r13=0, seed=30, **kw):
    """P1 / P2: random name tables and patterns, sprites off."""
    vram = vm.power_on_vram()
    rnd = random.Random(seed)
    for a in range(0x80000):
        vram[a] = rnd.randrange(256)
    regs = _regs(r6, r13, **kw)
    return vram, regs, _palette(seed + 100), False


SCENES.update({
    "p1": lambda: pattern("p1", 0x00, 0x09, seed=30),
    "p1_scroll": lambda: pattern("p1_scroll", 0x00, 0x06, seed=31, r17=0x35, r18=0x01, r19=5, r20=0x13,
                                 r21=0x77, r22=0x00, r23=3, r24=0x21),
    "p1_prio": lambda: pattern("p1_prio", 0x00, 0x0C, seed=32, r27=0x0A),
    "p1_roll": lambda: pattern("p1_roll", 0x00, 0x00, seed=33, r17=0xC0, r18=0x40),
    "p2": lambda: pattern("p2", 0x40, 0x0D, seed=34),
    "p2_scroll": lambda: pattern("p2_scroll", 0x40, 0x03, seed=35, r17=0x91, r18=0x81, r19=6, r20=0x55),
})


def sprites(name, r6, seed, r25, sprite_list, **kw):
    """P1 / P2 layers with sprites: sprite_list of (number, y, x, pattern,
    attr bits 7-4) for the first sprites, the rest moved off the lines."""
    vram, regs, pal, mcs = pattern(name, r6, 0x06, seed=seed, **kw)
    regs[8] = 0x80                                  # sprites on
    regs[25] = r25
    for sp in range(125):
        a = 0x3FE00 + 4 * sp
        vram[a] = 0xF0                              # line 0xF1: below the picture
        vram[a + 3] = 0x00
    for sp, y, x, no, attr in sprite_list:
        a = 0x3FE00 + 4 * sp
        vram[a], vram[a + 1], vram[a + 2] = y & 0xFF, no, x & 0xFF
        vram[a + 3] = (attr & 0xF0) | ((x >> 8) & 3)
    return vram, regs, pal, mcs


def _sprite_list(seed, n, xmax):
    rnd = random.Random(seed)
    out = []
    for k in range(n):
        attr = rnd.choice((0x00, 0x40, 0x80, 0xC0, 0x20, 0x60))   # palettes, back (20h)
        out.append((k, rnd.randrange(-8, 200), rnd.randrange(-16, xmax), rnd.randrange(256), attr))
    return out


SCENES.update({
    "p1_sprites": lambda: sprites("p1_sprites", 0x00, 40, 0x02, _sprite_list(41, 40, 256)),
    # 20 sprites on the same lines (16 per line), two disabled ones (10h)
    # lowering the limit, negative x.
    "p1_sprite_limit": lambda: sprites("p1_sprite_limit", 0x00, 42, 0x04,
        [(k, 60 + (k % 3), 12 * k - 8, k, 0x40 if k % 2 else 0x00) for k in range(20)]
        + [(30, 100, 50, 7, 0x10), (31, 101, 60, 8, 0x10)]
        + [(32 + k, 100, 14 * k - 16, 9 + k, 0x80) for k in range(16)]),
    "p2_sprites": lambda: sprites("p2_sprites", 0x40, 43, 0x05, _sprite_list(44, 40, 512)),
})
