-- The catalog behind the asset browser (gui/panels_assets.lua): one list of every placeable or usable thing the editor knows, with categories ("facets": faction, tech, layer, type ...)
-- for filtering, search, favourites and recently used, and the actions of an entry (pick, activate, drop into the viewport).
--
--   Kinds                          { id, label }  in tab order: units, props, decals, markers, textures, effects, mods
--   Entries(kind)                  list of entries (cached); kind 'all' = every kind
--     entry = { kind, key, name, sub, tags = { facet = value }, group, source, color, search }
--   Facets(kind)                   { { id, label }, ... } the filters of a kind;  Values(kind, facet)  the values found, sorted
--   Find(kind, opts)               opts { query, filters = { facet = value }, onlyFav, recent } -> list; favourites first, in 'recent' the last used first
--   Thumb(entry)                   vfs path of the picture | nil (a cached thumbnail; asks assetthumbs.lua to make it)
--   Pick(entry) / Activate(entry)  one click / double click: make it the active unit / prop / decal / marker, use a texture on the active layer, play an effect, open a project
--   Droppable(entry)               true for the kinds that can be dragged into the viewport
--   DropAt(entry, wx, wz)          what a drop does: places it (symmetry, one undo step); returns the number placed
--   IsActive(entry)                true when the matching tool places it now (the browser marks it)
--   WorldAt(x, y, frame)           world position under a position of a window when it is over the viewport, else nil
--   Invalidate()                   forget the lists (a mod changed what exists)
--
-- Lua 5.0 dialect.

local Fav = import('/lua/editor/favourites.lua')
local Thumbs = import('/lua/editor/assetthumbs.lua')
local Texmap = import('/lua/editor/texmap.lua')

Kinds = {
    { id = 'units', label = 'Units' },
    { id = 'props', label = 'Props' },
    { id = 'decals', label = 'Decals' },
    { id = 'markers', label = 'Markers' },
    { id = 'textures', label = 'Textures' },
    { id = 'effects', label = 'Effects' },
    { id = 'mods', label = 'Mods' },
}

local FACETS = {
    units = { { 'faction', 'Faction' }, { 'tech', 'Tech' }, { 'layer', 'Layer' }, { 'type', 'Type' } },
    props = { { 'group', 'Environment' }, { 'type', 'Type' } },
    decals = { { 'group', 'Environment' }, { 'type', 'Type' } },
    markers = { { 'type', 'Type' } },
    textures = { { 'group', 'Environment' }, { 'type', 'Map' } },
    effects = { { 'faction', 'Faction' }, { 'type', 'Type' } },
    mods = { { 'type', 'Type' } },
    all = { { 'kind', 'Kind' } },
}

local cache = {}

function Invalidate() cache = {} end

local function Lower(s) return string.lower(tostring(s or '')) end

local function Has(path, words)
    for _, w in words do
        if string.find(path, w, 1, true) then return true end
    end
    return false
end

local function Finish(entry)
    local parts = { Lower(entry.name), Lower(entry.key), Lower(entry.sub), entry.kind }
    for _, v in entry.tags do table.insert(parts, Lower(v)) end
    entry.search = table.concat(parts, ' ')
    return entry
end

-- ---- units ------------------------------------------------------------------------------------------------------------------------------------

local TYPES = {
    { 'COMMAND', 'commander' }, { 'SUBCOMMANDER', 'support commander' }, { 'ENGINEER', 'engineer' }, { 'FACTORY', 'factory' }, { 'TRANSPORTATION', 'transport' },
    { 'ARTILLERY', 'artillery' }, { 'ANTIAIR', 'anti-air' }, { 'SHIELD', 'shield' }, { 'MASSEXTRACTION', 'mass' }, { 'MASSFABRICATION', 'mass' },
    { 'ENERGYPRODUCTION', 'power' }, { 'RADAR', 'intel' }, { 'OMNI', 'intel' }, { 'SONAR', 'intel' }, { 'COUNTERINTELLIGENCE', 'intel' }, { 'DEFENSE', 'defense' },
    { 'SCOUT', 'scout' }, { 'BOMBER', 'bomber' }, { 'GUNSHIP', 'gunship' }, { 'MISSILE', 'missile' }, { 'NUKE', 'missile' }, { 'EXPERIMENTAL', 'experimental' },
    { 'ECONOMIC', 'economy' }, { 'WALL', 'wall' },
}

