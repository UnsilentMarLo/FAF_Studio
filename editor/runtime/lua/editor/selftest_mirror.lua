-- Mirror self test (units, decals, the whole half). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_mirror.lua').Run()
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local H = import('/lua/editor/history.lua')
local Sym = import('/lua/editor/symmetry.lua')
local MH = import('/lua/editor/mirrorhalf.lua')
local Mirror = import('/lua/editor/mirror.lua')

local out, failed, total = {}, 0, 0
Verbose = false

local function Check(ok, text)
    total = total + 1
    if not ok or Verbose then table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text) end
    if not ok then failed = failed + 1 end
end

local function Near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.01) end

local function Markers() return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end

local function FindProp(x, z)
    for i = 1, ed_prop_count() do
        local bp, px, py, pz, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
        if bp and Near(px, x, 0.05) and Near(pz, z, 0.05) then return i, 2 * math.atan2(qy, qw), sx, sy, sz end
    end
    return nil
end

local function FindDecal(x, z)
    for i = 1, ed_decal_count() do
        local t0, t1, kind, dx, dy, dz, sx, sy, sz, ox, oy, oz = ed_decal_get(i)
        if t0 and Near(dx, x, 0.05) and Near(dz, z, 0.05) then return i, oy, sx end
    end
    return nil
end

local function FindUnit(x, z)
    for _, u in import('/lua/editor/units.lua').All() do
        if Near(u.x, x, 0.1) and Near(u.z, z, 0.1) then return u end
    end
    return nil
end

local function FindMarker(x, z)
    for name, m in Markers() do
        if m.position and Near(m.position[1], x, 0.1) and Near(m.position[3], z, 0.1) then return name, m end
    end
    return nil
end

local function Finish()
    table.insert(out, failed == 0 and ('ALL PASSED (' .. total .. ' checks)') or (failed .. ' FAILED of ' .. total))
    return table.concat(out, '\n')
end

local function Regions()
    -- every mode: a sampled point is in exactly one region or on an axis, and its images are in other regions
    local modes = { 'mirror_x', 'mirror_z', 'mirror_xz', 'rot2', 'rot4', 'diag', 'diag_both' }
    for _, mode in modes do
        Sym.Mode = mode
        local sectors = MH.Sectors()
        local want = (mode == 'mirror_x' or mode == 'mirror_z' or mode == 'rot2' or mode == 'diag') and 2 or 4
        Check(table.getn(sectors) == want, mode .. ': ' .. want .. ' regions')
        local bad, badImage = 0, 0
        for x = 7, 250, 31 do
            for z = 11, 250, 29 do
                local inside = 0
                local which
                for i, s in sectors do if MH.InSector(s, x, z) then inside = inside + 1 which = i end end
                if inside > 1 then bad = bad + 1 end
                if inside == 1 then
                    local pts = Sym.Points(x, z)
                    for k = 2, table.getn(pts) do
                        local q = pts[k]
                        local back = nil
                        for i, s in sectors do if MH.InSector(s, q.x, q.z) then back = i end end
                        if back == nil or back == which then badImage = badImage + 1 end
                    end
                end
            end
        end
        Check(bad == 0, mode .. ': no point is in two regions')
        Check(badImage == 0, mode .. ': the images of a point lie in the other regions (' .. badImage .. ' wrong)')
        local poly = MH.Polygon(sectors[1])
        Check(table.getn(poly) >= 9, mode .. ': the region has a polygon (' .. table.getn(poly) / 3 .. ' corners)')
    end
    Sym.Mode = 'off'
end

