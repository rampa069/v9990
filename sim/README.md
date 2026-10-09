# V9990 simulation tests

Simulates `v9990_core` with [NVC](https://www.nickg.me.uk/nvc/) and drives
it from Python with [cocotb](https://www.cocotb.org/).

## Setup

```bash
brew install nvc          # VHDL simulator (GHDL's Homebrew cask is disabled)
make -C sim setup         # creates ../.venv with cocotb, pytest, numpy, pillow
```

## Running

```bash
make -C sim test                        # everything
make -C sim test T=v9990_cmd            # one module: v9990_io, v9990_timing, v9990_display, v9990_cmd
make -C sim test-quick                  # one test of each area
make -C sim test-trace                  # traces of real software (../tmp/traces, see below)
make -C sim test-openmsx                # the model against openMSX (~2 min, needs the oracle host)
```

Logs, results and captured frames go to `sim/sim_build/`
(`<module>.log`, `frames/<module>/`).

## Layout

| File | Purpose |
|---|---|
| `tb/v9990_tb.vhd`, `v9990_driver.py` | Testbench: 42.95 MHz core clock, VRAM in block RAM, synchronous host bus (req / ack) |
| `v9990_model.py` | Reference model following openMSX (`src/video/v9990`): CPU interface, display timing, bitmap modes and cursors |
| `v9990_cmd.py` | Command engine model (openMSX V9990CmdEngine without its timing) |
| `v9990_sequences.py` | Port sequences (`SEQUENCES_CMD` for the commands, run by the Z80 polling CE / TR) |
| `v9990_scenes.py` | Display scenes |
| `tests/test_v9990_io.py` | CPU interface (ports 60h-6Fh, registers, palette, VRAM pointers and mapping, system reset) against the model |
| `tests/test_v9990_timing.py` | Line / frame timing (NTSC, PAL), display area and R#16, status VR / HR / EO, VI and HI interrupts, border color |
| `tests/test_v9990_cmd.py` | Command engine against `v9990_cmd.py`: every command in the six command modes (P1, P2, 2 / 4 / 8 / 16 bpp), directions, logical operations with TP, write masks, CPU transfers, corner cases; reads, VRAM |
| `v9990_trace.py`, `tests/test_v9990_trace.py`, `openmsx/capture.tcl` | Traces of real software captured in openMSX, replayed on the RTL and the model (below) |
| `tests/test_v9990_display.py` | Bitmap modes against the model, one frame per scene compared clock by clock: B0-B4, B7, all color modes, scroll and roll, cursors, overscan, PAL, even / odd pages, C25M without HSCN, display off, CPU writes during the display |

## Reference model and openMSX oracle

The model is checked against openMSX with the GFX9000 extension
(`v9990_oracle.py`): the port sequences are run by the Z80 and the
`Sunrise GFX9000` regs, palette and VRAM debuggables dumped; the scenes are
loaded through the debugger and the raw double size screenshots
(`set ::videosource GFX9000`) compared with the model through the openMSX
DAC curve (calibrated with a 16 bpp ramp).  The screenshots are 640 pixels
wide, so B7 is compared as pairs of pixels.

openMSX (free C-BIOS ROMs) runs headless in Docker with Xvfb on the host
`V9990_OPENMSX_HOST` (default `rampa@ea5iue-laptop.local`, working
directory `V9990_OPENMSX_DIR`), image `openmsx-master` built from
`openmsx/Dockerfile.master` (`V9990_OPENMSX_IMAGE` selects another one,
e.g. `openmsx-headless` from `openmsx/Dockerfile`).  `openmsx_host.py` has
the host settings and the Z80 program assembler.

## Traces of real software

`openmsx/capture.tcl` runs a game in openMSX with the GFX9000 and saves a
trace: the V9990 state (VRAM, registers, palette, selected register) when
a command is started after `TRACE_T0` seconds, every access to ports
60h-6Fh from there, and the state at the first command started `TRACE_LEN`
seconds later.  openMSX keeps no copy of R#32-R#63, so the script shadows
every register write from power-on.  `TRACE_KEYS` presses keys on the
keyboard matrix to get through menus:

```bash
docker run --rm -v $PWD/title:/work -e TRACE_T0=12.5 -e TRACE_LEN=5 \
    -e TRACE_KEYS='{8 8 1 0.2} {12 8 1 0.2}' openmsx-master sh -c \
    'xvfb-run -a openmsx -machine C-BIOS_MSX2+ -ext gfx9000 -carta /work/game.rom \
     -romtype KonamiSCC -script /work/capture.tcl'
```

Copy `t0_*`, `t1_*` and `accesses.log` to `../tmp/traces/<name>/` (the
game data stays out of git).  `tests/test_v9990_trace.py` loads t0 into
the RTL, runs the accesses (waiting for CE = 0 before each command register
write, as the game polls CE itself) and compares the VRAM with the model
running the same accesses and with openMSX at t1, then one frame of the RTL
with the model showing the t1 state (P1 sprites included).
`test_v9990_model_openmsx.py::test_trace` loads the t1 state into openMSX
like a display scene and checks that picture against its screenshot.
