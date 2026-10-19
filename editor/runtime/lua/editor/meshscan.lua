-- The checks of a mesh terrain map that need the vertices of the patches (docs/projects/editor_research/MESH_MAP_EDITOR_NEEDS.md section 3):
--   V3   normals / tangents / binormals unit length, tangent frame orthogonal, no NaN or infinity, no degenerate triangles
--   V4   UV2 (light mask coordinate, clamp addressing) inside 0..1 for materials with light masks
--   V10  the mesh covers the playable rectangle (vertical ray samples; the rectangle is cut into at most ~160 x 160 samples)
--   V15  mesh_high: the highest vertex in the playable rectangle plus a 32 unit margin on the sides (manifest_heights.py)
-- Patches are read one at a time (scm.lua), so a 20 patch map needs the memory of one patch.
--
--   Scan(model, folder [, opts]) -> { findings = { { sev, code, text } }, patches = { [entryIndex] = stats }, meshHigh = number | nil, coverage = percent | nil }
--   MeshHigh(model, folder)      -> highest vertex only (what the importer writes into the manifest)
--   opts.coverage = false skips V10 (the slowest part); opts.cells = samples along the longer side (default 160)
--
-- Lua 5.0 dialect.

local Scm = import('/lua/editor/scm.lua')

MARGIN = 32

local abs, sqrt, floor, ceil, max, min = math.abs, math.sqrt, math.floor, math.ceil, math.max, math.min

local function Finite(v)
    return v == v and v > -1e30 and v < 1e30
end

--- The playable rectangle of a model (settings, default the whole map).
function Playable(model)
    local s = model.settings
    local size = s.size or 1024
    return s.playable_x0 or 0, s.playable_z0 or 0, s.playable_x1 or size, s.playable_z1 or size
end

--- Per patch numbers: counts of vertices that break V3 / V4, with the first example.
function PatchStats(mesh, wantUv2)
    local st = { n = mesh.n, tris = table.getn(mesh.idx) / 3, nan = 0, normal = 0, tangent = 0, ortho = 0, degenerate = 0, uv2 = 0, firstNormal = nil, firstOrtho = nil, firstNan = nil, firstUv2 = nil }
    local pos, nrm, tan, bin, uv2 = mesh.pos, mesh.nrm, mesh.tan, mesh.bin, mesh.uv2
    for k = 1, mesh.n do
        local a, b = (k - 1) * 3, (k - 1) * 2
        local bad = false
        for j = 1, 3 do
            if not (Finite(pos[a + j]) and Finite(nrm[a + j]) and Finite(tan[a + j]) and Finite(bin[a + j])) then bad = true end
        end
        if not (Finite(mesh.uv1[b + 1]) and Finite(mesh.uv1[b + 2]) and Finite(uv2[b + 1]) and Finite(uv2[b + 2])) then bad = true end
        if bad then
            st.nan = st.nan + 1
            st.firstNan = st.firstNan or k
        else
            local nx, ny, nz = nrm[a + 1], nrm[a + 2], nrm[a + 3]
            local tx, ty, tz = tan[a + 1], tan[a + 2], tan[a + 3]
            local bx, by, bz = bin[a + 1], bin[a + 2], bin[a + 3]
            if abs(sqrt(nx * nx + ny * ny + nz * nz) - 1) > 0.05 then
                st.normal = st.normal + 1
                st.firstNormal = st.firstNormal or k
            end
            if abs(sqrt(tx * tx + ty * ty + tz * tz) - 1) > 0.05 or abs(sqrt(bx * bx + by * by + bz * bz) - 1) > 0.05 then
                st.tangent = st.tangent + 1
                st.firstTangent = st.firstTangent or k
            end
            -- SC2 packed 10-bit frames are off by up to about 0.3 (sc2_mp_002), a tangent along the normal gives 1
            if abs(tx * nx + ty * ny + tz * nz) > 0.5 or abs(bx * nx + by * ny + bz * nz) > 0.5 then
                st.ortho = st.ortho + 1
                st.firstOrtho = st.firstOrtho or k
            end
            if wantUv2 then
                local u, v = uv2[b + 1], uv2[b + 2]
                if u < -0.001 or u > 1.001 or v < -0.001 or v > 1.001 then
                    st.uv2 = st.uv2 + 1
                    st.firstUv2 = st.firstUv2 or k
                end
            end
        end
    end
    local idx = mesh.idx
    for t = 0, st.tris - 1 do
        local a, b, c = idx[t * 3 + 1], idx[t * 3 + 2], idx[t * 3 + 3]
        if a == b or b == c or a == c then
            st.degenerate = st.degenerate + 1
        else
            local a3, b3, c3 = (a - 1) * 3, (b - 1) * 3, (c - 1) * 3
            local e1x, e1y, e1z = pos[b3 + 1] - pos[a3 + 1], pos[b3 + 2] - pos[a3 + 2], pos[b3 + 3] - pos[a3 + 3]
            local e2x, e2y, e2z = pos[c3 + 1] - pos[a3 + 1], pos[c3 + 2] - pos[a3 + 2], pos[c3 + 3] - pos[a3 + 3]
            local cx, cy, cz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
            if cx * cx + cy * cy + cz * cz < 1e-10 then st.degenerate = st.degenerate + 1 end
        end
    end
    return st
