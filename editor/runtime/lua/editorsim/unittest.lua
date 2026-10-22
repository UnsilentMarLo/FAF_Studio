-- Editor sim callbacks of the "Test in game" flow (unittest.lua in the editor, panel "Unit wizard"). Loaded by the loader at the end of schook/lua/simcallbacks.lua.
--
--   EdTestSpawn    makes the unit under test (not protected, unlike the unit viewer's) with dummy targets ahead of it, fills the army's storage, writes the status file
--   EdTestCommand  quick commands: attack (the dummy targets), move, patrol, stop, kill, heal, build (a factory / engineer of the game builds the unit: proves the build menu entry), clear
--   EdTestStatus   writes the status file: the unit's health and position, its order queue, the dummy targets' health and the damage dealt so far
--
-- The dummy targets belong to a second army, UNIT_TEST_TARGETS, which the editor adds to the map for the test (unittest.lua, Begin) and takes out again at the end of the test; it is an
-- enemy of ARMY_1, so the unit under test shoots at them by itself. Without that army (an older map document) the targets are ARMY_1's own and the `attack` command cannot order anything.
--
-- Status file: key value lines: unit <alive 0|1> <health> <max>, pos x z, orders n, target <i> <health> <max>, damage <total>, built <n>, ticks <n>, error <text>.
function Register(Callbacks)
    local function Alive(u) return u and not u.Dead and not u:BeenDestroyed() end

    local function State()
        ScenarioInfo.EdTest = ScenarioInfo.EdTest or { targets = {}, extras = {}, damage0 = 0 }
        return ScenarioInfo.EdTest
    end

    local function Kill(u)
        if Alive(u) then
            pcall(function() u:SetCanBeKilled(true) end)
            pcall(function() u:Destroy() end)
        end
    end

    local function Clear()
        local s = ScenarioInfo.EdTest
        if not s then return end
        Kill(s.unit)
        for _, t in s.targets do Kill(t) end
        for _, e in s.extras do Kill(e) end
        if s.fight then pcall(function() import('/lua/editorsim/peace.lua').Unfight(s.fight[1], s.fight[2]) end) end
        ScenarioInfo.EdTest = nil
    end

    local function Status(path)
        local s = ScenarioInfo.EdTest
        local lines = {}
        if not s then
            table.insert(lines, 'none')
        else
            local u = s.unit
            if Alive(u) then
                local p = u:GetPosition()
                table.insert(lines, string.format('unit 1 %.1f %.1f', u:GetHealth(), u:GetMaxHealth()))
                table.insert(lines, string.format('pos %.1f %.1f', p[1], p[3]))
                local ok, q = pcall(function() return u:GetCommandQueue() end)
                table.insert(lines, 'orders ' .. tostring(ok and q and table.getn(q) or 0))
            else
                table.insert(lines, 'unit 0 0 0')
            end
            local dealt = 0
            for i, t in s.targets do
                if Alive(t) then
                    local h, m = t:GetHealth(), t:GetMaxHealth()
                    table.insert(lines, string.format('target %d %.1f %.1f', i, h, m))
                    dealt = dealt + (m - h)
                else
                    table.insert(lines, string.format('target %d 0 %.1f', i, s.targetHealth or 0))
                    dealt = dealt + (s.targetHealth or 0)
                end
            end
            table.insert(lines, string.format('damage %.1f', dealt))
            local built = 0
            if s.builtBp and s.builtBefore then
                local u0 = s.unit
                local pos = Alive(u0) and u0:GetPosition() or { s.x, 0, s.z }
                for _, e in GetUnitsInRect(Rect(s.x - 80, s.z - 80, s.x + 80, s.z + 80)) or {} do
                    if Alive(e) and e:GetBlueprint().BlueprintId == s.builtBp and e ~= s.unit and e:GetFractionComplete() >= 1 then built = built + 1 end
                end
            end
            table.insert(lines, 'built ' .. tostring(built))
            local okb, brain = pcall(function() return GetArmyBrain('ARMY_1') end)
            if okb and brain then
                local okm, m = pcall(function() return brain:GetEconomyStored('MASS') end)
                local oke, e = pcall(function() return brain:GetEconomyStored('ENERGY') end)
                table.insert(lines, string.format('eco %.0f %.0f', okm and m or -1, oke and e or -1))
            end
            if s.builder and Alive(s.builder) then
                local okp, frac = pcall(function() return s.builder:GetWorkProgress() end)
                local okq, q = pcall(function() return s.builder:GetCommandQueue() end)
                table.insert(lines, string.format('builder %.2f orders %d', okp and frac or -1, okq and q and table.getn(q) or -1))
            end
            table.insert(lines, 'ticks ' .. tostring(GetGameTick()))
            if s.err then table.insert(lines, 'error ' .. tostring(s.err)) end
        end
        ed_write_file(path, table.concat(lines, '\n') .. '\n')
    end

    --- Storage first, then the resources: the stock only fills up to the storage the army has, and the storage counts from the next tick.
    local function Feed()
        local ok, brain = pcall(function() return GetArmyBrain('ARMY_1') end)
        if not (ok and brain) then return end
        pcall(function() brain:GiveStorage('Mass', 100000) end)
        pcall(function() brain:GiveStorage('Energy', 400000) end)
        ForkThread(function()
            WaitTicks(3)
            pcall(function() brain:GiveResource('Mass', 100000) end)
            pcall(function() brain:GiveResource('Energy', 400000) end)
        end)
    end

    local function Make(bp, x, z, heading, army)
        local y = GetTerrainHeight(x, z)
        army = army or 'ARMY_1'
        local ok, unit = pcall(function() return CreateUnitHPR(bp, army, x, y, z, 0, heading or 0, 0) end)
        if not ok or not unit then return nil, tostring(unit) end
        unit.EdLab = true      -- the lab's units fight while the map is edited: editorsim/peace.lua leaves them off hold fire
        return unit
    end

    Callbacks.EdTestSpawn = function(data)
        Clear()
        local s = State()
        s.x, s.z = data.x, data.z
        Feed()
        local unit, why = Make(data.bp, data.x, data.z, data.heading or 0)
        if not unit then
            s.err = 'cannot make ' .. tostring(data.bp) .. ': ' .. tostring(why)
            Status(data.path)
            return
        end
        s.unit = unit
        local n = data.targets or 2
        local dist = data.distance or 30
        s.targetHealth = 20000
        for i = 1, n do
            local tx = data.x + 8 * (i - (n + 1) / 2)
            local tz = data.z + dist
            local t = Make(data.targetBp or 'uel0106', tx, tz, 3.14159, data.targetArmy)
            if not t and data.targetArmy then
                s.err = 'the target army ' .. tostring(data.targetArmy) .. ' is not in the session: the targets are ARMY_1\'s own'
                t = Make(data.targetBp or 'uel0106', tx, tz, 3.14159, 'ARMY_1')
            end
            if t then
                pcall(function() t:SetMaxHealth(s.targetHealth) end)
                pcall(function() t:SetHealth(t, s.targetHealth) end)
                pcall(function() t:SetImmobile(true) end)
                -- a dummy does not shoot back
                pcall(function()
                    for i = 1, t:GetWeaponCount() do t:GetWeapon(i):SetEnabled(false) end
                end)
                pcall(function() t:SetReclaimable(false) end)
                pcall(function() t:SetCapturable(false) end)
                if data.targetAir then pcall(function() t:SetCanTakeDamage(true) end) end
                t.EdTestTarget = true
                table.insert(s.targets, t)
            end
        end
        -- editing is quiet (every army is neutral to every other, editorsim/peace.lua): the unit under test and its dummy targets are enemies for the length of the test
        if s.targets[1] then
            pcall(function()
                local a, b = unit:GetArmy(), s.targets[1]:GetArmy()
                if import('/lua/editorsim/peace.lua').Fight(a, b) then s.fight = { a, b } end
            end)
        end
        Status(data.path)
    end

    Callbacks.EdTestCommand = function(data)
        local s = ScenarioInfo.EdTest
        if not s then
            ed_write_file(data.path, 'none\n')
            return
        end
        local u = s.unit
        local cmd = data.cmd
        if cmd == 'clear' then
            Clear()
            ed_write_file(data.path, 'none\n')
            return
        end
        Feed()
        if cmd == 'attack' then
            if Alive(u) then
                IssueClearCommands({ u })
                for _, t in s.targets do
                    if Alive(t) then IssueAttack({ u }, t) end
                end
            end
        elseif cmd == 'move' then
            if Alive(u) then
                IssueClearCommands({ u })
                IssueMove({ u }, Vector(data.x, GetTerrainHeight(data.x, data.z), data.z))
            end
        elseif cmd == 'patrol' then
            if Alive(u) then
                IssueClearCommands({ u })
                IssueMove({ u }, Vector(data.x, GetTerrainHeight(data.x, data.z), data.z))
                IssueMove({ u }, Vector(data.x2, GetTerrainHeight(data.x2, data.z2), data.z2))
                IssuePatrol({ u }, Vector(data.x, GetTerrainHeight(data.x, data.z), data.z))
                IssuePatrol({ u }, Vector(data.x2, GetTerrainHeight(data.x2, data.z2), data.z2))
            end
        elseif cmd == 'stop' then
            if Alive(u) then IssueClearCommands({ u }) end
        elseif cmd == 'kill' then
            if Alive(u) then u:Kill() end
        elseif cmd == 'heal' then
            for _, e in { u, unpack(s.targets) } do
                if Alive(e) then pcall(function() e:SetHealth(e, e:GetMaxHealth()) end) end
            end
        elseif cmd == 'build' then
            -- a factory (mobile units) or an engineer (structures) of the game builds the unit under test: if the build menu entry is wrong this fails
            local builder, why = Make(data.builder, data.x - 14, data.z - 6, 0)
            if not builder then
                s.err = 'cannot make the builder ' .. tostring(data.builder) .. ': ' .. tostring(why)
            else
                table.insert(s.extras, builder)
                s.builder = builder
                s.builtBp = data.bp
                s.builtBefore = true
                s.err = nil
                IssueClearCommands({ builder })
                if data.structure then
                    IssueBuildMobile({ builder }, Vector(data.x - 14, GetTerrainHeight(data.x - 14, data.z + 10), data.z + 10), data.bp, {})
                else
                    IssueBuildFactory({ builder }, data.bp, 1)
                end
            end
        end
        Status(data.path)
    end

    Callbacks.EdTestStatus = function(data)
        Status(data.path)
    end
end
