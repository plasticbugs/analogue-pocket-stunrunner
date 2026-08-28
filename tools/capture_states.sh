#!/bin/sh
# Regenerate the frozen MAME states and snapshots used by the reference
# renderer and the RTL benches. Needs the stunrun romset in ./stunrun (or set
# ROMPATH). Output: artifacts/states/f<frame>.{txt,vram} and artifacts/snap/f<frame>.png
set -e
cd "$(dirname "$0")/.."
ROMPATH=${ROMPATH:-.}
FRAMES=${FRAMES:-600,1000,1500,2400}
W=$(mktemp -d)
mkdir -p artifacts/states artifacts/snap "$W/cfg" "$W/nvram"
OUTDIR=artifacts/states FRAMES="$FRAMES" mame stunrun -rompath "$ROMPATH" -video none -sound none -nothrottle \
    -skip_gameinfo -cfg_directory "$W/cfg" -nvram_directory "$W/nvram" -snapshot_directory "$W/snap" \
    -autoboot_script tools/dumpstate.lua >/dev/null 2>&1
i=0
for f in $(echo "$FRAMES" | tr ',' ' '); do
    mv "$W/snap/stunrun/$(printf %04d $i).png" "artifacts/snap/f$(printf %05d $f).png"
    i=$((i+1))
done
rm -rf "$W"
for f in $(echo "$FRAMES" | tr ',' ' '); do
    n=$(printf %05d $f)
    python3 tools/render_model.py artifacts/states/f$n.txt artifacts/states/f$n.vram artifacts/snap/f$n.png artifacts/diff/f$n
done
