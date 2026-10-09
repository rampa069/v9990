"""The openMSX oracle host and the Z80 port sequence assembler.

openMSX (C-BIOS machines, free ROMs) runs headless in a Docker container
with Xvfb on a Linux host.  Host setup (once): a Docker image
"openmsx-master" (openMSX built from git master) from
sim/openmsx/Dockerfile.master on the host given by V9990_OPENMSX_HOST
(default rampa@ea5iue-laptop.local), working directory V9990_OPENMSX_DIR.
V9990_OPENMSX_IMAGE=openmsx-headless (Debian's openMSX 20.0,
sim/openmsx/Dockerfile) selects the older version.

The port sequences are assembled into a Z80 program (z80_program) that
v9990_oracle starts from the H.TIMI hook, so reads and writes have their
real side effects.
"""

import os

HOST = os.environ.get("V9990_OPENMSX_HOST", "rampa@ea5iue-laptop.local")
REMOTE_DIR = os.environ.get("V9990_OPENMSX_DIR", "fpga/openmsx-docker")
IMAGE = os.environ.get("V9990_OPENMSX_IMAGE", "openmsx-master")

PROG_ADDR = 0xC000      # Z80 program in RAM (up to READS_ADDR, 10 KB)
READS_ADDR = 0xE800     # IN results


def z80_program(ops):
    """Assemble the port sequence: DI, then LD A,n / OUT (p),A and
    IN A,(p) / LD (nn),A with a few NOPs between accesses, then DI; HALT.

    Besides ("out", port, value) and ("in", port), the ops can be:
      ("delay", n)          LD B,n; DJNZ $ (13 T-states per count)
      ("block", port, data) OUT every byte of data, from a loop
      ("poll", p, mask, v)  IN A,(p); AND mask until the result is v (0 or
                            mask)
      ("tr_out_p", p, s, data)  for every byte: wait for bit 7 of port s,
                            OUT (p)
      ("tr_in_p", p, s, n)  n times: wait for bit 7 of port s, IN A,(p)
                            (stored like an IN)
    The model side (see test_v9990_model_openmsx.run_model) treats the
    waits and delays as no-ops.
    """
    code = bytearray([0xF3])                            # DI
    n_reads = 0

    def here():
        return PROG_ADDR + len(code)

    def loop_over(data, body):
        """LD HL,data; LD B,len; body (uses (HL)); INC HL; DJNZ; data after a JP."""
        nonlocal code
        start = len(code)
        code += bytes([0x21, 0, 0, 0x06, len(data) & 0xFF])
        top = len(code)
        code += body + bytes([0x23]) + bytes(4)         # INC HL, NOPs
        code += bytes([0x10, (top - (len(code) + 2)) & 0xFF])   # DJNZ top
        after = here() + 3 + len(data)
        code += bytes([0xC3, after & 0xFF, after >> 8])          # JP over data
        daddr = here()
        code += bytes(data)
        code[start + 1] = daddr & 0xFF
        code[start + 2] = daddr >> 8

    for op in ops:
        kind = op[0]
        if kind == "out":
            code += bytes([0x3E, op[2] & 0xFF, 0xD3, op[1]])
        elif kind == "in":
            addr = READS_ADDR + n_reads
            code += bytes([0xDB, op[1], 0x32, addr & 0xFF, addr >> 8])
            n_reads += 1
        elif kind == "poll":
            _, port, mask, val = op
            code += bytes([0xDB, port, 0xE6, mask, 0x20 if val == 0 else 0x28, 0xFA])
        elif kind == "tr_out_p":
            _, port, sport, data = op
            assert 0 < len(data) <= 256
            loop_over(data, bytes([0xDB, sport, 0xE6, 0x80, 0x28, 0xFA, 0x7E, 0xD3, port]) + bytes(8))
        elif kind == "tr_in_p":
            _, port, sport, n = op
            assert 0 < n <= 256
            addr = READS_ADDR + n_reads
            code += bytes([0x21, addr & 0xFF, addr >> 8, 0x06, n & 0xFF])
            top = len(code)
            code += bytes([0xDB, sport, 0xE6, 0x80, 0x28, 0xFA])
            code += bytes([0xDB, port, 0x77, 0x23]) + bytes(4)
            code += bytes([0x10, (top - (len(code) + 2)) & 0xFF])
            n_reads += n
        elif kind == "delay":
            code += bytes([0x06, op[1] & 0xFF, 0x10, 0xFE])
        elif kind == "block":
            assert 0 < len(op[2]) <= 256
            loop_over(op[2], bytes([0x7E, 0xD3, op[1]]) + bytes(8))     # LD A,(HL); OUT (p),A
        else:
            raise ValueError(f"unknown op {op}")
        code += bytes(8)                                # NOPs: VDP access time
    code += bytes([0xF3, 0x76, 0x18, 0xFE])             # DI; HALT; JR $
    assert PROG_ADDR + len(code) < READS_ADDR, f"sequence too long ({len(code)} bytes)"
    return bytes(code), n_reads
