#!/bin/sh
# End-to-end bench of the MiSTer top level (Gaiapolis.sv): hps_io and the PLL stubbed, everything else real.
#   sim/emu/run_emu.sh <mister-layout image> <eeprom.nv> [frames after load, default 110] [out prefix] [diag]
# Environment: PROBE=1 (public signals; needed for the flip check), FLIP=1 (Flip Screen on from the start: the picture
# the scaler gets must be the overlay's picture turned 180 degrees, one frame late), NOLOAD=1
# The image is the first 0x1360000 bytes of the Pocket repository's gaiapols.rom (or tools/mra_build.py on a
# mra/*.mra); the EEPROM default is gaiapols.nv from the romset (128 bytes).
set -e
cd "$(dirname "$0")"
IMG="$1"; NV="$2"; FR="${3:-110}"; PRE="${4:-emu}"; DIAG="${5:-0}"
[ -f "$IMG" ] && [ -f "$NV" ] || { echo "usage: $0 <image> <eeprom.nv> [frames] [prefix] [diag]" >&2; exit 2; }
case "$IMG" in /*) ;; *) IMG="$PWD/$IMG" ;; esac
case "$NV" in /*) ;; *) NV="$PWD/$NV" ;; esac
S=../../sys
OBJ=obj_emu${PROBE:+_probe}      # PROBE=1: a build with the top level's signals public (tb_emu.cpp probes them)
mkdir -p $OBJ
# The framework's video_mixer.sv declares R_in/G_in/B_in inside an unnamed generate block and uses them
# outside it. Quartus accepts that (every MiSTer core builds with it); Verilator takes them for undeclared
# implicit wires nothing drives, and the picture comes out black. The bench builds a copy with the three
# wires declared at module level (for GAMMA=1, HALF_DEPTH=0 -- arcade_video with DW=24): sys/ is untouched.
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE \
    +1364-2005ext+v -DMISTER_FB=1 -I. -I../.. ../waivers.vlt ${PROBE:+--public-flat-rw -CFLAGS -DPROBE} \
    --top-module tb_emu_top --prefix Vtb_emu_top -Mdir $OBJ \
    ../../Gaiapolis.sv ../../rtl/*.sv ../../modules/cpu-tg68k/gen/tg68k.v ../../modules/cpu-tv80/*.v \
    ../../target/mister/gaia_mem.sv ../../target/mister/rom_cache.sv ../../target/mister/mem_test.sv ../../target/mister/sdram_ctrl.sv ../../target/mister/ddr_arb.sv ../../target/mister/flip_buf.sv \
    $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv \
    hps_io_stub.sv pll_stub.sv sync_fix.sv ../sdram_model.sv ../ddr_model.sv tb_emu_top.sv tb_emu.cpp \
    > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -30; tail -5 $OBJ.log; exit 1; }
# the core reads its tables with $readmemh relative to the project directory (as Quartus does)
cd ../..
./sim/emu/$OBJ/Vtb_emu_top "$IMG" "$NV" "$FR" "$PRE" "$DIAG" "${NOLOAD:-0}"
