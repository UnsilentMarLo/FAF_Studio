-- Map > Resize self test. Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_resize.lua').Run()            one session: geometry, the save-file transform, the remapped native fields
-- and the two-stage flow test (scripts/editor_resize_flow.py drives it; the session is reloaded in between):
--   return import('/lua/editor/selftest_resize.lua').Setup()          fills the open blank 256 map with known content
--   return import('/lua/editor/selftest_resize.lua').Start('expand')  resizes it into ../mapout (the session reloads)
--   return import('/lua/editor/selftest_resize.lua').Verify('expand') after the reload: checks the new session and the saved folder
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local R = import('/lua/editor/resize.lua')

local out, failed, total = {}, 0, 0

local function Check(ok, text)
    total = total + 1
    -- the command channel returns a short text: only the failures are listed (Verbose = true lists everything)
    if not ok or Verbose then table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text) end
    if not ok then failed = failed + 1 end
end

Verbose = false

local function Near(a, b, tol)
    return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.01)
end

-- the content Setup puts into the 256 test map (old world coordinates)
local PROP_BP = '/env/common/props/markers/M_Blank_prop.bp'
local BUMP = { x0 = 20, z0 = 30, x1 = 60, z1 = 70, h = 77 }
local MASK = { stratum = 1, x0 = 10, z0 = 12, x1 = 14, z1 = 16, v = 200 }      -- mask cells (2 world units each on the 256 map)
local TT = { x0 = 22, z0 = 32, x1 = 26, z1 = 36, v = 7 }                       -- terrain-type cells (1 world unit each)
local POINTS = {
    marker_a = { 30, 40 }, marker_b = { 240, 240 }, marker_c = { 100, 20 },
    prop_a = { 30, 40 }, prop_b = { 240, 240 },
    unit_a = { 60, 90 }, unit_b = { 200, 200 },
    decal_a = { 50, 50 }, decal_b = { 230, 30 },
}
local AREA = { 20, 20, 200, 200 }

Cases = {
    expand = { size = 512, mode = 'canvas', ax = 0.5, az = 0.5, fill = 'edge' },
    crop   = { size = 128, mode = 'canvas', ax = 0, az = 0, fill = 'edge' },
    scale  = { size = 512, mode = 'scale', ax = 0.5, az = 0.5, fill = 'edge' },
    level  = { size = 512, mode = 'canvas', ax = 1, az = 1, fill = 'level', level = 60 },
}

local function Markers() return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end

-- ---- single session -----------------------------------------------------------------------------------------------------------------------------

