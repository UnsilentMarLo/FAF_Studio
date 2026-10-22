-- The environment libraries: lighting / water / sky LOOKS and strata THEMES. Shipped ones (data/envlib_looks.lua, data/envlib_themes.lua: the campaign maps and hand made moods, made by
-- editor/tools/gen_env_library.py), the user's own (saved next to the exe: editor_envlooks.lua, editor_envthemes.lua) and ones imported from another map on disk (EdScmapEnv.cpp reads its lighting,
-- water, sky and strata blocks without opening it).
--
-- Looks
--   Looks() -> list { id, name, group, desc, user, t }      t has the shape of ed_scmap_env: { width, light, water = { ..., texts }, sky = { ..., texts, billboards }, lookups, skycube, background }
--   ApplyLook(entry, opts) -> true | false, reason          opts: sections (default LOOK_SECTIONS), blend (0..1: how far to move from the present values), preview (no undo entry; returns the revert function)
--   SaveLook(name, sections) -> entry                       the present environment as a user look      DeleteLook(id)
--   ImportLook(scmapPath, name) -> entry | nil, reason      the look of a map file (a user look)
--   Thumb(kind, id) -> VFS path of the thumbnail picture of a 'look' or 'theme' (editor/tools/gen_env_thumbs.py), or nil
-- Themes
--   Themes() -> list { id, name, group, desc, user, layers = { [0] = { albedo, size, normal, nsize }, ... [9] } }
--   ApplyTheme(entry, opts) -> true | false, reason         opts: clearUnused (remove the textures of layers the theme leaves empty, and what they painted), preview (returns the revert function)
--   SaveTheme(name) -> entry      DeleteTheme(id)      ImportTheme(scmapPath, name) -> entry | nil, reason      CurrentLayers() -> the present layers in the theme shape
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Env = import('/lua/editor/environment.lua')
local World = import('/lua/editor/world.lua')
local Strata = import('/lua/editor/strata.lua')
local History = import('/lua/editor/history.lua')

LOOK_SECTIONS = { 'light', 'water', 'waves', 'sky', 'skyshape', 'cubes' }
USER_LOOKS = 'editor_envlooks.lua'
USER_THEMES = 'editor_envthemes.lua'
THUMBS = '/textures/editor/envthumbs/'

-- ---- text files of the user libraries -------------------------------------------------------------------------------------------------------

local function Serialize(v, pad)
    pad = pad or ''
    local t = type(v)
    if t == 'number' then
        if v == math.floor(v) and math.abs(v) < 1e9 then return string.format('%d', v) end
        return string.format('%.7g', v)
    elseif t == 'string' then
        return string.format('%q', v)
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'table' then
        local keys, array = {}, true
        local n = 0
        for k, _ in v do
            n = n + 1
            table.insert(keys, k)
        end
        for i = 1, n do if v[i] == nil then array = false end end
        if array then
            local flat = true
            for _, x in v do if type(x) == 'table' then flat = false end end
            local parts = {}
            for i = 1, n do parts[i] = Serialize(v[i], pad .. '    ') end
            if flat then return '{ ' .. table.concat(parts, ', ') .. ' }' end
            return '{\n' .. pad .. '    ' .. table.concat(parts, ',\n' .. pad .. '    ') .. ',\n' .. pad .. '}'
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local lines = {}
        for _, k in keys do
            local key = type(k) == 'number' and ('[' .. k .. ']') or (string.find(k, '^[%a_][%w_]*$') and k or ('[' .. string.format('%q', k) .. ']'))
            table.insert(lines, pad .. '    ' .. key .. ' = ' .. Serialize(v[k], pad .. '    ') .. ',')
        end
        return '{\n' .. table.concat(lines, '\n') .. '\n' .. pad .. '}'
    end
    return 'nil'
end

local function ReadFile(file, name)
    local text = ed_read_file(file)
    if not text or text == '' then return {} end
    local fn = loadstring(text)
    if not fn then return {} end
    local env = {}
    setfenv(fn, env)
    if not pcall(fn) then return {} end
    return env[name] or {}
end

local function WriteFile(file, name, list)
    return ed_write_file(file, '-- FAF Studio: ' .. name .. ' (written by the editor)\n' .. name .. ' = ' .. Serialize(list) .. '\n')
end

local function Slug(name)
    local s = string.lower(string.gsub(name or 'look', '[^%w]+', '_'))
    return (string.gsub(s, '^_+', ''))
end

-- ---- looks ----------------------------------------------------------------------------------------------------------------------------------

local shippedLooks = false
local userLooks = false

local function ShippedLooks()
    if not shippedLooks then
        local ok, mod = pcall(import, '/lua/editor/data/envlib_looks.lua')
        shippedLooks = (ok and mod and mod.Looks) or {}
    end
    return shippedLooks
end

local function UserLooks()
    if not userLooks then userLooks = ReadFile(USER_LOOKS, 'UserLooks') end
    return userLooks
end

