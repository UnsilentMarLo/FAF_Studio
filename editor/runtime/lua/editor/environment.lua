-- The environment of the open map as one model with undo: lighting, fog, bloom and water numbers (EdWorld.cpp, world.lua), and the sky dome, sky billboards (sun / moon / planets), cirrus layers, wave
-- motion, texture paths (sky atlases, cirrus, water ramp / cube map / four wave normal maps, sky cube, background), the environment cube lookups and the strategic imager colours (EdEnv.cpp).
-- The engine writes all of it into the .scmap on save (the sky block, the water block, the cube maps), so there is nothing to save here.
--
--   Value(name) -> number         one of the names of ed_world_get / ed_env_get
--   Text(name) -> string          a texture path (sky_billboards, sky_glow, sky_cumulus1..3, sky_cirrus, skycube, background, water_cubemap, water_ramp, water_wave1..4)
--   Billboards() -> list of { x, y, z, rot, sx, sy, u, v, du, dv }      Lookups() -> list of { key, path }
--   Apply(parts, opts)            parts = { num = { name = value }, texts = { name = path }, billboards = list | nil, lookups = list | nil }: ONE undo entry.
--                                 opts: label, merge (a key: applies with the same key within 1.5 s fold into one entry: a slider drag), preview (no entry: returns a revert function)
--   Capture(sections) -> parts    the current values of the named sections (see SECTIONS)
--   FromMap(t, sections, opts)    parts from the table ed_scmap_env made (opts.size = the size of this map: the sky is scaled to it)
--   Blend(a, b, t) -> parts       numbers between a and b (t 0..1), paths and lists from b when t >= 0.5
--   Sections, SectionOrder        the groups: light, water, waves, sky, skyshape, cubes, imager, levels
--   Listen(fn)                    fn() after every change, undo and redo
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local History = import('/lua/editor/history.lua')
local World = import('/lua/editor/world.lua')

local function Range(prefix, n0, n1, suffix)
    local list = {}
    for i = n0, n1 do table.insert(list, prefix .. i .. (suffix or '')) end
    return list
end

local function Join(...)
    local out = {}
    for i = 1, arg.n do for _, k in arg[i] do table.insert(out, k) end end
    return out
end

local function Cirrus()
    local list = {}
    for i = 1, 4 do
        for _, s in { '_fx', '_fz', '_speed', '_dx', '_dz' } do table.insert(list, 'cirrus' .. i .. s) end
    end
    return list
end

SectionOrder = { 'light', 'water', 'waves', 'sky', 'skyshape', 'cubes', 'imager', 'levels' }

