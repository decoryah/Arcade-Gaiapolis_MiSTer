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

### Fast load (the MRA's `address=` attribute)

With `address="0x32000000"` on the index-0 `<rom>`, a recent Main_MiSTer copies the whole assembled image into the DDR3 at that
byte address in one `memcpy`, bracketed by a download that has no data bytes: it starts with `ioctl_addr` = the image's length
(an ordinary download starts at 0, which is how `Gaiapolis.sv` tells them apart: `fast_dl`) and ends with it. The core
stays in reset from the start until `gaia_mem` has pushed the whole image through the loader (`fl_done`). `gaia_mem` reads the
image back in 256-byte blocks (a 32-beat burst through the arbiter's client port, `ddr_arb.sv` `c_*`, into a 32 x 64-bit
buffer), swaps each little-endian halfword to the image's big-endian word and pushes it into the loader's FIFO, as long as the
FIFO has room; the dispatcher behind it is unchanged, so the layout is the one above. The memory test (`mem_test.sv`) sums the
bytes of the image as they stream in, so the replay hands it the same bytes (high, then low, one word every three clocks) and
its sums are those of the image.

The client port is shared with the machine's own ROZ reads and with the loader's writes of the ROZ characters and map, so the
block read is a state of the DDR3 client's own state machine (`D_FL`, issued from `D_IDLE` between two loader writes, which
wait while the burst comes back) rather than a second driver of the port; the block reader (`F_*`) only asks for it
(`fl_rd_req` / `fl_rd_ack`) and starts the first block when no beat of an earlier read is still owed (`fowed`). The core is in
reset throughout, so nothing else asks for the port. Nothing else of the DDR3 is touched: the window's offset 0x400000 beats
(byte 0x32000000, `FL_BASE`) up to 0x66C000 is clear of the ROZ memories (0 to 0x50000), of the Flip Screen buffers (0x80000
to 0xA0000 beats) and of the framework's rotated frame buffer (outside the client's window). The loader accepts about a word
per ten clocks, so the 10.2 million words take about a second; that, not the DDR3, is the limit. `sim/emu/run_emu.sh` with
`FAST=1` models the HPS side.

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

## CRT Adjust

rmonic79's `crt_adjust` (`modules/crt-adjust/crt_adjust.sv`, GPL-3.0 or later; see `modules/VENDOR.md` for the
one-line sign fix) sits between the Flip Screen stage and `arcade_video`, in `Gaiapolis.sv`. It writes each
line into a ping-pong line buffer at the pixel enable and reads the previous line out at its own enable
(`crt_tick`: one pixel every 48 + H-Size quarters of a clock, restarted on the module's line reference
`hs_ref_out`); H-Position moves the read window (HPOS_CONTENTSHIFT, so the hsync stays native), V-Shift delays the
vsync through a per-line shift register. Cost: three M10K blocks for the 1,024 x 24 line buffer and about 100 ALMs.
Off, `arcade_video` gets the signals it always got (a static mux on `crt_on`); on, it gets the module's, with
`ce_pix` = the read enable. It is gated off while the scandoubler is in use (`Scandoubler Fx` or
`forced_scandoubler`): the scandoubler measures the pixel period and assumes it is constant per line.

What the raster of this core needed in the glue, all found by measuring the real top level in
`sim/emu/run_emu.sh` (the bench reports the rows with picture, where they start after the hsync pulse and how wide
they are, and the clocks from the vsync pulse to the first row):

* **The vertical blank is passed one line ahead.** The module's line starts at the hsync *rise*, which in this
  raster is 64 pixels before the line counter wraps (the picture is at pixels 40-415, the hsync at 444-491).
  It reads a line after it writes it, so the line it is emitting was written under the *previous* hsync rise,
  and it gates it with the vertical blank it sampled one rise earlier -- the blank of the line before. Passing
  the blank of the next line (`crt_vb_next`, from `dbg_vcount`) makes the gate the blank of the line being
  emitted; passing the raw blank loses the first and last row of the 224.
* **The vsync is delayed one line** (`crt_vs_t = 1 - V-Shift`), because the picture is emitted a line late
  against the native sync; with that, and `VBlank` held at 0 in front of `arcade_video` (the module's
  horizontal blank already carries the vertical gate), the first row comes the same number of clocks after
  the vsync pulse as without the module. A negative delay is counted from 264 lines, the length the module is
  built for; the board's frame is 263, so it is one line more negative with the board timing.
