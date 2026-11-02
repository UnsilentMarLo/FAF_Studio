-- Terrain strata (texture layers) of the open map: the layer list, the layer settings and the mask painting.
--
-- A map has ten texture layers: Base (everywhere), eight painted layers (strata 0..7, each with a paint mask), and Upper (an overlay without
-- a mask). Layer numbers here follow the editor's lists: 0 = Base, 1..8 = painted layers, 9 = Upper; the painted layer n is engine
-- stratum n - 1. Every layer has an albedo and a normal texture, each with its own tile size in world units. The masks are two RGBA textures
-- at half the height-map resolution by default, any size from there up to the cap of StratumMaskSize.h (MaskSizes / SetMaskSize; ed_stratum_* natives, moho/editor/EdStrata.cpp).
--
-- Settings follow the FAF Map Editor's strata window: per layer albedo + normal with their own scale, layer order up / down, the TerrainXP
-- switch for layers 5..8; brush Strength (percent, response curve (s / 100)^1.5 * 0.6 per dab), Size, Falloff, Target value (the opacity a
-- stroke may reach), Scatter, minimum / maximum slope angle (cells outside are skipped) and a height range, Invert.
--
--   Layers()                               list of { index, name, albedo, normal, size, nsize, ... }
--   SetTexture(i, albedo, normal, size, nsize)     (size nil = Optimal tile of the texture, texscale.lua; the 4 of Clear / Info is the engine's empty slot value)     Snapshot(i) / Restore(snapshot)      SetSizes(i, size, nsize)
--   Move(i, +1 | -1)     Clear(i)     ClearMask(i)     FillMask(i)     each returns an undo entry (or nil)
--   Active               the painted layer (1..8) the paint / erase brushes work on
--   Brush                the texture brush settings
--   BeginStroke() / Dab(cx, cz, brush, weight) / EndStroke()      painting; TakeEntry() returns the undo entry of the finished stroke
--   Range()                                'half' | 'full': how the map's shader reads a mask byte (shaders.lua RangeOf); every brush and mask tool stores bytes that way
--   Profile()                              shaders.lua Profile of the map's shader (painted layers, what layer 8 is ...)
--   PaintCap()                             the highest layer the shader paints with a mask      WhyNotPaintable(i) -> nil | reason: the check of every tool that writes a layer mask
--
-- Undo entries are plain { label, undo, redo } like the object edits (history.lua keeps one order for everything).
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Active = 1

--- The texture brush. strength / target / scatter are percent (strength -100..100: a negative strength erases, and so does holding Shift while
--- painting); slopes are degrees; heights world units.
Brush = {
    strength = 50,
    target = 100,
    scatter = 0,
    minSlope = 0,
    maxSlope = 90,
    minHeight = 0,
    maxHeight = 512,
    invert = false,
    blend = 'max',      -- how the dabs of one stroke combine: 'max' (a cell takes the strongest dab of the stroke; passes over it add nothing)
                        -- or 'add' (build up: every dab adds, so repeated passes and slow strokes get stronger)
}

--- "No texture": a fully transparent albedo (editor/tools/gen_layer_textures.py) and the engine's neutral normal map. The terrain shader lerps
--- the Upper layer over everything below with its alpha, so an Upper layer that is not transparent hides the base layer and every painted
--- layer; a layer cannot be unset (an empty slot keeps the texture it had), it is given this one.
CLEAR = '/textures/editor/layers/clear_albedo.dds'
NONE_NORMAL = '/env/common/layers/none_normal.dds'

local PI = 3.14159265
local Shaders = import('/lua/editor/shaders.lua')
local MD = import('/lua/editor/maskdelta.lua')
local TS = MD.TS

--- The legacy terrain technique ('TTerrain') blends the painted layers 1..4 only; layers 5..8 need 'TTerrainXP' (what FAF maps use).
local function EnsureShader(layer)
    if layer >= 5 and layer <= 8 and ed_stratum_shader() == 'TTerrain' then
        ed_stratum_shader('TTerrainXP')
        return true
    end
    return false
end

--- Whether the map uses the eight-layer technique.
function IsXP()
    return ed_stratum_shader() == 'TTerrainXP'
end

function SetXP(on)
    ed_stratum_shader(on and 'TTerrainXP' or 'TTerrain')
end

local stroke = false      -- { tiles = { [tile index] = { x0, z0, tw, th, before (packed bytes), cov, dirty } }, layer, w, h, cell, last, full, any }
local pending = false     -- the finished stroke's undo entry until ui.lua takes it
local notice = false      -- a message for the status line (ui.lua shows it)

-- The terrain shaders of the TTerrain family and the half-range numbered ones (Terrain050 ...) read a mask byte m as saturate(2 * m / 255 - 1) (terrain.fx): bytes up to 127 mean "nothing",
-- 255 means "fully this layer". The full-range shaders (Terrain000, Terrain100 ...) read the byte as it is (m / 255). The brushes work on the effective value (0..1) and store it back in the
-- encoding of the map's shader (Range()), so the first dab already shows and an erased cell goes back to 0.
local function Decode(m, full)
    if full then return m / 255 end
    local e = 2 * m / 255 - 1
    if e < 0 then return 0 end
    return e
end

local function Encode(e, full)
    if e <= 0 then return 0 end
    if e > 1 then e = 1 end
    if full then return math.floor(e * 255 + 0.5) end
    return math.floor((e + 1) / 2 * 255 + 0.5)
end

--- How the shader of the map reads a paint mask byte: 'half' (saturate(2m - 1)) or 'full' (the byte is the share). See shaders.lua.
function Range()
    return Shaders.RangeOf(ed_stratum_shader())
end

--- shaders.lua Profile of the map's shader: painted layers, what layer 8 is, what the Upper layer is, ...
function Profile()
    return Shaders.Profile(ed_stratum_shader())
end

--- nil when layer i (1..8) can be painted with the map's shader, else the reason (the numbered shaders have no painted 8th layer: its mask is the roughness multiplier or unused).
local function Unpaintable(i)
    if i ~= 8 then return nil end
    local p = Profile()
    if p.l8 == 'rough' then return 'Layer 8 is not painted with ' .. tostring(ed_stratum_shader()) .. ': its mask is the roughness multiplier' end
    if p.l8 == 'data' then return 'Layer 8 is not painted with ' .. tostring(ed_stratum_shader()) .. ': it only holds map-wide data' end
    return nil
end

--- The highest layer the map's shader draws with a paint mask: 8 for TTerrainXP and for TTerrain (writing layers 5-8 switches it to TTerrainXP), 7 for the numbered shaders (their 8th mask is the
--- roughness multiplier or map-wide data), 4 for TTerrainGlow; 8 without a terrain. recipes.lua Cap() is this function.
function PaintCap()
    if not rawget(_G, 'ed_stratum_shader') then return 8 end
    local name = ed_stratum_shader()
    if not name or name == 'TTerrain' then return 8 end
    return Profile().painted or 8
