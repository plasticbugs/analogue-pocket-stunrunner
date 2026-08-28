#!/bin/sh
# 68010 board bench: TG68K on the real ROM vs a MAME trace from reset.
#   sim/run_main.sh [max_instructions]
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j 8 -O2 --trace -Wno-fatal -Wno-DECLFILENAME -Wno-UNOPTFLAT waivers.vlt \
    --top-module tb_main_top -Mdir obj_main \
    ../rtl/stunrun_main.sv ../rtl/sdram_ctrl.sv ../rtl/dpram_be.sv ../modules/cpu-tg68k/gen/tg68k.v \
    sdram_model.sv tb_main_top.sv tb_main.cpp > obj_main.log 2>&1 || { tail -40 obj_main.log; exit 1; }
./obj_main/Vtb_main_top ../pkg/pocket/Assets/stunrun/common/stunrun.rom ../artifacts/traces/m68k_boot.txt ${1:-200000}
