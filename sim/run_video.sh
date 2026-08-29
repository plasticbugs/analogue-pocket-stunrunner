#!/bin/sh
# Frozen-state video gate: every state in artifacts/states is pushed through
# the RTL scan-out (VRAM in the SDRAM model) and diffed against the reference
# renderer. Zero differing pixels on every state is the pass condition.
#   sim/run_video.sh [state-name ...]
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-DECLFILENAME waivers.vlt \
    --top-module tb_video_top -Mdir obj_video \
    ../rtl/gsp_video.sv ../rtl/sdpram.sv ../rtl/sdram_ctrl.sv sdram_model.sv tb_video_top.sv tb_video.cpp > obj_video.log 2>&1 || { tail -30 obj_video.log; exit 1; }
mkdir -p ../artifacts/diff
fail=0
if [ $# -gt 0 ]; then names="$@"; else names=$(cd ../artifacts/states && ls *.txt | sed 's/\.txt$//'); fi
for n in $names; do
    # artifacts/snap/$n.png is a MAME snapshot, the oracle for this state. States
    # captured from the RTL itself have no such snapshot and cannot be gated;
    # skip them explicitly rather than dying on a missing file.
    if [ ! -f ../artifacts/snap/$n.png ]; then
        echo "$n: SKIPPED (no MAME snapshot in artifacts/snap)"; skipped="$skipped $n"; continue
    fi
    ./obj_video/Vtb_video_top ../artifacts/states/$n.txt ../artifacts/states/$n.vram ../artifacts/diff/${n}_rtl.rgb > ../artifacts/diff/${n}_rtl.log || { echo "$n: bench failed"; fail=1; continue; }
    python3 ../tools/render_model.py ../artifacts/states/$n.txt ../artifacts/states/$n.vram ../artifacts/snap/$n.png ../artifacts/diff/$n > /dev/null || true
    python3 ../tools/diff_frames.py ../artifacts/diff/${n}_rtl.rgb ../artifacts/snap/$n.png ../artifacts/diff/${n}_rtldiff.png || fail=1
done
[ -n "$skipped" ] && echo "skipped (no oracle):$skipped"
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
