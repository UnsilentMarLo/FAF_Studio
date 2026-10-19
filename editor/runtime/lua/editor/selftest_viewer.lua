-- The unit viewer (unitview.lua): the pure parts (3D box / circle / rectangle drawing, footprint and skirt, stage spot, camera focus) and, in a running editor, the live parts
-- (stage on / off, cleanup, naval units, bones every frame). Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_viewer.lua').Run()         synchronous checks (part of editor_inst.py selftests)
--   return import('/lua/editor/selftest_viewer.lua').RunLive()     starts the live checks in a thread; read  import('/lua/editor/selftest_viewer.lua').LIVERESULT  after about 50 seconds (needs the window in front)

local View = import('/lua/editor/unitview.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b, eps) return math.abs(a - b) <= (eps or 0.0001) end

function Run()
    out, failed = {}, 0

    -- the box: one polyline of 16 points that visits all 12 edges
    local pts = View.BoxPoints(0, 0, 0, 2, 3, 4)
    Ok(table.getn(pts) == 16 * 3, 'a box is one polyline of 16 points')
    local edges, seen = 0, {}
    for i = 0, 14 do
        local a = { pts[i * 3 + 1], pts[i * 3 + 2], pts[i * 3 + 3] }
        local b = { pts[i * 3 + 4], pts[i * 3 + 5], pts[i * 3 + 6] }
        local diff = 0
        for k = 1, 3 do if a[k] ~= b[k] then diff = diff + 1 end end
        Ok(diff == 1 or diff == 0, 'edge ' .. i .. ' runs along one axis')
        local key = math.min(a[1], b[1]) .. ',' .. math.min(a[2], b[2]) .. ',' .. math.min(a[3], b[3]) .. '>' .. math.max(a[1], b[1]) .. ',' .. math.max(a[2], b[2]) .. ',' .. math.max(a[3], b[3])
        if not seen[key] and diff == 1 then seen[key] = true edges = edges + 1 end
    end
    Ok(edges == 12, 'the polyline covers all 12 edges of the box (' .. edges .. ')')
    local minY, maxY = 1e9, -1e9
    for i = 0, 15 do
        local y = pts[i * 3 + 2]
        if y < minY then minY = y end
        if y > maxY then maxY = y end
    end
    Ok(minY == 0 and maxY == 3, 'the box has height (it is 3D, not a flat rectangle)')

    -- circle and rectangle
    local c = View.CirclePoints(10, 5, 20, 3, 8)
    Ok(table.getn(c) == 24 and Near(c[1], 13) and Near(c[2], 5) and Near(c[3], 20), 'a circle lies at the given height')
    local r = View.RectPoints(1, 2, 3, 4, 7)
    Ok(table.getn(r) == 12 and r[2] == 7 and r[1] == 1 and r[7] == 3 and r[9] == 4, 'a ground rectangle')

    -- footprint and skirt: the skirt starts at the footprint's corner plus the offsets
    local bp = { Footprint = { SizeX = 3, SizeZ = 3 }, Physics = { SkirtOffsetX = -0.5, SkirtOffsetZ = -0.5, SkirtSizeX = 4, SkirtSizeZ = 4 } }
    local foot, skirt = View.FootprintRects(bp, 100, 200)
    Ok(Near(foot[1], 98.5) and Near(foot[2], 198.5) and Near(foot[3], 101.5) and Near(foot[4], 201.5), 'the footprint is centred on the unit')
    Ok(skirt and Near(skirt[1], 98) and Near(skirt[2], 198) and Near(skirt[3], 102) and Near(skirt[4], 202), 'the skirt is 4 x 4 from the offset corner')
    local _, none = View.FootprintRects({ Footprint = { SizeX = 1, SizeZ = 1 } }, 0, 0)
    Ok(none == nil, 'no skirt when the blueprint has none')

    -- the stage spot: the corner farthest from every object
    local x, z = View.StageSpotFor(256, { { 10, 10 }, { 240, 20 }, { 20, 240 } })
    Ok(x > 128 and z > 128, 'the stage takes the corner no object is near (' .. x .. ', ' .. z .. ')')
    local x2, z2 = View.StageSpotFor(256, {})
    Ok(x2 > 0 and z2 > 0, 'a map without objects has a stage spot')

    -- the camera focus: the line of sight through the focus passes through the unit's centre, the focus lies on the ground
    for _, case in { { 0, 0.5 }, { 3.7, 0.55 }, { 1.2, 1.4 }, { 5, 0.12 } } do
        local h, p = case[1], case[2]
        local gx, gy, gz, s = View.FocusFor(40, 26, 50, h, p, 25, 0, 0, 0)
        Ok(Near(gy, 25), 'the focus is on the ground (heading ' .. h .. ', pitch ' .. p .. ')')
        local dx, dy, dz = math.sin(h) * math.cos(p), -math.sin(p), math.cos(h) * math.cos(p)
        Ok(Near(gx - dx * s, 40, 0.001) and Near(gy - dy * s, 26, 0.001) and Near(gz - dz * s, 50, 0.001), 'the line of sight from the focus back goes through the centre')
    end
    -- a unit that must appear 100 pixels right of the middle (0.01 units per pixel) has the line of sight one unit to its screen left (heading 0 looks along +z, screen right is -x, so +x)
    local ax = View.FocusFor(40, 26, 50, 0, 0.5, 25, 100, 0, 0.01)
    Ok(Near(ax, 41, 0.001), 'a screen offset of the unit shifts the focus sideways')

    -- LOD semantics: eye distance, not zoom
    local lods = View.LODs('uel0201')
    Ok(table.getn(lods) >= 2 and lods[2].from == lods[1].cutoff, 'LOD ranges follow each other')

    -- state: nothing drawn, nothing shown
    View.Remove()
    Ok(View.Id == false and View.EntityId == false and table.getn(View.Bones) == 0, 'Remove leaves nothing of the unit behind')
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end

local function Wait(seconds) WaitSeconds(seconds) end

--- Live checks, in a thread: stage, cleanup after naval units, bones every frame, close. LIVERESULT is the text when done.
function RunLive()
    LIVERESULT = 'running'
    ForkThread(function()
        local res, bad = {}, 0
        local function Check(ok, text)
            table.insert(res, (ok and '  ok   ' or '  FAIL ') .. text)
            if not ok then bad = bad + 1 end
        end
        local cam0 = { ed_camera_info() }
        View.Close()
        -- naval units one after the other: only the last stays, no wreck is left
        for _, id in { 'ues0203', 'ues0201', 'urs0103', 'ues0103' } do
            View.Spawn(id)
            Wait(2.2)
        end
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_live_around.txt', x = View.X, z = View.Z, radius = 100 } }, false)
        Wait(1)
        local text = ed_read_file('ed_live_around.txt') or ''
        local units, props = 0, 0
        for line in string.gfind(text, '[^\r\n]+') do
            if string.find(line, '^unit ') then units = units + 1 end
            if string.find(line, 'wreckage') then props = props + 1 end
        end
        Check(units == 1, 'after four naval units there is one unit on the stage (' .. units .. ')')
        Check(props == 0, 'no wreckage is left (' .. props .. ')')
        Check(View.EntityId ~= false and type(ed_unit_bones(View.EntityId)) == 'table', 'the renderer answers for the shown unit')
        -- a wreck that appears on the stage is taken down with the unit
        SimCallback({ Func = 'EdViewTestProp', Args = { x = View.X + 1, y = View.Y0, z = View.Z + 1 } }, false)
        Wait(1)
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_live_around.txt', x = View.X, z = View.Z, radius = 100 } }, false)
        Wait(1)
        text = ed_read_file('ed_live_around.txt') or ''
        Check(string.find(text, 'wreckage') ~= nil, 'the test wreck is there before the viewer takes things down')
        View.Spawn('ues0103')
        Wait(2)
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_live_around.txt', x = View.X, z = View.Z, radius = 100 } }, false)
        Wait(1)
        text = ed_read_file('ed_live_around.txt') or ''
        Check(string.find(text, 'wreckage') == nil and string.find(text, 'ues0103') ~= nil, 'a new unit clears the wreck (and stands there itself)')
        -- leaving the Mod workspace closes the viewer
        local Shell = import('/lua/editor/gui/shell.lua')
        Shell.ShowWorkspace('Terrain')
        Wait(1.5)
        Check(View.Id == false, 'leaving the Mod workspace takes the unit down')
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_live_around.txt', x = View.X, z = View.Z, radius = 100 } }, false)
        Wait(1)
        text = ed_read_file('ed_live_around.txt') or ''
        Check(not string.find(text, 'unit ') and not string.find(text, 'wreckage'), 'and leaves nothing on the stage')
        Shell.ShowWorkspace('Mod')
        Wait(1)
        View.Spawn('ues0103')
        Wait(2)
        -- the stage: terrain off, then back on at the map stage and after Close
        local alive = true
        View.Close()
        Wait(1.5)
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_live_around.txt', x = View.X, z = View.Z, radius = 100 } }, false)
        Wait(1)
        text = ed_read_file('ed_live_around.txt') or ''
        Check(not string.find(text, 'unit ') and not string.find(text, 'wreckage'), 'Close leaves no unit and no wreck on the stage')
        local cam1 = { ed_camera_info() }
        Check(cam0[3] and Near(cam0[3], cam1[3], 0.5) and Near(cam0[5], cam1[5], 0.5), 'Close puts the map camera back (' .. tostring(cam0[3]) .. ',' .. tostring(cam0[5]) .. ' -> ' .. tostring(cam1[3]) .. ',' .. tostring(cam1[5]) .. ')')
        LIVERESULT = (bad == 0 and 'PASS' or ('FAIL: ' .. bad)) .. '\n' .. table.concat(res, '\n')
    end)
    return 'started'
end