--- Which names belong to which group. `num` = numbers, `texts` = paths, `lists` = 'billboards' / 'lookups'.
Sections = {
    light = { label = 'Lighting, fog, bloom', num = { 'light_mult', 'sun_x', 'sun_y', 'sun_z', 'ambient_r', 'ambient_g', 'ambient_b', 'sun_r', 'sun_g', 'sun_b', 'fill_r', 'fill_g', 'fill_b',
                'spec_r', 'spec_g', 'spec_b', 'spec_a', 'bloom', 'fog_r', 'fog_g', 'fog_b', 'fog_start', 'fog_end' } },
    water = { label = 'Water colour and shading', num = { 'w_color_r', 'w_color_g', 'w_color_b', 'w_lerp_0', 'w_lerp_1', 'w_refraction', 'w_fresnel_bias', 'w_fresnel_power', 'w_unit_refl',
                'w_sky_refl', 'w_shininess', 'w_strength', 'w_sundir_x', 'w_sundir_y', 'w_sundir_z', 'w_suncol_r', 'w_suncol_g', 'w_suncol_b', 'w_sun_refl', 'w_glow' } },
    waves = { label = 'Waves: textures, scale, motion', num = Join(Range('w_repeat_', 0, 3), Range('w_move', 1, 4, '_x'), Range('w_move', 1, 4, '_z')),
              texts = { 'water_ramp', 'water_cubemap', 'water_wave1', 'water_wave2', 'water_wave3', 'water_wave4' } },
    sky = { label = 'Sky: colours, clouds, billboards', num = Join({ 'horizon_r', 'horizon_g', 'horizon_b', 'sky_r', 'sky_g', 'sky_b', 'horizon_blend', 'cirrus_mult', 'cirrus_r', 'cirrus_g', 'cirrus_b' }, Cirrus()),
            texts = { 'sky_billboards', 'sky_glow', 'sky_cumulus1', 'sky_cumulus2', 'sky_cumulus3', 'sky_cirrus' }, lists = { 'billboards' } },
    skyshape = { label = 'Sky dome shape', num = { 'dome_ox', 'dome_oy', 'dome_oz', 'dome_height', 'dome_radius', 'dome_start', 'dome_w', 'dome_h', 'horizon_size' } },
    cubes = { label = 'Sky cube, background, environment cubes', texts = { 'skycube', 'background' }, lists = { 'lookups' } },
    imager = { label = 'Strategic view colours', num = Join({ 'topo_samples', 'imager_offset' }, Range('hypso', 0, 4, '_r'), Range('hypso', 0, 4, '_g'), Range('hypso', 0, 4, '_b'), Range('hypso', 0, 4, '_a')) },
    levels = { label = 'Water levels (this map\'s terrain)', num = { 'water_on', 'water_elev', 'water_deep', 'water_abyss' } },
}

local listeners = {}

function Listen(fn)
    table.insert(listeners, fn)
end

local function Notify()
    for _, fn in listeners do pcall(fn) end
end

-- the numbers of the engine: the world ones (EdWorld.cpp) and the env ones (EdEnv.cpp), read afresh after every change
local envCache = false
local textCache = false

local function EnvNums()
    if not envCache then envCache = (rawget(_G, 'ed_env_get') and ed_env_get()) or {} end
    return envCache
end

local function EnvTexts()
    if not textCache then textCache = (rawget(_G, 'ed_env_texts') and ed_env_texts()) or {} end
    return textCache
end

function Available()
    return rawget(_G, 'ed_env_get') ~= nil and ed_env_get() ~= nil
end

function Value(name)
    local w = World.Get()[name]
    if w ~= nil then return w end
    return EnvNums()[name] or 0
end

function Has(name)
    return World.Get()[name] ~= nil or EnvNums()[name] ~= nil
end

function Text(name)
    return EnvTexts()[name] or ''
end

function Billboards()
    local flat = (rawget(_G, 'ed_env_sky_decals') and ed_env_sky_decals()) or {}
    local list = {}
    for i = 1, table.getn(flat), 10 do
        if flat[i + 9] then
            table.insert(list, { x = flat[i], y = flat[i + 1], z = flat[i + 2], rot = flat[i + 3], sx = flat[i + 4], sy = flat[i + 5], u = flat[i + 6], v = flat[i + 7], du = flat[i + 8], dv = flat[i + 9] })
        end
    end
    return list
end

local function Flatten(list)
    local flat = {}
    for _, b in list do
        for _, k in { 'x', 'y', 'z', 'rot', 'sx', 'sy', 'u', 'v', 'du', 'dv' } do table.insert(flat, b[k] or 0) end
    end
    return flat
end

function FlatBillboards(list) return Flatten(list) end

function Lookups()
    local flat = (rawget(_G, 'ed_env_lookups') and ed_env_lookups()) or {}
    local list = {}
    for i = 1, table.getn(flat), 2 do
        if flat[i + 1] then table.insert(list, { flat[i], flat[i + 1] }) end
    end
    return list
end

-- ---- capture, apply -------------------------------------------------------------------------------------------------------------------------

local function Copy(t)
    local c = {}
    for k, v in (t or {}) do c[k] = v end
    return c
end

local function CopyList(l)
    local c = {}
    for i, v in (l or {}) do c[i] = v end
    return c
