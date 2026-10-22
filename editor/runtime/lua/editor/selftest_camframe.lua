-- Self test of the marker looks by type (markervis.lua Style) and of the field-of-view frame of a selected Camera Info marker (camframe.lua). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_camframe.lua').Run()
-- Returns text that starts with PASS or FAIL. The geometry part is pure (no map needed); the last part draws a frame on the open map when there is one.
--
-- Lua 5.0 dialect.

local MV = import('/lua/editor/markervis.lua')
local CF = import('/lua/editor/camframe.lua')
local Tools = import('/lua/editor/tools.lua')
local Map = import('/lua/editor/map.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b, tol)
    return a ~= nil and b ~= nil and math.abs(a - b) <= tol
end

local function Flat(y)
    return function(x, z) return y end
end

function Run()
    out, failed = {}, 0

    -- ---- the look of a marker by type ---------------------------------------------------------------------------------------------------------
    local seen, dup, bad, n = {}, '', '', 0
    for _, t in Tools.MarkerTypes() do
        n = n + 1
        local s = MV.Style(t.name, nil, nil, nil)
        if type(s) ~= 'table' or type(s.prop) ~= 'string' or type(s.scale) ~= 'number' or s.scale <= 0 or not string.find(s.color or '', '^ff%x%x%x%x%x%x$') then
            bad = bad .. t.name .. ' '
        elseif not string.find(s.prop, 'M_Path_prop', 1, true) then
            -- the path nodes have no mesh (the overlay draws them); every other type must be told from the others by mesh, size or tint
            local key = s.prop .. '|' .. s.scale .. '|' .. s.color
            if seen[key] then dup = dup .. t.name .. '=' .. seen[key] .. ' ' end
            seen[key] = t.name
        end
    end
    Check(n > 0 and bad == '', 'every marker type (' .. n .. ') resolves to a prop, a scale and a tint ' .. bad)
    Check(dup == '', 'no two types look alike (mesh, size, tint) ' .. dup)
    local s = MV.Style('Combat Zone', '/env/common/props/markers/M_Blank_prop.bp', 'ff800080', 'Combat Zone 03')
    Check(string.find(s.prop, 'Combatzone', 1, true) ~= nil, 'a loaded Combat Zone marker with the blank prop stored shows the combat zone mesh (' .. s.prop .. ')')
    s = MV.Style('Camera Info', nil, nil, nil)
    Check(string.find(s.prop, 'Camera', 1, true) ~= nil, 'a Camera Info marker shows the camera mesh')
    s = MV.Style('Mass', nil, nil, nil)
    Check(string.find(s.prop, 'Mass', 1, true) ~= nil, 'a Mass marker keeps its mass prop (markervis shows the deposit mesh for it)')
    s = MV.Style('Some Mod Type', '/env/common/props/markers/M_Defensive_prop.bp', 'ff112233', nil)
    Check(string.find(s.prop, 'Defensive', 1, true) ~= nil, 'a type that is not in the table takes the stored prop')
    Check(s.color == 'ff19334c', 'and its stored colour, brightened (' .. tostring(s.color) .. ')')
    s = MV.Style('Some Mod Type', nil, nil, nil)
    Check(string.find(s.prop, 'M_Blank_prop', 1, true) ~= nil, 'a type without a table entry, a stored prop or a template falls back to the blank marker')
    local army = MV.Style('Blank Marker', '/env/common/props/markers/M_Blank_prop.bp', 'ff800080', 'ARMY_2')
    local blank = MV.Style('Blank Marker', '/env/common/props/markers/M_Blank_prop.bp', 'ff800080', 'Marker 01')
    Check(army.scale > blank.scale and army.color ~= blank.color, 'a start position (ARMY_<n>) is bigger and has another tint than a blank marker')
    local before = Tools.Templates()['Blank Marker'] and Tools.Templates()['Blank Marker'].prop
    Check(before == nil or type(before) == 'string', 'Style does not change the templates')

    -- ---- field of view -----------------------------------------------------------------------------------------------------------------------
    local d = 0.017453292519943295
    Check(Near(CF.FovFor(5, 4096), 65 * d, 1e-6) and Near(CF.FovFor(4096, 4096), 60 * d, 1e-6), 'FovFor: 65 degrees at the near zoom, 60 at the largest')
    Check(Near(CF.FovFor(1, 4096), 65 * d, 1e-6) and Near(CF.FovFor(99999, 4096), 60 * d, 1e-6), 'FovFor clamps outside the zoom range')
    local mid = CF.FovFor(100, 4096)
    Check(mid < 65 * d and mid > 60 * d, 'FovFor is in between at a middle zoom (' .. mid / d .. ' degrees)')
    Check(Near(CF.FovFor(100, nil), 60 * d, 1e-6), 'FovFor without a maximum zoom takes the far value')

    -- ---- the frustum on flat ground ---------------------------------------------------------------------------------------------------------------
    local fov, aspect, zoom = CF.FovFor(200, 4096), 16 / 9, 200
    local fx, fy, fz = 500, 10, 500
    local fr = CF.Frustum(fx, fy, fz, 0, 1.0, zoom, fov, aspect)
    local dist = zoom / math.tan(fov / 2) / 2
    local ex, ey, ez = fr.eye[1], fr.eye[2], fr.eye[3]
    Check(Near(fr.dist, dist, 1e-3) and Near(math.sqrt((ex - fx) * (ex - fx) + (ey - fy) * (ey - fy) + (ez - fz) * (ez - fz)), dist, 1e-2), 'the eye is zoom / tan(fov / 2) / 2 from the focus point (' .. dist .. ')')
    Check(Near(ey - fy, dist * math.sin(1.0), 1e-2) and Near(ex, fx, 1e-3) and ez < fz, 'heading 0 looks along +z: the eye is behind (smaller z) and above by distance * sin(pitch)')
    local pts = CF.Corners(fr, Flat(fy), dist * 6 + 400, 600)
    local allGround = true
    for i = 1, 4 do
        local c, r = pts[i], fr.rays[i]
        if c.kind ~= 'ground' or not Near(c[2], fy, 0.05) or not Near(c.t, (ey - fy) / -r[2], 0.05 + c.t * 1e-4) then allGround = false end
    end
    Check(allGround, 'the four corner rays meet the ground at the distance eye height / -ray.y')
    Check(Near(pts[1][1] + pts[2][1], 2 * fx, 0.05) and Near(pts[4][1] + pts[3][1], 2 * fx, 0.05) and Near(pts[1][3], pts[2][3], 0.05) and Near(pts[3][3], pts[4][3], 0.05),
        'the frame is symmetric about the vertical plane through the focus point and the look direction')
    Check(pts[1][3] > pts[4][3] and pts[2][1] - pts[1][1] < 0 and (pts[1][1] - pts[2][1]) > (pts[4][1] - pts[3][1]),
        'the far (top) edge is wider than the near (bottom) edge, and screen right is world -x for heading 0')
    local fxh, fyh, fzh = CF.RayGround(ex, ey, ez, fr.fwd[1], fr.fwd[2], fr.fwd[3], Flat(fy), dist * 6 + 400, 600)
    Check(fxh ~= nil and Near(fxh, fx, 0.05) and Near(fyh, fy, 0.05) and Near(fzh, fz, 0.05), 'the centre ray meets the ground at the focus point')

    -- looking straight down: a rectangle of zoom x zoom / aspect, turned by the heading
    local h = 0.7
    local down = CF.Frustum(fx, fy, fz, h, 1.5707, zoom, fov, aspect)
    local dp = CF.Corners(down, Flat(fy), dist * 6 + 400, 600)
    local w = math.sqrt((dp[2][1] - dp[1][1]) * (dp[2][1] - dp[1][1]) + (dp[2][3] - dp[1][3]) * (dp[2][3] - dp[1][3]))
    local hh = math.sqrt((dp[4][1] - dp[1][1]) * (dp[4][1] - dp[1][1]) + (dp[4][3] - dp[1][3]) * (dp[4][3] - dp[1][3]))
    Check(Near(w, zoom, zoom * 0.01) and Near(hh, zoom / aspect, zoom / aspect * 0.01), 'looking down, the frame is zoom wide and zoom / aspect high (' .. w .. ' x ' .. hh .. ')')
    Check(Near(dp[2][1] - dp[1][1], -math.cos(h) * zoom, 1.5) and Near(dp[2][3] - dp[1][3], math.sin(h) * zoom, 1.5), 'and turned with the heading (right = (-cos h, sin h))')
    Check(Near((dp[1][1] + dp[3][1]) / 2, fx, 1) and Near((dp[1][3] + dp[3][3]) / 2, fz, 1), 'and centred on the focus point')

    -- a narrow window: the fov belongs to the longer side
    local tall = CF.Frustum(fx, fy, fz, 0, 1.0, zoom, fov, 0.5)
    Check(Near(tall.halfH, math.tan(fov / 2), 1e-6) and Near(tall.halfW, math.tan(fov / 2) * 0.5, 1e-6), 'a window taller than wide takes the fov for its height')

    -- sloped ground, the edge of the terrain, rays that meet nothing
    local slope = function(x, z) return 0.2 * x end
    local sx, sy, sz, st, kind = CF.RayGround(0, 100, 0, 0.6, -0.8, 0, slope, 1000, 500)
    Check(sx ~= nil and kind == 'ground' and Near(sy, 0.2 * sx, 0.05), 'a ray meets sloped ground on the slope')
    local edge = function(x, z) if x > 40 then return nil end return 0 end
    local ox, oy, oz, ot, okind = CF.RayGround(0, 50, 0, 0.9, -0.1, 0, edge, 1000, 500)
    Check(ox ~= nil and okind == 'edge' and Near(ox, 40, 0.1), 'a ray that leaves the terrain before it comes down ends at the terrain edge (' .. tostring(ox) .. ')')
    Check(CF.RayGround(0, 50, 0, 0, 1, 0, Flat(0), 1000, 500) == nil, 'a ray that points up meets nothing')
    local low = CF.Frustum(fx, fy, fz, 0, 0.2, zoom, fov, aspect)
    local lp = CF.Corners(low, Flat(fy), 4000, 600)
    Check(lp[1].kind == 'far' and lp[2].kind == 'far' and lp[3].kind == 'ground' and lp[4].kind == 'ground', 'with a low pitch the top corners point above the horizon and get a far point, the bottom ones meet the ground')

    -- ---- on the open map -----------------------------------------------------------------------------------------------------------------------
    if Map.Doc and rawget(_G, 'ed_overlay_set') and rawget(_G, 'ed_overlay_count') then
        local chain = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
        local w0, h0 = ed_terrain_info()
        local cx, cz = math.floor((w0 or 257) / 2), math.floor((h0 or 257) / 2)
        local c0 = ed_overlay_count()
        chain.ZZ_CAM = { type = 'Camera Info', position = { cx, ed_terrain_get(cx, cz) or 0, cz, type = 'VECTOR3' }, orientation = { 0, 1.0, 0, type = 'VECTOR3' }, zoom = 150 }
        Tools.Select('marker', 'ZZ_CAM')
        CF.Update(nil, nil)
        Check(ed_overlay_count() == c0 + 6, 'selecting a Camera Info marker draws its frame: four edges, the outline and the line of sight (' .. (ed_overlay_count() - c0) .. ' lines)')
        CF.Update(nil, nil)
        Check(ed_overlay_count() == c0 + 6, 'a second frame with nothing changed adds nothing')
        Tools.Select(false)
        CF.Update(nil, nil)
        Check(ed_overlay_count() == c0, 'deselecting removes the frame')
        Tools.Select('marker', 'ZZ_CAM')
        CF.Update(nil, nil)
        CF.Forget()
        ed_overlay_remove('camfr:ZZ_CAM:e1') ed_overlay_remove('camfr:ZZ_CAM:e2') ed_overlay_remove('camfr:ZZ_CAM:e3') ed_overlay_remove('camfr:ZZ_CAM:e4')
        ed_overlay_remove('camfr:ZZ_CAM:q') ed_overlay_remove('camfr:ZZ_CAM:c')
        chain.ZZ_CAM = nil
        Tools.Select(false)
        CF.Update(nil, nil)
        Check(ed_overlay_count() == c0, 'the test marker and its lines are gone')
    else
        table.insert(out, '  skip no map open, or no overlay natives in this engine')
    end

    table.insert(out, 1, (failed == 0 and 'PASS' or 'FAIL') .. ' camframe: ' .. failed .. ' failed')
    return table.concat(out, '\n')
end
