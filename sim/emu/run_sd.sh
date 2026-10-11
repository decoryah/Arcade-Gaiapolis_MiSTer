#!/bin/sh
# What the framework's scandoubler (arcade_video) does with this core's raster, without the machine:
#   sim/emu/run_sd.sh [frames] [fx] [forced_scandoubler] [timing_mame]
set -e
cd "$(dirname "$0")"
S=../../sys; OBJ=obj_sd
mkdir -p $OBJ
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
verilator --cc --exe --build -j ${JOBS:-2} -O2 ${HONLY:+-GHONLY=$HONLY} ${PROBE:+--public-flat-rw -CFLAGS -DPROBE} -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE \
    +1364-2005ext+v -I. -I../.. ../waivers.vlt --top-module tb_sd_top --prefix Vtb_sd_top -Mdir $OBJ \
    ../../rtl/gaia_video.sv $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv \
    sync_fix.sv tb_sd_top.sv tb_sd.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -20; tail -5 $OBJ.log; exit 1; }
./$OBJ/Vtb_sd_top "${1:-6}" "${2:-0}" "${3:-0}" "${4:-0}"
