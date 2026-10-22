-- The unit viewer's path with fake natives (no sim, no renderer needed): Show unit -> SimCallback EdViewSpawn -> the sim's answer file -> entity id -> camera framing -> the camera lock
-- every frame, and what the viewer reports when something fails. Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_unitview2.lua').Run()
-- Checks: the spawn callback carries the blueprint, army, position and answer path; the entity id of the answer is taken; every camera preset is framed with a heading in -pi .. pi; the lock
-- puts the camera back on every frame (Tick, also through camera.lua Update, which does not depend on the overlay), not twice in one frame, and not when Lock is off; a sim error and a missing
-- answer are logged ('EDITOR unitview: ...') and kept in LastError while the camera is still held; a failing camera query is logged and does not throw; viewer units are skipped by the quiet
-- of editorsim/peace.lua. The globals the viewer calls are replaced for the length of the run and put back afterwards (the run never waits, so nothing else runs in between).

local View = import('/lua/editor/unitview.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local FAKES = { 'GetCamera', 'SimCallback', 'ed_write_file', 'ed_read_file', 'ed_camera_info', 'ed_terrain_info', 'ed_terrain_get', 'ed_unit_bones', 'ConExecute', 'ForkThread',
                'WaitSeconds', 'WaitTicks', 'GetSystemTimeSeconds', 'Vector', 'ed_overlay_set', 'ed_overlay_remove', 'LOG' }

local function Dist(a, b)
    return math.sqrt((a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]) + (a[3] - b[3]) * (a[3] - b[3]))
end

