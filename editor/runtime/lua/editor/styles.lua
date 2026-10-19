-- Environment styles: the look of a map (sun, lighting, ambient and fog, water colours and waves) as a small text file that can be saved and loaded onto another map
-- (GPG editor: export / import of lighting and water; Unity: presets). The three water elevations belong to the terrain of one map and are not part of a style unless asked for.
--
--   Text(withLevels)          -> the style file text: `Style = { light_mult = 1.5, ... }` (sorted keys, stable diffs)
--   Save(path, withLevels)    -> true | false, reason
--   Parse(text)               -> table of key -> number, or nil and a reason
--   Load(path, withLevels)    -> number of values applied (one undo step), or 0 and a reason
--
-- Lua 5.0 dialect.

local World = import('/lua/editor/world.lua')

local LEVELS = { water_elev = true, water_deep = true, water_abyss = true, water_on = true }

local function Keys(withLevels)
    local list = {}
    for k, v in World.Get() do
        if type(v) == 'number' and (withLevels or not LEVELS[k]) then table.insert(list, k) end
    end
    table.sort(list)
    return list
end

function Text(withLevels)
    local lines = { '-- FAF Studio environment style: lighting, ambient, fog and water look' .. (withLevels and ' (with water levels)' or ''), 'Style = {' }
    local all = World.Get()
    for _, k in Keys(withLevels) do
        table.insert(lines, string.format('    %s = %.6g,', k, all[k]))
    end
    table.insert(lines, '}')
    return table.concat(lines, '\n') .. '\n'
end

function Save(path, withLevels)
    if not ed_world_get() then return false, 'no map' end
    if ed_write_file(path, Text(withLevels)) then return true end
    return false, 'could not write ' .. tostring(path)
end

function Parse(text)
    local fn, err = loadstring(text or '')
    if not fn then return nil, tostring(err) end
    local env = {}
    setfenv(fn, env)
    local ok, why = pcall(fn)
    if not ok then return nil, tostring(why) end
    if type(env.Style) ~= 'table' then return nil, 'the file holds no Style table' end
    local out = {}
    for k, v in env.Style do
        if type(k) == 'string' and type(v) == 'number' then out[k] = v end
    end
    return out
end

function Load(path, withLevels)
    local text = ed_read_file(path)
    if not text then return 0, 'could not read ' .. tostring(path) end
    local style, why = Parse(text)
    if not style then return 0, why end
    local known = World.Get()
    local fields, n = {}, 0
    for k, v in style do
        if known[k] ~= nil and (withLevels or not LEVELS[k]) then fields[k] = v n = n + 1 end
    end
    if n == 0 then return 0, 'no known values in the file' end
    if not World.Change(fields, { label = 'load environment style', refresh = true }) then return 0, 'no map' end
    return n
end
