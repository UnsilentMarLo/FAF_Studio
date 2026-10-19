-- Brush shapes: a greyscale mask over the brush disc (u, v in -1..1, value 0..1) that replaces the round falloff profile of the height and texture
-- brushes. Procedural shapes are functions; image masks (greyscale PNG / TIFF / DDS-less formats WIC reads) found in the brush folders are loaded on
-- first use at 64 x 64.
--
--   List()                      { id, label, kind = 'round' | 'proc' | 'image', path? }  round (the falloff curve) first
--   Active                      id of the shape the brushes use ('round' = none)
--   Angle                       degrees the mask is turned; RandomAngle: every stroke adds a random turn
--   Weight(id, dx, dz, r, turn) -> 0..1: the mask value at the offset (dx, dz) from the centre of a brush of radius r, turned by `turn` degrees more
--   Folders                     where image masks are searched (VFS paths): the editor's /brushes, mods' /brushes and the user's own (/edbrushes, see Import)
--   Sample(id, u, v, n)         -> 0..1: the mask at (u, v) in the unit square -1..1 (no rotation, no falloff); image masks are loaded at n x n (default 64; the stamp tools ask for 128)
--   Import(paths)               copies image files (PNG / TIF / BMP / DDS) into the user's brush folder and rescans: -> number copied
--   Entry(id)                   the List() entry of a shape id
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

Active = 'round'
Angle = 0
RandomAngle = false

Folders = { '/brushes', '/edbrushes' }
USER_FOLDER = 'brushes'       -- below the user data folder; mounted as /edbrushes
EXTENSIONS = { '*.png', '*.tif', '*.tiff', '*.bmp', '*.dds' }

local mounted = false

local function MountUser()
    if mounted then return end
    local ok, UserData = pcall(import, '/lua/editor/userdata.lua')
    if not ok then return end
    ed_write_file(UserData.Path(USER_FOLDER) .. '/.keep', '')
    mounted = ed_vfs_mount and ed_vfs_mount(UserData.Path(USER_FOLDER), '/edbrushes') and true or false
end

--- Smoothstep from 0 at x = a to 1 at x = b (a may be larger than b: it then falls as x grows).
local function Smooth(a, b, x)
    local t = (x - a) / (b - a)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * t * (3 - 2 * t)
end

-- value noise in 0..1, deterministic
local function Hash(ix, iz)
    local n = ix * 374761393 + iz * 668265263
    n = math.mod(n, 2147483647)
    n = math.mod(n * 1103515245 + 12345, 2147483647)
    return math.mod(n, 65536) / 65535
end

local function ValueNoise(x, z)
    local ix, iz = math.floor(x), math.floor(z)
    local fx, fz = x - ix, z - iz
    fx = fx * fx * (3 - 2 * fx)
    fz = fz * fz * (3 - 2 * fz)
    local a, b = Hash(ix, iz), Hash(ix + 1, iz)
    local c, d = Hash(ix, iz + 1), Hash(ix + 1, iz + 1)
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fz
end

local function Fractal(x, z)
    return 0.55 * ValueNoise(x * 2, z * 2) + 0.3 * ValueNoise(x * 4 + 7, z * 4 + 3) + 0.15 * ValueNoise(x * 8 + 1, z * 8 + 11)
end

local proc = {
    { id = 'square',   label = 'Square',   f = function(u, v) return Smooth(1.0, 0.85, math.max(math.abs(u), math.abs(v))) end },
    { id = 'diamond',  label = 'Diamond',  f = function(u, v) return Smooth(1.0, 0.8, math.abs(u) + math.abs(v)) end },
    { id = 'cone',     label = 'Cone',     f = function(u, v) return math.max(0, 1 - math.sqrt(u * u + v * v)) end },
    { id = 'plateau',  label = 'Plateau',  f = function(u, v) return Smooth(1.0, 0.7, math.sqrt(u * u + v * v)) end },
    { id = 'ring',     label = 'Ring',     f = function(u, v)
        local d = math.sqrt(u * u + v * v)
        return Smooth(0.45, 0.7, d) * Smooth(1.0, 0.85, d)
    end },
    { id = 'ridge',    label = 'Ridge',    f = function(u, v)
        return Smooth(1.0, 0.85, math.abs(u)) * Smooth(0.35, 0.0, math.abs(v))
    end },
    { id = 'mountain', label = 'Mountain', f = function(u, v)
        local d = math.sqrt(u * u + v * v)
        local cone = math.max(0, 1 - d)
        return math.min(1, cone * (0.35 + 1.3 * Fractal(u + 3.7, v + 1.9)))
    end },
    { id = 'rocks',    label = 'Rocks',    f = function(u, v)
        local d = math.sqrt(u * u + v * v)
        if d >= 1 then return 0 end
        return Smooth(0.5, 0.62, ValueNoise(u * 3 + 11, v * 3 + 5)) * (1 - d)
    end },
    { id = 'bump',     label = 'Bump',     f = function(u, v)
        local d = math.sqrt(u * u + v * v)
        if d >= 1 then return 0 end
        return 0.5 * (1 + math.cos(3.14159265 * d))
    end },
}

local images = false
local imageById = {}
local masks = {}      -- id -> { n, values } loaded image masks

local function Basename(path)
    return (string.gsub(string.gsub(path, '^.*/', ''), '%.[^%.]*$', ''))
end

