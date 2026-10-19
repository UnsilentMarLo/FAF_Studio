-- SCM version 5 meshes (units and terrain patches): reader and writer in Lua, golden-tested against scripts/meshmaps/scm.py (selftest_meshimport.lua).
--
-- Layout (docs/projects/editor_research/MESH_MAP_EDITOR_NEEDS.md section 1.4): every block starts on a 32-byte boundary, the 4 bytes before it are its tag,
-- the gap is filled with 0xC5.
--   0    'MODL', u32 5, u32 bone offset, u32 skinned bone count, u32 vertex offset, u32 extra vertex offset (0), u32 vertex count,
--        u32 index offset, u32 index count, u32 info offset, u32 info size, u32 total bone count
--   NAME bone names, SKEL bones (108 bytes), VTXL vertices (68 bytes: position, normal, tangent, binormal, uv1, uv2, 4 bone bytes),
--   TRIS u16 indices (triangle list, **at most 65,535 vertices per file**), INFO strings
--
-- A mesh is a table of flat arrays (1-based vertex numbers, 3 or 2 numbers per vertex):
--   { n = vertex count, pos = {x,y,z,...}, nrm = {...}, tan = {...}, bin = {...}, uv1 = {u,v,...}, uv2 = {u,v,...}, idx = { v1,v2,v3, ... } }
-- A skinned unit mesh adds `bones` = { { name, parent (0-based index, -1 for the root), rest = { 12 numbers of the inverse bind pose: 3 rows of 3, then the translation row }, pos = {x,y,z}, rot = {w,x,y,z} }, ... }
-- (`rest` may be left out: BindPose(bones) computes it from pos and rot, parents first) and `bone` = the 1-based bone number minus one (0 = root) of every vertex; Write then writes that skeleton instead of the one root bone.
-- Read(data) -> mesh | nil, reason;  Write(mesh [, name, info]) -> bytes, bounds { x0,y0,z0, x1,y1,z1 };  Header(data) -> counts or nil, reason;
-- New() an empty mesh;  Split(mesh, limit, tile) -> list of meshes (port of scm.split);  Bounds(mesh).
--
-- Lua 5.0 dialect. (LuaPlus string.byte returns ONE value, whatever the range: every byte is its own call.) Numbers are 32-bit floats, which is exactly what the format stores, so a read followed by a write is byte exact.

LIMIT = 65535

local floor, mod, frexp = math.floor, math.mod, math.frexp
local sbyte, schar, ssub = string.byte, string.char, string.sub
local INF = 1 / 0
local NAN = 0 / 0

-- 2^(E-127) for the biased exponent E of a float32
local pow2 = {}
for e = 1, 254 do pow2[e] = math.ldexp(1, e - 127) end

--- Reads the float32 at byte `p` (1-based, little endian). Denormals read as 0.
function F32(s, p)
    local b0, b1, b2, b3 = sbyte(s, p), sbyte(s, p + 1), sbyte(s, p + 2), sbyte(s, p + 3)
    local e = mod(b3, 128) * 2 + (b2 >= 128 and 1 or 0)
    local v
    if e == 0 then
        v = 0
    elseif e == 255 then
        v = ((mod(b2, 128) * 65536 + b1 * 256 + b0) == 0) and INF or NAN
    else
        v = (1 + (mod(b2, 128) * 65536 + b1 * 256 + b0) / 8388608) * pow2[e]
    end
    if b3 >= 128 then v = -v end
    return v
end

local cache, cacheSize = {}, 0
local NANBYTES = string.char(0, 0, 192, 127)
local POSZERO, NEGZERO = string.char(0, 0, 0, 0), string.char(0, 0, 0, 128)

--- The 4 bytes of a float32.
function PackF32(x)
    if x ~= x then return NANBYTES end
    if x == 0 then return (1 / x < 0) and NEGZERO or POSZERO end      -- the sign of a negative zero is kept, like struct.pack does
    local c = cache[x]
    if c then return c end
    local key = x
    local b0, b1, b2, b3
    do
        local sign = 0
        if x < 0 then sign = 128 x = -x end
        local m, e = frexp(x)
        local E = e + 126
        if E >= 255 then
            b0, b1, b2, b3 = 0, 0, 128, 127 + sign
        elseif E <= 0 then
            b0, b1, b2, b3 = 0, 0, 0, sign
        else
            local f = floor((m * 2 - 1) * 8388608 + 0.5)
            b0 = mod(f, 256)
            local f1 = (f - b0) / 256
            b1 = mod(f1, 256)
            local f2 = (f1 - b1) / 256
            b2 = f2 + mod(E, 2) * 128
            b3 = floor(E / 2) + sign
        end
    end
    c = schar(b0, b1, b2, b3)
    if cacheSize > 40000 then cache, cacheSize = {}, 0 end
    cache[key] = c
    cacheSize = cacheSize + 1
    return c
