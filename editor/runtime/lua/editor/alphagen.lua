-- Alpha generation for the blending features of the newer terrain shaders (docs/projects/editor/MAP_TEXTURES.md, "Alpha generation").
--
-- What the shaders read as "alpha" (effects/terrain.fx, docs/projects/editor/LAYER_CONVERSION.md):
--   Terrain1xx / 2xx   no albedo alpha at all: roughness (R / B) and height (G / A) of every layer come from the Upper atlas. The height is what the 2xx splatting compares (splatLerp: the
--                      layer with the higher height wins where two overlap, SpecularColor.r = softness, .g = contrast); roughness is multiplied by the mask of layer 8.
--   x1 / x2 variants,  the alpha of the BASE layer's albedo is the opacity of that texture laid over the whole map (blend / multiply macrotexture).
--   Terrain001 / 051
--   TTerrainXP, 0xx    albedo alpha = specularity;   TTerrain, TTerrainGlow: specular = 1 - alpha.
--
--   Atlas(paths, normals, roles, size, o)   the roughness / height atlas with heights from the detail AND the relief of the layer textures, normalised per texture so every layer has the same
--                                           contrast, plus the bias of its kind of ground (rock above grass above wet ground), and roughness by the kind of ground modulated by the detail:
--                                           -> vfs, report | nil, message      o.cavity (0..1, how much the relief of the normal map counts, default 0.35)
--   BaseAlpha(src, opacity)                 a copy of the base layer's albedo whose alpha is `opacity` (the macrotexture variants: 0 = off, the editor's default)
--   SpecAlpha(src, role)                    a copy of an albedo whose alpha is the specularity of its kind of ground with the detail of the texture (TTerrainXP, 0xx; TTerrain: pass matte = true)
--   Stats(vfs)                              nil
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

local Fields = import('/lua/editor/fields.lua')
local MT = import('/lua/editor/maptextures.lua')

SIZE = 256                          -- the data of a layer in the atlas (a tile is 1024 / 4)
ROUGH_MIN, ROUGH_MAX = 0.45, 0.92   -- (texconv.lua: the same range the legacy alpha maps to)
-- the roughness of a kind of ground before the detail of its texture: wet ground and snow shiny, dry rock and sand dull
ROLE_ROUGH = { grass = 0.74, dirt = 0.80, wet = 0.48, sand = 0.82, rock = 0.88, darkrock = 0.90, highrock = 0.86, snow = 0.55 }
-- the specularity (what TTerrainXP and the 0xx shaders read from the alpha, 0 dull .. 1 shiny)
ROLE_SPEC = { grass = 0.18, dirt = 0.15, wet = 0.85, sand = 0.30, rock = 0.25, darkrock = 0.20, highrock = 0.30, snow = 0.70 }
-- how much a bright / dark spot of the texture moves its roughness and height (before the per texture normalisation)
ROUGH_DETAIL = 0.30
HEIGHT_SPREAD = 0.16                -- the standard deviation of a tile's detail height (0..1): every texture gets the same contrast, a flat texture is not flat in the splat
ROLE_HEIGHT = { rock = 0.20, highrock = 0.24, darkrock = 0.16, snow = 0.10, sand = 0.0, dirt = -0.05, grass = -0.12, wet = -0.20 }

local cache = {}                    -- [albedo .. '|' .. normal] = { height = number[], rough = number[], w, h } at SIZE x SIZE

local function Disk(path)
    if path and rawget(_G, 'ed_vfs_to_disk') then
        local d = ed_vfs_to_disk(path)
        if d then return d end
    end
    return path
end

--- Reads a DDS into { r, g, b, a } lists 0..1 and its size.
local function Read(path)
    local px, w, h = ed_dds_read(Disk(path))
    if not px then return nil, tostring(w) end
    return px, w, h
end

--- One value per texel of an SIZE x SIZE grid from a w x h picture: the mean of the texels in each cell (box average).
local function Box(w, h, fn)
    local out = {}
    local cx, cz = w / SIZE, h / SIZE
    for gz = 0, SIZE - 1 do
        local z0, z1 = math.floor(gz * cz), math.max(math.floor((gz + 1) * cz) - 1, math.floor(gz * cz))
        for gx = 0, SIZE - 1 do
            local x0, x1 = math.floor(gx * cx), math.max(math.floor((gx + 1) * cx) - 1, math.floor(gx * cx))
            local sum, n = 0, 0
            for z = z0, z1 do
                for x = x0, x1 do
                    sum = sum + fn(x, z)
                    n = n + 1
                end
            end
            out[gz * SIZE + gx + 1] = sum / n
        end
    end
    return out
end

