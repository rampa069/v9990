"""Traces of real software (v9990_trace.py, captured in openMSX): the RTL
loaded with the state at t0 runs the port accesses of the trace, then its
VRAM is compared with the model running the same accesses and with the
openMSX state at t1.  Skipped when there are no traces (the game data stays
out of git)."""

import time

import cocotb

import v9990_trace as tr
from v9990_driver import V9990, load_scene


async def load_state(v, s):
    """The t0 state: VRAM, palette, R#6-R#28 (load_scene), the VRAM pointers
    R#0-R#5, the command registers R#32-R#51 and the selected register."""
    await load_scene(v, s.vram, s.regs, s.palette)
    await v.write_port(0x64, 0)
    for r in range(6):
        await v.write_port(0x63, s.regs[r])
    await v.write_port(0x64, 32)
    for r in range(32, 52):
        await v.write_port(0x63, s.regs[r])
    await v.write_port(0x64, s.regsel)


async def check(dut, d):
    v = V9990(dut)
    await v.reset()
    s0, s1 = tr.load_state(d, "t0"), tr.load_state(d, "t1")
    ops = tr.load_ops(d)
    await load_state(v, s0)
    t = time.time()
    await v.run(tr.with_ce_waits(ops, s0.regsel))
    await v.run([("poll", 0x65, 0x01, 0)])
    dut._log.info(f"{d.name}: {len(ops)} accesses, RTL {time.time() - t:.1f} s")
    model = tr.replay_model(s0, ops)
    changed = [p for p in range(len(s0.vram)) if model.vram[p] != s0.vram[p] or s1.vram[p] != s0.vram[p]]
    addrs = sorted(set(changed) | set(range(0, len(s0.vram), 997)))
    bad = []
    for p in addrs:
        ram = dut.inst_vram.ram_hi if p & 0x40000 else dut.inst_vram.ram_lo
        got = int(ram[p & 0x3FFFF].value)
        if got != model.vram[p] or got != s1.vram[p]:
            bad.append((p, got, model.vram[p], s1.vram[p]))
    dut._log.info(f"{d.name}: {len(changed)} VRAM bytes changed, {len(addrs)} compared")
    assert not bad, f"{d.name}: {len(bad)} VRAM bytes differ: " + ", ".join(
        f"{p:05x} RTL {g:02x} model {m:02x} openMSX {o:02x}" for p, g, m, o in bad[:8])


def trace_test(d):
    async def run(dut):
        await check(dut, d)
    run.__name__ = f"trace_{d.name}"
    run.__qualname__ = run.__name__
    return cocotb.test()(run)


for _d in tr.traces():
    globals()[f"trace_{_d.name}"] = trace_test(_d)


@cocotb.test(skip=bool(tr.traces()))
async def no_traces(dut):
    """Placeholder so the module runs when there are no traces."""
