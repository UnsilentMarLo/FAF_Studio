-- The preview image of a map (the 256 x 256 picture the lobby shows, stored in the .scmap right after its header): a top-down render worked out from the map data:
-- every pixel takes the colour of the texture layers visible there (each layer's average colour weighted by its visible share: mask times what the layers above leave
-- free), lit by the map's sun like a hill shade, and tinted by the water where the ground is below the water surface.
--
--   Render(size)           -> table of size * size numbers 0xRRGGBB (row major)
--   Apply(scmapPath)       renders and writes the picture into the .scmap file; true | nil, message
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local SIZE = 256

local avgCache = {}

--- Average colour of a layer texture (r, g, b); a neutral grey when the file cannot be read.
local function LayerColor(albedo)
    if not albedo or albedo == '' then return 96, 96, 96 end
    local c = avgCache[albedo]
    if c then return c[1], c[2], c[3] end
    local r, g, b = 96, 96, 96
    local disk = ed_vfs_to_disk(albedo)
    if disk then
        local ar, ag, ab = ed_image_avg(disk)
        if ar then r, g, b = ar, ag, ab end
    end
    avgCache[albedo] = { r, g, b }
    return r, g, b
end

local function Decode(m)
    local e = 2 * m / 255 - 1
    if e < 0 then return 0 end
    return e
end

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function Render(size)
    size = size or SIZE
    local w, h = ed_terrain_info()
    local mw, mh = ed_stratum_info()
    if not w then return nil end
    local mapSize = w - 1
    local Strata = import('/lua/editor/strata.lua')
    -- the layers: colour and mask (the base layer has none: it is what the others leave free)
    local colors, masks = {}, {}
    colors[0] = { LayerColor(ed_stratum_layer(0)) }
    for k = 1, 8 do
        local albedo = ed_stratum_layer(k)
        if albedo and albedo ~= '' and albedo ~= Strata.CLEAR and mw then
            colors[k] = { LayerColor(albedo) }
            masks[k] = ed_stratum_read(k - 1, 0, 0, mw - 1, mh - 1)
        end
    end
    local t = ed_world_get() or {}
    local lx, ly, lz = t.sun_x or 0.4, t.sun_y or 0.8, t.sun_z or -0.4
    local ll = math.sqrt(lx * lx + ly * ly + lz * lz)
    if ll < 0.0001 then lx, ly, lz, ll = 0.4, 0.8, -0.4, 1 end
    lx, ly, lz = lx / ll, ly / ll, lz / ll
    local waterOn = (t.water_on or 0) ~= 0
    local waterElev = t.water_elev or 0
    local wr = Clamp((t.w_color_r or 0.1) * 110, 10, 255)
    local wg = Clamp((t.w_color_g or 0.5) * 110, 10, 255)
    local wb = Clamp((t.w_color_b or 0.9) * 110, 10, 255)

    local pixels = {}
    local step = mapSize / size
    local cell = mw and (mapSize / mw) or 2
    for j = 0, size - 1 do
        local z = (j + 0.5) * step
        for i = 0, size - 1 do
            local x = (i + 0.5) * step
            -- the visible texture colours
            local r, g, b = 0, 0, 0
            local remaining = 1
            if mw then
                local mx = Clamp(math.floor(x / cell), 0, mw - 1)
                local mz = Clamp(math.floor(z / cell), 0, mh - 1)
                local idx = mz * mw + mx + 1
                for k = 8, 1, -1 do
                    local m = masks[k]
                    if m then
                        local e = Decode(m[idx])
                        if e > 0 then
                            local share = e * remaining
                            local c = colors[k]
                            r, g, b = r + c[1] * share, g + c[2] * share, b + c[3] * share
                            remaining = remaining * (1 - e)
                        end
                    end
                end
            end
            local c0 = colors[0]
            r, g, b = r + c0[1] * remaining, g + c0[2] * remaining, b + c0[3] * remaining
            -- hill shade from the height around the point
            local ix, iz = math.floor(x + 0.5), math.floor(z + 0.5)
            local hc = ed_terrain_get(ix, iz) or 0
            local dx = ((ed_terrain_get(ix + 2, iz) or hc) - (ed_terrain_get(ix - 2, iz) or hc)) / 4
            local dz = ((ed_terrain_get(ix, iz + 2) or hc) - (ed_terrain_get(ix, iz - 2) or hc)) / 4
            local nl = math.sqrt(dx * dx + 1 + dz * dz)
            local shade = Clamp((-dx * lx + ly - dz * lz) / nl, 0, 1)
            local light = 0.75 + 0.95 * shade             -- texture averages are dark: the picture is brightened a little
            r, g, b = r * light, g * light, b * light
            -- water
            if waterOn and hc < waterElev then
                local depth = Clamp((waterElev - hc) / 12, 0, 1)
                local a = 0.45 + 0.45 * depth
                r, g, b = r * (1 - a) + wr * a, g * (1 - a) + wg * a, b * (1 - a) + wb * a
            end
            pixels[j * size + i + 1] = Clamp(math.floor(r + 0.5), 0, 255) * 65536 + Clamp(math.floor(g + 0.5), 0, 255) * 256 + Clamp(math.floor(b + 0.5), 0, 255)
        end
    end
    return pixels
end

function Apply(scmapPath)
    local pixels = Render(SIZE)
    if not pixels then return nil, 'no terrain' end
    return ed_scmap_set_preview(scmapPath, SIZE, SIZE, pixels)
end

--- Writes the preview as an RGB PNG (size x size, 256 or 512). true | false, reason.
function ExportPng(path, size)
    size = size or 256
    local px = Render(size)
    if not px then return false, 'no map' end
    return import('/lua/editor/png.lua').Write(path, size, size, px)
end
