-- Field engine self test (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T1). Run in the live editor:
--   return import('/lua/editor/selftest_fields.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The golden checksums of every op are in selftest_fields_cases.lua (shared with the native test EdFieldTest.cpp).
-- Bench() measures the speed on a 1025 x 1025 field (not part of Run).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')

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

--- 'k=v,k=v' -> params table (numbers, words, lists x:y;x:y flattened)
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
    fix.A = S:Op('perlin', { width = 33, height = 33, seed = 7, scale = 12, octaves = 4 })
    fix.H = S:Op('affine', { a = fix.A, mul = 40, add = 10 })
    fix.M = S:Op('voronoi', { width = 33, height = 33, scale = 10, seed = 5 })
    fix.N = S:Op('perlin', { width = 33, height = 33, seed = 9, scale = 9, octaves = 3 })
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
    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 65, tostring(w))
    if not w then return 'FAIL\n' .. table.concat(lines, '\n') end

    local startCount = ed_field_count()
    local threads0 = ed_field_threads()
    check('at least 35 ops', table.getn(Fields.OpNames()) >= 35, table.getn(Fields.OpNames()))

    -- golden checksums of every op, at several thread counts
    local Cases = import('/lua/editor/selftest_fields_cases.lua').Cases
    local cases = {}
    for _, rawLine in Split(Cases, '\n') do
        local line = (string.gsub(rawLine, '\r', ''))
        if line ~= '' and string.sub(line, 1, 1) ~= '#' then
            local f = Split(line, '|')
            if table.getn(f) >= 5 then table.insert(cases, f) end
        end
    end
    check('cases loaded', table.getn(cases) >= 60, table.getn(cases))
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

    -- a long pipeline on a bigger grid: no dependence on the thread count
    local sums = {}
    for _, threads in { 1, 2, 7 } do
        ed_field_threads(threads)
        Fields.Run(function(S)
            local e = Fields.Pipeline({
                { 'n', 'perlin', { width = 257, height = 257, seed = 3, scale = 60, octaves = 5 } },
                { 'h', 'affine', { a = '@n', mul = 60, add = 0 } },
                { 'b', 'blur', { a = '@h', radius = 3 } },
                { 't', 'thermal', { a = '@b', iterations = 12, talus = 0.5 } },
                { 'd', 'distance', { a = '@t', threshold = 40 } },
                { 's', 'slope', { a = '@t', mode = 'rating', window = 2 } },
                { 'm', 'blend', { a = '@d', b = '@s', mode = 'overlay', opacity = 0.7 } },
            }, S)
            table.insert(sums, Fields.Checksum(e.m))
        end)
    end
    ed_field_threads(threads0)
    check('pipeline is thread independent', sums[1] == sums[2] and sums[2] == sums[3], table.concat(sums, ' '))

    -- height round trip: map -> field -> map, exact
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    Fields.Run(function(S)
        local flat = S:Height()
        local mn, mx = Fields.Stats(flat)
        check('height field of a flat map', mn == 25 and mx == 25, tostring(mn) .. ' ' .. tostring(mx))
        local fw, fh, cell = Fields.Info(flat)
        check('height field shape', fw == w and fh == h and cell == 1, tostring(fw) .. 'x' .. tostring(fh))

        local n = S:Op('perlin', { seed = 4, scale = 40, octaves = 4 })
        local hgt = S:Op('affine', { a = n, mul = 60, add = 10 })
        local q = S:Op('quantize', { a = hgt })
        local depth = Terrain.UndoDepth()
        local historyBefore = History.Version
        local changed = Fields.CommitHeight(hgt, { label = 'selftest field' })
        check('commit changes samples', changed and changed > 1000, tostring(changed))
        check('commit is one document step', Terrain.UndoDepth() == depth + 1, tostring(Terrain.UndoDepth()) .. ' vs ' .. depth)
        check('commit is one history entry', History.Version == historyBefore + 1, tostring(History.Version) .. ' vs ' .. historyBefore)
        local back = S:Height()
        check('round trip height -> field -> height', Fields.Checksum(back) == Fields.Checksum(q), Fields.Checksum(back) .. ' / ' .. Fields.Checksum(q))
        check('document agrees', ed_terrain_get(100, 100) == Fields.Get(q, 100, 100), tostring(ed_terrain_get(100, 100)) .. ' / ' .. tostring(Fields.Get(q, 100, 100)))

        -- undo restores the flat map exactly, redo brings the field back
        check('undo', History.Undo() ~= false)
        check('undo restores the map', ed_terrain_get(100, 100) == 25 and ed_terrain_get(7, 9) == 25)
        check('redo', History.Redo() ~= false)
        check('redo restores the field', Fields.Checksum(S:Height()) == Fields.Checksum(q))
        History.Undo()

        -- masked, partial commit: only where the mask is 1, half way where it is 0.5
        local maskSrc = S:Op('gradient', { angle = 0, lo = 0, hi = 1 })
        local flat100 = S:New(w, h, 100)
        Fields.CommitHeight(flat100, { strength = 1, mask = maskSrc, label = 'selftest masked' })
        local left, right = ed_terrain_get(0, 50), ed_terrain_get(w - 1, 50)
        check('masked commit keeps the dark side', left < 26, left)
        check('masked commit takes the bright side', right > 99, right)
        History.Undo()
        check('masked commit undone', ed_terrain_get(w - 1, 50) == 25)
    end)

    -- paint masks
    local mw, mh = ed_stratum_info()
    if mw then
        Fields.Run(function(S)
            local before = S:Stratum(2, true)
            local pattern = S:Op('gradient', { like = before, angle = 0, lo = 0, hi = 1 })
            local entry, changed = Fields.CommitMask(pattern, 2, { noPush = true, label = 'selftest mask' })
            check('mask commit changes cells', entry ~= nil and changed > 100, tostring(changed))
            local after = S:Stratum(2, true)
            local mn, mx = Fields.Stats(after)
            check('mask holds the pattern', mx >= 250 and mn <= 128, tostring(mn) .. '..' .. tostring(mx))
            if entry then
                entry.undo()
                check('mask undo restores the bytes', Fields.Checksum(S:Stratum(2, true)) == Fields.Checksum(before))
                entry.redo()
                check('mask redo restores the pattern', Fields.Checksum(S:Stratum(2, true)) == Fields.Checksum(after))
                entry.undo()
            end
            -- one entry for heights and masks
            local depth0 = History.Version
            local hgt = S:New(w, h, 40)
            local cnt, applyEntry = Fields.Apply({ height = hgt, masks = { { layer = 2, field = pattern } }, label = 'selftest apply' })
            check('apply writes both', cnt > 1000, tostring(cnt))
            check('apply is one history entry', History.Version == depth0 + 1)
            History.Undo()
            check('apply undo (height)', ed_terrain_get(30, 30) == 25)
            check('apply undo (mask)', Fields.Checksum(S:Stratum(2, true)) == Fields.Checksum(before))
            History.Redo()
            check('apply redo (height)', ed_terrain_get(30, 30) == 40)
            check('apply redo (mask)', Fields.Checksum(S:Stratum(2, true)) == Fields.Checksum(after))
            History.Undo()
            applyEntry.release()
            if entry then entry.release() end
        end)
    else
        table.insert(lines, '  skip paint mask tests (no mask)')
    end

    -- previews and reads
    Fields.Run(function(S)
        local f = S:Op('perlin', { width = 65, height = 65, seed = 2, scale = 20 })
        local px, lo, hi = ed_field_preview(f, 16, 16, { ramp = 'terrain' })
        check('preview size', px and table.getn(px) == 16 * 16 * 4 and hi >= lo, px and table.getn(px))
        local path = Fields.Preview(f, 32, { ramp = 'heat' })
        check('preview picture written', path ~= nil, tostring(path))
        local vals = Fields.Read(f, 0, 0, 3, 3)
        check('read', vals and table.getn(vals) == 16 and vals[1] == Fields.Get(f, 0, 0))
        local mn, mx, mean, sd = Fields.Stats(f)
        check('stats', mn < mean and mean < mx and sd > 0)
        check('bad op is an error, not a crash', Fields.TryOp('no_such_op', {}) == nil)
        check('missing input is an error', Fields.TryOp('blur', { radius = 2 }) == nil)
    end)

    -- the terrain generator on the fields
    local Gen = import('/lua/editor/terraingen.lua')
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    local p = { seed = 11, scale = 60, octaves = 4, amplitude = 50, base = 20, mode = 'fbm', island = 0, replace = true }
    local n1 = Gen.Generate(p)
    local c1 = Fields.Run(function(S) return Fields.Checksum(S:Height()) end)
    History.Undo()
    local n2 = Gen.Generate(p)
    local c2 = Fields.Run(function(S) return Fields.Checksum(S:Height()) end)
    check('generator writes', n1 > 1000, n1)
    check('generator is deterministic', c1 == c2 and n1 == n2)
    local lo, hi = Fields.Run(function(S)
        local mn, mx = Fields.Stats(S:Height())
        return mn, mx
    end)
    check('generator spans base .. base + amplitude', lo >= 19.9 and hi <= 70.1 and hi - lo > 40, tostring(lo) .. ' .. ' .. tostring(hi))
    History.Undo()
    check('generator undo', ed_terrain_get(100, 100) == 25)
    p.island = 80
    Gen.Generate(p)
    check('island pulls the edge to the base', math.abs(ed_terrain_get(0, 0) - 20) < 0.01 and math.abs(ed_terrain_get(w - 1, h - 1) - 20) < 0.01,
        tostring(ed_terrain_get(0, 0)))
    History.Undo()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    p.island = 0
    p.replace = false
    Gen.Generate(p)
    local lo2 = Fields.Run(function(S) local a = Fields.Stats(S:Height()) return a end)
    check('generator can add to the heights', lo2 >= 25 - 0.01 and lo2 < 30, tostring(lo2))
    History.Undo()
    Gen.Flatten(33)
    check('flatten', ed_terrain_get(10, 10) == 33 and ed_terrain_get(w - 1, h - 1) == 33)
    History.Undo()
    check('flatten undo', ed_terrain_get(10, 10) == 25)

    -- no leaks
    ed_field_threads(threads0)
    local endCount = ed_field_count()
    check('no field leaks', endCount <= startCount, tostring(startCount) .. ' -> ' .. tostring(endCount))

    local head = 'PASS'
    if table.getn(failures) > 0 then head = 'FAIL (' .. table.getn(failures) .. ')' end
    return head .. '\n' .. table.concat(lines, '\n')
