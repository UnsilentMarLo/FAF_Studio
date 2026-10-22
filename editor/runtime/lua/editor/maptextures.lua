-- The map-wide textures of the terrain shaders: a normal map, a lighting (shadow) texture, a specular texture and a macrotexture. They are not painted like the texture layers: one picture
-- covers the whole map. The engine has no slot of its own for them; FAF's shaders (effects/terrain.fx) read them from texture layers that the newer shaders do not use as layers:
--
--   shader                          normal map (x, z)          lighting texture                          other
--   TTerrainXPExt, Terrain000/050   layer 8 normal (A = x,     layer 8 albedo (R water depth, G ambient  Upper albedo: macrotexture (RGB) + opacity (A)
--                                   R = G = B = z)             occlusion, B copy of G, A cast shadow)
--   Terrain001/051                  as above                   as above                                  Upper albedo: specular colour (RGB) + sharpness (A)
--   Terrain1xx / 2xx (PBR)          as above                   as above                                  (the Upper layer is a tiled PBR atlas there, not a map-wide texture)
--   Terrain301                      Upper albedo (R = x, G = z) together with B water depth and A shadow
--
-- The shaders only use the map-wide normal / lighting texture when the layer's tile size is bigger than the map (tile value < 1: terrain.fx ShaderUsesTerrainInfoTexture and
-- UseMapNormalFromTexture), so a texture written here gets the size map + 1. A map normal map replaces the normals the engine computes from the heights: after sculpting it is out of date until
-- it is made again (Generate / the graph's Output: map normal map); Clear gives the engine's own normals back.
--
-- Files: a texture made here is a DXT5 DDS named maptex_<kind>_<n>.dds in a staging folder (../maptex, mounted at /edmaptex) that the layer points to; saving the map copies the files that the
-- layers use into <map folder>/env/layers and points the layers there (PrepareSave, called by map.lua), and removes older maptex_* files nobody uses. A new file gets a new number every
-- time, because the engine keeps textures by path.
--
--   Order, Kinds                  the four kinds and what they are
--   ShaderClass(id) / Slot(kind[, shaderId]) -> slot | nil, why        which layer slot the shader reads the kind from
--   Current(kind) -> info         { slot, path, size, file, empty, active, managed, class }
--   Stale(kind) -> bool       made from the terrain here, and the terrain (or the sun) changed since, or the map was resized after it was made;   StaleReason(kind) -> 'terrain' | 'resized' | nil
--   AfterResize(oldSize, newSize) -> list of kinds    Map > Resize (resize.lua): the map-wide layers get the tile size of the new map so they stay active, and are marked out of date
--   Generate(kind, o) -> entry | nil, message         from the map's heights and lighting (o: size, strength, soft, quality, reach, ao, ambient); one undo entry
--   FromGraph(kind, pieces, o) -> entry | nil, message   from the graph's fields (pieces: nx, nz | shadow, ao); o: size, assign
--   Import(kind, file) / Export(kind, file) / Clear(kind) -> entry | true | nil, message
--   Preview(kind, size) -> VFS path of a small opaque picture | nil, message
--   NormalFields(env, h, p) / Lighting(env, h, p) / WaterDepth(env, h)       the generators (shared by the graph nodes and the panel); env = { Op = fn, Add = fn }
--   PrepareSave(diskDir, mount) -> restore function | nil
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Strata = import('/lua/editor/strata.lua')
local World = import('/lua/editor/world.lua')
local Shaders = import('/lua/editor/shaders.lua')

STAGE = '../maptex'
MOUNT = '/edmaptex'

State = { serial = 0, mounted = false, created = {}, thumbs = {}, made = {}, sumVersion = -1, nowSum = '', resized = {} }

Order = { 'normal', 'light', 'specular', 'macro' }

Kinds = {
    normal = { label = 'Normal map', generate = true,
        desc = 'One normal map for the whole ground, instead of normals the engine computes from the heights. The terrain is lit by it, so it can carry detail the heights do not have.',
        usedBy = 'TTerrainXPExt, Terrain000, Terrain001, Terrain050, Terrain051 and the Terrain1xx / 2xx shaders' },
    light = { label = 'Lighting (shadow)', generate = true,
        desc = 'Baked sun shadow (1 = lit, 0 = in shadow), ambient occlusion and water depth for the whole ground. The shader multiplies it into the sun light, so shadows can be soft and long without the cost of live shadows.',
        usedBy = 'TTerrainXPExt, Terrain000, Terrain001, Terrain050, Terrain051, the Terrain1xx / 2xx shaders and Terrain301' },
    specular = { label = 'Specular', generate = false,
        desc = 'How strongly and in what colour the ground shines, as one picture for the whole map (RGB = colour, alpha = sharpness).',
        usedBy = 'Terrain001 and Terrain051' },
    macro = { label = 'Macrotexture', generate = false,
        desc = 'A large colour picture laid over the whole ground to break up repetition (RGB = colour, alpha = how much).',
        usedBy = 'TTerrainXPExt, Terrain000 and Terrain050' },
}

-- Which layer slot each shader reads the kinds from comes from shaders.lua (Profile(id).maps, MapSlots(class)): one table for the editor.

local CH = { 'r', 'g', 'b', 'a' }

local function Basename(path)
    return (string.gsub(path or '', '^.*[/\\]', ''))
end

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

--- An error message without the "file:line:" the interpreter put in front.
local function Clean(err)
    return (string.gsub(tostring(err), '^.-:%d+: ', ''))
end

-- ---- the shader and its slots ----------------------------------------------------------------------------------------------------------------------

--- 'legacy' (TTerrain, TTerrainXP, TTerrainGlow), 'ext' (TTerrainXPExt, Terrain000, Terrain050), 'spec' (Terrain001, Terrain051), 'pbr' (Terrain1xx), 'splat' (Terrain2xx), 'old301' or 'other'.
function ShaderClass(id)
    return Shaders.ClassOf(id)
end

function ShaderId()
    if rawget(_G, 'ed_stratum_shader') then return ed_stratum_shader() or '' end
    return ''
end

--- The layer slot the shader reads `kind` from, or nil and the reason.
function Slot(kind, shaderId)
    local id = shaderId or ShaderId()
    local class = ShaderClass(id)
    local slot = Shaders.MapSlots(class)[kind]
    if slot then return slot end
    local info = Kinds[kind]
    if class == 'legacy' then
        return nil, string.format('%s does not use a map-wide %s (its layers are ordinary texture layers). Choose %s.', id ~= '' and id or 'This shader', string.lower(info and info.label or kind), 'Terrain000 or a later shader in the Layers panel')
    end
    return nil, string.format('%s does not use a map-wide %s. Used by: %s.', id ~= '' and id or 'This shader', string.lower(info and info.label or kind), info and info.usedBy or '?')
end

--- The side of the map in world units, or nil without a terrain.
function MapSize()
    local w = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    if not w then return nil end
    return w - 1
end

local function IsEmptyPath(path)
    if not path or path == '' then return true end
    local p = string.lower(path)
    return p == string.lower(Strata.CLEAR) or p == string.lower(Strata.NONE_NORMAL)
end

function Managed(path)
    return path ~= nil and string.find(string.lower(Basename(path)), '^maptex_%a+_%d+%.dds$') ~= nil
end

--- What the slot of `kind` holds now: { kind, class, slot, why, path, size, file, empty, active, managed }.
function Current(kind)
    local id = ShaderId()
    local info = { kind = kind, shader = id, class = ShaderClass(id) }
    local slot, why = Slot(kind, id)
    info.slot, info.why = slot, why
    if not slot then return info end
    local path, size = ed_stratum_layer(slot.layer)
    info.path, info.size = path or '', size or 0
    info.file = Basename(info.path)
    local W = MapSize() or 0
    info.empty = IsEmptyPath(info.path) or (slot.tile and (info.size or 0) <= W)
    info.active = not info.empty
    info.managed = Managed(info.path)
    return info
end

-- ---- staging ----------------------------------------------------------------------------------------------------------------------------------------

local function MapVfs()
    local ok, dir = pcall(function() return import('/lua/editor/maps.lua').saveDir end)
    if ok and dir and dir ~= '' then
        return '/maps/' .. string.lower(Basename(dir)), dir
    end
    return nil
end

local function SlotSerial()
    local top = 0
    for _, i in { 8, 9, 18, 19 } do
        local path = ed_stratum_layer(i)
        local _, _, n = string.find(string.lower(path or ''), 'maptex_%a+_(%d+)%.dds$')
        if n and tonumber(n) > top then top = tonumber(n) end
    end
    return top
end

--- Makes sure the staging folder exists (ed_write_file creates the folders above a file).
function EnsureStage()
    if not State.stageMade then
        State.stageMade = ed_write_file(STAGE .. '/readme.txt', 'Map textures made by the editor (maptex_*.dds) wait here until the map is saved; they are copied into the map folder then.\n') and true or false
    end
end

--- A file name nobody has used in this session or in the map's folder.
function NextName(kind)
    if State.serial < SlotSerial() then State.serial = SlotSerial() end
    local mapVfs = MapVfs()
    while true do
        State.serial = State.serial + 1
        local name = 'maptex_' .. kind .. '_' .. State.serial .. '.dds'
        local taken = ed_file_exists(STAGE .. '/' .. name)
        if not taken and mapVfs then
            local ok, info = pcall(DiskGetFileInfo, mapVfs .. '/env/layers/' .. name)
            taken = ok and info ~= nil and info ~= false
        end
        if not taken then return name end
    end
end

--- Runs writer(diskPath) -> ok, err on a new staged file; returns its VFS path and disk path, or nil and the reason.
function StageFile(kind, writer)
    EnsureStage()
    local name = NextName(kind)
    local disk = STAGE .. '/' .. name
    local ok, err = writer(disk)
    if not ok then return nil, err or 'the file could not be written' end
    if not State.mounted then
        if ed_vfs_mount(STAGE, MOUNT) then State.mounted = true end
    end
    table.insert(State.created, { vfs = MOUNT .. '/' .. name, disk = disk })
    return MOUNT .. '/' .. name, disk
end

--- Deletes staged files nothing uses any more (the newest few stay so that undo can reach them).
function Prune()
    local keep = {}
    for _, i in { 8, 9, 18, 19 } do
        local path = ed_stratum_layer(i)
        if path then keep[string.lower(path)] = true end
    end
    local list = State.created
    while table.getn(list) > 6 do
        local f = table.remove(list, 1)
        if not keep[string.lower(f.vfs)] and rawget(_G, 'ed_file_delete') then pcall(ed_file_delete, f.disk) end
    end
end

-- ---- writing a picture from fields ---------------------------------------------------------------------------------------------------------------

--- Writes the four channels { r, g, b, a } (fields of 0..1; the same field may stand for several channels) as a size x size DXT5 DDS with mip maps. `prepare(f)` turns a field into
--- one of size x size samples (a new field the caller does not own; it is freed here). Returns true, or nil and a message.
function WriteChannels(chan, path, size, prepare)
    local n = size * size
    local px = {}
    for i = 1, n * 4 do px[i] = 0 end
    local lastHandle, lastField = nil, nil
    local ok, err = pcall(function()
        for c = 1, 4 do
            local f = chan[CH[c]]
            if f ~= lastHandle then
                if lastField then Fields.Free(lastField) lastField = nil end
                lastField = prepare(f)
                lastHandle = f
            end
            -- 256 x 256 samples at a time (ed_field_read gives at most 65536)
            for z0 = 0, size - 1, 256 do
                local z1 = math.min(size - 1, z0 + 255)
                for x0 = 0, size - 1, 256 do
                    local x1 = math.min(size - 1, x0 + 255)
                    local vals = Fields.Read(lastField, x0, z0, x1, z1)
                    local tw = x1 - x0 + 1
                    local idx = 0
                    for z = z0, z1 do
                        local base = (z * size + x0) * 4 + c
                        for x = 0, tw - 1 do
                            idx = idx + 1
                            local v = vals[idx] * 255
                            if v < 0 then v = 0 elseif v > 255 then v = 255 end
                            px[base + x * 4] = v
                        end
                    end
                end
            end
        end
    end)
    if lastField then Fields.Free(lastField) end
    if not ok then return nil, tostring(err) end
    local bytes, werr = ed_dds_write(path, size, size, px, 16)
    if not bytes then return nil, tostring(werr) end
    return true
end

--- A preparer for fields of the map (world units, vertices at whole numbers): samples them at the centres of size x size squares over the map, which is where the engine's own normal map
--- takes its samples.
function MapPrepare(size, W)
    local cell = W / size
    local like = Fields.New(size, size, 0, cell, cell * 0.5, cell * 0.5)
    local function Prepare(f)
        return Fields.Op('resample', { a = f, like = like })
    end
    return Prepare, function() Fields.Free(like) end
end

function TextureSize(choice, W)
    local s = tonumber(choice)
    if not s or s <= 0 then s = math.min(W or 512, 1024) end
    s = math.max(64, math.min(2048, math.floor(s)))
    return s
end

-- ---- the generators (shared by the graph nodes and the panel) ---------------------------------------------------------------------------------------

--- The map normal of the engine from heights `h`: x, y, z as fields of 0..1 (n * 0.5 + 0.5). p: strength (1 = the real slope), span (units), squares (true: placed on the centres of the
--- map squares like the engine's normal map). env.Add(f) registers a field the caller frees.
function NormalFields(env, h, p)
    p = p or {}
    local main, extra = Fields.OpMulti('normal_map', { a = h, span = p.span or 1, strength = p.strength or 1, shift = (p.squares == false) and 0 or 0.5 })
    if not main then error(tostring(extra)) end
    env.Add(main)
    env.Add(extra.y)
    env.Add(extra.z)
    return main, extra.y, extra.z
end

--- Depth of the water over the ground 0..1 (0 on land, 1 at the abyss depth), what the R channel of the lighting texture holds.
function WaterDepth(env, h)
    local w = World.Get()
    local elev, abyss = w.water_elev or 25, w.water_abyss or 0
    if (w.water_on or 1) == 0 then return env.Op('affine', { a = h, mul = 0, add = 0 }) end
    local range = elev - abyss
    if range < 1 then range = 1 end
    local d = env.Op('affine', { a = h, mul = -1 / range, add = elev / range })
    return env.Op('clamp', { a = d, lo = 0, hi = 1 })
end

--- Directions (azimuth, altitude) that sample the disc of the sun: 1, 5 or 9 of them.
function SunSamples(az, alt, soft, count)
    local list = { { az, alt } }
    if count >= 5 and soft > 0 then
        for _, d in { { soft, 0 }, { -soft, 0 }, { 0, soft }, { 0, -soft } } do
            table.insert(list, { az + d[1], math.max(1, math.min(89, alt + d[2])) })
        end
    end
    if count >= 9 and soft > 0 then
        local s = soft * 0.7
        for _, d in { { s, s }, { s, -s }, { -s, s }, { -s, -s } } do
            table.insert(list, { az + d[1], math.max(1, math.min(89, alt + d[2])) })
        end
    end
    return list
end

--- Ambient occlusion of heights `h` as a field (1 = open sky, lower in pits and gullies); strength 0..1, radius in units.
function Occlusion(env, h, strength, radius)
    local occ = env.Op('occlusion', { a = h, mode = 'cavity', radius = radius or 40, directions = 12, gain = 2 })
    return env.Op('affine', { a = occ, mul = -strength, add = 1 })
end

--- Baked sun shadow of heights `h`: returns lit (1 = sun, 0 = shadow), light (lit * N.L with some ambient; nil unless p.light), ao (1 = open, nil unless p.ao > 0). p: azimuth, altitude (degrees,
--- towards the sun, 0 = +x, 90 = +z), soft (degrees, the size of the sun: soft shadow edges), quality (1, 5 or 9 samples of the sun disc), reach (units a shadow can be cast), ambient, ao (strength),
--- aoRadius (units).
function Lighting(env, h, p)
    local az, alt = p.azimuth or 315, p.altitude or 40
    local samples = SunSamples(az, alt, p.soft or 0, p.quality or 5)
    local acc = nil
    for _, s in samples do
        local f = env.Op('hillshade', { a = h, mode = 'shadow', azimuth = s[1], altitude = s[2], shadow_len = p.reach or 400 })
        if acc then acc = env.Op('add', { a = acc, b = f }) else acc = f end
    end
    local lit = env.Op('affine', { a = acc, mul = -1 / table.getn(samples), add = 1 })
    local light, ao = nil, nil
    if p.light then
        local ndl = env.Op('hillshade', { a = h, mode = 'shade', shadows = 0, azimuth = az, altitude = alt, ambient = 0, shadow_len = p.reach or 400 })
        local amb = p.ambient or 0.25
        light = env.Op('affine', { a = env.Op('mul', { a = ndl, b = lit }), mul = 1 - amb, add = amb })
    end
    if (p.ao or 0) > 0 then ao = Occlusion(env, h, p.ao, p.aoRadius) end
    return lit, light, ao
end

--- A scope as a generator environment.
local function ScopeEnv(S)
    return { Op = function(name, params) return S:Op(name, params) end, Add = function(f) return S:Add(f) end }
end

--- The channels of the pack `pack` from the fields in `f` (nx, nz, shadow, ao, depth; missing ones become neutral constants).
local function Channels(pack, f, env, h)
    local function Const(v) return env.Op('const', { like = h, value = v }) end
    if pack == 'normal7' then
        return { r = f.nz, g = f.nz, b = f.nz, a = f.nx }
    elseif pack == 'info7' then
        local ao = f.ao or Const(1)
        return { r = f.depth or Const(0), g = ao, b = ao, a = f.shadow or Const(1) }
    elseif pack == 'light301' then
        return { r = f.nx, g = f.nz, b = f.depth or Const(0), a = f.shadow or Const(1) }
    end
    error('no generator for ' .. tostring(pack))
end

-- ---- the layers --------------------------------------------------------------------------------------------------------------------------------------

local function Snapshot(writes)
    local list = {}
    for _, w in writes do
        local path, size = ed_stratum_layer(w.layer)
        table.insert(list, { layer = w.layer, path = path or '', size = size or 4 })
    end
    return list
end

local function Restore(snap)
    for _, s in snap do
        if s.path ~= '' then
            local exists = DiskGetFileInfo(s.path)
            if exists then
                ed_stratum_set_layer(s.layer, s.path, s.size)
            else
                Say('a map texture file is gone (' .. Basename(s.path) .. '): the layer keeps its texture')
            end
        end
    end
end

--- Gives layers new textures: writes = { { layer, path, size }, ... } (layer = the index of ed_stratum_layer). One undo entry (pushed unless o.noPush). Returns the entry, or nil and a message.
function Apply(label, writes, o)
    local before = Snapshot(writes)
    for _, w in writes do
        local ok, err = ed_stratum_set_layer(w.layer, w.path, w.size)
        if not ok then
            Restore(before)
            return nil, 'the texture could not be loaded: ' .. tostring(err or w.path)
        end
    end
    local after = Snapshot(writes)
    local entry = { label = label, undo = function() Restore(before) end, redo = function() Restore(after) end }
    if not (o and o.noPush) then History.Push(entry) end
    Prune()
    return entry
end

local function TileSize(slot)
    local W = MapSize() or 512
    if slot.tile then return W + 1 end
    local path, size = ed_stratum_layer(slot.layer)
    if size and size > 0 and not IsEmptyPath(path) then return size end
    return W + 1
end

local function Assign(kind, slot, vfs, o)
    local info = Kinds[kind]
    local writes = { { layer = slot.layer, path = vfs, size = TileSize(slot) } }
    return Apply('map ' .. string.lower(info.label), writes, o)
end

-- ---- generate ------------------------------------------------------------------------------------------------------------------------------------------

--- Makes the texture of `kind` from the map's heights and lighting and gives it to the shader. o: size (0 or nil = the map's size, at most 1024), strength (normal), soft, quality, reach, ao,
--- ambient (lighting); noPush. Returns the undo entry, or nil and a message.
function Generate(kind, o)
    o = o or {}
    local slot, why = Slot(kind)
    if not slot then return nil, why end
    if not Kinds[kind].generate then return nil, 'there is nothing to make this texture from: import an image' end
    if slot.shared then
        kind = slot.shared
        slot = Slot(kind)
    end
    local W = MapSize()
    if not W then return nil, 'no terrain' end
    local size = TextureSize(o.size, W)
    local sun_az, sun_alt = World.SunAngles()
    local vfs, disk, heightSum
    local ok, err = pcall(function()
        Fields.Run(function(S)
            local h = S:Height(1)
            heightSum = Fields.Checksum(h)
            local env = ScopeEnv(S)
            local f = {}
            local pack = slot.pack
            if pack == 'normal7' or pack == 'light301' then
                f.nx, f.ny, f.nz = NormalFields(env, h, { strength = o.strength or 1 })
            end
            if pack == 'info7' or pack == 'light301' then
                if o.shadow ~= false then          -- o.shadow = false: no baked shadow (alpha 1), only the water depth (Convert layers to a biplanar shader)
                    f.shadow = Lighting(env, h, { azimuth = o.azimuth or sun_az, altitude = o.altitude or sun_alt, soft = o.soft or 1, quality = o.quality or 5, reach = o.reach or 400 })
                end
                if (o.ao or 0) > 0 then f.ao = Occlusion(env, h, o.ao, o.aoRadius) end
                f.depth = WaterDepth(env, h)
            end
            local chan = Channels(pack, f, env, h)
            local prepare, done = MapPrepare(size, W)
            local wrote, werr = pcall(function()
                vfs, disk = StageFile(kind, function(path)
                    local r, e = WriteChannels(chan, path, size, prepare)
                    return r, e
                end)
            end)
            done()
            if not wrote then error(werr) end
            if not vfs then error(disk) end
        end)
    end)
    if not ok then return nil, Clean(err) end
    local entry, aerr = Assign(kind, slot, vfs, o)
    if not entry then return nil, aerr end
    State.made[string.lower(vfs)] = { heights = heightSum, sun = string.format('%.2f,%.2f', sun_az, sun_alt) }
    return entry
end

--- Whether the texture of `kind` was made from the terrain here and the terrain (or, for the lighting texture, the sun) has changed since: it is out of date then. Cheap: the heights are
--- compared only after the document changed.
function Stale(kind)
    return StaleReason(kind) ~= nil
end

--- Why the texture of `kind` is out of date: 'resized' (the map changed size after the picture was made: it still shows the old map), 'terrain' (heights or sun changed since it was made here),
--- or nil.
function StaleReason(kind)
    local cur = Current(kind)
    if not cur.slot or cur.empty then return nil end
    local lowerPath = string.lower(cur.path or '')
    if State.resized[lowerPath] then return 'resized' end
    local made = State.made[lowerPath]
    if not made then return nil end
    local v = History.Version
    if State.sumVersion ~= v then
        State.sumVersion = v
        local f = Fields.Height(1)
        State.nowSum = Fields.Checksum(f)
        Fields.Free(f)
    end
    if made.heights ~= State.nowSum then return 'terrain' end
    if cur.slot.pack ~= 'normal7' then
        local az, alt = World.SunAngles()
        if made.sun ~= string.format('%.2f,%.2f', az, alt) then return 'terrain' end
    end
    return nil
end

--- Map > Resize restores the texture layers of the old map, with their tile sizes: a map-wide picture had the old map size + 1, which is below the new map size when the map grew (the shaders
--- then treat the layer as an ordinary tiled texture and ignore the picture) and wastes the picture's extent when it shrank. The layers that were active get the new map size + 1, so they stay
--- active, and are marked out of date (the picture still shows the old map: Generate again). Returns the kinds changed.
function AfterResize(oldSize, newSize)
    local done, seen = {}, {}
    if not oldSize or not newSize or not rawget(_G, 'ed_stratum_layer') then return done end
    for _, kind in Order do
        local slot = Slot(kind)
        if slot and slot.tile and not seen[slot.layer] then
            seen[slot.layer] = true
            local path, size = ed_stratum_layer(slot.layer)
            if not IsEmptyPath(path) and (size or 0) > oldSize then
                if ed_stratum_set_layer(slot.layer, path, newSize + 1) then
                    State.resized[string.lower(path)] = true
                    table.insert(done, kind)
                end
            end
        end
    end
    return done
end

--- From the fields of the terrain graph (Build): kind 'normal' with pieces.nx and pieces.nz, kind 'light' with pieces.shadow and pieces.ao (optional). o.size (choice or number), o.assign
--- (false: only write the file, next to the map when it has a folder). Returns the undo entry (or the path of the file when only written), a message.
function FromGraph(kind, pieces, o)
    o = o or {}
    local W = MapSize()
    if not W then return nil, 'no terrain' end
    local slot, why = Slot(kind)
    local assign = o.assign ~= false
    if assign and not slot then return nil, why end
    slot = slot or Shaders.MapSlots('ext')[kind]
    if slot and slot.shared then
        kind = slot.shared
        slot = Slot(kind)
    end
    local size = TextureSize(o.size, W)
    local vfs, disk
    local ok, err = pcall(function()
        Fields.Run(function(S)
            local env = ScopeEnv(S)
            local h = S:Height(1)
            local f = {}
            for k, v in pieces do f[k] = v end
            local pack = slot.pack
            if (pack == 'light301') and not f.nx then
                f.nx, f.ny, f.nz = NormalFields(env, h, {})
            end
            if pack == 'info7' or pack == 'light301' then f.depth = WaterDepth(env, h) end
            local chan = Channels(pack, f, env, h)
            local prepare, done = MapPrepare(size, W)
            local wrote, werr = pcall(function()
                vfs, disk = StageFile(kind, function(path)
                    local r, e = WriteChannels(chan, path, size, prepare)
                    return r, e
                end)
            end)
            done()
            if not wrote then error(werr) end
            if not vfs then error(disk) end
        end)
    end)
    if not ok then return nil, Clean(err) end
    if not assign then
        return CopyNextToMap(disk, kind)
    end
    local entry, aerr = Assign(kind, slot, vfs, o)
    if not entry then return nil, aerr end
    return entry
end

--- Copies a staged file next to the map (<map folder>/env/layers) when the map has a folder; returns the path where the file is.
function CopyNextToMap(disk, kind)
    local mapVfs, dir = MapVfs()
    if not dir then return disk, 'written to ' .. disk .. ' (save the map once and it goes next to the map)' end
    local data = ed_read_file(disk)
    local target = dir .. '/env/layers/' .. Basename(disk)
    if data and ed_write_file(target, data) then return target, 'written to ' .. target end
    return disk, 'written to ' .. disk
end

-- ---- import, export, clear ---------------------------------------------------------------------------------------------------------------------------

local function Extension(path)
    return string.lower((string.gsub(path or '', '^.*%.', '')))
end

--- Uses an image file as the texture of `kind`. A DDS is taken as it is (its channels have to be laid out as the shader reads them); another picture (PNG, TGA, JPEG, BMP, TIFF) is stretched
--- to a power of two size at most 2048 and written as a DXT5 DDS.
function Import(kind, file, o)
    local slot, why = Slot(kind)
    if not slot then return nil, why end
    if not file or file == '' then return nil, 'no file' end
    local vfs, disk
    if Extension(file) == 'dds' then
        local w, h = ed_dds_thumb(file, STAGE .. '/check.dds', 4)
        if not w then return nil, 'cannot read ' .. Basename(file) .. ': ' .. tostring(h) end
        local data = ed_read_file(file)
        if not data then return nil, 'cannot read ' .. Basename(file) end
        vfs, disk = StageFile(kind, function(path)
            if ed_write_file(path, data) then return true end
            return false, 'cannot write ' .. path
        end)
        if not vfs then return nil, disk end
    else
        if not rawget(_G, 'ed_img_read') then return nil, 'this build cannot read pictures' end
        local fieldsMade = {}
        local ok, err = pcall(function()
            local chan = {}
            local width, height = 0, 0
            for _, c in CH do
                local f, info = ed_img_read(file, { channel = c })
                if not f then
                    if c == 'a' then
                        f = Fields.New(math.max(width, 2), math.max(height, 2), 1)
                    else
                        error(tostring(info))
                    end
                else
                    width, height = info.width or width, info.height or height
                end
                table.insert(fieldsMade, f)
                chan[c] = f
            end
            local side = 64
            while side < math.max(width, height) and side < 2048 do side = side * 2 end
            local function Prepare(f)
                return Fields.Op('resize', { a = f, width = side, height = side })
            end
            local wrote, werr = nil, nil
            vfs, disk = StageFile(kind, function(path)
                wrote, werr = WriteChannels(chan, path, side, Prepare)
                return wrote, werr
            end)
            if not vfs then error(tostring(disk)) end
        end)
        for _, f in fieldsMade do Fields.Free(f) end
        if not ok then return nil, Clean(err) end
    end
    local entry, aerr = Assign(kind, slot, vfs, o)
    if not entry then return nil, aerr end
    return entry
end

--- Writes the texture of `kind` to a file as it is stored: .dds is a copy of the file, .png the colour channels (and, when the alpha channel is not all white, a second picture
--- <name>_alpha.png). Returns true, or nil and a message.
function Export(kind, dest)
    local cur = Current(kind)
    if not cur.slot then return nil, cur.why end
    if cur.empty then return nil, 'this map has no ' .. string.lower(Kinds[kind].label) .. ' yet' end
    local src = ed_vfs_to_disk(cur.path) or cur.path
    local ext = Extension(dest)
    if ext == 'dds' then
        local data = ed_read_file(src)
        if not data then return nil, 'cannot read ' .. cur.file end
        if not ed_write_file(dest, data) then return nil, 'cannot write ' .. dest end
        return true
    elseif ext == 'png' then
        local px, w, h = ed_dds_read(src)
        if not px then return nil, 'cannot read ' .. cur.file .. ': ' .. tostring(w) end
        if w * h > 1048576 then return nil, 'this picture is too big for PNG export here: export it as DDS' end
        local Png = import('/lua/editor/png.lua')
        local rgb, grey, anyAlpha = {}, {}, false
        for i = 0, w * h - 1 do
            local o = i * 4
            rgb[i + 1] = px[o + 1] * 65536 + px[o + 2] * 256 + px[o + 3]
            local a = px[o + 4]
            if a < 254 then anyAlpha = true end
            grey[i + 1] = a * 65536 + a * 256 + a
        end
        local ok, werr = Png.Write(dest, w, h, rgb)
        if not ok then return nil, tostring(werr) end
        if anyAlpha then
            local alphaPath = string.gsub(dest, '%.[Pp][Nn][Gg]$', '') .. '_alpha.png'
            ok, werr = Png.Write(alphaPath, w, h, grey)
            if not ok then return nil, tostring(werr) end
        end
        return true
    end
    return nil, 'use a .dds or .png file name'
end

--- Takes the texture off: the shader gets the neutral one again (the engine's own normals; no baked shadow; no macrotexture / specular). Returns the undo entry, or nil and a message.
function Clear(kind, o)
    local slot, why = Slot(kind)
    if not slot then return nil, why end
    local path, size
    if slot.layer == 18 or slot.layer == 19 then
        path, size = Strata.NONE_NORMAL, 4
    elseif slot.pack == 'info7' or slot.pack == 'light301' then
        -- Terrain001 and Terrain301 read the shadow of this slot without a size check: a transparent texture would shade the whole map, so the neutral one is white
        local vfs, disk = StageFile('light', function(p)
            local px = {}
            for i = 0, 15 do
                if slot.pack == 'light301' then
                    px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3], px[i * 4 + 4] = 128, 128, 0, 255
                else
                    px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3], px[i * 4 + 4] = 0, 255, 255, 255
                end
            end
            local bytes, err = ed_dds_write(p, 4, 4, px, 1)
            return bytes ~= nil, err
        end)
        if not vfs then return nil, tostring(disk) end
        path, size = vfs, 4
    else
        path, size = Strata.CLEAR, 4
        if not DiskGetFileInfo(path) then return nil, path .. ' is missing (python editor/tools/gen_layer_textures.py writes it)' end
    end
    local entry, err = Apply('clear map ' .. string.lower(Kinds[kind].label), { { layer = slot.layer, path = path, size = size } }, o)
    if not entry then return nil, err end
    return entry