local function Pure()
    local g = R.Geometry(256, 512, { mode = 'canvas', ax = 0.5, az = 0.5 })
    Check(g.ox == 128 and g.oz == 128 and g.f == 1, 'canvas expand to the middle: offset 128')
    local x, z = R.MapPoint(g, 10, 20)
    Check(x == 138 and z == 148, 'a point moves by the offset')
    Check(R.Inside(g, 0, 0) and R.Inside(g, 512, 512) and not R.Inside(g, -1, 5), 'bounds are inclusive')
    local c = R.Geometry(512, 256, { mode = 'canvas', ax = 1, az = 0 })
    Check(c.ox == -256 and c.oz == 0, 'crop from the east edge: offset -256, 0')
    local a, b, cc, d = R.MapRect(c, 100, 100, 400, 200)
    Check(a == 0 and b == 100 and cc == 144 and d == 200, 'a rectangle is cut to the new bounds')
    Check(R.MapRect(c, 0, 0, 200, 50) == nil, 'a rectangle outside the new bounds is gone')
    local s = R.Geometry(256, 512, { mode = 'scale' })
    local sx, sz = R.MapPoint(s, 10, 20)
    Check(s.f == 2 and s.ox == 0 and sx == 20 and sz == 40, 'scale doubles positions')

    -- a synthetic save file
    local save = {
        MasterChain = { _MASTERCHAIN_ = { Markers = {
            ARMY_1 = { type = 'Blank Marker', position = { 50, 25, 50, type = 'VECTOR3' }, adjacentTo = 'M_B M_C' },
            ARMY_2 = { type = 'Blank Marker', position = { 480, 25, 480, type = 'VECTOR3' } },
            M_B = { type = 'Mass', position = { 100, 25, 60, type = 'VECTOR3' } },
            M_C = { type = 'Mass', position = { 400, 25, 60, type = 'VECTOR3' } },
        } } },
        Chains = { OneIn = { Markers = { 'M_B', 'ARMY_1' } }, Half = { Markers = { 'M_B', 'M_C' } }, Out = { Markers = { 'M_C', 'ARMY_2' } } },
        Areas = { AREA_1 = { rectangle = { 0, 0, 512, 512, type = 'RECTANGLE' } }, A = { rectangle = { 300, 300, 500, 500, type = 'RECTANGLE' } },
                  B = { rectangle = { 10, 10, 150, 150, type = 'RECTANGLE' } } },
        Armies = { ARMY_1 = { Units = { type = 'GROUP', Units = {
            INITIAL = { type = 'GROUP', Units = { UNIT_1 = { type = 'uel0106', Position = { 60, 25, 60, type = 'VECTOR3' }, Orientation = { 0, 1, 0, type = 'VECTOR3' } },
                                                  UNIT_2 = { type = 'uel0106', Position = { 450, 25, 450, type = 'VECTOR3' } } } },
            G2 = { type = 'GROUP', Units = { UNIT_3 = { type = 'uel0106', Position = { 200, 25, 100, type = 'VECTOR3' } } } },
        } } } },
    }
    local crop = R.Geometry(512, 256, { mode = 'canvas', ax = 0, az = 0 })
    local ns, rep = R.TransformSave(save, crop, { playable = 'keep' })
    local mk = ns.MasterChain._MASTERCHAIN_.Markers
    Check(mk.ARMY_1 and mk.M_B and not mk.ARMY_2 and not mk.M_C, 'crop: markers outside the new bounds are dropped')
    Check(table.getn(rep.markers.dropped) == 2 and table.getn(rep.starts) == 1 and rep.starts[1] == 'ARMY_2', 'crop: the report names the dropped markers and the lost start position')
    Check(ns.Chains.OneIn and table.getn(ns.Chains.OneIn.Markers) == 2, 'crop: a chain with all its markers stays')
    Check(ns.Chains.Half and table.getn(ns.Chains.Half.Markers) == 1 and ns.Chains.Half.Markers[1] == 'M_B', 'crop: a chain is shortened to the markers that are left')
    Check(not ns.Chains.Out and rep.chains.dropped[1] == 'Out', 'crop: a chain with none left is dropped')
    Check(mk.ARMY_1.adjacentTo == 'M_B', 'crop: adjacency lists lose dropped markers')
    Check(not ns.Areas.A and ns.Areas.B and ns.Areas.AREA_1.rectangle[3] == 256, 'crop: areas are cut or dropped, AREA_1 follows the new bounds')
    local g2 = ns.Areas.B.rectangle
    Check(g2[1] == 10 and g2[3] == 150 and g2.type == 'RECTANGLE', 'crop: a rectangle inside keeps its numbers')
    local units = ns.Armies.ARMY_1.Units.Units
    Check(units.INITIAL.Units.UNIT_1 and not units.INITIAL.Units.UNIT_2 and units.G2.Units.UNIT_3, 'crop: units in every group are kept or dropped by position')
    Check(rep.units.kept == 2 and rep.units.dropped == 1, 'crop: unit counts')
    Check(save.MasterChain._MASTERCHAIN_.Markers.ARMY_2 ~= nil, 'the original save table is not touched')
    local whole = R.TransformSave(save, crop, { playable = 'whole' })
    Check(whole.Areas.AREA_1 == nil, 'playable = whole drops AREA_1')

    local big = R.Geometry(512, 1024, { mode = 'scale' })
    local ns2 = R.TransformSave(save, big, {})
    local m2 = ns2.MasterChain._MASTERCHAIN_.Markers
    Check(m2.ARMY_2 and m2.ARMY_2.position[1] == 960 and m2.ARMY_2.position[2] == 25 and m2.ARMY_2.position[3] == 960, 'scale: positions double, heights stay')
    Check(ns2.Areas.AREA_1.rectangle[3] == 1024, 'scale: areas scale')

    local paths, prep = R.TransformPaths({ { id = 'p1', points = { { x = 10, z = 10, ho = { 4, 0 } }, { x = 300, z = 10 } } },
                                           { id = 'p2', name = 'gone', points = { { x = 400, z = 400 }, { x = 410, z = 400 } } } }, crop)
    Check(table.getn(paths) == 0 and table.getn(prep.dropped) == 2, 'paths: a path left with fewer than two points goes')
    local keepPaths = R.TransformPaths({ { id = 'p1', points = { { x = 10, z = 10, ho = { 4, 0 } }, { x = 100, z = 10 } } } }, R.Geometry(512, 1024, { mode = 'scale' }))
    Check(keepPaths[1].points[2].x == 200 and keepPaths[1].points[1].ho[1] == 8, 'paths: points and handles scale with the map')
