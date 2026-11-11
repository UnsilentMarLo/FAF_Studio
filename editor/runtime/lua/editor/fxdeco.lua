-- Effect decorations (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): an effect placed on the map as a marker of type `Effect` (fields `effect` = the emitter files' paths joined with ';', `scale`,
-- `height` above the ground), as upstream's editor does. The game has no "effect at a point" (only CreateEmitterAtEntity ...), so the map's script gets a function `MapEditorEffects`, called from
-- OnPopulate after ScenarioUtils.InitializeArmies(), that makes an entity of its own at each Effect marker and plays the effect on it (EdSaveFile.cpp WithScriptEffects, bound as
-- ed_fx_script_effects). The markers themselves are saved in `_save.lua` with the other markers (map.lua, textsave.lua); the function in `_script.lua`, which map.lua SaveAsCore patches through
-- PatchScript below. With no Effect marker the function and its call are taken out again.
--
-- While editing, the editor plays each decoration where it stands (ed_fxv_world_set, the game's particle renderer in the map's view); Refresh (4 Hz) keeps the list in step with the markers.
--
--   Effects()                 list of { name, effect, scale, height, x, y, z } of the Effect markers of the open map
--   PlaceAtView(effect)       an Effect marker at the middle of the view (one undo step) -> name | nil, why
--   PatchScript(script)       the map script with MapEditorEffects on when the map has Effect markers, else off
--   Sync(force)               sends the decorations to the engine (when they changed)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

local lastSignature = ''

--- The Effect markers of the open map.
function Effects()
    local list = {}
    if not Map.Doc then return list end
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        if m.type == 'Effect' and m.effect and m.effect ~= '' and m.position then
            table.insert(list, { name = name, effect = m.effect, scale = m.scale or 1, height = m.height or 0, x = m.position[1], y = m.position[2], z = m.position[3] })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function Count()
    local n = 0
    if not Map.Doc then return 0 end
    for _, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        if m.type == 'Effect' then n = n + 1 end
    end
    return n
end

--- Plays the Effect markers of the map in the map's view (the engine keeps the ones that did not change).
function Sync(force)
    if not ed_fxv_world_set then return end
    local list = Effects()
    local parts = {}
    for _, e in list do
        table.insert(parts, string.format('%s|%s|%.2f|%.2f|%.2f|%.3f|%.2f', e.name, e.effect, e.x, e.y + e.height, e.z, e.scale, 0))
    end
    local signature = table.concat(parts, ';;')
    if not force and signature == lastSignature then return end
    lastSignature = signature
    local send = {}
    for i, e in list do send[i] = { id = e.name, effect = e.effect, x = e.x, y = e.y + e.height, z = e.z, scale = e.scale } end
    ed_fxv_world_set(send)
end

--- Stops the decorations (the map was closed).
function Clear()
    lastSignature = ''
    if ed_fxv_world_clear then ed_fxv_world_clear() end
end

--- Puts an Effect marker in the middle of the view. `effect`: an emitter file's path (several: joined with ';').
function PlaceAtView(effect)
    if not Map.Doc then return nil, 'no map open' end
    local ok, focus = pcall(function() return GetCamera('WorldCamera'):SaveSettings().Focus end)
    if not ok or not focus then return nil, 'the camera has no focus' end
    local Tools = import('/lua/editor/tools.lua')
    local name = Tools.PlaceMarker(focus[1], focus[3], 'Effect')
    if not name then return nil, 'the marker could not be placed' end
    local m = Map.GetMarker(name)
    m.effect = effect
    m.scale = 1
    m.height = 0
    Sync(true)
    return name
end

--- The map script with the function that plays the decorations (and its call) when the map has Effect markers, else without them.
function PatchScript(script)
    if not ed_fx_script_effects then return script end
    return ed_fx_script_effects(script, Count() > 0)
end

--- Called by the shell about four times a second.
function Refresh()
    if not Map.Doc then
        if lastSignature ~= '' then Clear() end
        return
    end
    Sync(false)
end