end

-- ---- pictures --------------------------------------------------------------------------------------------------------------------------------------------

--- A small opaque picture of the texture of `kind` (VFS path for a Bitmap), or nil and a message. Remembered while the file stays the same.
function Preview(kind, size)
    local cur = Current(kind)
    if not cur.slot then return nil, cur.why end
    if cur.empty then return nil, 'none' end
    size = size or 96
    local key = cur.path .. '|' .. cur.slot.pack .. '|' .. size
    local cached = State.thumbs[kind]
    if cached and cached.key == key then return cached.vfs end
    local src = ed_vfs_to_disk(cur.path) or cur.path
    local dst = STAGE .. '/thumb_' .. kind .. '.dds'
    local w, h = ed_dds_thumb(src, dst, size)
    if not w then return nil, 'cannot read ' .. cur.file .. ': ' .. tostring(h) end
    local px, tw, th = ed_dds_read(dst)
    if not px then return nil, tostring(tw) end
    local out = {}
    local pack = cur.slot.pack
    for i = 0, tw * th - 1 do
        local o = i * 4
        local r, g, b, a = px[o + 1], px[o + 2], px[o + 3], px[o + 4]
        if pack == 'normal7' then
            -- A = x, G = z: show x, z and the y that makes a unit vector
            local x, z = a / 127.5 - 1, g / 127.5 - 1
            local y = 1 - x * x - z * z
            if y < 0 then y = 0 end
            out[o + 1], out[o + 2], out[o + 3], out[o + 4] = a, g, math.sqrt(y) * 127.5 + 127.5, 255
        elseif pack == 'info7' or pack == 'light301' then
            local d = (pack == 'info7') and r or b
            out[o + 1], out[o + 2], out[o + 3], out[o + 4] = a * (1 - 0.6 * d / 255), a * (1 - 0.3 * d / 255), a, 255
        else
            out[o + 1], out[o + 2], out[o + 3], out[o + 4] = r, g, b, 255
        end
    end
    local vfs = Fields.PreviewPixels(out, tw, th)
    if not vfs then return nil, 'the picture could not be shown' end
    State.thumbs[kind] = { key = key, vfs = vfs }
    return vfs
