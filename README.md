# Gaiapolis for MiSTer

Konami's **Gaiapolis** (1993, GX123 "pre-GX" hardware) for the MiSTer FPGA platform.

This is a MiSTer platform layer around the Gaiapolis core that **plasticbugs** wrote for the
Analogue Pocket ([analogue-pocket-gaiapolis](https://github.com/plasticbugs/analogue-pocket-gaiapolis)):
the whole machine is theirs and is used here (`rtl/`) with one change, the raster timing option
described under "Video timing" below -- the 68000 and the Z80
sound board with its two K054539s, the ER5911 EEPROM, the K054000, and the video chain
(K056832 tilemaps, K053936 rotating plane, K053247 sprites, K055555 mixer), pixel-exact
against MAME in their verification. What is new here is everything around it: the memories,
clocks, video, audio, controls and ROM/NVRAM loading through the MiSTer framework
(`Gaiapolis.sv`, `target/mister/`, `rtl/pll*`, `mra/`).

No ROMs or other copyrighted data are in this repository; you supply your own MAME `gaiapols.zip`.

## Status

**Tested on a real MiSTer, and it works**, on a CRT screen and, in direct video, through a RetroTINK 4K.
Flip Screen (added in `gaiapolis_20261005.rbf`) and the Video timing option (`gaiapolis_20261008.rbf`)
have been tried on the board too, both timings.

Known issues:

* The open items inherited from the Pocket core (see "Differences from the Pocket core").

What was checked before the hardware tests, in simulation and in the Quartus tool flow:

* `sim/run_mem.sh`: the new memory subsystem against behavioural SDRAM and Avalon DDR3 models
  -- loader, every region through every port, caches, tile RAM, all ports under contention,
  built-in memory test. 0 errors. (details: `docs/mister-memory.md`)
* `sim/emu/run_emu.sh`: the real MiSTer top level (`Gaiapolis.sv`, with only `hps_io` and the PLL
  stubbed) with the full 20 MB image streamed in through the ioctl port, the EEPROM default after it,
  then the built-in memory test at full size and 260 frames of the machine running. All seven regions
  read back correct and stable, the tile RAM is ok, no render line overran, the DDR3 write queue never
  overflowed, the rotated frame buffer in DDR3 is exactly the picture turned a quarter clockwise (every
  pixel, over 25 million frame-buffer writes against a DDR3 model that pushes back), and the EEPROM reads
  back through the save path. (`sim/emu/decode_overlay.py` reads the overlay out of a captured frame.)
* `sim/run_flip.sh`: Flip Screen's frame buffers behind the DDR3 arbiter, against a DDR3 model with
  random `BUSY`, a synthetic raster, `screen_rotate`'s writes and a random memory client as competing
  traffic, with the option switched on and off at random points inside frames. Every visible pixel of
  every frame is checked (turned 180 degrees from the frame before, or unchanged), and so is every beat
  the client reads. 0 errors, at DDR3 latencies of 8 to 100 clocks and up to 50 % `BUSY`.
  `sim/emu/run_emu.sh` with `PROBE=1 FLIP=1 NOLOAD=1` checks the same on the real top level: the picture
  the scaler gets is exactly the overlay turned 180 degrees, a frame late, and the rotated frame buffer
  still matches it.
* `sim/run_system.sh`: the whole machine from reset with the real ROM set through that memory subsystem, 1,500
  frames. It boots through the self-test (the 68000's wait loop runs 19,287 iterations a frame where MAME's is
  19,314; the PCM checksum through both K054539s from the SDRAM completes at frame ~915 as in MAME's
  trace) into the game's intro -- sunset clouds, the bird sprite, "CREDIT 000" -- with the vblank handler
  running from frame ~1312, no render line overrun in any frame, no unsupported mode, and 25 s of
  non-silent audio. (That run was of the revision before the ROZ-map lookup was pipelined by one clock
  and the machine reset registered, both covered by `sim/run_mem.sh` and the end-to-end run, which use
  the final RTL. It has not yet reached the ROZ-heavy scenes, character select and the stages: those
  were checked against the DDR3 latency instead, in `docs/mister-memory.md`.)
* Quartus Prime Lite 17.0.2 (MiSTer's toolchain) compiles the project for the 5CSEBA6U23I7:
  45 % of the ALMs, 71 % of the block RAM (529 of 553 blocks, so there is almost none left), 65 DSPs, and
  timing closes at 96 MHz with every check positive (`gaiapolis_20261008`: setup +0.19 ns, hold +0.24,
  recovery +1.67, removal +1.56 in the slow 100 C model, `releases/gaiapolis_20261008.sta.summary`;
  `gaiapolis_20261005`: setup +0.26; the first build, `gaiapolis_20261004`: setup +0.71). A clean
  rebuild from the committed sources gives a slightly different fit that closes too (setup +0.12 ns
  when that was tried).

## Install

1. Download the newest RBF in `releases/` (`gaiapolis_20261008.rbf`, with Flip Screen and Video timing)
   and the three `.mra` files from `mra/` (or clone this repository). Put the RBF in
   `/media/fat/_Arcade/cores/` and the MRAs in `/media/fat/_Arcade/`. Keep the RBF's `gaiapolis_` name and date: MiSTer finds the core by the
   MRA's `<rbf>` name plus the date, and takes the newest if there are several. The earlier builds stay in
   `releases/` (`gaiapolis_20261004.rbf` is the first, without Flip Screen; `gaiapolis_20261005.rbf` adds
   Flip Screen and runs MAME's 59.19 Hz timing only).
2. Put your MAME 0.289 `gaiapols.zip` in `/media/fat/games/mame/` (the parent set; the Japan
   and USA versions' ROMs are in the merged set, or in `gaiapolsj.zip` / `gaiapolsu.zip` next to it).
   No ROMs are distributed here.
3. Start `Gaiapolis (World ver EAF)` from the Arcade menu. The ROM takes a few seconds to load.

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | Original is 3:4 when rotated (Vert) and 4:3 when not; ARC1 / ARC2 are the custom ratios from `MiSTer.ini` |
| Orientation | Vert, Horz | Not shown in direct video (see below). Vert: rotated for a monitor on its side (the frame buffer in DDR3, the framework's `screen_rotate`). Horz: the native raster |
| Rotation | CW, CCW | Not shown in direct video (see below). Which way Vert turns the picture, if your screen wants it the other way |
| Flip Screen | Off, On | The picture turned 180 degrees, on every output (analog, direct video, HDMI). Done on the finished picture through a frame buffer in the DDR3, so it adds one frame (16 ms) of delay while it is on and nothing when it is off. See below |
| Video timing | Board 59.88Hz, MAME 59.19Hz | The raster's size and sync widths. Board (the default) is what the board's K053252 timing chip produces from the values the game programs into it; MAME is MAME's fixed 512 x 264. See "Video timing" below. Takes effect at the next frame |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | |
| Test Mode | Off, On | The board's test switch: the game's service menu |
| Audio | Stereo, Mono | The board's mono/stereo input; Mono puts the left mix on both channels |
| Diagnostic overlay | Off, On | Three rows of 32 squares along the bottom of the picture, and the built-in memory test (a few seconds, black screen) after each ROM load |
| SDRAM read capture | Normal, Late | Late samples SDRAM reads one clock later, for a module that answers slowly; try it if the picture is garbage and the overlay shows the SDRAM regions red |
| Reset | | Restarts the machine (the ROM stays loaded) |

**Where Orientation and Rotation apply**, by output:

* **HDMI through MiSTer's scaler** (the default): the items are shown. Vert (the default) turns the picture
  for a monitor on its side, and Rotation picks the direction. (Not yet tried on hardware: the tester
  used direct video.)
* **Analog VGA / RGB (a CRT)**: the picture is the core's native raster, straight from the core, and the
  items change nothing there (a CRT on its side needs no rotation). With `vga_scaler=1` in `MiSTer.ini`
  the analog output comes through the scaler and follows the items like HDMI.
* **Direct video** (`direct_video=1`, e.g. a RetroTINK 4K in DV1 mode): the picture bypasses the scaler and
  its frame buffer, which is what does the rotating, so the core sends the raw unrotated raster and the two
  items are hidden. The device on the other end turns the picture, from the game direction MiSTer reports
  (the MRA's `<rotation>vertical (cw)</rotation>`).

Controls: joystick or gamepad for both players -- three buttons, Start and Coin each. On a gamepad
the default mapping is A / B / R for buttons 1 / 2 / 3, Start for Start and Select for Coin (remap it
in MiSTer's usual way). From the keyboard: 1 / 2 start, 5 / 6 coin and F2 for the test switch, on top
of MiSTer's usual keyboard-as-joystick. The game's own settings and high scores live in its EEPROM,
which MiSTer saves and restores.

**Flip Screen** is not the game's own flip setting. That setting only asks the video chips to flip, and
the Pocket core's renderers do not implement a global flip (it is on the list of unsupported modes in
`rtl/k056832_tilemap.sv`), so wiring the OSD option to it would leave the picture unchanged or
half flipped. Instead the finished picture is turned 180 degrees in `target/mister/flip_buf.sv`: each
frame is written to a frame buffer in the DDR3 and the next frame is shown from it, read backwards. The
controls are not flipped. Switching it on or off never shows half a frame: the first frame after
switching on is shown as it is, the second is the first flipped one. It is checked pixel for pixel in
simulation (`sim/run_flip.sh`, and `sim/emu/run_emu.sh` with `PROBE=1 FLIP=1 NOLOAD=1`).

**Video timing.** MAME runs this game on a fixed 512 x 264 raster (15.625 kHz, 59.1856 Hz) that ignores
the values the game writes into the K053252 timing chip. The board's chip produces something slightly
different, and the default here follows it:

* The schematic of the board (PWB353396A, Franck78's) shows the K053252's clock pin wired to the 32 MHz
  output of the oscillator module, and its three SEL pins tied to ground: it divides by 4, an 8 MHz
  pixel clock.
* The game programs a horizontal count of 0x1FB and a vertical count of 0x106 (and the porches and sync
  widths in the other registers) at boot. SiliconRE's model of the chip, traced from the silicon, turns
  those into 508 x 263 clocks: 15.748 kHz and **59.88 Hz**, with a 48-pixel hsync and an 8-line vsync
  (MAME's raster has 32 pixels and 3 lines).
* The visible 376 x 224 picture, its origin and everything the renderers see are the same in both. The
  game's logic is locked to the vertical interrupt, so on the board it runs about 1.2 % faster than in
  MAME; the sound, which has its own clocks, does not.

The option is read at the start of each frame, so it can be switched while playing. The part of this
that cannot be checked without the real board is the exact phase of the vertical interrupt inside the
chip's 386 x 225 active window; it stays at the end of the visible picture, as in MAME.

## Differences from the Pocket core

The core's ports are the same; what sits behind them is not, because MiSTer has no PSRAM or
SRAM. The programs moved to the SDRAM behind caches, the ROZ plane's memory to the DDR3, the
tile RAM to block RAM. The reasoning and the numbers are in `docs/mister-memory.md`.

Open items inherited from the Pocket core (its README): the ROZ plane's lead when the game
writes its registers late in vblank; a dozen frames of dropped tilemap lines at the start of
the intro after a new game on the Pocket's memories (the MiSTer SDRAM carries far less of
the line, so this should not occur here -- not yet measured on the board); two shadow
objects on one pixel; and the attract intro running longer than MAME's before the music.

## Repository layout

| Path | |
|---|---|
| `Gaiapolis.sv`, `Gaiapolis.q*`, `Gaiapolis.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `target/mister/` | the memory subsystem (`gaia_mem`, `rom_cache`, `ddr_arb`), SDRAM controller, memory test |
| `rtl/` | the Gaiapolis machine, the Pocket core's apart from the raster timing option in `gaia_video.sv` and `gaia_core.sv` (`rtl/data/` generated tables, `rtl/pll*` the clock PLL) |
| `modules/` | vendored TG68K.C and tv80 |
| `sys/` | the MiSTer framework (identical to Template_MiSTer) |
| `mra/` | the three MRAs, generated by `tools/make_mra.py` |
| `releases/` | the tested RBF, with its timing and fitter summaries |
| `sim/` | Verilator benches: memory subsystem, whole machine, and the MiSTer top level end to end |
| `docs/mister-memory.md` | the memory design: partition, caches, timing, latency sweep, build results |
| `tools/` | MRA generator and builder, PNG helpers for the benches |

## Building

Quartus Prime Lite 17.0.2 (the version MiSTer's framework is built with):

```
quartus_sh --flow compile Gaiapolis
```

`tools/make_mra.py gaiapols.zip` regenerates the MRAs.

The simulation benches need Verilator 5 and a C++ compiler, and a ROM image you build yourself from
your own romset with `tools/mra_build.py` (it checks every part's CRC and the image's md5):

```
python tools/mra_build.py "mra/Gaiapolis (World ver EAF).mra" gaiapols.zip gaiapols.rom   # 20,316,160 bytes
```

* `sim/emu/run_emu.sh gaiapols.rom gaiapols.nv [frames]` takes that image as is, plus the 128-byte
  `gaiapols.nv` from the romset (the EEPROM default).
* `sim/run_mem.sh <image>` and `sim/run_system.sh <image> [frames]` want the same image with
  the 128-byte `gaiapols.nv` appended (the Pocket layout, 20,316,288 bytes).

Run the benches from a Linux filesystem (WSL's own, not `/mnt/c`); the full-system bench simulates
at about a quarter of a MHz, so a thousand frames takes hours.

## Credits

* **plasticbugs** -- the Gaiapolis core for the Analogue Pocket (the machine, `rtl/`; the
  SDRAM controller `target/mister/sdram_ctrl.sv` and the memory test `mem_test.sv`, adapted;
  `tools/mra_build.py`), and through it the MAME team's work as the reference, **Tobias Gubener**'s
  TG68K.C (LGPL-3.0) and **Guy Hutchison**'s tv80 (MIT), vendored under `modules/`.
* **Claude** (Anthropic's AI model, used through Claude Code) -- the MiSTer layer, written together with the
  repository owner: the memory subsystem, video, audio and controls, the MRAs, the simulation benches
  and this documentation. The hardware testing is the owner's.
* **Sorgelig** and the MiSTer team -- the framework (`sys/`, GPL).
* **furrtek** (SiliconRE's K053252 model) and **Franck78** (the Gaiapolis board schematic) -- the sources for
  the board's video timing.
* **Jose Tejada (jotego)** -- JTFRAME's MiSTer SDRAM clock phase and read-capture timing, which this
  core's PLL and controller settings follow.

## Licence

GPL-3.0, as the Pocket core this is built on (see `LICENSE`). The vendored TG68K.C (LGPL-3.0) and
tv80 (MIT) in `modules/` keep their own licences (`modules/VENDOR.md`), and the MiSTer framework in `sys/`
is GPL (see the headers of its files).
