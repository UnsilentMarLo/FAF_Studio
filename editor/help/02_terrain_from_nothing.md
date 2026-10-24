# Terrain from nothing
summary: Workflow: from a blank map to a playable skirmish map you can release.
keywords: terrain, new map, blank, generate, brush, raise, lower, texture, layers, symmetry, start positions, mass, hydrocarbon, markers, validate, release, skirmish, workflow

This is the shortest path from an empty map to something you can play on. Every step can be undone.

## 1. A blank map

1. Start screen > New map, or File > New map. Pick a size: 5 km (256) for a small map, 10 km (512) for the usual 1v1 and 2v2 size, 20 km (1024) for big maps. **Any size...** makes a map of any width and height from 1 to 80 km (for example 7.5 x 12 km): the terrain is the next power of two and the playable area is cut to your size, in the middle of it. The map starts flat with one start position.

## 2. Shape the land

1. Terrain workspace. Terrain > Generate... makes a whole landscape from a few settings (fractal noise); try it, and press Ctrl+Z if you do not like the result.
2. Refine with the brushes of the Tools panel: Raise and Lower, Flatten (levels to the height under the first click), Smooth, Plateau, Noise, Erode (paints erosion by hand). The Brush panel sets radius, strength and falloff; hold Shift to invert the brush.
3. Turn on Symmetry (Symmetry panel) before you start if the map should be fair: brushes, markers and units are mirrored.
4. The View panel and the Grid / Slope buttons show where structures can be built and where units can walk.

## 3. Paint it

1. Layers panel: choose a layer and its texture (Change albedo...). The Paint layer tool paints the chosen layer, Erase layer removes it.
2. For a quick start use Stratum recipes (Generate workspace): a preset makes slope and height based masks for grass, dirt, rock and snow.
3. Terrain type and Auto type set how the ground sounds and how units move on it; Auto type > Generate fills it from the textures.

## 4. Start positions and resources

1. Objects workspace. The Start position tool places ARMY_1, ARMY_2 and so on; a skirmish map needs at least two, without gaps in the numbering.
2. The Markers panel has mass points, hydrocarbon points, expansion areas and more: pick a type, click in the Viewport. Resource markers snap to the build grid; Map > Snap resource markers to grid fixes any that are off.
3. Props (trees, rocks) and decals (ground details) are in their own panels and brushes.

## 5. Check, save, release

1. The Validation panel (Check now) finds resource markers that cannot be used, stacked markers and more. The Terrain checks panel (Generate workspace) tests the ground around bases and the paths between start positions.
2. Ctrl+S saves. The editor autosaves while you work and offers to restore the autosave after a crash.
3. File > Release map... runs the final checks (name, start positions, script) and writes a numbered version folder (for example my_map.v0002) next to the working map. Run python scripts/pack_map.py (in the editor folder) to zip it for the vault.