end

--- Speed of the engine on a 1025 x 1025 field: milliseconds per op with the pool's threads and with one thread.
function Bench()
    local out = {}
    local threads0 = ed_field_threads()
    for _, threads in { threads0, 1 } do
        ed_field_threads(threads)
        local rows = {}
        Fields.Run(function(S)
            local function T(label, fn)
                local ms = Fields.Timed(label, fn) * 1000
                table.insert(rows, string.format('  %-28s %8.1f ms', label, ms))
            end
            local n, hgt
            T('fBm perlin 5 octaves', function() n = S:Op('perlin', { width = 1025, height = 1025, seed = 3, scale = 120, octaves = 5 }) end)
            T('fBm simplex 5 octaves', function() S:Op('simplex', { like = n, seed = 3, scale = 120, octaves = 5 }) end)
            T('voronoi', function() S:Op('voronoi', { like = n, scale = 60 }) end)
            T('affine (height)', function() hgt = S:Op('affine', { a = n, mul = 60 }) end)
            T('gaussian blur sigma 4', function() S:Op('blur', { a = hgt, radius = 4 }) end)
            T('gaussian blur sigma 30', function() S:Op('blur', { a = hgt, radius = 30 }) end)
            T('thermal 50 iterations', function() S:Op('thermal', { a = hgt, iterations = 50, talus = 0.5 }) end)
            T('slope (degrees)', function() S:Op('slope', { a = hgt }) end)
            T('slope rating window 2', function() S:Op('slope', { a = hgt, mode = 'rating', window = 2 }) end)
            T('curvature', function() S:Op('curvature', { a = hgt, radius = 2 }) end)
            T('distance field', function() S:Op('distance', { a = hgt, threshold = 30 }) end)
            T('warp by noise', function() S:Op('warp', { a = hgt, dx = n, dz = n, strength = 20 }) end)
            T('rotate 30 degrees', function() S:Op('rotate', { a = hgt, angle = 30 }) end)
            T('remap curve', function() S:Op('remap', { a = n, points = { 0, 0, 0.4, 0.1, 0.6, 0.9, 1, 1 } }) end)
            T('stats', function() Fields.Stats(hgt) end)
            T('preview 128 x 128', function() ed_field_preview(hgt, 128, 128, {}) end)
            local w, h = ed_terrain_info()
            if w and w == 1025 then
                T('commit to the map heights', function() Fields.CommitHeight(hgt, { label = 'bench' }) end)
                History.Undo()
            end
        end)
        table.insert(out, 'threads ' .. threads .. ' of the pool:')
        for _, r in rows do table.insert(out, r) end
    end
    ed_field_threads(threads0)
    return table.concat(out, '\n')
end
