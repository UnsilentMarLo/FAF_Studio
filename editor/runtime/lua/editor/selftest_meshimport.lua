-- Mesh import self test (scm.lua, meshimport.lua, meshscan.lua, the material helpers of meshmap.lua). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_meshimport.lua').Run()
-- Returns text that starts with PASS or FAIL (one line per check below it).
--
-- Golden data: testdata/scm_golden.scm and the numbers in SPLIT_EXPECTED come from scripts/meshmaps/scm.py through editor/tools/gen_scm_golden.py.
-- When a converted SC2 patch is on this machine (SupCom_MeshMaps), its bytes must survive read + write unchanged.

local Scm = import('/lua/editor/scm.lua')
local Imp = import('/lua/editor/meshimport.lua')
local Scan = import('/lua/editor/meshscan.lua')
local Mesh = import('/lua/editor/meshmap.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b, eps)
    return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-4)
end

-- from editor/tools/gen_scm_golden.py
SPLIT_EXPECTED = {
    { 500, 889, 66281, 51299 },
    { 500, 890, 54141, 35196 },
    { 500, 878, 22988, 14810 },
    { 231, 385, 87962, 57378 },
}

local GOLDEN_COUNT = 12

local function GoldenMesh()
    local m = Scm.New()
    m.n = GOLDEN_COUNT
    for k = 0, GOLDEN_COUNT - 1 do
        local a, b = k * 3, k * 2
        m.pos[a + 1], m.pos[a + 2], m.pos[a + 3] = 100 + k * 0.75, math.mod(k * k, 17) * 0.25 + 3.125, 200 - k * 1.5
        m.nrm[a + 1], m.nrm[a + 2], m.nrm[a + 3] = 0.25 * math.mod(k, 3), 0.5, -0.125 * math.mod(k, 5)
        m.tan[a + 1], m.tan[a + 2], m.tan[a + 3] = 0.5, 0.25 * math.mod(k, 4), -0.5
        m.bin[a + 1], m.bin[a + 2], m.bin[a + 3] = 0.125 * k, 0.75, 0.0625
        m.uv1[b + 1], m.uv1[b + 2] = k * 0.125 - 2, 1.5 - k * 0.0625
        m.uv2[b + 1], m.uv2[b + 2] = k / 16, 1 - k / 16
    end
    for t = 0, GOLDEN_COUNT - 3 do
        table.insert(m.idx, t + 1) table.insert(m.idx, t + 2) table.insert(m.idx, t + 3)
    end
    return m
end

local function GridMesh(n, step)
    local m = Scm.New()
    m.n = n * n
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local a = (j * n + i) * 3
            m.pos[a + 1], m.pos[a + 2], m.pos[a + 3] = i * step, math.mod(i * j, 7), j * step
        end
    end
    for j = 0, n - 2 do
        for i = 0, n - 2 do
            local a, b, c, d = j * n + i + 1, j * n + i + 2, (j + 1) * n + i + 1, (j + 1) * n + i + 2
            for _, v in { a, c, b, b, c, d } do table.insert(m.idx, v) end
        end
    end
    return m
end

local function Diff(a, b)
    local n = math.min(string.len(a), string.len(b))
    for i = 1, n do
        if string.byte(a, i) ~= string.byte(b, i) then return i end
    end
    return string.len(a) ~= string.len(b) and (n + 1) or nil
end

