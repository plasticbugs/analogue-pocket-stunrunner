#!/bin/sh
# Convert the VHDL CPU cores (TG68K 68010, T65 6502) to Verilog with GHDL so a
# single source feeds both Quartus and Verilator. Run from the repo root.
set -e
W=$(mktemp -d)
M=modules/cpu-tg68k
(cd $W && ghdl -a --std=08 -fsynopsys -frelaxed "$OLDPWD/$M/TG68K_Pack.vhd" "$OLDPWD/$M/TG68K_ALU.vhd" "$OLDPWD/$M/TG68KdotC_Kernel.vhd" \
  && ghdl synth --std=08 -fsynopsys -frelaxed --latches --out=verilog TG68KdotC_Kernel > "$OLDPWD/$M/gen/tg68k.v")
T=modules/cpu-t65
mkdir -p $T/gen
(cd $W && ghdl -a --std=08 -fsynopsys -frelaxed "$OLDPWD/$T/T65_Pack.vhd" "$OLDPWD/$T/T65_MCode.vhd" "$OLDPWD/$T/T65_ALU.vhd" "$OLDPWD/$T/T65.vhd" \
  && ghdl synth --std=08 -fsynopsys -frelaxed --latches --out=verilog T65 > "$OLDPWD/$T/gen/t65.v")
rm -rf $W
wc -l $M/gen/tg68k.v $T/gen/t65.v
