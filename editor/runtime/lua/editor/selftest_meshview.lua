-- Mesh terrain view self test (EdMeshData / EdMeshDraw natives ed_mesh_*, meshview.lua). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_meshview.lua').Run()      a few seconds later: Check2()    (the viewport has drawn the mesh)
-- Run returns text that starts with PASS or FAIL. Needs the editor engine with the ed_mesh natives (skips with a note otherwise).
--
-- The fixture is made with the mesh importer (a sloped plane and a bridge deck above it), mounted as /maps/selftest_meshview; a converted SC2 map is used too when
-- the maps folder has one: its native height range must equal what the Lua SCM reader (meshscan.lua) finds.

local Imp = import('/lua/editor/meshimport.lua')
local Mesh = import('/lua/editor/meshmap.lua')
local Scan = import('/lua/editor/meshscan.lua')
local MeshView = import('/lua/editor/meshview.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b, eps)
    return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 0.01)
end

local function MapDir()
    local p = ed_vfs_to_disk('/lua/editor/meshmap.lua')
    if not p then return nil end
    p = string.gsub(p, '\\', '/')
    return (string.gsub(p, '/[^/]*/[^/]*/[^/]*/[^/]*$', '')) .. '/mapout/selftest_meshview'
end

--- A grid of cells over x, z in 0..size, height from `height(x, z)`, material name `mat`.
local function GridObj(size, step, height, mat)
    local lines = { 'usemtl ' .. mat }
    local n = math.floor(size / step) + 1
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            table.insert(lines, string.format('v %g %g %g', i * step, height(i * step, j * step), j * step))
        end
    end
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            table.insert(lines, string.format('vt %g %g', i / (n - 1), j / (n - 1)))
        end
    end
    for j = 0, n - 2 do
        for i = 0, n - 2 do
            local a, b, c, d = j * n + i + 1, j * n + i + 2, (j + 1) * n + i + 2, (j + 1) * n + i + 1
            table.insert(lines, string.format('f %d/%d %d/%d %d/%d %d/%d', a, a, d, d, c, c, b, b))
        end
    end
    return table.concat(lines, '\n') .. '\n'
end