--- An OBJ of a hilly grid: two materials (left and right half), one quad face per cell (so fans are exercised), uvs, optionally normals, one
--- degenerate triangle and one zero-area one at the end.
local function GridObj(n, step, withNormals, zup)
    local lines = { '# test grid', 'mtllib none.mtl' }
    local function H(i, j) return math.mod(i * j, 5) * 0.5 end
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local x, y, z = i * step, H(i, j), j * step
            if zup then y, z = -z, y end
            table.insert(lines, string.format('v %g %g %g', x, y, z))
        end
    end
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            table.insert(lines, string.format('vt %g %g', i / (n - 1), 1 - j / (n - 1)))
        end
    end
    if withNormals then
        table.insert(lines, zup and 'vn 0 0 1' or 'vn 0 1 0')
    end
    local half = math.floor((n - 1) / 2)
    local cur
    for j = 0, n - 2 do
        for i = 0, n - 2 do
            local a, b, c, d = j * n + i + 1, j * n + i + 2, (j + 1) * n + i + 2, (j + 1) * n + i + 1
            -- the quad a d c b is counter clockwise seen from above (y up)
            local side = (i < half) and 'left' or 'right'
            if side ~= cur then
                cur = side
                table.insert(lines, 'usemtl ' .. side)
            end
            if withNormals then
                table.insert(lines, string.format('f %d/%d/1 %d/%d/1 %d/%d/1 %d/%d/1', a, a, d, d, c, c, b, b))
            else
                table.insert(lines, string.format('f %d/%d %d/%d %d/%d %d/%d', a, a, d, d, c, c, b, b))
            end
        end
    end
    table.insert(lines, 'f 1 1 2')                       -- repeated vertex
    table.insert(lines, 'f 1 2 3')                       -- three points on one line (y = 0 along z = 0): no area
    return table.concat(lines, '\n') .. '\n'
end

local function MapDir()
    local p = ed_vfs_to_disk('/lua/editor/meshmap.lua')
    if not p then return nil end
    p = string.gsub(p, '\\', '/')
    -- <instance>/bin/../editor/lua/editor/meshmap.lua -> <instance>/mapout/selftest_meshimport (three folders up from lua/editor)
    return (string.gsub(p, '/[^/]*/[^/]*/[^/]*/[^/]*$', '')) .. '/mapout/selftest_meshimport'
end

