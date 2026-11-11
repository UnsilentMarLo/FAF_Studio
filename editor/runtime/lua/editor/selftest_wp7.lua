-- WP7 self test (upstream port: Terrace and Plane brushes, prop symmetry check, Lua syntax check of the map scripts). Run in the live editor:
--   return import('/lua/editor/selftest_wp7.lua').Run()
-- Returns a report string; the first line is PASS or FAIL. Needs an exe with the WP7 natives (ed_plane_through, ed_up_check_lua, ed_up_check_props); without them the checks
-- that need them are reported as skipped (the Lua loop of the brushes is still compared with itself and the properties).

function Run()
    local T = import('/lua/editor/terrain.lua')
    local Symmetry = import('/lua/editor/symmetry.lua')
    local MC = import('/lua/editor/markercheck.lua')
    local failures = {}
    local lines = {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local function skip(name) table.insert(lines, '  skip ' .. name) end

    local w, h = ed_terrain_info()
    check('terrain present', w ~= nil and w >= 129 and h >= 129, tostring(w) .. 'x' .. tostring(h))
    if not w then return 'FAIL\n' .. table.concat(lines, '\n') end

    local saved = { mode = T.Brush.mode, radius = T.Brush.radius, strength = T.Brush.strength, falloff = T.Brush.falloff, level = T.Brush.level,
                    terraceStep = T.Brush.terraceStep, points = T.Brush.planePoints, native = T.NativeBrush, symMode = Symmetry.Mode, symManual = Symmetry.Manual }
    Symmetry.Mode = 'off'
    T.ClearHistory()

    -- a rolling test ground (4 x 4 sample blocks, heights between 16 and 44 units)
    local function Roll()
        for z = 60, 160, 4 do
            for x = 60, 160, 4 do
                ed_terrain_set_rect(x, z, x + 3, z + 3, 30 + 8 * math.sin(x * 0.21) + 6 * math.cos(z * 0.17))
            end
        end
    end
    Roll()
    T.ClearHistory()

    -- ---- terrace: the native dab and the Lua loop agree; a strong dab puts the middle of the brush on a step ---------------------------------------------------------
    local function Run(mode, native, setup, dabs)
        T.NativeBrush = native
        Roll()
        T.ClearHistory()
        T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff, T.Brush.level = mode, 14, 3.5, 0.7, nil
        setup()
        T.SetNextStrokeId(77)
        T.BeginStroke()
        local total = 0
        for _, d in dabs do total = total + T.Dab(d[1], d[2]) end
        T.EndStroke()
        local words = ed_terrain_read_rect(70, 70, 150, 150)
        T.NativeBrush = true
        return words, total
    end
    local function Compare(name, a, ca, b, cb)
        local differ, worst = 0, 0
        for i = 1, 81 * 81 do
            local d = math.abs(a[i] - b[i])
            if d > 0 then differ = differ + 1 end
            if d > worst then worst = d end
        end
        check(name, worst <= 1 and differ <= 30 and ca > 0 and cb > 0, differ .. ' words differ, worst ' .. worst .. ', changed ' .. tostring(ca) .. ' / ' .. tostring(cb))
    end
    local dabs = { { 100.3, 100.6 }, { 108, 104.25 }, { 106.5, 112 } }
    local hasNative = rawget(_G, 'ed_terrain_brush') ~= nil
    local terraceSetup = function() T.Brush.terraceStep = 4 end
    local lua1, c1 = Run('terrace', false, terraceSetup, dabs)
    if hasNative then
        local nat1, n1 = Run('terrace', true, terraceSetup, dabs)
        Compare('native terrace dab = the Lua loop', lua1, c1, nat1, n1)
    else
        skip('native terrace dab = the Lua loop (no ed_terrain_brush)')
    end
    -- strong strength: the centre of a hard brush sits on a multiple of the step (4 units = 512 words)
    Roll()
    T.ClearHistory()
    T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff, T.Brush.terraceStep = 'terrace', 10, 6, 0.2, 4
    T.NativeBrush = true
    local tbase = T.Checksum(60, 60, 160, 160)
    T.BeginStroke()
    T.Dab(110, 110)
    T.EndStroke()
    local centre = ed_terrain_get(110, 110) * 128           -- (ed_terrain_get answers in world units)
    local step = 4 * 128
    check('a strong terrace dab leaves the centre on a step', math.abs(centre - math.floor(centre / step + 0.5) * step) <= 1, tostring(centre))
    local after = T.Checksum(60, 60, 160, 160)
    check('terrace changed the ground', after ~= tbase)
    check('undo of the terrace stroke restores the checksum', T.Undo() and T.Checksum(60, 60, 160, 160) == tbase)
    check('redo of the terrace stroke restores it', T.Redo() and T.Checksum(60, 60, 160, 160) == after)

    -- ---- plane: three points, the native dab and the Lua loop, symmetry images ------------------------------------------------------------------------------------
    T.PlaneClear()
    Roll()
    ed_terrain_set_rect(80, 80, 80, 80, 20)
    ed_terrain_set_rect(140, 80, 140, 80, 32)
    ed_terrain_set_rect(80, 140, 80, 140, 44)
    T.ClearHistory()
    check('no points: no plane', T.PlaneFor(1) == nil)
    check('first point', T.PlaneAddPoint(80, 80) == 1)
    check('second point', T.PlaneAddPoint(140, 80) == 2)
    check('third point', T.PlaneAddPoint(80, 140) == 3)
    local px, pz, pc = T.PlaneFor(1)
    -- heights 20, 32, 44 units over 60 samples: 0.2 units per sample in x, 0.4 in z: 25.6 and 51.2 words per sample
    check('the plane through the points', px ~= nil and math.abs(px - 12 * 128 / 60) < 0.01 and math.abs(pz - 24 * 128 / 60) < 0.01 and math.abs(px * 80 + pz * 80 + pc - 20 * 128) < 0.5,
          tostring(px) .. ' ' .. tostring(pz) .. ' ' .. tostring(pc))
    check('three points on a line have no plane', T.PlaneThrough({ x = 0, z = 0, h = 0 }, { x = 1, z = 1, h = 5 }, { x = 2, z = 2, h = 9 }) == nil)
    if rawget(_G, 'ed_plane_through') then
        local a, b, c = ed_plane_through(80, 20 * 128, 80, 140, 32 * 128, 80, 80, 44 * 128, 140)
        check('ed_plane_through = the plane of the points', a ~= nil and math.abs(a - px) < 1e-6 and math.abs(b - pz) < 1e-6 and math.abs(c - pc) < 1e-3)
    else
        skip('ed_plane_through (no native)')
    end

    local planeSetup = function() end
    local planeDabs = { { 100.3, 100.6 }, { 108, 104.25 }, { 106.5, 112 } }
    local keep = {}
    for i = 1, 3 do keep[i] = T.Brush.planePoints[i] end
    local luaP, cl = Run('plane', false, planeSetup, planeDabs)
    if hasNative then
        local natP, cn = Run('plane', true, planeSetup, planeDabs)
        Compare('native plane dab = the Lua loop', luaP, cl, natP, cn)
    else
        skip('native plane dab = the Lua loop (no ed_terrain_brush)')
    end
    -- a strong dab puts the middle on the plane
    Roll()
    ed_terrain_set_rect(80, 80, 80, 80, 20)
    ed_terrain_set_rect(140, 80, 140, 80, 32)
    ed_terrain_set_rect(80, 140, 80, 140, 44)
    T.ClearHistory()
    T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff = 'plane', 10, 6, 0.2
    T.NativeBrush = true
    local base = T.Checksum(60, 60, 160, 160)
    T.BeginStroke()
    T.Dab(110, 110)
    T.EndStroke()
    local want = px * 110 + pz * 110 + pc
    check('a strong plane dab leaves the centre on the plane', math.abs(ed_terrain_get(110, 110) * 128 - want) <= 1, tostring(ed_terrain_get(110, 110) * 128) .. ' vs ' .. tostring(want))
    check('plane undo restores the checksum', T.Undo() and T.Checksum(60, 60, 160, 160) == base)
    T.Redo()
    T.Undo()

    -- symmetry: the mirror image of a dab follows the plane through the mirrored points
    Symmetry.Mode = 'mirror_x'
    Symmetry.CenterX, Symmetry.CenterZ = 110, 110
    local sx2, sz2, sc2 = T.PlaneFor(2)
    check('the second image has its own plane', sx2 ~= nil and math.abs(sx2 + px) < 0.01 and math.abs(sz2 - pz) < 0.01, tostring(sx2))
    T.BeginStroke()
    T.Dab(95, 110)
    T.EndStroke()
    check('symmetric plane dab: the image centre is on its plane', math.abs(ed_terrain_get(125, 110) * 128 - (sx2 * 125 + sz2 * 110 + sc2)) <= 1,
          tostring(ed_terrain_get(125, 110) * 128) .. ' vs ' .. tostring(sx2 * 125 + sz2 * 110 + sc2))
    Symmetry.Mode = 'off'
    Symmetry.CenterX, Symmetry.CenterZ = false, false
    T.Undo()
    T.PlaneClear()
    check('clear points', table.getn(T.Brush.planePoints) == 0 and T.PlaneFor(1) == nil)

    -- ---- Lua syntax check ---------------------------------------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_up_check_lua') then
        local Script = import('/lua/editor/scriptcheck.lua')
        local ok = Script.CheckText('local a = 1\nreturn a\n', 'good_script.lua')
        check('a good script compiles', ok and ok.ok == true)
        local bad = Script.CheckText('local a = 1\nb = = 2\nreturn a\n', 'bad_script.lua')
        check('a syntax error is found with its line', bad and bad.ok == false and bad.line == 2 and type(bad.message) == 'string' and bad.message ~= '', bad and (tostring(bad.line) .. ' ' .. tostring(bad.raw)))
        local last = Script.CheckText('function F()\n  return 1\n', 'open_script.lua')
        check('an unclosed function is reported', last and last.ok == false and last.line ~= nil, last and tostring(last.raw))
        local line, msg = ed_up_parse_lua_error('x_script.lua(12): unexpected symbol near `end\'')
        check('parse: name(12): message', line == 12 and msg ~= nil and string.find(msg, 'unexpected symbol', 1, true) ~= nil, tostring(line) .. ' ' .. tostring(msg))
        line, msg = ed_up_parse_lua_error('[string "x"]:7: \'=\' expected near \'end\'')
        check('parse: [string "x"]:7: message', line == 7, tostring(line))
        check('parse: no line', ed_up_parse_lua_error('something went wrong') == nil)

        -- the validation lists a broken script of the map: the scripts are read from their files, so one is pointed at a broken temporary file
        local tmp = 'ed_selftest_wp7_script.lua'
        if ed_write_file(tmp, 'local ScenarioUtils = import(\'/lua/sim/ScenarioUtilities.lua\')\nfunction OnPopulate()\n    x = = 1\nend\n') then
            local orig = Script.Scripts
            Script.Scripts = function() return { { file = 'demo_script.lua', vfs = '/maps/demo/demo_script.lua', disk = tmp } } end
            local found = Script.Check()
            local issues = import('/lua/editor/validate.lua').MapIssues()
            Script.Scripts = orig
            check('Check() names the file and the line', found and found[1] and found[1].file == 'demo_script.lua' and found[1].line == 3, found and found[1] and tostring(found[1].text))
            local seen = false
            for _, i in issues do
                if i.kind == 'script' and string.find(i.text, 'demo_script.lua:3', 1, true) then seen = true end
            end
            check('the validation lists the script error with its line', seen)
        else
            skip('validation lists a broken script (cannot write a temporary file)')
        end
        local real = Script.Check()
        check('the open map\'s scripts are checked', type(real) == 'table')
    else
        skip('Lua syntax check (no ed_up_check_lua)')
    end

    -- ---- prop symmetry --------------------------------------------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_up_check_props') then
        local size = 256
        local cx = size / 2
        local balanced = { { '/env/rock1.bp', 50, 60, 10 }, { '/env/rock1.bp', size - 50, 60, 10 }, { '/env/tree.bp', 70, 90, 5 }, { '/env/tree.bp', size - 70, 90, 5 } }
        local r = MC.PropSymmetry(balanced, 'mirror_x', cx, cx)
        check('a symmetric prop set has no findings', r and table.getn(r) == 0, r and tostring(table.getn(r)))
        local odd = { { '/env/rock1.bp', 50, 60, 10 }, { '/env/rock1.bp', size - 50, 60, 10 }, { '/env/tree.bp', 70, 90, 500 } }
        r = MC.PropSymmetry(odd, 'mirror_x', cx, cx)
        check('a prop without its partner is listed', r and table.getn(r) == 2 and r[1].sev == 'W' and string.find(r[2].text, 'tree.bp', 1, true) ~= nil and math.abs(r[2].x - 70) < 0.01,
              r and r[2] and r[2].text)
        local noMass = { { '/env/rock1.bp', 50, 60, 0 } }
        r = MC.PropSymmetry(noMass, 'mirror_x', cx, cx)
        check('without reclaim mass the summary is a note', r and r[1] and r[1].sev == 'I', r and r[1] and r[1].sev)
        r = MC.PropSymmetry(odd, 'off', cx, cx)
        check('symmetry off: no check', r and table.getn(r) == 0)
        r = MC.PropSymmetry({ { '/env/rock1.bp', 50, 60, 10 }, { '/env/rock1.bp', 206, 196, 10 } }, 'rot2', cx, cx)
        check('rot2 matches the turned copy', r and table.getn(r) == 0, r and r[1] and r[1].text)
        r = MC.PropSymmetry({ { '/env/rock1.bp', 50, 60, 10 } }, 'rot4', cx, cx + 10)
        check('a square-only mode with the centre off the diagonal is skipped', r and table.getn(r) == 0)

        -- through the document: two real props, one without a partner
        local Map = import('/lua/editor/map.lua')
        local bp
        for _, f in (DiskFindFiles('/env/common/props', '*.bp') or {}) do
            if not bp and not string.find(f, 'markers', 1, true) then bp = f end
        end
        if bp and Map.AddProp then
            Symmetry.Mode = 'mirror_x'
            Symmetry.CenterX, Symmetry.CenterZ = false, false
            local mx = (w - 1) / 2
            local i1 = Map.AddProp(bp, mx - 40, 25, 100, 0)
            local i2 = Map.AddProp(bp, mx - 41, 25, 130, 0)
            local i3 = Map.AddProp(bp, mx + 40, 25, 100, 0)
            local issues = import('/lua/editor/validate.lua').MapIssues()
            local found = false
            for _, i in issues do
                if i.kind == 'propsym' and string.find(i.text, 'no partner', 1, true) and math.abs((i.x or 0) - (mx - 41)) < 1.5 then found = true end
            end
            check('the validation shows a prop without its symmetric partner', found)
            -- remove the test props again (highest index first)
            local ids = { i1, i2, i3 }
            table.sort(ids, function(a, b) return a > b end)
            for _, id in ids do Map.RemoveProp(id) end
            Symmetry.Mode = 'off'
        else
            skip('props through the document (no prop blueprint found)')
        end
    else
        skip('prop symmetry (no ed_up_check_props)')
    end

    -- put everything back
    T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff, T.Brush.level = saved.mode, saved.radius, saved.strength, saved.falloff, saved.level
    T.Brush.terraceStep, T.Brush.planePoints, T.NativeBrush = saved.terraceStep, saved.points, saved.native
    Symmetry.Mode, Symmetry.Manual = saved.symMode, saved.symManual
    Symmetry.CenterX, Symmetry.CenterZ = false, false
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    T.ClearHistory()
    T.PlaneClear()

    local head = 'PASS'
    if table.getn(failures) > 0 then head = 'FAIL (' .. table.getn(failures) .. ')' end
    return head .. '\n' .. table.concat(lines, '\n')
end