end

local function Fields()
    if rawget(_G, 'ed_field_op') == nil then Check(false, 'field engine is missing') return end
    local w = ed_terrain_info()
    local S = (w or 257) - 1
    -- a known pattern in the live document (restored below)
    local old = ed_terrain_read_rect(0, 0, S, S)
    ed_terrain_set_rect(BUMP.x0, BUMP.z0, BUMP.x1, BUMP.z1, BUMP.h)
    local mw, mh = ed_stratum_info()
    local maskBefore = ed_stratum_read(MASK.stratum, 0, 0, mw - 1, mh - 1)
    local tw, th = ed_tt_info()
    local ttBefore = ed_tt_read(0, 0, tw - 1, th - 1)
    local vals = {}
    for i = 1, (MASK.x1 - MASK.x0 + 1) * (MASK.z1 - MASK.z0 + 1) do vals[i] = MASK.v end
    ed_stratum_write(MASK.stratum, MASK.x0, MASK.z0, MASK.x1, MASK.z1, vals)
    local tvals = {}
    for i = 1, (TT.x1 - TT.x0 + 1) * (TT.z1 - TT.z0 + 1) do tvals[i] = TT.v end
    ed_tt_write(TT.x0, TT.z0, TT.x1, TT.z1, tvals)

    local ground = (ed_field_get(ed_field_height(), 0, 0))
    for name, opts in { expand = Cases.expand, crop = Cases.crop, scale = Cases.scale } do
        local g = R.Geometry(S, opts.size, opts)
        local F = R.BuildFields(g)
        local hw, hh = ed_field_info(F.height)
        Check(hw == opts.size + 1 and hh == opts.size + 1, name .. ': the height field has the new size')
        -- the bump centre
        local ox, oz = R.MapPoint(g, 40, 50)
        Check(Near(ed_field_get(F.height, math.floor(ox + 0.5), math.floor(oz + 0.5)), BUMP.h, 0.1), name .. ': the bump is at its new place')
        -- a corner far from the bump
        Check(Near(ed_field_get(F.height, 0, 0), ground, 1) or name == 'crop', name .. ': the corner keeps the ground height')
        if F.masks[MASK.stratum] then
            local cell = S / mw
            local mx, mz = R.MapPoint(g, (MASK.x0 + 2.5) * cell, (MASK.z0 + 2.5) * cell)
            local ncell = opts.size / F.maskW
            local v = ed_field_get(F.masks[MASK.stratum], math.floor(mx / ncell), math.floor(mz / ncell))
            Check(Near(v, MASK.v, 1), name .. ': the paint mask block moved (' .. tostring(v) .. ')')
        end
        if F.tt then
            local cell = S / tw
            local tx, tz = R.MapPoint(g, (TT.x0 + 2.5) * cell, (TT.z0 + 2.5) * cell)
            local ncell = opts.size / F.ttW
            local v = ed_field_get(F.tt, math.floor(tx / ncell), math.floor(tz / ncell))
            Check(v == TT.v, name .. ': the terrain-type block moved as a code (' .. tostring(v) .. ')')
            -- nothing between codes
            -- (the cells around the block: whole codes only. The field as a whole can hold the codes other tests painted, so its largest value says nothing)
            local fractional = 0
            for dz = -8, 8 do
                for dx = -8, 8 do
                    local okc, c = pcall(ed_field_get, F.tt, math.floor(tx / ncell) + dx, math.floor(tz / ncell) + dz)
                    if okc and c and c ~= math.floor(c) then fractional = fractional + 1 end
                end
            end
            Check(fractional == 0, name .. ': codes are not blended (' .. fractional .. ' fractional cells around the block)')
        end
        R.Free(F)
    end
    -- the expand/edge padding repeats the edge
    do
        local g = R.Geometry(S, 512, Cases.expand)
        local F = R.BuildFields(g)
        local edge = ed_field_get(F.height, g.ox, g.oz + 5)
        Check(Near(ed_field_get(F.height, 0, g.oz + 5), edge, 0.01), 'expand: padding repeats the edge heights')
        R.Free(F)
    end
    -- restore
    ed_terrain_write_rect(0, 0, S, S, old)
    ed_stratum_write(MASK.stratum, 0, 0, mw - 1, mh - 1, maskBefore)
    ed_tt_write(0, 0, tw - 1, th - 1, ttBefore)
