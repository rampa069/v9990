"""V9990 CPU interface of the RTL against the reference model.

Runs the port sequences of v9990_sequences.py (checked against openMSX in
test_v9990_model_openmsx.py) on the RTL and on v9990_model, then compares
the reads, the registers, the palette and the VRAM.
"""

import cocotb

import v9990_model as vm
import v9990_sequences
from test_v9990_model_openmsx import TIMING_BITS, run_model
from v9990_driver import V9990


# The VRAM and the palette survive the reset between tests: the model of the
# previous test of this simulation.
_last = None


async def check(dut, seq):
    global _last
    v = V9990(dut)
    await v.reset()
    ops = v9990_sequences.SEQUENCES[seq]()
    reads = await v.run(ops)
    exp_reads, model = run_model(ops, _last)
    _last = model
    cpu = dut.inst_core.inst_cpu

    for k, (got, (port, exp)) in enumerate(zip(reads, exp_reads)):
        mask = 0xFF & ~TIMING_BITS.get(port, 0)
        assert got & mask == exp & mask, f"read {k} port {port:02x}: RTL {got:02x} model {exp:02x}"
    for r in range(53):
        got = int(cpu.regs[r].value)
        assert got == model.regs[r], f"R#{r}: RTL {got:02x} model {model.regs[r]:02x}"
    for i in range(64):
        for c, ram in enumerate((cpu.pal_r, cpu.pal_g, cpu.pal_b)):
            got = int(ram[i].value)
            exp = model.palette[4 * i + c]
            assert got == exp, f"palette {i}.{'RGB'[c]}: RTL {got:02x} model {exp:02x}"
    # VRAM: every byte the model changed, and a sample of the rest.
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
    assert not bad, "VRAM differs: " + ", ".join(f"{p:05x} RTL {g:02x} model {model.vram[p]:02x}" for p, g in bad)


@cocotb.test()
async def io_basic(dut):
    await check(dut, "basic")


@cocotb.test()
async def io_masks(dut):
    await check(dut, "masks")


@cocotb.test()
async def io_maps(dut):
    await check(dut, "maps")


@cocotb.test()
async def io_noinc(dut):
    await check(dut, "noinc")


@cocotb.test()
async def io_srs(dut):
    await check(dut, "srs")