function Run()
    out, failed = {}, 0
    if not rawget(_G, 'ed_mesh_load') then
        return 'PASS meshview: skipped (this engine has no ed_mesh natives)'
    end
    local dir = MapDir()
    Check(dir ~= nil, 'a folder for the fixture')
    if not dir then return 'FAIL meshview' end

    -- ---- the fixture: ground y = 0.1 x + 5 over 0..64, a deck at y = 60 over x 20..40, z 20..40 ----------------------------------------------------
    local ground = Imp.Run(GridObj(64, 8, function(x, z) return 0.1 * x + 5 end, 'ground'), { mapSize = 64, limit = 65535 })
    local deck = Imp.Run(GridObj(20, 4, function(x, z) return 60 end, 'deck'), { mapSize = 64, offsetX = 20, offsetZ = 20 })
    local model = Mesh.New()
    local s = model.settings
    s.size, s.playable_x0, s.playable_z0, s.playable_x1, s.playable_z1 = 64, 0, 0, 64, 64
    Imp.Commit(model, ground, dir, { updateHeights = false })
    Imp.Commit(model, deck, dir, { updateHeights = false })
    Check(table.getn(model.patches) == 2 and table.getn(model.materials) == 2, 'fixture manifest has a ground and a deck patch')
    ed_write_file(dir .. '/terrain/terrain.lua', Mesh.Write(model))
    local mounted = ed_vfs_mount(dir, '/maps/selftest_meshview')
    Check(mounted, 'the fixture folder is mounted at /maps/selftest_meshview')

    local ok, why = ed_mesh_load('/maps/selftest_meshview/terrain/terrain.lua')
    Check(ok == true, 'ed_mesh_load reads the manifest and both patches' .. (why and (': ' .. tostring(why)) or ''))
    local info = ed_mesh_info()
    Check(info ~= nil and info.patches == 2 and info.materials == 2, 'ed_mesh_info: two patches, two materials')
    Check(info ~= nil and info.vertices == 117 and info.triangles == 178, 'ed_mesh_info: 81 + 36 vertices, 128 + 50 triangles (' .. tostring(info and info.vertices) .. ' / ' .. tostring(info and info.triangles) .. ')')
    Check(info ~= nil and info.size == 64, 'ed_mesh_info: size from the manifest')
    ok, why = ed_mesh_load('/maps/selftest_meshview/terrain/missing.lua')
    Check(ok == nil and why ~= nil, 'a missing manifest is refused with a reason')
    ed_mesh_load('/maps/selftest_meshview/terrain/terrain.lua')

    -- ---- height under a point -------------------------------------------------------------------------------------------------------------------------
    Check(Near(ed_mesh_height(10, 30), 6), 'height on the slope at x 10 (' .. tostring(ed_mesh_height(10, 30)) .. ')')
    Check(Near(ed_mesh_height(30, 30), 60), 'the highest surface wins where the deck is (' .. tostring(ed_mesh_height(30, 30)) .. ')')
    Check(Near(ed_mesh_height(30, 30, 20), 8), 'with a ceiling the ground below the deck is found (' .. tostring(ed_mesh_height(30, 30, 20)) .. ')')
    Check(ed_mesh_height(100, 30) == nil, 'nothing outside the mesh')

    -- ---- rays ----------------------------------------------------------------------------------------------------------------------------------------
    local t, x, y, z, nx, ny, nz, patch, material = ed_mesh_ray(10, 100, 30, 0, -1, 0)
    Check(Near(t, 94) and Near(y, 6) and ny > 0.99, 'a ray straight down hits the slope at y 6, t 94 (t ' .. tostring(t) .. ', y ' .. tostring(y) .. ')')
    Check(patch == 1 and material == 1, 'and reports patch 1, material 1 (' .. tostring(patch) .. ' / ' .. tostring(material) .. ')')
    t, x, y, z, nx, ny, nz, patch, material = ed_mesh_ray(30, 100, 30, 0, -1, 0)
    Check(Near(y, 60) and patch == 2 and material == 2, 'over the deck the first hit is the deck (y ' .. tostring(y) .. ', patch ' .. tostring(patch) .. ')')
    t, x, y, z = ed_mesh_ray(30, 40, 30, 0, -1, 0)
    Check(Near(y, 8), 'a ray from between the layers goes through to the ground (y ' .. tostring(y) .. ')')
    t, x, y, z, nx, ny, nz = ed_mesh_ray(0, 20, 30, 1, -0.5, 0)
    Check(t ~= nil and ny > 0.9 and nx < 0, 'an oblique ray hits with the slope normal tilted against the slope (n ' .. string.format('%.2f %.2f', nx or 0, ny or 0) .. ')')
    Check(ed_mesh_ray(200, 100, 30, 0, -1, 0) == nil, 'a ray beside the mesh misses')
    Check(ed_mesh_ray(10, 100, 30, 0, 1, 0) == nil, 'a ray pointing away misses')

    -- ---- range, modes -----------------------------------------------------------------------------------------------------------------------------
    local lo, hi = ed_mesh_range(0)
    Check(Near(lo, 5) and Near(hi, 60), 'ed_mesh_range: lowest and highest vertex (' .. tostring(lo) .. ' / ' .. tostring(hi) .. ')')
    Check(ed_mesh_mode(0) == 0 and ed_mesh_mode(2) == 2 and ed_mesh_mode(1) == 1, 'ed_mesh_mode sets and returns 0, 2, 1')
    Check(MeshView.SetMode('both') == 2 and MeshView.Mode() == 2, 'meshview.SetMode takes names')
    MeshView.SetMode(1)
    ed_mesh_unload()
    Check(ed_mesh_info() == nil and ed_mesh_height(10, 30) == nil, 'ed_mesh_unload empties the mesh')

    -- ---- a converted map, when the maps folder has one: native reader against the Lua reader --------------------------------------------------------
    local real = '/maps/sc2_mp_002/terrain/terrain.lua'
    local disk = ed_vfs_to_disk(real)
    if disk then
        local folder = string.gsub(string.gsub(disk, '\\', '/'), '/terrain/terrain%.lua$', '')
        local m = Mesh.Load(folder)
        local scan = m and Scan.Scan(m, folder, { coverage = false })
        local ok2 = ed_mesh_load(real)
        local i = ed_mesh_info()
        Check(ok2 == true and i ~= nil and i.patches == table.getn(m.patches), 'converted map sc2_mp_002: ' .. tostring(i and i.patches) .. ' patches')
        local mlo, mhi = ed_mesh_range(32)
        Check(scan and scan.meshHigh and Near(mhi, scan.meshHigh, 0.02), 'its native mesh_high equals the Lua SCM reader (' .. tostring(mhi) .. ' / ' .. tostring(scan and scan.meshHigh) .. ')')
        local total = 0
        for _, p in m.patches do total = total + (p.vertices or 0) end
        Check(i ~= nil and i.vertices == total, 'and the vertex count equals the manifest (' .. tostring(i and i.vertices) .. ' / ' .. total .. ')')
        local h = ed_mesh_height(512, 512)
        Check(h ~= nil and h > -50 and h < 200, 'a height under the middle of the map (' .. tostring(h) .. ')')
        ed_mesh_unload()
    else
        table.insert(out, '  skip converted map sc2_mp_002 not in the maps folders')
    end

    -- ---- Check2: with the mesh loaded the viewport draws it ----------------------------------------------------------------------------------------------
    ed_mesh_load('/maps/selftest_meshview/terrain/terrain.lua')
    ed_mesh_mode(1)
    table.insert(out, 1, (failed == 0 and 'PASS' or 'FAIL') .. ' meshview: ' .. failed .. ' failed (run Check2() a few seconds later, then it unloads the fixture)')
    return table.concat(out, '\n')
end

--- A few seconds after Run(): the viewport has drawn the fixture (draw_ms > 0) and the mesh pick answers for the screen centre.
function Check2()
    local lines, bad = {}, 0
    local i = ed_mesh_info()
    local drawn = i ~= nil and i.draw_ms > 0
    table.insert(lines, (drawn and '  ok   ' or '  FAIL ') .. 'the viewport drew the mesh (draw_ms ' .. tostring(i and i.draw_ms) .. ')')
    if not drawn then bad = bad + 1 end
    ed_mesh_unload()
    return (bad == 0 and 'PASS' or 'FAIL') .. ' meshview 2: ' .. bad .. ' failed\n' .. table.concat(lines, '\n')
end
