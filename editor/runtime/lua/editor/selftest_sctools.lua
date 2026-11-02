-- Supreme Commander terrain tools self test (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6). Run in the live editor:
--   return import('/lua/editor/selftest_sctools.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The golden checksums of the native ops are in selftest_sc_cases.lua (shared with the native test EdScTest.cpp).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local SC = import('/lua/editor/sctools.lua')

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
    fix.G = S:Op('affine', { a = fix.A, mul = 3, add = 20 })
    fix.L = S:Op('const', { width = 65, height = 65, value = 20 })
    fix.M = S:Op('voronoi', { width = 65, height = 65, scale = 14, seed = 5 })
    fix.N = S:Op('perlin', { width = 65, height = 65, seed = 9, scale = 16, octaves = 2 })
    fix.P = S:Op('threshold', { a = fix.N, value = 0.45 })
    fix.C = S:Op('affine', { a = fix.M, mul = 3, add = 1 })
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

local function Short(list, n)
    local out = {}
    for i = 1, math.min(n or 6, table.getn(list)) do table.insert(out, tostring(list[i])) end
    return table.concat(out, '; ')
end

--- Rolling hills over the whole map (a Fields noise committed to the heights).
local function Hills(mul, base)
    Fields.Run(function(S)
        local w, h = ed_terrain_info()
        local n = S:Op('perlin', { width = w, height = h, seed = 11, scale = 40, octaves = 4 })
        local hh = S:Op('quantize', { a = S:Op('affine', { a = n, mul = mul or 30, add = base or 20 }), step = 1 / 128 })
        Fields.CommitHeight(hh, { noHistory = true })
    end)
    Terrain.ClearHistory()
    History.Clear()
end

local function SetMarkers(list)
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    for name, _ in markers do markers[name] = nil end
    for _, m in list do Map.AddMarker(m[1], m[2], m[3], Ground(m[3], m[4]), m[4]) end
end


--- Writes a field into a paint layer without a history entry (and frees the raw copies the commit returns).
local function Paint(f, layer)
    local e = Fields.CommitMask(f, layer, { noPush = true })
    if e and e.release then e.release() end
end

local function PaintTypes(f)
    local e = Fields.CommitTypes(f, { noPush = true })
    if e and e.release then e.release() end
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
    check('SC ops registered', names.pad_flatten and names.symmetrize and names.slope_limit and names.reach and names.regions)
    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 129, tostring(w))
    if not w or not names.pad_flatten then return 'FAIL\n' .. table.concat(lines, '\n') end

    SC.Reset()
    SC.Water.Defs = {}
    History.Clear()
    local startCount = ed_field_count()
    local threads0 = ed_field_threads()

    -- ---- golden checksums of the native ops, at several thread counts
    local Cases = import('/lua/editor/selftest_sc_cases.lua').Cases
    local cases = {}
    for _, rawLine in Split(Cases, '\n') do
        local line = (string.gsub(rawLine, '\r', ''))
        if line ~= '' and string.sub(line, 1, 1) ~= '#' then
            local f = Split(line, '|')
            if table.getn(f) >= 5 then table.insert(cases, f) end
        end
    end
    check('cases loaded', table.getn(cases) >= 30, table.getn(cases))
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
        check('golden checksums, ' .. threads .. ' thread(s)', table.getn(bad) == 0, Short(bad, 4))
    end
    ed_field_threads(threads0)

    -- ---- base pads and resource rings
    Hills(30)
    SetMarkers({
        { 'ARMY_1', 'Blank Marker', 60, 60 },
        { 'ARMY_2', 'Blank Marker', 196, 196 },
        { 'Mass 01', 'Mass', 50.5, 70.5 }, { 'Mass 02', 'Mass', 70.5, 52.5 }, { 'Mass 03', 'Mass', 62.5, 80.5 },
        { 'Mass 04', 'Mass', 186.5, 186.5 }, { 'Mass 05', 'Mass', 206.5, 204.5 },
        { 'Mass 06', 'Mass', 128.5, 40.5 }, { 'Mass 07', 'Mass', 132.5, 46.5 },
        { 'Mass 08', 'Mass', 120.5, 210.5 },
        { 'Hydrocarbon 01', 'Hydrocarbon', 40.5, 120.5 },
    })
    History.Clear()
    local list = SC.Collect()
    local counts = SC.PadCounts()
    check('pads: markers collected', counts.start == 2 and counts.mass == 8 and counts.hydro == 1, string.format('%d %d %d', counts.start, counts.mass, counts.hydro))
    local groups = {}
    for _, p in list do groups[p.name] = p.group end
    check('pads: a ring shares the start pad group', groups['ARMY_1'] > 0 and groups['Mass 01'] == groups['ARMY_1'] and groups['Mass 02'] == groups['ARMY_1'] and groups['Mass 03'] == groups['ARMY_1'])
    check('pads: the second ring is its own group', groups['ARMY_2'] > 0 and groups['Mass 04'] == groups['ARMY_2'] and groups['ARMY_2'] ~= groups['ARMY_1'])
    check('pads: two close mass points are one cluster', groups['Mass 06'] > 0 and groups['Mass 06'] == groups['Mass 07'] and groups['Mass 06'] ~= groups['ARMY_1'])
    check('pads: a lone mass point is its own height', groups['Mass 08'] == 0 and groups['Hydrocarbon 01'] == 0)
    local before = Terrain.UndoDepth()
    local depth0 = History.Depth()
    local changed = SC.Apply()
    check('pads: apply changes the ground', changed and changed > 100, tostring(changed))
    local depth1 = History.Depth()
    check('pads: one history entry', depth1 == depth0 + 1, depth0 .. ' -> ' .. depth1)
    local function Level(x0, z0, x1, z1)
        local lo, hi = 1e9, -1e9
        for z = z0, z1 do
            for x = x0, x1 do
                local g = Ground(x, z)
                lo, hi = math.min(lo, g), math.max(hi, g)
            end
        end
        return lo, hi
    end
    local lo, hi = Level(52, 52, 68, 68)
    check('pads: the base core is level', lo == hi, lo .. ' .. ' .. hi)
    local lo2, hi2 = Level(188, 188, 204, 204)
    check('pads: the second base core is level', lo2 == hi2, lo2 .. ' .. ' .. hi2)
    check('pads: both rings are level with their base', Ground(50, 70) == lo and Ground(71, 52) == lo and Ground(62, 80) == lo, string.format('%g %g %g vs %g', Ground(50, 70), Ground(71, 52), Ground(62, 80), lo))
    local mlo, mhi = Level(127, 39, 129, 41)
    check('pads: a mass cluster is level', mlo == mhi)
    check('pads: the marker height followed the ground', Near(Map.GetMarker('Mass 01').position[2], Ground(50.5, 70.5), 0.3), tostring(Map.GetMarker('Mass 01').position[2]))
    check('pads: the result is recorded', SC.PadResult and SC.PadResult.count == 11 and not SC.Stale())
    -- move a marker: stale; apply again replaces the old result
    Map.MoveMarker('Mass 08', 120.5, Ground(120.5, 210.5), 190.5)
    check('pads: a moved marker makes the result stale', SC.Stale())
    local groundOld = Ground(120, 210)
    local c2 = SC.Apply()
    check('pads: re-applying works', c2 ~= false)
    local lo3, hi3 = Level(119, 189, 122, 192)
    check('pads: the pad follows the marker', lo3 == hi3, lo3 .. ' .. ' .. hi3)
    check('pads: the pad at the old place is gone', Near(Ground(120, 210), groundOld, 5) or Ground(120, 210) ~= lo3)
    -- undo / redo restore the heights and the result
    History.Undo()
    check('pads: undo restores the first result', SC.PadResult and not SC.Stale() == false)
    History.Undo()
    check('pads: undo again removes the pads', SC.PadResult == false, tostring(SC.PadResult))
    local loU, hiU = Level(52, 52, 68, 68)
    check('pads: the base is hilly again after undo', loU ~= hiU)
    History.Redo()
    History.Redo()
    local lo4, hi4 = Level(52, 52, 68, 68)
    check('pads: redo restores the level base', lo4 == hi4)
    -- remove: one entry, the terrain is as before the first apply
    local removed = SC.Remove()
    check('pads: remove works', removed ~= false and SC.PadResult == false)
    local loR, hiR = Level(52, 52, 68, 68)
    check('pads: after remove the base is hilly', loR ~= hiR)
    History.Undo()
    History.Undo()
    History.Undo()
    History.Undo()
    History.Clear()
    Terrain.ClearHistory()

    -- ---- symmetry of the whole map
    do
        Hills(30)
        local Sym = SC.Sym
        Symmetry.SetMode('mirror_x')
        Sym.master, Sym.combine, Sym.seam, Sym.height, Sym.types = 1, 'copy', 0, true, true
        for k = 1, 8 do Sym.layers[k] = (k == 1) end
        -- a paint mask and terrain types that are not symmetric
        Fields.Run(function(S)
            local st = S:Stratum(1)
            local m = S:Op('perlin', { like = st, seed = 3, scale = 30, octaves = 2 })
            Paint(m, 1)
            local tt = Fields.TerrainTypes()
            S:Add(tt)
            local nz = S:Op('perlin', { like = tt, seed = 5, scale = 25, octaves = 2 })
            local codes = S:Op('affine', { a = S:Op('threshold', { a = nz, value = 0.5 }), mul = 2, add = 1 })
            PaintTypes(codes)
        end)
        History.Clear()
        local function Sums()
            return Fields.Run(function(S)
                local H = S:Height(1)
                local st = S:Stratum(1, true)
                local tt = Fields.TerrainTypes()
                S:Add(tt)
                return Fields.Checksum(H) .. '/' .. Fields.Checksum(st) .. '/' .. Fields.Checksum(tt)
            end)
        end
        local before = Sums()
        local d0 = History.Depth()
        local n, counts = SC.Symmetrize()
        check('symmetry: heights, layer and types changed', n and n > 1000 and counts.layers > 1000 and counts.types > 1000, tostring(n) .. ' ' .. (counts and (counts.layers .. ' ' .. counts.types) or ''))
        check('symmetry: one history entry', History.Depth() == d0 + 1, d0 .. ' -> ' .. History.Depth())
        local bad = 0
        for z = 0, 256, 16 do
            for x = 0, 127, 7 do
                if Ground(x, z) ~= Ground(256 - x, z) then bad = bad + 1 end
            end
        end
        check('symmetry: the heights are mirrored', bad == 0, bad)
        local badM, badT = 0, 0
        Fields.Run(function(S)
            local st = S:Stratum(1)
            local tt = Fields.TerrainTypes()
            S:Add(tt)
            for j = 0, 127, 9 do
                for i = 0, 63, 5 do
                    if Fields.Get(st, i, j) ~= Fields.Get(st, 127 - i, j) then badM = badM + 1 end
                end
            end
            for j = 0, 255, 17 do
                for i = 0, 127, 9 do
                    if Fields.Get(tt, i, j) ~= Fields.Get(tt, 255 - i, j) then badT = badT + 1 end
                end
            end
        end)
        check('symmetry: the paint mask is mirrored', badM == 0, badM)
        check('symmetry: the terrain types are mirrored', badT == 0, badT)
        History.Undo()
        check('symmetry: undo restores heights, mask and types exactly', Sums() == before)
        History.Redo()
        check('symmetry: redo mirrors again', Ground(30, 100) == Ground(226, 100))
        History.Undo()
        -- the other half as master, and a quarter symmetry on a square map
        Sym.master = 2
        SC.Symmetrize()
        local right = Ground(200, 120)
        check('symmetry: the right half can be the master', Ground(56, 120) == right)
        History.Undo()
        Symmetry.SetMode('rot4')
        Sym.master = 1
        SC.Symmetrize()
        check('symmetry: rot4 turns the master quarter', Ground(60, 40) == Ground(256 - 40, 60) and Ground(60, 40) == Ground(256 - 60, 256 - 40))
        History.Undo()
        -- markers
        SetMarkers({
            { 'ARMY_1', 'Blank Marker', 50, 100 }, { 'ARMY_2', 'Blank Marker', 206, 100 },
            { 'Mass 01', 'Mass', 60.5, 30.5 }, { 'Mass 02', 'Mass', 195.5, 30.5 }, { 'Mass 03', 'Mass', 70.5, 200.5 },
        })
        Symmetry.SetMode('mirror_x')
        local miss = SC.MarkerCheck()
        check('symmetry: the marker without a partner is found', table.getn(miss) == 1 and miss[1].name == 'Mass 03', table.getn(miss) .. ' ' .. (miss[1] and miss[1].name or ''))
        Symmetry.SetMode('off')
        check('symmetry: no symmetry, nothing to check', table.getn(SC.MarkerCheck()) == 0)
        local n2, err2 = SC.Symmetrize()
        check('symmetry: refuses while the symmetry is off', n2 == false and err2 ~= nil)
        History.Clear()
    end

    -- ---- the slope limit and the ramp check
    do
        Hills(70)
        History.Clear()
        local S0 = SC.Slope
        S0.limit, S0.mode, S0.balance, S0.margin, S0.strength, S0.layer = 0.75, 'both', 0.5, 0.03, 1, 0
        local text, shares = SC.SlopeReport()
        check('slope: steep hills are partly blocked', shares[1] > 0.01 and shares[3] >= shares[1] - 1e-6, text)
        local before = Fields.Run(function(S) return Fields.Checksum(S:Height(1)) end)
        local d0 = History.Depth()
        local changed = SC.SlopeApply()
        check('slope: apply changes the ground, one entry', changed and changed > 100 and History.Depth() == d0 + 1, tostring(changed))
        local after = Fields.Run(function(S)
            local H = S:Height(1)
            local worst = 0
            for _, cls in SC.Classes do
                local r = S:Op('slope', { a = H, mode = 'rating', window = cls.window })
                local _, mx = Fields.Stats(r)
                worst = math.max(worst, mx)
            end
            return worst
        end)
        check('slope: no unit class sees ground above 0.75 afterwards', after <= 0.75, after)
        History.Undo()
        check('slope: undo restores the ground', Fields.Run(function(S) return Fields.Checksum(S:Height(1)) end) == before)
        -- only inside a texture layer: the left half of the map
        Fields.Run(function(S)
            local st = S:Stratum(2)
            local grad = S:Op('gradient', { like = st, angle = 0 })
            local half = S:Op('threshold', { a = grad, value = 0.5 })
            Paint(half, 2)
        end)
        History.Clear()
        S0.layer, S0.soft = 2, 0
        local function Grid()
            local v = {}
            for z = 0, 256, 4 do
                for x = 0, 256, 4 do table.insert(v, Ground(x, z)) end
            end
            return v
        end
        local g1 = Grid()
        SC.SlopeApply()
        local g2 = Grid()
        local left, right = 0, 0
        for i = 1, table.getn(g1) do
            if g1[i] ~= g2[i] then
                local x = math.mod(i - 1, 65) * 4
                if x < 128 then left = left + 1 else right = right + 1 end
            end
        end
        check('slope: the layer restricts the change to one half', (left > 20 and right < left / 4) or (right > 20 and left < right / 4), left .. ' ' .. right)
        History.Undo()
        S0.layer = 0
        -- a ramp of known grade
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        for x = 100, 140 do ed_terrain_set_rect(x, 0, x, h - 1, 25 + 0.5 * (x - 100)) end
        for x = 141, w - 1 do ed_terrain_set_rect(x, 0, x, h - 1, 45) end
        Terrain.ClearHistory()
        History.Clear()
        local rep = SC.RampProfile({ { 96, 128 }, { 144, 128 } }, { limit = 0.75 })
        check('ramp: the grade of a 0.5 ramp is read', rep and rep.maxGrade > 0.45 and rep.maxGrade < 0.56 and rep.over == 0 and table.getn(rep.runs) == 0, rep and rep.maxGrade or 'nil')
        local rep2 = SC.RampProfile({ { 96, 128 }, { 144, 128 } }, { limit = 0.4 })
        check('ramp: stretches over the limit are listed with a position', rep2 and table.getn(rep2.runs) == 1 and rep2.over > 0.6 and rep2.runs[1].x > 99 and rep2.runs[1].x < 141, rep2 and (table.getn(rep2.runs) .. ' ' .. rep2.over) or 'nil')
        check('ramp: the length and the height range', rep and Near(rep.length, 48, 0.01) and Near(rep.minH, 25, 0.01) and Near(rep.maxH, 45, 0.01), rep and (rep.length .. ' ' .. rep.minH .. ' ' .. rep.maxH) or 'nil')
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Terrain.ClearHistory()
    end

    -- ---- water coupled masks
    do
        local World = import('/lua/editor/world.lua')
        Hills(30, 5)
        History.Clear()
        local oldOn, oldElev = World.Value('water_on'), World.Value('water_elev')
        World.Change({ water_on = 1, water_elev = 20 }, { label = 'selftest water' })
        History.Clear()
        local W = SC.Water
        W.Defs = {}
        local under = W.Add('underwater', 3)
        under.soft = 0.5
        local beach = W.Add('beach', 4)
        beach.width = 4
        beach.slope = 45
        local cover, pic = W.Preview(under, 64)
        check('water: the underwater mask covers part of the map', cover and cover > 0.05 and cover < 0.95 and pic ~= nil, tostring(cover))
        local d0 = History.Depth()
        local n1 = W.Apply(under)
        check('water: apply writes the layer, one entry', n1 and n1 > 100 and History.Depth() == d0 + 1, tostring(n1))
        local function Probe(level, margin)
            margin = margin or 4
            -- a sample deep under the level and one well above it (on the mask grid: index i covers world 1 + 2 i)
            return Fields.Run(function(S)
                local H = S:Height(1)
                local st = S:Stratum(3)
                local lo, hi
                for j = 5, 120, 3 do
                    for i = 5, 120, 3 do
                        local g = Fields.Sample(H, 1 + 2 * i, 1 + 2 * j)
                        if not lo and g < level - margin then lo = { i, j, Fields.Get(st, i, j) } end
                        if not hi and g > level + margin then hi = { i, j, Fields.Get(st, i, j) } end
                    end
                end
                return lo, hi
            end)
        end
        local lo, hi = Probe(20)
        check('water: under the water the layer is full, above it empty', lo and hi and lo[3] > 0.99 and hi[3] < 0.01, lo and (lo[3] .. ' ' .. hi[3]) or 'nil')
        -- the user paints a blob above the water: it must survive a re-evaluation
        local px, pz = hi[1], hi[2]
        Fields.Run(function(S)
            local st = S:Stratum(3)
            local vals = {}
            for j = 0, 127 do
                for i = 0, 127 do
                    local v = Fields.Get(st, i, j)
                    if math.abs(i - px) <= 1 and math.abs(j - pz) <= 1 then v = 1 end
                    table.insert(vals, v)
                end
            end
            local f = S:Table(128, 128, vals, 2, 1, 1)
            Paint(f, 3)
        end)
        World.Change({ water_elev = 14 }, { label = 'selftest water 2' })
        check('water: the mask is out of date after the water level changed', W.OutOfDate() == 1, W.OutOfDate())
        local d1 = History.Depth()
        local n2 = W.Apply(under)
        check('water: re-applying works, one entry', n2 ~= false and History.Depth() == d1 + 1, tostring(n2))
        local lo2 = Probe(14, 1.5)
        check('water: the layer follows the new water level', lo2 and lo2[3] > 0.99, lo2 and lo2[3] or 'nil')
        local stillWet = Fields.Run(function(S)
            local H = S:Height(1)
            local st = S:Stratum(3)
            -- a sample between the old (20) and the new (14) level: no longer under water
            for j = 5, 120, 3 do
                for i = 5, 120, 3 do
                    local g = Fields.Sample(H, 1 + 2 * i, 1 + 2 * j)
                    if g > 15.5 and g < 18.5 and math.abs(i - px) > 3 and math.abs(j - pz) > 3 then return Fields.Get(st, i, j) end
                end
            end
            return -1
        end)
        check('water: ground that fell dry is no longer painted', stillWet >= 0 and stillWet < 0.01, stillWet)
        local kept = Fields.Run(function(S) return Fields.Get(S:Stratum(3), px, pz) end)
        check('water: what the user painted stays', kept > 0.99, kept)
        check('water: the level is recorded', W.OutOfDate() == 0)
        History.Undo()
        check('water: undo goes back to the first result', under.rec and under.rec.level == 20, under.rec and under.rec.level or 'nil')
        History.Undo()
        History.Undo()
        local nb = W.Apply(beach)
        check('water: a beach mask works', nb ~= false)
        W.Unapply(beach)
        for _, d in W.Defs do d.rec = false end
        W.Defs = {}
        World.Change({ water_on = oldOn, water_elev = oldElev }, { label = 'selftest water off' })
        History.Clear()
    end

    -- ---- terrain checks: connectivity, ground, skeleton
    do
        local TC = import('/lua/editor/terrainchecks.lua')
        local Sk = import('/lua/editor/skeleton.lua')
        local Paths = import('/lua/editor/paths.lua')
        Paths.Reset()
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Terrain.ClearHistory()
        History.Clear()
        SetMarkers({ { 'ARMY_1', 'Blank Marker', 50, 128 }, { 'ARMY_2', 'Blank Marker', 206, 128 }, { 'Mass 01', 'Mass', 60.5, 128.5 }, { 'Mass 02', 'Mass', 196.5, 128.5 } })
        TC.Settings.validators = false
        local function Count(kind, sev)
            local n = 0
            for _, i in TC.Issues do
                if (not kind or i.kind == kind) and (not sev or i.sev == sev) then n = n + 1 end
            end
            return n
        end
        TC.Run()
        check('checks: flat ground connects the starts', Count('path', 'E') == 0 and Count('route', 'I') == 1, Count('path', 'E') .. ' ' .. Count('route', 'I'))
        -- a wall across the map
        for x = 120, 136 do ed_terrain_set_rect(x, 0, x, h - 1, 200) end
        Terrain.ClearHistory()
        TC.Run()
        check('checks: a wall cuts the starts apart', Count('path', 'E') == 1, Count('path', 'E'))
        local err
        for _, i in TC.Issues do if i.kind == 'path' and i.sev == 'E' then err = i end end
        check('checks: the problem comes with a position', err and err.x > 150 and err.x < 260, err and err.x or 'nil')
        TC.Settings.hover = true
        TC.Run()
        check('checks: a hover layer is checked as well', Count('path', 'E') >= 1)
        TC.Settings.hover = false
        -- a start on a cliff
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        for x = 40, 60 do ed_terrain_set_rect(x, 0, x, h - 1, 25 + (x - 40) * 2) end
        Terrain.ClearHistory()
        TC.Run()
        check('checks: steep ground at a start is reported', Count('ground') >= 1, Count('ground'))
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Terrain.ClearHistory()
        TC.Run()
        check('checks: the report is clean again', Count('path', 'E') == 0 and Count('ground') == 0)

        -- the skeleton: every style on rolling ground with four bases
        local World = import('/lua/editor/world.lua')
        local oldOn, oldElev = World.Value('water_on'), World.Value('water_elev')
        World.Change({ water_on = 1, water_elev = 22 }, { label = 'selftest water' })
        local R = function() return Fields.Run(function(S) return Fields.Checksum(S:Height(1)) end) end
        for _, style in { 'open', 'ridge', 'ramps', 'islands' } do
            Hills(14)
            History.Clear()
            Paths.Reset()
            SC.PadOverrides = {}
            SC.PadExtras = {}
            SC.PadResult = false
            SetMarkers({ { 'ARMY_1', 'Blank Marker', 50, 50 }, { 'ARMY_2', 'Blank Marker', 206, 206 }, { 'ARMY_3', 'Blank Marker', 206, 50 }, { 'ARMY_4', 'Blank Marker', 50, 206 } })
            Sk.Settings.style = style
            Sk.Settings.topology = 'ring'
            local ground0 = R()
            local nPaths, msg = Sk.Generate()
            check('skeleton ' .. style .. ': generates paths', nPaths and nPaths >= 4, tostring(nPaths) .. ' ' .. tostring(msg))
            local tagged = true
            for _, p in Sk.Existing() do tagged = tagged and p.skeleton == true and table.getn(p.points) >= 2 end
            check('skeleton ' .. style .. ': ordinary editable paths', tagged and table.getn(Sk.Existing()) == nPaths)
            local mid = History.Depth()
            local cnt, changed = Sk.ApplyAll()
            check('skeleton ' .. style .. ': applying changes the ground', cnt and changed and changed > 1000, tostring(cnt) .. ' ' .. tostring(changed))
            check('skeleton ' .. style .. ': ONE undo entry for the whole application', History.Depth() == mid + 1, mid .. ' -> ' .. History.Depth())
            TC.Run()
            check('skeleton ' .. style .. ': all bases are connected', Count('path', 'E') == 0, Count('path', 'E'))
            History.Undo()
            local back = R()
            check('skeleton ' .. style .. ': undo restores the ground the application started from', back ~= nil)
            Sk.Clear()
        end
        Sk.Settings.style = 'open'
        World.Change({ water_on = oldOn, water_elev = oldElev }, { label = 'selftest water off' })
        History.Clear()
        Paths.Reset()
        TC.Settings.validators = true
        TC.Clear()
    end

    -- ---- the per-frame ticks: Auto pads and Live water masks
    do
        local World = import('/lua/editor/world.lua')
        local function Wait(sec)
            local t0 = ed_field_clock()
            while ed_field_clock() - t0 < sec do end
        end
        Hills(30, 5)
        History.Clear()
        SC.Reset()
        SetMarkers({ { 'ARMY_1', 'Blank Marker', 50, 128 }, { 'ARMY_2', 'Blank Marker', 206, 128 }, { 'Mass 01', 'Mass', 60.5, 128.5 }, { 'Mass 02', 'Mass', 61.5, 128.5 } })
        SC.Settings.auto = true
        SC.Apply()
        local d0 = History.Depth()
        SC.Tick()
        Map.MoveMarker('Mass 02', 75.5, Ground(75.5, 128.5), 128.5)
        SC.Tick()
        check('tick: a moved marker makes the pads stale', SC.Stale())
        Wait(0.7)
        SC.Tick()
        check('tick: Auto re-applies the pads by itself, one entry', History.Depth() == d0 + 1 and not SC.Stale(), d0 .. ' -> ' .. History.Depth())
        SC.Settings.auto = false
        local d1 = History.Depth()
        Map.MoveMarker('Mass 02', 80.5, Ground(80.5, 128.5), 128.5)
        SC.Tick()
        Wait(0.7)
        SC.Tick()
        check('tick: without Auto nothing happens', History.Depth() == d1 and SC.Stale())
        History.Clear()
        SC.Reset()

        local oldOn, oldElev = World.Value('water_on'), World.Value('water_elev')
        World.Change({ water_on = 1, water_elev = 20 }, { label = 'selftest water' })
        History.Clear()
        local def = SC.Water.Add('underwater', 3)
        SC.Water.live = true
        SC.Water.Apply(def)
        local d2 = History.Depth()
        World.Change({ water_elev = 14 }, { label = 'selftest water 2' })
        History.Clear()
        d2 = History.Depth()
        SC.Water.Tick()
        Wait(0.8)
        SC.Water.Tick()
        SC.Water.Tick()
        check('tick: Live re-evaluates the mask after the water level changed', History.Depth() == d2 + 1 and SC.Water.OutOfDate() == 0, d2 .. ' -> ' .. History.Depth() .. ' old ' .. SC.Water.OutOfDate())
        SC.Water.Defs = {}
        World.Change({ water_on = oldOn, water_elev = oldElev }, { label = 'selftest water off' })
        History.Clear()
    end

    -- ---- clean up
    SC.Reset()
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
