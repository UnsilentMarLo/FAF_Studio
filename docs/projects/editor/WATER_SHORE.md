# Water shores (2026-10-25)

**Problem.** The shore of a lake was a staircase of 2 unit steps (seen on a lake drawn in the Layout workspace). It is not the heightmap: the engine draws the water surface where the *water map*
says so. `CWldTerrainRes::RebuildWaterMapRect` makes that texture with one texel per 2 x 2 cells; the blue channel is 255 when any of the four corners is above the water, the green channel is the
depth at the first corner; `water2.fx` `TWaterLayAlphaMask` lays the water alpha where the sampled blue is exactly 0 (alpha test `Equal 0`, bilinear filter, so the flag is dilated by a texel).
The water plane itself is one quad.

**Fix** (engine patch 0104, `CWldMap.cpp`). The editor keeps a second water map for rendering with `ed_water_hires` texels per cell (default 4, at most 4096 texels a side: a 1024 cell map has
4096 x 4096, a 2048 cell map 2 texels per cell, a bigger one keeps the half resolution map). Every texel centre reads the *bilinear* height: the shore flag is "the ground there is above the water",
the depth byte is the exact depth there, foam and flatness come from the half resolution masks of the map (index `cell >> 1`). `GetWaterMap()` hands the finer texture to the renderers (terrain
shaders, water, alpha mask); the half resolution map (saved with the map, edited by the foam brush) is untouched. Writers mark cells dirty: `RebuildWaterMapRect` (height edits, water level) and
`UpdateTextureChannel` on the water map (foam / flatness brush); `GetWaterMap()` rebuilds only the dirty cells (a cell more on every side), the whole map on the first call and when the setting
changes, on the worker pool when it is big. `ed_water_hires 0` switches it off. The finer texture belongs to the terrain resource (kept per `CWldTerrainRes`, removed in its destructor).

**Checked** on a layout lake seen from above at 0.25 map distance: 2 unit steps with the half resolution map, a 0.5 unit comb with 2 texels per cell, a clean edge with 4.