function Looks()
    local list = {}
    for _, l in UserLooks() do
        table.insert(list, { id = l.id, name = l.name, group = 'My looks', desc = l.desc or '', user = true, t = l.t })
    end
    for _, l in ShippedLooks() do table.insert(list, l) end
    return list
end

function FindLook(id)
    for _, l in Looks() do
        if l.id == id then return l end
    end
    return nil
end

--- The present environment in the shape of a look table (what ed_scmap_env returns).
local function CaptureTable(sections)
    local size = ed_terrain_info()
    local t = { width = (size or 257) - 1, light = {}, water = { texts = {} }, sky = { texts = {} } }
    local parts = Env.Capture(sections)
    local lightKeys, waterKeys = {}, {}
    for _, k in Env.Sections.light.num do lightKeys[k] = true end
    for id, section in Env.Sections do
        for _, k in (section.num or {}) do
            if parts.num[k] ~= nil then
                if lightKeys[k] then t.light[k] = parts.num[k]
                elseif id == 'water' or id == 'waves' or id == 'levels' then t.water[k] = parts.num[k]
                else t.sky[k] = parts.num[k] end
            end
        end
    end
    for k, v in parts.texts do
        if string.sub(k, 1, 6) == 'water_' then t.water.texts[k] = v
        elseif string.sub(k, 1, 4) == 'sky_' then t.sky.texts[k] = v
        else t[k] = v end
    end
    t.sky.billboards = parts.billboards
    t.lookups = parts.lookups
    return t
end

function SaveLook(name, sections)
    local entry = { id = 'user_' .. Slug(name), name = name, desc = 'Saved from this map', t = CaptureTable(sections or LOOK_SECTIONS) }
    local list = UserLooks()
    for i, l in list do
        if l.id == entry.id then table.remove(list, i) break end
    end
    table.insert(list, 1, entry)
    WriteFile(USER_LOOKS, 'UserLooks', list)
    return { id = entry.id, name = entry.name, group = 'My looks', desc = entry.desc, user = true, t = entry.t }
end

function DeleteLook(id)
    local list = UserLooks()
    for i, l in list do
        if l.id == id then
            table.remove(list, i)
            WriteFile(USER_LOOKS, 'UserLooks', list)
            return true
        end
    end
    return false
end

function ImportLook(path, name)
    if not rawget(_G, 'ed_scmap_env') then return nil, 'this engine build cannot read maps (ed_scmap_env)' end
    local t, why = ed_scmap_env(path)
    if not t then return nil, why end
    local entry = { id = 'user_' .. Slug(name), name = name, desc = 'Imported from ' .. tostring(name), t = t }
    local list = UserLooks()
    for i, l in list do
        if l.id == entry.id then table.remove(list, i) break end
    end
    table.insert(list, 1, entry)
    WriteFile(USER_LOOKS, 'UserLooks', list)
    return { id = entry.id, name = name, group = 'My looks', desc = entry.desc, user = true, t = t }
end

--- Applies a look. opts.sections, opts.blend (0..1), opts.preview.
function ApplyLook(entry, opts)
    opts = opts or {}
    if not Env.Available() then return false, 'no map' end
    local sections = opts.sections or LOOK_SECTIONS
    local size = ed_terrain_info()
    local parts = Env.FromMap(entry.t, sections, { size = size and (size - 1) or nil })
    local blend = opts.blend or 1
    if blend < 1 then parts = Env.Blend(Env.Capture(sections), parts, blend) end
    local label = 'look ' .. entry.name
    if opts.merge then return Env.Apply(parts, { label = label, merge = opts.merge, preview = opts.preview }) end
    return Env.Apply(parts, { label = label, preview = opts.preview })
end

-- ---- previews ---------------------------------------------------------------------------------------------------------------------------

-- A preview applies without an undo entry and keeps the function that puts everything back (and one that applies it again). A saved map must not carry a preview: Map.SaveAs calls
-- SuspendPreviews first (everything back) and the function it returns afterwards (the previews again).
local previews = {}

function SetPreview(kind, revert, reapply)
    if previews[kind] then pcall(previews[kind].revert) end
    if revert then previews[kind] = { revert = revert, reapply = reapply } else previews[kind] = nil end
end

function RevertPreview(kind)
    local p = previews[kind]
    if p then
        pcall(p.revert)
        previews[kind] = nil
        return true
    end
    return false
end

function RevertPreviews()
    local any = false
    for kind, _ in previews do
        if RevertPreview(kind) then any = true end
    end
    return any
end

function HasPreview(kind)
    return previews[kind] ~= nil
end

function SuspendPreviews()
    local list = {}
    for kind, p in previews do
        pcall(p.revert)
        table.insert(list, { kind = kind, p = p })
    end
    if table.getn(list) == 0 then return false end
    return function()
        for _, e in list do
            if previews[e.kind] == e.p and e.p.reapply then
                local ok, revert = pcall(e.p.reapply)
                if ok and revert then e.p.revert = revert end
            end
        end
    end
end

function Thumb(kind, id)
    local path = THUMBS .. kind .. '_' .. id .. '.dds'
    if DiskGetFileInfo(path) then return path end
    return nil
