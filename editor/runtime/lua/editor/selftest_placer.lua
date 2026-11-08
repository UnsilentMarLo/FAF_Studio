-- Self test of the placing preview and the unit edits that depend on the sim's entities (placer.lua, units.lua). Run in the live editor on a map with a terrain:
--   return import('/lua/editor/selftest_placer.lua').Run()
-- 1. With the Unit tool the footprints of ALL the units already on the map are drawn (outlines of the footprint, and of the skirt where it differs), kept up to date as units change.
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

    -- 1. with the Unit tool EVERY unit of the map shows its footprint, wherever the pointer is; a moved unit is redone, a removed one is gone
    local hasOverlay = rawget(_G, 'ed_overlay_count') ~= nil
    local scale = {}
    if hasOverlay then
        UI.State.tool = 'unit'           -- (the Unit tool is not offered by every workspace: set it directly)
        Placer.SetTestCursor(110, 110)
        local function Settle()
            local t0 = GetSystemTimeSeconds()
            local frames, todo = 0, 1
            while todo > 0 and frames < 3000 do
                Placer.Update(UI, { CursorOverWorld = true })
                frames = frames + 1
                local _
                _, todo = Placer.NearState()
            end
            return frames, GetSystemTimeSeconds() - t0
        end
        local n0 = ed_overlay_count()
        Settle()
        local have = Placer.NearState()
        Check(have >= before + 3, 'every unit of the map has its outline (' .. have .. ' of ' .. (before + 3) .. ')')
        Check(ed_overlay_count() - n0 >= 3, 'the footprints of the three units are drawn (' .. tostring(ed_overlay_count() - n0) .. ' overlay objects)')
        Placer.SetTestCursor(900, 900)
        Settle()
        Check(Placer.NearState() == have, 'far from them they are still drawn (' .. have .. ')')
        -- many units: 400 in a grid, all drawn, and the layer is made in a handful of frames
        for i = 0, 19 do
            for j = 0, 19 do Units.Place(200 + i * 4, 200 + j * 4) end
        end
        local frames, secs = Settle()
        local have2 = Placer.NearState()
        Check(have2 >= have + 400, '400 more units all have their outline (' .. have2 .. ' now)')
        table.insert(lines, string.format('INFO %d units outlined, 400 of them made in %d frames / %.2f s', have2, frames, secs))
        -- a change redoes only what changed
        Units.Selection = {}
        for _, u in Units.All() do
            if u.bp == 'ueb1101' and u.x == 100 and u.z == 100 then Units.Select(u, 'add') end
        end
        Units.MoveSelected(0, 20)
        Placer.Update(UI, { CursorOverWorld = true })
        local _, todo = Placer.NearState()
        Check(todo <= 1, 'after moving one unit one outline is redone (' .. todo .. ')')
        Settle()
        Units.MoveSelected(0, -20)
        Units.Selection = {}
        -- the units of the grid go again
        for _, u in Units.All() do
            if u.bp == 'ueb1101' and u.x >= 200 and u.x <= 280 and u.z >= 200 and u.z <= 280 then Units.RemoveRaw(u) end
        end
        Settle()
        Check(Placer.NearState() <= have + 1, 'removed units lose their outline (' .. Placer.NearState() .. ')')
        -- leaving the Unit tool takes the layer away
        UI.State.tool = 'select'
        Placer.Update(UI, { CursorOverWorld = true })
        Check(Placer.NearState() == 0, 'without the Unit tool no outlines are left (' .. Placer.NearState() .. ')')
        UI.State.tool = 'unit'
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
