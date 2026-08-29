#!/bin/sh
# JSA II sound board against MAME.
#
#   sim/run_jsa.sh [seconds]        default 30 s of machine time
#
# Needs artifacts/jsa/main/{events.txt,mame.wav} from tools/trace_jsa.lua
# (run automatically here if missing, ~1 min) and the stunrun romset in
# stunrun/. Builds the Verilator bench, replays the 68k command stream into
# the RTL, then tools/compare_audio.py holds the RTL to MAME: the YM2151
# register-write sequence must be identical and the audio envelope must match.
set -e
cd "$(dirname "$0")/.."
SECS=${1:-30}
ROM=${ROMSET:-stunrun}
OUT=artifacts/jsa
mkdir -p "$OUT/main" build/jsa build/cfg_m

if [ ! -f "$OUT/main/events.txt" ] || [ ! -f "$OUT/main/mame.wav" ]; then
    echo "--- capturing MAME reference (events + audio) ---"
    TAPS=all FRAMES=3000 OUT="$OUT/main" mame stunrun -rompath "$PWD/$ROM" -video none -sound none \
        -nothrottle -skip_gameinfo -cfg_directory build/cfg_m -nvram_directory build/cfg_m \
        -wavwrite "$OUT/main/mame.wav" -autoboot_script tools/trace_jsa.lua > "$OUT/main/log.txt" 2>&1
fi

# ROM images the bench loads
python3 - "$ROM" build/jsa <<'EOF'
import sys, os
rom, out = sys.argv[1:3]
open(os.path.join(out, 'jsa.bin'), 'wb').write(open(os.path.join(rom, '136070-2123.10c'), 'rb').read())
oki = b''.join(open(os.path.join(rom, n), 'rb').read() for n in ('136070-2124.1fh', '136070-2125.1ef', '136070-2126.1de', '136070-2127.1cd'))
open(os.path.join(out, 'oki.bin'), 'wb').write(oki)
EOF

echo "--- building bench ---"
# jt51.f is upstream's file list and ends with ../ver/common/sep32{,_cnt}.v.
# Those are debug-only helpers, instantiated solely under `ifdef JT51_DEBUG +
# `ifdef SIMULATION (jt51_eg.v), and only modules/sound-jt51/hdl is vendored --
# so they do not exist here and neither Quartus nor this bench needs them.
# Drop any ../ver/ entry rather than carrying dead files into the build.
JT51=$(grep -v '^\.\./ver/' modules/sound-jt51/hdl/jt51.f | sed 's#^#modules/sound-jt51/hdl/#' | tr '\n' ' ')
JT6295="modules/sound-jt6295/hdl/jt6295.v modules/sound-jt6295/hdl/jt6295_adpcm.v modules/sound-jt6295/hdl/jt6295_timing.v \
        modules/sound-jt6295/hdl/jt6295_acc.v modules/sound-jt6295/hdl/jt6295_ctrl.v modules/sound-jt6295/hdl/jt6295_rom.v \
        modules/sound-jt6295/hdl/jt6295_serial.v modules/sound-jt6295/hdl/jt6295_sh_rst.v"
verilator --cc --exe --build -O2 -j 4 --Mdir build/jsa/obj +1364-2005ext+v -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
    --top-module tb_jsa_top -Imodules/sound-jt6295/hdl \
    modules/cpu-t65/gen/t65.v $JT51 $JT6295 rtl/jsa/jsa2.sv sim/jsa/tb_jsa_top.sv sim/jsa/tb_jsa.cpp \
    -o tb_jsa > build/jsa/build.log 2>&1 || { tail -30 build/jsa/build.log; exit 1; }

echo "--- running $SECS s of machine time ---"
build/jsa/obj/tb_jsa build/jsa/jsa.bin build/jsa/oki.bin "$OUT/main/events.txt" "$SECS" "$OUT"

echo "--- comparing with MAME ---"
python3 tools/compare_audio.py "$OUT/rtl.wav" "$OUT/main/mame.wav" "$OUT/rtl_events.txt" "$OUT/main/events.txt" "$SECS"