end

local function U32(s, p)
    local d = sbyte(s, p + 3)
    if not d then return nil end
    local a, b, c = sbyte(s, p), sbyte(s, p + 1), sbyte(s, p + 2)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function PackU32(n)
    local a = mod(n, 256)
    n = (n - a) / 256
    local b = mod(n, 256)
    n = (n - b) / 256
    local c = mod(n, 256)
    return schar(a, b, c, (n - c) / 256)
end

local function PackU16(n)
    local a = mod(n, 256)
    return schar(a, (n - a) / 256)
end

function New()
    return { n = 0, pos = {}, nrm = {}, tan = {}, bin = {}, uv1 = {}, uv2 = {}, idx = {} }
end

-- ---- reading ---------------------------------------------------------------------------------------------------------------------------------

--- Counts and offsets of an SCM v5 file, or nil + reason. Only the header is looked at, plus the size checks the patch makes.
function Header(data)
    if not data or string.len(data) < 48 then return nil, 'file too short' end
    if ssub(data, 1, 4) ~= 'MODL' then return nil, 'not an SCM file (no MODL header)' end
    local version = U32(data, 5)
    if version ~= 5 then return nil, 'SCM version ' .. tostring(version) .. ', the patch reads version 5' end
    local h = { vertexAt = U32(data, 17), vertexCount = U32(data, 25), indexAt = U32(data, 29), indexCount = U32(data, 33), size = string.len(data) }
    if h.vertexCount > LIMIT then return nil, h.vertexCount .. ' vertices (at most ' .. LIMIT .. ' per patch)' end
    if mod(h.indexCount, 3) ~= 0 then return nil, 'index count ' .. h.indexCount .. ' is not a multiple of 3' end
    if h.vertexAt + h.vertexCount * 68 > h.size then return nil, 'vertex block runs past the end of the file' end
    if h.indexAt + h.indexCount * 2 > h.size then return nil, 'index block runs past the end of the file' end
    return h
end

--- Decodes the file. -> mesh, or nil + reason. `opts.noIndexCheck`: skip the range check of the indices.
function Read(data, opts)
    local h, why = Header(data)
    if not h then return nil, why end
    local m = New()
    local n = h.vertexCount
    m.n = n
    local pos, nrm, tan, bin, uv1, uv2 = m.pos, m.nrm, m.tan, m.bin, m.uv1, m.uv2
    local p = h.vertexAt + 1
    local i3, i2 = 0, 0
    for k = 1, n do
        pos[i3 + 1] = F32(data, p)      pos[i3 + 2] = F32(data, p + 4)   pos[i3 + 3] = F32(data, p + 8)
        nrm[i3 + 1] = F32(data, p + 12) nrm[i3 + 2] = F32(data, p + 16)  nrm[i3 + 3] = F32(data, p + 20)
        tan[i3 + 1] = F32(data, p + 24) tan[i3 + 2] = F32(data, p + 28)  tan[i3 + 3] = F32(data, p + 32)
        bin[i3 + 1] = F32(data, p + 36) bin[i3 + 2] = F32(data, p + 40)  bin[i3 + 3] = F32(data, p + 44)
        uv1[i2 + 1] = F32(data, p + 48) uv1[i2 + 2] = F32(data, p + 52)
        uv2[i2 + 1] = F32(data, p + 56) uv2[i2 + 2] = F32(data, p + 60)
        i3 = i3 + 3
        i2 = i2 + 2
        p = p + 68
    end
    local idx = m.idx
    p = h.indexAt + 1
    for i = 1, h.indexCount do
        local v = sbyte(data, p) + sbyte(data, p + 1) * 256
        if v >= n and not (opts and opts.noIndexCheck) then return nil, 'index ' .. (i - 1) .. ' points past the last vertex' end
        idx[i] = v + 1
        p = p + 2
    end
    return m
end

-- ---- skeletons -------------------------------------------------------------------------------------------------------------------------------

-- Matrices are row-vector 4x4 (Direct3D): v' = v * M. A bone's local transform is its rotation (quaternion w x y z, the transpose of the usual column matrix) and its position; the absolute
-- transform is local * parent's absolute; the file stores the inverse of the absolute one. Checked against the bones of the shipped units (selftest_unitwiz.lua).