--- The detail of a layer texture as SIZE x SIZE lists: lum (0..1 brightness) and cav (the divergence of the normal map: positive in pits and at the foot of bumps; all 0 without a normal map).
local function Detail(albedo, normal)
    local px, w, h = Read(albedo)
    if not px then return nil, w end
    local lum = Box(w, h, function(x, z)
        local i = (z * w + x) * 4
        return (0.299 * px[i + 1] + 0.587 * px[i + 2] + 0.114 * px[i + 3]) / 255
    end)
    px = nil
    local cav = {}
    for i = 1, SIZE * SIZE do cav[i] = 0 end
    local haveNormal = false
    if normal then
        local np, nw, nh = Read(normal)
        if np then
            haveNormal = true
            -- nx, ny at SIZE x SIZE, then a central difference of the divergence (wrapping: the textures tile)
            local nx = Box(nw, nh, function(x, z) return np[(z * nw + x) * 4 + 1] / 127.5 - 1 end)
            local ny = Box(nw, nh, function(x, z) return np[(z * nw + x) * 4 + 2] / 127.5 - 1 end)
            np = nil
            for gz = 0, SIZE - 1 do
                local zm, zp = math.mod(gz + SIZE - 1, SIZE), math.mod(gz + 1, SIZE)
                for gx = 0, SIZE - 1 do
                    local xm, xp = math.mod(gx + SIZE - 1, SIZE), math.mod(gx + 1, SIZE)
                    local dnx = nx[gz * SIZE + xp + 1] - nx[gz * SIZE + xm + 1]
                    local dny = ny[zp * SIZE + gx + 1] - ny[zm * SIZE + gx + 1]
                    cav[gz * SIZE + gx + 1] = -(dnx + dny) * 0.5
                end
            end
        end
    end
    return lum, cav, haveNormal
end

--- Mean and standard deviation of a list.
local function MeanSd(list)
    local n = table.getn(list)
    local sum = 0
    for i = 1, n do sum = sum + list[i] end
    local mean = sum / n
    local sq = 0
    for i = 1, n do
        local d = list[i] - mean
        sq = sq + d * d
    end
    return mean, math.sqrt(sq / n)
end

--- height and roughness lists (0..1) of one layer: detail normalised to HEIGHT_SPREAD, relief from the normal map, bias by the kind of ground.
local function Tile(albedo, normal, role, o)
    local key = tostring(albedo) .. '|' .. tostring(normal) .. '|' .. tostring(role) .. '|' .. string.format('%.2f', o.cavity)
    if cache[key] then return cache[key] end
    local lum, cav, haveNormal = Detail(albedo, normal)
    if not lum then return nil, cav end
    local lm, ls = MeanSd(lum)
    local cm, cs = MeanSd(cav)
    local wc = haveNormal and o.cavity or 0
    local gl = ls > 0.002 and (HEIGHT_SPREAD / ls) or 0
    local gc = cs > 0.0005 and (HEIGHT_SPREAD / cs) or 0
    local bias = ROLE_HEIGHT[role or ''] or 0
    local baseRough = ROLE_ROUGH[role or ''] or 0.65
    local height, rough = {}, {}
    for i = 1, SIZE * SIZE do
        local l = (lum[i] - lm) * gl                      -- standard deviation HEIGHT_SPREAD
        local c = -(cav[i] - cm) * gc                     -- pits are low
        local hv = 0.5 + bias + (1 - wc) * l + wc * c
        if hv < 0.05 then hv = 0.05 elseif hv > 0.95 then hv = 0.95 end
        height[i] = hv
        local rv = baseRough - ROUGH_DETAIL * l * 2
        if rv < ROUGH_MIN then rv = ROUGH_MIN elseif rv > ROUGH_MAX then rv = ROUGH_MAX end
        rough[i] = rv
    end
    local t = { height = height, rough = rough }
    cache[key] = t
    return t
end

--- Writes a proxy picture of a layer (R = height, G = roughness) and returns its disk path.
local function Proxy(tile)
    local vfs, disk
    vfs, disk = MT.StageFile('conv', function(path)
        local ok, err = pcall(function()
            Fields.Run(function(S)
                local h = S:Table(SIZE, SIZE, tile.height, 1, 0, 0)
                local r = S:Table(SIZE, SIZE, tile.rough, 1, 0, 0)
                local one = S:Op('const', { like = h, value = 1 })
                local bytes, err2 = ed_dds_fields(path, SIZE, SIZE, h, r, one, one, 1)
                if not bytes then error(tostring(err2)) end
            end)
        end)
        if not ok then return false, tostring(err) end
        return true
    end)
    if not vfs then return nil, tostring(disk) end
    return disk
end

