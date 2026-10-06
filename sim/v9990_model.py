"""Reference model of the V9990 CPU interface (ports 60h-6Fh).

Follows openMSX V9990::readIO / writeIO / writeRegister (src/video/v9990,
git master), checked against openMSX itself in test_v9990_model_openmsx.py.
The VRAM is physical (two banks, see v9990/v9990_pkg.vhd); the CPU uses
logical addresses mapped per display mode.
"""

VRAM_SIZE = 512 * 1024

# Register access (openMSX regAccess) and write masks (regWriteMask).
RD, WR = 1, 2
ACCESS = ([WR] * 6 + [RD | WR] * 7 + [WR, WR] + [RD | WR] * 13 + [WR] + [0] * 3
          + [WR] * 21 + [RD, RD] + [0] * 9)
assert len(ACCESS) == 64
MASK = [0xFF] * 64
MASK[9], MASK[11], MASK[12] = 0x87, 0x83, 0x0F
MASK[18], MASK[19], MASK[22], MASK[23], MASK[24], MASK[25] = 0xDF, 0x07, 0xC1, 0x07, 0x3F, 0xCF

PAL_MASK = (0x9F, 0x1F, 0x1F, 0x00)

# Ports.
P_VRAM, P_PALETTE, P_CMDDATA, P_REGDATA, P_REGSEL, P_STATUS, P_INTFLAG, P_SYSCTRL = range(8)

# Status bits that depend on the time of the read (VR, HR, EO).
STATUS_TIMING = 0x62