end

-- ---- saving ---------------------------------------------------------------------------------------------------------------------------------------------

--- Called by map.lua before the map is written to `diskDir` (mounted at `mount`): the layers' maptex_* files (and any texture of another map folder) are copied into <diskDir>/env/layers and the layers point there; maptex_* files
--- of that folder that no layer uses are deleted. An autosave folder only gets the copies for the file it writes: the returned function puts the layers back. Never raises.
function PrepareSave(diskDir, mount)
    local restore = nil
    local ok, err = pcall(function()
        local temporary = string.find(string.lower(diskDir), '_autosave', 1, true) ~= nil
        local moved = {}
        local used = {}
        local mounted = false
        -- A texture of the map's own folder (/maps/<folder>/...) or of the staging folder stays with the map: a layer that points into ANOTHER map folder (the map was saved as a new
        -- folder, or opened from one and saved elsewhere, or a texture was picked from the browser's "This map" list of a map that is gone) gets a copy in this folder.
        local copied = {}          -- lower case source path -> the path the layer points to now
        local function Relocate(path)
            local lowerPath = string.lower(path)
            if copied[lowerPath] then return copied[lowerPath] end
            local base = Basename(path)
            local target = mount .. '/env/layers/' .. base
            if lowerPath == string.lower(target) then
                copied[lowerPath] = target
                return target
            end
            local src = ed_vfs_to_disk(path)
            local data = src and ed_read_file(src)
            if not data then return nil end
            local name, n = base, 1
            local same = false
            local managed = Managed(path)
            while not managed do
                local existing = ed_file_exists(diskDir .. '/env/layers/' .. name) and ed_read_file(diskDir .. '/env/layers/' .. name)
                if not existing then break end
                if existing == data then same = true break end
                n = n + 1
                name = string.gsub(base, '%.[dD][dD][sS]$', '') .. '_' .. n .. '.dds'      -- another texture of that name is in the folder already
            end
            if not same and not ed_write_file(diskDir .. '/env/layers/' .. name, data) then return nil end
            target = mount .. '/env/layers/' .. name
            if not ed_vfs_to_disk(target) then ed_vfs_mount(diskDir, mount) mounted = true end
            copied[lowerPath] = target
            return target
        end
        local function Foreign(path)
            local lower = string.lower(path)
            return string.sub(lower, 1, 6) == '/maps/' and string.sub(lower, 1, string.len(mount) + 1) ~= string.lower(mount) .. '/'
        end
        for i = 0, 19 do
            local path, size = ed_stratum_layer(i)
            if path and path ~= '' and (Managed(path) or Foreign(path)) then
                local target = Relocate(path)
                if target then
                    if string.lower(target) ~= string.lower(path) then
                        if ed_stratum_set_layer(i, target, size) then
                            table.insert(moved, { layer = i, path = path, size = size })
                            used[string.lower(Basename(target))] = true
                        end
                    else
                        used[string.lower(Basename(target))] = true
                    end
                end
            end
        end
        if not temporary then
            local files = DiskFindFiles(mount .. '/env/layers', 'maptex_*.dds') or {}
            for _, f in files do
                if not used[string.lower(Basename(f))] then
                    local disk = ed_vfs_to_disk(f)
                    if disk and rawget(_G, 'ed_file_delete') then pcall(ed_file_delete, disk) end
                end
            end
        else
            restore = function()
                for _, m in moved do ed_stratum_set_layer(m.layer, m.path, m.size) end
            end
        end
    end)
    if not ok then LOG('EDITOR maptextures: PrepareSave failed: ' .. tostring(err)) end
    return restore
end
