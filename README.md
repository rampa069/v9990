# V9990

  The Yamaha V9990 (E-VDP-III, the GFX9000 VDP for MSX) in VHDL, for FPGA
  retro computer cores (MiST family boards, OCM-PLD / ZEMMIX MSX cores).

  Split from the F18A 3.0 fork (https://github.com/rampa069/f18a), where it
  was developed; the history of `rtl/` starts there.

---

## Status

  * Ports 60h-6Fh, the registers, the palette, VRAM pointers and mapping,
    system reset.
  * Display timing (NTSC, PAL), status VR / HR / EO, VI and HI interrupts.
  * Bitmap modes B0-B4 and B7 in every color mode, scroll and roll, the
    cursors, overscan, even / odd pages.
  * Pattern modes P1 and P2 with their sprites.
  * The command engine (blitter): every command in the six command modes.
  * High scan B5 / B6 (R#7 HSCN, C25M: 640x400 at 25 kHz, 640x480 at
    31 kHz), not in openMSX: line and frame from the V9990 Application
    Manual (13.3.12 / 13.3.13), B6 with 25.175 MHz dots on the 42.95 MHz
    clock (640 pixels in 1092 clocks, 1 or 2 clocks each).  Not checked
    against a real chip.

  The core (`rtl/v9990_core.vhd`) runs from a 42.95 MHz clock and keeps
  its 512 KB VRAM in block RAM (`rtl/v9990_vram_bram.vhd`), or in an SDRAM
  behind `rtl/v9990_vram_cache.vhd` (lines of 4 words; the sprite
  attribute table is copied in block RAM by the core).  In the simulation
  `V9990_VRAM_LAT=7 V9990_VRAM_GAP=5 V9990_VRAM_CACHE=4` is the SDRAM of
  ZEMMIX.

## Layout

| Path | Contents |
|---|---|
| `rtl/` | The core: `v9990_core` and its units (CPU interface, raster, bitmap and pattern modes, sprites, command engine) |
| `sim/` | NVC + cocotb testbench, reference model checked against openMSX (see `sim/README.md`) |

## Tests

```bash
brew install nvc
make -C sim setup
make -C sim test-quick     # one test of each area
make -C sim test           # everything
```