--- The roughness / height atlas (see the header). paths[0..7] albedo, normals[0..7] normal maps (optional), roles[0..7] kinds of ground (optional).
function Atlas(paths, normals, roles, size, o)
    o = o or {}
    o.cavity = o.cavity or 0.35
    if not rawget(_G, 'ed_dds_fields') or not rawget(_G, 'ed_dds_read') or not rawget(_G, 'ed_tex_atlas') then return nil, 'this editor build cannot make the atlas (ed_dds_fields is missing)' end
    local TexConv = import('/lua/editor/texconv.lua')
    local tiles = {}
    local stats = {}
    for k = 1, 8 do
        local path = paths[k - 1]
        local role = roles and roles[k - 1] or nil
        if TexConv.IsTexture(path) then
            local tile, why = Tile(path, normals and normals[k - 1] or nil, role, o)
            if not tile then return nil, 'layer ' .. (k - 1) .. ': ' .. tostring(why) end
            local proxy, perr = Proxy(tile)
            if not proxy then return nil, tostring(perr) end
            tiles[k] = { src = proxy, rough = { from = 'g', lo = ROUGH_MIN, hi = ROUGH_MAX }, height = { from = 'r', lo = 0.05, hi = 0.95 } }
            local hm, hs = MeanSd(tile.height)
            local rm, rs = MeanSd(tile.rough)
            stats[k] = string.format('%s height %.2f+-%.2f rough %.2f+-%.2f', tostring(role), hm, hs, rm, rs)
        else
            tiles[k] = { rough = { from = 'const', value = TexConv.ROUGH_NEUTRAL }, height = { from = 'const', value = 0.5 + (ROLE_HEIGHT[role or ''] or 0) } }
        end
    end
    local spec = { size = size or 1024, rough = TexConv.ROUGH_NEUTRAL, height = 0.5, tiles = tiles }
    local report
    local vfs, disk = MT.StageFile('atlas', function(path)
        local bytes, rep = ed_tex_atlas(path, spec)
        if not bytes then return false, rep end
        report = rep
        return true
    end)
    if not vfs then return nil, tostring(disk) end
    return vfs, report, stats
end

--- A copy of the base layer's albedo with alpha = opacity (0 .. 1). Returns vfs, lossless | nil, message.
function BaseAlpha(src, opacity)
    return import('/lua/editor/texconv.lua').Alpha(src, { from = 'const', value = opacity })
end

--- A copy of an albedo whose alpha is the specularity of its kind of ground, moved by the detail of the texture (bright spots shinier). matte = true for TTerrain (it reads 1 - alpha).
function SpecAlpha(src, role, matte)
    local base = ROLE_SPEC[role or ''] or 0.3
    local c = { from = 'lum', center = true, scale = 0.35, bias = base - 0.5, lo = 0.02, hi = 0.98 }
    if matte then c = { from = 'lum', center = true, scale = -0.35, bias = (1 - base) - 0.5, lo = 0.02, hi = 0.98 } end
    return import('/lua/editor/texconv.lua').Alpha(src, c)
end

local baseOrigin = {}              -- [vfs of an alpha copy this module made] = the base albedo it was made from

--- Makes the alpha of the base layer right for the shader of the map. The shaders with a macrotexture variant (Terrain1xx / 2xx ending in 1 or 2, Terrain001 / 051: profile.baseAlpha = 'opacity') lay
--- the base layer's own texture over the whole map by its alpha, and a texture set's base texture has a specularity in its alpha: grass over everything, dark (multiply variant) or washed out. The
--- base layer then gets a copy of its albedo with alpha = `opacity` (default 0: no macrotexture; the colours are copied bit for bit). Moving to a shader without that feature puts the original
--- back. Returns a short text when it changed something, else nil. Does not touch the history (the files and the layer are the same kind of change as a texture set).
function FitBase(opacity)
    local Strata = import('/lua/editor/strata.lua')
    local profile = Strata.Profile()
    if not profile or not rawget(_G, 'ed_stratum_layer') then return nil end
    local path, size = ed_stratum_layer(0)
    local normal, nsize = ed_stratum_layer(10)
    local TexConv = import('/lua/editor/texconv.lua')
    if not TexConv.IsTexture(path) then return nil end
    if profile.baseAlpha == 'opacity' then
        opacity = opacity or 0
        local key = string.lower(path)
        local known = baseOrigin[key]
        if known and known.opacity == opacity then return nil end
        local origin = known and known.origin or path
        local vfs, lossless = BaseAlpha(origin, opacity)
        if not vfs then return nil end
        baseOrigin[string.lower(vfs)] = { origin = origin, opacity = opacity }
        Strata.SetTexture(0, vfs, normal, size, nsize)
        return 'base texture alpha ' .. opacity .. ' (macrotexture off)'
    end
    local known = baseOrigin[string.lower(path)]
    if known then
        Strata.SetTexture(0, known.origin, normal, size, nsize)
        return 'base texture alpha restored'
    end
    return nil
end

function Forget() cache = {} baseOrigin = {} end
