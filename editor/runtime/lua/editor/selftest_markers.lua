-- Marker placement self test (markercheck.lua, the marker checks of validate.lua, Tools.ClampMarkersToMap, the overlay reset). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_markers.lua').Run()
-- Returns text that starts with PASS or FAIL. Real map files are used when the maps folder has them (skipped otherwise).
--
-- Background (2026-10-18): after opening another map the markers of the previous one stayed on screen, outside the new terrain and hanging at their old heights,
-- because the engine keeps its overlay objects in static tables and the editor's own id lists are lost with the Lua state of the session.

local MC = import('/lua/editor/markercheck.lua')
local Map = import('/lua/editor/map.lua')
local Validate = import('/lua/editor/validate.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Marker(x, y, z)
    return { type = 'Blank Marker', position = { x, y, z, type = 'VECTOR3' } }
end

function Run()
    out, failed = {}, 0

    -- ---- Analyse ---------------------------------------------------------------------------------------------------------------------------
    local ground = function(x, z) if x < 0 or z < 0 or x > 100 or z > 100 then return nil end return 10 end
    local markers = {
        ok = Marker(50, 10, 50), high = Marker(20, 40, 20), low = Marker(30, 2, 30), out1 = Marker(-5, 10, 50), out2 = Marker(50, 999, 130),
        play = Marker(95, 10, 95), nan = Marker(0 / 0, 0, 0),
    }
    local st = MC.Analyse(markers, 100, 100, { 10, 10, 90, 90 }, ground)
    Check(st.total == 7 and st.outsideMap == 2 and st.outsidePlayable == 1 and st.above == 1 and st.below == 1 and st.nonFinite == 1,
        'Analyse counts outside map, outside playable, above, below, broken (' .. st.outsideMap .. '/' .. st.outsidePlayable .. '/' .. st.above .. '/' .. st.below .. '/' .. st.nonFinite .. ')')
    Check(st.maxAbove == 30 and st.maxBelow == 8, 'Analyse reports the largest height differences')
    Check(MC.Analyse(markers, 100, 100, nil, nil).above == 0, 'without a ground function there are no height findings')
    Check(MC.SnapY(markers, { 'high', 'low', 'out1', 'nan' }, ground) == 2 and markers.high.position[2] == 10 and markers.low.position[2] == 10, 'SnapY moves markers onto the ground and skips those outside it')

    -- ---- DisplayPos on the open map ---------------------------------------------------------------------------------------------------------
    local w, h = ed_terrain_info()
    local sx, sz = w - 1, h - 1
    local edge = ed_terrain_get(sx, 10)
    local x, y, z, kind = MC.DisplayPos(Marker(sx + 500, 9999, 10))
    Check(kind == 'map' and y == edge and x == sx + 500, 'a marker outside the map is drawn on the terrain at the nearest edge, not at its stored height (' .. tostring(y) .. ' vs ' .. tostring(edge) .. ')')
    x, y, z, kind = MC.DisplayPos(Marker(10, 77, 10))
    Check(kind == nil and y == 77, 'a marker inside is drawn where it is stored')
    x, y, z, kind = MC.DisplayPos(Marker(0 / 0, 1, 1))
    Check(kind == 'bad' and x == 0 and z == 0, 'a marker with NaN coordinates is drawn at the corner')

    -- ---- Validation entries -------------------------------------------------------------------------------------------------------------------
    local doc = Map.Doc
    local chain = doc.save.MasterChain._MASTERCHAIN_.Markers
    local oldArea = doc.save.Areas.AREA_1
    local added = {}
    for i = 1, 6 do
        local name = 'ZZ_OUT_' .. i
        chain[name] = Marker(sx + 10 * i, 123, 20)
        table.insert(added, name)
    end
    chain.ZZ_PLAY = Marker(sx - 4, 20, sx - 4)
    chain.ZZ_NAN = Marker(0 / 0, 0, 0)
    table.insert(added, 'ZZ_PLAY') table.insert(added, 'ZZ_NAN')
    doc.save.Areas.AREA_1 = { rectangle = { 20, 20, sx - 20, sz - 20, type = 'RECTANGLE' } }
    local issues = Validate.MapIssues()
    local outside, playable, broken
    for _, i in issues do
        if i.outside then outside = i end
        if string.find(i.text, 'playable area', 1, true) then playable = i end
        if string.find(i.text, 'broken position', 1, true) then broken = i end
    end
    Check(outside ~= nil and table.getn(outside.names) == 6, 'the validation has one entry for the 6 markers outside the map (' .. tostring(outside and table.getn(outside.names)) .. ')')
    Check(playable ~= nil and table.getn(playable.names) == 1 and playable.names[1] == 'ZZ_PLAY', 'and one for the marker outside the playable area')
    Check(broken ~= nil and broken.names[1] == 'ZZ_NAN', 'and one for the broken position')

    -- ---- pulling markers inside, undoable ---------------------------------------------------------------------------------------------------------
    chain.ZZ_NAN = nil
    local depth = History.Depth and History.Depth() or 0
    local n = Tools.ClampMarkersToMap(outside.names)
    Check(n == 6 and chain.ZZ_OUT_3.position[1] == sx and chain.ZZ_OUT_3.position[2] == ed_terrain_get(sx, 20), 'ClampMarkersToMap puts the markers on the map edge at terrain height (' .. n .. ')')
    History.Undo()
    Check(chain.ZZ_OUT_3.position[1] == sx + 30 and chain.ZZ_OUT_3.position[2] == 123, 'and one undo restores them')

    -- ---- the overlay is emptied between sessions --------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_overlay_icon') then
        for i = 1, 25 do ed_overlay_icon('mi:ZZ_STALE_' .. i, i, 5, i, '/textures/editor/markers/default.dds', 22, 'FFFFFFFF') end
        Check(ed_overlay_count() >= 25, 'overlay objects exist (' .. ed_overlay_count() .. ')')
        import('/lua/editor/control.lua').ClearOverlays()
        Check(ed_overlay_count() == 0, 'control.ClearOverlays empties the engine overlay (stale icons of a previous session)')
        for i = 1, 25 do ed_overlay_icon('mi:ZZ_STALE_' .. i, i, 5, i, '/textures/editor/markers/default.dds', 22, 'FFFFFFFF') end
        import('/lua/editor/overlay.lua').Clear()
        Check(ed_overlay_count() == 0, 'overlay.Clear does too')
    else
        table.insert(out, '  skip no overlay natives in this engine')
    end

    -- ---- the marker meshes are destroyed when a map is queued (the rocks of a map's resource markers stayed in the next map: a WorldMesh outlives the Lua modules) ----------------
    do
        local MV = import('/lua/editor/markervis.lua')
        local Placer = import('/lua/editor/placer.lua')
        local Control = import('/lua/editor/control.lua')
        chain.ZZ_MASS = { type = 'Mass', resource = true, amount = 100, size = 1, prop = '/env/common/props/markers/M_Mass_prop.bp', position = { 40, ed_terrain_get(40, 40) or 0, 40, type = 'VECTOR3' } }
        table.insert(added, 'ZZ_MASS')
        MV.Update()
        local entries, meshes = MV.Count()
        Check(entries > 0 and meshes > 0, 'a resource marker has its deposit mesh (' .. entries .. ' entries, ' .. meshes .. ' meshes)')
        Control.Teardown()
        entries, meshes = MV.Count()
        Check(entries == 0 and meshes == 0 and Placer.GhostCount() == 0, 'control.Teardown destroys every marker mesh and placement ghost (' .. entries .. ' / ' .. meshes .. ')')
        if rawget(_G, 'ed_overlay_count') then Check(ed_overlay_count() == 0, 'and empties the engine overlay') end
        MV.Update()
        entries, meshes = MV.Count()
        Check(entries == 0 and meshes == 0, 'nothing is built again while the session ends (' .. entries .. ' / ' .. meshes .. ')')
        MV.Resume()
        Placer.Resume()
        MV.Update()
        entries = MV.Count()
        Check(entries > 0, 'after Resume the markers are drawn again')
        MV.Clear()
    end

    -- clean up
    for _, name in added do chain[name] = nil end
    doc.save.Areas.AREA_1 = oldArea

    -- ---- real maps, when present --------------------------------------------------------------------------------------------------------------
    local real = { { '/maps/sc2_ca_c06/sc2_ca_c06_scenario.lua', 18 }, { '/maps/sc2_ca_c03/sc2_ca_c03_scenario.lua', 7 } }
    for _, r in real do
        if DiskGetFileInfo(r[1]) then
            local s = MC.Survey(r[1])
            Check(s ~= nil and s.outsideMap == r[2], 'survey of ' .. r[1] .. ': ' .. tostring(r[2]) .. ' markers outside the map (' .. tostring(s and s.outsideMap) .. ')')
        else
            table.insert(out, '  skip ' .. r[1] .. ' not in the maps folders')
        end
    end

    table.insert(out, 1, (failed == 0 and 'PASS' or 'FAIL') .. ' markers: ' .. failed .. ' failed')
    return table.concat(out, '\n')
end