local function UnitTags(id, bp, faction)
    local set = {}
    for _, cat in bp.Categories or {} do set[cat] = true end
    local tech = (set.COMMAND and 'ACU') or (set.EXPERIMENTAL and 'T4') or (set.TECH3 and 'T3') or (set.TECH2 and 'T2') or (set.TECH1 and 'T1') or 'other'
    local layer = (set.STRUCTURE and 'structure') or (set.AIR and 'air') or (set.NAVAL and 'naval') or (set.LAND and 'land') or 'other'
    local kind = 'other'
    for _, t in TYPES do
        if set[t[1]] then kind = t[2] break end
    end
    if kind == 'other' and layer ~= 'structure' and set.MOBILE then kind = 'combat' end
    return { faction = faction, tech = tech, layer = layer, type = kind }
end

local function BuildUnits()
    local list = {}
    local Units = import('/lua/editor/units.lua')
    for _, e in Units.Catalog() do
        local bp = __blueprints and __blueprints[e.id]
        local entry = {
            kind = 'units', key = e.id, name = (e.desc ~= '' and e.desc) or e.name or e.id, sub = e.id,
            tags = bp and UnitTags(e.id, bp, e.faction) or { faction = e.faction }, group = e.faction,
        }
        table.insert(list, Finish(entry))
    end
    return list
end

-- ---- props, decals, textures ----------------------------------------------------------------------------------------------------------------

local PROP_TYPES = {
    { 'tree', { 'tree', 'palm', 'pine', 'fir', 'conifer', 'birch', 'oak', 'bamboo' } },
    { 'rock', { 'rock', 'boulder', 'stone', 'cliff', 'crystal' } },
    { 'wreck', { 'wreck' } },
    { 'plant', { 'plant', 'grass', 'bush', 'shrub', 'flower', 'reed', 'fern', 'cactus', 'weed', 'vine', 'moss' } },
    { 'structure', { 'ruin', 'building', 'wall', 'pillar', 'tower', 'crate', 'barrel', 'bus', 'car', 'truck', 'fence', 'pipe', 'light', 'pole', 'sign' } },
    { 'debris', { 'debris', 'rubble', 'scrap', 'junk' } },
}

local DECAL_TYPES = {
    { 'crack', { 'crack' } }, { 'crater', { 'crater', 'impact' } }, { 'scorch', { 'scorch', 'burn', 'blast' } }, { 'dirt', { 'dirt', 'mud', 'sand', 'soil' } },
    { 'vegetation', { 'grass', 'moss', 'leaf', 'weed' } }, { 'rock', { 'rock', 'stone', 'gravel' } }, { 'tracks', { 'track', 'road', 'path' } },
    { 'snow / ice', { 'snow', 'ice', 'frost' } }, { 'water', { 'water', 'wave', 'foam', 'shore' } },
}

local function TypeOf(lowerPath, table_, fallback)
    for _, t in table_ do
        if Has(lowerPath, t[2]) then return t[1] end
    end
    return fallback
end

local function BuildProps()
    local list = {}
    local Props = import('/lua/editor/props.lua')
    for _, e in Props.Catalog() do
        local lower = Lower(e.path)
        table.insert(list, Finish({ kind = 'props', key = e.path, name = e.name, sub = e.group, source = e.path, group = e.group,
            tags = { group = e.group, type = TypeOf(lower, PROP_TYPES, 'other') } }))
    end
    return list
