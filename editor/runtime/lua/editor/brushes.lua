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
--   Grid(id, n)                 the shape rasterised once on an n x n grid over the unit square (corners on the samples): { n, values } with values[z * n + x + 1]. Procedural shapes
--                               are evaluated at n (default 129), image masks are read at n (default 64); both are cached until Rescan(). Weight, Fill, the stamp tools and the native
--                               brush (NativeShape) all read this one grid, bilinear, so no shape function or file is touched per sample.
--   GridSample(g, u, v)         the bilinear read of a grid (0 outside the unit square)
--   Fill(id, r, turn, px, pz, x0, z0, x1, z1 [, scale])    the weights Weight gives a brush of radius r at (px, pz) over the samples x0..x1 / z0..z1 (a table, row after row), 0 at and
--                               beyond the radius; with `scale` each is floor(weight * scale) (the cursor preview); a tight loop (the erosion brush and the preview use it)
--   NativeShape(id)             the handle of the shape in the exe's brush shape table (ed_brush_shape_set, uploaded once per shape and Rescan), or nil when the exe has no such native
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Perf = import('/lua/editor/perf.lua')

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

local grids = {}      -- 'id|n' -> { n, values }: procedural shapes rasterised (images are in `masks`)
local gridRev = 0        -- bumped by Rescan: anything derived from the grids (the exe's shape table) is stale when it differs
local PROC_RES = 129     -- procedural shapes are rasterised at 129 x 129 (an odd size puts the middle of the brush, u = v = 0, on a grid sample, so a cone keeps its peak; the finest feature, the mountain's third octave, is 8 grid steps wide)

--- Changes whenever the grids are dropped (Rescan): a cached grid or exe shape from an older revision is stale.
function Revision()
    return gridRev
end

function Rescan()
    images = false
    masks = {}
    grids = {}
    gridRev = gridRev + 1
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

--- The bilinear read of a grid { n, values } at (u, v) of the unit square (-1..1); 0 outside it.
function GridSample(m, u, v)
    local n = m.n
    local top = n - 1
    local fx, fz = (u + 1) * 0.5 * top, (v + 1) * 0.5 * top
    if fx < 0 or fz < 0 or fx > top or fz > top then return 0 end
    local x0, z0 = math.min(n - 2, math.floor(fx)), math.min(n - 2, math.floor(fz))
    local tx, tz = fx - x0, fz - z0
    local vals = m.values
    local i = z0 * n + x0 + 1
    local a, b, c, d = vals[i], vals[i + 1], vals[i + n], vals[i + n + 1]
    local upper = a * (1 - tx) + b * tx
    local lower = c * (1 - tx) + d * tx
    return upper * (1 - tz) + lower * tz
end

local ImageSample = GridSample

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

--- The grid of a shape id (see the header), cached. nil for 'round' and an unknown id.
function Grid(id, n)
    local p = Find(id)
    if p then
        n = n or PROC_RES
        local key = id .. '|' .. n
        local g = grids[key]
        if g then return g end
        local t0 = Perf.Begin()
        local values = {}
        local f = p.f
        local step = 2 / (n - 1)
        for j = 0, n - 1 do
            local v = j * step - 1
            local row = j * n + 1
            for i = 0, n - 1 do
                values[row + i] = f(i * step - 1, v)
            end
        end
        g = { n = n, values = values }
        grids[key] = g
        Perf.End('brush.mask', t0)
        return g
    end
    if string.sub(id, 1, 4) == 'img:' then
        if not images then List() end
        local e = imageById[id]
        if e then
            local t0 = Perf.Begin()
            local g = Mask(e, n)
            Perf.End('brush.mask', t0)
            return g
        end
    end
    return nil
end

local trigAngle, trigC, trigS = nil, 1, 0      -- cos / sin of the last angle used (the angle is the same for every sample of a dab)
local lastId, lastGrid, lastRev = nil, nil, -1 -- the grid of the last shape id Weight read

--- Mask value at offset (dx, dz) from the centre of a brush of radius r, the mask turned by Angle + `turn` degrees. A bilinear read of Grid(id): the native brush
--- (ed_terrain_brush with a shape handle, EdBrush.h ShapeSampler) does the same arithmetic.
function Weight(id, dx, dz, r, turn)
    local angle = (Angle or 0) + (turn or 0)
    if angle ~= trigAngle then
        trigAngle = angle
        local a = math.rad(angle)
        trigC, trigS = math.cos(a), math.sin(a)
    end
    local c, s = trigC, trigS
    local u = (dx * c + dz * s) / r
    local v = (-dx * s + dz * c) / r
    if u * u + v * v > 1.6 then return 0 end
    local g
    if id == lastId and lastRev == gridRev then
        g = lastGrid
    else
        g = Grid(id)
        lastId, lastGrid, lastRev = id, g, gridRev
    end
    if not g then return 0 end
    -- (GridSample inlined: the texture brush calls this once per mask cell)
    local n = g.n
    local top = n - 1
    local fx, fz = (u + 1) * 0.5 * top, (v + 1) * 0.5 * top
    if fx < 0 or fz < 0 or fx > top or fz > top then return 0 end
    local x0, z0 = math.min(n - 2, math.floor(fx)), math.min(n - 2, math.floor(fz))
    local tx, tz = fx - x0, fz - z0
    local vals = g.values
    local i = z0 * n + x0 + 1
    local upper = vals[i] * (1 - tx) + vals[i + 1] * tx
    local lower = vals[i + n] * (1 - tx) + vals[i + n + 1] * tx
    return upper * (1 - tz) + lower * tz
end

--- The weights of a shaped brush over a sample rectangle (see the header): the loop of Weight with everything hoisted, for the cursor preview and the erosion brush.
function Fill(id, r, turn, px, pz, x0, z0, x1, z1, scale)
    local t0 = Perf.Begin()
    local out = {}
    local g = Grid(id)
    local n = 0
    if not g or not (r > 0) then
        for i = 1, (x1 - x0 + 1) * (z1 - z0 + 1) do out[i] = 0 end
        Perf.End('brush.fill', t0)
        return out
    end
    local a = math.rad((Angle or 0) + (turn or 0))
    local c, s = math.cos(a), math.sin(a)
    local gn, vals = g.n, g.values
    local top = gn - 1
    local sqrt, floor = math.sqrt, math.floor
    for z = z0, z1 do
        local dz = z - pz
        local dz2 = dz * dz
        for x = x0, x1 do
            local dx = x - px
            n = n + 1
            local w = 0
            if sqrt(dx * dx + dz2) < r then
                local u = (dx * c + dz * s) / r
                local v = (-dx * s + dz * c) / r
                if u * u + v * v <= 1.6 then
                    local fx, fz = (u + 1) * 0.5 * top, (v + 1) * 0.5 * top
                    if fx >= 0 and fz >= 0 and fx <= top and fz <= top then
                        local ix, iz = floor(fx), floor(fz)
                        if ix > gn - 2 then ix = gn - 2 end
                        if iz > gn - 2 then iz = gn - 2 end
                        local tx, tz = fx - ix, fz - iz
                        local i = iz * gn + ix + 1
                        local upper = vals[i] * (1 - tx) + vals[i + 1] * tx
                        local lower = vals[i + gn] * (1 - tx) + vals[i + gn + 1] * tx
                        w = upper * (1 - tz) + lower * tz
                    end
                end
            end
            if scale then w = floor(w * scale) end
            out[n] = w
        end
    end
    Perf.End('brush.fill', t0)
    return out
end

local handles = {}       -- shape id -> { handle, rev, ok }: where the shape lives in the exe's table
local nextHandle = 0

--- The handle of a shape in the exe's brush shape table (ed_brush_shape_set, EdBrush.cpp), uploading its grid on first use and after Rescan; nil when the exe has no
--- such native, the shape is 'round' / unknown or the upload failed. The native dab (ed_terrain_brush) and the erosion brush read the shape by this handle.
function NativeShape(id)
    local set = rawget(_G, 'ed_brush_shape_set')
    if not set then return nil end
    local h = handles[id]
    if h and h.rev == gridRev then return h.ok and h.handle or nil end
    local g = Grid(id)
    if not g then return nil end
    if not h then
        nextHandle = nextHandle + 1
        h = { handle = nextHandle }
        handles[id] = h
    end
    local t0 = Perf.Begin()
    h.ok = set(h.handle, g.n, g.values) and true or false
    Perf.End('brush.upload', t0)
    h.rev = gridRev
    return h.ok and h.handle or nil
end
