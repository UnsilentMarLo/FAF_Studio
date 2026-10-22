-- A counter that moves when the ground under the markers, areas and icons may have changed, so that what hugs the terrain (area outlines, footprint boxes, marker
-- heights, the transform gizmo) is laid onto it again then and not every half second.
--
--   Terrainepoch.Step(stroking)   once per frame (overlay.lua Update): `stroking` = a brush stroke is being dragged
--   Terrainepoch.Epoch            the counter
--   Terrainepoch.Touch()          code that writes the map heights calls this (Fields.CommitHeight does): the Lua side of the height revision
--   Terrainepoch.Stamp()          a string that differs whenever the map heights may differ: the document's native revision (every height write of any kind moves it: brush,
--                                 commits, undo / redo, imports, terrain tools, a preview on the terrain), Touch(), History.Version and the map size. The terrain graph (graphrun.lua
--                                 Refresh) compares it, so a height write that records no history entry still re-reads the "Map heights" node.
--
-- It moves when the undo history moved (a finished stroke, an undo, a redo, a generated or imported terrain: they all push an entry) and every 5 seconds (an edit that
-- records no history entry, a mesh view switched on). It stands still while a stroke is dragged: laying hundreds of outlines onto the terrain again costs more than a
-- frame, and the lines catch up when the button is released.
--
-- Lua 5.0 dialect.

local History = import('/lua/editor/history.lua')

Epoch = 0
Revision = 0

local lastVersion, frames = '', 0

--- A height write happened (called by the code that makes one; the native document revision moves on its own; this is the Lua-side count).
function Touch()
    Revision = Revision + 1
end

--- See the header. Cheap: two native calls and a string.
function Stamp()
    local rev, w, h = '-', 0, 0
    if rawget(_G, 'ed_cmd_depth') then
        local ok, a, b, c, d = pcall(ed_cmd_depth)
        if ok and d ~= nil then rev = tostring(d) end
    end
    if rawget(_G, 'ed_terrain_info') then
        local ok, a, b = pcall(ed_terrain_info)
        if ok then w, h = a or 0, b or 0 end
    end
    return rev .. '|' .. Revision .. '|' .. History.Version .. '|' .. w .. 'x' .. h
end

function Step(stroking)
    local v = tostring(History.Version) .. ':' .. Revision
    if v ~= lastVersion then
        lastVersion = v
        Epoch = Epoch + 1
        frames = 0
        return
    end
    if stroking then return end
    frames = frames + 1
    if frames >= 300 then
        Epoch = Epoch + 1
        frames = 0
    end
end

--- Forces the next users to lay everything onto the terrain again (a map was opened, the overlay was cleared).
function Bump()
    Epoch = Epoch + 1
    frames = 0
end