--- Every shape: the round profile, the procedural ones and the image masks of the brush folders.
function List()
    local list = { { id = 'round', label = 'Round (falloff)', kind = 'round' } }
    for _, p in proc do table.insert(list, { id = p.id, label = p.label, kind = 'proc' }) end
    if not images then
        images = {}
        MountUser()
        for _, folder in Folders do
            for _, ext in EXTENSIONS do
                for _, path in DiskFindFiles(folder, ext) or {} do
                    table.insert(images, { id = 'img:' .. string.lower(path), label = Basename(path), kind = 'image', path = path })
                end
            end
        end
        table.sort(images, function(a, b) return a.label < b.label end)
        imageById = {}
        for _, e in images do imageById[e.id] = e end
    end
    for _, e in images do table.insert(list, e) end
    return list
end

function Rescan()
    images = false
    masks = {}
end

local function Mask(entry, n)
    n = n or 64
    local key = entry.id .. '|' .. n
    local m = masks[key]
    if m then return m end
    local disk = ed_vfs_to_disk and ed_vfs_to_disk(entry.path) or entry.path
    local values
    if disk and string.find(string.lower(entry.path), '%.dds$') then
        -- a DDS is reduced natively to n x n; a picture that has an alpha channel and a flat colour (white brushes) is read by its alpha
        local tmp = import('/lua/editor/userdata.lua').Path('assetthumbs/brushmask.dds')
        if ed_dds_thumb(disk, tmp, n) then
            local px = ed_dds_read(tmp)
            if px then
                local lum, alpha = {}, {}
                local lmin, lmax, amin, amax = 255, 0, 255, 0
                for i = 1, n * n do
                    local r, g, b, a = px[i * 4 - 3], px[i * 4 - 2], px[i * 4 - 1], px[i * 4]
                    local l = 0.3 * r + 0.59 * g + 0.11 * b
                    lum[i], alpha[i] = l, a
                    if l < lmin then lmin = l end if l > lmax then lmax = l end
                    if a < amin then amin = a end if a > amax then amax = a end
                end
                local src = ((lmax - lmin) < 8 and (amax - amin) >= 32) and alpha or lum
                values = {}
                for i = 1, n * n do values[i] = src[i] / 255 end
            end
        end
    elseif disk then
        local words = ed_image_read16(disk, n, n)
        if words then
            values = {}
            for i = 1, n * n do values[i] = words[i] / 65535 end
        end
    end
    if values then
        m = { n = n, values = values }
    else
        m = { n = 2, values = { 0, 0, 0, 0 } }
    end
    masks[key] = m
    return m
end

local function ImageSample(m, u, v)
    local n = m.n
    local fx, fz = (u + 1) * 0.5 * (n - 1), (v + 1) * 0.5 * (n - 1)
    if fx < 0 or fz < 0 or fx > n - 1 or fz > n - 1 then return 0 end
    local x0, z0 = math.min(n - 2, math.floor(fx)), math.min(n - 2, math.floor(fz))
    local tx, tz = fx - x0, fz - z0
    local function At(x, z) return m.values[z * n + x + 1] end
    local top = At(x0, z0) * (1 - tx) + At(x0 + 1, z0) * tx
    local bottom = At(x0, z0 + 1) * (1 - tx) + At(x0 + 1, z0 + 1) * tx
    return top * (1 - tz) + bottom * tz
end

local procById = false

local function Find(id)
    if not procById then
        procById = {}
        for _, p in proc do procById[p.id] = p end
    end
    return procById[id]
end

function Entry(id)
    if id == 'round' then return { id = 'round', label = 'Round (falloff)', kind = 'round' } end
    if not images then List() end
    local p = Find(id)
    if p then return { id = p.id, label = p.label, kind = 'proc' } end
    return imageById[id]
end

--- The mask at (u, v) of the unit square (-1..1 each; the shape lies inside the unit disc), not rotated. 'round' is a flat disc here.
function Sample(id, u, v, n)
    if id == 'round' then return (u * u + v * v <= 1) and 1 or 0 end
    local p = Find(id)
    if p then return p.f(u, v) end
    if string.sub(id, 1, 4) == 'img:' then
        if not images then List() end
        local e = imageById[id]
        if e then return ImageSample(Mask(e, n), u, v) end
    end
    return 0
end

--- Copies image files (disk paths) into the user's brush folder and rescans. Returns the number copied. A name that exists is replaced.
function Import(paths)
    local UserData = import('/lua/editor/userdata.lua')
    local count = 0
    MountUser()
    for _, path in paths or {} do
        local name = string.gsub(string.gsub(path, '[\\]', '/'), '^.*/', '')
        local lower = string.lower(name)
        if string.find(lower, '%.png$') or string.find(lower, '%.tiff?$') or string.find(lower, '%.bmp$') or string.find(lower, '%.dds$') then
            local data = ed_read_file(path)
            if data and data ~= '' and ed_write_file(UserData.Path(USER_FOLDER .. '/' .. name), data) then count = count + 1 end
        end
    end
    if count > 0 then Rescan() end
    return count
end

--- Mask value at offset (dx, dz) from the centre of a brush of radius r, the mask turned by Angle + `turn` degrees.
function Weight(id, dx, dz, r, turn)
    local a = math.rad((Angle or 0) + (turn or 0))
    local c, s = math.cos(a), math.sin(a)
    local u = (dx * c + dz * s) / r
    local v = (-dx * s + dz * c) / r
    if u * u + v * v > 1.6 then return 0 end
    local p = Find(id)
    if p then return p.f(u, v) end
    if string.sub(id, 1, 4) == 'img:' then
        if not images then List() end
        local e = imageById[id]
        if e then return ImageSample(Mask(e), u, v) end
    end
    return 0
end
