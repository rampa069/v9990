"""V9990 command engine of the RTL against the reference model
(v9990_cmd.py): the sequences of v9990_sequences.SEQUENCES_CMD (checked
against openMSX in test_v9990_model_openmsx.py), every command in the six
command modes, compared on the reads, the registers and the VRAM."""

import cocotb

import v9990_model as vm
import v9990_sequences
from test_v9990_model_openmsx import TIMING_BITS, run_model
from v9990_driver import V9990

_last = None


async def check(dut, seq):
    global _last
    v = V9990(dut)
    await v.reset()
    ops = v9990_sequences.SEQUENCES_CMD[seq]()
    import time
    t0 = time.time()
    reads = await v.run(ops)
    t1 = time.time()
    exp_reads, model = run_model(ops, _last)
    dut._log.info(f"{seq}: RTL {t1 - t0:.1f} s, model {time.time() - t1:.1f} s")
    _last = model
    assert len(reads) == len(exp_reads)
    for k, (got, (port, exp)) in enumerate(zip(reads, exp_reads)):
        mask = 0xFF & ~TIMING_BITS.get(port, 0)
        assert got & mask == exp & mask, f"read {k} port {port:02x}: RTL {got:02x} model {exp:02x}"
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


def cmd_test(name):
    async def run(dut):
        await check(dut, name)
    run.__name__ = name
    run.__qualname__ = name
    return cocotb.test()(run)


for _n in v9990_sequences.SEQUENCES_CMD:
    globals()[_n] = cmd_test(_n)
