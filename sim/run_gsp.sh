#!/bin/sh
# TMS34010 trace bench: build with Verilator and run every captured window.
#
#   sim/run_gsp.sh              all windows under artifacts/gsp (w*.trace)
#   sim/run_gsp.sh w2 [max]     one window, optional instruction cap
#
# sim/gsp/waivers_bench.vlt only waives MULTIDRIVEN for the wrapper's hierarchical
# state loads; the core itself lints clean with -Wall and sim/waivers.vlt.
#
# Each window needs <w>_start.regs/.vram, <w>.trace, <w>.host, <w>_end.vram
# from tools/trace_gsp.lua. Prints PASS/FAIL per window; exit code is non-zero
# on any failure.
set -e
cd "$(dirname "$0")/.."
OBJ=sim/gsp/obj_dir
verilator --cc --exe --build -O2 -Wall -Wno-DECLFILENAME sim/waivers.vlt sim/gsp/waivers_bench.vlt \
    --top-module tb_gsp_top -Mdir "$OBJ" \
    sim/gsp/tb_gsp_top.sv rtl/gsp/tms34010.sv rtl/gsp/gsp_icache.sv rtl/gsp/gsp_div.sv \
    sim/gsp/tb_gsp.cpp -o tb_gsp >"$OBJ.build.log" 2>&1 || { tail -30 "$OBJ.build.log"; exit 1; }

if [ -n "$1" ]; then
    WINDOWS="artifacts/gsp/$1"
else
    WINDOWS=$(ls artifacts/gsp/w*.trace 2>/dev/null | sed 's/\.trace$//')
fi
fail=0
for w in $WINDOWS; do
    echo "== $w"
    if "$OBJ/tb_gsp" "$w" ${2:-}; then :; else fail=1; fi
done
[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
