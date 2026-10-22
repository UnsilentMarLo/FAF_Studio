-- Shaded-relief pictures of normal maps. A tangent normal map shown as it is (red = x, green = y, blue = z, so almost everything is blue / purple) hides its detail; this module draws
-- what the normals describe instead: the surface lit from the upper left like a hillshade, contrast stretched so that even a shallow texture shows its bumps, with a little of the
-- hue of the albedo texture when one is given.
--
--   Preview(path, opts) -> vfs path | nil, layout   a 128 x 128 relief picture of the normal map `path` (a VFS or a disk path). It is made once and kept on disk (a folder of the user data,
--                                                   `normalpreview/v<Version>/`, mounted as /ednormals): the file name is a hash of path, albedo, the time stamps of both files, the size
--                                                   and Version, so a changed texture gets a new picture and raising Version starts a new folder. Returns nil when anything fails
--                                                   (no native, unreadable file): the caller then shows the raw texture. opts.albedo: the albedo texture whose hue tints the picture.
--                                                   The second result is the channel layout found ('rgb' or 'ag').
--   Cached(path, opts)  -> vfs path | nil           only what is on disk already (no decoding)
--   Relief(px, w, h, opts) -> pixels                the pure part: `px` is the list of w * h * 4 numbers 0..255 that ed_dds_read gives (R, G, B, A per pixel); the result is a list of the
--                                                   same size, ready for ed_dds_write (grey 128 = a flat surface, lighter = facing the light, darker = facing away).
--                                                   opts: layout ('rgb' | 'ag', else Layout()), tint (a pixel list of the same size) and tintAmount (0..1, default TINT), gain (else stretched).
--   Layout(px, w, h) -> 'rgb' | 'ag'                how the normal is stored. 'rgb': x, y, z in red, green, blue (the layer normals of all terrain shaders: terrain.fx reads
--                                                   `tex2D(...) * 2 - 1`; the shaders.lua tables call it XYZ). 'ag': the DXT5nm style, x in alpha, y in green, z left out (rebuilt from x
--                                                   and y), recognised by a red channel that is the same everywhere and far from the middle (255 or 0) beside an alpha channel that varies.
--
-- The picture is lit from the upper left, 45 degrees above the surface (LIGHT, in the texture's x right / y up space, which is what the green channel of the usual normal maps holds; a map
-- that stores y the other way round shows its bumps as dents). Used by the Layers panel (gui/panels_strata.lua); the texture browser may use Preview() for normal maps.
--
-- Cost: one native reduction of the texture (ed_dds_thumb: any source size in a few milliseconds) and two Lua loops over 128 * 128 pixels; nothing when the picture is on disk.
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')

Version = 1
Size = 128
TINT = 0.3                          -- how much of the albedo hue is mixed in
LIGHT = { -0.5, 0.5, 0.7071 }       -- the direction to the light (unit length): from the upper left, 45 degrees up
BINS = 150                          -- histogram bins per unit of brightness deviation (the contrast stretch)
MIN_SPREAD = 0.02                   -- a surface flatter than this is not stretched further (the noise of 8 bit normals would fill the picture)

local mounted = false
local failed = {}                   -- cache names that could not be made: not tried again in this run

function Dir() return UserData.Path('normalpreview/v' .. Version) end

local function Natives()
    return rawget(_G, 'ed_dds_thumb') and rawget(_G, 'ed_dds_read') and rawget(_G, 'ed_dds_write') and rawget(_G, 'ed_vfs_mount')
        and rawget(_G, 'ed_write_file') and rawget(_G, 'ed_file_exists')
end

-- ---- the picture -----------------------------------------------------------------------------------------------------------------------------

--- How the normals are stored in `px`: 'rgb' or 'ag' (see the header).
function Layout(px, w, h)
    local n = w * h
    if n < 1 then return 'rgb' end
    local sr, sr2, sa, sa2 = 0, 0, 0, 0
    for i = 0, n - 1 do
        local r, a = px[i * 4 + 1] - 128, px[i * 4 + 4] - 128      -- around 0: the sums stay small (numbers are 32 bit floats)
        sr = sr + r
        sr2 = sr2 + r * r
        sa = sa + a
        sa2 = sa2 + a * a
    end
    local mr, ma = sr / n, sa / n
    local stdR = math.sqrt(math.max(0, sr2 / n - mr * mr))
    local stdA = math.sqrt(math.max(0, sa2 / n - ma * ma))
    -- DXT5nm leaves red at 255 (or 0): a red channel that is constant around the middle is an RGB map that happens not to lean in x
    if stdR < 4 and stdA >= 8 and math.abs(mr) > 60 then return 'ag' end
    return 'rgb'
end