function Run()
    out, failed = {}, 0

    local clock = 100
    local cam = { focus = { 0, 0, 0 }, heading = 0, pitch = 1, zoom = 30, snaps = 0 }
    local files = {}
    local calls = {}
    local logs = {}
    local answer = 'ok'            -- what the fake sim answers to EdViewSpawn: 'ok' | 'error' | 'silent'
    local cameraBroken = false

    local camObj = {
        SnapTo = function(self, v, o, z) cam.focus = { v[1], v[2], v[3] } cam.heading, cam.pitch, cam.zoom = o[1], o[2], z cam.snaps = cam.snaps + 1 end,
        SaveSettings = function(self) return { Focus = cam.focus, Heading = cam.heading, Pitch = cam.pitch, Zoom = cam.zoom } end,
        RestoreSettings = function(self, s) end,
        GetTargetZoom = function(self) return cam.zoom end,
        GetZoom = function(self) return cam.zoom end,
        GetMinZoom = function(self) return 1 end,
        GetMaxZoom = function(self) return 1000 end,
    }
    local fake = {
        GetCamera = function(name) return camObj end,
        SimCallback = function(msg, flag)
            table.insert(calls, msg)
            if msg.Func == 'EdViewSpawn' then
                local a = msg.Args
                if answer == 'ok' then
                    files[a.path] = string.format('id 4242\npos %.3f %.3f %.3f\next %.3f %.3f %.3f %.3f %.3f %.3f\n', a.x, a.y, a.z, a.x - 1, a.y, a.z - 2, a.x + 1, a.y + 3, a.z + 2)
                elseif answer == 'error' then
                    files[a.path] = 'error boom: the army has no brain\n'
                end
            end
        end,
        ed_write_file = function(path, text) files[path] = text return true end,
        ed_read_file = function(path) return files[path] end,
        ed_camera_info = function()
            if cameraBroken then error('camera query broke') end
            return 0.6, cam.zoom, cam.focus[1], cam.focus[2], cam.focus[3], cam.heading, cam.pitch, cam.zoom, 0, 0, 1000, 800
        end,
        ed_terrain_info = function() return 513 end,
        ed_terrain_get = function(x, z) return 5 end,
        ed_unit_bones = function(id) return {} end,
        ConExecute = function(text) table.insert(calls, { console = text }) end,
        ForkThread = function(fn) fn() return {} end,          -- (the thread runs at once; its waits only move the clock)
        WaitSeconds = function(s) clock = clock + (s or 0) end,
        WaitTicks = function(t) clock = clock + (t or 0) * 0.1 end,
        GetSystemTimeSeconds = function() return clock end,
        Vector = function(x, y, z) return { x, y, z, type = 'VECTOR3' } end,
        ed_overlay_set = function() end,
        ed_overlay_remove = function() end,
        LOG = function(...) table.insert(logs, table.concat(arg, ' ')) end,
    }
    local saved = {}
    for _, name in FAKES do saved[name] = rawget(_G, name) end

    local oldBlueprints = rawget(_G, '__blueprints')
    local fakeBp = { BlueprintId = 'zzview01', SizeX = 2, SizeY = 3, SizeZ = 4, Footprint = {}, Physics = { MotionType = 'RULEUMT_Land' }, Categories = { 'LAND' }, Weapon = {}, Display = {} }
    local bps = oldBlueprints or {}
    if not oldBlueprints then rawset(_G, '__blueprints', bps) end
    local hadBp = bps.zzview01
    bps.zzview01 = fakeBp

    local lockWas = View.Show.lock
    local stageWas = View.Stage

    local ok, err = pcall(function()
        for _, name in FAKES do rawset(_G, name, fake[name]) end
        View.Show.lock = true
        View.SetStage('viewer')
        View.Close()
        calls, logs = {}, {}

        -- the unit is not in the blueprints: no callback, a reason
        local good, why = View.Spawn('zzview_nothing')
        Ok(good == nil and type(why) == 'string', 'an unknown unit is refused with a reason')
        Ok(View.LastError ~= false and string.find(View.LastError, 'zzview_nothing', 1, true) ~= nil, 'and LastError says which unit')

        -- 1. the normal path
        answer = 'ok'
        clock = clock + 10
        calls, logs = {}, {}
        good = View.Spawn('zzview01')
        Ok(good == true, 'Spawn accepts a known unit')
        local spawn
        for _, c in calls do if c.Func == 'EdViewSpawn' then spawn = c end end
        Ok(spawn ~= nil, 'the viewer calls the sim callback EdViewSpawn')
        if spawn then
            local a = spawn.Args
            Ok(a.bp == 'zzview01' and a.army == 'ARMY_1' and type(a.x) == 'number' and type(a.z) == 'number' and type(a.y) == 'number' and type(a.path) == 'string' and a.path ~= '',
               'the callback carries blueprint, army, position and the answer path')
        end
        local stageOff = false
        for _, c in calls do if c.console and string.find(c.console, 'ren_Terrain false', 1, true) then stageOff = true end end
        Ok(stageOff, 'the viewer stage switches the terrain off')
        Ok(View.Id == 'zzview01' and View.EntityId == 4242, 'the entity id of the sim\'s answer is taken (' .. tostring(View.EntityId) .. ')')
        Ok(View.LastError == false, 'no error is reported when the sim answers')
        Ok(cam.snaps > 0, 'the camera is framed on the unit (' .. cam.snaps .. ' SnapTo calls)')
        Ok(cam.heading <= 3.1415927 and cam.heading > -3.1415927, 'the heading of the framing is within -pi .. pi (' .. string.format('%.3f', cam.heading) .. ')')

        -- 2. every preset keeps the heading in range
        for _, mode in { 'iso', 'front', 'side', 'back', 'top' } do
            View.Frame(mode)
            Ok(cam.heading <= 3.1415927 and cam.heading > -3.1415927, mode .. ': heading ' .. string.format('%.3f', cam.heading) .. ' is within -pi .. pi')
        end
        View.Orbit(7, 0)
        Ok(cam.heading <= 3.1415927 and cam.heading > -3.1415927 and View.Heading <= 3.1415927 and View.Heading > -3.1415927, 'orbiting by more than a turn stays within -pi .. pi')

        -- 3. the lock: the camera goes back to the unit on every frame
        clock = clock + 2
        local held = { cam.focus[1], cam.focus[2], cam.focus[3] }
        for frame = 1, 3 do
            cam.focus = { cam.focus[1] + 40, cam.focus[2], cam.focus[3] - 25 }          -- the user pans away
            local panned = { cam.focus[1], cam.focus[2], cam.focus[3] }
            clock = clock + 0.016
            local before = cam.snaps
            View.Tick()
            Ok(cam.snaps == before + 1, 'frame ' .. frame .. ': the lock sets the camera (SnapTo called)')
            Ok(Dist(cam.focus, held) < Dist(panned, held) / 2, 'frame ' .. frame .. ': the focus is back near the unit (' .. string.format('%.1f', Dist(cam.focus, held)) .. ' off, was ' .. string.format('%.1f', Dist(panned, held)) .. ')')
            held = { cam.focus[1], cam.focus[2], cam.focus[3] }
        end
        -- not twice in one frame
        clock = clock + 0.016
        cam.focus = { cam.focus[1] + 30, cam.focus[2], cam.focus[3] }
        local before = cam.snaps
        View.Tick()
        View.Tick()
        Ok(cam.snaps == before + 1, 'a second Tick in the same instant does nothing (one SnapTo for two calls)')
        -- the shell's tick: camera.lua Update runs the lock (it does not depend on the overlay)
        clock = clock + 0.016
        cam.focus = { cam.focus[1] + 30, cam.focus[2], cam.focus[3] }
        before = cam.snaps
        import('/lua/editor/camera.lua').Update({ order = {}, registry = {} })
        Ok(cam.snaps == before + 1, 'camera.lua Update holds the camera on the unit')
        -- the overlay's per-frame call locks too (bones are drawn there)
        cam.focus = { cam.focus[1] + 30, cam.focus[2], cam.focus[3] }
        clock = clock + 0.016
        before = cam.snaps
        View.OnFrame()
        Ok(cam.snaps == before + 1, 'overlay OnFrame holds the camera on the unit as well')
        -- Lock off: free camera
        View.Show.lock = false
        cam.focus = { cam.focus[1] + 30, cam.focus[2], cam.focus[3] }
        clock = clock + 0.016
        before = cam.snaps
        View.Tick()
        Ok(cam.snaps == before, 'with Lock off the camera is left alone')
        View.Show.lock = true

        -- 4. a failing camera query is logged and does not throw
        logs = {}
        clock = clock + 10
        cameraBroken = true
        local okTick = pcall(View.Tick)
        cameraBroken = false
        local logged = false
        for _, l in logs do if string.find(l, 'EDITOR unitview:', 1, true) and string.find(l, 'LockCamera failed', 1, true) then logged = true end end
        Ok(okTick and logged, 'a failure of the lock is logged with the EDITOR unitview: prefix and does not throw')
        logs = {}
        clock = clock + 0.1
        cameraBroken = true
        View.Tick()
        clock = clock + 0.1
        View.Tick()
        cameraBroken = false
        Ok(table.getn(logs) <= 1, 'and the log is rate limited (' .. table.getn(logs) .. ' lines for repeated failures)')

        -- 5. the sim cannot make the unit
        answer = 'error'
        clock = clock + 10
        calls, logs = {}, {}
        View.Spawn('zzview01')
        Ok(View.LastError ~= false and string.find(View.LastError, 'boom', 1, true) ~= nil, 'the sim\'s error text is kept in LastError')
        local errLogged = false
        for _, l in logs do if string.find(l, 'EDITOR unitview:', 1, true) and string.find(l, 'boom', 1, true) then errLogged = true end end
        Ok(errLogged, 'and logged')
        Ok(View.EntityId == false, 'no entity id without a unit')
        clock = clock + 2
        cam.focus = { cam.focus[1] + 40, cam.focus[2], cam.focus[3] }
        before = cam.snaps
        View.Tick()
        Ok(cam.snaps == before + 1, 'the camera is still held on the stage')

        -- 6. the sim does not answer
        answer = 'silent'
        clock = clock + 10
        calls, logs = {}, {}
        View.Spawn('zzview01')
        Ok(View.LastError ~= false and string.find(View.LastError, 'did not answer', 1, true) ~= nil, 'a missing answer is reported')
        local silentLogged = false
        for _, l in logs do if string.find(l, 'EDITOR unitview:', 1, true) and string.find(l, 'did not answer', 1, true) then silentLogged = true end end
        Ok(silentLogged, 'and logged')
        clock = clock + 2
        cam.focus = { cam.focus[1] + 40, cam.focus[2], cam.focus[3] }
        before = cam.snaps
        View.Tick()
        Ok(cam.snaps == before + 1, 'the lock does not wait for the sim\'s answer')

        -- 7. Remove takes it all down
        View.Remove()
        Ok(View.Id == false and View.EntityId == false and View.LastError == false, 'Remove forgets the unit and the error')
        clock = clock + 1
        cam.focus = { cam.focus[1] + 40, cam.focus[2], cam.focus[3] }
        before = cam.snaps
        View.Tick()
        Ok(cam.snaps == before, 'and the camera is free again')

        -- 8. editing is quiet: the viewer's unit keeps its fire state, an ordinary unit is held
        local Peace = import('/lua/editorsim/peace.lua')
        Peace.Reset()
        local function Unit(flag)
            local u = { Dead = false, state = 0, EdViewUnit = flag }
            u.GetFireState = function(self) return self.state end
            u.SetFireState = function(self, n) self.state = n end
            return u
        end
        local viewUnit, mapUnit = Unit(true), Unit(false)
        Peace.UseApi({ armies = function() return { 1, 2 } end, relation = function(a, b) return 'Enemy' end, set = function() end, units = function() return { viewUnit, mapUnit } end })
        Peace.Enter()
        Ok(viewUnit.state == 0 and not viewUnit.EdHeld, 'peace.lua skips the viewer\'s unit')
        Ok(mapUnit.state == 1, 'and holds an ordinary unit')
        Peace.Restore()
        Peace.UseApi(nil)
        Peace.Reset()
    end)
    if not ok then Ok(false, 'the run stopped with an error: ' .. tostring(err)) end

    -- put everything back
    pcall(View.Close)
    for _, name in FAKES do rawset(_G, name, saved[name]) end
    bps.zzview01 = hadBp
    if not oldBlueprints then rawset(_G, '__blueprints', nil) end
    View.Show.lock = lockWas
    if stageWas and View.Stage ~= stageWas then pcall(View.SetStage, stageWas) end

    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end