end

local function Objects()
    local before = ed_prop_count()
    Map.AddProp(PROP_BP, 30, 25, 40, 0.4, { 1, 2, 3 })
    Map.AddProp(PROP_BP, 240, 25, 240, 0, 1)
    local g = R.Geometry(256, 128, { mode = 'canvas', ax = 0, az = 0 })
    local props, decals, pd = R.CollectObjects(g)
    Check(table.getn(props) == 1 and pd == 1 and Near(props[1].x, 30) and Near(props[1].heading, 0.4, 0.001) and props[1].sz == 3, 'props: kept ones move, others are counted as dropped, scale and heading survive')
    for i = ed_prop_count(), before + 1, -1 do Map.RemoveProp(i) end
    Check(ed_prop_count() == before, 'props removed again')
end

function Run()
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    Pure()
    Fields()
    Objects()
    local p = R.Plan({ size = 512, mode = 'canvas', ax = 0.5, az = 0.5, fill = 'edge', level = 25, playable = 'keep' })
    Check(not p.error and table.getn(p.lines) >= 6, 'the plan has a report')
    Check(R.Plan({ size = 256 }).error ~= nil, 'a resize to the same size is refused')
    table.insert(out, failed == 0 and ('ALL PASSED (' .. total .. ' checks)') or (failed .. ' FAILED of ' .. total))
    return table.concat(out, '\n')
end

-- ---- the flow over a reload ----------------------------------------------------------------------------------------------------------------------

--- Fills the open (blank 256) map with known content. Idempotent.
function Setup()
    if not Map.Doc then Map.Load() end
    local Units = import('/lua/editor/units.lua')
    local Tools = import('/lua/editor/tools.lua')
    for i = ed_prop_count(), 1, -1 do Map.RemoveProp(i) end
    for i = ed_decal_count(), 1, -1 do Map.RemoveDecal(i) end
    local w = ed_terrain_info()
    local S = (w or 257) - 1
    ed_terrain_set_rect(0, 0, S, S, 25)
    ed_terrain_set_rect(BUMP.x0, BUMP.z0, BUMP.x1, BUMP.z1, BUMP.h)
    local mw, mh = ed_stratum_info()
    ed_stratum_write(MASK.stratum, 0, 0, mw - 1, mh - 1, (function() local t = {} for i = 1, mw * mh do t[i] = 0 end return t end)())
    local vals = {}
    for i = 1, (MASK.x1 - MASK.x0 + 1) * (MASK.z1 - MASK.z0 + 1) do vals[i] = MASK.v end
    ed_stratum_write(MASK.stratum, MASK.x0, MASK.z0, MASK.x1, MASK.z1, vals)
    local tw, th = ed_tt_info()
    ed_tt_write(0, 0, tw - 1, th - 1, (function() local t = {} for i = 1, tw * th do t[i] = 0 end return t end)())
    local tvals = {}
    for i = 1, (TT.x1 - TT.x0 + 1) * (TT.z1 - TT.z0 + 1) do tvals[i] = TT.v end
    ed_tt_write(TT.x0, TT.z0, TT.x1, TT.z1, tvals)
    for _, n in { 'RESZ_A', 'RESZ_B', 'RESZ_C' } do if Markers()[n] then Map.RemoveMarker(n) end end
    Tools.PlaceMarker(POINTS.marker_a[1], POINTS.marker_a[2], 'Blank Marker', 'RESZ_A')
    Tools.PlaceMarker(POINTS.marker_b[1], POINTS.marker_b[2], 'Blank Marker', 'RESZ_B')
    Tools.PlaceMarker(POINTS.marker_c[1], POINTS.marker_c[2], 'Rally Point', 'RESZ_C')
    Map.Doc.save.Chains.RESZ_CH = { Markers = { 'RESZ_A', 'RESZ_B', 'RESZ_C' } }
    Map.Doc.save.Areas.RESZ_AR = { rectangle = { AREA[1], AREA[2], AREA[3], AREA[4], type = 'RECTANGLE' } }
    Map.AddProp(PROP_BP, POINTS.prop_a[1], 25, POINTS.prop_a[2], 0.5, { 1, 2, 3 })
    Map.AddProp(PROP_BP, POINTS.prop_b[1], 25, POINTS.prop_b[2], 0, 1)
    Map.AddDecal('resize_test_decal.dds', 'albedo', POINTS.decal_a[1], 25, POINTS.decal_a[2], 0.7, 12, 800)
    Map.AddDecal('resize_test_decal.dds', 'albedo', POINTS.decal_b[1], 25, POINTS.decal_b[2], 0, 6, 800)
    pcall(function() import('/lua/editor/armies.lua').Sync(Map.Doc) end)
    local army = 'ARMY_1'
    Units.ArmyName, Units.Active = army, 'uel0106'
    local n0 = table.getn(Units.All())
    Units.Place(POINTS.unit_a[1], POINTS.unit_a[2])
    Units.Place(POINTS.unit_b[1], POINTS.unit_b[2])
    return 'setup: units ' .. n0 .. ' -> ' .. table.getn(Units.All()) .. ', props ' .. ed_prop_count() .. ', decals ' .. ed_decal_count()