end

-- ---- themes ---------------------------------------------------------------------------------------------------------------------------------

local shippedThemes = false
local userThemes = false

local function ShippedThemes()
    if not shippedThemes then
        local ok, mod = pcall(import, '/lua/editor/data/envlib_themes.lua')
        shippedThemes = (ok and mod and mod.Themes) or {}
    end
    return shippedThemes
end

local function UserThemes()
    if not userThemes then userThemes = ReadFile(USER_THEMES, 'UserThemes') end
    return userThemes
end

function Themes()
    local list = {}
    for _, t in UserThemes() do
        table.insert(list, { id = t.id, name = t.name, group = 'My themes', desc = t.desc or '', user = true, layers = t.layers })
    end
    for _, t in ShippedThemes() do table.insert(list, t) end
    return list
end

--- The layers of the open map in the theme shape: [0] Base, [1..8] painted layers, [9] Upper; a layer without a texture is left out.
function CurrentLayers()
    local layers = {}
    for _, l in Strata.Layers() do
        if l.albedo and l.albedo ~= '' and l.albedo ~= Strata.CLEAR then
            layers[l.index] = { albedo = l.albedo, size = l.size, normal = l.normal, nsize = l.nsize }
        end
    end
    return layers
end

local function AddUserTheme(entry)
    local list = UserThemes()
    for i, l in list do
        if l.id == entry.id then table.remove(list, i) break end
    end
    table.insert(list, 1, entry)
    WriteFile(USER_THEMES, 'UserThemes', list)
    return { id = entry.id, name = entry.name, group = 'My themes', desc = entry.desc, user = true, layers = entry.layers }
end

function SaveTheme(name)
    return AddUserTheme({ id = 'user_' .. Slug(name), name = name, desc = 'Saved from this map', layers = CurrentLayers() })
end

function DeleteTheme(id)
    local list = UserThemes()
    for i, l in list do
        if l.id == id then
            table.remove(list, i)
            WriteFile(USER_THEMES, 'UserThemes', list)
            return true
        end
    end
    return false
end

function ImportTheme(path, name)
    if not rawget(_G, 'ed_scmap_env') then return nil, 'this engine build cannot read maps (ed_scmap_env)' end
    local t, why = ed_scmap_env(path)
    if not t then return nil, why end
    local layers = {}
    for i, s in (t.strata or {}) do
        if s.albedo and s.albedo ~= '' then layers[i - 1] = { albedo = s.albedo, size = s.size, normal = s.normal, nsize = s.nsize } end
    end
    return AddUserTheme({ id = 'user_' .. Slug(name), name = name, desc = 'Imported from ' .. tostring(name), layers = layers })
end

--- Applies a theme: the textures and tile sizes of the layers it has. opts.clearUnused: layers the theme leaves empty lose their texture and what they painted (painted layers 1..8).
--- opts.preview: no undo entry, the result is a function that puts everything back. Returns true | false, reason (and the revert function).
function ApplyTheme(entry, opts)
    opts = opts or {}
    if not ed_stratum_info() then return false, 'no map' end
    local before, undoParts = {}, {}
    local missing = {}
    for i = 0, 9 do before[i] = Strata.Snapshot(i) end
    local function Put(snapshots)
        for i = 0, 9 do
            local s = snapshots[i]
            if s and s.albedo ~= '' then
                Strata.Restore(s)
            elseif i >= 1 then
                Strata.Clear(i)        -- a layer that had no texture before gets none again (transparent; its mask is not touched)
            end
        end
    end
    local touched = {}
    for i = 0, 9 do
        local l = entry.layers[i]
        if l and l.albedo and l.albedo ~= '' then
            -- a look without a tile size gets the Optimal one for its texture (texscale.lua), the normal map the same as the albedo
            local size = l.size or import('/lua/editor/texscale.lua').Optimal(l.albedo)
            local ok = Strata.SetTexture(i, l.albedo, l.normal or '', size, l.nsize or size)
            if not ok then table.insert(missing, l.albedo) end
            touched[i] = true
        end
    end
    local removals = {}
    if opts.clearUnused then
        for i = 1, 9 do
            if not touched[i] and before[i].albedo ~= '' and before[i].albedo ~= Strata.CLEAR then
                local e = Strata.RemoveTexture(i)
                if e then table.insert(removals, e) end
            end
        end
    end
    local after = {}
    for i = 0, 9 do after[i] = Strata.Snapshot(i) end
    local function Revert()
        for i = table.getn(removals), 1, -1 do removals[i].undo() end
        Put(before)
    end
    local function Redo()
        Put(after)
        for _, e in removals do e.redo() end
    end
    if table.getn(missing) > 0 and not opts.preview then
        LOG('EDITOR theme: textures not found: ' .. table.concat(missing, ', '))
    end
    if opts.preview then return true, Revert, missing end
    History.Push({ label = 'theme ' .. entry.name, undo = Revert, redo = Redo })
    return true, nil, missing
end