end

-- The map's own folder (texmap.lua): its textures are listed beside the game's, in the group 'This map' (a capital letter sorts before the lower case environment names).
local sigs = {}       -- kind -> { sig, at }: what the map folder held when the list was made

local function NoteMapFolder(kind)
    sigs[kind] = { sig = Texmap.Signature(), at = GetSystemTimeSeconds() }
end

--- True when files came or went in the map folder since the list of `kind` was made (looked at most every 2 seconds).
local function MapChanged(kind)
    local s = sigs[kind]
    if not s then return false end
    local now = GetSystemTimeSeconds()
    if now - s.at < 2 then return false end
    s.at = now
    local sig = Texmap.Signature()
    if sig ~= s.sig then
        s.sig = sig
        return true
    end
    return false
end

local function BuildDecals()
    local list = {}
    local Decals = import('/lua/editor/decals.lua')
    for _, f in Texmap.Files{ staged = false } do
        if string.find(f.lower, '/decals/', 1, true) and not string.find(f.lower, 'normal', 1, true) then
            local name = string.gsub(string.gsub(f.name, '%.[dD][dD][sS]$', ''), '_[aA][lL][bB][eE][dD][oO]$', '')
            table.insert(list, Finish({ kind = 'decals', key = f.path, name = name, sub = Texmap.LABEL, source = f.path, group = Texmap.LABEL,
                tags = { group = Texmap.LABEL, type = TypeOf(f.lower, DECAL_TYPES, 'other') } }))
        end
    end
    for _, e in Decals.Catalog() do
        local lower = Lower(e.path)
        table.insert(list, Finish({ kind = 'decals', key = e.path, name = e.name, sub = e.group, source = e.path, group = e.group,
            tags = { group = e.group, type = TypeOf(lower, DECAL_TYPES, 'other') } }))
    end
    NoteMapFolder('decals')
    return list
end

local function BuildTextures()
    local list = {}
    for _, f in Texmap.Files() do
        if not string.find(f.lower, '/decals/', 1, true) then
            local kind = string.find(f.lower, 'normal', 1, true) and 'normal' or 'albedo'
            local name = string.gsub(f.name, '%.[dD][dD][sS]$', '')
            name = string.gsub(name, '_[aA][lL][bB][eE][dD][oO]$', '')
            name = string.gsub(name, '_[nN][oO][rR][mM][aA][lL][sS]?$', '')
            table.insert(list, Finish({ kind = 'textures', key = f.path, name = name .. (kind == 'normal' and ' (normals)' or ''), sub = Texmap.LABEL, source = f.path, group = Texmap.LABEL,
                tags = { group = Texmap.LABEL, type = kind } }))
        end
    end
    NoteMapFolder('textures')
    for _, f in DiskFindFiles('/env', '*.dds') or {} do
        local lower = Lower(f)
        if string.find(lower, '/layers/', 1, true) then
            local kind = (string.find(lower, '_albedo.dds', 1, true) and 'albedo') or (string.find(lower, '_normals.dds', 1, true) and 'normal') or nil
            if kind then
                local name = string.gsub(string.gsub(f, '^.*/', ''), '_[aA][lL][bB][eE][dD][oO]%.dds$', '')
                name = string.gsub(name, '_[nN][oO][rR][mM][aA][lL][sS]%.dds$', '')
                local env = string.gsub(string.sub(lower, 6), '/.*$', '')
                table.insert(list, Finish({ kind = 'textures', key = f, name = name .. (kind == 'normal' and ' (normals)' or ''), sub = env, source = f, group = env,
                    tags = { group = env, type = kind } }))
            end
        end
    end
    table.sort(list, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.name < b.name
    end)
    return list
end

-- ---- markers, effects, mods -------------------------------------------------------------------------------------------------------------------

