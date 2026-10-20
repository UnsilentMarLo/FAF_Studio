-- Short tips for the start screen (one is shown at a time). Keys are written the way the editor's hotkey list spells them; the help panel (F1) has the full list.
-- Lua 5.0 dialect.

List = {
    'Press F1 for help: search the topics, see every shortcut, read the step-by-step workflows.',
    'Ctrl+Shift+P opens the command palette: type a few letters of anything the editor can do and press Enter.',
    'Ctrl+Z / Ctrl+Y undo and redo. A brush stroke is one step, so a bad stroke is one Ctrl+Z away.',
    'Drag a panel tab out of the window to get a second window (a second screen works well); closing it docks the panel back. The editor remembers your layout.',
    'Hold Shift while painting with a height brush to invert it: raise becomes lower.',
    'The Terrain > Generate command makes a whole landscape from a few settings. Use Undo if you do not like it.',
    'Symmetry (Terrain workspace) mirrors brushes, markers and units, so a 1v1 map is half the work.',
    'The Grid button shows the build grid, Slope shows where units can walk: check your expansions before you ship.',
    'File > Release map checks the map (start positions, script, resources) and writes a numbered version folder for the vault.',
    'The Mission workspace has stages, objectives and triggers: no scripting needed for a simple mission.',
    'Mod workspace: pick a unit and change its stats in the Unit lab. Changes are written as small merge blueprints, not as copies of the unit.',
    'Autosave runs every few minutes. After a crash the editor offers to restore it the next time you start.',
    'The + and - buttons in the top right change the UI size; a panel that does not fit scrolls with the mouse wheel.',
    'Right-click in the viewport for place and paste commands; right-click an object for its own menu.',
    'Ctrl+C / Ctrl+V copy markers, areas, units, props and decals; Ctrl+D duplicates the selection.',
    'Help > Save diagnostics for a bug report writes the version, the log tail and your settings into one file you can attach.',
}

--- Tip number i (wraps around).
function Get(i)
    local n = table.getn(List)
    return List[math.mod(i - 1, n) + 1]
end

function Count()
    return table.getn(List)
end
