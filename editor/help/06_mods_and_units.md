# Mods and the unit lab
summary: Change unit stats, derive new units and test them in the game.
keywords: mod, unit, blueprint, lab, project, merge, derive, icon, viewer, effects, stats, mod project, test

The Mod workspace changes units without copying them: your changes are written as small merge blueprints that only contain what you changed.

## First steps

1. Mod workspace. In the Units panel pick a unit (filter by name or id).
2. Unit lab panel: New project (a name of letters, digits, space, - and _) or Open an existing project. Projects live in the modproj folder of the editor.
3. Edit unit: the list shows the unit's fields; pick one and change it with the slider (or type the value). The game's own value stays visible beside it.
4. Write generates the project's merge blueprints. Test writes them, enables the project for this map and reloads the session so the changes are live in the Viewport.

## Looking at a unit

- Unit viewer: puts the unit on a stage with its own camera, shows ranges, senses, footprint, hit box and bones, and plays its animations.
- Effects: the effect templates and projectiles of the game; the Fields tab edits the numbers of an effect and writes them into the project.
- Icons: renders the strategic icon of a unit with a fixed recipe and writes it into the project.

## New units

Derive unit... in the Unit lab makes a new unit from an existing one: give it an id (lower case letters and digits) and a name, then edit its stats like any other.

## Good to know

- Mods are applied when a session starts: "Apply & reload" in the Mods panel (and Test) autosaves the map and reopens it.
- The Mods panel also lists the game mods you want loaded for this map.
