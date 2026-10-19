-- Mesh import for mesh terrain maps: an OBJ file becomes SCM v5 patches and manifest entries (docs/projects/editor/MESH_IMPORT.md).
--
--   ParseObj(text)                 -> obj { v, vt, vn (flat arrays), groups = { { name, c = corners (v, vt, vn per corner, 3 corners per triangle), nc } }, warnings }
--   Build(obj [, opts])            -> result { groups = { { name, mesh, source, kept, dropped, patches = { scm mesh, ... } } }, stats, warnings }
--   Commit(model, result, folder [, copts])
--                                  writes <folder>/terrain/sectionGG_NNN.scm, adds the materials and patch entries to the manifest model -> list of file names
--   Run(text, opts)                = ParseObj + Build;  Describe(result) -> text lines for the dialog
--
-- Options (Defaults): scale (OBJ unit -> world unit), axis ('y_up' | 'z_up': Blender's default), mirrorX / mirrorZ, flipWinding, flipV (OBJ's v runs up, DDS
-- textures run down), offsetX / Y / Z, normals ('auto' = the file's when it has them | 'smooth' | 'flat'), uvTile (world units per texture repeat when the
-- OBJ has no UVs), uv2 ('planar' = x, z over the map | 'copy'), mapSize, groupBy ('material' | 'object' | 'none'), limit (vertices per patch), tile (split
-- tile size in world units), minArea (triangles below this area are dropped).
--
-- Conventions, taken from a converted SC2 patch (sc2_mp_002/section01_000.scm, 398 of 398 sampled triangles): triangles run counter clockwise seen
-- from the side the normal points to (cross(b - a, c - a) . n > 0), the tangent follows +u (dP/du), the binormal is cross(normal, tangent).
--
-- Lua 5.0 dialect.

local Scm = import('/lua/editor/scm.lua')

Defaults = {
    scale = 1, axis = 'y_up', mirrorX = false, mirrorZ = false, flipWinding = false, flipV = true,
    offsetX = 0, offsetY = 0, offsetZ = 0,
    normals = 'auto', uvTile = 64, uv2 = 'planar', mapSize = 1024, groupBy = 'material',
    limit = 65535, tile = 256, minArea = 1e-6,
}

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

local function Merge(opts)
    local o = {}
    for k, v in Defaults do o[k] = v end
    if opts then
        for k, v in opts do o[k] = v end
    end
    return o
end

-- ---- reading the OBJ -------------------------------------------------------------------------------------------------------------------------

local function Trim(s)
    s = string.gsub(s, '^%s+', '')
    return (string.gsub(s, '%s+$', ''))
end

