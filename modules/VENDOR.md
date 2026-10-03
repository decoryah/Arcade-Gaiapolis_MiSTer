# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-tg68k | https://github.com/TobiFlex/TG68K.C @ ade33e396a1e647c2de9daf71ff9d5b3979639b2 | plasticbugs/analogue-pocket-stunrunner (ghdl-converted `gen/tg68k.v`) | LGPL-3.0 (the .vhd headers; "change GPL to LGPL", 04.04.2017) |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80) | plasticbugs/punchout, with its `tv80s_cen.v` clock-enable wrapper | MIT |

Not vendored, and why: jotego's `jt539` (K054539) is referenced by jtcores as a
submodule but the repository is not public (404), so the K054539 is written
here from MAME's `k054539.cpp`. See docs/prior-art.md in the Pocket repository (plasticbugs/analogue-pocket-gaiapolis).

To update one: re-copy from upstream at the new commit and record it here.
