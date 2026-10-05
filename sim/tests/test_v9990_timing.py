"""V9990 display timing: line and frame length, display area and R#16,
status VR / HR / EO, the vertical and line interrupts, border color.
Expected values from v9990_model.geometry / hint_position (openMSX)."""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

import v9990_model as vm
from v9990_driver import V9990

P = 0x60


async def set_regs(v, reg, values):
    await v.write_port(P + 4, reg)
    for x in values:
        await v.write_port(P + 3, x)


async def position(dut):
    r = dut.inst_core.inst_raster
    return int(r.vcnt.value), int(r.hcnt.value)


async def wait_frame(dut):
    """Wait for the first clock of the next frame."""
    r = dut.inst_core.inst_raster
    while True:
        await RisingEdge(dut.clk_o)
        await ReadOnly()
        if r.frame_o.value == 1:
            return


async def edge_period(dut, signal, n=3):
    clk = dut.clk_o
    times = []
    count = 0

    async def counter():
        nonlocal count
        while True:
            await RisingEdge(clk)
            count += 1

    task = cocotb.start_soon(counter())
    for _ in range(n + 1):
        await FallingEdge(signal)
        times.append(count)
    task.cancel()
    return [b - a for a, b in zip(times, times[1:])]


@cocotb.test()
async def line_and_frame(dut):
    v = V9990(dut)
    await v.reset()
    assert set(await edge_period(dut, dut.hsync_n_o)) == {vm.H_TOTAL}
    assert set(await edge_period(dut, dut.vsync_n_o, 2)) == {262 * vm.H_TOTAL}
    await set_regs(v, 7, [0x08])                        # PAL, from the next frame
    await wait_frame(dut)
    assert set(await edge_period(dut, dut.vsync_n_o, 2)) == {313 * vm.H_TOTAL}


async def check_area(dut, regs, mcs=False, pal=False):
    """HR / VR of the raster against the model on a grid over a frame."""
    left, right, top, bottom, lines = vm.geometry(regs, mcs, pal)
    r = dut.inst_core.inst_raster
    await wait_frame(dut)
    seen = 0
    while seen < lines * 8:
        await ClockCycles(dut.clk_o, 337)
        await ReadOnly()
        y, x = int(r.vcnt.value), int(r.hcnt.value)
        hr = x < left or x >= right
        vr = y < top or y >= bottom
        assert int(r.hr.value) == hr, f"HR at line {y} clock {x}: RTL {r.hr.value}, area {left}-{right}"
        assert int(r.vr.value) == vr, f"VR at line {y} clock {x}: RTL {r.vr.value}, area {top}-{bottom}"
        seen += 1


@cocotb.test()
async def display_area(dut):
    v = V9990(dut)
    await v.reset()
    regs = [0] * 64
    await check_area(dut, regs)
    for adj in (0x77, 0x88, 0x3C, 0xF0):
        regs[16] = adj
        await set_regs(v, 16, [adj])
        await check_area(dut, regs)
    # Overscan (B2, MCS) and PAL.
    regs[6], regs[7], regs[16] = 0x90, 0x08, 0x00
    await set_regs(v, 6, [0x90, 0x08])
    await set_regs(v, 16, [0x00])
    await v.write_port(P + 7, 0x01)
    await wait_frame(dut)
    await check_area(dut, regs, mcs=True, pal=True)


@cocotb.test()
async def status_bits(dut):
    """P#5: VR / HR follow the raster, EO flips every frame, MCS."""
    v = V9990(dut)
    await v.reset()
    left, right, top, bottom, _ = vm.geometry([0] * 64)
    eo = []
    for _ in range(3):
        await wait_frame(dut)
        s = await v.read_port(P + 5)
        eo.append(s & 0x02)
        assert s & 0x40, "VR in the top blank"
    assert eo[0] != eo[1] and eo[1] != eo[2], f"EO {eo}"
    # Somewhere in the display area.
    r = dut.inst_core.inst_raster
    while True:
        await RisingEdge(dut.clk_o)
        await ReadOnly()
        if int(r.vcnt.value) == top + 10 and int(r.hcnt.value) == left + 100:
            break
    await RisingEdge(dut.clk_o)
    s = await v.read_port(P + 5)
    assert s & 0x60 == 0, f"status {s:02x} in the display area"
    await v.write_port(P + 7, 0x01)
    assert await v.read_port(P + 5) & 0x04