local function BuildMarkers()
    local list = {}
    local Tools = import('/lua/editor/tools.lua')
    for _, t in Tools.MarkerTypes() do
        table.insert(list, Finish({ kind = 'markers', key = t.name, name = t.name, sub = t.category or '', color = t.color, group = t.category or '',
            tags = { type = t.category or 'marker' } }))
    end
    return list
end

local FX_FACTIONS = { { 'Aeon', 'Aeon' }, { 'UEF', 'UEF' }, { 'Cybran', 'Cybran' }, { 'Seraphim', 'Seraphim' }, { 'Default', 'generic' }, { 'Common', 'generic' } }
local FX_TYPES = {
    { 'muzzle', { 'muzzle' } }, { 'hit', { 'hit', 'impact' } }, { 'beam', { 'beam' } }, { 'trail', { 'trail', 'polytrail' } }, { 'explosion', { 'explosion', 'destroy', 'death' } },
    { 'build', { 'build', 'construct', 'upgrade' } }, { 'ambient', { 'ambient', 'idle', 'glow', 'flare' } }, { 'smoke', { 'smoke', 'fire', 'burn' } },
}

local function BuildEffects()
    local list = {}
    local View = import('/lua/editor/effectview.lua')
    for _, t in View.Templates() do
        local faction = 'generic'
        for _, f in FX_FACTIONS do
            if string.find(t.name, '^' .. f[1]) then faction = f[2] break end
        end
        table.insert(list, Finish({ kind = 'effects', key = t.name, name = t.name, sub = table.getn(t.emitters) .. ' emitters', group = faction,
            tags = { faction = faction, type = TypeOf(Lower(t.name), FX_TYPES, 'other') } }))
    end
    return list
end

local function BuildMods()
    local list = {}
    local ok, Bp = pcall(import, '/lua/editor/bpedit.lua')
    if ok then
        for _, name in Bp.Projects() do
            table.insert(list, Finish({ kind = 'mods', key = name, name = name, sub = 'mod project', group = 'project', tags = { type = 'project' } }))
        end
    end
    return list
end

local BUILDERS = { units = BuildUnits, props = BuildProps, decals = BuildDecals, markers = BuildMarkers, textures = BuildTextures, effects = BuildEffects, mods = BuildMods }

function Entries(kind)
    if cache[kind] and (kind == 'textures' or kind == 'decals') and MapChanged(kind) then
        cache[kind] = nil
        cache.all = nil
    end
    if kind == 'all' and cache.all then
        Entries('textures')            -- (a changed map folder drops the cache of 'all' too)
        Entries('decals')
    end
    if cache[kind] then return cache[kind] end
    local list
    if kind == 'all' then
        list = {}
        for _, k in Kinds do
            for _, e in Entries(k.id) do table.insert(list, e) end
        end
    else
        local build = BUILDERS[kind]
        local ok, res = pcall(build or function() return {} end)
        list = ok and res or {}
        if not ok then WARN('asset catalog ' .. tostring(kind) .. ': ' .. tostring(res)) end
    end
    if kind == 'mods' then return list end      -- (the project list changes while the editor runs: not cached)
    cache[kind] = list
    return list
end

function Facets(kind)
    return FACETS[kind] or {}
end

--- The values a facet takes in a kind, sorted; for 'all' the facet 'kind' lists the kind labels.
function Values(kind, facet)
    local seen, list = {}, {}
    if kind == 'all' and facet == 'kind' then
        for _, k in Kinds do table.insert(list, k.id) end
        return list
    end
    for _, e in Entries(kind) do
        local v = e.tags[facet]
        if v and not seen[v] then
            seen[v] = true
            table.insert(list, v)
        end
    end
    table.sort(list)
    return list
end

-- ---- search ------------------------------------------------------------------------------------------------------------------------------------

local function Words(query)
    local words = {}
    for w in string.gfind(Lower(query), '%S+') do table.insert(words, w) end
    return words
end

