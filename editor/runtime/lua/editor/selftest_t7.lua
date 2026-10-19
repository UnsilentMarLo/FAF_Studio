-- Stage T7 self test (docs/projects/editor/TERRAIN_GEN_DESIGN.md, section T7: more ops, the speed work, the graph library). Run in the live editor:
--   return import('/lua/editor/selftest_t7.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The golden checksums of the new ops are in selftest_t7_cases.lua (shared with the native test EdT7Test.cpp).
-- Bench() measures the speed of the whole stack on a 1025 x 1025 map (not part of Run).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

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

--- The fixtures of the golden cases (the same as EdT7Test.cpp BuildFixtures), 65 x 65 samples.
local function Fixtures(S)
    local fix = {}
    fix.A = S:Op('perlin', { width = 65, height = 65, seed = 7, scale = 20, octaves = 3 })
    fix.H = S:Op('affine', { a = fix.A, mul = 30, add = 20 })
    fix.G = S:Op('affine', { a = fix.A, mul = 3, add = 20 })
    fix.R = S:Op('ridged', { width = 65, height = 65, seed = 4, scale = 24, octaves = 4 })
    fix.T = S:Op('affine', { a = fix.R, mul = 70, add = 0 })
    fix.L = S:Op('const', { width = 65, height = 65, value = 20 })
    fix.M = S:Op('voronoi', { width = 65, height = 65, scale = 14, seed = 5 })
    fix.N = S:Op('perlin', { width = 65, height = 65, seed = 9, scale = 16, octaves = 2 })
    fix.P = S:Op('threshold', { a = fix.N, value = 0.45 })
    fix.S = S:Op('affine', { a = fix.N, mul = 4, add = 0 })
    fix.W = S:Op('affine', { a = fix.N, mul = 0.6, add = 0.3 })
    return fix
end

--- Runs a case line (op or op@extra); returns the checksum.
local function CaseChecksum(fix, case)
    local op, extra = case[2], nil
    local at = string.find(op, '@', 1, true)
    if at then
        extra = string.sub(op, at + 1)
        op = string.sub(op, 1, at - 1)
    end
    local p = ParseParams(case[3])
    if case[4] ~= '' then
        for _, kv in Split(case[4], ',') do
            local eq = string.find(kv, '=', 1, true)
            p[string.sub(kv, 1, eq - 1)] = fix[string.sub(kv, eq + 1)]
        end
    end
    local main, others = ed_field_op_multi(op, p)
    if not main then return nil, tostring(others) end
    local sum, err
    if extra then
        if others and others[extra] then sum = Fields.Checksum(others[extra]) else err = 'no extra output ' .. extra end
    else
        sum = Fields.Checksum(main)
    end
    Fields.Free(main)
    if others then for _, f in others do Fields.Free(f) end end
    return sum, err
end

local function LoadCases()
    local Cases = import('/lua/editor/selftest_t7_cases.lua').Cases
    local cases = {}
    for _, rawLine in Split(Cases, '\n') do
        local line = (string.gsub(rawLine, '\r', ''))
        if line ~= '' and string.sub(line, 1, 1) ~= '#' then
            local f = Split(line, '|')
            if table.getn(f) >= 5 then table.insert(cases, f) end
        end
    end
    return cases
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
    check('the T7 ops are in the engine', rawget(_G, 'ed_field_ops') ~= nil)
    local names = {}
    for _, n in Fields.OpNames() do names[n] = true end
    local missing = {}
    for _, n in { 'musgrave', 'fbm_damped', 'cells', 'craters', 'dunes', 'cracks', 'island', 'dwarp', 'bilateral', 'diffuse', 'unsharp', 'edge', 'morph', 'convolve', 'blur_dir', 'blur_slope',
                  'stratify', 'occlusion', 'hillshade', 'wetness', 'rockiness', 'color_ramp', 'thermal_map', 'erode_rocksoil', 'erode_snow', 'erode_wind', 'erode_glacier', 'settle' } do
        if not names[n] then table.insert(missing, n) end
    end
    check('all 28 T7 ops listed by the engine', table.getn(missing) == 0, table.concat(missing, ' '))
    if table.getn(missing) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. table.concat(lines, '\n') end

    local startCount = ed_field_count()
    local threads0 = ed_field_threads()

    -- golden checksums of every new op, at several thread counts
    local cases = LoadCases()
    check('cases loaded', table.getn(cases) >= 90, table.getn(cases))
    for _, threads in { 1, 3, threads0 } do
        ed_field_threads(threads)
        local bad = {}
        local S = Fields.Scope()
        local fix = Fixtures(S)
        for _, c in cases do
            local sum, err = CaseChecksum(fix, c)
            if not sum then
                table.insert(bad, c[1] .. ': ' .. tostring(err))
            elseif sum ~= c[5] then
                table.insert(bad, c[1] .. ' ' .. sum .. ' <> ' .. c[5])
            end
        end
        S:Free()
        check('golden checksums with ' .. threads .. ' threads', table.getn(bad) == 0, table.concat(bad, '; '))
    end
    ed_field_threads(threads0)
    check('no field leaks', ed_field_count() <= startCount, ed_field_count() - startCount)    -- fewer is fine: a cache another module held at the start (the graph's base heights) may be released meanwhile

    local extraOk, extraMsg = pcall(function() return import('/lua/editor/selftest_t7_nodes.lua').Run(check) end)
    if not extraOk then check('node tests ran', false, extraMsg) end

    local head = table.getn(failures) == 0 and 'PASS' or ('FAIL (' .. table.getn(failures) .. ': ' .. string.sub(table.concat(failures, ', '), 1, 300) .. ')')
    return head .. '\n' .. table.concat(lines, '\n')
end

-- ---- speed report -----------------------------------------------------------------------------------------------------------------------------------

--- Times the new ops and the stack on a 1025 x 1025 map (milliseconds, the editor's own thread count).
function Bench()
    local out = {}
    local function T(label, fn)
        local t = Fields.Timed(label, fn)
        table.insert(out, string.format('%-34s %8.1f ms', label, t * 1000))
    end
    local S = Fields.Scope()
    local base = S:Op('ridged', { width = 1025, height = 1025, seed = 3, scale = 180, octaves = 6 })
    local a = S:Op('affine', { a = base, mul = 60, add = 10 })
    local b = S:Op('perlin', { width = 1025, height = 1025, seed = 9, scale = 100, octaves = 3 })
    local list = {
        { 'musgrave', { width = 1025, height = 1025, seed = 3, scale = 120, octaves = 6 } },
        { 'cells', { width = 1025, height = 1025, seed = 3, scale = 60, mode = 'plate', warp = 20 } },
        { 'dwarp', { a = a, strength = 40, size = 100 } },
        { 'bilateral', { a = a, radius = 6, sigma_r = 2 } },
        { 'diffuse', { a = a, iterations = 50, kappa = 0.4 } },
        { 'morph', { a = a, op = 'open', radius = 5, shape = 'disc' } },
        { 'occlusion', { a = a, radius = 30 } },
        { 'hillshade', { a = a, shadows = 1 } },
        { 'wetness', { a = a } },
        { 'thermal_map', { a = a, iterations = 50 } },
        { 'erode_rocksoil', { a = a, iterations = 50 } },
        { 'erode_wind', { a = a, iterations = 40 } },
        { 'erode_glacier', { a = a, iterations = 100, ela = 30 } },
    }
    for _, e in list do
        T(e[1], function()
            local f = Fields.Op(e[1], e[2])
            Fields.Free(f)
        end)
    end
    S:Free()
    return table.concat(out, '\n')
end
