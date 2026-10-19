-- Lua table -> source text, in the form FAF map files use (`_scenario.lua`, `_save.lua`).
--
--   Dump(value, indent)       -> text of one value
--   Chunk({ {'Scenario', tbl}, {'version', 3} })  -> `Name = value` assignments, in the given order
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

local function SortedKeys(t)
    local array = {}
    local n = table.getn(t)
    local isArrayKey = {}
    for i = 1, n do
        isArrayKey[i] = true
    end
    local names = {}
    local others = {}
    for k, v in t do
        if not isArrayKey[k] then
            if type(k) == 'string' then
                table.insert(names, k)
            else
                table.insert(others, k)
            end
        end
    end
    table.sort(names)
    table.sort(others, function(a, b) return tostring(a) < tostring(b) end)
    return n, names, others
end

function Dump(value, indent)
    indent = indent or 0
    local kind = type(value)
    if kind == 'nil' then
        return 'nil'
    elseif kind == 'boolean' then
        return value and 'true' or 'false'
    elseif kind == 'number' then
        return Number(value)
    elseif kind == 'string' then
        return String(value)
    elseif kind ~= 'table' then
        return 'nil'
    end

    if CALLS[value.type] then
        local parts = {}
        for i = 1, table.getn(value) do
            parts[i] = Number(value[i])
        end
        return value.type .. '( ' .. table.concat(parts, ', ') .. ' )'
    end

    local pad = string.rep('    ', indent + 1)
    local n, names, others = SortedKeys(value)
    local lines = {}
    for i = 1, n do
        table.insert(lines, pad .. Dump(value[i], indent + 1) .. ',')
    end
    for _, k in names do
        table.insert(lines, pad .. '[' .. String(k) .. '] = ' .. Dump(value[k], indent + 1) .. ',')
    end
    for _, k in others do
        local key = type(k) == 'number' and Number(k) or String(tostring(k))
        table.insert(lines, pad .. '[' .. key .. '] = ' .. Dump(value[k], indent + 1) .. ',')
    end
    if table.getn(lines) == 0 then
        return '{\n' .. string.rep('    ', indent) .. '}'
    end
    return '{\n' .. table.concat(lines, '\n') .. '\n' .. string.rep('    ', indent) .. '}'
end

--- `assignments` is an array of { name, value }.
function Chunk(assignments)
    local out = {}
    for _, a in assignments do
        table.insert(out, a[1] .. ' = ' .. Dump(a[2], 0) .. '\n')
    end
    return table.concat(out)
end
