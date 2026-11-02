-- Self test of the save path (luaser.lua, map.lua SaveText / PrepareSave / opts.saveText, the sliced text of the autosave). Run in the live editor on any map:
--   return import('/lua/editor/selftest_savejob.lua').Run()
-- The serialiser is compared with a reference copy of the one it replaced (same text for the map's documents and for odd tables), the text made in slices with the text made at once,
-- and a SaveAs with the text made ahead with a plain SaveAs (every file byte for byte).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local Ser = import('/lua/editor/luaser.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

-- ---- the serialiser as it was (a reference) ----
local CALLS = { VECTOR3 = true, VECTOR2 = true, RECTANGLE = true }
local function RNumber(n)
    if n == math.floor(n) and n > -1000000000 and n < 1000000000 then return string.format('%d', n) end
    return string.format('%.7g', n)
end
local function RString(s)
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, "'", "\\'")
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\r', '\\r')
    return "'" .. s .. "'"
end
local function RSortedKeys(t)
    local n = table.getn(t)
    local isArrayKey = {}
    for i = 1, n do isArrayKey[i] = true end
    local names, others = {}, {}
    for k, v in t do
        if not isArrayKey[k] then
            if type(k) == 'string' then table.insert(names, k) else table.insert(others, k) end
        end
    end
    table.sort(names)
    table.sort(others, function(a, b) return tostring(a) < tostring(b) end)
    return n, names, others
end
local function RDump(value, indent)
    indent = indent or 0
    local kind = type(value)
    if kind == 'nil' then return 'nil'
    elseif kind == 'boolean' then return value and 'true' or 'false'
    elseif kind == 'number' then return RNumber(value)
    elseif kind == 'string' then return RString(value)
    elseif kind ~= 'table' then return 'nil' end
    if CALLS[value.type] then
        local parts = {}
        for i = 1, table.getn(value) do parts[i] = RNumber(value[i]) end
        return value.type .. '( ' .. table.concat(parts, ', ') .. ' )'
    end
    local pad = string.rep('    ', indent + 1)
    local n, names, others = RSortedKeys(value)
    local lines = {}
    for i = 1, n do table.insert(lines, pad .. RDump(value[i], indent + 1) .. ',') end
    for _, k in names do table.insert(lines, pad .. '[' .. RString(k) .. '] = ' .. RDump(value[k], indent + 1) .. ',') end
    for _, k in others do
        local key = type(k) == 'number' and RNumber(k) or RString(tostring(k))
        table.insert(lines, pad .. '[' .. key .. '] = ' .. RDump(value[k], indent + 1) .. ',')
    end
    if table.getn(lines) == 0 then return '{\n' .. string.rep('    ', indent) .. '}' end
    return '{\n' .. table.concat(lines, '\n') .. '\n' .. string.rep('    ', indent) .. '}'
end
local function RChunk(assignments)
    local o = {}
    for _, a in assignments do table.insert(o, a[1] .. ' = ' .. RDump(a[2], 0) .. '\n') end
    return table.concat(o)
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
    local function Done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end

    -- ---- odd tables ----
    local odd = {
        { 1, 2, 3, nil, 5 }, { [1] = 'a', [3] = 'c' }, { a = 1, [2.5] = 'x', [true] = 'b', 7, 8 }, {}, { {}, { {} } }, { 'q\'uote', 'new\nline', 'cr\rx', 'back\\slash' },
        { ['key with \' quote'] = 1, ['nl\nkey'] = 2 }, { type = 'VECTOR3', 1, 2.5, -3 }, { type = 'RECTANGLE', 0, 0, 10, 10 }, { type = 'other', 1 }, { x = { y = { z = { 1, 2, { w = 1 } } } } },
        { 1e10, -1e10, 0.1, 1 / 3, 123456789, 1e-7, 2147483648 }, { [0] = 'zero', [-1] = 'neg', 'one' }, 'str', 12, true, false, { f = true, g = false, h = 'x', i = 4.5 },
    }
    local same, which = true, ''
    for i, v in odd do
        if RChunk({ { 'T', v } }) ~= Ser.Chunk({ { 'T', v } }) then same = false which = which .. ' chunk' .. i end
        if RDump(v, 2) ~= Ser.Dump(v, 2) then same = false which = which .. ' dump' .. i end
    end
    check('the serialiser writes the same text as the one it replaced, for odd tables (holes, mixed keys, escapes, calls, numbers)', same, which)

    -- ---- the open map's documents ----
    if not Map.Doc then Map.Load() end
    if not Map.Doc then return 'skipped the document checks (no map)\n' .. Done() end
    local ref = RChunk({ { 'Scenario', Map.Doc.save } })
    check('the document text equals the reference text (' .. string.len(ref) .. ' bytes)', Ser.Chunk({ { 'Scenario', Map.Doc.save } }) == ref)
    check('the scenario info too', Ser.Chunk({ { 'ScenarioInfo', Map.Doc.info } }) == RChunk({ { 'ScenarioInfo', Map.Doc.info } }))

    -- ---- the text in slices ----
    local whole = Map.SaveText()
    local calls, yields = 0, 0
    local function Pace()
        calls = calls + 1
        if math.mod(calls, 3) == 0 then
            yields = yields + 1
            coroutine.yield()
        end
    end
    local co = coroutine.create(function() return Map.SaveText(Pace) end)
    local text, steps = nil, 0
    while steps < 1000000 do
        steps = steps + 1
        local ok, r = coroutine.resume(co)
        if not ok then check('the sliced text runs', false, r) break end
        if coroutine.status(co) == 'dead' then text = r break end
    end
    check('SaveText in slices (a coroutine that yields every third pace call) is the text made at once', text == whole, 'slices ' .. steps)
    check('and it really was cut into pieces', steps > 1 or calls < 3, steps .. ' resumes, ' .. calls .. ' pace calls')

    -- ---- SaveAs with the text made ahead ----
    if rawget(_G, 'ed_map_save') and rawget(_G, 'ed_write_file') then
        local a, b = '../mapout/_selftest_a.v0001', '../mapout/_selftest_b.v0001'
        local stem = '_selftest'
        Map.PrepareSave()
        local ahead = Map.SaveText()
        local sa = Map.SaveAs(a, stem, { saveText = ahead })
        local sb = Map.SaveAs(b, stem)
        check('both saves work', sa ~= nil and sb ~= nil, tostring(sa) .. ' ' .. tostring(sb))
        if sa and sb then
            for _, ext in { '.scmap', '_save.lua', '_script.lua', '_editor.lua' } do
                local da, db = ed_read_file(a .. '/' .. stem .. ext), ed_read_file(b .. '/' .. stem .. ext)
                -- (the map's own folder is inside the files that name its textures: /maps/_selftest_a.v0001/env/layers/maptex_...: the same name for both before comparing)
                if da then da = string.gsub(da, '_selftest_a%.v0001', '_selftest_X.v0001') end
                if db then db = string.gsub(db, '_selftest_b%.v0001', '_selftest_X.v0001') end
                check('SaveAs with the text made ahead writes the same ' .. ext .. ' (' .. (da and string.len(da) or 0) .. ' bytes)', da ~= nil and da == db)
            end
            local sa1 = ed_read_file(a .. '/' .. stem .. '_scenario.lua')
            local sb1 = ed_read_file(b .. '/' .. stem .. '_scenario.lua')
            if sb1 then sb1 = string.gsub(sb1, '_selftest_b%.v0001', '_selftest_a.v0001') end
            check('and the same scenario file (apart from the folder name)', sa1 ~= nil and sa1 == sb1)
        end
    end
    return Done()
end