--- The relief picture of the normal map pixels `px` (w * h * 4 numbers 0..255); a list of the same size with alpha 255.
function Relief(px, w, h, opts)
    opts = opts or {}
    local n = w * h
    local layout = opts.layout or Layout(px, w, h)
    local lx, ly, lz = LIGHT[1], LIGHT[2], LIGHT[3]
    local shade, hist = {}, {}
    for b = 0, 255 do hist[b] = 0 end
    for i = 0, n - 1 do
        local o = i * 4
        local nx, ny, nz
        if layout == 'ag' then
            nx, ny = px[o + 4] / 127.5 - 1, px[o + 2] / 127.5 - 1
            nz = 1 - nx * nx - ny * ny
            if nz > 0 then nz = math.sqrt(nz) else nz = 0 end
        else
            nx, ny, nz = px[o + 1] / 127.5 - 1, px[o + 2] / 127.5 - 1, px[o + 3] / 127.5 - 1
            if nz < 0.05 then                       -- a missing or broken blue channel: rebuild z from x and y
                nz = 1 - nx * nx - ny * ny
                if nz > 0 then nz = math.sqrt(nz) else nz = 0 end
            end
        end
        local len = math.sqrt(nx * nx + ny * ny + nz * nz)
        if len < 0.0001 then nx, ny, nz, len = 0, 0, 1, 1 end
        local s = (nx * lx + ny * ly + nz * lz) / len - lz          -- 0 on a flat surface
        shade[i + 1] = s
        local bin = math.floor(math.abs(s) * BINS)
        if bin > 255 then bin = 255 end
        hist[bin] = hist[bin] + 1
    end
    -- the contrast stretch: the 98th percentile of the deviation from flat becomes (nearly) full black / white
    local gain = opts.gain
    if not gain then
        local want, seen, spread = n * 0.98, 0, 1.7
        for b = 0, 255 do
            seen = seen + hist[b]
            if seen >= want then spread = (b + 1) / BINS break end
        end
        gain = 0.45 / math.max(spread, MIN_SPREAD)
    end
    local tint = opts.tint
    if tint and not tint[n * 4] then tint = nil end
    local ta = opts.tintAmount or TINT
    local out = {}
    for i = 0, n - 1 do
        local o = i * 4
        local v = 0.5 + shade[i + 1] * gain
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        local r, g, b = v, v, v
        if tint then
            local tr, tg, tb = tint[o + 1], tint[o + 2], tint[o + 3]
            local luma = 0.3 * tr + 0.59 * tg + 0.11 * tb
            if luma > 8 then
                local k = 1 / luma                       -- the hue of the albedo with its brightness taken out
                r = v * (1 - ta + ta * math.min(1.6, math.max(0.4, tr * k)))
                g = v * (1 - ta + ta * math.min(1.6, math.max(0.4, tg * k)))
                b = v * (1 - ta + ta * math.min(1.6, math.max(0.4, tb * k)))
            end
        end
        out[o + 1] = math.floor(math.min(1, r) * 255 + 0.5)
        out[o + 2] = math.floor(math.min(1, g) * 255 + 0.5)
        out[o + 3] = math.floor(math.min(1, b) * 255 + 0.5)
        out[o + 4] = 255
    end
    return out, layout
end

-- ---- the cache -------------------------------------------------------------------------------------------------------------------------------

local function Hash(text, mod, mul)
    local h = 7
    for i = 1, string.len(text) do
        h = math.mod(h * mul + string.byte(text, i), mod)
    end
    return h
end

--- The time stamp of the file a path comes from (a file inside an archive is stamped by the archive).
local function Stamp(path)
    if not path or path == '' then return '0' end
    local disk = rawget(_G, 'ed_vfs_to_disk') and ed_vfs_to_disk(path) or path
    local scd = string.find(string.lower(disk), '%.scd[\\/]')
    if scd then disk = string.sub(disk, 1, scd + 3) end
    return tostring(rawget(_G, 'ed_file_stamp') and ed_file_stamp(disk) or '0')
end

--- The cache file name for a normal map (and the albedo that tints it).
function Name(path, albedo)
    albedo = albedo or ''
    local text = path .. '|' .. Stamp(path) .. '|' .. albedo .. '|' .. (albedo ~= '' and Stamp(albedo) or '0') .. '|' .. Size .. '|' .. Version
    return string.format('n_%04x%04x%04x.dds', Hash(text, 65521, 31), Hash(text, 65519, 37), Hash(text, 65497, 41))
end

local function Mount()
    if mounted then return true end
    ed_write_file(Dir() .. '/.keep', '')
    mounted = ed_vfs_mount(Dir(), '/ednormals') and true or false
    return mounted
end

local function Usable(path)
    return path and path ~= '' and Natives()
end

function Cached(path, opts)
    if not Usable(path) then return nil end
    local name = Name(path, opts and opts.albedo)
    if ed_file_exists(Dir() .. '/' .. name) and Mount() then return '/ednormals/' .. name end
    return nil
end

--- `path` reduced to Size x Size and read as pixels (through a scratch file), or nil.
local function ReadSmall(path, scratchName)
    local disk = rawget(_G, 'ed_vfs_to_disk') and ed_vfs_to_disk(path) or path
    local scratch = UserData.Path('normalpreview/' .. scratchName)
    local w = ed_dds_thumb(disk, scratch, Size)
    if not w then return nil end
    local px, tw, th = ed_dds_read(scratch)
    if not px then return nil end
    return px, tw, th
end

local function Make(path, opts, file)
    local px, w, h = ReadSmall(path, 'scratch_normal.dds')
    if not px then return nil end
    local ropts = {}
    if opts and opts.albedo and opts.albedo ~= '' then
        local ok, apx, aw, ah = pcall(ReadSmall, opts.albedo, 'scratch_albedo.dds')
        if ok and apx and aw == w and ah == h then ropts.tint = apx end
    end
    local out, layout = Relief(px, w, h, ropts)
    if not ed_dds_write(file, w, h, out, 1) then return nil end
    return layout
end

--- The relief picture of the normal map `path` (see the header); nil when it cannot be made.
function Preview(path, opts)
    if not Usable(path) then return nil end
    local name = Name(path, opts and opts.albedo)
    local file = Dir() .. '/' .. name
    if ed_file_exists(file) then
        if Mount() then return '/ednormals/' .. name end
        return nil
    end
    if failed[name] then return nil end
    local ok, layout = pcall(Make, path, opts, file)
    if not ok or not layout or not Mount() then
        failed[name] = true
        if not ok then LOG('EDITOR normalpreview: ' .. tostring(path) .. ': ' .. tostring(layout)) end
        return nil
    end
    return '/ednormals/' .. name, layout
end
