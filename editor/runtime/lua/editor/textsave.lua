-- Text-preserving saves of `_save.lua` and `_scenario.lua` (WP3 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md).
--
-- The document keeps these files as Lua tables (map.lua Doc.save / Doc.info), and luaser.lua used to write them whole: sorted keys, no comments, the game's layout lost. Here the file the map was
-- loaded from stays the base: upstream's SaveFile (ed_savefile_*) rewrites only the entries of the markers / areas / armies / chains blocks that changed, an entry only in the values that changed, and
-- ed_luatext_fields finds the values of the scenario's top-level fields so that only the changed ones are replaced.
--
--   Save(original, save)      -> text | nil, why       `_save.lua`: `original` is the file's text, `save` the document's Scenario table
--   Scenario(original, info)  -> text | nil, why       `_scenario.lua`: `info` is the ScenarioInfo table to be written
--
-- Both end with a proof: the new text is run (with FAF's dataInit) and its table must equal the document's. When it does not (a block the parser does not know, a key that was removed, a native that
-- is not there) the result is nil and the caller writes the whole file from the tables as before, so the text-preserving path can only ever give the same data, never different data.
--
-- Lua 5.0 dialect: no `#`, no `%` operator, no string.match.

local Ser = import('/lua/editor/luaser.lua')

local getn, insert, sort, concat = table.getn, table.insert, table.sort, table.concat

local function NewEnv()
    local env = {}
    doscript('/lua/dataInit.lua', env)
    return env
end

--- The value a text stands for, with FAF's STRING / FLOAT / VECTOR3 / GROUP functions available: true, value | false.
local function Eval(env, text)
    local f = loadstring('return ' .. text)
    if not f then return false end
    setfenv(f, env)
    local ok, v = pcall(f)
    if not ok then return false end
    return true, v
end

--- Deep equality of two values (tables by content).
local function Same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in a do
        if not Same(v, b[k]) then return false end
    end
    for k, _ in b do
        if a[k] == nil then return false end
    end
    return true
end

--- Where two values first differ (a path like Scenario.Armies.ARMY_1.Units), for the message of a refused proof; nil when equal.
local function Where(a, b, path)
    if a == b then return nil end
    if type(a) ~= 'table' or type(b) ~= 'table' then return path .. ' (' .. tostring(a) .. ' / ' .. tostring(b) .. ')' end
    for k, v in a do
        local d = Where(v, b[k], path .. '.' .. tostring(k))
        if d then return d end
    end
    for k, _ in b do
        if a[k] == nil then return path .. '.' .. tostring(k) .. ' (missing)' end
    end
end

local WRAPPED = { STRING = true, FLOAT = true, INTEGER = true, BOOLEAN = true }

--- A value in the form the game's save files write it: STRING( 'x' ), FLOAT( 1.000000 ), BOOLEAN( true ), VECTOR3( 1, 2, 3 ); tables as luaser writes them.
local function Wrapped(v, indent)
    local t = type(v)
    if t == 'string' then
        return 'STRING( ' .. Ser.Dump(v) .. ' )'
    elseif t == 'number' then
        return string.format('FLOAT( %f )', v)
    elseif t == 'boolean' then
        return 'BOOLEAN( ' .. (v and 'true' or 'false') .. ' )'
    end
    return Ser.Dump(v, indent or 4)
end

--- A changed value written like the text it replaces: a STRING( ... ) stays one, a plain number stays plain.
local function Like(original, v, indent)
    local _, _, wrap = string.find(original, '^%s*(%u+)%s*%(')
    if wrap and WRAPPED[wrap] then
        local t = type(v)
        if wrap == 'STRING' and t == 'string' then return Wrapped(v) end
        if wrap == 'FLOAT' and t == 'number' then return Wrapped(v) end
        if wrap == 'INTEGER' and t == 'number' then return string.format('INTEGER( %d )', v) end
        if wrap == 'BOOLEAN' and t == 'boolean' then return Wrapped(v) end
        return Wrapped(v, indent)
    end
    if wrap == nil and type(v) ~= 'table' then
        return Ser.Dump(v, 0)
    end
    return Ser.Dump(v, indent or 4)
end

--- The entries of one block: the file's order (the entries still in the document, their texts kept where the value is the same), then the new ones by name.
local function Entries(read, current, env)
    local out, used = {}, {}
    for _, o in read do
        local cur = current[o.name]
        if cur then
            used[o.name] = true
            local keys, values, seen = {}, {}, {}
            for i = 1, getn(o.keys) do
                local k = o.keys[i]
                local v = cur[k]
                if v ~= nil then
                    seen[k] = true
                    local ok, previous = Eval(env, o.values[i])
                    insert(keys, k)
                    insert(values, (ok and Same(previous, v)) and o.values[i] or Like(o.values[i], v, 4))
                end
            end
            local extra = {}
            for k, _ in cur do
                if type(k) == 'string' and not seen[k] then insert(extra, k) end
            end
            sort(extra)
            for _, k in extra do
                insert(keys, k)
                insert(values, Wrapped(cur[k], 4))
            end
            insert(out, { name = o.name, keys = keys, values = values })
        end
    end
    local fresh = {}
    for name, _ in current do
        if not used[name] then insert(fresh, name) end
    end
    sort(fresh)
    for _, name in fresh do
        local keys, values = {}, {}
        local names = {}
        for k, _ in current[name] do
            if type(k) == 'string' then insert(names, k) end
        end
        sort(names)
        for _, k in names do
            insert(keys, k)
            insert(values, Wrapped(current[name][k], 4))
        end
        insert(out, { name = name, keys = keys, values = values })
    end
    return out
end

--- The chains the document has, in the file's order then by name; nil when a chain holds more than a name and its markers (the file's text then stays as it was).
local function ChainList(read, chains)
    local out, used = {}, {}
    local function Add(name, c)
        if type(c) ~= 'table' then return false end
        for k, _ in c do
            if k ~= 'Name' and k ~= 'Markers' then return false end
        end
        local markers = {}
        for _, m in c.Markers or {} do insert(markers, m) end
        insert(out, { name = name, markers = markers })
        return true
    end
    for _, c in read do
        if chains[c.name] then
            used[c.name] = true
            if not Add(c.name, chains[c.name]) then return nil end
        end
    end
    local fresh = {}
    for name, _ in chains do
        if not used[name] then insert(fresh, name) end
    end
    sort(fresh)
    for _, name in fresh do
        if not Add(name, chains[name]) then return nil end
    end
    return out
