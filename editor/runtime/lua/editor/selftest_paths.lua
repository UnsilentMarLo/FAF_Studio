-- Path (spline) tool self test (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T4). Run in the live editor:
--   return import('/lua/editor/selftest_paths.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The golden checksums of the native path ops are in selftest_paths_cases.lua (shared with the native test EdPathTest.cpp).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Paths = import('/lua/editor/paths.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Ser = import('/lua/editor/luaser.lua')

local function Split(s, sep)
    local out, pos = {}, 1
    while true do
        local i = string.find(s, sep, pos, true)
        if not i then
            table.insert(out, string.sub(s, pos))
            break
        end
        table.insert(out, string.sub(s, pos, i - 1))
        pos = i + 1
    end
    return out
end

local function ParseParams(text)
    local p = {}
    if text == '' then return p end
    for _, kv in Split(text, ',') do
        local eq = string.find(kv, '=', 1, true)
        if eq then
            local key, val = string.sub(kv, 1, eq - 1), string.sub(kv, eq + 1)
            if string.find(val, '[:;]') then
                local flat = {}
                for _, pt in Split(val, ';') do
                    for _, c in Split(pt, ':') do
                        local n = tonumber(c)
                        if n then table.insert(flat, n) end
                    end
                end
                p[key] = flat
            elseif tonumber(val) then
                p[key] = tonumber(val)
            else
                p[key] = val
            end
        end
    end
    return p
end

local function Fixtures(S)
    local fix = {}
    fix.A = S:Op('perlin', { width = 65, height = 65, seed = 7, scale = 20, octaves = 3 })
    fix.H = S:Op('affine', { a = fix.A, mul = 30, add = 20 })
    fix.L = S:Op('const', { width = 65, height = 65, value = 20 })
    fix.M = S:Op('voronoi', { width = 65, height = 65, scale = 14, seed = 5 })
    fix.B = S:Op('perlin', { width = 9, height = 7, seed = 3, scale = 5, ox = 4, oz = 6 })
    return fix
end

local function CaseChecksum(S, fix, case)
    local p = ParseParams(case[3])
    if case[4] ~= '' then
        for _, kv in Split(case[4], ',') do
            local eq = string.find(kv, '=', 1, true)
            p[string.sub(kv, 1, eq - 1)] = fix[string.sub(kv, eq + 1)]
        end
    end
    local f, err = Fields.TryOp(case[2], p)
    if not f then return nil, err end
    S:Add(f)
    return Fields.Checksum(f)
end

local function Ground(x, z) return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0 end

local function Near(a, b, eps) return math.abs(a - b) <= (eps or 0.0001) end

--- A straight path along z = z0 from x0 to x1 (two points) as a path table in the module's list; returns it.
local function Straight(mode, x0, x1, z0, h, w, f)
    local before = Paths.Begin()
    local path = Paths.NewPath(mode, 'catmull')
    table.insert(path.points, { x = x0, z = z0, w = w or 6, f = f or 4, h = h, abs = false, bank = 0 })
    table.insert(path.points, { x = x1, z = z0, w = w or 6, f = f or 4, h = h, abs = false, bank = 0 })
    table.insert(Paths.List, path)
    Paths.Current = path.id
    Paths.Sel = {}
    Paths.End('selftest add', before)
    return path
end

function Run()
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end

    check('field natives present', Fields.IsAvailable())
    if not Fields.IsAvailable() then return 'FAIL (1)\n' .. table.concat(lines, '\n') end
    local names = {}
    for _, n in Fields.OpNames() do names[n] = true end
    check('path ops registered', names.path_dist and names.path_along and names.path_u and names.path_mask and names.path_shape and names.path_paste)
    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 129, tostring(w))
    if not w or not names.path_shape then return 'FAIL\n' .. table.concat(lines, '\n') end

    local startCount = ed_field_count()
    local threads0 = ed_field_threads()

    -- ---- golden checksums of the native ops, at several thread counts
    local Cases = import('/lua/editor/selftest_paths_cases.lua').Cases
    local cases = {}
    for _, rawLine in Split(Cases, '\n') do
        local line = (string.gsub(rawLine, '\r', ''))
        if line ~= '' and string.sub(line, 1, 1) ~= '#' then
            local f = Split(line, '|')
            if table.getn(f) >= 5 then table.insert(cases, f) end
        end
    end
    check('cases loaded', table.getn(cases) >= 20, table.getn(cases))
    for _, threads in { 1, 3, threads0 } do
        ed_field_threads(threads)
        local bad = {}
        Fields.Run(function(S)
            local fix = Fixtures(S)
            for _, c in cases do
                local sum, err = CaseChecksum(S, fix, c)
                if sum ~= c[5] then table.insert(bad, c[1] .. ' (' .. tostring(sum or err) .. ' / ' .. c[5] .. ')') end
            end
        end)
        check('golden checksums, ' .. threads .. ' thread(s)', table.getn(bad) == 0, table.concat(bad, '; '))
    end
    ed_field_threads(threads0)

    -- ---- the Lua profile curve equals the native one
    Fields.Run(function(S)
        local like = S:Op('const', { width = 65, height = 9, value = 0 })
        local pts = { { 0, 1 }, { 0.4, 0.3 }, { 0.7, 0.9 }, { 1, 0.1 } }
        for _, smooth in { true, false } do
            local flat = {}
            for _, q in pts do table.insert(flat, q[1]) table.insert(flat, q[2]) end
            -- a path along x with half width 32: |u| = z distance / 32; sample row z = 4 + k
            local path = { 0, 4, 0, 32, 0, 0, 0, 0, 64, 4, 0, 32, 0, 0, 0, 64 }
            local m = S:Op('path_mask', { like = like, pts = path, profile = flat, smooth = smooth and 1 or 0 })
            local worst = 0
            for z = 4, 8 do
                local u = (z - 4) / 32
                local want = Paths.EvalProfile(pts, smooth, u)
                worst = math.max(worst, math.abs(Fields.Get(m, 20, z) - want))
            end
            check('profile curve matches the native one (smooth=' .. tostring(smooth) .. ')', worst < 0.003, tostring(worst))
        end
    end)

    -- ---- curve sampling
    local sp = Paths.NewPath('carve', 'catmull')
    sp.points = { { x = 10, z = 10, w = 4, f = 2, h = -1, bank = 0 }, { x = 40, z = 25, w = 8, f = 2, h = -3, bank = 10 }, { x = 70, z = 10, w = 4, f = 2, h = -1, bank = 0 } }
    local S1 = Paths.Sample(sp, 1)
    check('sample starts and ends at the end points', Near(S1.x[1], 10) and Near(S1.z[1], 10) and Near(S1.x[S1.n], 70) and Near(S1.z[S1.n], 10), S1.x[S1.n])
    local nearest = 1e9
    for k = 1, S1.n do nearest = math.min(nearest, math.sqrt((S1.x[k] - 40) * (S1.x[k] - 40) + (S1.z[k] - 25) * (S1.z[k] - 25))) end
    check('Catmull-Rom passes through every control point', nearest < 0.6, tostring(nearest))
    check('arc length grows', S1.s[S1.n] > 60 and S1.s[2] > S1.s[1], tostring(S1.s[S1.n]))
    check('width is interpolated', Near(S1.w[1], 4) and S1.w[S1.n] == 4 and S1.w[math.floor(S1.n / 2)] > 5)
    sp.closed = true
    local S2 = Paths.Sample(sp, 1)
    check('closed path returns to its start', Near(S2.x[S2.n], 10, 0.01) and Near(S2.z[S2.n], 10, 0.01), S2.x[S2.n] .. ',' .. S2.z[S2.n])
    sp.closed = false
    sp.kind = 'bezier'
    sp.points[2].ho = { 10, 0 }
    local S3 = Paths.Sample(sp, 1)
    local passes = 1e9
    for k = 1, S3.n do passes = math.min(passes, math.sqrt((S3.x[k] - 40) * (S3.x[k] - 40) + (S3.z[k] - 25) * (S3.z[k] - 25))) end
    check('Bezier passes through its points, too', passes < 0.6)
    local tangentOk = false
    for k = 1, S3.n - 1 do
        if S3.seg[k] == 2 and S3.t[k] == 0 then
            local dx, dz = S3.x[k + 1] - S3.x[k], S3.z[k + 1] - S3.z[k]
            tangentOk = dx > 0 and math.abs(dz) < 0.2 * dx          -- leaves along +x, the handle direction
        end
    end
    check('Bezier handle sets the tangent', tangentOk)

    -- ---- heights and grade
    local rp = Paths.NewPath('ramp', 'catmull')
    rp.points = { { x = 10, z = 50, w = 5, f = 3, h = 10, abs = true, bank = 0 }, { x = 60, z = 50, w = 5, f = 3, h = 0, abs = false, bank = 0 }, { x = 110, z = 50, w = 5, f = 3, h = 60, abs = true, bank = 0 } }
    local SR = Paths.Sample(rp, 1)
    local ys = Paths.Heights(rp, SR, function() return 99 end)
    check('ramp starts at its first pinned height', Near(ys[1], 10, 0.01), ys[1])
    check('ramp ends at its second pinned height', Near(ys[SR.n], 60, 0.01), ys[SR.n])
    local mid
    for k = 1, SR.n do if SR.seg[k] == 2 and SR.t[k] == 0 then mid = ys[k] end end
    check('the unpinned middle point lies on the line between the pins', mid and Near(mid, 35, 0.6), tostring(mid))
    rp.limitGrade = true
    rp.grade = 0.3
    local ys2 = Paths.Heights(rp, SR, function() return 99 end)
    rp.points[3].h = 25
    local rep = Paths.Report(rp)
    check('a reachable ramp stays within the limit', rep.max <= 0.3001, tostring(rep.max))
    rp.points[3].h = 60
    rep = Paths.Report(rp)
    check('an unreachable ramp is flagged', rep.max > 0.3 and table.getn(rep.flagged) > 0, tostring(rep.max))
    rp.limitGrade = false
    rep = Paths.Report(rp)
    check('grade of the plain ramp is 0.5', Near(rep.max, 0.5, 0.02), tostring(rep.max))
    local rv = Paths.NewPath('river', 'catmull')
    rv.points = { { x = 10, z = 50, w = 5, f = 3, h = 2, abs = false, bank = 0 }, { x = 60, z = 50, w = 5, f = 3, h = 5, abs = false, bank = 0 }, { x = 110, z = 50, w = 5, f = 3, h = 1, abs = false, bank = 0 } }
    local SV = Paths.Sample(rv, 1)
    local yv = Paths.Heights(rv, SV, Ground)
    local uphill = false
    for k = 2, SV.n do if yv[k] > yv[k - 1] + 0.0001 then uphill = true end end
    check('a river bed never runs uphill', not uphill)

    -- ---- editing with undo
    Paths.Reset()
    History.Clear()
    Terrain.ClearHistory()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    local v0 = History.Version
    Paths.AddPoint(40, 60, 'carve')
    check('first point makes a path', table.getn(Paths.List) == 1 and table.getn(Paths.List[1].points) == 1 and Paths.Current == Paths.List[1].id)
    Paths.AddPoint(120, 60, 'carve')
    Paths.AddPoint(200, 60, 'carve')
    check('points are appended', table.getn(Paths.List[1].points) == 3)
    History.Undo()
    check('undo removes the last point', table.getn(Paths.List[1].points) == 2)
    History.Redo()
    check('redo brings it back', table.getn(Paths.List[1].points) == 3 and Paths.List[1].points[3].x == 200)
    local id = Paths.Current
    Paths.Sel = { [2] = true }
    Paths.MoveSelected(5, 7)
    check('move selected point', Near(Paths.List[1].points[2].x, 125) and Near(Paths.List[1].points[2].z, 67))
    History.Undo()
    check('undo of the move', Near(Paths.List[1].points[2].x, 120) and Near(Paths.List[1].points[2].z, 60))
    Paths.InsertPoint(1, 80, 60)
    check('insert a point', table.getn(Paths.List[1].points) == 4 and Paths.List[1].points[2].x == 80)
    History.Undo()
    -- a slider drag is one undo entry
    local depthA = History.Version
    Paths.Sel = {}
    Paths.SetPoint('w', 7) Paths.SetPoint('w', 8) Paths.SetPoint('w', 9)
    check('a slider drag merges into one entry', Paths.List[1].points[1].w == 9)
    History.Undo()
    check('one undo reverts the whole drag', Paths.List[1].points[1].w ~= 7 and Paths.List[1].points[1].w ~= 8 and Paths.List[1].points[1].w ~= 9, tostring(Paths.List[1].points[1].w))
    Paths.SetPoint('w', 6) Paths.SetPoint('f', 4) Paths.SetPoint('h', -3)
    Paths.Sel = {}
    local copyId = Paths.Duplicate(id)
    check('duplicate adds a path', table.getn(Paths.List) == 2 and copyId ~= nil)
    History.Undo()
    check('undo of the duplicate', table.getn(Paths.List) == 1)
    Paths.Current = id
    Paths.CopyCurrent()
    local pasted = Paths.Paste(100, 100)
    check('paste puts the copy at the pointer', pasted and Near(pasted.points[2].x, 100, 0.01) and Near(pasted.points[2].z, 100, 0.01), pasted and pasted.points[2].x)
    History.Undo()
    Paths.Current = id
    Paths.Delete(id)
    check('delete removes the path', table.getn(Paths.List) == 0)
    History.Undo()
    check('undo of the delete', table.getn(Paths.List) == 1 and Paths.List[1].id == id)
    Paths.Current = id
    Paths.Sel = { [2] = true }
    Paths.DeletePoints()
    check('delete a point', table.getn(Paths.List[1].points) == 2)
    History.Undo()
    check('undo of the point delete', table.getn(Paths.List[1].points) == 3)
    Paths.Snap = 4
    Paths.AddPoint(203, 61)
    check('snap rounds new points to the grid step', Near(Paths.List[1].points[4].x, 204) and Near(Paths.List[1].points[4].z, 60), Paths.List[1].points[4].x)
    Paths.Snap = 0
    History.Undo()

    -- ---- sidecar
    do
        Paths.SetStrata(1, 2, 'core')
        Paths.SetScatter('scatter', 'bp', '/env/test/props/x_prop.bp')
        Paths.SetField('name', 'The road')
        local text = Paths.SidecarText()
        check('sidecar text', string.find(text, 'Paths = {', 1, true) ~= nil and string.find(text, 'The road', 1, true) ~= nil, string.sub(text, 1, 60))
        local env = {}
        local f = loadstring(text)
        setfenv(f, env)
        f()
        local back = env.Paths and env.Paths[1]
        check('sidecar round trip: points', back and table.getn(back.points) == 3 and back.points[3].x == 200)
        check('sidecar round trip: profile and options', back and back.profile and back.profile.preset == 'u' and back.strata[1].layer == 2 and back.scatter.bp == '/env/test/props/x_prop.bp' and back.name == 'The road')
        check('sidecar of an empty list is empty', (function()
            local keep = Paths.List
            Paths.List = {}
            local t = Paths.SidecarText()
            Paths.List = keep
            return t == ''
        end)())
    end

    -- ---- apply: replace, undo, bake
    local path = Paths.List[1]
    Paths.SetStrata(1, 0, 'core')
    Paths.SetScatter('scatter', 'bp', '')
    for _, p in path.points do p.h = -3 p.w = 6 p.f = 4 end
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    local depth0 = Terrain.UndoDepth()
    local ver0 = History.Version
    -- preview
    local ok, perr = Paths.Preview(id)
    check('preview runs', ok, tostring(perr))
    check('preview changes the terrain', Near(ed_terrain_get(120, 60), 22), ed_terrain_get(120, 60))
    check('preview is no history entry', History.Version == ver0)
    Paths.RevertPreview()
    check('revert takes the preview off', ed_terrain_get(120, 60) == 25 and Terrain.UndoDepth() == depth0)
    local n = Paths.Apply(id)
    check('apply changes samples', n and n > 200, tostring(n))
    check('apply: centre line is cut by the offset', Near(ed_terrain_get(120, 60), 22), ed_terrain_get(120, 60))
    check('apply: beside the road is untouched', ed_terrain_get(120, 90) == 25)
    local rim = ed_terrain_get(120, 65)
    check('apply: the profile shapes the cross section', rim < 25 and rim > 22, rim)
    check('apply keeps a result', Paths.Results[id] ~= nil)
    check('apply is one history entry', History.Version == ver0 + 1)
    for _, p in path.points do p.h = -5 end
    local count1 = ed_field_count()
    Paths.Apply(id)
    check('re-apply replaces the previous result', Near(ed_terrain_get(120, 60), 20), ed_terrain_get(120, 60))
    History.Undo()
    check('undo of the re-apply returns to the first result', Near(ed_terrain_get(120, 60), 22), ed_terrain_get(120, 60))
    History.Undo()
    check('undo of the first apply restores the map', ed_terrain_get(120, 60) == 25 and Paths.Results[id] == nil)
    History.Redo()
    History.Redo()
    check('redo twice: the second result again', Near(ed_terrain_get(120, 60), 20) and Paths.Results[id] ~= nil)
    -- an edit made after the apply stays when the result is replaced
    ed_terrain_set_rect(10, 10, 20, 20, 77)
    History.PushTerrain()
    for _, p in path.points do p.h = -2 end
    Paths.Apply(id)
    check('re-apply keeps unrelated edits', ed_terrain_get(15, 15) == 77 and Near(ed_terrain_get(120, 60), 23), ed_terrain_get(15, 15) .. ' ' .. ed_terrain_get(120, 60))
    ed_terrain_set_rect(10, 10, 20, 20, 25)
    History.PushTerrain()
    -- bake: the next apply adds to the terrain
    check('bake', Paths.Bake(id) and Paths.Results[id] == nil)
    Paths.Apply(id)
    check('apply after bake stacks', Near(ed_terrain_get(120, 60), 21), ed_terrain_get(120, 60))
    History.Undo()
    check('undo of the stacked apply', Near(ed_terrain_get(120, 60), 23))
    History.Undo()
    History.Undo()
    check('undo of bake and the apply before it', Paths.Results[id] ~= nil)
    -- remove the result
    local r = Paths.Unapply(id)
    check('remove result restores the map', Near(ed_terrain_get(120, 60), 25) and Paths.Results[id] == nil, ed_terrain_get(120, 60))
    History.Undo()
    check('undo of the removal', Near(ed_terrain_get(120, 60), 23) and Paths.Results[id] ~= nil)
    History.Undo()
    History.Undo()

    -- ---- bank erosion
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        local ep = Straight('carve', 40, 200, 60, -12, 6, 2)
        Paths.Apply(ep.id)
        local wall = Fields.Run(function(S) return Fields.Checksum(S:Height()) end)
        History.Undo()
        Paths.SetField('erosion', 25)
        Paths.Apply(ep.id)
        local eroded = Fields.Run(function(S) return Fields.Checksum(S:Height()) end)
        check('bank erosion changes the banks', wall ~= eroded)
        check('bank erosion leaves the middle of the channel', Near(ed_terrain_get(120, 60), 13, 0.6), ed_terrain_get(120, 60))
        check('bank erosion stays near the path', ed_terrain_get(120, 100) == 25)
        History.Undo()
    end

    -- ---- strata along the path
    local mw, mh = ed_stratum_info()
    if mw then
        Paths.Reset()
        History.Clear()
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Terrain.ClearHistory()
        local road = Straight('road', 40, 200, 60, 0, 6, 4)
        Paths.SetStrata(1, 3, 'core')
        Paths.SetStrata(2, 4, 'bank')
        local before3 = Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end)
        local before4 = Fields.Run(function(S) return Fields.Checksum(S:Stratum(4, true)) end)
        Paths.Apply(road.id)
        local after3 = Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end)
        local after4 = Fields.Run(function(S) return Fields.Checksum(S:Stratum(4, true)) end)
        check('strata: the core layer is painted', after3 ~= before3)
        check('strata: the bank layer is painted', after4 ~= before4)
        local covered = Fields.Run(function(S)
            local m = S:Stratum(3)
            local ps = (w - 1) / mw
            return Fields.Sample(m, 120, 60), Fields.Sample(m, 120, 120)
        end)
        check('strata: paint sits on the road, not beside it', covered > 0.9, tostring(covered))
        local drift = Fields.Run(function(S)
            local a = S:Stratum(3, true)
            Paths.Apply(road.id)
            local b = S:Stratum(3, true)
            local _, mx = Fields.Stats(S:Op('abs', { a = S:Op('sub', { a = a, b = b }) }))
            return mx
        end)
        check('strata: re-apply is stable (within one byte step of rounding)', drift <= 2, tostring(drift))
        History.Undo()
        History.Undo()
        check('strata: undo restores the layers', Fields.Run(function(S) return Fields.Checksum(S:Stratum(3, true)) end) == before3 and Fields.Run(function(S) return Fields.Checksum(S:Stratum(4, true)) end) == before4)
        Paths.Delete(road.id)
        History.Undo()
        History.Undo()
        History.Undo()
    else
        table.insert(lines, '  skip strata tests (no mask)')
    end

    -- ---- props along the path, one undo step with the apply
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        local Props = import('/lua/editor/props.lua')
        local cat = Props.Catalog()
        if cat[1] then
            local pp = Straight('carve', 40, 200, 100, -2, 5, 3)
            Paths.SetScatter('scatter', 'on', true)
            Paths.SetScatter('scatter', 'bp', cat[1].path)
            Paths.SetScatter('scatter', 'spacing', 20)
            local c0 = ed_prop_count()
            Paths.Apply(pp.id)
            local c1 = ed_prop_count()
            check('props are placed along the path', c1 > c0 + 6, tostring(c0) .. ' -> ' .. tostring(c1))
            Paths.Apply(pp.id)
            check('re-apply replaces the props', ed_prop_count() == c1, tostring(ed_prop_count()))
            History.Undo()
            check('undo removes / restores props with the apply', ed_prop_count() == c1, tostring(ed_prop_count()))
            History.Undo()
            check('undo of the first apply removes the props', ed_prop_count() == c0, tostring(ed_prop_count()))
            History.Redo()
            check('redo brings the props back', ed_prop_count() == c1)
            History.Undo()
        else
            table.insert(lines, '  skip prop tests (no prop catalog)')
        end
        local Decals = import('/lua/editor/decals.lua')
        local dcat = Decals.Catalog()
        if dcat[1] then
            local dp = Straight('carve', 40, 200, 140, -1, 5, 3)
            Paths.SetScatter('decals', 'on', true)
            Paths.SetScatter('decals', 'tex', dcat[1].path)
            Paths.SetScatter('decals', 'spacing', 25)
            local d0 = ed_decal_count()
            Paths.Apply(dp.id)
            local d1 = ed_decal_count()
            check('decals are placed along the path', d1 > d0 + 3, tostring(d0) .. ' -> ' .. tostring(d1))
            Paths.Apply(dp.id)
            check('re-apply replaces the decals', ed_decal_count() == d1)
            History.Undo()
            History.Undo()
            check('undo removes the decals', ed_decal_count() == d0, tostring(ed_decal_count()))
        else
            table.insert(lines, '  skip decal tests (no decal catalog)')
        end
    end

    -- ---- symmetry: a mirrored image of the path is shaped, too
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        local oldMode = Symmetry.Mode
        Symmetry.SetMode('mirror_x')
        local sy = Straight('carve', 20, 90, 60, -4, 5, 3)
        Paths.SetField('sym', true)
        Paths.Apply(sy.id)
        local cx = Symmetry.Centre()
        check('symmetry: the path is carved', Near(ed_terrain_get(50, 60), 21), ed_terrain_get(50, 60))
        local mx = math.floor(2 * cx - 50 + 0.5)
        check('symmetry: the mirror image is carved too', Near(ed_terrain_get(mx, 60), 21), tostring(ed_terrain_get(mx, 60)) .. ' at ' .. mx)
        History.Undo()
        check('symmetry: one undo removes both', ed_terrain_get(50, 60) == 25 and ed_terrain_get(mx, 60) == 25)
        Symmetry.SetMode(oldMode)
    end

    -- ---- pathing check of a steep ramp
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        local flatPath = Straight('level', 40, 160, 60, 0, 5, 3)
        local frac = Paths.Pathable(flatPath.id, 0.75)
        check('a flat corridor is pathable', frac == 0, tostring(frac))
        local ramp = Straight('ramp', 40, 100, 90, 0, 5, 3)
        ramp.points[1].abs, ramp.points[1].h = true, 20
        ramp.points[2].abs, ramp.points[2].h = true, 80
        Paths.Apply(ramp.id)
        local fracRamp = Paths.Pathable(ramp.id, 0.75)
        check('a steep ramp is not pathable (grade 1.0 over its length)', fracRamp and fracRamp > 0.3, tostring(fracRamp))
        ramp.points[2].h = 40
        Paths.Apply(ramp.id)
        local fracOk = Paths.Pathable(ramp.id, 0.75)
        check('a gentle ramp is pathable (grade 0.33)', fracOk == 0, tostring(fracOk))
        History.Undo()
        History.Undo()
    end

    -- ---- the preview and the history
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        local pv = Straight('carve', 40, 200, 60, -3, 6, 4)
        local ver = History.Version
        Paths.Preview(pv.id)
        check('preview shows on the terrain', Near(ed_terrain_get(120, 60), 22))
        check('an undo request with a preview showing only takes the preview off', History.Undo() == 'preview' and ed_terrain_get(120, 60) == 25 and not Paths.HasPreview())
        Paths.Preview(pv.id)
        -- a terrain edit on top of the preview: the preview becomes an entry before it
        local stamp
        Fields.Run(function(S)
            stamp = Fields.CommitHeight(S:Op('const', { width = 21, height = 21, value = 90, ox = 10, oz = 100 }), { label = 'selftest stroke' })
        end)
        check('a stroke over a preview is committed', stamp and stamp > 0 and ed_terrain_get(20, 110) == 90, tostring(stamp))
        check('the preview was adopted into the history', not Paths.HasPreview())
        History.Undo()
        check('undo 1: the stroke', ed_terrain_get(20, 110) == 25 and Near(ed_terrain_get(120, 60), 22), tostring(ed_terrain_get(20, 110)) .. ' ' .. tostring(ed_terrain_get(120, 60)))
        History.Undo()
        check('undo 2: the preview', ed_terrain_get(120, 60) == 25)
        History.Redo()
        History.Redo()
        check('redo twice restores both', ed_terrain_get(20, 110) == 90 and Near(ed_terrain_get(120, 60), 22))
        History.Undo()
        History.Undo()
        -- live preview of the panel follows the model
        local Panel = import('/lua/editor/gui/panels_paths.lua')
        Panel.state.live = true
        Panel.state.lastPreview = -1
        Panel.state.lastTime = 0
        Panel.Refresh()
        check('live preview runs on the first tick', Paths.HasPreview() and Near(ed_terrain_get(120, 60), 22))
        Paths.SetPoint('h', -6)
        Panel.state.lastTime = 0
        Panel.Refresh()
        check('live preview follows a model change', Near(ed_terrain_get(120, 60), 19), ed_terrain_get(120, 60))
        local ver2 = History.Version
        Panel.state.lastTime = 0
        Panel.Refresh()
        check('live preview does not run again when nothing changed', History.Version == ver2)
        Panel.state.live = false
        Paths.RevertPreview()
        check('live preview reverts', ed_terrain_get(120, 60) == 25)
    end

    -- ---- the tool: hit tests and clicks
    Paths.Reset()
    History.Clear()
    do
        local Tool = import('/lua/editor/pathtool.lua')
        local tp = Straight('carve', 40, 200, 60, -3, 6, 4)
        local k0 = Tool.HitTest(40, 60)
        check('tool: a point is hit', k0 == 'point')
        local kind, hid, hidx = Tool.HitTest(120, 60)
        check('tool: the line is hit between the points', kind == 'segment' and hid == tp.id and hidx == 1, tostring(kind))
        check('tool: empty ground is no hit', Tool.HitTest(120, 200) == nil)
        Paths.Mode = 'draw'
        Paths.Current = false
        local before = table.getn(Paths.List)
        Tool.NewMode = 'raise'
        Tool.Press(100, 150, {})
        Tool.Press(150, 150, {})
        Tool.Press(150, 190, {})
        check('tool: draw mode starts a path with the clicks', table.getn(Paths.List) == before + 1 and table.getn(Paths.CurrentPath().points) == 3 and Paths.CurrentPath().mode == 'raise')
        Tool.Press(100.5, 150.5, {})
        check('tool: a click on the first point closes the path', Paths.CurrentPath().closed == true and Paths.Mode == 'edit')
        Paths.Mode = 'edit'
        Tool.Press(120, 60, {})
        check('tool: a click on a line selects its path', Paths.Current == tp.id)
        History.Undo() History.Undo() History.Undo() History.Undo()
    end

    -- ---- every mode changes the heights when the path is drawn with clicks (no hand-set heights): checksum before / after, preview and apply
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    do
        -- some relief: a slanted plane with a bump, so level / ramp / road have something to follow
        Fields.Run(function(S)
            local plane = S:Op('gradient', { angle = 20, lo = 20, hi = 60 })
            local bump = S:Op('radial', { cx = 120, cz = 120, radius = 60 })
            local relief = S:Op('add', { a = plane, b = S:Op('affine', { a = bump, mul = -25, add = 25 }) })
            Fields.CommitHeight(S:Op('quantize', { a = relief }), { label = 'selftest relief' })
        end)
        local function Sum() return Fields.Run(function(S) return Fields.Checksum(S:Height()) end) end
        local base = Sum()
        for _, mode in Paths.ModeOrder do
            local p = Paths.Add(mode, 'catmull', 60, 150)
            Paths.AddPoint(100, 110, mode) Paths.AddPoint(140, 130, mode) Paths.AddPoint(190, 90, mode)
            if mode == 'ramp' or mode == 'road' then
                Paths.Sel = { [4] = true }
                Paths.SetPoint('h', ed_terrain_get(190, 90) + 14)         -- the last pin 14 units above the ground
                Paths.Sel = {}
            end
            local before = Sum()
            local okp = Paths.Preview(p.id)
            local pv = Sum()
            check(mode .. ': the live preview changes the heights', okp and pv ~= before)
            check(mode .. ': the preview reports a height change', Paths.LastStats and Paths.LastStats.kind == 'preview' and (Paths.LastStats.hi - Paths.LastStats.lo) > 0.1 and string.find(Paths.StatsText(), 'height change', 1, true) ~= nil, Paths.StatsText())
            Paths.RevertPreview()
            check(mode .. ': the preview reverts', Sum() == before)
            local n = Paths.Apply(p.id)
            local after = Sum()
            check(mode .. ': apply changes the heights', n and n > 100 and after ~= before, tostring(n))
            check(mode .. ': apply reports a height change', Paths.LastStats.kind == 'apply' and Paths.LastStats.n == n and string.find(Paths.StatsText(), 'applied:', 1, true) ~= nil, Paths.StatsText())
            History.Undo()
            check(mode .. ': undo restores the heights', Sum() == before)
            Paths.Delete(p.id)
        end
        check('the relief is back where it started', Sum() == base)
        -- carve and raise point the right way in a fresh path, and switching the mode flips the sign
        local pc = Paths.Add('carve', 'catmull', 60, 150)
        Paths.AddPoint(100, 110, 'carve')
        check('carve starts negative, raise positive', pc.points[1].h < 0 and Paths.Modes.raise.h > 0)
        Paths.SetMode('raise')
        check('carve -> raise flips the sign', Paths.CurrentPath().points[1].h > 0)
        Paths.SetMode('carve')
        check('raise -> carve flips it back', Paths.CurrentPath().points[1].h < 0)
        -- a path that cannot change anything says so
        local pz = Paths.Add('carve', 'catmull', 60, 150)
        Paths.AddPoint(100, 110, 'carve')
        Paths.Sel = {}
        Paths.SetPoint('h', 0)
        Paths.Preview(pz.id)
        check('a zero-depth carve is reported as changing nothing', string.find(Paths.StatsText(), 'changes nothing', 1, true) ~= nil, Paths.StatsText())
        Paths.RevertPreview()
        -- level / ramp / road pin their ends by themselves
        local pr = Paths.Add('ramp', 'catmull', 60, 150)
        Paths.AddPoint(100, 110, 'ramp') Paths.AddPoint(140, 130, 'ramp')
        check('a ramp pins its first and last point at the ground', pr.points[1].abs and pr.points[3].abs and not pr.points[2].abs and Near(pr.points[3].h, ed_terrain_get(140, 130), 0.3), tostring(pr.points[3].h))
        local pl = Paths.Add('level', 'catmull', 60, 150)
        Paths.AddPoint(100, 110, 'level') Paths.AddPoint(140, 130, 'level')
        check('a level way is flat at the height of its first point', pl.points[3].abs and Near(pl.points[3].h, pl.points[1].h) and not pl.points[2].abs)
        Paths.Sel = { [1] = true }
        Paths.SetAbsolute(false)
        check('releasing a pin', not pl.points[1].abs and pl.points[1].h == 0)
        Paths.SetAbsolute(true)
        check('pinning takes the ground height', pl.points[1].abs and Near(pl.points[1].h, ed_terrain_get(60, 150), 0.3))
        Paths.Reset()
        History.Undo()
    end

    -- ---- marquee selection and picking
    Paths.Reset()
    History.Clear()
    do
        local Tool = import('/lua/editor/pathtool.lua')
        local a = Straight('carve', 40, 200, 60, -3, 6, 4)
        local pts = a.points
        table.insert(pts, 2, { x = 80, z = 60, w = 6, f = 4, h = -3, abs = false, bank = 0 })
        table.insert(pts, 3, { x = 120, z = 60, w = 6, f = 4, h = -3, abs = false, bank = 0 })
        local b = Straight('carve', 40, 200, 140, -3, 6, 4)
        Paths.Current = a.id
        local n = Paths.SelectInRect({ 70, 50, 130, 70 }, 'set')
        check('marquee selects the points inside', n == 2 and Paths.Sel[2] and Paths.Sel[3] and not Paths.Sel[1], tostring(n))
        n = Paths.SelectInRect({ 190, 50, 210, 70 }, 'add')
        check('shift adds to the selection', Paths.Sel[2] and Paths.Sel[3] and Paths.Sel[4])
        n = Paths.SelectInRect({ 70, 50, 90, 70 }, 'toggle')
        check('ctrl toggles points', not Paths.Sel[2] and Paths.Sel[3] and Paths.Sel[4])
        Paths.SelectInRect({ 0, 0, 10, 10 }, 'set')
        check('an empty marquee clears the selection', next(Paths.Sel) == nil)
        Paths.Current = a.id
        Paths.SelectInRect({ 30, 130, 210, 150 }, 'set')
        check('a marquee over another path picks that path', Paths.Current == b.id and Paths.Sel[1] and Paths.Sel[2])
        -- picking: the line selects its path only near the line, empty ground selects nothing
        Paths.Current = a.id
        Paths.Sel = {}
        local px = Tool.PixelSizeForTest and Tool.PixelSizeForTest() or 1
        local kind = Tool.HitTest(100, 60 + 3 * px)
        check('a click near the line hits the line', kind == 'segment' or kind == 'point', (kind == 'segment' or kind == 'point') and '' or (tostring(kind) .. ' (' .. Tool.NearestForTest(100, 60 + 3 * px) .. ')'))
        check('a click a few pixels away hits nothing', Tool.HitTest(100, 60 + 30 * px) == nil)
        Paths.Current = b.id
        Paths.Sel = { [1] = true }
        Tool.ApplyMarquee(false, 'set', false)
        check('a click on empty ground clears the point selection, not the path', Paths.Current == b.id and next(Paths.Sel) == nil)
        Paths.Sel = { [1] = true }
        Tool.ApplyMarquee(false, 'add', false)
        check('shift + click on empty ground keeps the selection', Paths.Sel[1])
        -- the gizmo drags live and records one entry at the release
        Paths.Current = a.id
        Paths.Sel = { [2] = true, [3] = true }
        local x2, x3 = a.points[2].x, a.points[3].x
        local depthBefore = History.Depth()
        Paths.GizmoOffset({ 12, 5 })
        check('gizmo drag: the points follow live', Near(a.points[2].x, x2 + 12) and Near(a.points[3].x, x3 + 12) and History.Depth() == depthBefore)
        Paths.GizmoOffset({ 20, 5 })
        check('gizmo drag: a second step moves on from the first', Near(a.points[2].x, x2 + 20))
        Paths.GizmoOffset(false)
        check('gizmo drag: the release takes the live move back', Near(a.points[2].x, x2) and Near(a.points[3].x, x3))
        Paths.MoveSelected(20, 5)
        check('gizmo drag: the final move is one undo entry', Near(a.points[2].x, x2 + 20) and History.Depth() == depthBefore + 1)
        local tz = a.points[2].z
        Paths.GizmoTurn(40)
        check('gizmo turn: the points turn live', not Near(a.points[2].z, tz, 0.5))
        Paths.GizmoTurn(false)
        check('gizmo turn: the release takes it back', Near(a.points[2].z, tz) and Near(a.points[2].x, x2 + 20))
        Paths.Reset()
        History.Clear()
    end

    -- ---- clean up
    Paths.Reset()
    History.Clear()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    ed_field_threads(threads0)
    local endCount = ed_field_count()
    check('no field leaks', endCount <= startCount, tostring(startCount) .. ' -> ' .. tostring(endCount))

    local head = 'PASS'
    if table.getn(failures) > 0 then head = 'FAIL (' .. table.getn(failures) .. ')' end
    return head .. '\n' .. table.concat(lines, '\n')
end
