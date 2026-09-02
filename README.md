# S.T.U.N. Runner for Analogue Pocket

An openFPGA core for **S.T.U.N. Runner** (Atari Games, 1989), reimplementing
the Hard Drivin' "multisync" hardware the game runs on: a 68010 main board, a
TMS34010 graphics processor drawing polygons into a 512 KB frame buffer, an
ADSP-2100 DSP doing the 3D maths, and the JSA II sound board (6502, YM2151,
OKI6295). All of it is gateware; nothing is emulated in software.

> **ROMs are not included and never will be.** You supply your own MAME
> `stunrun` romset; the core reads one image built from it.

## Status

Work in progress; nothing has run on a Pocket yet. Verified against MAME so
far (details and numbers in `docs/verification.md`):

* reference frame renderer and the RTL scan-out path: pixel-identical on 7
  frozen states (attract and gameplay)
* 68010 board: 43,000 instructions from reset match MAME's trace, within 2 %
  of real-time
* JSA II sound board: YM2151 register stream identical over 40 s, audio
  envelope within 0.01 dB
* SDRAM controller: randomised multi-client bench, zero errors

In progress: the TMS34010 and ADSP-2100 cores (trace-verified against MAME),
whole-machine simulation, first Quartus build.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card.
2. Build the ROM image and copy it to `Assets/stunrun/common/stunrun.rom`:

   ```sh
   python3 mra_build.py stunrun.mra stunrun.zip
   ```

   Nothing but Python 3 is needed. It checks every ROM's CRC32 and verifies the
   finished 1,511,424-byte image against a known md5.

## Controls

| Pocket | Arcade |
|---|---|
| D-pad / left stick | flight stick (steer, pitch) |
| A, X or R | fire |
| B, Y or L | boost |
| Select | coin |
| Start | start |

Settings and high scores (the board's timekeeper NVRAM and EEPROM) are saved
to `Saves/stunrun/plasticbugs.stunrun/stunrun.sav`. The very first boot with
no save file takes about seven seconds longer than usual: the game
initialises its EEPROM records byte by byte, exactly as the real board (and
MAME with a fresh NVRAM directory) does.

## Repository layout

| Path | What |
|---|---|
| `docs/hardware.md` | the machine, from MAME's driver and Lua probes — read first |
| `docs/rtl-conventions.md` | clocks, memory interface, block interfaces |
| `rtl/` | the core: `stunrun_core.sv` (machine), `stunrun_main.sv` (68010 board), `gsp_*.sv` (video glue/scan-out), `sdram_ctrl.sv`, `gsp/` (TMS34010), `adsp/` (ADSP-2100), `jsa/` (sound board) |
| `modules/` | reused cores: TG68K.C (68010), T65 (6502), jt51 (YM2151), jt6295 (OKI) — the VHDL ones converted to Verilog with GHDL (`tools/gen_vhdl_cores.sh`) |
| `sim/` | Verilator benches: `run_sdram.sh`, `run_gsp.sh`, `run_adsp.sh`, `run_jsa.sh`, `run_system.sh`, `lint.sh` |
| `tools/` | `mra_build.py` (ROM image), `render_model.py` (reference frame renderer), MAME Lua probes (`dumpstate.lua`, `trace_*.lua`) |
| `target/pocket/`, `platform/pocket/`, `projects/`, `pkg/pocket/` | Analogue Pocket integration, Quartus project, core package |
| `artifacts/` | scratch outputs (MAME snapshots, state dumps, traces, diffs); gitignored |

## Building

```sh
./build-local.sh map      # quartus_map only, ~2 min: catches syntax/inference errors
./build-local.sh          # full compile in Docker (raetro/quartus:pocket) + package
./sim/lint.sh             # Verilator lint of everything that synthesises
```

CI (`.github/workflows/compile.yml`) lints, compiles, checks timing closure
and block-RAM fit, and publishes the SD-card package.

## Credits

The S.T.U.N. Runner-specific RTL and verification harness are original; the
rest of the core is built on other people's work.

**Platform & toolchain**

* the **Analogue Pocket** openFPGA framework (APF) itself — Analogue
  Enterprises Limited, `platform/pocket/bsp/pocket/apf_top.sv`,
  `platform/pocket/peripherals/io_pad_controller.sv` and related files
* **boogermann (Marcus Andrade)** / OpenGateware — the Pocket integration
  framework the rest of `platform/pocket/` (pad, audio, save/hiscore, video
  and memory glue) is built from, and the `raetro/quartus:pocket` Docker
  image `build-local.sh` and CI compile with; the hiscore/NVRAM autosave
  support carries earlier copyright from Alan Steremberg and Jim Gregory
* **GHDL** — converts the vendored VHDL CPU cores to Verilog
  (`tools/gen_vhdl_cores.sh`) so one source feeds both Quartus and Verilator
* **Verilator** — every simulation bench in `sim/`

**Vendored cores** (`modules/`, see `modules/VENDOR.md`)

* **TG68K.C**, the 68000/68010 core, by Tobias Gubener — `modules/cpu-tg68k`
* **T65**, the 6502 core from FPGAARCADE (Daniel Wallner, Mike Johnson,
  Wolfgang Scherr and other contributors), by way of `plasticbugs/punchout`
  — `modules/cpu-t65`
* **JT51** (YM2151) and **JT6295** (OKI MSM6295), by Jose Tejada (jotego) —
  `modules/sound-jt51`, `modules/sound-jt6295`
* the SDRAM controller's pin-level timing — CL2, read data captured at
  READ+4, proven on the Pocket at 96 MHz — is carried over from the
  Punch-Out!! core's `sdram16.sv` (`rtl/sdram_ctrl.sv`)

**Reference & verification**

* **MAME** — the `harddriv` driver, and its TMS34010 and ADSP-2100 CPU
  cores, are the behavioural reference the GSP and ADSP RTL (`rtl/gsp/`,
  `rtl/adsp/`) were written from and verified against instruction by
  instruction (`docs/gsp.md`, `docs/adsp.md`, `docs/verification.md`,
  `METHODOLOGY.md`)
* **Ghidra** — disassembled the 68010 boot program for
  `docs/boot-sequence.md`
