# The MiSTer memory partition

The machine (`rtl/`) is the Pocket core's (apart from the raster totals, below): it sees seven ROM ports and a
tile RAM port, all level request / one-cycle ack (`docs/hardware.md` section 11 of the
Pocket repository describes them, and the loads they carry). What differs is what sits
behind the ports, because the two boards have different memories.

| | Analogue Pocket | MiSTer (DE10-Nano + SDRAM module) |
|---|---|---|
| SDRAM | 32 MB, 16 bit | 32 MB (or more), 16 bit |
| PSRAM | 2 x 16 MB, async, 12-clock reads | none |
| SRAM | 256 KB, async | none |
| DDR3 | none | the HPS's 1 GB, 64 bit, shared with Linux and the scaler |
| block RAM | 3.1 Mbit | 5.6 Mbit |

## The partition

```
SDRAM   tiles         2 MB   2-word bursts                     K056832, line deadline
        sprites       8 MB   4-word bursts                     K053247, line deadline
        PCM           4 MB   single words                      two K054539s
        68000 program 3 MB   behind a 16 KB cache, 8-word line fills
        Z80 program 256 KB   behind a  4 KB cache, 8-word line fills
DDR3    ROZ characters 1.5 MB   64-word tile = 16 beats, buffered whole, streamed to the plane
        ROZ map       640 KB    3 beats per tile miss (prefetched together), 3 one-beat slots
block   K056832 tile RAM  64K x 16, byte enables               (the Pocket's SRAM)
RAM
```

Why this way round, from the Pocket's own measurements:

* The Pocket's SDRAM carried tiles (~2,100 clocks of each 6,144-clock raster line),
  sprites (~520), PCM (~160) and the ROZ plane's characters (1,400-3,200 on average, up
  to ~97 % of the line on the worst scenes), with the programs in PSRAM so that the
  68000's random accesses did not queue behind bursts. MiSTer has no PSRAM, so the
  programs have to come to the SDRAM; the ROZ plane goes the other way, to the DDR3,
  which is otherwise idle. The SDRAM then carries ~2,800 clocks a line plus the cache
  fills (about half the line), where the Pocket's carried up to ~6,000.
* The 68000 asks for a word every 24 clocks but fetches mostly in straight lines, so a
  small direct-mapped cache with 16-byte lines (`rom_cache.sv`) turns almost every
  access into a two-clock hit; a miss is one 8-word burst on the SDRAM's burst port.
  A fill that has waited 40 clocks (Z80: 120) goes ahead of the renderers' requests, so
  neither CPU can be starved by their back-to-back fetches. Over 40 frames of the boot
  the 68000 takes 70,114 steps a frame with the caches against 70,128 with ideal
  memories (`sim/run_system.sh`, `MEM=mister` against `MEM=ideal`).
