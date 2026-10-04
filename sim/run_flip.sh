#!/bin/sh
# Flip Screen gate: target/mister/flip_buf.sv behind ddr_arb and a behavioural DDR3, a synthetic raster, the
# rotate writes and a random memory client as competing traffic; every visible pixel of every frame checked.
#   sim/run_flip.sh [frames, default 40]
# Environment: LAT=n (DDR3 read latency, default 24), BUSY=pct (DDR3 BUSY share, default 20), CLRATE=n (the memory
# client starts an operation on 1 of 2^n idle clocks, default 9), FLIP=0 (never switch flip on: the traffic
# baseline), JOBS=n
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT \
    -GLAT=${LAT:-24} -GBUSY_PCT=${BUSY:-20} -GFRAMES=${1:-40} -GCL_MASK=${CLRATE:-9} -GFLIP_ON=${FLIP:-1} \
    --top-module tb_flip_top -Mdir obj_flip \
    ../target/mister/flip_buf.sv ../target/mister/ddr_arb.sv ddr_model.sv tb_flip_top.sv tb_flip.cpp > obj_flip.log 2>&1 || { tail -40 obj_flip.log; exit 1; }
grep -E "%Warning.*(flip_buf|ddr_arb)" obj_flip.log || true
./obj_flip/Vtb_flip_top
