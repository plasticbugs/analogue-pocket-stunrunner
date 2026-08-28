#!/bin/sh
# Whole-machine bench. Builds with Verilator (~1-2 min) and runs the machine
# from power-on through the ROM download for N frames.
#   sim/run_system.sh [frames] [snap_every] [coin_frame] [start_frame] [zram.sav]
# With a .sav (tools/make_sav.py from MAME's nvram dir) the boot skips the game's
# factory EEPROM initialisation (~400 frames).
# Frames land in artifacts/sim/. Needs pkg/pocket/Assets/stunrun/common/stunrun.rom.
set -e
cd "$(dirname "$0")"
FRAMES=${1:-120}; SNAP=${2:-30}; COIN=${3:--1}; START=${4:--1}; SAV=${5:-}
mkdir -p ../artifacts/sim
RTL="$(ls ../rtl/*.sv ../rtl/gsp/*.sv ../rtl/adsp/*.sv ../rtl/jsa/*.sv)"
VENDOR="../modules/cpu-tg68k/gen/tg68k.v ../modules/cpu-t65/gen/t65.v $(ls ../modules/sound-jt51/hdl/*.v ../modules/sound-jt6295/hdl/*.v)"
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-DECLFILENAME -Wno-UNOPTFLAT +1364-2005ext+v waivers.vlt \
    -I../modules/sound-jt6295/hdl \
    --top-module tb_system_top -Mdir obj_system \
    $RTL $VENDOR sdram_model.sv tb_system_top.sv tb_system.cpp -LDFLAGS -lz > obj_system.log 2>&1 || { tail -40 obj_system.log; exit 1; }
./obj_system/Vtb_system_top ../pkg/pocket/Assets/stunrun/common/stunrun.rom $FRAMES $SNAP $COIN $START $SAV
