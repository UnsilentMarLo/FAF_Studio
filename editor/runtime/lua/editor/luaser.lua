-- Lua table -> source text, in the form FAF map files use (`_scenario.lua`, `_save.lua`).
--
--   Dump(value, indent)       -> text of one value
--   Chunk({ {'Scenario', tbl}, {'version', 3} }[, pace])  -> `Name = value` assignments, in the given order
--
-- Tables tagged by FAF's dataInit helpers (`type = 'VECTOR3' | 'VECTOR2' | 'RECTANGLE'`, array part = the
-- numbers) are written back as calls: VECTOR3( x, y, z ). Everything else is written with `['key'] = value`,
-- array part first, then the string keys sorted so a saved file is stable between saves.
--
-- Lua 5.0 dialect: no `#` length, no `%` operator.

local CALLS = { VECTOR3 = true, VECTOR2 = true, RECTANGLE = true }

local function Number(n)
    if n == math.floor(n) and n > -1000000000 and n < 1000000000 then
        return string.format('%d', n)
    end
    return string.format('%.7g', n)
end

local function String(s)
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, "'", "\\'")
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\r', '\\r')
    return "'" .. s .. "'"
end

-- The text is built into one list of pieces (joined once at the end), not by joining the lines of every table level: a map's save file is megabytes (a mission map: 6 MB, thousands of units) and
-- the per-level copies made the serialiser the slowest part of a save. The output is the same text as ever (selftest_paintundo.lua keeps a reference serialiser and compares).
--
-- `pace` (optional) is called every PACE_EVERY tables: code that serialises a big document in slices passes a function that coroutine.yield()s when its time slice is used up.

local PACE_EVERY = 200
local floor, getn, find, concat, sort, rep = math.floor, table.getn, string.find, table.concat, table.sort, string.rep

local function OtherKeyLess(a, b) return tostring(a) < tostring(b) end

--- A writer: returns Put(value, indent) (appends the text of a value to the list), Finish() (the text of everything put so far) and Raw(text).
local function Writer(pace)
    local buf, n = {}, 0
    local pads, keys = {}, {}
    local visits = 0
    local Put

    local function Pad(k)
        local p = pads[k]
        if not p then
            p = rep('    ', k)
            pads[k] = p
        end
        return p
    end

    local function Quoted(s)
        if find(s, "[\\'\n\r]") then return String(s) end
        return "'" .. s .. "'"
    end

    --- `['name'] = ` of a string key (many tables share their key names: made once).
    local function KeyText(k)
        local t = keys[k]
        if not t then
            t = '[' .. Quoted(k) .. '] = '
            keys[k] = t
        end
        return t
    end

    --- One `pad key value,` line; scalars take one piece.
    local function Entry(pad, keyText, v, indent)
        local kind = type(v)
        n = n + 1
        if kind == 'number' then
            buf[n] = pad .. keyText .. Number(v) .. ',\n'
        elseif kind == 'string' then
            buf[n] = pad .. keyText .. Quoted(v) .. ',\n'
        elseif kind == 'boolean' then
            buf[n] = pad .. keyText .. (v and 'true' or 'false') .. ',\n'
        elseif kind == 'table' then
            buf[n] = pad .. keyText
            Put(v, indent)
            n = n + 1
            buf[n] = ',\n'
        else
            buf[n] = pad .. keyText .. 'nil,\n'
        end
    end

    Put = function(value, indent)
        local kind = type(value)
        if kind ~= 'table' then
            n = n + 1
            if kind == 'number' then
                buf[n] = Number(value)
            elseif kind == 'string' then
                buf[n] = Quoted(value)
            elseif kind == 'boolean' then
                buf[n] = value and 'true' or 'false'
            else
                buf[n] = 'nil'
            end
            return
        end
        visits = visits + 1
        if pace and visits >= PACE_EVERY then
            visits = 0
            pace()
        end

        local call = value.type
        if CALLS[call] then
            local parts = {}
            for i = 1, getn(value) do
                parts[i] = Number(value[i])
            end
            n = n + 1
            buf[n] = call .. '( ' .. concat(parts, ', ') .. ' )'
            return
        end

        local len = getn(value)
        local names, nn, others, no
        for k, _ in value do
            if type(k) == 'number' and k >= 1 and k <= len and k == floor(k) then
                -- an array key (written below, in order)
            elseif type(k) == 'string' then
                if not names then names, nn = {}, 0 end
                nn = nn + 1
                names[nn] = k
            else
                if not others then others, no = {}, 0 end
                no = no + 1
                others[no] = k
            end
        end
        if len == 0 and not names and not others then
            n = n + 1
            buf[n] = '{\n' .. Pad(indent) .. '}'
            return
        end
        n = n + 1
        buf[n] = '{\n'
        local pad = Pad(indent + 1)
        for i = 1, len do
            Entry(pad, '', value[i], indent + 1)
        end
        if names then
            sort(names)
            for i = 1, nn do
                local k = names[i]
                Entry(pad, KeyText(k), value[k], indent + 1)
            end
        end
        if others then
            sort(others, OtherKeyLess)
            for i = 1, no do
                local k = others[i]
                local keyText = '[' .. (type(k) == 'number' and Number(k) or String(tostring(k))) .. '] = '
                Entry(pad, keyText, value[k], indent + 1)
            end
        end
        n = n + 1
        buf[n] = Pad(indent) .. '}'
    end

    local function Raw(text)
        n = n + 1
        buf[n] = text
    end

    return Put, function() return concat(buf) end, Raw