end

function Start(case)
    local opts = {}
    for k, v in Cases[case] do opts[k] = v end
    opts.base = '../mapout'
    opts.playable = 'keep'
    local ok, why = R.Run(opts)
    return ok and 'resizing' or ('FAILED: ' .. tostring(why))
end

--- Opens the saved folder again (File > Open): the .scmap must hold what the resize wrote.
function Reopen()
    local Maps = import('/lua/editor/maps.lua')
    local dir, stem = Maps.saveDir, Maps.saveStem
    if not dir or not stem then return 'no saved folder' end
    local folder = string.gsub(string.gsub(dir, '\\', '/'), '^.*/', '')
    Maps.Open('/maps/' .. string.lower(folder) .. '/' .. stem .. '_scenario.lua')
    return 'reopening'
end

local function UnitAt(x, z)
    for _, u in import('/lua/editor/units.lua').All() do
        if Near(u.x, x, 0.5) and Near(u.z, z, 0.5) then return u end
    end
    return nil
end

local function PropAt(x, z)
    for i = 1, ed_prop_count() do
        local bp, px, py, pz = ed_prop_get(i)
        if bp and Near(px, x, 0.05) and Near(pz, z, 0.05) then return i end
    end
    return nil
end

local function DecalAt(x, z)
    for i = 1, ed_decal_count() do
        local t0, t1, kind, dx, dy, dz = ed_decal_get(i)
        if t0 and Near(dx, x, 0.05) and Near(dz, z, 0.05) then return i end
    end
    return nil
end