function ParseObj(text, groupBy)
    groupBy = groupBy or 'material'
    local obj = { v = {}, vt = {}, vn = {}, nv = 0, nvt = 0, nvn = 0, groups = {}, warnings = {}, faces = 0, badFaces = 0 }
    local byName = {}
    local current
    local function Group(name)
        local g = byName[name]
        if not g then
            g = { name = name, c = {}, nc = 0 }
            byName[name] = g
            table.insert(obj.groups, g)
        end
        current = g
    end
    local material, object = 'default', 'default'
    local function Select()
        if groupBy == 'material' then Group(material)
        elseif groupBy == 'object' then Group(object)
        else Group('mesh') end
    end
    Select()
    local v, vt, vn = obj.v, obj.vt, obj.vn
    text = string.gsub(text, '\r', '')
    for line in string.gfind(text .. '\n', '([^\n]*)\n') do
        local c1 = string.byte(line, 1)
        if c1 == 118 then                                  -- v
            local c2 = string.byte(line, 2)
            if c2 == 32 or c2 == 9 then
                local s, e, x, y, z = string.find(line, '^v%s+(%S+)%s+(%S+)%s+(%S+)')
                if s then
                    local n = obj.nv * 3
                    v[n + 1], v[n + 2], v[n + 3] = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
                    obj.nv = obj.nv + 1
                end
            elseif c2 == 116 then                          -- vt
                local s, e, u, w = string.find(line, '^vt%s+(%S+)%s+(%S+)')
                if s then
                    local n = obj.nvt * 2
                    vt[n + 1], vt[n + 2] = tonumber(u) or 0, tonumber(w) or 0
                    obj.nvt = obj.nvt + 1
                end
            elseif c2 == 110 then                          -- vn
                local s, e, x, y, z = string.find(line, '^vn%s+(%S+)%s+(%S+)%s+(%S+)')
                if s then
                    local n = obj.nvn * 3
                    vn[n + 1], vn[n + 2], vn[n + 3] = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
                    obj.nvn = obj.nvn + 1
                end
            end
        elseif c1 == 102 then                              -- f
            local refs = {}
            local ok = true
            for tok in string.gfind(string.sub(line, 2), '%S+') do
                local s, e, a, b, c = string.find(tok, '^(-?%d+)/?(-?%d*)/?(-?%d*)$')
                if not s then ok = false break end
                local vi, ti, ni = tonumber(a), tonumber(b) or 0, tonumber(c) or 0
                if vi < 0 then vi = obj.nv + vi + 1 end
                if ti < 0 then ti = obj.nvt + ti + 1 end
                if ni < 0 then ni = obj.nvn + ni + 1 end
                if vi < 1 or vi > obj.nv or ti > obj.nvt or ni > obj.nvn then ok = false break end
                table.insert(refs, { vi, ti, ni })
            end
            local nr = table.getn(refs)
            if ok and nr >= 3 then
                obj.faces = obj.faces + 1
                local g = current
                for k = 2, nr - 1 do
                    for _, r in { refs[1], refs[k], refs[k + 1] } do
                        local n = g.nc * 3
                        g.c[n + 1], g.c[n + 2], g.c[n + 3] = r[1], r[2], r[3]
                        g.nc = g.nc + 1
                    end
                end
            else
                obj.badFaces = obj.badFaces + 1
            end
        elseif c1 == 117 then                              -- usemtl
            local s, e, name = string.find(line, '^usemtl%s+(.*)$')
            if s then
                material = Trim(name)
                if material == '' then material = 'default' end
                Select()
            end
        elseif c1 == 111 or c1 == 103 then                 -- o, g
            local s, e, name = string.find(line, '^[og]%s+(.*)$')
            if s then
                object = Trim(name)
                if object == '' then object = 'default' end
                Select()
            end
        end
    end
    -- groups without faces (a material named but never used) are dropped
    local kept = {}
    for _, g in obj.groups do
        if g.nc > 0 then table.insert(kept, g) end
    end
    obj.groups = kept
    if obj.badFaces > 0 then table.insert(obj.warnings, obj.badFaces .. ' faces with unreadable or out of range references were skipped') end
    return obj
end

-- ---- building meshes -------------------------------------------------------------------------------------------------------------------------

