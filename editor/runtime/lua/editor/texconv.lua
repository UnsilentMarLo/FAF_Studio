-- The texture files of the layer converter (stratumconv.lua): what the shaders read from the albedo alpha and from the Upper atlas, and the natives that write new files for it. A conversion never
-- changes a texture file in place (the engine keeps textures by path, and a texture may belong to the game): it writes a NEW DXT5 file into the map textures staging folder (maptextures.lua
-- STAGE, mounted as /edmaptex) and points the layer at it. Saving the map copies the files the layers use into <map>/env/layers (maptextures.PrepareSave) and deletes unused maptex_*.dds there.
-- The pixel work is native (ed_tex_convert, ed_tex_atlas: moho/editor/EdTexConv.cpp): a 1024 x 1024 texture is four million numbers as a Lua table.
--
--   Available()                          the natives exist in this build
--   IsTexture(path)                      a layer texture (not empty, not the transparent "no texture")
--   RoughChan(kind) / HeightChan() / SpecFromRoughChan(kind, tile)     channel tables for the natives (see EdTexConv.cpp for the fields)
--   AtlasSpec(paths, kind, size) -> table for ed_tex_atlas      paths[0..7] = the albedo of the base layer and layers 1-7;  kind = what their alpha means: 'spec' | 'matte' | nil
--   Atlas(paths, kind, size) -> vfs, report | nil, message     writes the atlas        Alpha(src, chan) -> vfs, lossless | nil, message       writes a copy of src with another alpha
--   Constants: ROUGH_MIN, ROUGH_MAX, ROUGH_NEUTRAL, SPEC_DEFAULT, HEIGHT_GAIN
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Strata = import('/lua/editor/strata.lua')
local MT = import('/lua/editor/maptextures.lua')

-- The legacy albedo alpha is a specularity (0..1; TTerrain: 1 - alpha), the PBR shaders want a roughness. A specularity of 1 gives ROUGH_MIN, 0 gives ROUGH_MAX: between a fairly glossy and a
-- dull ground. ROUGH_NEUTRAL is the roughness of the editor's neutral atlas. SPEC_DEFAULT is the specularity given to textures made for a shader that ignores their alpha.
ROUGH_MIN = 0.45
ROUGH_MAX = 0.92
ROUGH_NEUTRAL = 0.65
SPEC_DEFAULT = 0.3
-- The heights of the atlas are the detail of the albedo (luminance around its mean); the gain sets how strongly a bright / dark spot wins a transition.
HEIGHT_GAIN = 1.3

function Available()
    return rawget(_G, 'ed_tex_convert') ~= nil and rawget(_G, 'ed_tex_atlas') ~= nil
end

function IsTexture(path)
    return path ~= nil and path ~= '' and string.lower(path) ~= string.lower(Strata.CLEAR)
end

--- The roughness of a tile from the alpha of its texture: kind 'spec' (alpha = specularity: TTerrainXP, the 0xx), 'matte' (TTerrain: specularity = 1 - alpha), anything else a constant.
function RoughChan(kind)
    local range = ROUGH_MAX - ROUGH_MIN
    if kind == 'spec' then
        return { from = 'a', scale = -range, bias = ROUGH_MAX, lo = ROUGH_MIN, hi = ROUGH_MAX }
    elseif kind == 'matte' then
        return { from = 'a', scale = range, bias = ROUGH_MIN, lo = ROUGH_MIN, hi = ROUGH_MAX }
    end
    return { from = 'const', value = ROUGH_NEUTRAL }
end

--- The height of a tile from the detail of its texture.
function HeightChan()
    return { from = 'lum', center = true, scale = HEIGHT_GAIN, lo = 0.05, hi = 0.95 }
end

--- The alpha (specularity of `kind` 'spec' or alpha of 'matte') of a texture made from the roughness of tile `tile` (1..8) of an atlas: the inverse of RoughChan. `atlas` = the file.
function SpecFromRoughChan(kind, atlas, tile)
    local range = ROUGH_MAX - ROUGH_MIN
    local ch = (tile <= 4) and 'r' or 'b'           -- first four tiles: roughness in R, the others in B
    local c = { from = 'atlas', atlas = { src = atlas, tile = tile, ch = ch }, lo = 0, hi = 1 }
    if kind == 'matte' then
        c.scale, c.bias = 1 / range, 1 - ROUGH_MAX / range           -- 1 - spec
    else
        c.scale, c.bias = -1 / range, ROUGH_MAX / range              -- spec
    end
    return c
end

--- The ed_tex_atlas table for the eight tiles (base layer, layers 1-7): roughness from the alpha of the layer's texture (by `kind`), height from its detail. A layer without a texture gets neutral tiles.
function AtlasSpec(paths, kind, size)
    local tiles = {}
    for k = 1, 8 do
        local path = paths[k - 1]
        if IsTexture(path) then
            tiles[k] = { src = path, rough = RoughChan(kind), height = HeightChan() }
        else
            tiles[k] = { rough = { from = 'const', value = ROUGH_NEUTRAL }, height = { from = 'const', value = 0.5 } }
        end
    end
    return { size = size or 1024, rough = ROUGH_NEUTRAL, height = 0.5, tiles = tiles }
end

--- Stages a new file. Conversion files are not in maptextures' list of files it prunes: undo and redo of a conversion must always find them (saving the map removes the unused ones).
local function Stage(kind, writer)
    local vfs, disk = MT.StageFile(kind, writer)
    if vfs then
        local created = MT.State.created
        local last = created[table.getn(created)]
        if last and last.vfs == vfs then table.remove(created) end
    end
    return vfs, disk
end

--- Writes the atlas file. Returns its VFS path and the per-tile report of the native ({ [1..8] = 'ok' | 'no texture' | 'cannot read: ...' }), or nil and a message.
function Atlas(paths, kind, size)
    local spec = AtlasSpec(paths, kind, size)
    local report
    local vfs, disk = Stage('atlas', function(path)
        local bytes, rep = ed_tex_atlas(path, spec)
        if not bytes then return false, rep end
        report = rep
        return true
    end)
    if not vfs then return nil, disk end
    return vfs, report
end

--- Writes a copy of the texture `src` whose alpha channel is made by `chan` (the colour stays as it is; for a DXT5 source nothing but the alpha blocks is rewritten: lossless = true).
--- Returns the new file's VFS path and lossless, or nil and a message.
function Alpha(src, chan)
    local lossless = false
    -- the native reader takes a disk path (entries inside .scd archives included), not a VFS path
    local disk0 = rawget(_G, 'ed_vfs_to_disk') and ed_vfs_to_disk(src)
    if disk0 then src = disk0 end
    local vfs, disk = Stage('conv', function(path)
        local bytes, w, h, same = ed_tex_convert(src, path, { a = chan })
        if not bytes then return false, w end
        lossless = same and true or false
        return true
    end)
    if not vfs then return nil, disk end
    return vfs, lossless
end