end

--- nil when layer i (1..8) can be written with a mask tool (mask generator, graph outputs, field commit, mask import, recipes), else the reason as a sentence. Every tool that writes a layer's mask
--- calls this first so none of them paints a layer the map's shader reads as something else.
function WhyNotPaintable(i)
    i = math.floor((i or 0) + 0.5)
    if i < 1 or i > 8 then return 'Layer ' .. tostring(i) .. ' does not exist (1 to 8)' end
    local cap = PaintCap()
    if i <= cap then return nil end
    return Unpaintable(i) or ('Layer ' .. i .. ' is not drawn with ' .. tostring(ed_stratum_shader()) .. ': it paints layers 1 to ' .. cap .. ' only')
end

--- Mask size in cells and the world size of one cell (nil without a terrain).
function MaskInfo()
    local w, h = ed_stratum_info()
    local sx = ed_terrain_info()
    if not w or not sx or w < 1 then return nil end
    return w, h, (sx - 1) / w
end

--- The sizes the paint masks of this map may have: minW, minH, maxW, maxH (nil without a map or an older exe). A mask is never smaller than half the map's size and never bigger than two
--- texels per world unit (2048 on any map, 8192 at the most): the rule of the engine (StratumMaskSize.h).
function MaskLimits()
    if not rawget(_G, 'ed_stratum_limits') then return nil end
    return ed_stratum_limits()
