"""The host at the speed of a real CPU (a few clocks between accesses, not
the 600 of the other tests), against the model, on the VRAM:

* r6_then_cmd: R#6 from P1 to a bitmap mode, then at once a command and CPU
  writes to the VRAM: the command mode and the VRAM mapping follow R#6 at
  once, not the mode of the current line (SymbOS G9K, ZEMMIX-s09).
* p2_no_tr: LMMC and CMMC data written to P#2 without polling TR: the host
  waits until the engine has taken the byte (SymbOS G9K font cache).

Both matter with a slow VRAM: make test-zemmix runs them with the timing of
the SDRAM of ZEMMIX."""

import cocotb

import v9990_model as vm
from test_v9990_model_openmsx import run_model
from v9990_driver import V9990

HOST_GAP = 16
_last = None                                        # the VRAM survives the reset between tests


def regs(first, values):
    """Registers from 'first' on, auto increment."""
    return [("out", 0x64, first)] + [("out", 0x63, v) for v in values]


def cmd(dx, dy, nx, ny, lop, fc, bc, op, arg=0):
    w = lambda v: [v & 0xFF, v >> 8]
    return regs(36, w(dx) + w(dy) + w(nx) + w(ny) + [arg, lop] + w(0xFFFF) + w(fc) + w(bc) + [op])


async def check(dut, ops):
    global _last
    v = V9990(dut)
    await v.reset()
    v.gap = HOST_GAP
    await v.run(ops)
    _, model = run_model(ops, _last)
    _last = model
    vram = dut.inst_vram
    power_on = vm.power_on_vram()
    addrs = [p for p in range(vm.VRAM_SIZE) if model.vram[p] != power_on[p]]
    addrs += list(range(0, vm.VRAM_SIZE, 997))
    bad = []
    for p in addrs:
        ram = vram.ram_hi if p & 0x40000 else vram.ram_lo
        got = int(ram[p & 0x3FFFF].value)
        if got != model.vram[p]:
            bad.append((p, got))
    assert not bad, f"{len(bad)} VRAM bytes differ: " + ", ".join(
        f"{p:05x} RTL {g:02x} model {model.vram[p]:02x}" for p, g in bad[:8])


DONE = [("poll", 0x65, 0x01, 0)]


@cocotb.test()
async def r6_then_cmd(dut):
    ops = []
    ops += regs(8, [0x82])                          # display on, in P1 (after reset)
    ops += regs(6, [0x95, 0x00])                    # B3, 4 bpp: then at once
    ops += cmd(10, 5, 40, 8, 0x0C, 0x5555, 0, 0x20)  # LMMV
    ops += DONE
    ops += regs(0, [0x00, 0x10, 0x00])             # VRAM write address 01000h
    ops += [("out", 0x60, 0x11 * (i & 15)) for i in range(32)]
    await check(dut, ops)


@cocotb.test()
async def p2_no_tr(dut):
    ops = []
    ops += regs(6, [0x95, 0x00])                    # B3, 4 bpp
    ops += regs(8, [0x82])
    ops += cmd(3, 2, 16, 8, 0x0C, 0, 0, 0x10)       # LMMC 16 x 8: 64 bytes (2 pixels each)
    ops += [("out", 0x62, (i * 37) & 0xFF) for i in range(64)]
    ops += DONE
    ops += cmd(40, 20, 16, 8, 0x0C, 0x7777, 0x2222, 0x50)   # CMMC 16 x 8: 16 bytes (8 pixels each)
    ops += [("out", 0x62, (i * 91) & 0xFF) for i in range(16)]
    ops += DONE
    await check(dut, ops)
