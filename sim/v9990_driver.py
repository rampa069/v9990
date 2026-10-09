"""cocotb helpers to drive the V9990 testbench (tb/v9990_tb.vhd).

The host bus is synchronous to the 42.95 MHz core clock: req held with
wrt / adr / dbo until ack, dbi read with ack.
"""

from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

# Clocks between two accesses: like the openMSX oracle program (LD A,n;
# OUT (n),A; 8 NOPs = 50 T-states of 12 clocks), so register changes that
# take effect at the next line (R#6) line up with openMSX.
GAP = 50 * 12
CLK_PS = 23280                                  # 42.95 MHz


class V9990:
    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.clk_o

    async def reset(self):
        dut = self.dut
        dut.reset_n_i.value = 0
        dut.req_i.value = 0
        dut.wrt_i.value = 0
        dut.adr_i.value = 0
        dut.dbo_i.value = 0
        dut.capture_en_i.value = 0
        dut.cap_step_i.value = 1
        dut.load_i.value = 0
        await Timer(200, "ns")
        await RisingEdge(self.clk)
        dut.reset_n_i.value = 1
        await ClockCycles(self.clk, 4)

    async def _access(self, port, wrt, value=0):
        dut = self.dut
        await FallingEdge(self.clk)           # out of a ReadOnly phase of the caller
        dut.req_i.value = 1
        dut.wrt_i.value = 1 if wrt else 0
        dut.adr_i.value = port & 0x0F
        dut.dbo_i.value = value & 0xFF
        for _ in range(1000):
            await RisingEdge(self.clk)
            await ReadOnly()
            if dut.ack_o.value == 1:
                data = dut.dbi_o.value
                break
        else:
            raise AssertionError(f"no ack for {'write' if wrt else 'read'} of port {port:02x}")
        await RisingEdge(self.clk)
        dut.req_i.value = 0
        # One timer, not GAP clock edge callbacks (they pile up in NVC).
        await Timer(GAP * CLK_PS, "ps")
        if not wrt:
            if not data.is_resolvable:
                raise AssertionError(f"dbi has unresolved value {data}")
            return int(data)

    async def write_port(self, port, value):
        await self._access(port, True, value)

    async def read_port(self, port):
        return await self._access(port, False)

    async def run(self, ops):
        """Run a v9990_sequences op list; returns the reads."""
        reads = []
        for op in ops:
            if op[0] == "out":
                await self.write_port(op[1], op[2])
            elif op[0] == "block":
                for v in op[2]:
                    await self.write_port(op[1], v)
            elif op[0] == "in":
                reads.append(await self.read_port(op[1]))
            elif op[0] == "poll":
                _, port, mask, val = op
                for _ in range(3000):
                    if (await self.read_port(port)) & mask == val:
                        break
                else:
                    cmd = self.dut.inst_core.inst_cmd
                    raise AssertionError(f"poll of port {port:02x} timed out; engine state {cmd.st.value} op {cmd.op.value} "
                                         f"ANX {int(cmd.ANX.value)} ANY {int(cmd.ANY.value)} tr {cmd.tr.value}")
            elif op[0] == "tr_out_p":
                _, port, sport, data = op
                for v in data:
                    await self.run([("poll", sport, 0x80, 0x80)])
                    await self.write_port(port, v)
            elif op[0] == "tr_in_p":
                _, port, sport, n = op
                for _ in range(n):
                    await self.run([("poll", sport, 0x80, 0x80)])
                    reads.append(await self.read_port(port))
            elif op[0] == "delay":
                # LD B,n; DJNZ $: 13 T-states (12 clocks each) per count.
                await Timer(op[1] * 13 * 12 * CLK_PS, "ps")
        return reads


# -- Scenes and frames ---------------------------------------------------------

import os
from pathlib import Path

import numpy as np

import v9990_model as vm

CAPTURE_DIR = Path(os.environ.get("V9990_CAPTURE_DIR", "."))