end

function Dump(value, indent)
    local put, finish = Writer()
    put(value, indent or 0)
    return finish()
end

--- `assignments` is an array of { name, value }. `pace` (optional): see above.
function Chunk(assignments, pace)
    local put, finish, raw = Writer(pace)
    for _, a in assignments do
        raw(a[1] .. ' = ')
        put(a[2], 0)
        raw('\n')
    end
    return finish()
end

local RESERVED = { ['and'] = true, ['break'] = true, ['do'] = true, ['else'] = true, ['elseif'] = true, ['end'] = true, ['false'] = true, ['for'] = true, ['function'] = true,
                   ['if'] = true, ['in'] = true, ['local'] = true, ['nil'] = true, ['not'] = true, ['or'] = true, ['repeat'] = true, ['return'] = true, ['then'] = true,
                   ['true'] = true, ['until'] = true, ['while'] = true }

--- The text of a `_scenario.lua` in the form the game's own maps have: `key = value` for names that are identifiers (`['standard']` stays quoted, as in the game's files), the no-rush radius
--- and offsets as numbers with decimals, and an offset of 0 for every army (norushoffsetX_ARMY_1 ... Y). `info` is not changed.
function ScenarioChunk(info)
    local copy = {}
    for k, v in info do copy[k] = v end
    local std = info.Configurations and info.Configurations.standard
    local armies = std and std.teams and std.teams[1] and std.teams[1].armies
    for _, name in armies or {} do
        if copy['norushoffsetX_' .. name] == nil then copy['norushoffsetX_' .. name] = 0 end
        if copy['norushoffsetY_' .. name] == nil then copy['norushoffsetY_' .. name] = 0 end
    end
    local text = Chunk({ { 'version', 3 }, { 'ScenarioInfo', copy } })
    local out = {}
    for line in string.gfind(text, '[^\n]+') do
        local rest
        local s, e, p, k = string.find(line, "^(%s*)%['([%a_][%w_]*)'%] = ")
        if s and k ~= 'standard' and not RESERVED[k] then
            rest = string.sub(line, e + 1)
            if string.find(k, '^norush') then
                local _, _, num, tail = string.find(rest, '^(%-?%d+),(.*)$')
                if num then rest = string.format('%d.000000,', tonumber(num)) .. tail end
            end
            line = p .. k .. ' = ' .. rest
        end
        table.insert(out, line)
    end
    return table.concat(out, '\n') .. '\n'
end