end

--- The current values of the named sections as parts.
function Capture(sections)
    local parts = { num = {}, texts = {}, order = {} }
    for _, id in sections do
        local s = Sections[id]
        if s then
            for _, k in (s.num or {}) do
                if Has(k) then parts.num[k] = Value(k) end
            end
            for _, k in (s.texts or {}) do parts.texts[k] = Text(k) end
            for _, l in (s.lists or {}) do
                if l == 'billboards' then parts.billboards = Flatten(Billboards()) end
                if l == 'lookups' then
                    local flat = {}
                    for _, pair in Lookups() do table.insert(flat, pair[1]) table.insert(flat, pair[2]) end
                    parts.lookups = flat
                end
            end
        end
    end
    return parts
end

--- The names in `parts` with their current values: what an undo has to put back.
local function Before(parts)
    local b = { num = {}, texts = {} }
    for k, _ in (parts.num or {}) do b.num[k] = Value(k) end
    for k, _ in (parts.texts or {}) do b.texts[k] = Text(k) end
    if parts.billboards then b.billboards = Flatten(Billboards()) end
    if parts.lookups then
        local flat = {}
        for _, pair in Lookups() do table.insert(flat, pair[1]) table.insert(flat, pair[2]) end
        b.lookups = flat
    end
    return b
end

local WATER_REFRESH = { water_on = true, water_elev = true, water_deep = true, water_abyss = true }

--- Writes parts into the engine (no history).
local function Write(parts)
    local world, env = {}, {}
    local refresh, anyWorld, anyEnv = false, false, false
    local known = World.Get()
    for k, v in (parts.num or {}) do
        if known[k] ~= nil then
            world[k] = v
            anyWorld = true
            if WATER_REFRESH[k] then refresh = true end
        elseif EnvNums()[k] ~= nil then
            env[k] = v
            anyEnv = true
        end
    end
    if anyWorld then
        ed_world_set(world, refresh)
        World.Invalidate()
    end
    local resetSky = false
    if anyEnv then
        for k, _ in env do
            if k == 'dome_w' or k == 'dome_h' or k == 'dome_ox' or k == 'dome_oy' or k == 'dome_oz' or k == 'dome_height' or k == 'dome_radius' or k == 'dome_start' then resetSky = true end
        end
        ed_env_set(env, resetSky)
    end
    local texts = parts.texts
    if texts and next(texts) then ed_env_set_texts(texts) end
    if parts.billboards then ed_env_set_sky_decals(parts.billboards) end
    if parts.lookups then ed_env_set_lookups(parts.lookups) end
    envCache, textCache = false, false
    Notify()
end

local merge = false      -- { key, entry, time, parts }

--- Applies parts. Returns true, and with opts.preview a function that puts the old values back. One undo entry (a drag of one slider: opts.merge).
function Apply(parts, opts)
    opts = opts or {}
    if not Available() then return false end
    local before = Before(parts)
    local after = { num = Copy(parts.num), texts = Copy(parts.texts), billboards = parts.billboards and CopyList(parts.billboards), lookups = parts.lookups and CopyList(parts.lookups) }
    Write(after)
    if opts.preview then
        return true, function() Write(before) end
    end
    local now = GetSystemTimeSeconds()
    if opts.merge and merge and merge.key == opts.merge and now - merge.time < 1.5 and History.Top() == merge.entry then
        local entry = merge.entry
        local redo = after
        entry.redo = function() Write(redo) end
        merge.time = now
    else
        local entry = {
            label = opts.label or 'environment',
            undo = function() Write(before) end,
            redo = function() Write(after) end,
        }
        History.Push(entry)
        merge = opts.merge and { key = opts.merge, entry = entry, time = now } or false
    end
    return true
end

--- One number or text, with a merge key per name (a slider drag is one undo step).
function SetNumber(name, value, label)
    local num = {}
    num[name] = value
    return Apply({ num = num }, { label = label or name, merge = 'n:' .. name })
