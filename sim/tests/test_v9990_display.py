"""V9990 display against the model: the scenes of v9990_scenes.py (checked
against openMSX in test_v9990_model_openmsx.py) and a few more (overscan
modes, PAL, even / odd pages, display off), one frame each, compared clock
by clock (8-bit RGB: the 5-bit levels expanded)."""

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles

import v9990_model as vm
import v9990_scenes
from v9990_driver import V9990, capture_frame, compare_frames, expected_frame, load_scene


async def check(dut, name, vram, regs, palette, mcs=False, pal=False):
    v = V9990(dut)
    await v.reset()
    await load_scene(v, vram, regs, palette, mcs)
    if pal:
        await v.write_port(0x64, 7)
        await v.write_port(0x63, regs[7] | 0x08)
    for _ in range(2):
        await capture_frame(v)                   # settle (R#18, PAL, display at frame start)
    eo = (int(await v.read_port(0x65)) >> 1) & 1
    got = await capture_frame(v)
    r = list(regs)
    if pal:
        r[7] |= 0x08
    # EO flips at the start of the captured frame.
    exp = expected_frame(vram, r, palette, mcs, pal, eo ^ 1)
    compare_frames(name, got, exp)


def scene_test(name):
    async def run(dut):
        vram, regs, pal, mcs = v9990_scenes.SCENES[name]()
        await check(dut, name, vram, regs, pal, mcs)
    run.__name__ = f"render_{name}"
    run.__qualname__ = run.__name__
    return cocotb.test()(run)


for _n in v9990_scenes.SCENES:
    globals()[f"render_{_n}"] = scene_test(_n)


def _extra(name, r6, r13=0, mcs=False, **kw):
    vram, regs, pal, _ = v9990_scenes.bitmap(name, r6, r13, seed=20, **kw)
    return vram, regs, pal, mcs


@cocotb.test()
async def render_b0_overscan(dut):
    await check(dut, "b0", *_extra("b0", 0x81, 0x04, mcs=True))


@cocotb.test()
async def render_b2_overscan(dut):
    await check(dut, "b2", *_extra("b2", 0x96, 0x00, mcs=True))


@cocotb.test()
async def render_b4_overscan(dut):
    await check(dut, "b4", *_extra("b4", 0xA5, 0x04, mcs=True))


@cocotb.test()
async def render_pal(dut):
    await check(dut, "pal", *_extra("pal", 0x81, 0x00, r16=0x9A), pal=True)


@cocotb.test()
async def render_eo_pages(dut):
    await check(dut, "eo", *_extra("eo", 0x81, 0x00, r7=0x04))


@cocotb.test()
async def render_c25m(dut):
    """R#7 C25M without HSCN (Ghosts'n Goblins title: R#6 86h, R#7 40h) is
    plain B1, as in openMSX: no B5 / B6, same timing and picture."""
    await check(dut, "c25m", *_extra("c25m", 0x86, 0x00, r7=0x40))


@cocotb.test()
async def render_display_off(dut):
    vram, regs, pal, mcs = _extra("off", 0x81, 0x00)
    regs[8] = 0x00
    await check(dut, "off", vram, regs, pal, mcs)


@cocotb.test()
async def render_cpu_writes(dut):
    """CPU writes through P#0 while the display reads VRAM (arbiter)."""
    vram, regs, pal, mcs = _extra("cpu", 0x83, 0x00)          # B1, 16 bpp
    v = V9990(dut)
    await v.reset()
    await load_scene(v, vram, regs, pal, mcs)
    await capture_frame(v)
    addr = 2 * (256 * 40 + 100)                                 # line 40, pixel 100
    await v.write_port(0x64, 0)
    for b in (addr & 0xFF, (addr >> 8) & 0xFF, addr >> 16):
        await v.write_port(0x63, b)
    data = [(k * 37 + 11) & 0xFF for k in range(96)]
    for k, b in enumerate(data):
        await v.write_port(0x60, b)
        vram[vm.vram_phys(addr + k, 0x80)] = b
    await capture_frame(v)
    eo = (int(await v.read_port(0x65)) >> 1) & 1
    got = await capture_frame(v)
    exp = expected_frame(vram, regs, pal, mcs, False, eo ^ 1)
    diff = np.any(got != exp, axis=2)
    assert not diff.any(), f"{diff.sum()} clocks differ after the CPU writes"