--- After the reload: the new session and the saved folder are what Setup + case should give.
function Verify(case, afterResize)
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    if afterResize and not R.Saved then return 'WAIT the resized folder is not saved yet' end
    local opts = Cases[case]
    local N = opts.size
    local g = R.Geometry(256, N, opts)
    local w = ed_terrain_info()
    Check((w or 0) - 1 == N, case .. ': the session has a ' .. N .. ' terrain (' .. tostring(w) .. ')')
    local sz = Map.Doc.info.size
    Check(sz and sz[1] == N and sz[2] == N, case .. ': the scenario says ' .. N)
    local function Expect(name, p)
        local x, z = R.MapPoint(g, p[1], p[2])
        return R.Inside(g, x, z), x, z
    end
    -- markers, chain, area
    for _, e in { { 'RESZ_A', 'marker_a' }, { 'RESZ_B', 'marker_b' }, { 'RESZ_C', 'marker_c' } } do
        local inside, x, z = Expect(e[1], POINTS[e[2]])
        local m = Markers()[e[1]]
        if inside then
            Check(m and Near(m.position[1], x, 0.05) and Near(m.position[3], z, 0.05), case .. ': marker ' .. e[1] .. ' at ' .. string.format('%.0f,%.0f', x, z))
        else
            Check(m == nil, case .. ': marker ' .. e[1] .. ' dropped')
        end
    end
    local chain = Map.Doc.save.Chains.RESZ_CH
    local expectChain = 0
    for _, e in { { 'RESZ_A', 'marker_a' }, { 'RESZ_B', 'marker_b' }, { 'RESZ_C', 'marker_c' } } do
        if Expect(e[1], POINTS[e[2]]) then expectChain = expectChain + 1 end
    end
    Check((expectChain == 0 and chain == nil) or (chain and table.getn(chain.Markers) == expectChain), case .. ': the chain has ' .. expectChain .. ' markers')
    local ar = Map.Doc.save.Areas.RESZ_AR
    local ax0, az0, ax1, az1 = R.MapRect(g, AREA[1], AREA[2], AREA[3], AREA[4])
    Check((ax0 == nil and ar == nil) or (ar and Near(ar.rectangle[1], ax0, 0.05) and Near(ar.rectangle[3], ax1, 0.05)), case .. ': the area is cut to the new bounds')
    -- heights, masks, terrain types
    local bx, bz = R.MapPoint(g, 40, 50)
    Check(Near(ed_terrain_get(math.floor(bx + 0.5), math.floor(bz + 0.5)), BUMP.h, 0.3), case .. ': the bump is at its new place (' .. tostring(ed_terrain_get(math.floor(bx + 0.5), math.floor(bz + 0.5))) .. ')')
    if opts.fill == 'level' then
        Check(Near(ed_terrain_get(1, 1), opts.level, 0.2), case .. ': the padding is at the level (' .. tostring(ed_terrain_get(1, 1)) .. ')')
    else
        Check(Near(ed_terrain_get(1, 1), 25, 0.2), case .. ': the ground height is 25 everywhere else')
    end
    local mw, mh = ed_stratum_info()
    local pcell = N / mw
    -- the mask block is 5x5 old mask cells of 2 world units: its middle is at old world (10..20, 12..22) -> centre (25, 29) in a 2-unit grid
    local cx, cz = R.MapPoint(g, (MASK.x0 + 2.5) * 2, (MASK.z0 + 2.5) * 2)
    local mv = ed_stratum_read(MASK.stratum, math.floor(cx / pcell), math.floor(cz / pcell), math.floor(cx / pcell), math.floor(cz / pcell))
    Check(mv and mv[1] and Near(mv[1], MASK.v, 2), case .. ': the paint mask block moved (' .. tostring(mv and mv[1]) .. ')')
    local tw, th = ed_tt_info()
    local tcell = N / tw
    local tx, tz = R.MapPoint(g, TT.x0 + 2.5, TT.z0 + 2.5)
    local tv = ed_tt_read(math.floor(tx / tcell), math.floor(tz / tcell), math.floor(tx / tcell), math.floor(tz / tcell))
    Check(tv and tv[1] == TT.v, case .. ': the terrain type block moved (' .. tostring(tv and tv[1]) .. ')')
    -- props, decals, units
    for _, e in { { 'prop_a', 'prop' }, { 'prop_b', 'prop' } } do
        local inside, x, z = Expect(e[1], POINTS[e[1]])
        Check((PropAt(x, z) ~= nil) == inside, case .. ': ' .. e[1] .. (inside and ' moved' or ' dropped'))
    end
    for _, k in { 'decal_a', 'decal_b' } do
        local inside, x, z = Expect(k, POINTS[k])
        Check((DecalAt(x, z) ~= nil) == inside, case .. ': ' .. k .. (inside and ' moved' or ' dropped'))
    end
    local pin, pax, paz = Expect('prop_a', POINTS.prop_a)
    local pa = pin and PropAt(pax, paz)
    if pa then
        local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(pa)
        Check(Near(2 * math.atan2(qy, qw), 0.5, 0.01) and Near(sz, 3, 0.01), case .. ': prop heading and scale survived')
    end
    for _, k in { 'unit_a', 'unit_b' } do
        local inside, x, z = Expect(k, POINTS[k])
        Check((UnitAt(x, z) ~= nil) == inside, case .. ': ' .. k .. (inside and ' moved' or ' dropped'))
    end
    -- the folder is saved a few seconds after the reload
    local Maps = import('/lua/editor/maps.lua')
    local dir, stem = Maps.saveDir, Maps.saveStem
    Check(dir and stem and ed_file_exists(dir .. '/' .. stem .. '.scmap') and ed_file_exists(dir .. '/' .. stem .. '_save.lua'), case .. ': the new folder exists (' .. tostring(dir) .. ')')
    table.insert(out, 'dirty=' .. tostring(Maps.Dirty()) .. ' saveDir=' .. tostring(dir))
    table.insert(out, failed == 0 and ('ALL PASSED (' .. total .. ' checks)') or (failed .. ' FAILED of ' .. total))
    return table.concat(out, '\n')
end
