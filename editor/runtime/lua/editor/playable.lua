-- The playable area of the map: the part of the terrain players can use. FAF maps keep it as the area AREA_1 of the save file and the map script applies it
-- (ScenarioFramework.SetPlayableArea('AREA_1', false) in OnPopulate); the editor edits that area and makes sure the script has the line when the map is saved.
--
--   Get()                      -> x0, z0, x1, z1 of AREA_1, or the whole map when there is none; second result: true when AREA_1 exists
--   Set(x0, z0, x1, z1)        sets AREA_1 (creating it), one undo step
--   PatchScript(text)          the map script with the SetPlayableArea line added after InitializeArmies() when AREA_1 exists and the script lacks the call
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')

NAME = 'AREA_1'

local function MapSize()
    local w, h = ed_terrain_info()
    return (w or 257) - 1, (h or 257) - 1
end

function Get()
    local mw, mh = MapSize()
    local a = Map.Doc and Map.Doc.save.Areas and Map.Doc.save.Areas[NAME]
    if a and a.rectangle then
        local r = a.rectangle
        return r[1], r[2], r[3], r[4], true
    end
    return 0, 0, mw, mh, false
end

function Set(x0, z0, x1, z1)
    if not Map.Doc then return false end
    local mw, mh = MapSize()
    x0, x1 = math.max(0, math.min(x0, x1)), math.min(mw, math.max(x0, x1))
    z0, z1 = math.max(0, math.min(z0, z1)), math.min(mh, math.max(z0, z1))
    if x1 - x0 < 8 or z1 - z0 < 8 then return false end
    local areas = Map.Doc.save.Areas
    local old = areas[NAME]
    local new = { rectangle = { x0, z0, x1, z1, type = 'RECTANGLE' } }
    areas[NAME] = new
    pcall(function() import('/lua/editor/tools.lua').Prune() end)
    History.Push({
        label = 'set the playable area',
        undo = function() areas[NAME] = old end,
        redo = function() areas[NAME] = new end,
    })
    return true
end

function PatchScript(text)
    if not Map.Doc or not Map.Doc.save.Areas or not Map.Doc.save.Areas[NAME] then return text end
    if string.find(text, 'SetPlayableArea', 1, true) then return text end
    local i, j = string.find(text, 'ScenarioUtils%.InitializeArmies%(%)')
    if not i then
        LOG('EDITOR playable: the map script has no ScenarioUtils.InitializeArmies() to put SetPlayableArea after: the playable area is not applied')
        return text
    end
    local line = "\n    import('/lua/ScenarioFramework.lua').SetPlayableArea('" .. NAME .. "', false)"
    return string.sub(text, 1, j) .. line .. string.sub(text, j + 1)
end