* **A one-pixel bias** (`CRT_HBIAS`): the picture comes out one pixel later than the unadjusted one at
  H-Position 0, and the bias cancels it. With it, CRT Adjust on at 0, 0, 0 reproduces the unadjusted output
  exactly: the same 224 rows, the same start (1,248 clocks after the hsync pulse) and width (4,512 clocks) for
  every row, the same first-row distance from the vsync, and a byte-identical picture, with the board's and with
  MAME's timing. The rotated frame buffer in DDR3 matches it pixel for pixel as before.
* **The picture is blanked while the output hsync is active.** A picture that runs past the end of its line
  (H-Size too large for its H-Position) used to leave a one-pixel blip of DE just after the next hsync rise;
  the HDMI scaler and `screen_rotate` would count it as a pixel.
* **The ranges are what the line holds.** The picture runs from 104 to 480 of the 508 pixels after the hsync
  rise, and the module reads at 48 + H-Size quarters per pixel, so the picture ends at
  (480 + H-Position) x (48 + H-Size) quarters, which must stay under 4 x 6,096 (4 x 6,144 for MAME's line).
  Without H-Position, H-Size +2 fits and +3 does not; at H-Position -48, +8 fits. Hence the menu's H-Size up to
  +8 and H-Position up to +28 (the room to the right at normal size).
* **One clock of delay in front of the select.** The first build with the module missed timing by 0.24 ns, on a path
  that has nothing to do with it: from the 68000's register file through the diagnostic overlay's address
  squares to the picture. The select between the module's output and the plain picture added a logic level to
  it. The picture's signals (`vq_*`) are now registered once before the select, which put the path back to its
  old depth (setup slack -0.24 ns became +0.09 ns) at the cost of one clock (10 ns) of video delay, with CRT
  Adjust on or off.
* **A negative H-Position blanked the picture in the module as published**: it chooses between
  `$signed(hoffset)` and an unsigned zero, which makes the result unsigned in Verilog, so -1 became 511 and the
  window moved out of the line. The line now sign-extends explicitly.

The vertical shift's direction was checked at the signal level: a positive V-Shift puts the first row more lines
after the vsync pulse, which is lower on a monitor. The horizontal and vertical amounts, the H-Size widths
(376 pixels of 8 to 14 clocks) and the limits above were each measured on the real top level, with the
picture's pixel count and content unchanged.

## The scandoubler needs the horizontal blank alone

`sys/scandoubler.v` (Scandoubler Fx, MiSTer.ini's `forced_scandoubler`) takes its line timing from the edges of
`HBlank`: `hb` falling starts a line (`hcnt`, `sd_hcnt`, `hde_start` and the sampling of `vb_in` hang on it),
and it shifts `vs_in` / `vb_in` through at those edges. It therefore expects `HBlank` to toggle on every line of
the frame, the vertical blank lines included, with `VBlank` separate. This core gave it `~de`, where `de` is
the visible *rectangle* (`in_active_x && in_active_y`): `HBlank` stayed high through the whole vertical blank,
the scandoubler's line counters, reset only on that falling edge, ran on through the blank lines, and its
doubled output had no hsync in them, no vsync and no vertical blank (measured by probing the mixer in
`sim/emu/run_sd.sh`: `vs_sd` and `vb_sd` constant 0, `hs_sd` pulsing only in the 448 picture lines of a frame). The 15 kHz path is unaffected, as
`arcade_video` without the scandoubler only uses the combined blank for `VGA_DE`. A user on a 1080p TATE
monitor reported sound and a frozen picture, with a "31.51 kHz" video info (the doubled lines), which is what
this produces.

`gaia_video.sv` now also outputs `hde` (the horizontal window, through the same pipeline as `de`), through
`gaia_core.sv`; `Gaiapolis.sv` gives `arcade_video` `HBlank = ~hde` and `VBlank = vblank` (registered with the
rest in `vq_*`). `VGA_DE` comes out the same rows as before (the video mixer ANDs the two) and the 15 kHz
output is unchanged (same geometry, byte-identical scaler picture in the whole-machine bench). The CRT Adjust
module and Flip Screen keep the combined blank (`hblank_c`), which is what they want; CRT Adjust is gated off
while the scandoubler is in use.

Measured with the scandoubler on (forced, or CRT 25 %): 526 lines (528 with MAME's timing), 448 picture rows of
376 pixels, line period 3,048 clocks (3,072), frame period exact, each source line twice in order; HQ2x 752
pixels a line. The whole top level with the forced scandoubler gives 448 rows and a vertical sync.

## Scale (integer scaling for the HDMI scaler)

The OSD's Scale item (`status[34:32]`: Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+) goes to the framework's
`video_freak` (`sys/video_freak.sv`, with `sys/math.sv`), which sits behind `arcade_video` and turns the aspect ratio plus
the picture's own size into `VIDEO_ARX` / `VIDEO_ARY`. With Normal they pass through (3:4 turned, 4:3 not, or the ARC entries);
with an integer mode they carry the exact size in pixels (bit 12 set) that the scaler is to give the picture: the picture's row
count times the largest whole factor that fits the scaler's height, and a width that is the aspect ratio's (V-Integer) or a
whole multiple of the 376-pixel row (the HV modes: Narrower is the multiple below the aspect width, HV-Integer+ the one above,
HV-Integer the nearer of the two). The menu's order is the user's; `video_freak`'s `SCALE` input counts 0 Normal, 1 V-Integer,
2 Narrower, 3 HV-Integer+, 4 HV-Integer, and `Gaiapolis.sv` maps one onto the other (`scale_sel`).

`video_freak` measures the stream it is given: 376 pixels, 224 rows (448 with the scandoubler), that is, the picture *before*
`screen_rotate` turns it. With Orientation Vert (the default) the scaler shows the rotated frame buffer, 224 x 376, and the
exact size `video_freak` would work out belongs to the other orientation. The core therefore keeps Scale at Normal then
(`scale_sel` is forced to 0 and the menu entry is hidden: `status_menumask` bit 2 is `~no_rotate`), and the aspect ratio passes
through as before. The integer modes act with Orientation Horz and in direct video (where the scaler is not in use at all, so
there is nothing to scale).

Full Screen (Aspect ratio ARX = ARY = 0) has no proportions for the integer rule to size the width from, and the rule then
sizes the height from the width and asks for more rows than the screen has. With an integer Scale the core therefore hands
`video_freak` the scaler's own size (`HDMI_WIDTH` x `HDMI_HEIGHT`) as the proportions (`fs_int`), so Full Screen is the largest
whole-number picture in the screen's aspect; with the scaler's size unknown (direct video) it passes through as before.

## Sound

The Pocket core's K054539 (`rtl/k054539.sv`) and its two-chip mix (`rtl/gaia_sound.sv`) were checked against
MAME 0.289 playing `gaiapols`: a 130-second attract run with every Z80 write to both chips logged, the same
writes replayed through the RTL chips, and the result compared with MAME's own wav (lag -76 samples) second
by second. The Pocket chip's median per-second correlation was 0.915 (31 of 68 sounding seconds below 0.9).
Changes, each to match MAME's `k054539.cpp`:

* a 16-bit sample steps `pdelta << 1`, two bytes, and fetches `pos` and `pos + 1` whatever the alignment (the
  chip forced an even address);
* `UPDATE_AT_KEYON` (MAME's default): while register 0x22f bit 0 is set, a write to a channel's 0x0c-0x0e is
  kept in a latch (`posl`) and the register is left alone; the key-on write copies the latched bytes in for each
  channel it starts (`ko_pend`, then a three-byte copy between samples); key-on and key-off are gated by bit 7
  of 0x22f;
* the reverb ring index is `rdelta + pos + pos` (MAME's `rdelta = (delay + pos) & 0x3fff`, then
  `rbase[(rdelta + pos) & 0x1fff]`); one add was 10 % off in the mid bands and 2x off above 12 kHz;
* the sum of the two chips saturates (`sat_add`) as MAME's mixer clips, rather than wrapping a loud overlap into a
  full-scale click of the opposite sign.

With these the median is 0.964 (one second below 0.9), bit-identical to the Monster Maulers core's chip (the
same chip, where the changes were worked out) and in agreement with a line-by-line C++ transcription of MAME's
chip. **The channel order is MAME's, not the Pocket core's**: `mystwarr.cpp` adds each chip's output 0 to the
right speaker ("stereo channels are inverted"), and `gaiapols` uses that machine config; the old order
(`l1 + l2` left, `r1 + r2` right) correlated 0.4-0.66 against MAME's audio, the swapped one 0.97. So
`snd_l = sat(r1 + r2)` and `snd_r = sat(l1 + l2)`. Audio Mono (`AUDIO_R = AUDIO_L`) is unchanged.

The whole-machine bench (110 frames) is silent that early, so these changes are covered at the chip level;
the whole machine with them boots and runs as before (every frame the board period, the picture and the frame
buffer as before).

## Verification

* `sim/emu/run_emu.sh` with `TIMING_MAME=0` or `1` checks the frame period in clocks on the
  real top level (1,603,248 for the board's raster, 1,622,016 for MAME's).
* `sim/emu/run_emu.sh` with `NOLOAD=1` and `CRT=1 HSIZE=.. HPOS=.. VSHIFT=..` (CRT Adjust, on the real top
  level): at 0, 0, 0 the picture's geometry and the scaler picture (byte for byte) are those of the run without
  CRT Adjust, with both timings; H-Position moves the rows by exactly that many pixels (-48..+28), H-Size makes
  every pixel 8 to 14 clocks, V-Shift moves the first row by exactly that many lines (both timings), and the
  picture is 376 x 224 and unchanged in every case that fits the line. Past the limits (H-Size +3 at
  H-Position 0, H-Size -16 with H-Position -48) the picture is cut at the line end or the hsync, and nothing
  appears inside the hsync pulse. With Flip Screen on as well the picture is still the overlay turned 180
  degrees. The rotated frame buffer matches the picture pixel for pixel with CRT Adjust on.
* `sim/emu/run_emu.sh` with `FAST=1` (the whole top level; the HPS side of the MRA's `address=` attribute is modelled: the
  image copied into the DDR3 model at byte 0x32000000, then a download with no bytes whose address is the image's length):
  the core comes out of reset on its own, replays the 10,158,080 words from the DDR3 in 70.3 million clocks (0.733 s at
  96 MHz; the bench's streamed load of the same image, an HPS as fast as the loader will take, needs 69.8 million: the loader's
  rate is the limit, so the replay is as fast as this loader goes), and the loader check -- every word of the image against where the ports read it, in the SDRAM chip's
  array and the DDR3 model's (the ROZ characters column-major) -- finds 0 wrong, as it does for the streamed load; frames,
  timing, the rotated frame buffer and the EEPROM read-back are those of a streamed load. With `PROBE=1` the memory test's
  seven running sums are compared with the image's region sums.
* `sim/run_mem.sh` also replays the whole image from the DDR3 model into `gaia_mem` (`fl_go` / `fl_len` / `fl_done`) with
  the ROZ regions of the DDR3 poisoned first, 20% `BUSY` and the frame buffer's write traffic running: every word where
  the ports read it (0 wrong of 10,158,080), the memory test's seven sums equal to the image's, 1,200 random port reads
  right, no DDR3 protocol error; and again after a download that starts 2 million clocks into the replay (the reader
  stops, waits for the beats still owed, and replays from the start): the same.
* `sim/emu/run_emu.sh` with `SCALE=` / `AR=` / `HW=` / `HH=` and `HORZ=1` or `DIRECT=1` (the whole top level, video path
  only): the size the core asks the scaler for (`VIDEO_ARX` / `VIDEO_ARY`) is compared with the framework's integer rule
  worked out in the bench from the picture's rows and width. Turned (Vert) with any Scale setting the core asks for the
  aspect ratio 3:4 as before and the rotated frame buffer matches the picture pixel for pixel with `video_freak` in the path.
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
  5CSEBA6U23I7: 49 % of the ALMs, 4.04 Mbit (71 %) of block RAM in 532 of the 553 blocks --
  nearly all of the blocks (the first build used 525; Flip Screen's line buffers and the deeper
  write FIFO took four; CRT Adjust's line buffer three more), so a core change that adds memory will need the caches or the
  line buffers looked at -- and 65 of 112 DSPs. Timing closes at 96 MHz in the slow 100 C
  model with every check positive: `gaiapolis_20261014` (fast loading and Scale) setup +0.11 ns, hold +0.24,
  recovery +1.31, removal +0.97 (HDMI clock; +1.31 on the core clock), HDMI clock setup +0.42
  (`releases/gaiapolis_20261014.sta.summary`, seed 1; seed 2 closed too: setup +0.18, hold +0.25, recovery +1.48);
  `gaiapolis_20261011` (the scandoubler fix) setup +0.36 ns, hold +0.16,
  recovery +1.59, removal +1.74 (`releases/gaiapolis_20261011.sta.summary`, seed 1; seed 2 missed, -0.24);
  `gaiapolis_20261010` (CRT Adjust and the sound fixes) setup +0.40 ns,
  hold +0.25, recovery +1.54, removal +1.65 (`releases/gaiapolis_20261010.sta.summary`, seed 1; seed 2 +0.39);
  `gaiapolis_20261008` (Video timing option) setup +0.19 ns,
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
