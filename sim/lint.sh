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

# The Analogizer: the re-timer on its own, then the wrapper with the adapter's
# vendored module behind it and a stand-in for its one VHDL file.  The
# vendored files are kept as upstream wrote them, so their warnings are
# dropped by path -- their errors are not, but for one: hq2x.sv (MiSTer's)
# assigns its output wire in an always block, which Quartus takes and
# Verilator calls an error.  Unused signals and parameters are let through
# for the wrapper, as in the template: it takes the adapter's every output and
# the keyboard stand-in takes every input, used or not.
echo "--- ana_retime ---"
verilator --lint-only $FLAGS --top-module ana_retime target/pocket/ana_retime.sv
echo "--- analogizer ---"
A=target/pocket/analogizer
out=$(verilator --lint-only $FLAGS -Wno-PROCASSWIRE -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD --top-module pocket_analogizer \
      target/pocket/pocket_analogizer.sv platform/pocket/helpers/synch_3.sv \
      $A/*.v $A/*.sv sim/ps2_keyboard_stub.v 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
      | grep -v -E '^%Warning[^ ]*: [^ ]*(target/pocket/analogizer|platform/pocket)/' || true)
if [ -n "$out" ]; then echo "$out"; exit 1; fi
echo "lint clean"