local function QuatRows(w, x, y, z)
    local xx, yy, zz = x * x, y * y, z * z
    -- the usual (column vector) matrix, transposed
    return {
        { 1 - 2 * (yy + zz), 2 * (x * y + z * w), 2 * (x * z - y * w) },
        { 2 * (x * y - z * w), 1 - 2 * (xx + zz), 2 * (y * z + x * w) },
        { 2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (xx + yy) },
    }
end

--- The absolute transform of every bone: list of { R = 3x3 rows, t = {x, y, z} }, parents first.
local function Absolute(bones)
    local abs = {}
    for i, b in bones do
        local q = b.rot or { 1, 0, 0, 0 }
        local p = b.pos or { 0, 0, 0 }
        local R = QuatRows(q[1], q[2], q[3], q[4])
        local t = { p[1], p[2], p[3] }
        local parent = b.parent >= 0 and abs[b.parent + 1]
        if parent then
            local PR, PT = parent.R, parent.t
            local NR = {}
            for r = 1, 3 do
                NR[r] = {}
                for c = 1, 3 do NR[r][c] = R[r][1] * PR[1][c] + R[r][2] * PR[2][c] + R[r][3] * PR[3][c] end
            end
            local nt = {}
            for c = 1, 3 do nt[c] = t[1] * PR[1][c] + t[2] * PR[2][c] + t[3] * PR[3][c] + PT[c] end
            R, t = NR, nt
        end
        abs[i] = { R = R, t = t }
    end
    return abs
end

--- Fills `rest` (12 numbers) of every bone that has none, from pos and rot. -> the bones.
function BindPose(bones)
    local abs = Absolute(bones)
    for i, b in bones do
        if not b.rest then
            local R, t = abs[i].R, abs[i].t
            -- inverse of a rigid transform: the rotation transposed, the translation -t * R^T
            local rest = {}
            for r = 1, 3 do
                for c = 1, 3 do rest[(r - 1) * 3 + c] = R[c][r] end
            end
            for c = 1, 3 do rest[9 + c] = -(t[1] * R[c][1] + t[2] * R[c][2] + t[3] * R[c][3]) end
            b.rest = rest
        end
    end
    return bones
end

--- Positions of the bones in the bind pose: list of { x, y, z }.
function BonePositions(bones)
    local out = {}
    for i, a in Absolute(bones) do out[i] = { a.t[1], a.t[2], a.t[3] } end
    return out
end

-- ---- writing ---------------------------------------------------------------------------------------------------------------------------------

--- Bounding box of the positions: x0, y0, z0, x1, y1, z1 (nil for an empty mesh).
function Bounds(m)
    if m.n == 0 then return nil end
    local pos = m.pos
    local x0, y0, z0, x1, y1, z1 = pos[1], pos[2], pos[3], pos[1], pos[2], pos[3]
    for i = 4, m.n * 3, 3 do
        local x, y, z = pos[i], pos[i + 1], pos[i + 2]
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
        if z < z0 then z0 = z elseif z > z1 then z1 = z end
    end
    return x0, y0, z0, x1, y1, z1
end