end

--- The mask sizes to offer, ascending: the smallest the map allows (half its size, what the shipped exe uses), the powers of two between, and the biggest.
function MaskSizes()
    local minW, _, maxW = MaskLimits()
    if not minW then return {} end
    local list, seen = { minW }, { [minW] = true }
    local p = 256
    while p <= maxW do
        if p > minW and not seen[p] then table.insert(list, p) seen[p] = true end
        p = p * 2
    end
    if not seen[maxW] then table.insert(list, maxW) end
    return list
end

--- Gives the eight paint masks another resolution (the paint is resampled: linear when it grows, the area average when it shrinks). The shipped exe resamples every mask to half the map's
--- size when it loads the map; an exe that keeps the resolution draws the finer mask. Undo entries of mask edits are tied to the old grid, so the undo history is cleared.
--- Returns true | nil, message.
function SetMaskSize(n)
    if not rawget(_G, 'ed_stratum_set_size') then return nil, 'this exe cannot change the mask size' end
    local w, h = ed_stratum_info()
    if not w then return nil, 'the map has no paint masks' end
    if w == n and h == n then return true end
    local ok, why = ed_stratum_set_size(n, n)
    if not ok then return nil, why end
    pcall(function() import('/lua/editor/history.lua').Clear() end)
    pcall(function() import('/lua/editor/recipes.lua').Invalidate() end)
    return true
end

local function Basename(path)
    return (string.gsub(path or '', '^.*/', ''))
end

local NAMES = { [0] = 'Base', 'Layer 1', 'Layer 2', 'Layer 3', 'Layer 4', 'Layer 5', 'Layer 6', 'Layer 7', 'Layer 8', 'Upper' }

--- Name of layer i for lists.
function LayerName(i)
    return NAMES[i] or ('Layer ' .. tostring(i))
end

--- The message of the last refused action (once), for the status line.
function TakeNotice()
    local n = notice
    notice = false
    return n
end

-- ---- layer settings --------------------------------------------------------------------------------------------------------------------------

--- The ten layers, bottom to top.
function Layers()
    local list = {}
    for i = 0, 9 do
        local albedo, size, count = ed_stratum_layer(i)
        local normal, nsize = ed_stratum_layer(i + 10)
        if albedo then
            list[i + 1] = { index = i, name = LayerName(i), albedo = albedo, normal = normal or '', size = size or 1, nsize = nsize or size or 1,
                            count = count or 1, file = Basename(albedo), normalFile = Basename(normal), painted = (i >= 1 and i <= 8) }
        end
    end
    return list
end

local function Info(i)
    local albedo, size = ed_stratum_layer(i)
    local normal, nsize = ed_stratum_layer(i + 10)
    return albedo or '', size or 4, normal or '', nsize or size or 4
end

--- What a layer is made of now; Restore(snapshot) puts it back (undo of a texture change).
function Snapshot(i)
    local albedo, size, normal, nsize = Info(i)
    return { index = i, albedo = albedo, size = size, normal = normal, nsize = nsize }
end

--- The normal map that belongs to an albedo texture: the file next to it with the usual name (`x_albedo.dds` -> `x_normals.dds`, `x_normal.dds`),
--- otherwise the engine's neutral normal map.
function NormalFor(albedoPath)
    if albedoPath and albedoPath ~= '' then
        for _, suffix in { '_normals.dds', '_normal.dds', '_normalmap.dds' } do
            local candidate, n = string.gsub(albedoPath, '_albedo%.dds$', suffix)
            if n > 0 and candidate ~= albedoPath and DiskGetFileInfo(candidate) then
                return candidate
            end
        end
    end
    return NONE_NORMAL
end

--- Gives layer i new textures and tile sizes (the normal map gets its own size, `nsize`, which follows `size` when nil). A layer always
--- gets a normal map: with none the terrain shader samples nothing and lights the painted area as a black hole, so the engine's neutral
--- normal map stands in. Returns true when the albedo loaded.
function SetTexture(i, albedoPath, normalPath, size, nsize)
    EnsureShader(i)
    if not size then size = import('/lua/editor/texscale.lua').Optimal(albedoPath) end      -- no size given: the Optimal tile of the texture (texel density)
    if not normalPath or normalPath == '' then
        normalPath = NormalFor(albedoPath)
    end
    local ok = ed_stratum_set_layer(i, albedoPath, size)
    ed_stratum_set_layer(i + 10, normalPath, nsize or size)
    return ok
