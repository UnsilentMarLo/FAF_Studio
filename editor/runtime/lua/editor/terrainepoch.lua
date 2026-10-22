-- A counter that moves when the ground under the markers, areas and icons may have changed, so that what hugs the terrain (area outlines, footprint boxes, marker
-- heights, the transform gizmo) is laid onto it again then and not every half second.
--
--   Terrainepoch.Step(stroking)   once per frame (overlay.lua Update): `stroking` = a brush stroke is being dragged
--   Terrainepoch.Epoch            the counter
--
-- It moves when the undo history moved (a finished stroke, an undo, a redo, a generated or imported terrain: they all push an entry) and every 5 seconds (an edit that
-- records no history entry, a mesh view switched on). It stands still while a stroke is dragged: laying hundreds of outlines onto the terrain again costs more than a
-- frame, and the lines catch up when the button is released.
--
-- Lua 5.0 dialect.

local History = import('/lua/editor/history.lua')

Epoch = 0

local lastVersion, frames = -1, 0

function Step(stroking)
    local v = History.Version
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