def power_on_vram():
    """openMSX V9990VRAM::clear: 00h / FFh alternating every 512 bytes."""
    block = bytes(512) + b"\xff" * 512
    return bytearray(block * (VRAM_SIZE // 1024))


def vram_phys(addr, scrmode0):
    """Logical to physical VRAM address (openMSX V9990VRAM::mapAddress)."""
    addr &= 0x7FFFF
    bx = ((addr & 1) << 18) | ((addr & 0x7FFFE) >> 1)
    mode = scrmode0 & 0xC0
    if mode == 0x80:                    # bitmap
        return bx
    if mode == 0x40:                    # P2
        if addr < 0x78000:
            return bx
        if addr < 0x7C000:
            return addr - 0x3C000
        return addr
    return addr                         # P1 (and the invalid mode 11)


def cmd_mode(regs):
    """Command engine mode (openMSX V9990CmdEngine::setCommandMode) and the
    image width."""
    m = regs[6] & 0xC0
    if m == 0x40:
        name = "P2"
    elif m == 0x80:
        name = {"BP2": "BPP2", "BP4": "BPP4", "BD16": "BPP16"}.get(color_mode(regs), "BPP8")
    else:
        name = "P1"
    return name, image_width(regs)


class V9990:
    def __init__(self):
        self.vram = power_on_vram()
        self.palette = bytearray([0x9F, 0x1F, 0x1F, 0x00] * 64)
        self.regs = [0] * 64
        self.regsel = 0xFF
        self.read_buffer = 0
        self.pending = 0
        self.status = 0                 # bit 2 MCS, bit 1 EO
        self.system_reset = False
        import v9990_cmd
        self.cmd = v9990_cmd.CmdEngine(self.vram, irq=self._cmd_irq)

    def _cmd_irq(self):
        self.pending |= 4

    @property
    def border_x(self):
        self.cmd.sync()
        return self.cmd.border_x

    # -- helpers ------------------------------------------------------------

    def _addr(self, base):
        return self.regs[base] | (self.regs[base + 1] << 8) | ((self.regs[base + 2] & 7) << 16)

    def _set_addr(self, base, addr):
        self.regs[base] = addr & 0xFF
        self.regs[base + 1] = (addr >> 8) & 0xFF
        self.regs[base + 2] = ((addr >> 16) & 7) | (self.regs[base + 2] & 0x80)

    def _vram_read(self, addr):
        return self.vram[vram_phys(addr, self.regs[6])]

    def write_register(self, reg, val):
        if not ACCESS[reg] & WR:
            return
        if reg >= 32:
            self.regs[reg] = val        # command engine parameters
            name, width = cmd_mode(self.regs)
            self.cmd.set_reg(reg, val, name, width)
            return
        self.regs[reg] = val & MASK[reg]
        if reg == 5:
            self.read_buffer = self._vram_read(self._addr(3))

    def read_register(self, reg):
        if self.system_reset:
            return 0xFF
        if not ACCESS[reg] & RD:
            return 0xFF
        if reg == 53:
            return self.border_x & 0xFF
        if reg == 54:
            return self.border_x >> 8
        return self.regs[reg]

    def write_palette(self, idx, val):
        self.palette[idx] = val & PAL_MASK[idx & 3]

    @staticmethod
    def _pal_step(ptr):
        return (ptr + (1, 1, 2, -3)[ptr & 3]) & 0xFF

    # -- ports ----------------------------------------------------------------

    def read(self, port):
        port &= 0x0F
        if port == P_VRAM:
            result = self.read_buffer
        elif port == P_PALETTE:
            result = self.palette[self.regs[14]]
        elif port == P_CMDDATA:
            result = None               # below: it has side effects in any case
        elif port == P_REGDATA:
            result = self.read_register(self.regsel & 0x3F)
        elif port == P_INTFLAG:
            result = self.pending
        elif port == P_STATUS:
            result = self.cmd.get_status() | (self.status & 0x06)
        else:
            result = 0xFF
        if port == P_CMDDATA:
            return self.cmd.get_data()
        if self.system_reset:
            return result
        if port == P_VRAM:
            if not self.regs[5] & 0x80:
                addr = (self._addr(3) + 1) & 0x7FFFF
                self._set_addr(3, addr)
                self.read_buffer = self._vram_read(addr)
        elif port == P_PALETTE:
            if not self.regs[13] & 0x10:
                self.regs[14] = self._pal_step(self.regs[14])
        elif port == P_REGDATA:
            if not self.regsel & 0x40:
                self.regsel = ((self.regsel + 1) & ~0x40) & 0xFF
        return result

    def write(self, port, val):
        port &= 0x0F
        val &= 0xFF
        if port == P_VRAM:
            if self.system_reset:
                return
            addr = self._addr(0)
            self.vram[vram_phys(addr, self.regs[6])] = val
            if not self.regs[2] & 0x80:
                self._set_addr(0, (addr + 1) & 0x7FFFF)
        elif port == P_CMDDATA:
            self.cmd.set_data(val)
        elif port == P_PALETTE:
            if self.system_reset:
                self.write_palette(0, 0)
                return
            self.write_palette(self.regs[14], val)
            self.regs[14] = self._pal_step(self.regs[14])
        elif port == P_REGDATA:
            if self.system_reset:
                val = 0
            self.write_register(self.regsel & 0x3F, val)
            if not self.regsel & 0x80:
                self.regsel = (self.regsel & 0xC0) | ((self.regsel + 1) & 0x3F)
        elif port == P_REGSEL:
            self.regsel = 0 if self.system_reset else val
        elif port == P_INTFLAG:
            self.pending &= ~val
        elif port == P_SYSCTRL:
            self.status = (self.status & 0xFB) | ((val & 1) << 2)
            srs = bool(val & 2)
            if srs != self.system_reset:
                self.system_reset = srs
                if srs:
                    for r in range(64):
                        self.write_register(r, 0)
                    self.pending = 0


# -- Display timing (openMSX V9990DisplayTiming, V9990::getLeftBorder etc.) --

H_TOTAL = 2736


def is_overscan(regs, mcs):
    """B0 / B2 / B4: bitmap mode with MCS (14 MHz master clock)."""
    return (regs[6] & 0xC0) == 0x80 and mcs and (regs[6] & 0x30) != 0x30


def geometry(regs, mcs=False, pal=False):
    """(left, right, top, bottom, lines): the display area in clocks of the
    line and lines of the frame, and the lines per frame."""
    os_ = is_overscan(regs, mcs)
    adjx = ((regs[16] & 0x0F) ^ 7) - 8
    adjy = ((regs[16] >> 4) ^ 7) - 8
    if os_:
        left = 372 + adjx * 8
        right = left + 2304
        top = 15 + adjy
        bottom = top + (290 if pal else 240)
    else:
        left = 400 + 112 + adjx * 8
        right = left + 2048
        top = 15 + (41 if pal else 14) + adjy
        bottom = top + 212
    return left, right, top, bottom, 313 if pal else 262


def hint_position(regs, mcs=False, pal=False):
    """Line interrupt: (line, clock) of the first one in the frame."""
    top = geometry(regs, mcs, pal)[2]
    line = regs[10] + 256 * (regs[11] & 3) + top
    off = (regs[12] & 0x0F) * 64 * (3 if mcs else 2)
    return line + off // H_TOTAL, off % H_TOTAL


# -- Bitmap modes (openMSX V9990BitmapConverter, V9990SDLRasterizer) --------

# Clocks per pixel and pixels per line, per display mode.
PIXEL_CLOCKS = {"B0": 12, "B1": 8, "B2": 6, "B3": 4, "B4": 3, "B7": 2, "P1": 8, "P2": 4}
MAP_RG = (0, 4, 9, 13, 18, 22, 27, 31)
MAP_B = (0, 11, 21, 31)


def display_mode(regs, mcs=False):
    m = regs[6] & 0xC0
    if m == 0x40:
        return "P2"
    if m == 0x80:
        n = (regs[6] >> 4) & 3
        if n == 3:
            return "P1"
        return ("B0", "B2", "B4")[n] if mcs else ("B1", "B3", "B7")[n]
    return "P1"


def color_mode(regs):
    if not regs[6] & 0x80:
        return "BP4"
    depth = regs[6] & 3
    if depth == 2:
        return ("BP6", "BD8", "BYJK", "BYUV")[regs[13] >> 6]
    return ("BP2", "BP4", None, "BD16")[depth]


def image_width(regs):
    m = regs[6] & 0xC0
    if m == 0x00:
        return 256
    if m == 0x40:
        return 512
    return 256 << ((regs[6] & 0x0C) >> 2)


def pal_rgb(palette, idx):
    """Palette entry idx (0-63) as (r, g, b), 5 bits each."""
    return (palette[4 * idx] & 0x1F, palette[4 * idx + 1] & 0x1F, palette[4 * idx + 2] & 0x1F)


def grb15(c):
    """15-bit G R B (openMSX palette32768 index) to (r, g, b)."""
    return ((c >> 5) & 31, (c >> 10) & 31, c & 31)


def rgb15(rgb):
    r, g, b = rgb
    return (g << 10) | (r << 5) | b


def _clamp(v):
    return max(0, min(31, v))


class Bitmap:
    """Renders the display area of the bitmap modes: line(display_y) gives
    the (r, g, b) of each pixel of a display line."""

    def __init__(self, vram, regs, palette, mcs=False, eo=0, interlace=None):
        self.vram, self.regs, self.palette = vram, regs, palette
        self.mode = display_mode(regs, mcs)
        self.cmode = color_mode(regs)
        self.width = image_width(regs)
        self.high_res = self.mode in ("B4", "B7")
        self.pixels = (2304 if is_overscan(regs, mcs) else 2048) // PIXEL_CLOCKS[self.mode]
        self.eo = eo
        self.interlace = bool(regs[7] & 0x02) if interlace is None else interlace
        self.cursor_y_offset = 14 if is_overscan(regs, mcs) else 0   # NTSC

    def rd(self, addr):
        return self.vram[vram_phys(addr & 0x7FFFF, 0x80)]

    def _pixels(self, x, y):
        """Pixels from image x, line y (openMSX raster*): list of colors as
        ("p", palette index) or ("d", 15-bit GRB)."""
        n, w, rd, cm = self.pixels, self.width, self.rd, self.cmode
        out = []
        off = self.regs[13] & 0x0F
        if cm in ("BYJK", "BYUV"):
            a = (x & ~3) + y * w
            first = x & 3
            while len(out) < n:
                d = [rd(a + k) for k in range(4)]
                a += 4
                u = (d[2] & 7) + ((d[3] & 3) << 3) - ((d[3] & 4) << 3)
                v = (d[0] & 7) + ((d[1] & 3) << 3) - ((d[1] & 4) << 3)
                for i in range(first, 4):
                    yy = (d[i] & 0xF8) >> 3
                    r, g, b = _clamp(yy + u), _clamp((5 * yy - 2 * u - v) // 4), _clamp(yy + v)
                    if cm == "BYJK":
                        g, b = b, g
                    out.append(("d", (g << 10) | (r << 5) | b))
                first = 0
        elif cm == "BD16":
            a = 2 * (x + y * w)
            for _ in range(n):
                out.append(("d", (rd(a) + 256 * rd(a + 1)) & 0x7FFF))
                a += 2
        elif cm == "BD8":
            a = x + y * w
            for _ in range(n):
                c = rd(a)
                a += 1
                g, r, b = c >> 5, (c >> 2) & 7, c & 3
                out.append(("d", (MAP_RG[g] << 10) | (MAP_RG[r] << 5) | MAP_B[b]))
        elif cm == "BP6":
            a = x + y * w
            for _ in range(n):
                out.append(("p", rd(a) & 0x3F))
                a += 1
        elif cm == "BP4":
            base = ((off & 0x4) << 2) if self.high_res else ((off & 0xC) << 2)
            for k in range(n):
                xx = x + k
                d = rd((xx + y * w) // 2)
                nib = d & 0x0F if xx & 1 else d >> 4
                out.append(("p", base + nib + (32 if self.high_res and xx & 1 else 0)))
        else:   # BP2
            base = ((off & 0x7) << 2) if self.high_res else (off << 2)
            for k in range(n):
                xx = x + k
                d = rd((xx + y * w) // 4)
                c = (d >> (6 - 2 * (xx & 3))) & 3
                out.append(("p", base + c + (32 if self.high_res and xx & 1 else 0)))
        return out[:n]

    def _cursor(self, attr_addr, pat_addr, cursor_y):
        rd = self.rd
        ay = rd(attr_addr) + (rd(attr_addr + 2) & 1) * 256
        ay += 2 if self.interlace else 1
        line = (cursor_y - ay) & 511
        if line >= 32:
            return None
        attr = rd(attr_addr + 6)
        if attr & 0x10 or (attr & 0xE0) == 0:
            return None
        pattern = 0
        for k in range(4):
            pattern = (pattern << 8) | rd(pat_addr + 4 * line + k)
        if pattern == 0:
            return None
        x = rd(attr_addr + 4) + (attr & 3) * 256
        xor = (attr & 0xE0) == 0x20
        color = rgb15(pal_rgb(self.palette, ((self.regs[28] << 2) + (attr >> 6)) & 0x3F))
        if attr & 0x20:
            color ^= 0x7FFF
        return x, pattern, xor, color

    def line(self, display_y):
        """(r, g, b) of each pixel of display line display_y."""
        regs = self.regs
        scroll_x = regs[19] + 8 * regs[20]
        scroll_y = regs[17] + 256 * regs[18]
        roll = {0: 0x1FFF, 1: 0xFF, 2: 0x1FF, 3: 0xFF}[regs[18] >> 6]
        ya = display_y
        dy = display_y
        if regs[7] & 0x04:                     # even / odd pages
            ya = 2 * ya + self.eo
            dy += self.eo
        y = (scroll_y & ~roll & 0x1FFF) + ((ya + scroll_y) & roll)
        px = self._pixels(scroll_x, y)
        colors = [rgb15(pal_rgb(self.palette, v)) if k == "p" else v for k, v in px]
        if not regs[8] & 0x40:                 # cursors enabled
            cy = dy - self.cursor_y_offset
            cursors = [c for c in (self._cursor(0x7FE00, 0x7FF00, cy),
                                   self._cursor(0x7FE08, 0x7FF80, cy)) if c]
            for i in range(len(colors)):
                for cx, pat, xor, col in cursors:
                    k = i - cx
                    if 0 <= k < 32 and pat & (0x80000000 >> k):
                        colors[i] = colors[i] ^ 0x7FFF if xor else col
                        break
        return [grb15(c) for c in colors]


# -- Pattern modes P1 / P2 (openMSX V9990P1Converter / V9990P2Converter) -----

class Pattern:
    """Renders the display area of P1 (two 256 pixel layers) and P2 (one 512
    pixel layer), without the sprites: line(display_y) gives the (r, g, b)
    of each pixel.  ya / yb: the layer lines (display_y unless R#17 / R#21
    were written during the frame)."""

    def __init__(self, vram, regs, palette):
        self.vram, self.regs, self.palette = vram, regs, palette
        self.p2 = (regs[6] & 0xC0) == 0x40
        self.pixels = 512 if self.p2 else 256

    def _layer(self, name_tab, pat_base, x, y, n, p2):
        """n pixels of a layer from image x, line y: (nibble, odd byte)."""
        v = self.vram
        name_chars = 128 if p2 else 64
        pat_chars = 64 if p2 else 32
        pitch = pat_chars * 32
        out = []
        while len(out) < n:
            name = name_tab + ((y // 8) * name_chars + (x // 8)) * 2
            pn = (v[name] + 256 * v[name + 1]) & 0x1FFF
            base = pat_base + (pn // pat_chars) * pitch + (y & 7) * name_chars * 2 + (pn % pat_chars) * 4
            for k in range(x & 7, 8):
                a = base + k // 2
                d = v[vram_phys(a, 0x80)] if p2 else v[a]
                out.append(((d >> 4) if k % 2 == 0 else (d & 0x0F), a & 1))
            x = (x & ~7) + 8
            x &= (1023 if p2 else 511)
        return out[:n]

    def line(self, display_y, ya=None, yb=None):
        regs, pal = self.regs, self.palette
        ya = display_y if ya is None else ya
        yb = display_y if yb is None else yb
        backdrop = regs[15] & 63
        off = regs[13] & 0x0F
        pal_a, pal_b = (off & 0x03) << 4, (off & 0x0C) << 2
        roll = {0: 0x1FF, 1: 0xFF, 2: 0x1FF, 3: 0xFF}[regs[18] >> 6]
        say = regs[17] + 256 * regs[18]
        ay = (say & ~roll & 0x1FF) + ((ya + say) & roll)
        if self.p2:
            ax = (regs[19] + 8 * regs[20]) & 1023
            px = self._layer(0x7C000, 0, ax, ay, 512, True)
            idx = [backdrop if c == 0 else (pal_b if odd else pal_a) + c for c, odd in px]
            info = [1 if c else 0 for c, _ in px]
        else:
            ax = (regs[19] + 8 * regs[20]) & 511
            bx = (regs[23] + 8 * regs[24]) & 511
            by = (yb + regs[21] + 256 * regs[22]) & 0x1FF
            a = self._layer(0x7C000, 0x00000, ax, ay, 256, False)
            b = self._layer(0x7E000, 0x40000, bx, by, 256, False)
            prio_x = 256 if regs[27] & 3 == 0 else (regs[27] & 3) << 6
            prio_y = 256 if regs[27] & 0x0C == 0 else (regs[27] & 0x0C) << 4
            if display_y >= prio_y:
                prio_x = 0
            idx = []
            info = []
            for i in range(256):
                (ca, _), (cb, _) = a[i], b[i]
                if i < prio_x:      # B behind A
                    back, front = (cb, pal_b), (ca, pal_a)
                else:               # A behind B
                    back, front = (ca, pal_a), (cb, pal_b)
                c = backdrop if back[0] == 0 else back[1] + back[0]
                if front[0]:
                    c = front[1] + front[0]
                idx.append(c)
                info.append(1 if front[0] else 0)
        if not regs[8] & 0x40:
            self._sprites(idx, info, display_y)
        return [pal_rgb(pal, i & 63) for i in idx]

    def _sprites(self, idx, info, display_y):
        """openMSX renderSprites: info 0 background, 1 front layer, 2 sprite."""
        v, regs = self.vram, self.regs
        width = len(idx)
        table = 0x3FE00
        visible = []
        index_max = 16
        for sp in range(125):
            a = table + 4 * sp
            if ((display_y - (v[a] + 1)) & 0xFF) < 16:
                if v[a + 3] & 0x10:
                    index_max -= 1
                else:
                    visible.append(sp)
                if len(visible) == index_max:
                    break
        if self.p2:
            pat_table = (regs[25] & 0x0F) << 15
        else:
            pat_table = (regs[25] & 0x0E) << 14
        for sp in visible:
            a = table + 4 * sp
            attr = v[a + 3]
            level = 2 if not attr & 0x20 else 1
            sx = v[a + 2] + 256 * (attr & 3)
            if sx > 1008:
                sx -= 1024
            no = v[a + 1]
            line = (display_y - (v[a] + 1)) & 0xFF
            if self.p2:
                pa = pat_table + 256 * (((no & 0xE0) >> 1) + line) + 8 * (no & 0x1F)
            else:
                pa = pat_table + 128 * ((no & 0xF0) + line) + 8 * (no & 0x0F)
            pal16 = (attr >> 2) & 0x30
            for k in range(8):
                d = v[vram_phys(pa + k, 0x80)] if self.p2 else v[pa + k]
                for xx, c in ((sx + 2 * k, d >> 4), (sx + 2 * k + 1, d & 0x0F)):
                    if 0 <= xx < width and c:
                        if info[xx] < level:
                            idx[xx] = pal16 + c
                        info[xx] = 2