--- Entries of a kind matching the words of opts.query (each must occur in the name, key, group or a tag), opts.filters (facet = value) and opts.onlyFav / opts.recent.
function Find(kind, opts)
    opts = opts or {}
    local words = Words(opts.query or '')
    local out = {}
    for _, e in Entries(kind) do
        local ok = true
        for facet, value in opts.filters or {} do
            local have = (facet == 'kind') and e.kind or e.tags[facet]
            if value and value ~= '' and have ~= value then ok = false break end
        end
        if ok then
            for _, w in words do
                if not string.find(e.search, w, 1, true) then ok = false break end
            end
        end
        if ok and opts.onlyFav and not Fav.Is(e.kind, e.key) then ok = false end
        if ok and opts.recent and not Fav.RecentRank(e.kind, e.key) then ok = false end
        if ok then table.insert(out, e) end
    end
    if opts.recent then
        table.sort(out, function(a, b) return Fav.RecentRank(a.kind, a.key) < Fav.RecentRank(b.kind, b.key) end)
    else
        local starred, rest = {}, {}
        for _, e in out do
            if Fav.Is(e.kind, e.key) then table.insert(starred, e) else table.insert(rest, e) end
        end
        for _, e in rest do table.insert(starred, e) end
        out = starred
    end
    return out
end

-- ---- thumbnails --------------------------------------------------------------------------------------------------------------------------------

local iconOk = {}

function Thumb(entry)
    if entry.kind == 'units' then
        -- the game's strategic icon; a unit without one (mod units, campaign specials) has no picture
        local path = '/textures/ui/common/icons/units/' .. string.upper(entry.key) .. '_icon.dds'
        local ok = iconOk[path]
        if ok == nil then
            ok = DiskGetFileInfo(path) and true or false
            iconOk[path] = ok
        end
        return ok and path or nil
    elseif entry.kind == 'props' or entry.kind == 'decals' or entry.kind == 'textures' then
        return Thumbs.Request(entry.kind, entry.key, entry.source, 'assets')
    end
    return nil
end

-- ---- actions -----------------------------------------------------------------------------------------------------------------------------------

local function SelectTool(id)
    local UI = import('/lua/editor/ui.lua')
    local current
    for _, t in UI.Tools do if t.id == UI.State.tool then current = t end end
    if not current or current.id ~= id then UI.SelectTool(id) end
end

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

--- Gives the texture of the entry to the active terrain layer (albedo or normals, by its name); one undo step. Returns true | nil, reason.
local function UseTexture(entry)
    local Strata = import('/lua/editor/strata.lua')
    local UI = import('/lua/editor/ui.lua')
    local i = Strata.Active
    local before = Strata.Snapshot(i)
    if not before then return nil, 'no terrain layer is selected' end
    local albedo, normal = before.albedo, before.normal
    if entry.tags.type == 'normal' then normal = entry.key else albedo = entry.key normal = '' end
    local size, nsize = before.size, before.nsize
    if entry.tags.type ~= 'normal' then size, nsize = import('/lua/editor/texscale.lua').Carry(before.albedo, size, nsize, albedo) end      -- an empty or default tile size becomes the Optimal one
    Strata.SetTexture(i, albedo, normal, size, nsize)
    local after = Strata.Snapshot(i)
    UI.PushEdit({
        label = 'texture of layer ' .. tostring(i),
        -- (Restore does not take a layer back to "no texture": Clear does)
        undo = function() if before.albedo == '' then Strata.Clear(i) else Strata.Restore(before) end end,
        redo = function() Strata.Restore(after) end,
    })
    return true
end

