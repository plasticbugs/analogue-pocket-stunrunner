#!/bin/sh
# Lint every RTL file the core synthesises. Run before every push: it catches
# syntax and inference errors in seconds, where a broken push costs a whole
# CI cycle. The vendored/generated cores (TG68K, T65, jt51, jt6295) are waived
# by path in sim/waivers.vlt; nothing under rtl/ is waived wholesale.
set -e
cd "$(dirname "$0")/.."
verilator --version >/dev/null 2>&1 || { echo "verilator not found"; exit 2; }

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"
WANT="DECLFILENAME UNOPTFLAT PINCONNECTEMPTY PINMISSING GENUNNAMED"
FLAGS="-Wall -Irtl -Imodules/sound-jt6295/hdl +1364-2005ext+v sim/waivers.vlt"
for w in $WANT; do
    if verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1; then
        FLAGS="$FLAGS -Wno-$w"
    fi
done

RTL="$(ls rtl/*.sv rtl/gsp/*.sv rtl/adsp/*.sv rtl/jsa/*.sv 2>/dev/null)"
VENDOR="modules/cpu-tg68k/gen/tg68k.v modules/cpu-t65/gen/t65.v $(ls modules/sound-jt51/hdl/*.v modules/sound-jt6295/hdl/*.v)"

for top in sdram_ctrl gsp_video gsp_bus stunrun_main; do
    echo "--- $top ---"
    verilator --lint-only $FLAGS --top-module $top $RTL $VENDOR
done
echo "--- whole machine ---"
verilator --lint-only $FLAGS --top-module stunrun_core $RTL $VENDOR
echo "lint clean"