--- The SCM v5 bytes of a mesh (one root bone, every vertex on it) and its bounds. `name`: the file name without extension (the bone's name),
--- `info`: list of strings for the INFO block. Missing tangent frames are written flat (1,0,0) / (0,0,1) like scm.py does.
function Write(m, name, info)
    local n = m.n
    if n > LIMIT then return nil, n .. ' vertices: an SCM file holds at most ' .. LIMIT end
    local ni = table.getn(m.idx)
    if mod(ni, 3) ~= 0 then return nil, 'index count ' .. ni .. ' is not a multiple of 3' end
    local out, len = {}, 0
    local function Add(s) table.insert(out, s) len = len + string.len(s) end
    local function Block(tag)
        Add(string.rep('\197', mod(32 - mod(len + 4, 32), 32)) .. tag)
    end
    Add(string.rep('\0', 48))
    Block('NAME')
    local nameOffset = len
    local bones = m.bones
    local boneNames = {}
    if bones then
        local names = ''
        for i, b in bones do
            boneNames[i] = nameOffset + string.len(names)
            names = names .. b.name .. '\0'
        end
        Add(names)
    else
        Add((name or 'patch') .. '\0')
    end
    Block('SKEL')
    local boneOffset = len
    local skinned = 1
    if bones then
        BindPose(bones)
        local used = 0
        local mb = m.bone
        for k = 1, n do
            local b = mb and mb[k] or 0
            if b > used then used = b end
        end
        skinned = used + 1
        for i, b in bones do
            local r = b.rest
            local rows = { r[1], r[2], r[3], 0, r[4], r[5], r[6], 0, r[7], r[8], r[9], 0, r[10], r[11], r[12], 1 }
            local f = {}
            for _, v in rows do table.insert(f, PackF32(v)) end
            for _, v in b.pos do table.insert(f, PackF32(v)) end
            for _, v in b.rot do table.insert(f, PackF32(v)) end
            Add(table.concat(f) .. PackU32(boneNames[i]) .. (b.parent < 0 and '\255\255\255\255' or PackU32(b.parent)) .. PackU32(0) .. PackU32(0))
        end
    else
        local bone = {}
        for _, v in { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 } do table.insert(bone, PackF32(v)) end
        Add(table.concat(bone) .. PackU32(nameOffset) .. '\255\255\255\255' .. PackU32(0) .. PackU32(0))
    end
    Block('VTXL')
    local vertexOffset = len
    local pos, nrm, tan, bin, uv1, uv2 = m.pos, m.nrm, m.tan, m.bin, m.uv1, m.uv2
    local parts = {}
    local chunk, chunkN = {}, 0
    local zero4 = '\0\0\0\0'
    local mbone = m.bone
    for k = 1, n do
        local a, b = (k - 1) * 3, (k - 1) * 2
        local t, bn = tan[a + 1], bin[a + 1]
        local row = {
            PackF32(pos[a + 1]), PackF32(pos[a + 2]), PackF32(pos[a + 3]),
            PackF32(nrm[a + 1] or 0), PackF32(nrm[a + 2] or 1), PackF32(nrm[a + 3] or 0),
            PackF32(t or 1), PackF32(tan[a + 2] or 0), PackF32(tan[a + 3] or 0),
            PackF32(bn or 0), PackF32(bin[a + 2] or 0), PackF32(bin[a + 3] or 1),
            PackF32(uv1[b + 1] or 0), PackF32(uv1[b + 2] or 0), PackF32(uv2[b + 1] or 0), PackF32(uv2[b + 2] or 0), (mbone and mbone[k] and mbone[k] > 0) and schar(mbone[k], 0, 0, 0) or zero4,
        }
        chunkN = chunkN + 1
        chunk[chunkN] = table.concat(row)
        if chunkN == 512 then
            table.insert(parts, table.concat(chunk))
            chunk, chunkN = {}, 0
        end
    end
    if chunkN > 0 then
        for i = chunkN + 1, table.getn(chunk) do chunk[i] = nil end
        table.insert(parts, table.concat(chunk))
    end
    Add(table.concat(parts))
    Block('TRIS')
    local indexOffset = len
    parts, chunk, chunkN = {}, {}, 0
    local idx = m.idx
    for i = 1, ni do
        chunkN = chunkN + 1
        chunk[chunkN] = PackU16(idx[i] - 1)
        if chunkN == 1024 then
            table.insert(parts, table.concat(chunk))
            chunk, chunkN = {}, 0
        end
    end
    if chunkN > 0 then
        for i = chunkN + 1, table.getn(chunk) do chunk[i] = nil end
        table.insert(parts, table.concat(chunk))
    end
    Add(table.concat(parts))
    Block('INFO')
    local infoOffset = len
    local text = ''
    for _, s in (info or { 'Terrain mesh patch' }) do text = text .. s .. '\0' end
    Add(text)
    out[1] = 'MODL' .. PackU32(5) .. PackU32(boneOffset) .. PackU32(skinned) .. PackU32(vertexOffset) .. PackU32(0) .. PackU32(n) ..
        PackU32(indexOffset) .. PackU32(ni) .. PackU32(infoOffset) .. PackU32(string.len(text)) .. PackU32(bones and table.getn(bones) or 1)
    local x0, y0, z0, x1, y1, z1 = Bounds(m)
    return table.concat(out), { x0 or 0, y0 or 0, z0 or 0, x1 or 0, y1 or 0, z1 or 0 }
end

-- ---- splitting -------------------------------------------------------------------------------------------------------------------------------

--- Port of scm.split: a mesh of at most `limit` vertices is passed through (as a one element list); a larger one is cut by map tile (`tile` units,
--- sorted by tile row, tile column, then vertex numbers) so that each patch stays in one area. Triangles are never cut; a vertex shared by two
--- patches is copied. -> list of meshes.
function Split(m, limit, tile)
    limit = limit or LIMIT
    tile = tile or 256
    if m.n <= limit then return { m } end
    local pos, idx = m.pos, m.idx
    local tris = {}
    local nt = table.getn(idx) / 3
    for t = 0, nt - 1 do
        local a, b, c = idx[t * 3 + 1], idx[t * 3 + 2], idx[t * 3 + 3]
        local cx = (pos[(a - 1) * 3 + 1] + pos[(b - 1) * 3 + 1] + pos[(c - 1) * 3 + 1]) / 3
        local cz = (pos[(a - 1) * 3 + 3] + pos[(b - 1) * 3 + 3] + pos[(c - 1) * 3 + 3]) / 3
        tris[t + 1] = { floor(cz / tile), floor(cx / tile), a, b, c }
    end
    table.sort(tris, function(p, q)
        if p[1] ~= q[1] then return p[1] < q[1] end
        if p[2] ~= q[2] then return p[2] < q[2] end
        if p[3] ~= q[3] then return p[3] < q[3] end
        if p[4] ~= q[4] then return p[4] < q[4] end
        return p[5] < q[5]
    end)
    local list = {}
    local remap, cur
    local function Start()
        remap, cur = {}, New()
    end
    local function Flush()
        if table.getn(cur.idx) > 0 then table.insert(list, cur) end
    end
    Start()
    for _, tr in tris do
        local new = 0
        for k = 3, 5 do
            if not remap[tr[k]] then new = new + 1 end
        end
        -- like the Python original: every slot that is not yet in the patch counts, a repeated index inside one triangle included
        if cur.n + new > limit then
            Flush()
            Start()
        end
        for k = 3, 5 do
            local v = tr[k]
            local r = remap[v]
            if not r then
                cur.n = cur.n + 1
                r = cur.n
                remap[v] = r
                local a3, a2, b3, b2 = (v - 1) * 3, (v - 1) * 2, (r - 1) * 3, (r - 1) * 2
                for j = 1, 3 do
                    cur.pos[b3 + j] = m.pos[a3 + j]
                    cur.nrm[b3 + j] = m.nrm[a3 + j]
                    cur.tan[b3 + j] = m.tan[a3 + j]
                    cur.bin[b3 + j] = m.bin[a3 + j]
                end
                for j = 1, 2 do
                    cur.uv1[b2 + j] = m.uv1[a2 + j]
                    cur.uv2[b2 + j] = m.uv2[a2 + j]
                end
            end
            table.insert(cur.idx, r)
        end
    end
    Flush()
    return list
end

-- ---- file level readers for the validators ---------------------------------------------------------------------------------------------------------

--- The bones of an SCM file: list of { name, parent (0-based, -1 root) } | nil + reason. Only the bone table is read.
function Bones(data)
    local h, why = Header(data)
    if not h then return nil, why end
    local boneAt, total = U32(data, 9), U32(data, 45)
    if not boneAt or not total or total > 4096 then return nil, 'bone table out of range' end
    if boneAt + total * 108 > string.len(data) then return nil, 'bone table runs past the end of the file' end
    local list = {}
    for i = 0, total - 1 do
        local o = boneAt + i * 108
        local nameAt, parent = U32(data, o + 93), U32(data, o + 97)
        local e = string.find(data, '\0', nameAt + 1, true)
        if not e then return nil, 'bone ' .. i .. ' has no name' end
        list[i + 1] = { name = ssub(data, nameAt + 1, e - 1), parent = (parent == 4294967295) and -1 or parent }
    end
    return list
end

--- Bounding box of the vertex positions of an SCM file: x0, y0, z0, x1, y1, z1 | nil + reason, and the vertex count. Reads positions only.
function FileBounds(data)
    local h, why = Header(data)
    if not h then return nil, why end
    if h.vertexCount == 0 then return nil, 'no vertices' end
    local p = h.vertexAt + 1
    local x0, y0, z0 = F32(data, p), F32(data, p + 4), F32(data, p + 8)
    local x1, y1, z1 = x0, y0, z0
    for k = 1, h.vertexCount - 1 do
        p = p + 68
        local x, y, z = F32(data, p), F32(data, p + 4), F32(data, p + 8)
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
        if z < z0 then z0 = z elseif z > z1 then z1 = z end
    end
    return x0, y0, z0, x1, y1, z1, h.vertexCount
end
