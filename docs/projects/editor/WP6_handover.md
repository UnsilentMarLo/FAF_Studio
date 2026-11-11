# WP6 hand-over (water bodies, shore waves)

Engine: branch `port/wp6-water` (worktree C:\Users\Marlo\Documents\GitHub\faf-re-port-wp6), commit d3b4279f5 on `port/wp3-exact-save`. Not pushed. Lua / docs: FAF_Studio commits (see git log: "water bodies and shore waves ... (WP6)"). Full description, checks, limits: `docs/projects/editor/WP6_WATER.md`; shore note: `WATER_SHORE.md`.

- Natives `src/moho/editor/EdUpWaterLua.cpp`: ed_waterbodies_{fill,clear,info,crosscheck,simfix}, ed_water_texel, ed_waves_{get,set,read,write,patterns,generate}. `editor/doc/EdWaterBodies.cpp` is compiled in the exe (editor_sources.cmake).
- Engine edit: `CWldTerrainRes.cpp` (hi-res water map follows bodies; Save writes the sea's water map). Nothing sim-linked changed.
- Lua: water.lua, gui/panels_waterbodies.lua, gui/feature_water.lua, tool `waterbody` (ui.lua), control.lua Start, tips, selftest_waterbodies.lua, scripts/ed_waterbodies_check.py.
- `.scmwtr` is WP2's; this branch is not merged with WP2, WP5 or WP7.
- Traps: a lake below the sea is a hole in the sea (not a shore); the game needs sim_FixWaterBodies (water.lua sets it); instance Lua modules are cached: restart the instance after editing Lua; `Build()` stubs WP5's ed_adaptive_tables_path when missing.
- Open: Play with bodies not run; no before/after sim checksum (see WP6_WATER.md); bounds are sliders only.
