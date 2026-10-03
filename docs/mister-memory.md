# The MiSTer memory partition

The machine (`rtl/`) is the Pocket core's, unchanged: it sees seven ROM ports and a
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
  into, and which ignores `DDRAM_BUSY`. `ddr_arb.sv` queues those writes in a 32-deep
  FIFO and plays them out whenever the bus is free; the core's client holds its command
  until accepted, as the protocol says, and the arbiter never changes the selection
  while a command is presented and stalled.
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

## Verification

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
  5CSEBA6U23I7: 45 % of the ALMs, 3.99 Mbit (70 %) of block RAM in 525 of the 553 blocks --
  nearly all of the blocks, so a core change that adds memory will need the caches or the
  line buffers looked at -- and 65 of 112 DSPs. Timing closes at 96 MHz in the slow 100 C
  model with every check positive: setup +0.71 ns, hold +0.25, recovery +1.15, removal +1.73
  (`releases/gaiapolis_20261004.sta.summary`). Two things it took, both in the SDC and the top
  level: the framework's HQ2x pixel filter (`sys/hq2x.sv`, the OSD's Scandoubler Fx "HQ2x")
  is the worst path of a stock build, -0.57 ns, but every register in it updates on the pixel
  enable (one clock in twelve here), so `Gaiapolis.sdc` gives it a four-cycle multicycle; and the
  machine's reset is registered in `Gaiapolis.sv`, because the OR of its sources feeding the
  Z80's asynchronous reset through the whole core's fan-out missed recovery by 9 ps.