* The DDR3 is reached through one Avalon-MM port (the framework's `DDRAM_*`) that the
  framework's `screen_rotate` also writes every pixel of the rotated frame buffer
  into, and which ignores `DDRAM_BUSY`. `ddr_arb.sv` queues those writes in a 64-deep
  FIFO and plays them out whenever the bus is free; the core's client holds its command
  until accepted, as the protocol says, and the arbiter never changes the selection
  while a command is presented and stalled. A third client, the Flip Screen buffer
  (below), writes through the same FIFO and reads with the lowest priority.
* A ROZ tile-cache miss costs three map reads (the colour nibble, then two attribute
  bytes, in three regions 128-384 KB apart) before the character block. All three
  derive from the first read's address, so on a miss in the first region the other two
  beats are fetched with it (three commands back to back, data in order); each region
  keeps its last beat for the next misses along the walk. That is one DDR3 latency a
  miss instead of three.
* The tile RAM was the Pocket's one external RAM (128 KB is too big for its FPGA). The
  MiSTer FPGA has the room: it is a plain block RAM behind the same port, two clocks
  from request to ack.

## The loader

The ROM image (`mra/*.mra`, 0x1360000 bytes, layout in the MRA header and `gaia_mem.sv`)
arrives from the HPS a byte at a time. `gaia_mem.sv` merges even/odd byte pairs into
words, queues them in a 64-entry FIFO (`dl_wait` holds the HPS off at 32), and a
dispatcher routes each word by address: SDRAM writes for the programs, tiles, PCM and
sprites, 64-bit DDR3 writes with byte enables for the ROZ characters (stored
column-major within each tile, the layout the plane's burst reads wants) and map. The
caches are swept on every download start. The default EEPROM is a separate download
(MRA index 2), and the same index is used to save and restore it (`<nvram>`).

## The SDRAM clock

The controller (`sdram_ctrl.sv`) is the Pocket core's. The Pocket clocked the chip in
phase and sampled read data four clocks after the READ command; on MiSTer the chip's
clock is a PLL output shifted half a period early (`rtl/pll/pll_0002.v`, -5078 ps: the
nearest legal value to JTFRAME's -4971 ps at 98.3 MHz, 175.5 degrees against its 175.9)
and the data is sampled three clocks after. Those two settings are the ones jotego's
MiSTer builds are tuned to. The OSD option "SDRAM read capture: Late" samples a clock
later, for a module whose chips answer slowly; it is the one thing to try first if the
picture is garbage or the self-test fails and every other region of the overlay is red.

## Flip Screen

The renderers have no global flip (`rtl/k056832_tilemap.sv` flags it unsupported, the
sprite and ROZ paths only wire their flip bits through), and there is no reference for
what the chips do when flipped, so the OSD option does not drive the game's own flip
input. `flip_buf.sv` turns the finished picture 180 degrees instead, between the
diagnostic overlay and `arcade_video`, so it applies to every output.

* The frame buffers are two regions of the DDR3 client window, at word offset 0x80000
  (above everything the core stores there): a word is two 24-bit pixels, a line 256 words
  (188 used), so the address is just {frame, line, word}. The visible pixels are
  written during the frame (one 64-bit word per two pixels, through `ddr_arb`'s write
  FIFO, held back for a clock where `screen_rotate` writes in the same one); at the next
  vertical sync the buffers swap.
* The next frame is shown from the other buffer: output line y is input line 223-y,
  pixels in the opposite order. Each line is read a line ahead, as three bursts (64, 64
  and 60 beats) into one of two line buffers in block RAM (512 x 64 bit), and played
  backwards, so the picture is the previous frame turned 180 degrees: one frame of delay
  while the option is on. The sync and blanking are the core's own and do not move.
* Whether a frame is flipped is decided at its start, from the option and whether the
  frame before it was written whole, so switching never shows half a frame. With the
  option off nothing is written or read and the output is the input.
* `ddr_arb.sv` gives the line reads the lowest priority: a read starts only with nothing
  else presented, the write FIFO empty (the two clocks the FIFO takes to load its next
  head used to let a 64-beat burst in between every queued write, and the FIFO filled)
  and no read data owed, and while it is in flight the core's client waits and the beats
  go to the flip reader only. The FIFO is 64 deep now (the same RAM blocks).
* `sim/run_flip.sh`: the module behind `ddr_arb` and the DDR3 model, a synthetic raster,
  `screen_rotate`'s writes and a random client as competing traffic, the option switched
  at random points inside frames. Every visible pixel of every frame is compared with the
  frame before it turned 180 degrees (or with the input, when not flipped); the client's
  read data is checked beat by beat; no line may start before its data is in. It passes
  at DDR3 latencies of 8-100 clocks with 0-50 % `BUSY` (the write FIFO peaks at 10-47 of 64;
  with the flip off a client that saturates the bus at 100 clocks and 50 % `BUSY` already
  overflows it, so that load is beyond the design anyway).

## Video timing

`gaia_video.sv` generates the raster the K053252 would. It has two sets of totals, chosen
by the OSD option (`timing_mame`, taken at the start of each frame):

| | board (default) | MAME |
|---|---|---|
| line | 508 pixels, 15.748 kHz | 512 pixels, 15.625 kHz |
| frame | 263 lines, 133,604 clocks, 59.88 Hz | 264 lines, 135,168 clocks, 59.1856 Hz |
| hsync | 48 pixels at 444 | 32 pixels at 448 |
| vsync | 8 lines at 255 | 3 lines at 248 |

The visible 376 x 224 picture and its origin (40, 16) are the same in both; the renderers see
only those. How the board numbers were found:

* The game writes the K053252's registers once at boot (`2002CA`-`200312` in the 68000
  program) and its frame-interrupt acknowledge (register 14) in the interrupt handler; it
  never reads the chip. The values: registers 0/1 = 0x01FB (H max), 2/3 = 0x0013, 4/5 = 0x0037,
  8/9 = 0x0106 (V max), 10 = 0x0F, 11 = 0x0E, 12 = 0x75 (VSW 8 lines, HSW 6 x 8 pixels).
* furrtek's SiliconRE Verilog model of the chip (https://github.com/furrtek/SiliconRE, `Konami/053252/hdl`, traced from the die) was run
  with those values at CLK/4. First it was run with Metamorphic Force's, and reproduced the
  numbers in SiliconRE's README exactly (384 x 264, 40-line vblank, 8-line vsync). For this game:
  508 x 263, hblank 122 pixels (18 front porch, 48 sync, 56 back porch), vblank 38 lines (15, 8,
  15), an active window of 386 x 225, and the frame interrupt (INT1) at the start of vblank.
* The board's schematic (Franck78, https://github.com/Franck78/The-Konami-Gaiapolis-schematic, PWB353396A) puts the K053252's CLK pin on the 32 MHz output
  of the oscillator module (the other output is 18.432 MHz) and ties SEL0-2 to ground: CLKSEL is
  CLK/4, internal syncs. So the pixel clock is 8 MHz and the frame 59.88 Hz.
* MAME 0.289 runs `gaiapols` at 376 x 224 and 59.1856 Hz regardless: its driver's raster is
  `set_raw(8 MHz, 512, ..., 264)`, which agrees with the chip's registers for Metamorphic Force
  (6 MHz, 384 x 264) but not for this game.

The chip's active window is a little larger than the picture (386 x 225 against 376 x 224); the
extra 10 pixels and line are shown black here, as MAME crops them. The vertical interrupt stays at
the end of the 224-line picture. The board numbers shorten the vertical blanking by a line and the
horizontal by 4 pixels in total; the renderers' budgets (6,096 clocks a line against 6,144) have
the room, and the overlay's overrun counter would show it if not.

## Verification

* `sim/emu/run_emu.sh` with `TIMING_MAME=0` or `1` checks the frame period in clocks on the
  real top level (1,603,248 for the board's raster, 1,622,016 for MAME's).
* `sim/run_mem.sh` -- the memory subsystem against a behavioural SDRAM and an Avalon DDR3
  model (latency, random `BUSY`, protocol checks) with the frame buffer's write traffic
  running: the real loader at one byte per 1-6 clocks, every region read back through
  every port, the caches under aliasing windows, the ROZ map's three-region access
  pattern, the tile RAM's byte lanes, all ports hammered together with random
  withdrawals, and the built-in memory test on a clean machine and with words corrupted
  behind the caches. 0 errors.
* `sim/run_system.sh` -- the whole machine from reset with the real program, through
  the MiSTer memory subsystem (see the status in the README for how far it has run).
* How slow can the DDR3 be? The Pocket repository's frame bench (`sim/run_frame.sh`, frozen
  game states, each renderer's worst line against the 6,144-clock budget, every frame
  diffed against the reference renderer) with the ROZ plane's two memories modelled as
  this partition makes them behave: a miss costs one DDR3 latency L for the map (the other
  two reads hit the prefetch: `LAT_MROM` = (L+6)/3 per read) and L plus the 16-beat burst
  for the block (`LAT_BLK` = L+16), then the 64 words stream at one a clock. On the heaviest ROZ states
  (character-select water at several angles, the emblem zoom, the stage backgrounds):
  L = 24 and L = 100 clocks (1 us, several times what the HPS's controller normally
  takes): no late line, at least 5 lines of lead in hand, all frames pixel-exact. Even
  L = 250 (2.6 us) is pixel-exact, with the lead down to 1-2 lines on the character
  select. The tilemap's worst line (3,340 clocks) and the sprites' (2,900) do not depend
  on it.
* Quartus Prime Lite 17.0.2 (MiSTer's toolchain) compiles the whole design for the
  5CSEBA6U23I7: 45 % of the ALMs, 4.01 Mbit (71 %) of block RAM in 529 of the 553 blocks --
  nearly all of the blocks (the first build used 525; Flip Screen's line buffers and the deeper
  write FIFO took four), so a core change that adds memory will need the caches or the
  line buffers looked at -- and 65 of 112 DSPs. Timing closes at 96 MHz in the slow 100 C
  model with every check positive: `gaiapolis_20261008` (Video timing option) setup +0.19 ns,
  hold +0.24, recovery +1.67, removal +1.56 (`releases/gaiapolis_20261008.sta.summary`);
  `gaiapolis_20261005` setup +0.26 ns, hold +0.25, recovery
  +1.25, removal +1.74 (`releases/gaiapolis_20261005.sta.summary`); the first build,
  `gaiapolis_20261004`, setup +0.71, hold +0.25, recovery +1.15, removal +1.73. A clean rebuild
  from the committed sources closes too (setup +0.12 ns). Two things it took, both in the SDC and
  the top level: the framework's HQ2x pixel filter (`sys/hq2x.sv`, the OSD's Scandoubler Fx "HQ2x")
  is the worst path of a stock build (-0.57 ns in the Blend; -0.11 on one placement of the Flip
  Screen build, in `cyc` to `nextpatt`), but every register of its datapath updates on one clock
  enable, `ce_in`, which the scandoubler places four times per pixel, evenly: three clocks apart
  for this core's 12-clock pixels (`sys/scandoubler.v`). `Gaiapolis.sdc` therefore gives that
  datapath a three-cycle multicycle. (The first build used four cycles on the Blend alone, one
  more than the enable spacing allows; re-checked under the three-cycle rule its fit is
  unchanged: same slacks, no violation.) And the machine's reset is registered in `Gaiapolis.sv`,
  because the OR of its sources feeding the Z80's asynchronous reset through the whole core's
  fan-out missed recovery by 9 ps.