end

local function SameChains(a, b)
    if getn(a) ~= getn(b) then return false end
    for i = 1, getn(a) do
        if a[i].name ~= b[i].name or getn(a[i].markers) ~= getn(b[i].markers) then return false end
        for j = 1, getn(a[i].markers) do
            if a[i].markers[j] ~= b[i].markers[j] then return false end
        end
    end
    return true
end

function Save(original, save)
    if not (rawget(_G, 'ed_savefile_entries') and rawget(_G, 'ed_savefile_write')) then return nil, 'the exact-save natives are not in this engine' end
    if type(original) ~= 'string' or original == '' or type(save) ~= 'table' then return nil, 'no original text' end
    local read, why = ed_savefile_entries(original)
    if not read then return nil, why end
    local env = NewEnv()
    local master = save.MasterChain and save.MasterChain._MASTERCHAIN_
    local entries = {
        markers = Entries(read.markers, (master and master.Markers) or {}, env),
        areas = Entries(read.areas, save.Areas or {}, env),
        armies = Entries(read.armies, save.Armies or {}, env),
    }
    local chains = ChainList(read.chains, save.Chains or {})
    if chains and not SameChains(chains, read.chains) then entries.chains = chains end
    local text, why2 = ed_savefile_write(original, entries)
    if not text then return nil, why2 end
    -- the proof also for a text that came back unchanged: an edit in a block the parser did not find would be missing from it
    local f = loadstring(text)
    if not f then return nil, 'the text does not compile' end
    local proof = NewEnv()
    setfenv(f, proof)
    local ok, err = pcall(f)
    if not ok then return nil, 'the text does not run: ' .. tostring(err) end
    if not Same(proof.Scenario, save) then return nil, 'the text differs from the document at ' .. tostring(Where(proof.Scenario, save, 'Scenario')) end
    return text