end

function Restore(snap)
    if not snap then return end
    if snap.albedo == '' then return end
    SetTexture(snap.index, snap.albedo, snap.normal, snap.size, snap.nsize)
end

--- Changes the tile sizes of layer i (the textures stay).
function SetSizes(i, size, nsize)
    local albedo, _, normal = Info(i)
    if albedo == '' then return false end
    return SetTexture(i, albedo, normal, size, nsize)
end

--- Gives layer i (1..9) no texture: transparent.
function Clear(i)
    if not DiskGetFileInfo(CLEAR) then
        LOG('EDITOR strata: ' .. CLEAR .. ' is missing (python editor/tools/gen_layer_textures.py writes it); the layer keeps its texture')
        return false
    end
    return SetTexture(i, CLEAR, NONE_NORMAL, 4, 4)
end

--- The editor's blank map ships with an opaque Upper layer (a grass texture) that hides every other layer. On that map, and only there, the
--- Upper layer is made transparent when the editor starts. Layers that have an albedo but no normal map get the neutral one. Returns true when
--- it changed something.
function Normalize()
    local changed = false
    for i = 1, 8 do
        local albedo, size, normal, nsize = Info(i)
        if albedo ~= '' and normal == '' then
            ed_stratum_set_layer(i + 10, NormalFor(albedo), size)
            changed = true
        end
    end
    local ok, doc = pcall(function() return import('/lua/editor/map.lua').Doc end)
    if not ok or not doc or not string.find(string.lower(doc.scenarioPath or ''), 'editor_blank', 1, true) then return changed end
    local path, size = ed_stratum_layer(9)
    if path and string.lower(path) == '/env/evergreen/layers/dirt001_albedo.dds' and size == 40 then
        Clear(9)
        return true
    end
    return changed
end

-- ---- masks as a whole -------------------------------------------------------------------------------------------------------------------------
-- Whole-mask edits work tile by tile (maskdelta.lua): one tile of the mask is a Lua table at a time, and the undo entry keeps the packed bytes of the tiles that changed (it used to keep
-- two tables of w * h cells: 128 MB for one Clear on a 2048 mask).

--- Runs `fn(values, n, x0, z0, tw, th)` on every tile of the mask of stratum `stratum`; fn returns the new values of the tile (a table of n) or nil to leave it. Returns the delta of the
--- tiles that changed (maskdelta.lua), nil without a mask.
local function EditTiles(stratum, fn)
    local w, h = ed_stratum_info()
    if not w then return nil end
    local d = MD.New(stratum)
    MD.Tiles(w, h, function(x0, z0, x1, z1)
        local before = ed_stratum_read(stratum, x0, z0, x1, z1)
        if not before then return end
        local tw, th = x1 - x0 + 1, z1 - z0 + 1
        local n = tw * th
        local after = fn(before, n, x0, z0, tw, th)
        if not after then return end
        local same = true
        for k = 1, n do
            if after[k] ~= before[k] then same = false break end
        end
        if same then return end
        MD.Add(d, x0, z0, tw, th, before, after)
        ed_stratum_write(stratum, x0, z0, x1, z1, after, true)
    end)
    ed_stratum_flush()
    return d
end