--- Makes the entry the thing the matching tool places and selects that tool.
function Pick(entry)
    Fav.Touch(entry.kind, entry.key)
    if entry.kind == 'units' then
        import('/lua/editor/units.lua').Active = entry.key
        SelectTool('unit')
    elseif entry.kind == 'props' then
        import('/lua/editor/props.lua').Active = entry.key
        -- (an active prop tool, the brush, the eraser or Place prop, stays: picking a prop does not change the tool)
        local now = import('/lua/editor/ui.lua').State.tool
        if now ~= 'prop_place' and now ~= 'prop_erase' then SelectTool('prop') end
    elseif entry.kind == 'decals' then
        import('/lua/editor/decals.lua').Active = entry.key
        local now = import('/lua/editor/ui.lua').State.tool
        if now ~= 'decal_place' and now ~= 'decal_erase' then SelectTool('decal') end
    elseif entry.kind == 'markers' then
        import('/lua/editor/tools.lua').SetMarkerType(entry.key)
        SelectTool('marker')
    end
    return true
end

--- Double click: the entries that are not placed by a tool do their thing.
function Activate(entry)
    Pick(entry)
    if entry.kind == 'textures' then
        local ok, why = UseTexture(entry)
        if not ok then Say(why) end
        return ok
    elseif entry.kind == 'effects' then
        local n = import('/lua/editor/effectview.lua').Play(entry.key)
        if not n then Say('no such effect') end
        return n and true or false
    elseif entry.kind == 'mods' then
        local Bp = import('/lua/editor/bpedit.lua')
        Bp.Open(entry.key)
        pcall(function() import('/lua/editor/gui/shell.lua').ShowWorkspace('Mod') end)
        return true
    end
    return true
end

function Droppable(entry)
    local k = entry.kind
    return k == 'units' or k == 'props' or k == 'decals' or k == 'markers'
end

--- Puts the entry at the world point (wx, wz): at every symmetry image, one undo step. Returns the number placed.
function DropAt(entry, wx, wz)
    local Map = import('/lua/editor/map.lua')
    if not Map.Doc then
        Say('no map document')
        return 0
    end
    Fav.Touch(entry.kind, entry.key)
    if entry.kind == 'units' then
        local Units = import('/lua/editor/units.lua')
        Units.Active = entry.key
        return Units.Place(wx, wz)
    elseif entry.kind == 'props' then
        return import('/lua/editor/props.lua').PlaceAt(entry.key, wx, wz)
    elseif entry.kind == 'decals' then
        return import('/lua/editor/decals.lua').PlaceAt(entry.key, wx, wz)
    elseif entry.kind == 'markers' then
        import('/lua/editor/tools.lua').SetMarkerType(entry.key)
        return import('/lua/editor/ui.lua').PlaceMarkerAt(wx, wz) and 1 or 0
    end
    return 0
end

--- True when the entry is what the matching tool places now.
function IsActive(entry)
    local k = entry.kind
    if k == 'units' then return import('/lua/editor/units.lua').Active == entry.key
    elseif k == 'props' then return import('/lua/editor/props.lua').Active == entry.key
    elseif k == 'decals' then return import('/lua/editor/decals.lua').Active == entry.key
    elseif k == 'markers' then return import('/lua/editor/tools.lua').MarkerType == entry.key
    elseif k == 'mods' then
        local ok, Bp = pcall(import, '/lua/editor/bpedit.lua')
        return ok and Bp.Project == entry.key or false
    end
    return false
end

--- The ground point under position (x, y) of window `frame` (default: the main window), or nil when that is not over the viewport. A drag that started in a pop-out window reports positions
--- of that window; the pointer's screen position is turned into the main window's.
function WorldAt(x, y, frame)
    if frame and frame ~= GetFrame(0) then
        local sp = rawget(_G, 'GetMouseScreenPos') and GetMouseScreenPos()
        local cx, cy = ed_main_window_rect()
        if not sp or not cx then return nil end
        x, y = sp[1] - cx, sp[2] - cy
    end
    local ok, view = pcall(function() return import('/lua/ui/game/worldview.lua').viewLeft end)
    if not ok or not view then return nil end
    if x < view.Left() or x > view.Right() or y < view.Top() or y > view.Bottom() then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end