async def load_scene(v, vram, regs, palette, mcs=False):
    """VRAM (physical, written straight into the block RAM), palette and
    registers R#6-R#28 (through the ports, R#8 last), MCS."""
    dut = v.dut
    with open(CAPTURE_DIR / "vram.hex", "w") as f:
        half = 1 << 18
        f.write("".join(f"{vram[w + half]:02X}{vram[w]:02X}\n" for w in range(half)))
    await FallingEdge(v.clk)
    dut.load_i.value = 1
    await RisingEdge(dut.loading_o)
    await FallingEdge(dut.loading_o)
    dut.load_i.value = 0
    await v.write_port(0x67, 1 if mcs else 0)
    await v.write_port(0x64, 14)
    await v.write_port(0x63, 0)
    for i in range(64):
        for c in range(3):
            await v.write_port(0x61, palette[4 * i + c])
    await v.write_port(0x64, 6)
    for r in range(6, 29):
        await v.write_port(0x63, regs[r] if r != 8 else 0)
    await v.write_port(0x64, 8)
    await v.write_port(0x63, regs[8])


async def capture_frame(v, step=1):
    """The next whole frame: (lines, 2736 / step, 3) 8-bit RGB, sampled every
    step clocks from clock 0 of each line."""
    dut = v.dut
    dut.cap_step_i.value = step
    start = int(dut.frames_o.value)
    dut.capture_en_i.value = 1
    while int(dut.frames_o.value) == start:
        await dut.frames_o.value_change
    await FallingEdge(v.clk)
    dut.capture_en_i.value = 0
    await ClockCycles(v.clk, 2)                 # seen low before the next capture
    path = CAPTURE_DIR / f"v9990_{start}.ppm"
    with open(path) as f:
        f.readline()
        data = np.loadtxt(f, dtype=np.int32)
    w = (2735 + step) // step
    return data.reshape(-1, w, 3)


def c8(c):
    return (c << 3) | (c >> 2)


def expected_frame(vram, regs, palette, mcs=False, pal=False, eo=0, frame_regs=None):
    """(lines, 2736, 3) 8-bit RGB the RTL should output."""
    left, right, top, bottom, lines = vm.geometry(regs, mcs, pal)
    mode = vm.display_mode(regs, mcs)
    os_ = vm.is_overscan(regs, mcs)
    border = (0, 0, 0) if os_ else vm.pal_rgb(palette, regs[15] & 63)
    out = np.zeros((lines, vm.H_TOTAL, 3), dtype=np.int32)
    # Picture: display area and border; overscan: the display area.
    vis_l, vis_r = (left, right) if os_ else (400, 400 + 2 * 112 + 2048)
    vis_t, vis_b = (top, bottom) if os_ else (15, 15 + 2 * (41 if pal else 14) + 212)
    bm = None
    if regs[8] & 0x80:
        bm = vm.Pattern(vram, regs, palette) if mode in ("P1", "P2") else vm.Bitmap(vram, regs, palette, mcs, eo=eo)
    pclk = vm.PIXEL_CLOCKS[mode]
    for y in range(vis_t, vis_b):
        row = np.array([c8(c) for c in border])
        out[y, vis_l:vis_r] = row
        if bm is not None and top <= y < bottom:
            px = np.array([[c8(c) for c in p] for p in bm.line(y - top)])
            out[y, left:right] = np.repeat(px, pclk, axis=0)[:right - left]
    return out


def compare_frames(name, got, exp):
    """Assert a captured frame equals the expected one; if not, both go to
    CAPTURE_DIR as <name>_rtl.png and <name>_model.png (every other clock)."""
    assert got.shape == exp.shape, f"{name}: frame {got.shape}, expected {exp.shape}"
    diff = np.any(got != exp, axis=2)
    if diff.any():
        from PIL import Image
        Image.fromarray(got[:, ::2].astype(np.uint8)).save(CAPTURE_DIR / f"{name}_rtl.png")
        Image.fromarray(exp[:, ::2].astype(np.uint8)).save(CAPTURE_DIR / f"{name}_model.png")
        ys, xs = np.nonzero(diff)
        y, x = ys[0], xs[0]
        raise AssertionError(f"{name}: {diff.sum()} clocks differ, first line {y} clock {x}: "
                             f"RTL {got[y, x]} model {exp[y, x]}")