end

function SetText(name, path, label)
    local texts = {}
    texts[name] = path
    return Apply({ texts = texts }, { label = label or name })
end

-- ---- from another map, blends --------------------------------------------------------------------------------------------------------------------

--- Parts from the table ed_scmap_env made (the names are the engine's). `sections` picks the groups; opts.size: the size of this map (the sky dome and its billboards are scaled to it).
function FromMap(t, sections, opts)
    opts = opts or {}
    local parts = { num = {}, texts = {} }
    local sky = t.sky
    local ratio = 1
    if opts.size and t.width and t.width > 0 then ratio = opts.size / t.width end
    local function Take(source, key)
        if source and source[key] ~= nil then parts.num[key] = source[key] end
    end
    for _, id in sections do
        local s = Sections[id]
        if s then
            for _, k in (s.num or {}) do
                Take(t.light, k)
                Take(t.water, k)
                Take(sky, k)
                if id == 'levels' then Take(t.water, k) end
            end
            for _, k in (s.texts or {}) do
                local v = (t.water and t.water.texts and t.water.texts[k]) or (sky and sky.texts and sky.texts[k]) or t[k]
                if v ~= nil then parts.texts[k] = v end
            end
            for _, l in (s.lists or {}) do
                if l == 'billboards' and sky and sky.billboards then
                    -- the billboards lie on the dome (absolute positions, a sphere of the dome radius around the dome origin): move and scale them with the dome
                    local ox, oy, oz = sky.dome_ox or ((t.width or 0) / 2), sky.dome_oy or 0, sky.dome_oz or ((t.width or 0) / 2)
                    local nx, ny, nz = ox, oy, oz
                    if opts.size then
                        nx, nz = opts.size / 2, opts.size / 2
                        ny = Value('dome_oy')
                    end
                    local list = {}
                    for i, v in sky.billboards do
                        local k = math.mod(i - 1, 10)
                        if k == 0 then v = nx + (v - ox) * ratio
                        elseif k == 1 then v = ny + (v - oy) * ratio
                        elseif k == 2 then v = nz + (v - oz) * ratio
                        elseif k == 4 or k == 5 then v = v * ratio end        -- the size grows with the map
                        list[i] = v
                    end
                    parts.billboards = list
                end
                if l == 'lookups' and t.lookups then parts.lookups = CopyList(t.lookups) end
            end
        end
    end
    -- the dome is centred on the map and as big as the map: take this map's centre and scale the radius
    if sky and opts.size then
        for _, id in sections do
            if id == 'skyshape' then
                local half = opts.size / 2
                parts.num.dome_ox, parts.num.dome_oz = half, half
                if parts.num.dome_radius then parts.num.dome_radius = parts.num.dome_radius * ratio end
                if parts.num.horizon_size then parts.num.horizon_size = parts.num.horizon_size * ratio end
                if parts.num.dome_height then parts.num.dome_height = Value('dome_height') end        -- keep the dome on this map's water / floor
                if parts.num.dome_oy then parts.num.dome_oy = Value('dome_oy') end
            end
        end
    end
    -- the sky needs a 'skyshape' only when asked; without sky data in the map nothing of it is set
    return parts
end

--- Numbers between a and b; paths and lists from b when t >= 0.5 (from a otherwise).
function Blend(a, b, t)
    local out = { num = {}, texts = {} }
    for k, v in (b.num or {}) do
        local from = (a.num or {})[k]
        if from ~= nil then out.num[k] = from + (v - from) * t else out.num[k] = v end
    end
    local pick = t >= 0.5 and b or a
    for k, v in (b.texts or {}) do
        out.texts[k] = (t >= 0.5 or (a.texts or {})[k] == nil) and v or a.texts[k]
    end
    if b.billboards or a.billboards then out.billboards = pick.billboards or b.billboards or a.billboards end
    if b.lookups or a.lookups then out.lookups = pick.lookups or b.lookups or a.lookups end
    return out
end
