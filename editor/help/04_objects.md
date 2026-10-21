# Markers, units, props and decals
summary: Placing, selecting, moving and copying things on the map.
keywords: objects, marker, area, start position, army, unit, prop, decal, select, box select, move, copy, paste, duplicate, delete, outliner, properties, group

The Objects workspace has the tools for everything that stands on the map.

## Tools

- Select marker: click a marker to select it; drag on empty ground to draw a selection box; Shift adds or removes. Dragging a selected marker moves the whole selection. It never picks an area, and markers of a layer that is switched off in the View panel are not picked either.
- Select area: the same for areas. Click inside an area (the smallest one under the pointer), drag a selected area to move it, drag its handles to resize it. It never picks a marker. Alt+A switches to it.
- Marker: pick a type in the Markers panel (mass, hydrocarbon, expansion, rally points and more), click to place. Resource markers snap to the build grid.
- Start position: places the next army (ARMY_1, ARMY_2, ...). A ghost of the marker with its name follows the pointer; with symmetry on the mirror images show too.
- Area: drag a rectangle; areas are used by missions and scripts.
- Draw chain (Alt+C): every click places a marker at the end of the current chain. With no chain chosen in the Chains panel the first click starts a new one (Chain_1, ...); Ctrl+click starts another; a chain chosen in the panel is extended. The markers are Blank Markers named after the chain. With symmetry on the mirror images get markers and chains of their own (Chain_1_mx ...). One click is one undo step.
- Unit tool and Select units: pick a unit in the Units panel; the army button chooses which army owns it. Select units works like Select: click, Shift, drag a box.
- Prop brush, Erase props, Select props: the Props panel lists the prop blueprints; the Properties panel has radius, density, spacing and scale range of the brush. Select props picks single props or a box of them.
- Decal brush, Erase decals, Select decals: the same for decals.
- Ruler: measures distances.

## Editing

- The Properties panel shows the selected object's values; the Outliner lists every marker and area (click to select, right-click for its menu).
- Ctrl+C, Ctrl+X, Ctrl+V (pastes at the pointer), Ctrl+D (duplicate), Delete, Ctrl+A (select all), Ctrl+Shift+A (deselect). They work for markers, areas, units, props and decals of the active select tool.
- Right-click in the Viewport for the place and paste menu, right-click an object for its own menu.
- View panel, Show markers: switches the marker layers (resources, areas and points, paths, other). A switched-off layer hides the icons, names, 3D props, footprints and the chain lines of its markers (a selected marker stays visible). Only the selected chain draws just the chain of the selected marker (else the one chosen in the Chains panel), with a ring on each member.
- Symmetry (Symmetry panel) mirrors what you place, including start positions.

## Hints

- The status line shows what is selected.
- Everything is undoable; a drag that moves several objects is one step.
