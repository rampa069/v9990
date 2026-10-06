"""Reference model of the V9990 command engine (blitter).

A port of openMSX V9990CmdEngine (src/video/v9990, git master) without its
timing: block commands run to the end at once (like openMSX with
"cmdtiming broken"); the commands that move data through P#2 (LMMC, LMCM,
CMMC, POINT) advance with each transfer.  The VRAM is physical (see
v9990_model).  Like openMSX, CMMK and ADVN do nothing and PSET does not
move DX / DY.

Integer types follow openMSX: the coordinates and counters are 16 bits.
"""

TR, BD, CE = 0x80, 0x10, 0x01
DIY, DIX, NEQ, MAJ = 0x08, 0x04, 0x02, 0x01

M16 = 0xFFFF


def u16(v):
    return v & M16


def transform_bx(a):
    return ((a & 1) << 18) | ((a & 0x7FFFE) >> 1)


def transform_p2(a):
    if a < 0x78000:
        return transform_bx(a)
    if a < 0x7C000:
        return a - 0x3C000
    return a


def _bit(op, s, d):
    """openMSX bitLUT: the result bit for source / destination bits."""
    return (op >> (2 * s + d)) & 1


def log_op(op, src, dst, bpp):
    """Logical operation on a byte; op bit 4 (TP): a source pixel of 0
    leaves the destination pixel (per pixel field of bpp bits)."""
    if not op & 0x10 or bpp == 16:
        res = 0
        for b in range(8):
            res |= _bit(op & 15, (src >> b) & 1, (dst >> b) & 1) << b
        return res
    res = 0
    fmask = (1 << bpp) - 1
    for f in range(0, 8, bpp):
        sf = (src >> f) & fmask
        df = (dst >> f) & fmask
        if sf == 0:
            res |= df << f
        else:
            for b in range(bpp):
                res |= _bit(op & 15, (sf >> b) & 1, (df >> b) & 1) << (f + b)
    return res