end

--- Highest vertex whose x, z lie in the rectangle (grown by `margin`), or nil.
function HighestIn(mesh, x0, z0, x1, z1)
    local pos = mesh.pos
    local high
    for i = 1, mesh.n * 3, 3 do
        local x, z = pos[i], pos[i + 2]
        if x >= x0 and x <= x1 and z >= z0 and z <= z1 then
            local y = pos[i + 1]
            if not high or y > high then high = y end
        end
    end
    return high
end

--- The grid for the coverage samples: rectangle, cell size, counts.
local function Grid(x0, z0, x1, z1, cells)
    local w, h = x1 - x0, z1 - z0
    local cell = max(1, max(w, h) / cells)
    return { x0 = x0, z0 = z0, cell = cell, nx = max(1, ceil(w / cell)), nz = max(1, ceil(h / cell)), hit = {}, count = 0 }
end

--- Marks the samples that lie under a triangle of the mesh (looking straight down).
local function Cover(grid, mesh)
    local pos, idx = mesh.pos, mesh.idx
    local x0, z0, cell, nx, nz, hit = grid.x0, grid.z0, grid.cell, grid.nx, grid.nz, grid.hit
    local count = grid.count
    for t = 0, table.getn(idx) / 3 - 1 do
        local a, b, c = (idx[t * 3 + 1] - 1) * 3, (idx[t * 3 + 2] - 1) * 3, (idx[t * 3 + 3] - 1) * 3
        local ax, az, bx, bz, cx, cz = pos[a + 1], pos[a + 3], pos[b + 1], pos[b + 3], pos[c + 1], pos[c + 3]
        local denom = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(denom) > 1e-9 then
            local i0 = max(0, ceil((min(ax, bx, cx) - x0) / cell - 0.5))
            local i1 = min(nx - 1, floor((max(ax, bx, cx) - x0) / cell - 0.5))
            local j0 = max(0, ceil((min(az, bz, cz) - z0) / cell - 0.5))
            local j1 = min(nz - 1, floor((max(az, bz, cz) - z0) / cell - 0.5))
            for j = j0, j1 do
                local pz = z0 + (j + 0.5) * cell
                for i = i0, i1 do
                    local key = j * nx + i + 1
                    if not hit[key] then
                        local px = x0 + (i + 0.5) * cell
                        local l1 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / denom
                        local l2 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / denom
                        if l1 >= -1e-5 and l2 >= -1e-5 and 1 - l1 - l2 >= -1e-5 then
                            hit[key] = true
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    grid.count = count
end

local function ReadPatch(folder, entry)
    local data = ed_read_file(folder .. '/terrain/' .. entry.mesh)
    if not data then return nil, 'file not found' end
    return Scm.Read(data)
end

local function HasLightMask(model, materialIndex)
    local mat = model.materials[materialIndex]
    if not mat then return false end
    for _, f in mat do
        if string.find(f[1], '^light_mask_') then return true end
    end
    return false
end

