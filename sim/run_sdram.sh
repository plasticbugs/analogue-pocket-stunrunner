#!/bin/sh
# SDRAM controller bench: random multi-client traffic against a shadow memory.
#   sim/run_sdram.sh          2-clock burst spacing
#   sim/run_sdram.sh slow     5-clock burst spacing (the Punch-Out!! cadence)
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j 4 -Wno-fatal -Wno-DECLFILENAME waivers.vlt \
    --top-module tb_sdram_top -Mdir obj_sdram \
    ../rtl/sdram_ctrl.sv sdram_model.sv tb_sdram_top.sv tb_sdram.cpp > obj_sdram.log 2>&1 || { tail -30 obj_sdram.log; exit 1; }
./obj_sdram/Vtb_sdram_top "$@"