local function Normalize(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-12 then return 0, 0, 0, 0 end
    return x / l, y / l, z / l, l
end

local function Round(x)
    return floor(x * 100 + 0.5)
end

--- One group (one material) -> one mesh. `P`, `N`, `UV` are the transformed positions, normals and uvs of the whole OBJ.
local function BuildGroup(obj, g, o, P, N, UV, flipTris)
    local c = g.c
    local nt = g.nc / 3
    -- pass 1: triangles that stay (in output winding)
    local keep = {}
    local nk, dropped = 0, 0
    local minArea2 = 4 * o.minArea * o.minArea
    for t = 0, nt - 1 do
        local base = t * 9
        local va, vb, vc = c[base + 1], c[base + 4], c[base + 7]
        local ok = true
        if va == vb or vb == vc or va == vc then
            ok = false
        else
            local a, b, d = (va - 1) * 3, (vb - 1) * 3, (vc - 1) * 3
            local e1x, e1y, e1z = P[b + 1] - P[a + 1], P[b + 2] - P[a + 2], P[b + 3] - P[a + 3]
            local e2x, e2y, e2z = P[d + 1] - P[a + 1], P[d + 2] - P[a + 2], P[d + 3] - P[a + 3]
            local cx, cy, cz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
            local l2 = cx * cx + cy * cy + cz * cz
            if not (l2 > minArea2) or l2 ~= l2 then ok = false end
        end
        if ok then
            nk = nk + 1
            keep[nk] = base
        else
            dropped = dropped + 1
        end
    end
    local mesh = Scm.New()
    if nk == 0 then return nil, dropped end

    -- pass 2: vertices, welded by (position, uv, normal) reference
    local useFileNormals = (o.normals == 'auto') and obj.nvn > 0
    local flat = o.normals == 'flat'
    local map = {}
    local src = {}                         -- new vertex -> { vi, ti, ni }
    local pos, nrm, uv1 = mesh.pos, mesh.nrm, mesh.uv1
    local idx = mesh.idx
    local nvert = 0
    local function Vertex(vi, ti, ni, tri)
        local key
        if flat then key = tri .. ':' .. vi
        elseif ti == 0 and ni == 0 then key = vi
        else key = vi .. '/' .. ti .. '/' .. ni end
        local r = map[key]
        if r then return r end
        nvert = nvert + 1
        r = nvert
        map[key] = r
        src[r] = { vi, ti, ni }
        local b3, b2 = (r - 1) * 3, (r - 1) * 2
        pos[b3 + 1], pos[b3 + 2], pos[b3 + 3] = P[(vi - 1) * 3 + 1], P[(vi - 1) * 3 + 2], P[(vi - 1) * 3 + 3]
        if ti > 0 then
            uv1[b2 + 1], uv1[b2 + 2] = UV[(ti - 1) * 2 + 1], UV[(ti - 1) * 2 + 2]
        else
            uv1[b2 + 1], uv1[b2 + 2] = pos[b3 + 1] / o.uvTile, pos[b3 + 3] / o.uvTile
        end
        return r
    end
    local nIdx = 0
    for k = 1, nk do
        local base = keep[k]
        local a = Vertex(c[base + 1], c[base + 2], c[base + 3], k)
        local b = Vertex(c[base + 4], c[base + 5], c[base + 6], k)
        local d = Vertex(c[base + 7], c[base + 8], c[base + 9], k)
        if flipTris then b, d = d, b end
        idx[nIdx + 1], idx[nIdx + 2], idx[nIdx + 3] = a, b, d
        nIdx = nIdx + 3
    end
    mesh.n = nvert

    -- normals: the file's, or area weighted over vertices at the same place, or the face's own
    local acc = {}                         -- weld id -> x, y, z sums
    local weld = {}                        -- vertex -> weld id
    local welds = {}
    local nw = 0
    local fnorm = {}                       -- flat: per triangle
    local allHave = useFileNormals
    if useFileNormals then
        for k = 1, nk do
            local base = keep[k]
            if c[base + 3] == 0 or c[base + 6] == 0 or c[base + 9] == 0 then allHave = false break end
        end
    end
    local needSmooth = not flat and not allHave
    for k = 1, nk do
        local a, b, d = (idx[(k - 1) * 3 + 1] - 1) * 3, (idx[(k - 1) * 3 + 2] - 1) * 3, (idx[(k - 1) * 3 + 3] - 1) * 3
        local e1x, e1y, e1z = pos[b + 1] - pos[a + 1], pos[b + 2] - pos[a + 2], pos[b + 3] - pos[a + 3]
        local e2x, e2y, e2z = pos[d + 1] - pos[a + 1], pos[d + 2] - pos[a + 2], pos[d + 3] - pos[a + 3]
        local cx, cy, cz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
        if needSmooth then
            for j = 0, 2 do
                local v = idx[(k - 1) * 3 + 1 + j]
                local w = weld[v]
                if not w then
                    local key = Round(pos[(v - 1) * 3 + 1]) .. ',' .. Round(pos[(v - 1) * 3 + 2]) .. ',' .. Round(pos[(v - 1) * 3 + 3])
                    w = welds[key]
                    if not w then
                        nw = nw + 1
                        w = nw
                        welds[key] = w
                        acc[w * 3 - 2], acc[w * 3 - 1], acc[w * 3] = 0, 0, 0
                    end
                    weld[v] = w
                end
                acc[w * 3 - 2], acc[w * 3 - 1], acc[w * 3] = acc[w * 3 - 2] + cx, acc[w * 3 - 1] + cy, acc[w * 3] + cz
            end
        elseif flat then
            fnorm[k] = { cx, cy, cz }
        end
    end
    local filled, generated = 0, 0
    for v = 1, nvert do
        local b3 = (v - 1) * 3
        local x, y, z
        if useFileNormals and src[v][3] > 0 then
            local ni = src[v][3]
            x, y, z = N[(ni - 1) * 3 + 1], N[(ni - 1) * 3 + 2], N[(ni - 1) * 3 + 3]
            x, y, z = Normalize(x, y, z)
            filled = filled + 1
        elseif flat then
            -- set below from the triangle
        else
            if not weld[v] then
                local key = Round(pos[b3 + 1]) .. ',' .. Round(pos[b3 + 2]) .. ',' .. Round(pos[b3 + 3])
                weld[v] = welds[key]
            end
            local w = weld[v]
            if w then x, y, z = Normalize(acc[w * 3 - 2], acc[w * 3 - 1], acc[w * 3]) end
            generated = generated + 1
        end
        nrm[b3 + 1], nrm[b3 + 2], nrm[b3 + 3] = x or 0, y or 1, z or 0
        if (x or 0) == 0 and (y or 0) == 0 and (z or 0) == 0 then nrm[b3 + 2] = 1 end
    end
    if flat then
        for k = 1, nk do
            local fx, fy, fz = Normalize(fnorm[k][1], fnorm[k][2], fnorm[k][3])
            if fx == 0 and fy == 0 and fz == 0 then fy = 1 end
            for j = 0, 2 do
                local b3 = (idx[(k - 1) * 3 + 1 + j] - 1) * 3
                nrm[b3 + 1], nrm[b3 + 2], nrm[b3 + 3] = fx, fy, fz
            end
        end
    end

    -- uv2: the light mask coordinate
    local uv2 = mesh.uv2
    for v = 1, nvert do
        local b3, b2 = (v - 1) * 3, (v - 1) * 2
        local u, w
        if o.uv2 == 'copy' then
            u, w = uv1[b2 + 1], uv1[b2 + 2]
        else
            u, w = pos[b3 + 1] / o.mapSize, pos[b3 + 3] / o.mapSize
        end
        uv2[b2 + 1] = math.max(0, math.min(1, u))
        uv2[b2 + 2] = math.max(0, math.min(1, w))
    end

    -- tangents: dP/du of every triangle added to its vertices, made perpendicular to the normal; binormal = normal x tangent
    local tan, bin = mesh.tan, mesh.bin
    local ts = {}
    for i = 1, nvert * 3 do ts[i] = 0 end
    for k = 1, nk do
        local ia, ib, ic = idx[(k - 1) * 3 + 1], idx[(k - 1) * 3 + 2], idx[(k - 1) * 3 + 3]
        local a, b, d = (ia - 1) * 3, (ib - 1) * 3, (ic - 1) * 3
        local a2, b2, d2 = (ia - 1) * 2, (ib - 1) * 2, (ic - 1) * 2
        local du1, du2 = uv1[b2 + 1] - uv1[a2 + 1], uv1[d2 + 1] - uv1[a2 + 1]
        local dv1, dv2 = uv1[b2 + 2] - uv1[a2 + 2], uv1[d2 + 2] - uv1[a2 + 2]
        local det = du1 * dv2 - du2 * dv1
        if abs(det) > 1e-12 then
            local r = 1 / det
            local tx = (( pos[b + 1] - pos[a + 1]) * dv2 - (pos[d + 1] - pos[a + 1]) * dv1) * r
            local ty = (( pos[b + 2] - pos[a + 2]) * dv2 - (pos[d + 2] - pos[a + 2]) * dv1) * r
            local tz = (( pos[b + 3] - pos[a + 3]) * dv2 - (pos[d + 3] - pos[a + 3]) * dv1) * r
            local tl = sqrt(tx * tx + ty * ty + tz * tz)
            if tl > 1e-12 then
                tx, ty, tz = tx / tl, ty / tl, tz / tl
                for _, vb in { a, b, d } do
                    ts[vb + 1], ts[vb + 2], ts[vb + 3] = ts[vb + 1] + tx, ts[vb + 2] + ty, ts[vb + 3] + tz
                end
            end
        end
    end
    local noTangent = 0
    for v = 1, nvert do
        local b3 = (v - 1) * 3
        local nx, ny, nz = nrm[b3 + 1], nrm[b3 + 2], nrm[b3 + 3]
        local tx, ty, tz = ts[b3 + 1], ts[b3 + 2], ts[b3 + 3]
        local d = tx * nx + ty * ny + tz * nz
        tx, ty, tz = tx - nx * d, ty - ny * d, tz - nz * d
        local l
        tx, ty, tz, l = Normalize(tx, ty, tz)
        if l < 1e-6 then
            -- no usable uv: any direction across the normal
            noTangent = noTangent + 1
            local rx, ry, rz = 1, 0, 0
            if abs(nx) > 0.9 then rx, ry, rz = 0, 0, 1 end
            tx, ty, tz = Normalize(ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx)
        end
        tan[b3 + 1], tan[b3 + 2], tan[b3 + 3] = tx, ty, tz
        bin[b3 + 1], bin[b3 + 2], bin[b3 + 3] = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
    end
    return mesh, dropped, { fileNormals = filled, computedNormals = generated, noTangent = noTangent }
end

function Build(obj, opts)
    local o = Merge(opts)
    local result = { groups = {}, warnings = {}, options = o, stats = { vertices = 0, triangles = 0, dropped = 0, patches = 0, sourceTriangles = 0 } }
    for _, w in obj.warnings do table.insert(result.warnings, w) end
    if obj.nv == 0 or table.getn(obj.groups) == 0 then
        table.insert(result.warnings, 'the file has no faces')
        return result
    end
    -- transform everything once
    local zup = o.axis == 'z_up'
    local sx, sz = o.mirrorX and -1 or 1, o.mirrorZ and -1 or 1
    local flip = o.flipWinding
    if o.mirrorX then flip = not flip end
    if o.mirrorZ then flip = not flip end
    local P, N, UV = {}, {}, {}
    for i = 0, obj.nv - 1 do
        local x, y, z = obj.v[i * 3 + 1], obj.v[i * 3 + 2], obj.v[i * 3 + 3]
        if zup then y, z = z, -y end
        P[i * 3 + 1], P[i * 3 + 2], P[i * 3 + 3] = x * sx * o.scale + o.offsetX, y * o.scale + o.offsetY, z * sz * o.scale + o.offsetZ
    end
    for i = 0, obj.nvn - 1 do
        local x, y, z = obj.vn[i * 3 + 1], obj.vn[i * 3 + 2], obj.vn[i * 3 + 3]
        if zup then y, z = z, -y end
        N[i * 3 + 1], N[i * 3 + 2], N[i * 3 + 3] = x * sx, y, z * sz
    end
    for i = 0, obj.nvt - 1 do
        local u, w = obj.vt[i * 2 + 1], obj.vt[i * 2 + 2]
        UV[i * 2 + 1], UV[i * 2 + 2] = u, o.flipV and (1 - w) or w
    end
    if obj.nvt == 0 then table.insert(result.warnings, 'no texture coordinates in the file: planar uv over x, z (' .. o.uvTile .. ' units per repeat)') end
    local noNormals = 0
    for gi, g in obj.groups do
        result.stats.sourceTriangles = result.stats.sourceTriangles + g.nc / 3
        local mesh, dropped, info = BuildGroup(obj, g, o, P, N, UV, flip)
        result.stats.dropped = result.stats.dropped + dropped
        if mesh then
            local patches = Scm.Split(mesh, o.limit, o.tile)
            local tris = table.getn(mesh.idx) / 3
            table.insert(result.groups, { name = g.name, mesh = mesh, kept = tris, dropped = dropped, patches = patches, info = info })
            result.stats.vertices = result.stats.vertices + mesh.n
            result.stats.triangles = result.stats.triangles + tris
            result.stats.patches = result.stats.patches + table.getn(patches)
            if info.noTangent > 0 then
                table.insert(result.warnings, "'" .. g.name .. "': " .. info.noTangent .. ' vertices without usable uv got an arbitrary tangent')
            end
        else
            table.insert(result.warnings, "'" .. g.name .. "': no triangle left after dropping " .. dropped .. ' degenerate ones')
        end
    end
    if result.stats.dropped > 0 then
        table.insert(result.warnings, result.stats.dropped .. ' degenerate triangles dropped (repeated vertex or area below ' .. o.minArea .. ')')
    end
    return result
end

function Run(text, opts)
    local o = Merge(opts)
    return Build(ParseObj(text, o.groupBy), o)
end

--- Lines for the dialog.
function Describe(result)
    local st = result.stats
    local lines = {
        string.format('%d triangles in, %d kept, %d vertices, %d patches', st.sourceTriangles, st.triangles, st.vertices, st.patches),
    }
    for gi, g in result.groups do
        local counts = {}
        for _, p in g.patches do table.insert(counts, tostring(p.n)) end
        table.insert(lines, string.format("  %d. '%s': %d triangles, patches of %s vertices", gi, g.name, g.kept, table.concat(counts, ', ')))
    end
    for _, w in result.warnings do table.insert(lines, 'note: ' .. w) end
    return lines
end

-- ---- writing into the map --------------------------------------------------------------------------------------------------------------------

local function FieldIndex(mat, key)
    for i, f in mat do
        if f[1] == key then return i end
    end
end

--- The name of a material entry.
function MaterialName(mat)
    local i = FieldIndex(mat, 'name')
    return i and mat[i][2] or ''
end

--- Index of the material called `name` in the manifest model, or nil.
function FindMaterial(model, name)
    for i, mat in model.materials do
        if MaterialName(mat) == name then return i end
    end
end

--- Appends a material with only its name (the textures are assigned afterwards); -> index.
function AddMaterial(model, name)
    table.insert(model.materials, { { 'name', name } })
    return table.getn(model.materials)
end

local function FreeName(section, serial)
    return string.format('section%02d_%03d.scm', section, serial)
end

--- Writes the patches of `result` into <folder>/terrain/ and adds them (and their materials) to the manifest model.
--- copts: replace (drop the model's non-sky patch entries first; the old files stay on disk), materials = { [group number] = material index } to reuse
--- materials, updateHeights (default true: mesh_high is recomputed from all patch files). -> list of file names, or nil + reason.
function Commit(model, result, folder, copts)
    copts = copts or {}
    if not folder then return nil, 'the map has no folder yet (save it first)' end
    local tdir = folder .. '/terrain'
    if copts.replace then
        local keep = {}
        for _, p in model.patches do
            if p.comment or (p.sky and p.sky ~= 0) then table.insert(keep, p) end
        end
        model.patches = keep
    end
    local taken = {}
    for _, p in model.patches do
        if p.mesh then taken[string.lower(p.mesh)] = true end
    end
    -- section numbers continue after the highest one in use
    local section = 0
    for name, _ in taken do
        local s, e, n = string.find(name, '^section(%d+)_')
        if s and tonumber(n) >= section then section = tonumber(n) + 1 end
    end
    -- new entries go before the first sky patch (sky patches are drawn last, in manifest order)
    local at = table.getn(model.patches) + 1
    for i, p in model.patches do
        if p.sky and p.sky ~= 0 then at = i break end
    end
    local written = {}
    for gi, grp in result.groups do
        local mi = copts.materials and copts.materials[gi]
        if not mi or not model.materials[mi] then
            mi = FindMaterial(model, grp.name) or AddMaterial(model, grp.name)
        end
        for pi, mesh in grp.patches do
            local file = FreeName(section, pi - 1)
            local base = string.sub(file, 1, -5)
            local data, bb = Scm.Write(mesh, base, { 'Terrain mesh patch' })
            if not data then return nil, bb end
            if not ed_write_file(tdir .. '/' .. file, data) then return nil, 'cannot write ' .. tdir .. '/' .. file end
            table.insert(model.patches, at, {
                mesh = file, material = mi, vertices = mesh.n, triangles = table.getn(mesh.idx) / 3,
                min = { bb[1], bb[2], bb[3] }, max = { bb[4], bb[5], bb[6] },
            })
            at = at + 1
            table.insert(written, file)
        end
        section = section + 1
    end
    if copts.updateHeights ~= false then
        local high = import('/lua/editor/meshscan.lua').MeshHigh(model, folder)
        if high then model.settings.mesh_high = high end
    end
    return written
end