function Run()
    out, failed = {}, 0

    -- ---- the binary format against the Python reference ---------------------------------------------------------------------------------
    local goldenPath = ed_vfs_to_disk('/lua/editor/testdata/scm_golden.scm')
    local golden = goldenPath and ed_read_file(goldenPath)
    Check(golden ~= nil, 'golden file testdata/scm_golden.scm found')
    if golden then
        local bytes = Scm.Write(GoldenMesh(), 'scm_golden', { 'Terrain mesh patch' })
        local at = Diff(bytes, golden)
        Check(at == nil, 'writer output equals scm.py output byte for byte (' .. string.len(golden) .. ' bytes)' .. (at and (', first difference at byte ' .. at) or ''))
        local m, why = Scm.Read(golden)
        Check(m ~= nil, 'golden file reads' .. (why and (': ' .. why) or ''))
        if m then
            local ref = GoldenMesh()
            local same = m.n == ref.n and table.getn(m.idx) == table.getn(ref.idx)
            for _, key in { 'pos', 'nrm', 'tan', 'bin', 'uv1', 'uv2', 'idx' } do
                for i = 1, table.getn(ref[key]) do
                    if m[key][i] ~= ref[key][i] then same = false break end
                end
            end
            Check(same, 'reader returns exactly the values scm.py wrote')
        end
    end
    local sc2 = 'C:/Users/Marlo/Documents/SupCom_MeshMaps/maps/sc2_mp_002/terrain/section01_000.scm'
    local real = ed_read_file(sc2)
    if real then
        local m = Scm.Read(real)
        local bytes = m and Scm.Write(m, 'section01_000', { 'Terrain mesh patch' })
        Check(bytes ~= nil and bytes == real, 'a converted SC2 patch (' .. (m and m.n or 0) .. ' vertices) survives read + write byte for byte')
    else
        table.insert(out, '  skip converted SC2 patch not on this machine')
    end
    -- header checks
    Check(Scm.Header('nonsense') == nil, 'a short file is rejected')
    local bad = Scm.Write(GoldenMesh(), 'x')
    Check(Scm.Header(string.sub(bad, 1, 4) .. string.char(4) .. string.sub(bad, 6)) == nil, 'version 4 is rejected')
    local many = Scm.New()
    many.n = 65536
    Check(Scm.Write(many, 'x') == nil, 'more than 65,535 vertices are refused')
    -- float32 corner cases
    local ok = true
    for _, v in { 1, -1, 0.5, 3.14159, -327.2637, 1e-3, 123456.789, -0.0001, 0, 65535, 8388607 } do
        if Scm.F32(Scm.PackF32(v), 1) ~= v then ok = false Check(false, 'float32 round trip of ' .. v) end
    end
    Check(ok, 'float32 pack / unpack round trip')

    -- ---- split ---------------------------------------------------------------------------------------------------------------------------
    local grid = GridMesh(40, 8)
    local parts = Scm.Split(grid, 500, 64)
    local split = table.getn(parts) == table.getn(SPLIT_EXPECTED)
    local detail = ''
    for i, p in parts do
        local e = SPLIT_EXPECTED[i]
        local sum, isum = 0, 0
        for k = 1, p.n do
            sum = math.mod(sum + k * math.floor(p.pos[(k - 1) * 3 + 1] + 3 * p.pos[(k - 1) * 3 + 3] + 7 * p.pos[(k - 1) * 3 + 2]), 100003)
        end
        for k = 1, table.getn(p.idx) do isum = math.mod(isum + k * p.idx[k], 100003) end
        if not e or p.n ~= e[1] or table.getn(p.idx) / 3 ~= e[2] or sum ~= e[3] or isum ~= e[4] then
            split = false
            detail = detail .. ' patch ' .. i .. ': ' .. p.n .. '/' .. table.getn(p.idx) / 3 .. '/' .. sum .. '/' .. isum
        end
    end
    Check(split, 'split of a 40 x 40 grid (limit 500, tile 64) equals scm.split' .. detail)
    Check(table.getn(Scm.Split(grid, 5000, 64)) == 1, 'a mesh under the limit passes through as one patch')

    -- ---- OBJ import ----------------------------------------------------------------------------------------------------------------------
    local n = 13
    local r = Imp.Run(GridObj(n, 8, false, false), { mapSize = 96 })
    Check(table.getn(r.groups) == 2, 'two materials give two groups (' .. table.getn(r.groups) .. ')')
    Check(r.stats.dropped == 2, 'a repeated-vertex and a zero-area triangle are dropped (' .. r.stats.dropped .. ')')
    Check(r.stats.triangles == (n - 1) * (n - 1) * 2, 'every quad became two triangles (' .. r.stats.triangles .. ')')
    local g1 = r.groups[1]
    Check(g1 and g1.name == 'left', 'group names come from usemtl')
    local p1 = g1.patches[1]
    local st = Scan.PatchStats(p1, true)
    Check(st.nan == 0 and st.normal == 0 and st.tangent == 0 and st.ortho == 0 and st.degenerate == 0 and st.uv2 == 0, 'imported patch passes V3 / V4 (' ..
        st.normal .. ' normals, ' .. st.tangent .. ' tangents, ' .. st.ortho .. ' frames, ' .. st.degenerate .. ' degenerate, ' .. st.uv2 .. ' uv2)')
    -- winding and frame conventions
    local up, rightHanded, tangentAlongU = 0, 0, 0
    for t = 0, p1.n * 0 + table.getn(p1.idx) / 3 - 1 do
        local a, b, c = (p1.idx[t * 3 + 1] - 1) * 3, (p1.idx[t * 3 + 2] - 1) * 3, (p1.idx[t * 3 + 3] - 1) * 3
        local e1x, e1y, e1z = p1.pos[b + 1] - p1.pos[a + 1], p1.pos[b + 2] - p1.pos[a + 2], p1.pos[b + 3] - p1.pos[a + 3]
        local e2x, e2y, e2z = p1.pos[c + 1] - p1.pos[a + 1], p1.pos[c + 2] - p1.pos[a + 2], p1.pos[c + 3] - p1.pos[a + 3]
        local cy = e1z * e2x - e1x * e2z
        if cy > 0 then up = up + 1 end
    end
    for v = 0, p1.n - 1 do
        local b = v * 3
        if p1.nrm[b + 2] > 0 then rightHanded = rightHanded + 1 end
        -- u grows with x in this grid: the tangent points to +x
        if p1.tan[b + 1] > 0.9 then tangentAlongU = tangentAlongU + 1 end
    end
    local tris = table.getn(p1.idx) / 3
    Check(up == tris, 'counter clockwise triangles seen from above face up (' .. up .. ' of ' .. tris .. ')')
    Check(rightHanded == p1.n, 'smooth normals point up (' .. rightHanded .. ' of ' .. p1.n .. ')')
    Check(tangentAlongU == p1.n, 'tangents follow +u (' .. tangentAlongU .. ' of ' .. p1.n .. ')')
    -- binormal = cross(normal, tangent)
    local frame = true
    for v = 0, p1.n - 1 do
        local b = v * 3
        local nx, ny, nz, tx, ty, tz = p1.nrm[b + 1], p1.nrm[b + 2], p1.nrm[b + 3], p1.tan[b + 1], p1.tan[b + 2], p1.tan[b + 3]
        local cx, cy, cz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
        if not (Near(cx, p1.bin[b + 1], 1e-3) and Near(cy, p1.bin[b + 2], 1e-3) and Near(cz, p1.bin[b + 3], 1e-3)) then frame = false end
    end
    Check(frame, 'binormal = normal x tangent (the convention of converted SC2 patches)')
    -- v is flipped by default: the OBJ's v = 1 at j = 0 becomes 0
    Check(Near(p1.uv1[2], 0, 1e-5) or Near(p1.uv1[2], 1, 1e-5), 'uv v is flipped for DDS textures')

    -- options
    local flip = Imp.Run(GridObj(n, 8, false, false), { flipWinding = true, mapSize = 96 })
    local fp = flip.groups[1].patches[1]
    Check(Near(fp.nrm[2], -1, 0.5) and fp.nrm[2] < 0, 'flipWinding turns the faces over (normal y ' .. fp.nrm[2] .. ')')
    local zup = Imp.Run(GridObj(n, 8, false, true), { axis = 'z_up', mapSize = 96 })
    local zp = zup.groups[1].patches[1]
    local same = zp.n == p1.n
    if same then
        for i = 1, p1.n * 3 do
            if not Near(zp.pos[i], p1.pos[i], 1e-4) then same = false break end
        end
    end
    Check(same, 'axis z_up gives the positions of the y_up file')
    local scaled = Imp.Run(GridObj(n, 8, false, false), { scale = 2, offsetY = 10, mapSize = 96 })
    Check(Near(scaled.groups[1].patches[1].pos[1], p1.pos[1] * 2, 1e-4) and Near(scaled.groups[1].patches[1].pos[2], p1.pos[2] * 2 + 10, 1e-4), 'scale and offset are applied')
    local mirror = Imp.Run(GridObj(n, 8, false, false), { mirrorX = true, mapSize = 96 })
    local mp = mirror.groups[1].patches[1]
    local mup = 0
    for t = 0, table.getn(mp.idx) / 3 - 1 do
        local a, b, c = (mp.idx[t * 3 + 1] - 1) * 3, (mp.idx[t * 3 + 2] - 1) * 3, (mp.idx[t * 3 + 3] - 1) * 3
        if (mp.pos[b + 3] - mp.pos[a + 3]) * (mp.pos[c + 1] - mp.pos[a + 1]) - (mp.pos[b + 1] - mp.pos[a + 1]) * (mp.pos[c + 3] - mp.pos[a + 3]) > 0 then mup = mup + 1 end
    end
    Check(mup == table.getn(mp.idx) / 3, 'a mirrored mesh keeps its faces up (winding follows the mirror)')
    local flatR = Imp.Run(GridObj(n, 8, false, false), { normals = 'flat', mapSize = 96 })
    Check(flatR.groups[1].patches[1].n == flatR.groups[1].kept * 3, 'flat normals split every triangle into its own vertices')
    local fileN = Imp.Run(GridObj(n, 8, true, false), { mapSize = 96 })
    Check(Near(fileN.groups[1].patches[1].nrm[2], 1) and fileN.groups[1].info.fileNormals == fileN.groups[1].patches[1].n, 'normals of the file are used when it has them')
    -- no uvs: planar
    local neg = Imp.Run('v 0 0 0\nv 0 0 8\nv 8 0 0\nf -3 -2 -1\n', {})
    Check(neg.stats.triangles == 1, 'negative face indices count from the end')
    local noUv = Imp.Run('v 0 0 0\nv 0 0 64\nv 64 0 0\nf 1 2 3\n', { uvTile = 64 })
    local nu = noUv.groups[1].patches[1]
    Check(nu and nu.n == 3 and Near(nu.uv1[3], 0) and Near(nu.uv1[4], 1), 'a file without uvs gets planar uv over x, z')
    Check(nu and Near(nu.tan[1], 1, 1e-3) and nu.nrm[2] > 0.99, 'and a tangent along x (' .. tostring(nu and nu.tan[1]) .. ')')

    -- limit: patches stay under it and keep all triangles
    local small = Imp.Run(GridObj(n, 8, false, false), { limit = 60, tile = 32, mapSize = 96 })
    local tri, over = 0, false
    for _, g in small.groups do
        for _, p in g.patches do
            tri = tri + table.getn(p.idx) / 3
            if p.n > 60 then over = true end
        end
    end
    Check(not over and tri == small.stats.triangles and small.stats.patches > 2, 'a low vertex limit cuts into patches of at most that many vertices (' .. small.stats.patches .. ' patches)')

    -- ---- commit into a map folder, scans --------------------------------------------------------------------------------------------------
    local dir = MapDir()
    if not dir then
        Check(false, 'no folder for the commit test')
    else
        local model = Mesh.New()
        model.settings.size = 96
        model.settings.playable_x0, model.settings.playable_z0, model.settings.playable_x1, model.settings.playable_z1 = 0, 0, 96, 96
        local files, why = Imp.Commit(model, r, dir, {})
        Check(files ~= nil and table.getn(files) == 2, 'commit wrote two patch files' .. (why and (': ' .. why) or ''))
        Check(table.getn(model.patches) == 2 and table.getn(model.materials) == 2 and model.patches[2].material == 2, 'manifest model has two patches and two materials')
        Check(files and files[1] == 'section00_000.scm' and files[2] == 'section01_000.scm', 'files are named section<group>_<serial>.scm')
        local back = files and Scm.Read(ed_read_file(dir .. '/terrain/' .. files[1]))
        Check(back ~= nil and back.n == p1.n, 'written file reads back')
        Check(model.settings.mesh_high ~= nil and Near(model.settings.mesh_high, 2, 0.01), 'mesh_high follows from the vertices (' .. tostring(model.settings.mesh_high) .. ')')
        -- manifest text round trip
        local text = Mesh.Write(model)
        local m2 = Mesh.Parse(text)
        Check(Mesh.Write(m2) == text and table.getn(m2.warnings) == 0, 'manifest of the import writes and parses without change')
        -- a second import appends with new section numbers
        local again = Imp.Commit(model, r, dir, {})
        Check(again and again[1] == 'section02_000.scm' and table.getn(model.patches) == 4, 'a second import continues the numbering')
        local replaced = Imp.Commit(model, r, dir, { replace = true })
        Check(replaced and table.getn(model.patches) == 2, 'replace drops the earlier patch entries')
        -- the checks
        local scan = Scan.Scan(model, dir, {})
        Check(scan.meshHigh ~= nil and Near(scan.meshHigh, 2, 0.01), 'scan: highest vertex')
        Check(scan.coverage ~= nil and scan.coverage > 99.9, 'scan: grid covers the playable rectangle (' .. tostring(scan.coverage) .. '%)')
        local clean = true
        for _, f in scan.findings do
            if f.sev ~= 'I' then clean = false table.insert(out, '       finding ' .. f.code .. ' ' .. f.text) end
        end
        Check(clean, 'scan of a clean import has no findings')
        -- V15
        model.settings.mesh_high = 50
        local bad15 = Scan.Scan(model, dir, { coverage = false })
        local has15 = false
        for _, f in bad15.findings do if f.code == 'V15' then has15 = true end end
        Check(has15, 'V15 reports a wrong mesh_high')
        model.settings.mesh_high = scan.meshHigh
        -- V10: a playable rectangle larger than the mesh
        model.settings.size = 192
        model.settings.playable_x1, model.settings.playable_z1 = 192, 192
        local wide = Scan.Scan(model, dir, {})
        local has10 = false
        for _, f in wide.findings do if f.code == 'V10' then has10 = true end end
        Check(has10 and wide.coverage < 40, 'V10 reports a mesh that covers a quarter of the rectangle (' .. tostring(wide.coverage) .. '%)')
        model.settings.size = 96
        model.settings.playable_x1, model.settings.playable_z1 = 96, 96
        -- V3 / V4 on a damaged patch
        local broken = Scm.Read(ed_read_file(dir .. '/terrain/' .. files[1]))
        broken.nrm[1], broken.nrm[2], broken.nrm[3] = 0, 3, 0
        broken.uv2[1] = 1.5
        broken.tan[4], broken.tan[5], broken.tan[6] = 0, 1, 0       -- along the normal
        broken.pos[7] = 1 / 0
        local stBroken = Scan.PatchStats(broken, true)
        Check(stBroken.normal >= 1 and stBroken.uv2 >= 1 and stBroken.ortho >= 1 and stBroken.nan >= 1, 'V3 / V4 count a broken normal, tangent frame, uv2 and infinity')
        -- deep check through meshmap.Check
        local list = Mesh.Check(model, dir, { deep = true })
        local errs = 0
        for _, f in list do
            if f.sev == 'E' and f.code ~= 'V11' and f.code ~= 'V19' and f.code ~= 'V9' and f.code ~= 'V12' then errs = errs + 1 table.insert(out, '       ' .. f.code .. ' ' .. f.text) end
        end
        Check(errs == 0, 'Mesh.Check with deep = true runs on the written folder')
    end

    -- ---- a real converted map, when this machine has one ----------------------------------------------------------------------------------
    local realDir = 'C:/Users/Marlo/Documents/SupCom_MeshMaps/maps/sc2_mp_002'
    local rm = ed_file_stamp(realDir .. '/terrain/terrain.lua') and Mesh.Load(realDir)
    if rm then
        local scan = Scan.Scan(rm, realDir, {})
        Check(scan.coverage and scan.coverage > 99.9, 'converted map sc2_mp_002: the mesh covers its playable rectangle (' .. tostring(scan.coverage) .. '%)')
        Check(scan.meshHigh and rm.settings.mesh_high and Near(scan.meshHigh, rm.settings.mesh_high, 0.05), 'converted map: mesh_high of the manifest equals the vertices (' .. tostring(scan.meshHigh) .. ' / ' .. tostring(rm.settings.mesh_high) .. ')')
        local bad = false
        for _, f in scan.findings do if f.code == 'V1' or f.code == 'V4' or f.code == 'V15' then bad = true end end
        Check(not bad, 'converted map: no V1 / V4 / V15 findings')
    else
        table.insert(out, '  skip converted map sc2_mp_002 not on this machine')
    end

    -- ---- material entries ----------------------------------------------------------------------------------------------------------------
    local mat = { { 'name', 'x' } }
    Mesh.MaterialSet(mat, 'light_mask_0', 'textures/m0.dds')
    Mesh.MaterialSet(mat, 'diffuse_a', 'textures/d.dds')
    Mesh.MaterialSet(mat, 'blending', 1)
    Mesh.MaterialSet(mat, 'normal_a', 'textures/n.dds')
    local order = ''
    for _, f in mat do order = order .. f[1] .. ' ' end
    Check(order == 'name blending diffuse_a normal_a light_mask_0 ', 'material fields stay in canonical order (' .. order .. ')')
    Mesh.MaterialSet(mat, 'diffuse_a', 'textures/e.dds')
    Mesh.MaterialSet(mat, 'blending', nil)
    Check(Mesh.MaterialGet(mat, 'diffuse_a') == 'textures/e.dds' and Mesh.MaterialGet(mat, 'blending') == nil, 'a field is replaced and removed')

    table.insert(out, 1, (failed == 0 and 'PASS' or 'FAIL') .. ' mesh import: ' .. failed .. ' failed')
    return table.concat(out, '\n')
end
