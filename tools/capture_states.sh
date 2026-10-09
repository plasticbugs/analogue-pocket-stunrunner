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
# Headless: MAME must never take the display.  Its defaults are fullscreen,
# which on macOS moves the desktop to a new Space; SDL_VIDEODRIVER=dummy keeps
# SDL off the display, -videodriver dummy says so to MAME, and -window
# -nomaximize keeps any window that is made anyway small.  -seconds_to_run is
# the backstop if the script does not end the run: the last frame, at 60.2 Hz,
# and ten seconds more.
LAST=$(echo "$FRAMES" | tr ',' '\n' | sort -n | tail -1)
SDL_VIDEODRIVER=dummy OUTDIR=artifacts/states FRAMES="$FRAMES" mame stunrun -rompath "$ROMPATH" \
    -video none -videodriver dummy -window -nomaximize -sound none -nothrottle \
    -seconds_to_run $((LAST / 60 + 10)) \
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