--- Swaps layer i with its neighbour (dir = +1 up, -1 down): textures, tile sizes and masks. Only the painted layers 1..8 move.
function Move(i, dir)
    local j = i + dir
    if i < 1 or i > 8 or j < 1 or j > 8 then
        notice = 'Only the painted layers (1 to 8) can change their order'
        return nil
    end
    local function Swap()
        local a, b = Snapshot(i), Snapshot(j)
        if a.albedo ~= '' then SetTexture(j, a.albedo, a.normal, a.size, a.nsize) end
        if b.albedo ~= '' then SetTexture(i, b.albedo, b.normal, b.size, b.nsize) end
        local w, h = ed_stratum_info()
        if w then
            MD.Tiles(w, h, function(x0, z0, x1, z1)
                local ma = ed_stratum_read(i - 1, x0, z0, x1, z1)
                local mb = ed_stratum_read(j - 1, x0, z0, x1, z1)
                if ma and mb then
                    ed_stratum_write(i - 1, x0, z0, x1, z1, mb, true)
                    ed_stratum_write(j - 1, x0, z0, x1, z1, ma, true)
                end
            end)
            ed_stratum_flush()
        end
    end
    Swap()
    Active = (Active == i) and j or ((Active == j) and i or Active)
    return { label = 'move ' .. LayerName(i) .. (dir > 0 and ' up' or ' down'), undo = Swap, redo = Swap }
end

--- An edit of the whole mask of layer i; `fn` is EditTiles's. The entry holds the changed tiles only (it is returned even when nothing changed).
local function MaskEdit(i, label, fn)
    local d = EditTiles(i - 1, fn)
    if not d then return nil end
    return MD.Entry(d, label .. ' ' .. LayerName(i))
end

local constants = {}        -- one table of 1024 cells per value: Clear / Fill hand the same table to every full tile

--- The tile function of a mask edit that sets every cell to `value`.
local function Constant(value)
    return function(before, n)
        local c = constants[value]
        if not c then
            c = {}
            for k = 1, TS * TS do c[k] = value end
            constants[value] = c
        end
        local differs = false
        for k = 1, n do
            if before[k] ~= value then differs = true break end
        end
        if not differs then return nil end
        if n == TS * TS then return c end
        local t = {}
        for k = 1, n do t[k] = value end
        return t
    end
end

--- Removes everything painted with layer i (1..8).
function ClearMask(i)
    if i < 1 or i > 8 then return nil end
    return MaskEdit(i, 'clear mask of', Constant(0))
end

--- Paints layer i (1..8) everywhere.
function FillMask(i)
    if i < 1 or i > 8 then return nil end
    return MaskEdit(i, 'fill mask of', Constant(255))
end

--- Removes the texture of layer i (1..9) and everything it painted: one undo entry (nil when there is no transparent texture to put in its place). A painted layer without a texture but with a
--- mask would lerp its transparent colour over the layers below by the mask alone (the shader weighs albedo and normal by the mask, not by the texture), so the mask goes with the texture;
--- undo brings both back. The Upper layer (9) has no mask and keeps its own alpha.
function RemoveTexture(i)
    if i < 1 or i > 9 then return nil end
    local snap = Snapshot(i)
    local masked = (i <= 8)
    if not Clear(i) then return nil end
    local d = masked and EditTiles(i - 1, Constant(0)) or nil       -- the cells it changed, packed (undo writes them back)
    return {
        label = 'remove texture of ' .. LayerName(i),
        bytes = d and d.bytes or 0,
        undo = function()
            Restore(snap)
            if d then MD.Apply(d, true) end
        end,
        redo = function()
            Clear(i)
            if d then MD.Apply(d, false) end
        end,
    }
end

-- ---- painting -------------------------------------------------------------------------------------------------------------------------------

--- Slope angle in degrees at a world position (from the height samples around it), and its height.
local function SlopeAt(x, z)
    local sx, sz = math.floor(x + 0.5), math.floor(z + 0.5)
    local h = ed_terrain_get(sx, sz) or 0
    local gx = ((ed_terrain_get(sx + 1, sz) or h) - (ed_terrain_get(sx - 1, sz) or h)) / 2
    local gz = ((ed_terrain_get(sx, sz + 1) or h) - (ed_terrain_get(sx, sz - 1) or h)) / 2
    return math.atan(math.sqrt(gx * gx + gz * gz)) * 180 / PI, h
end

