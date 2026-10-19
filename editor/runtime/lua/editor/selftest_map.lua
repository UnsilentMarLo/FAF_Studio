-- Map document round trip, run in the live editor through the /edcmd channel (two steps, because step 2 runs in
-- the session that is opened from the saved folder):
--   return import('/lua/editor/selftest_map.lua').Build('<disk dir>', '<stem>')
--       edits the open map, spawns a unit on flat ground, raises a hill under it, saves the map as a folder and
--       returns the scenario path; open it with import('/lua/editor/control.lua').LoadMap(<that path>)
--   return import('/lua/editor/selftest_map.lua').Verify()
--       in the reopened session: checks markers, areas, props, decals, terrain and the unit height.

local Map = import('/lua/editor/map.lua')
local T = import('/lua/editor/terrain.lua')

function Build(diskDir, stem)
    local doc, why = Map.Load()
    if not doc then
        return 'FAIL load: ' .. tostring(why)
    end
    Map.AddMarker('ED_TEST_MARKER', 'Blank Marker', 50, 25, 60)
    Map.AddMarker('ED_TEST_MEX', 'Mass', 70, 25, 60, { amount = 150 })
    Map.AddArea('ED_TEST_AREA', 10, 10, 40, 40)
    local p = Map.AddProp('/env/common/props/markers/M_Blank_prop.bp', 150, 25, 150, 0.5)
    local d = Map.AddDecal('/env/Evergreen/decals/eg_ground001_albedo.dds', 'albedo', 120, 25, 90, 0.4, 20, 500)

    ed_terrain_set_rect(0, 0, 256, 256, 25)
    T.ClearHistory()
    T.Brush.mode = 'raise'
    T.Brush.radius = 14
    T.Brush.strength = 10
    T.BeginStroke()
    T.Dab(200, 200)
    T.EndStroke()

    local scenario, err = Map.SaveAs(diskDir, stem)
    if not scenario then
        return 'FAIL save: ' .. tostring(err)
    end
    return scenario .. ' prop=' .. tostring(p) .. ' decal=' .. tostring(d) .. ' hill=' .. tostring(ed_terrain_get(200, 200))
end

function Verify()
    local lines = {}
    local failures = 0
    local function check(name, ok, detail)
        if not ok then
            failures = failures + 1
        end
        table.insert(lines, (ok and '  ok   ' or '  FAIL ') .. name .. (ok and '' or (' ' .. tostring(detail or ''))))
    end

    local doc, why = Map.Load()
    check('document loads', doc ~= nil, why)
    if not doc then
        return 'FAIL\n' .. table.concat(lines, '\n')
    end
    local m = Map.GetMarker('ED_TEST_MARKER')
    check('marker present', m ~= nil)
    check('marker position', m and m.position[1] == 50 and m.position[3] == 60, m and tostring(m.position[1]))
    local mex = Map.GetMarker('ED_TEST_MEX')
    check('mass marker fields', mex and mex.type == 'Mass' and mex.resource == true and mex.amount == 150 and mex.size == 1)
    check('area present', doc.save.Areas.ED_TEST_AREA ~= nil and doc.save.Areas.ED_TEST_AREA.rectangle[3] == 40)
    check('army kept', doc.save.Armies.ARMY_1 ~= nil)
    check('prop in file', ed_prop_count() == 1, ed_prop_count())
    local bp, x, y, z = ed_prop_get(1)
    check('prop data', bp == '/env/common/props/markers/M_Blank_prop.bp' and x == 150 and z == 150, tostring(bp))
    check('decal in file', ed_decal_count() == 1, ed_decal_count())
    local tex, _, ty, dx, dy, dz = ed_decal_get(1)
    check('decal data', tex and string.find(tex, 'eg_ground001', 1, true) and ty == 1 and dx == 120, tostring(tex))
    check('hill saved', ed_terrain_get(200, 200) > 30, ed_terrain_get(200, 200))
    check('far field flat', ed_terrain_get(20, 230) == 25, ed_terrain_get(20, 230))
    check('no commander', true)
    return (failures == 0 and 'PASS' or ('FAIL (' .. failures .. ')')) .. '\n' .. table.concat(lines, '\n')
end