function Run()
    out, failed, total = {}, 0, 0
    if not Map.Doc then Map.Load() end
    local doc = Map.Doc
    local depth0 = H.Depth()
    local Units = import('/lua/editor/units.lua')
    local Props = import('/lua/editor/props.lua')
    local Decals = import('/lua/editor/decals.lua')
    local savedMode, savedCx, savedCz = Sym.Mode, Sym.CenterX, Sym.CenterZ
    local savedUnits = { Units.Group, Units.Active, Units.ArmyName }
    Regions()
    -- bulk removal of props
    do
        local PB = import('/lua/editor/propbulk.lua')
        local c0 = ed_prop_count()
        for i = 1, 40 do Map.AddProp('/env/common/props/markers/M_Blank_prop.bp', 10 + i, 25, 230, 0, 1) end
        local list = {}
        for i = c0 + 1, c0 + 40, 2 do table.insert(list, i) end
        table.insert(list, c0 + 1) table.insert(list, 99999999)        -- a duplicate and a number out of range are ignored
        local removed = PB.Remove(list)
        Check(removed == 20 and ed_prop_count() == c0 + 20, 'propbulk removes the listed props in one call (' .. tostring(removed) .. ')')
        local left = 0
        for i = c0 + 1, ed_prop_count() do
            local bp, x = ed_prop_get(i)
            if bp and math.mod(math.floor(x + 0.5) - 10, 2) == 0 then left = left + 1 end
        end
        Check(left == 20, 'the right half is left (' .. left .. ')')
        for i = ed_prop_count(), c0 + 1, -1 do Map.RemoveProp(i) end
    end

    Sym.Mode = 'mirror_x'
    Sym.CenterX, Sym.CenterZ = 128, 128
    -- other self tests leave objects behind: count against what is there already
    local allCats = { markers = true, areas = true, props = true, decals = true, units = true }
    local base = MH.Plan({ sector = 1, cats = allCats, mode = 'add' })
    local baseR = MH.Plan({ sector = 1, cats = allCats, mode = 'replace' })
    -- start positions of two armies, mirror images of each other
    Tools.PlaceMarker(60, 128, 'Blank Marker', 'ARMY_2')
    Tools.PlaceMarker(196, 128, 'Blank Marker', 'ARMY_3')
    pcall(function() import('/lua/editor/armies.lua').Sync(doc) end)
    Check(doc.save.Armies.ARMY_2 ~= nil and doc.save.Armies.ARMY_3 ~= nil, 'two armies exist')
    local before = H.Depth()
    Tools.PlaceMarker(50, 100, 'Blank Marker', 'MH_A')
    Markers().MH_A.orientation = { 0, 0.4, 0, type = 'VECTOR3' }
    Tools.PlaceMarker(128, 60, 'Blank Marker', 'MH_AXIS')
    Tools.PlaceMarker(210, 40, 'Blank Marker', 'MH_EAST')
    doc.save.Areas.MH_AR = { rectangle = { 20, 20, 60, 60, type = 'RECTANGLE' } }
    Map.AddProp('/env/common/props/markers/M_Blank_prop.bp', 40, 25, 40, 0.5, { 1, 2, 3 })
    Map.AddProp('/env/common/props/markers/M_Blank_prop.bp', 200, 25, 100, 0, 1)         -- an east prop (replaced in the second run)
    Map.AddDecal('mh_decal.dds', 'albedo', 30, 25, 200, 0.7, 12, 800)
    Units.ArmyName, Units.Group, Units.Active = 'ARMY_2', 'MHG', 'uel0106'
    Sym.Mode = 'off'              -- (the unit tool places the symmetry images too)
    Units.Place(60, 130)
    Sym.Mode = 'mirror_x'
    local u = FindUnit(60, 130)
    Check(u ~= nil, 'a test unit was placed')
    if u then Units.Selection = { { army = u.army, name = u.name } } Units.SetHeading(math.deg(0.3)) Units.Selection = {} end

    -- plan
    local sectors = MH.Sectors()
    local plan = MH.Plan({ sector = 1, cats = { markers = true, areas = true, props = true, decals = true, units = true }, mode = 'add' })
    Check(not plan.error and plan.nSource == base.nSource + 5, 'the plan finds the objects of the west half (' .. tostring(plan.nSource) .. ')')
    local hasA, hasAxis = false, false
    for _, n in plan.source.markers do if n == 'MH_A' then hasA = true end if n == 'MH_AXIS' or string.find(n, '^ARMY_') then hasAxis = true end end
    Check(hasA and not hasAxis, 'start positions and axis markers are not copied')
    Check(plan.images == base.images + 5, 'five more images (' .. tostring(plan.images) .. ')')
    Check(Sym.Mode == 'mirror_x' and MH.Plan({ sector = 9 }).error ~= nil, 'a missing region is an error')

    -- add, armies mapped
    local d1 = H.Depth()
    local made, removed = MH.Run({ sector = 1, cats = { markers = true, areas = true, props = true, decals = true, units = true }, mode = 'add', armies = 'map' })
    Check(made == plan.images and removed == 0, 'the planned copies are made (' .. tostring(made) .. ')')
    Check(H.Depth() == d1 + 1, 'the whole run is one undo step')
    local nm, m = FindMarker(206, 100)
    Check(nm ~= nil and Near(m.orientation[2], -0.4, 0.001), 'the marker copy is at the image with its heading mirrored')
    Check(m and m.adjacentTo == nil, 'a copy has no adjacency')
    local ai, ah, sx, sy, sz = FindProp(216, 40)
    Check(ai ~= nil and Near(ah, -0.5, 0.001) and Near(sz, 3, 0.001) and Near(sy, 2, 0.001), 'the prop copy keeps its scale and has its heading mirrored')
    local di, doy = FindDecal(226, 200)
    Check(di ~= nil and Near(doy, -0.7, 0.001), 'the decal copy has its rotation mirrored')
    local ar = nil
    for name, a in doc.save.Areas do
        if string.find(name, '^MH_AR_') and Near(a.rectangle[1], 196, 0.01) and Near(a.rectangle[3], 236, 0.01) then ar = name end
    end
    Check(ar ~= nil, 'the area copy is the mirrored rectangle')
    local mu = FindUnit(196, 130)
    Check(mu ~= nil and mu.army == 'ARMY_3' and Near(mu.heading, -0.3, 0.001), 'the unit copy belongs to the mirrored start position\'s army with its heading mirrored')
    H.Undo()
    Check(FindMarker(206, 100) == nil and FindProp(216, 40) == nil and FindDecal(226, 200) == nil and FindUnit(196, 130) == nil, 'undo removes every copy')
    local depth = H.Depth()
    H.Redo()
    Check(FindMarker(206, 100) ~= nil and FindProp(216, 40) ~= nil and FindDecal(226, 200) ~= nil and FindUnit(196, 130) ~= nil, 'redo brings every copy back')
    H.Undo()

    -- army kept
    MH.Run({ sector = 1, cats = { units = true }, mode = 'add', armies = 'keep' })
    local ku = FindUnit(196, 130)
    Check(ku ~= nil and ku.army == 'ARMY_2', 'with the army kept the copy stays with its army')
    H.Undo()

    -- replace: the east side is emptied first
    local before2 = ed_prop_count()
    local made2, removed2 = MH.Run({ sector = 1, cats = { markers = true, areas = true, props = true, decals = true, units = true }, mode = 'replace', armies = 'map' })
    Check(removed2 == baseR.nOthers + 2 and made2 == plan.images, 'replace removes what is in the east (' .. tostring(removed2) .. ') and copies the west (' .. tostring(made2) .. ')')
    Check(FindProp(200, 100) == nil and FindMarker(210, 40) == nil, 'the east prop and marker are gone')
    Check(Markers().ARMY_3 ~= nil and Markers().MH_AXIS ~= nil, 'start positions and axis objects stay')
    H.Undo()
    Check(FindProp(200, 100) ~= nil and FindMarker(210, 40) ~= nil and FindProp(216, 40) == nil, 'undo of a replace brings the east back and removes the copies')

    -- the selection (Edit > Mirror selection) now follows units and decals
    Units.Selection = {}
    local su = FindUnit(60, 130)
    Units.Selection = { { army = su.army, name = su.name } }
    Decals.Selection = {}
    local di2 = FindDecal(30, 200)
    local t0 = ed_decal_get(di2)
    Decals.Selection = { { tex = t0, x = 30, z = 200 } }
    MH.ArmyMode = 'map'
    local n = Mirror.Mirror()
    Check(n == 2, 'Mirror selection copies the selected unit and decal (' .. tostring(n) .. ')')
    local su2 = FindUnit(196, 130)
    Check(su2 ~= nil and su2.army == 'ARMY_3', 'the selected unit goes to the mirrored army')
    Check(FindDecal(226, 200) ~= nil, 'the selected decal is mirrored')
    H.Undo()
    Check(FindUnit(196, 130) == nil and FindDecal(226, 200) == nil, 'and both are one undo step')
    MH.ArmyMode = 'keep'
    Units.Selection = {}
    Decals.Selection = {}

    -- clean up
    UndoAllTo(before)
    for _, name in { 'ARMY_2', 'ARMY_3', 'MH_A', 'MH_AXIS', 'MH_EAST' } do Markers()[name] = nil end
    doc.save.Areas.MH_AR = nil
    for k, _ in doc.save.Areas do if string.find(k, '^MH_AR_') then doc.save.Areas[k] = nil end end
    for i = ed_prop_count(), 1, -1 do
        local bp, x, y, z = ed_prop_get(i)
        if bp and (Near(x, 40, 0.1) or Near(x, 200, 0.1)) then Map.RemoveProp(i) end
    end
    for i = ed_decal_count(), 1, -1 do
        local t = ed_decal_get(i)
        if t == 'mh_decal.dds' then Map.RemoveDecal(i) end
    end
    local ux = FindUnit(60, 130)
    if ux then Units.Selection = { { army = ux.army, name = ux.name } } Units.DeleteSelected() end
    Units.Selection = {}
    pcall(function() import('/lua/editor/armies.lua').Sync(doc) end)
    Units.Group, Units.Active, Units.ArmyName = savedUnits[1], savedUnits[2], savedUnits[3]
    Sym.Mode, Sym.CenterX, Sym.CenterZ = savedMode, savedCx, savedCz
    return Finish()
end

function UndoAllTo(depth)
    while H.Depth() > depth do H.Undo() end
end
