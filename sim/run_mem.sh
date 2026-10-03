#!/bin/sh
# MiSTer memory-subsystem gate: target/mister/gaia_mem.sv and ddr_arb.sv with a behavioural SDRAM and
# Avalon DDR3; samples of every ROM region through the download port and back through every core port,
# the program caches under aliasing, the ROZ map's access pattern, the tile RAM, every port under
# contention, and the built-in memory test.
#   sim/run_mem.sh <gaiapolis.rom> [load gap in clocks, default 6]
set -e
cd "$(dirname "$0")"
ROM="$1"; [ -f "$ROM" ] || { echo "usage: $0 <gaiapolis.rom>" >&2; exit 2; }
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT \
    waivers_mister.vlt waivers_models.vlt --top-module tb_mem_top -Mdir obj_mem \
    ../target/mister/gaia_mem.sv ../target/mister/rom_cache.sv ../target/mister/mem_test.sv ../target/mister/sdram_ctrl.sv ../target/mister/ddr_arb.sv \
    sdram_model.sv ddr_model.sv tb_mem_top.sv tb_mem.cpp > obj_mem.log 2>&1 || { tail -40 obj_mem.log; exit 1; }
./obj_mem/Vtb_mem_top "$ROM" ${2:-6} $3 $PLUS