async def wait_int(dut, limit=2 * 313 * vm.H_TOTAL):
    """Position of the next falling edge of INT (one that happened while
    the caller was busy is skipped)."""
    high = False
    for _ in range(limit):
        await RisingEdge(dut.clk_o)
        await ReadOnly()
        if dut.int_n_o.value == 1:
            high = True
        elif high:
            return await position(dut)
    raise AssertionError("no interrupt")


@cocotb.test()
async def vertical_interrupt(dut):
    v = V9990(dut)
    await v.reset()
    bottom = vm.geometry([0] * 64)[3]
    await v.write_port(P + 6, 0x07)
    await set_regs(v, 9, [0x01])
    for _ in range(2):
        y, x = await wait_int(dut)
        assert y == bottom and x <= 4, f"VI at line {y} clock {x}, expected line {bottom}"
        await RisingEdge(dut.clk_o)
        assert await v.read_port(P + 6) & 0x01
        await v.write_port(P + 6, 0x01)
        assert dut.int_n_o.value == 1


@cocotb.test()
async def line_interrupt(dut):
    v = V9990(dut)
    await v.reset()
    await v.write_port(P + 6, 0x07)
    for mcs, r10, r11, r12 in ((0, 50, 0, 0), (0, 0, 0, 5), (1, 20, 0, 5),
                               (1, 3, 0, 15), (0, 0xC0, 0x00, 2)):
        regs = [0] * 64
        regs[10], regs[11], regs[12] = r10, r11, r12
        await v.write_port(P + 7, mcs)
        await set_regs(v, 9, [0x02, r10, r11, r12])
        await v.write_port(P + 6, 0x07)
        exp = vm.hint_position(regs, bool(mcs))
        y, x = await wait_int(dut, 2 * 313 * vm.H_TOTAL)
        # The flag is registered twice (raster, P#6) before INT.
        assert y == exp[0] and 0 <= x - exp[1] <= 3, f"HI {r10},{r11},{r12} MCS {mcs}: line {y} clock {x}, expected {exp}"
        await set_regs(v, 9, [0x00])
    # Every line (R#11 bit 7).
    await set_regs(v, 9, [0x02, 0, 0x80, 1])
    await v.write_port(P + 7, 0x00)
    # The raster pulses (INT stays low while the flag is set).
    r = dut.inst_core.inst_raster
    lines = []
    while len(lines) < 3:
        await RisingEdge(dut.clk_o)
        await ReadOnly()
        if r.irq_h_o.value == 1:
            y, x = await position(dut)
            assert x == 129, f"HI every line at clock {x}"
            lines.append(y)
    assert lines[1] == lines[0] + 1 and lines[2] == lines[1] + 1, f"HI lines {lines}"


@cocotb.test()
async def border_color(dut):
    """Backdrop R#15 from the palette in the border and, with the display
    disabled, the display area; black in the overscan modes."""
    v = V9990(dut)
    await v.reset()
    await set_regs(v, 14, [4 * 5])
    for c in (31, 16, 3):
        await v.write_port(P + 1, c)
    await set_regs(v, 15, [5])
    await wait_frame(dut)
    await wait_frame(dut)
    left, right, top, bottom, _ = vm.geometry([0] * 64)
    exp = tuple((c << 3) | (c >> 2) for c in (31, 16, 3))
    for y, x in ((top - 5, 1000), (top + 50, left - 20), (top + 100, left + 500)):
        while True:
            await RisingEdge(dut.clk_o)
            await ReadOnly()
            if int(dut.vid_y_o.value) == y and int(dut.vid_x_o.value) == x:
                break
        got = tuple(int(s.value) for s in (dut.red_o, dut.grn_o, dut.blu_o))
        assert got == exp, f"line {y} clock {x}: {got}, expected {exp}"
    # Blanking.
    while True:
        await RisingEdge(dut.clk_o)
        await ReadOnly()
        if int(dut.vid_x_o.value) == 100:
            break
    assert int(dut.red_o.value) == 0 and dut.hblank_o.value == 1
