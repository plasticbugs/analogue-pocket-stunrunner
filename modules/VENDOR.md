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