--- Paints (or, with `erase`, removes) layer i (1..8) over the whole map wherever the slope and height limits of the texture brush hold: cells inside the
--- limits are brought up to the target (or down to nothing), the others are left as they are. One undo entry; nil when the layer has no texture.
function AutoPaint(i, erase)
    if i < 1 or i > 8 then return nil end
    local albedo = ed_stratum_layer(i)
    if not albedo or albedo == '' or albedo == CLEAR then
        notice = LayerName(i) .. ' has no texture: pick one in the Layers panel first'
        return nil
    end
    EnsureShader(i)
    local why = Unpaintable(i)
    if why then
        notice = why
        return nil
    end
    local w, h, cell = MaskInfo()
    if not w then return nil end
    local full = (Range() == 'full')
    local b = Brush
    local target = b.target / 100
    local frac = math.min(1, math.abs(b.strength) / 100)
    return MaskEdit(i, (erase and 'auto erase of' or 'auto paint of'), function(before, n, x0, z0, tw, th)
        local after = {}
        for k = 1, n do after[k] = before[k] end
        for k = 1, n do
            local x = x0 + math.mod(k - 1, tw)
            local z = z0 + math.floor((k - 1) / tw)
            local slope, height = SlopeAt((x + 0.5) * cell, (z + 0.5) * cell)
            if slope >= b.minSlope and slope <= b.maxSlope and height >= b.minHeight and height <= b.maxHeight then
                local e = Decode(before[k], full)
                if erase then
                    e = e * (1 - frac)
                elseif e < target then
                    e = e + (target - e) * frac
                end
                after[k] = Encode(e, full)
            end
        end
        return after
    end)
end

local function Hash01(x, z, seed)
    local n = x * 374761393 + z * 668265263 + seed * 2147483
    n = math.mod(n, 2147483647)
    n = math.mod(n * 1103515245 + 12345, 2147483647)
    return math.mod(n, 10001) / 10000
end

local strokeSeed = 0

--- The stroke's record of tile (tx, tz): the bytes the mask has there now (= before the stroke: a tile is made when the first dab reaches it), packed, and an empty coverage table.
--- nil when the mask cannot be read.
local function NewTile(st, tx, tz)
    local x0, z0 = tx * TS, tz * TS
    local x1, z1 = math.min(x0 + TS - 1, st.w - 1), math.min(z0 + TS - 1, st.h - 1)
    local vals = ed_stratum_read(st.layer - 1, x0, z0, x1, z1)
    if not vals then return nil end
    local tw, th = x1 - x0 + 1, z1 - z0 + 1
    return { x0 = x0, z0 = z0, tw = tw, th = th, before = MD.Pack(vals, tw * th), cov = {}, dirty = false }
end

function BeginStroke()
    EnsureShader(Active)
    local w, h, cell = MaskInfo()
    stroke = { tiles = {}, layer = Active, w = w, h = h, cell = cell, last = {}, full = (Range() == 'full'), any = false }
    if w then stroke.tilesX = math.ceil(w / TS) end
    pending = false
    strokeSeed = strokeSeed + 1
    local albedo = ed_stratum_layer(Active)
    local why = Unpaintable(Active)
    if why then
        stroke.refused = true
        notice = why
    elseif not albedo or albedo == '' then
        stroke.refused = true
        notice = LayerName(Active) .. ' has no texture: pick one in the Layers panel first'
    end
end

--- Slope angle in degrees at a mask cell's centre (from the height samples around it), and its height.
local function Terrain(x, z)
    local sx, sz = math.floor(x + 0.5), math.floor(z + 0.5)
    local h = ed_terrain_get(sx, sz) or 0
    local gx = ((ed_terrain_get(sx + 1, sz) or h) - (ed_terrain_get(sx - 1, sz) or h)) / 2
    local gz = ((ed_terrain_get(sx, sz + 1) or h) - (ed_terrain_get(sx, sz - 1) or h)) / 2
    return math.atan(math.sqrt(gx * gx + gz * gz)) * 180 / PI, h
end