--- Runs the vertex based checks. `folder`: the map folder on disk.
function Scan(model, folder, opts)
    opts = opts or {}
    local res = { findings = {}, patches = {}, meshHigh = nil, coverage = nil }
    local function Add(sev, code, text) table.insert(res.findings, { sev = sev, code = code, text = text }) end
    local px0, pz0, px1, pz1 = Playable(model)
    local grid = (opts.coverage ~= false) and Grid(px0, pz0, px1, pz1, opts.cells or 160) or nil
    local totals = { nan = 0, normal = 0, tangent = 0, ortho = 0, degenerate = 0, uv2 = 0 }
    local examples = {}
    local scanned = 0
    for i, p in model.patches do
        if not p.comment and p.mesh then
            local mesh, why = ReadPatch(folder, p)
            if not mesh then
                Add('E', 'V1', p.mesh .. ': ' .. tostring(why))
            else
                scanned = scanned + 1
                local st = PatchStats(mesh, HasLightMask(model, p.material))
                res.patches[i] = st
                for k, _ in totals do
                    if st[k] > 0 then
                        totals[k] = totals[k] + st[k]
                        examples[k] = examples[k] or (p.mesh .. ' vertex ' .. (st['first' .. string.upper(string.sub(k, 1, 1)) .. string.sub(k, 2)] or '?'))
                    end
                end
                if not (p.sky and p.sky ~= 0) then
                    local hi = HighestIn(mesh, px0 - MARGIN, pz0 - MARGIN, px1 + MARGIN, pz1 + MARGIN)
                    if hi and (not res.meshHigh or hi > res.meshHigh) then res.meshHigh = hi end
                    if grid then Cover(grid, mesh) end
                end
            end
        end
    end
    if totals.nan > 0 then Add('W', 'V3', totals.nan .. ' vertices with NaN or infinite values (first: ' .. examples.nan .. ')') end
    if totals.normal > 0 then Add('W', 'V3', totals.normal .. ' normals are not unit length (first: ' .. examples.normal .. ')') end
    if totals.tangent > 0 then Add('W', 'V3', totals.tangent .. ' tangents or binormals are not unit length (first: ' .. examples.tangent .. ')') end
    if totals.ortho > 0 then Add('W', 'V3', totals.ortho .. ' tangent frames are not perpendicular to the normal (first: ' .. examples.ortho .. ')') end
    if totals.degenerate > 0 then Add('W', 'V3', totals.degenerate .. ' degenerate triangles (repeated vertex or no area)') end
    if totals.uv2 > 0 then Add('W', 'V4', totals.uv2 .. " light mask coordinates (uv2) outside 0..1; the masks use clamp addressing (first: " .. examples.uv2 .. ')') end
    if grid and scanned > 0 then
        local total = grid.nx * grid.nz
        res.coverage = 100 * grid.count / total
        if res.coverage < 99.9 then
            local first
            for key = 1, total do
                if not grid.hit[key] then first = key - 1 break end
            end
            local fi, fj = math.mod(first, grid.nx), floor(first / grid.nx)
            Add('W', 'V10', string.format('the mesh covers %.2f%% of the playable rectangle (%d of %d samples of %.1f units are open; first at x %.0f z %.0f)',
                res.coverage, total - grid.count, total, grid.cell, grid.x0 + (fi + 0.5) * grid.cell, grid.z0 + (fj + 0.5) * grid.cell))
        end
    end
    -- V15: mesh_high
    local s = model.settings
    if res.meshHigh then
        if not s.mesh_high then
            Add('W', 'V15', string.format('the manifest has no mesh_high; the vertices reach %.2f (range rings and fog of war volumes need it)', res.meshHigh))
        elseif abs(s.mesh_high - res.meshHigh) > 0.05 then
            Add('W', 'V15', string.format('mesh_high is %.2f but the highest vertex in the playable area (+%d units on the sides) is %.2f', s.mesh_high, MARGIN, res.meshHigh))
        end
    end
    return res
end

--- Highest vertex of all non-sky patches inside the playable rectangle plus the margin, or nil.
function MeshHigh(model, folder)
    local px0, pz0, px1, pz1 = Playable(model)
    local high
    for _, p in model.patches do
        if not p.comment and p.mesh and not (p.sky and p.sky ~= 0) then
            local mesh = ReadPatch(folder, p)
            if mesh then
                local hi = HighestIn(mesh, px0 - MARGIN, pz0 - MARGIN, px1 + MARGIN, pz1 + MARGIN)
                if hi and (not high or hi > high) then high = hi end
            end
        end
    end
    return high
end
