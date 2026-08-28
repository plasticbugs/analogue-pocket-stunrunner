#!/bin/sh
# ADSP-2100 trace bench: run the RTL over MAME instruction traces and diff.
#
#   sim/run_adsp.sh [window_dir ...]
#
# Each window directory holds the files produced by tools/trace_adsp.lua
# (adsp_start.txt, adsp_trace[_pc].txt, adsp_io.txt, adsp_end.txt, ...).
# With no arguments, every artifacts/adsp/w* directory is run.
# Prints PASS/FAIL per window and exits non-zero on any failure.
set -e
cd "$(dirname "$0")/.."
OBJ=sim/adsp/obj_dir
mkdir -p "$OBJ"
verilator --cc --exe --build -O2 -Wall -Wno-fatal --top-module tb_adsp_top \
    -Mdir "$OBJ" sim/waivers.vlt rtl/adsp/adsp2100.sv sim/adsp/tb_adsp_top.sv sim/adsp/tb_adsp.cpp \
    -o tb_adsp > "$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log"; exit 1; }

if [ $# -eq 0 ]; then set -- artifacts/adsp/w*; fi
fail=0
for w in "$@"; do
    [ -f "$w/adsp_trace.txt" ] || { echo "$w: no trace"; continue; }
    echo "== $w"
    if "$OBJ/tb_adsp" "$w" ${CEN_PERIOD:-12} ${MAX_MIS:-20} 2>"$w/bench.log"; then
        tail -1 "$w/bench.log"
    else
        fail=1; tail -20 "$w/bench.log"
    fi
done
[ $fail -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