--- One dab of the paint or erase brush at world (cx, cz). `brush` is terrain.lua's Brush (mode, radius), `weight(distance, radius)` its falloff.
--- Returns the number of mask cells changed.
function Dab(cx, cz, brush, weight, slot)
    if not stroke then BeginStroke() end
    if stroke.refused then return 0 end
    local w, h, cell = stroke.w, stroke.h, stroke.cell
    if not w then return 0 end
    local b = Brush
    local erase = (brush.mode == 'erase')
    if b.invert then erase = not erase end
    if b.strength < 0 then erase = not erase end
    if IsKeyDown and IsKeyDown('Shift') then erase = not erase end
    local r = brush.radius
    local mx0 = math.max(0, math.floor((cx - r) / cell))
    local mz0 = math.max(0, math.floor((cz - r) / cell))
    local mx1 = math.min(w - 1, math.ceil((cx + r) / cell))
    local mz1 = math.min(h - 1, math.ceil((cz + r) / cell))
    if mx1 < mx0 or mz1 < mz0 then return 0 end
    local values, x0, z0, x1, z1 = ed_stratum_read(stroke.layer - 1, mx0, mz0, mx1, mz1)
    if not values then return 0 end
    local rw = x1 - x0 + 1
    -- Coverage model: a cell's coverage in this stroke is the strongest weight any dab gave it (times the strength), and the result is the cell's
    -- value before the stroke blended toward the target (paint) or toward nothing (erase) by that coverage. Dabs do not pile up, so the edge keeps
    -- the smooth profile of the brush weight (at least one and a half cells wide) instead of a staircase where many dabs saturate.
    local frac = math.min(1, math.abs(b.strength) / 100)
    -- 'add' (build up): the strength is applied per dab, as the FAF Map Editor's curve gives it at a dab spacing of radius / 3, and every dab
    -- combines with what the cell has already got: coverage = 1 - (1 - coverage) * (1 - opacity * weight). The dabs of a stroke are closer
    -- than radius / 3, so the opacity of one dab is scaled to the distance since the last dab: a stroke covers the same however densely it is dabbed.
    local add = (b.blend == 'add')
    if add then
        local op = math.pow(frac, 1.5) * 0.6
        local ratio = 1
        local last = stroke.last[slot or 1]
        if last then
            local ddx, ddz = cx - last[1], cz - last[2]
            ratio = math.max(0.02, math.min(1, math.sqrt(ddx * ddx + ddz * ddz) / math.max(1, r / 3)))
        end
        frac = 1 - math.pow(1 - math.min(op, 0.999), ratio)
    end
    local lastDab = stroke.last[slot or 1]          -- per symmetry image (the table is reused: a dab allocates none of its own)
    if lastDab then lastDab[1], lastDab[2] = cx, cz else stroke.last[slot or 1] = { cx, cz } end
    local target = b.target / 100
    local useSlope = (b.minSlope > 0) or (b.maxSlope < 90)
    local useHeight = (b.minHeight > 0) or (b.maxHeight < 512)
    local changed = 0
    -- The loop below runs once per mask cell of the dab (2500 for a radius of 50 on a 4096 map): the helpers are locals, Decode / Encode are inlined, and the cells outside the
    -- circle skip the weight call (terrain.lua's round / shaped brush weight is 0 at and beyond the radius; the stamp brush's own weight is not assumed to be a circle).
    local sqrt = math.sqrt
    local r2 = r * r * 1.001
    local circle = (brush.mode == 'paint' or brush.mode == 'erase')
    local softMin = cell * 1.5              -- the edge is at least one and a half mask cells wide
    local scatter = b.scatter
    local full = stroke.full            -- the shader reads a mask byte as it is (Range() == 'full') instead of saturate(2m - 1)
    local byte = string.byte
    -- The cells are visited tile by tile (the stroke keeps, per tile, the bytes the mask had before the stroke as a packed string, and the coverage of its cells in a table of 1024):
    -- a cell's value before the stroke is one string.byte, and the undo data of the stroke is those strings, not a table of the whole bounding box.
    local tiles, tilesX = stroke.tiles, stroke.tilesX
    local tx0, tx1 = math.floor(x0 / TS), math.floor(x1 / TS)
    local tz0, tz1 = math.floor(z0 / TS), math.floor(z1 / TS)
    for tz = tz0, tz1 do
        for tx = tx0, tx1 do
            local tile = tiles[tz * tilesX + tx]
            if not tile then
                tile = NewTile(stroke, tx, tz)
                if not tile then return changed end
                tiles[tz * tilesX + tx] = tile
            end
            local beforeBytes, covA = tile.before, tile.cov
            local zs, ze = math.max(z0, tile.z0), math.min(z1, tile.z0 + tile.th - 1)
            local xs, xe = math.max(x0, tile.x0), math.min(x1, tile.x0 + tile.tw - 1)
            for z = zs, ze do
                local wz = (z + 0.5) * cell
                local dz = wz - cz
                local dz2 = dz * dz
                local rowV = (z - z0) * rw - x0 + 1             -- values[rowV + x]
                local rowT = (z - tile.z0) * tile.tw - tile.x0 + 1      -- the cell's place in the tile: rowT + x
                for x = xs, xe do
                    local wx = (x + 0.5) * cell
                    local dx = wx - cx
                    local wt = 0
                    if not circle or dx * dx + dz2 < r2 then
                        wt = weight(sqrt(dx * dx + dz2), r, softMin, dx, dz)
                    end
                    if wt > 0 and scatter > 0 then
                        wt = wt * (1 - scatter / 100 * Hash01(x, z, strokeSeed))
                    end
                    if wt > 0 and (useSlope or useHeight) then
                        local slope, height = Terrain(wx, wz)
                        if (useSlope and (slope < b.minSlope or slope > b.maxSlope)) or (useHeight and (height < b.minHeight or height > b.maxHeight)) then
                            wt = 0
                        end
                    end
                    if wt > 0 then
                        local i = rowV + x
                        local old = values[i]
                        local li = rowT + x
                        local base = byte(beforeBytes, li)
                        local cov = covA[li] or 0
                        if add then
                            local c = wt * frac
                            if c > 0.999 then c = 0.999 end
                            cov = 1 - (1 - cov) * (1 - c)
                            covA[li] = cov
                        elseif wt * frac > cov then
                            cov = wt * frac
                            covA[li] = cov
                        end
                        -- Decode: the shader reads a byte m as saturate(2 * m / 255 - 1) (full range shaders: m / 255)
                        local e0, e
                        if full then
                            e0 = base / 255
                            e = old / 255
                        else
                            e0 = 2 * base / 255 - 1
                            if e0 < 0 then e0 = 0 end
                            e = 2 * old / 255 - 1
                            if e < 0 then e = 0 end
                        end
                        if erase then
                            local t = e0 * (1 - cov)
                            if t < e then e = t end
                        elseif e0 < target then
                            local t = e0 + (target - e0) * cov
                            if t > e then e = t end
                        end
                        -- Encode
                        local new
                        if e <= 0 then
                            new = 0
                        else
                            if e > 1 then e = 1 end
                            if full then
                                new = math.floor(e * 255 + 0.5)
                            else
                                new = math.floor((e + 1) / 2 * 255 + 0.5)
                            end
                        end
                        if new ~= old then
                            tile.dirty = true
                            values[i] = new
                            changed = changed + 1
                        end
                    end
                end
            end
        end
    end
    if changed > 0 then stroke.any = true end
    if changed > 0 then
        ed_stratum_write(stroke.layer - 1, x0, z0, x1, z1, values, true)      -- deferred: the texture is uploaded once per mouse event (Flush)
    end
    return changed
end

--- Uploads the mask changes of the dabs since the last call (one texture upload however many dabs).
function Flush()
    ed_stratum_flush()
end

--- Ends the stroke and makes its undo entry (nil when nothing changed): the tiles the stroke changed, with the bytes before (kept from the first dab) and after (read now), packed.
function EndStroke()
    ed_stratum_flush()
    local s = stroke
    stroke = false
    pending = false
    if not s or not s.any then return end
    local d = MD.New(s.layer - 1)
    for _, tile in s.tiles do
        if tile.dirty then
            local n = tile.tw * tile.th
            local after = ed_stratum_read(s.layer - 1, tile.x0, tile.z0, tile.x0 + tile.tw - 1, tile.z0 + tile.th - 1)
            if after then
                local packed = MD.Pack(after, n)
                if packed ~= tile.before then MD.AddPacked(d, tile.x0, tile.z0, tile.tw, tile.th, tile.before, packed) end
            end
        end
    end
    if d.n == 0 then return end
    pending = MD.Entry(d, 'paint ' .. LayerName(s.layer))
end

--- The undo entry of the stroke that just ended (once).
function TakeEntry()
    local e = pending
    pending = false
    return e
end
