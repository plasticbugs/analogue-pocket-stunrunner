# Vendored modules

These directories are third-party HDL cores vendored into the tree (no
submodules — the whole point is a self-contained, reproducible build). Each
was copied from its upstream repository at the commit below; their own
LICENSE files are kept alongside the sources.

| module | upstream | commit |
|---|---|---|
| cpu-tg68k | https://github.com/TobiFlex/TG68K.C | ade33e396a1e647c2de9daf71ff9d5b3979639b2 |
| cpu-t65 (from punchout) | https://github.com/mist-devel/T65 (via plasticbugs/punchout) | vendored |
| sound-jt51 | https://github.com/jotego/jt51 | 985a573dcfc1ff135553a39f7eae21d18ba57cbe |
| sound-jt6295 | https://github.com/jotego/jt6295 | 7d76b0be8cd8f85f3ae741178c9830b20e2071a1 |

To update one: re-copy from upstream at the new commit (do not add it as a
submodule) and record the commit here.

## The Analogizer adapter module

| module | upstream | commit | licence |
|---|---|---|---|
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim; `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket, `src/fpga/analogizer/` | 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f | GPL-3.0-or-later; `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

Copied through plasticbugs' pocket-core-template (d9503cc), with the template's
wrapper `target/pocket/pocket_analogizer.sv`.  It lives under `target/pocket/`
rather than `modules/` because it is the Pocket's cartridge port, not the
machine: `core.qip` includes its own `analogizer.qip`, and `sim/lint.sh` lints
it behind the wrapper with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  `docs/analogizer.md` has the rest.

**Local change (not upstream).** `openFPGA_Pocket_Analogizer.v` gains two
parameters, `USE_YC` and `USE_SD`, default 1.  0 leaves out the Y/C encoder
(`yc_out_legacy`), or the scandoubler (`scandoubler_2`, with `Hq2x`) and the
VGA scanlines (`scanlines_analogizer`), with their outputs tied to the
pass-through values and their video modes mapped to RGBS.  Why: S.T.U.N.
Runner fills 90 % of the FPGA, and with the whole module it needed 102 %.
The change adds the parameters, three generate blocks and one selector
line, each marked `LOCAL`, and a note under RndMnkIII's header, which is
otherwise untouched; with both parameters at 1 the module is the upstream
1.4 exactly.  `core_top.sv` sets both to 0 through `pocket_analogizer.sv`.
A re-copy from upstream must carry the change over.
