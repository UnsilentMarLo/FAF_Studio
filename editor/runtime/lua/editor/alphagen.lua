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
--   ApplyLayerAlpha(o)                      the albedo alpha of the layers made for the shader (TTerrain / TTerrainXP / 0xx read it as specularity): o.mode 'generate' (the specularity of the kind
--                                           of ground with the detail of the texture) | 'adjust' (the texture's own alpha pulled towards the kind of ground by o.amount) | 'off' (the originals
--                                           back); o.detail (0..0.6). Returns an undo entry | nil, a one line report, the number of layers.
--   PRESETS, ApplyStyle(o)                  the named combinations of the atlas settings (default | soft | patchy; 'custom' = the numbers as given) and of the splat settings of the shader; ApplyStyle fills o
--   SetSplat(soft, contrast)                sets the Terrain2xx blending settings of the map's SpecularColor (softness .r, height contrast .g; 0 = leave as it is). Returns a note | nil, message
--   RestoreLayerAlpha()                     puts the original textures back on the layers ApplyLayerAlpha changed
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

-- named combinations of the atlas settings (spread = height contrast inside a texture, biasScale = step between the kinds of ground, cavity = weight of the normal map's relief, roughDetail) and
-- of the splat settings the Terrain2xx shaders take from SpecularColor (splatSoft = .r, splatContrast = .g; absent = leave the map's). soft: transitions blend smoothly, no kind wins; patchy: the
-- higher kind (rock) takes the transition in sharp islands.
PRESETS = {
    default = { spread = 1, biasScale = 1, cavity = 0.35, roughDetail = 1 },
    soft = { spread = 0.5, biasScale = 0.3, cavity = 0.35, roughDetail = 1, splatSoft = 0.7, splatContrast = 0.8 },
    patchy = { spread = 2.0, biasScale = 2.0, cavity = 0.35, roughDetail = 1, splatSoft = 0.3, splatContrast = 1.5 },
}

--- Fills the atlas and splat settings of o from the named style (o.style); 'custom' or none keeps the numbers in o. Returns o.
function ApplyStyle(o)
    local preset = o and o.style and PRESETS[o.style]
    if preset then
        for k, v in preset do o[k] = v end
    end
    return o
end

--- Terrain2xx read their blending from the map's SpecularColor: .r = softness of the transitions, .g = contrast of the heights (docs/projects/editor/LAYER_CONVERSION.md). soft / contrast 0 or nil
--- leave the lane as it is. Other shaders use that colour as the specular highlight: nothing is changed there (nil and a message).
function SetSplat(soft, contrast)
    soft, contrast = tonumber(soft) or 0, tonumber(contrast) or 0
    if soft <= 0 and contrast <= 0 then return nil end
    local profile = import('/lua/editor/strata.lua').Profile()
    if not profile or profile.class ~= 'splat' then
        return nil, 'the splat softness and contrast are read by the Terrain2xx shaders only (SpecularColor is the specular highlight of the others)'
    end
    local Shaders = import('/lua/editor/shaders.lua')
    local t = Shaders.SpecColor()
    if not t then return nil, 'no map lighting' end
    if soft > 0 then t.spec_r = soft end
    if contrast > 0 then t.spec_g = contrast end
    Shaders.SetSpecColor(t)
    return string.format('splat softness %.2f, height contrast %.2f', t.spec_r, t.spec_g)
end

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
local function Detail(albedo, normal, integrate)
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
    local heightN = nil
    if normal then
        local np, nw, nh = Read(normal)
        if np then
            haveNormal = true
            -- nx, ny at SIZE x SIZE, then a central difference of the divergence (wrapping: the textures tile)
            local nx = Box(nw, nh, function(x, z) return np[(z * nw + x) * 4 + 1] / 127.5 - 1 end)
            local ny = Box(nw, nh, function(x, z) return np[(z * nw + x) * 4 + 2] / 127.5 - 1 end)
            np = nil
            -- the height the normal map describes (the Poisson solve of its slopes, native height_from_gradient; the textures tile, so periodic); nil when the editor build has no such op
            if integrate then
                local okI, hv = pcall(function()
                    local list
                    Fields.Run(function(S)
                        local sx, sz = {}, {}
                        for i = 1, SIZE * SIZE do
                            local x, y = nx[i], ny[i]
                            local zz = 1 - x * x - y * y
                            if zz < 0.04 then zz = 0.04 end
                            local inv = 1 / math.sqrt(zz)
                            sx[i] = -x * inv                              -- n = -grad(h): the same convention as the divergence below (pits positive)
                            sz[i] = -y * inv
                        end
                        local fx = S:Table(SIZE, SIZE, sx, 1, 0, 0)
                        local fz = S:Table(SIZE, SIZE, sz, 1, 0, 0)
                        local h = S:Op('height_from_gradient', { dx = fx, dz = fz, periodic = 1 })
                        list = Fields.Read(h, 0, 0, SIZE - 1, SIZE - 1)
                    end)
                    return list
                end)
                if okI and type(hv) == 'table' and hv[1] then heightN = hv end
            end
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
    return lum, cav, haveNormal, heightN
end

--- The detail of a texture for tests and tools: lum, cav, haveNormal, heightN (SIZE x SIZE lists; heightN is the integrated relief of the normal map, nil without the native op).
function Relief(albedo, normal) return Detail(albedo, normal, true) end

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
    local key = tostring(albedo) .. '|' .. tostring(normal) .. '|' .. tostring(role) .. '|' .. string.format('%.2f|%.2f|%.2f|%.2f|%s', o.cavity, o.spread, o.biasScale, o.roughDetail, tostring(o.integrate ~= false))
    if cache[key] then return cache[key] end
    local lum, cav, haveNormal, heightN = Detail(albedo, normal, o.integrate ~= false)
    if not lum then return nil, cav end
    local lm, ls = MeanSd(lum)
    local cm, cs = MeanSd(cav)
    local hm, hs = 0, 0
    if heightN then hm, hs = MeanSd(heightN) end
    local wc = haveNormal and o.cavity or 0
    local spread = HEIGHT_SPREAD * o.spread
    local gl = ls > 0.002 and (spread / ls) or 0
    local gc = cs > 0.0005 and (spread / cs) or 0
    local gh = hs > 1.0e-6 and (spread / hs) or 0
    local bias = (ROLE_HEIGHT[role or ''] or 0) * o.biasScale
    local baseRough = ROLE_ROUGH[role or ''] or 0.65
    local height, rough = {}, {}
    for i = 1, SIZE * SIZE do
        local l = (lum[i] - lm) * gl                      -- standard deviation HEIGHT_SPREAD
        local c = heightN and (heightN[i] - hm) * gh or -(cav[i] - cm) * gc      -- the integrated relief of the normal map; without it the divergence (pits are low)
        local hv = 0.5 + bias + (1 - wc) * l + wc * c
        if hv < 0.05 then hv = 0.05 elseif hv > 0.95 then hv = 0.95 end
        height[i] = hv
        local rv = baseRough - ROUGH_DETAIL * o.roughDetail * l * 2
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
    o.spread = o.spread or 1                    -- x HEIGHT_SPREAD: the contrast of the heights the splatting compares
    o.biasScale = o.biasScale or 1              -- x the height step between the kinds of ground (rock above grass above wet ground)
    o.roughDetail = o.roughDetail or 1          -- x ROUGH_DETAIL: how much the bright / dark spots of a texture move its roughness
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
            tiles[k] = { rough = { from = 'const', value = TexConv.ROUGH_NEUTRAL }, height = { from = 'const', value = 0.5 + (ROLE_HEIGHT[role or ''] or 0) * o.biasScale } }
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
--- o.detail: how much the detail moves it (0 .. 0.6, default 0.35); o.adjust = weight 0..1 of the kind of ground against the texture's own alpha (pulled towards it instead of replaced).
function SpecAlpha(src, role, matte, o)
    o = o or {}
    local base = ROLE_SPEC[role or ''] or 0.3
    local detail = o.detail or 0.35
    local c
    if o.adjust then
        local w = o.adjust
        c = { from = 'a', scale = 1 - w, bias = w * (matte and (1 - base) or base), lo = 0.02, hi = 0.98 }
    elseif matte then
        c = { from = 'lum', center = true, scale = -detail, bias = (1 - base) - 0.5, lo = 0.02, hi = 0.98 }
    else
        c = { from = 'lum', center = true, scale = detail, bias = base - 0.5, lo = 0.02, hi = 0.98 }
    end
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
        local key = string.lower(path)
        local known = baseOrigin[key]
        opacity = opacity or (known and known.opacity) or 0      -- no value: what is set stays
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

local layerOrigin = {}             -- [lower(vfs of a specularity copy)] = { origin = the albedo it was made from, layer }

--- Puts the original albedo back on the layers ApplyLayerAlpha made copies for. Returns how many.
function RestoreLayerAlpha()
    local Strata = import('/lua/editor/strata.lua')
    local n = 0
    for layer = 0, 8 do
        local path, size = ed_stratum_layer(layer)
        local known = path and layerOrigin[string.lower(path)]
        if known then
            local normal, nsize = ed_stratum_layer(layer + 10)
            Strata.SetTexture(layer, known.origin, normal, size, nsize)
            n = n + 1
        end
    end
    return n
end

--- The albedo alpha of the layers for the map's shader (see the header). Read as specularity by profile.alpha = 'spec' (TTerrainXP, 0xx) or as 1 - specularity by 'matte' (TTerrain). The other
--- shaders ignore it (Terrain1xx / 2xx take roughness and height from the Upper atlas, see Atlas): nil and a message. One undo entry (MT.Apply, pushed unless o.noPush).
function ApplyLayerAlpha(o)
    o = o or {}
    local Strata = import('/lua/editor/strata.lua')
    local TexConv = import('/lua/editor/texconv.lua')
    local profile = Strata.Profile()
    if not profile or not rawget(_G, 'ed_stratum_layer') then return nil, 'no terrain' end
    local mode = o.mode or 'generate'
    if mode == 'off' then
        local n = RestoreLayerAlpha()
        return nil, n > 0 and ('the original alpha of ' .. n .. ' layers is back') or 'the layers have their own alpha already', n
    end
    if profile.alpha ~= 'spec' and profile.alpha ~= 'matte' then
        return nil, (rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or 'this shader') .. ' does not read the alpha of the layer textures as specularity (TTerrain, TTerrainXP and the 0xx shaders do).'
    end
    if not TexConv.Available() then return nil, 'this editor build cannot make textures (ed_tex_convert is missing)' end
    RestoreLayerAlpha()                                   -- always from the originals: the same settings give the same files
    local det = import('/lua/editor/roledetect.lua').Layers(7)
    local writes, kinds = {}, {}
    local painted = profile.painted or 7
    if painted > 8 then painted = 8 end
    for layer = 0, painted do
        local path, size = ed_stratum_layer(layer)
        if TexConv.IsTexture(path) then
            local role = det[layer] and det[layer].role or nil
            local vfs = SpecAlpha(path, role, profile.alpha == 'matte', { detail = o.detail, adjust = mode == 'adjust' and (o.amount or 0.6) or nil })
            if vfs then
                layerOrigin[string.lower(vfs)] = { origin = path, layer = layer }
                table.insert(writes, { layer = layer, path = vfs, size = size or 4 })
                table.insert(kinds, tostring(role))
            end
        end
    end
    if not writes[1] then return nil, 'no layer has a texture' end
    local entry, why = MT.Apply('texture alpha', writes, o)
    if not entry then return nil, why end
    -- Apply loads the albedo only: the layer's normal map stays as it was (it is a separate layer slot)
    return entry, table.getn(writes) .. ' layers: alpha = ' .. (profile.alpha == 'matte' and '1 - ' or '') .. 'specularity by the kind of ground (' .. table.concat(kinds, ', ') .. ')', table.getn(writes)
end

function Forget() cache = {} baseOrigin = {} layerOrigin = {} end
