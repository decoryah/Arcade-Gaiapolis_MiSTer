#!/bin/sh
# Full-system simulation: the whole machine from reset with the real program.
#   sim/run_system.sh <gaiapolis.rom> [frames] [out-name]
# Writes artifacts/system/<name>.rgb, .png and .trace.
# Environment: JOBS=n (parallel C++ compile jobs, default 8), SNAPEVERY=n (a PNG every n frames), AUDIO=1 (write <name>.wav),
# MEM=mister (default: the MiSTer memory subsystem, target/mister/gaia_mem.sv + ddr_arb.sv, with a behavioural SDRAM and
# Avalon DDR3 in the loop) or MEM=ideal (one-clock ROM ports; LAT="+LAT_PROG=12 ..." sets their latencies),
# DDRLAT=n, DDRBUSY=pct (the DDR3 model's latency and BUSY share), OBJ=dir (build directory, for parallel builds),
# PACE="-GSTEP_COST_BUS=n -GSTEP_COST_INT=m" (68000 pacing overrides; add -GTIMING_MAME=1 for MAME's 512 x 264 raster
# instead of the board's 508 x 263, the default).
set -e
cd "$(dirname "$0")"
ROM="$1"; FRAMES="${2:-4}"; NAME="${3:-sys}"
[ -f "$ROM" ] || { echo "usage: $0 <gaiapolis.rom> [frames] [name]" >&2; exit 2; }
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac

case "${MEM:-mister}" in
    mister) TOP="--top-module tb_mister_top --prefix Vtb_system_top"; OBJ="${OBJ:-obj_mister}"
            SRC="../target/mister/gaia_mem.sv ../target/mister/rom_cache.sv ../target/mister/mem_test.sv ../target/mister/sdram_ctrl.sv ../target/mister/ddr_arb.sv sdram_model.sv ddr_model.sv tb_mister_top.sv"
            EXTRA="waivers_mister.vlt waivers_models.vlt -CFLAGS -DMISTER_TOP -GDDR_LAT=${DDRLAT:-24} -GDDR_BUSY_PCT=${DDRBUSY:-20}" ;;
    *)      TOP="--top-module tb_system_top"; SRC="tb_system_top.sv"; EXTRA=""; OBJ="${OBJ:-obj_system}" ;;
esac
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY \
    +1364-2005ext+v waivers.vlt $EXTRA $TOP -Mdir $OBJ ${PACE:-} \
    ../rtl/*.sv ../modules/cpu-tg68k/gen/tg68k.v ../modules/cpu-tv80/*.v $SRC tb_system.cpp \
    > $OBJ.log 2>&1 || { tail -40 $OBJ.log; exit 1; }

mkdir -p ../artifacts/system
case "${LAT:-}" in
    pocket) LATARGS="+LAT_PROG=12 +LAT_TILE=12 +LAT_MAP=12 +LAT_SPR=14 +LAT_BLK=14 +LAT_SROM=12 +LAT_PCM=10 +LAT_VRAM=5" ;;
    *)      LATARGS="${LAT:-}" ;;
esac
./$OBJ/Vtb_system_top "$ROM" "$FRAMES" ../artifacts/system/$NAME.rgb ../artifacts/system/$NAME.trace $LATARGS
# periodic frames (SNAPEVERY=n) become <name>.f<n>.png as well
for f in ../artifacts/system/$NAME.rgb.f*; do
    [ -f "$f" ] || continue
    python3 ../tools/rgb2png.py "$f" "${f%.rgb.f*}.f${f##*.f}.png" >/dev/null
done
python3 - <<PY
import sys, struct; sys.path.insert(0,'../tools')
import pngio
VIS_W,VIS_H=376,224
d=open('../artifacts/system/$NAME.rgb','rb').read(); buf=struct.unpack('<%dI'%(VIS_W*VIS_H), d)
w,h=VIS_H,VIS_W; out=bytearray(w*h*3)
for y in range(VIS_H):
    for x in range(VIS_W):
        v=buf[y*VIS_W+x]; o=(x*w+(VIS_H-1-y))*3
        out[o]=(v>>16)&0xff; out[o+1]=(v>>8)&0xff; out[o+2]=v&0xff
pngio.write('../artifacts/system/$NAME.png',w,h,out)
nz=sum(1 for v in buf if v)
print('wrote artifacts/system/$NAME.png  non-black pixels: %d (%.1f%%)'%(nz,100*nz/(VIS_W*VIS_H)))
PY