end

-- ---- _scenario.lua -----------------------------------------------------------------------------------------------------------------------------------

local RESERVED = { ['and'] = true, ['break'] = true, ['do'] = true, ['else'] = true, ['elseif'] = true, ['end'] = true, ['false'] = true, ['for'] = true, ['function'] = true,
                   ['if'] = true, ['in'] = true, ['local'] = true, ['nil'] = true, ['not'] = true, ['or'] = true, ['repeat'] = true, ['return'] = true, ['then'] = true,
                   ['true'] = true, ['until'] = true, ['while'] = true }

local function KeyText(k)
    if string.find(k, '^[%a_][%w_]*$') and not RESERVED[k] then return k end
    return "['" .. k .. "']"
end

function Scenario(original, info)
    if not (rawget(_G, 'ed_luatext_fields')) then return nil, 'the exact-save natives are not in this engine' end
    if type(original) ~= 'string' or original == '' then return nil, 'no original text' end
    local fields, span = ed_luatext_fields(original, 'ScenarioInfo')
    if not fields then return nil, span end
    local want = Ser.ScenarioCopy(info)       -- what a full write would hold (the no-rush offsets of every army included)
    local hasNoRush = false
    for _, f in fields do
        if string.find(f.key, '^norushoffset') then hasNoRush = true end
    end
    if not hasNoRush then       -- a scenario that has none does not get them added (an unedited map is saved as it is)
        for k, _ in info do
            if type(k) == 'string' and string.find(k, '^norushoffset') then hasNoRush = true end
        end
        if not hasNoRush then
            for k, _ in want do
                if type(k) == 'string' and string.find(k, '^norushoffset') then want[k] = nil end
            end
        end
    end
    local env = NewEnv()
    local pieces, pos = {}, 1
    local known = {}
    for _, f in fields do
        known[f.key] = true
        local v = want[f.key]
        if v == nil then return nil, 'the key ' .. f.key .. ' was removed' end
        local ok, previous = Eval(env, f.text)
        if not (ok and Same(previous, v)) then
            insert(pieces, string.sub(original, pos, f.from - 1))
            local text
            if string.find(f.key, '^norush') and type(v) == 'number' then text = string.format('%.6f', v) else text = Like(f.text, v, 1) end
            insert(pieces, text)
            pos = f.to + 1
        end
    end
    local fresh = {}
    for k, _ in want do
        if type(k) == 'string' and not known[k] then insert(fresh, k) end
    end
    if getn(fresh) > 0 then
        sort(fresh)
        local last = fields[getn(fields)]
        if not last then return nil, 'no fields to add to' end
        local gap = string.sub(original, last.to + 1, span.to - 1)
        local _, comma = string.find(gap, '^%s*,')
        insert(pieces, string.sub(original, pos, last.to))
        pos = last.to + 1
        if comma then
            insert(pieces, string.sub(original, pos, last.to + comma))
            pos = last.to + comma + 1
        else
            insert(pieces, ',')
        end
        for _, k in fresh do
            local v = want[k]
            local text
            if string.find(k, '^norush') and type(v) == 'number' then text = string.format('%.6f', v) else text = Ser.Dump(v, 1) end
            insert(pieces, '\n    ' .. KeyText(k) .. ' = ' .. text .. ',')
        end
    end
    insert(pieces, string.sub(original, pos))
    local text = concat(pieces)
    local f = loadstring(text)
    if not f then return nil, 'the text does not compile' end
    local proof = NewEnv()
    setfenv(f, proof)
    local ok, err = pcall(f)
    if not ok then return nil, 'the text does not run: ' .. tostring(err) end
    if not Same(proof.ScenarioInfo, want) then return nil, 'the text differs from the scenario at ' .. tostring(Where(proof.ScenarioInfo, want, 'ScenarioInfo')) end
    return text
end