class Mode:
    """Addressing of one command mode (openMSX V9990P1 ... V9990Bpp16)."""

    def __init__(self, name):
        self.name = name
        self.bpp = {"P1": 4, "P2": 4, "BPP2": 2, "BPP4": 4, "BPP8": 8, "BPP16": 16}[name]
        self.ppb = {2: 4, 4: 2, 8: 1, 16: 0}[self.bpp]

    def pitch(self, width):
        return {"P1": width // 2, "P2": width // 2, "BPP2": width // 4, "BPP4": width // 2,
                "BPP8": width, "BPP16": width}[self.name]

    def address(self, x, y, pitch):
        n = self.name
        if n == "P1":
            a = ((x // 2) & (pitch - 1)) + y * pitch
            return (a & 0x3FFFF) | ((x & 0x200) << 9)
        if n == "P2":
            return transform_p2(((x // 2) & (pitch - 1)) + y * pitch) & 0x7FFFF
        if n == "BPP2":
            return transform_bx(((x // 4) & (pitch - 1)) + y * pitch) & 0x7FFFF
        if n == "BPP4":
            return transform_bx(((x // 2) & (pitch - 1)) + y * pitch) & 0x7FFFF
        if n == "BPP8":
            return transform_bx((x & (pitch - 1)) + y * pitch) & 0x7FFFF
        return ((x & (pitch - 1)) + y * pitch) & 0x3FFFF    # 16 bpp: word

    def shift(self, value, from_x, to_x):
        if self.bpp == 2:
            s = 2 * ((to_x & 3) - (from_x & 3))
        elif self.bpp == 4:
            s = 4 * ((to_x & 1) - (from_x & 1))
        else:
            return value
        return (value >> s) & 0xFF if s > 0 else (value << -s) & 0xFF

    def shift_mask(self, x):
        if self.bpp == 2:
            return 0xC0 >> (2 * (x & 3))
        if self.bpp == 4:
            return 0x0F if x & 1 else 0xF0
        return 0xFF if self.bpp == 8 else 0xFFFF


class CmdEngine:
    def __init__(self, vram, irq=None):
        self.vram = vram                    # physical, 512 KB (shared with the VDP model)
        self.irq = irq                      # called on command end (CE interrupt)
        self.SX = self.SY = self.DX = self.DY = self.NX = self.NY = 0
        self.ARG = self.LOG = self.WM = self.fg = self.bg = 0
        self.CMD = 0
        self.status = 0
        self.border_x = 0
        self.data = self.partial = self.bits_left = 0
        self.end_after_read = False
        self.ASX = self.ADX = self.ANX = self.ANY = 0
        self.src_addr = self.dst_addr = self.nb_bytes = 0
        self.mode = Mode("P1")
        self.width = 256

    # -- VRAM helpers ---------------------------------------------------------

    def rd(self, a):
        return self.vram[a & 0x7FFFF]

    def wr(self, a, v):
        self.vram[a & 0x7FFFF] = v & 0xFF

    def rd_bx(self, a):
        return self.vram[transform_bx(a & 0x7FFFF)]

    def wr_bx(self, a, v):
        self.vram[transform_bx(a & 0x7FFFF)] = v & 0xFF

    def wnx(self):
        return self.NX or 2048

    def wny(self):
        return self.NY or 4096

    def point(self, x, y):
        m = self.mode
        a = m.address(x, y, m.pitch(self.width))
        if m.bpp == 16:
            return self.rd(a) + 256 * self.rd(a + 0x40000)
        return self.rd(a)

    def _pset_byte(self, a, x, src, newsrc_is_color, color=0):
        m = self.mode
        if newsrc_is_color:
            src = (color >> 8) & 0xFF if a & 0x40000 else color & 0xFF
        dst = self.rd(a)
        new = log_op(self.LOG, src, dst, m.bpp)
        mask1 = (self.WM >> 8) & 0xFF if a & 0x40000 else self.WM & 0xFF
        if m.bpp == 2:
            mask2 = mask1 & (0xC0 >> (2 * (x & 3)))
        elif m.bpp == 4:
            mask2 = mask1 & (0x0F if x & 1 else 0xF0)
        else:
            mask2 = mask1
        self.wr(a, (dst & ~mask2) | (new & mask2))

    def _pset16(self, a, src):
        dst = self.rd(a) + 256 * self.rd(a + 0x40000)
        if self.LOG & 0x10 and src == 0:
            new = dst
        else:
            new = log_op(self.LOG & 0x0F, src & 0xFF, dst & 0xFF, 8) | \
                (log_op(self.LOG & 0x0F, src >> 8, dst >> 8, 8) << 8)
        res = (dst & ~self.WM) | (new & self.WM)
        self.wr(a, res & 0xFF)
        self.wr(a + 0x40000, res >> 8)

    def pset(self, x, y, src):
        """Mode::pset: src already shifted to x."""
        m = self.mode
        a = m.address(x, y, m.pitch(self.width))
        if m.bpp == 16:
            self._pset16(a, src)
        else:
            self._pset_byte(a, x, src, False)

    def pset_color(self, x, y, color):
        m = self.mode
        a = m.address(x, y, m.pitch(self.width))
        if m.bpp == 16:
            self._pset16(a, color)
        else:
            self._pset_byte(a, x, 0, True, color)

    def ready(self):
        self.CMD = 0
        self.status &= ~(CE | TR)
        if self.irq:
            self.irq()

    # -- Registers and data ---------------------------------------------------

    def set_reg(self, reg, value, mode_name, width):
        r = reg - 32
        v = value & 0xFF
        if r == 0:
            self.SX = (self.SX & 0x0700) | v
        elif r == 1:
            self.SX = (self.SX & 0x00FF) | ((v & 0x07) << 8)
        elif r == 2:
            self.SY = (self.SY & 0x0F00) | v
        elif r == 3:
            self.SY = (self.SY & 0x00FF) | ((v & 0x0F) << 8)
        elif r == 4:
            self.DX = (self.DX & 0x0700) | v
        elif r == 5:
            self.DX = (self.DX & 0x00FF) | ((v & 0x07) << 8)
        elif r == 6:
            self.DY = (self.DY & 0x0F00) | v
        elif r == 7:
            self.DY = (self.DY & 0x00FF) | ((v & 0x0F) << 8)
        elif r == 8:
            self.NX = (self.NX & 0x0F00) | v
        elif r == 9:
            self.NX = (self.NX & 0x00FF) | ((v & 0x0F) << 8)
        elif r == 10:
            self.NY = (self.NY & 0x0F00) | v
        elif r == 11:
            self.NY = (self.NY & 0x00FF) | ((v & 0x0F) << 8)
        elif r == 12:
            self.ARG = v & 0x0F
        elif r == 13:
            self.LOG = v & 0x1F
        elif r == 14:
            self.WM = (self.WM & 0xFF00) | v
        elif r == 15:
            self.WM = (self.WM & 0x00FF) | (v << 8)
        elif r == 16:
            self.fg = (self.fg & 0xFF00) | v
        elif r == 17:
            self.fg = (self.fg & 0x00FF) | (v << 8)
        elif r == 18:
            self.bg = (self.bg & 0xFF00) | v
        elif r == 19:
            self.bg = (self.bg & 0x00FF) | (v << 8)
        elif r == 20:
            self.CMD = v
            self.status |= CE
            self.mode = Mode(mode_name)
            self.width = width
            self.start()
            self.sync()

    def set_data(self, value):
        self.sync()
        self.data = value & 0xFF
        self.status &= ~TR
        self.sync()

    def get_data(self):
        self.sync()
        value = 0xFF
        if self.status & TR:
            value = self.data
            self.status &= ~TR
            if self.end_after_read:
                self.end_after_read = False
                self.ready()
        self.sync()
        return value

    def get_status(self):
        self.sync()
        return self.status

    # -- Commands -------------------------------------------------------------

    def start(self):
        op = self.CMD >> 4
        m = self.mode
        if op == 0:                                     # STOP
            self.ready()
        elif op in (1, 5):                              # LMMC, CMMC
            self.ANX, self.ANY = self.wnx(), self.wny()
            if op == 1 and m.bpp == 16:
                self.bits_left = 1
            self.status |= TR
        elif op in (2, 4):                              # LMMV, LMMM
            self.ANX, self.ANY = self.wnx(), self.wny()
        elif op == 3:                                   # LMCM
            self.ANX, self.ANY = self.wnx(), self.wny()
            self.status &= ~TR
            self.end_after_read = False
            if m.bpp == 16:
                self.bits_left = 0
        elif op in (6, 15):                             # CMMK, ADVN: not implemented
            self.ready()
        elif op in (7, 8):                              # CMMM, BMXL
            self.src_addr = (self.SX & 0xFF) + ((self.SY & 0x7FF) << 8)
            self.ANX, self.ANY = self.wnx(), self.wny()
            self.bits_left = 0
        elif op == 9:                                   # BMLX
            self.dst_addr = (self.DX & 0xFF) + ((self.DY & 0x7FF) << 8)
            self.ANX, self.ANY = self.wnx(), self.wny()
        elif op == 10:                                  # BMLL
            self.src_addr = (self.SX & 0xFF) + ((self.SY & 0x7FF) << 8)
            self.dst_addr = (self.DX & 0xFF) + ((self.DY & 0x7FF) << 8)
            self.nb_bytes = (self.NX & 0xFF) + ((self.NY & 0x7FF) << 8)
            if self.nb_bytes == 0:
                self.nb_bytes = 0x80000
            if m.bpp == 16:
                self.src_addr >>= 1
                self.dst_addr >>= 1
                self.nb_bytes >>= 1
        elif op == 11:                                  # LINE
            # C++ uint16_t((NX - 1) / 2): int division, -1 / 2 = 0.
            self.ASX = (self.NX - 1) // 2 if self.NX else 0
            self.ADX = self.DX
            self.ANX = 0
        elif op == 12:                                  # SRCH
            self.ASX = self.SX
        elif op == 13:                                  # POINT
            d = self.point(self.SX, self.SY)
            if m.bpp != 16:
                self.data = d & 0xFF
                self.end_after_read = True
            else:
                self.data = d & 0xFF
                self.partial = d >> 8
                self.end_after_read = False
            self.status |= TR
        elif op == 14:                                  # PSET
            self.pset_color(self.DX, self.DY, self.fg)
            self.ready()

    def _step_x(self, attr):
        """Advance DX (attr 'DX') or SX over the block; True at the end."""
        dx = M16 if self.ARG & DIX else 1
        dy = M16 if self.ARG & DIY else 1
        setattr(self, attr, u16(getattr(self, attr) + dx))
        self.ANX = u16(self.ANX - 1)
        if self.ANX == 0:
            setattr(self, attr, u16(getattr(self, attr) - u16(self.NX * dx)))
            ya = "DY" if attr == "DX" else "SY"
            setattr(self, ya, u16(getattr(self, ya) + dy))
            self.ANY = u16(self.ANY - 1)
            if self.ANY == 0:
                return True
            self.ANX = self.wnx()
        return False

    def sync(self):
        """Run the current command as far as it can go."""
        op = self.CMD >> 4
        if op == 0:
            return
        m = self.mode
        dx = M16 if self.ARG & DIX else 1
        dy = M16 if self.ARG & DIY else 1
        if op == 1:                                     # LMMC
            if self.status & TR:
                return
            self.status |= TR
            if m.bpp == 16:
                if self.bits_left:
                    self.bits_left = 0
                    self.partial = self.data
                    return
                self.bits_left = 1
                self.pset(self.DX, self.DY, (self.data << 8) | self.partial)
                if self._step_x("DX"):
                    self.ready()
                return
            for i in range(m.ppb):
                if self.ANY == 0:
                    break
                self.pset(self.DX, self.DY, m.shift(self.data, i, self.DX))
                self.DX = u16(self.DX + dx)
                self.ANX = u16(self.ANX - 1)
                if self.ANX == 0:
                    self.DX = u16(self.DX - u16(self.NX * dx))
                    self.DY = u16(self.DY + dy)
                    self.ANY = u16(self.ANY - 1)
                    if self.ANY == 0:
                        self.ready()
                    else:
                        self.ANX = self.NX           # (openMSX: not wrapped here)
        elif op == 2:                                   # LMMV
            while True:
                self.pset_color(self.DX, self.DY, self.fg)
                if self._step_x("DX"):
                    self.ready()
                    return
        elif op == 3:                                   # LMCM
            if self.status & TR:
                return
            self.status |= TR
            if m.bpp == 16 and self.bits_left:
                self.bits_left = 0
                self.data = self.partial
                return
            d = 0
            # 16 bpp: PIXELS_PER_BYTE is 0 in openMSX, nothing is read (and
            # the command does not end); kept as is.
            for i in range(m.ppb):
                if self.ANY == 0:
                    break
                src = self.point(self.SX, self.SY)
                d |= m.shift(src, self.SX, i) & m.shift_mask(i)
                self.SX = u16(self.SX + dx)
                self.ANX = u16(self.ANX - 1)
                if self.ANX == 0:
                    self.SX = u16(self.SX - u16(self.NX * dx))
                    self.SY = u16(self.SY + dy)
                    self.ANY = u16(self.ANY - 1)
                    if self.ANY == 0:
                        self.end_after_read = True
                    else:
                        self.ANX = self.wnx()
            if m.bpp == 16:
                self.data = d & 0xFF
                self.partial = d >> 8
                self.bits_left = 1
            else:
                self.data = d & 0xFF
        elif op == 4:                                   # LMMM
            while True:
                src = m.shift(self.point(self.SX, self.SY), self.SX, self.DX)
                self.pset(self.DX, self.DY, src)
                self.DX = u16(self.DX + dx)
                self.SX = u16(self.SX + dx)
                self.ANX = u16(self.ANX - 1)
                if self.ANX == 0:
                    self.DX = u16(self.DX - u16(self.NX * dx))
                    self.SX = u16(self.SX - u16(self.NX * dx))
                    self.DY = u16(self.DY + dy)
                    self.SY = u16(self.SY + dy)
                    self.ANY = u16(self.ANY - 1)
                    if self.ANY == 0:
                        self.ready()
                        return
                    self.ANX = self.wnx()
        elif op == 5:                                   # CMMC
            if self.status & TR:
                return
            self.status |= TR
            for _ in range(8):
                bit = self.data & 0x80
                self.data = (self.data << 1) & 0xFF
                self.pset_color(self.DX, self.DY, self.fg if bit else self.bg)
                if self._step_x("DX"):
                    self.ready()
                    return
        elif op == 7:                                   # CMMM
            while True:
                if not self.bits_left:
                    self.data = self.rd_bx(self.src_addr)
                    self.src_addr += 1
                    self.bits_left = 8
                self.bits_left -= 1
                bit = self.data & 0x80
                self.data = (self.data << 1) & 0xFF
                self.pset_color(self.DX, self.DY, self.fg if bit else self.bg)
                if self._step_x("DX"):
                    self.ready()
                    return
        elif op == 8:                                   # BMXL
            if m.bpp == 16:
                while True:
                    src = self.rd_bx(self.src_addr) + 256 * self.rd_bx(self.src_addr + 1)
                    self.src_addr += 2
                    self.pset(self.DX, self.DY, src)
                    if self._step_x("DX"):
                        self.ready()
                        return
            while True:
                d = self.rd_bx(self.src_addr)
                self.src_addr += 1
                for i in range(m.ppb):
                    if self.ANY == 0:
                        break
                    self.pset(self.DX, self.DY, m.shift(d, i, self.DX))
                    if self._step_x("DX"):
                        self.ready()
                        return
        elif op == 9:                                   # BMLX
            if m.bpp == 16:
                while True:
                    src = self.point(self.SX, self.SY)
                    self.wr_bx(self.dst_addr, src & 0xFF)
                    self.wr_bx(self.dst_addr + 1, src >> 8)
                    self.dst_addr += 2
                    if self._step_x("SX"):
                        self.ready()
                        return
            while True:
                d = 0
                for i in range(m.ppb):
                    src = self.point(self.SX, self.SY)
                    d |= m.shift(src, self.SX, i) & m.shift_mask(i)
                    if self._step_x("SX"):
                        self.wr_bx(self.dst_addr, d)
                        self.dst_addr += 1
                        self.ready()
                        return
                self.wr_bx(self.dst_addr, d)
                self.dst_addr += 1
        elif op == 10:                                  # BMLL
            while True:
                if m.bpp == 16:
                    s = self.src_addr
                    d = self.dst_addr
                    src = self.rd(s) + 256 * self.rd(s + 0x40000)
                    self._pset16(d, src)
                    self.src_addr = (self.src_addr + 1) & 0x3FFFF
                    self.dst_addr = (self.dst_addr + 1) & 0x3FFFF
                else:
                    src = self.rd_bx(self.src_addr)
                    a = transform_bx(self.dst_addr)
                    dst = self.rd(a)
                    new = log_op(self.LOG, src, dst, m.bpp)
                    mask = (self.WM >> 8) & 0xFF if a & 0x40000 else self.WM & 0xFF
                    self.wr(a, (dst & ~mask) | (new & mask))
                    self.src_addr = (self.src_addr + 1) & 0x7FFFF
                    self.dst_addr = (self.dst_addr + 1) & 0x7FFFF
                self.nb_bytes -= 1
                if self.nb_bytes == 0:
                    self.ready()
                    return
        elif op == 11:                                  # LINE
            tx, ty = dx, dy
            while True:
                self.pset_color(self.ADX, self.DY, self.fg)
                if not self.ARG & MAJ:
                    self.ADX = u16(self.ADX + tx)
                    if self.ASX < self.NY:
                        self.ASX = u16(self.ASX + self.NX)
                        self.DY = u16(self.DY + ty)
                else:
                    self.DY = u16(self.DY + ty)
                    if self.ASX < self.NY:
                        self.ASX = u16(self.ASX + self.NX)
                        self.ADX = u16(self.ADX + tx)
                self.ASX = u16(self.ASX - self.NY)
                end = self.ANX == self.NX or (self.ADX & self.width)
                self.ANX = u16(self.ANX + 1)
                if end:
                    self.ready()
                    return
        elif op == 12:                                  # SRCH
            pitch = m.pitch(self.width)
            while True:
                if m.bpp == 16:
                    value, col, mask2 = self.point(self.ASX, self.SY), self.fg, M16
                else:
                    a = m.address(self.ASX, self.SY, pitch)
                    value = self.rd(a)
                    col = (self.fg >> 8) & 0xFF if a & 0x40000 else self.fg & 0xFF
                    mask2 = m.shift((1 << m.bpp) - 1, 3, self.ASX)
                if ((value & mask2) == (col & mask2)) != bool(self.ARG & NEQ):
                    self.status |= BD
                    self.ready()
                    self.border_x = self.ASX
                    return
                self.ASX = u16(self.ASX + dx)
                if self.ASX & self.width:
                    self.status &= ~BD
                    self.ready()
                    self.border_x = self.ASX
                    return
        elif op == 13:                                  # POINT (16 bpp: 2nd byte)
            if self.status & TR:
                return
            self.status |= TR
            self.data = self.partial
            self.end_after_read = True
