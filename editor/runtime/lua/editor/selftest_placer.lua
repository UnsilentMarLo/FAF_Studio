-- Self test of the placing preview and the unit edits that depend on the sim's entities (placer.lua, units.lua). Run in the live editor on a map with a terrain:
--   return import('/lua/editor/selftest_placer.lua').Run()
-- 1. With the Unit tool the footprints of the units already on the map near the pointer are drawn (outlines of the footprint, and of the skirt where it differs).
-- 2. Turning or moving several selected units keeps each one where it is (the data), and the units are found again by the selection.
-- (The sim side of 2, EdRemoveUnitAt taking down the nearest unit and not a neighbour, is checked by dumping the sim's units: scripts/editor_unit_edit_check.py.)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Units = import('/lua/editor/units.lua')
local Placer = import('/lua/editor/placer.lua')
local UI = import('/lua/editor/ui.lua')

local fails = 0
local lines = {}
local function Check(ok, what)
    if not ok then
        fails = fails + 1
        table.insert(lines, 'FAIL ' .. what)
    end
end

function Run()
    local oldTool, oldActive, oldArmy = UI.State.tool, Units.Active, Units.ArmyName
    local armies = Units.Armies()
    Units.ArmyName = armies[1] or 'ARMY_1'
    Units.Active = 'ueb1101'          -- a power generator, 3 x 3
    local before = table.getn(Units.All())
    Units.Place(100, 100)
    Units.Place(103, 100)
    Units.Place(100, 106)
    Check(table.getn(Units.All()) == before + 3, 'three units were placed')

    -- 1. the preview draws the neighbours
    local hasOverlay = rawget(_G, 'ed_overlay_count') ~= nil
    if hasOverlay then
        UI.State.tool = 'unit'           -- (the Unit tool is not offered by every workspace: set it directly)
        Placer.SetTestCursor(110, 110)
        local n0 = ed_overlay_count()
        Placer.Update(UI, { CursorOverWorld = true })
        local n1 = ed_overlay_count()
        Check(n1 - n0 >= 3, 'the footprints of the three units near the pointer are drawn (' .. tostring(n1 - n0) .. ' overlay objects)')
        Placer.SetTestCursor(300, 300)
        Placer.Update(UI, { CursorOverWorld = true })
        local n2 = ed_overlay_count()
        Check(n2 < n1, 'far from them they are not drawn (' .. tostring(n1) .. ' -> ' .. tostring(n2) .. ')')
        Placer.SetTestCursor(false)
        Placer.Clear()
    end

    -- 2. a group turn and a group move keep every unit where it is
    Units.Selection = {}
    for _, u in Units.All() do
        if u.bp == 'ueb1101' and u.x >= 99 and u.x <= 104 and u.z >= 99 and u.z <= 107 then Units.Select(u, 'add') end
    end
    Check(table.getn(Units.Selection) == 3, 'three units selected (' .. table.getn(Units.Selection) .. ')')
    Units.RotateSelected(30)
    local seen = {}
    for _, u in Units.All() do
        if u.bp == 'ueb1101' and u.x >= 99 and u.x <= 104 and u.z >= 99 and u.z <= 107 then
            seen[string.format('%.0f,%.0f', u.x, u.z)] = math.deg(u.heading)
        end
    end
    Check(seen['100,100'] and seen['103,100'] and seen['100,106'], 'after a group turn the three units are at their places')
    Check(seen['100,100'] and math.abs(seen['100,100'] - 30) < 0.5, 'and turned by 30 degrees')
    Check(table.getn(Units.Selection) == 3, 'and still selected (' .. table.getn(Units.Selection) .. ')')
    Units.MoveSelected(10, 0)
    local moved = 0
    for _, u in Units.All() do
        if u.bp == 'ueb1101' and u.x >= 109 and u.x <= 114 and u.z >= 99 and u.z <= 107 then moved = moved + 1 end
    end
    Check(moved == 3, 'a group move moves all three (' .. moved .. ')')

    -- clean up: take the test units away (undo is for the user's history: delete them directly)
    for _, u in Units.All() do
        if u.bp == 'ueb1101' and u.x >= 99 and u.x <= 114 and u.z >= 99 and u.z <= 107 then Units.RemoveRaw(u) end
    end
    Units.Selection = {}
    Units.Active, Units.ArmyName = oldActive, oldArmy
    UI.State.tool = oldTool
    Placer.Clear()
    local summary = fails == 0 and 'PASS placer / unit edits' or ('FAIL placer / unit edits: ' .. fails .. ' check(s)')
    for _, l in lines do LOG('EDITOR selftest_placer: ' .. l) end
    return summary
end
