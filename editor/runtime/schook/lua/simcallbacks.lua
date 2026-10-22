-- Editor sim callbacks (appended to /lua/simcallbacks.lua through the schook mechanism).
-- UI -> sim: SimCallback({Func = 'EdResnap', Args = {...}}). Only meaningful in an /editor session; they do
-- nothing the normal game would not allow a cheating player to do.
do
    local edProps = {}   -- key -> prop entity created by the editor

    --- Play / edit switch of the editor: a mission script that sees Options.EditorMode waits for ScenarioInfo.EditorPlaying before its first stage.
    --- While editing, a unit stands where the editor put it: it cannot move, so other units and the terrain edits cannot push it away from its gizmo, and it does not
    --- trample props. A test run lets every unit go again.
    local function FreezeUnit(u)
        if u and not u.Dead and not u.EdFrozen then
            u.EdFrozen = true
            pcall(function() u:SetImmobile(true) end)
        end
    end
    EdFreezeUnit = FreezeUnit

    Callbacks.EdSetPlay = function(data)
        ScenarioInfo.EditorPlaying = data.on and true or false
        if data.on then
            local units = GetUnitsInRect(Rect(0, 0, 100000, 100000))
            if units then
                for _, u in units do
                    if u.EdFrozen and not u.Dead then
                        u.EdFrozen = nil
                        pcall(function() u:SetImmobile(false) end)
                        -- structures get the footprint decal the editor withheld (schook/lua/sim/units/StructureUnit.lua)
                        if u.CreateTarmac and EntityCategoryContains(categories.STRUCTURE, u) then
                            pcall(function() u:CreateTarmac(true, true, true) end)
                        end
                    end
                end
            end
        end
        if data.on and ScenarioInfo.EditorGroupUnits then
            for _, u in ScenarioInfo.EditorGroupUnits do
                if u and not u.Dead then u:Destroy() end
            end
            ScenarioInfo.EditorGroupUnits = nil
        end
        if data.on then
            -- a test run starts like a game: the human army gets its commander at its start position (the game's own CreateInitialArmyGroup does that; the editor
            -- world has none while editing, schook/lua/sim/scenarioutilities.lua). Armies that already have one (a mission map's INITIAL group) are left alone.
            pcall(function()
                local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
                for _, brain in ArmyBrains do
                    if brain.BrainType == 'Human' then
                        local name = brain.Name
                        local have = brain:GetListOfUnits(categories.COMMAND, false)
                        if (not have or table.getn(have) == 0) and ScenarioUtils.GetMarker(name) then
                            local faction = import('/lua/factions.lua').Factions[brain:GetFactionIndex()]
                            local cdr = CreateInitialArmyUnit(name, faction.InitialUnit)      -- (engine global: the unit at the army's start marker)
                            if cdr and cdr.RotateTowardsMid then cdr:RotateTowardsMid() end
                            ScenarioInfo.EditorACU = cdr
                        end
                        break
                    end
                end
            end)
        end
    end

    --- Puts every unit / prop in a rectangle back on the (edited) terrain.
    Callbacks.EdResnap = function(data)
        local x0 = math.min(data.x0, data.x1)
        local x1 = math.max(data.x0, data.x1)
        local z0 = math.min(data.z0, data.z1)
        local z1 = math.max(data.z0, data.z1)
        local rect = Rect(x0, z0, x1, z1)

        -- height edits are queued by the UI thread and applied between beats: make sure this callback sees them
        ed_sim_apply_pending()

        -- the pathfinder caches clusters of walkable cells: tell it the heights changed here (first, so the
        -- units moved below already see the new paths)
        if not data.noDirty then
            ed_sim_terrain_changed(x0, z0, x1, z1)
        end

        local units = GetUnitsInRect(rect)
        if units then
            for _, u in units do
                if not u.Dead then
                    local p = u:GetPosition()
                    local y = GetTerrainHeight(p[1], p[3])
                    if math.abs(y - p[2]) > 0.01 then
                        Warp(u, Vector(p[1], y, p[3]))
                    end
                end
            end
        end

        -- the UI says when the map has no props at all (ed_prop_count() == 0, sim.lua): then the rectangle is not searched
        local props = (not data.noProps) and GetReclaimablesInRect(rect) or nil
        if props then
            for _, e in props do
                if e and not e:BeenDestroyed() then
                    local p = e:GetPosition()
                    local y = GetTerrainHeight(p[1], p[3])
                    if math.abs(y - p[2]) > 0.01 then
                        e:SetPosition(Vector(p[1], y, p[3]), true)
                    end
                end
            end
        end
    end

    -- The record's scale multiplies the draw scale the blueprint gives the prop (Display.UniformScale), like the
    -- engine does for the props a map loads. 1,1,1 and lanes that are not positive (or above 1000) change nothing.
    local function ApplyPropScale(prop, sx, sy, sz)
        local base = 1
        local bp = prop:GetBlueprint()
        if bp and bp.Display and bp.Display.UniformScale then
            base = bp.Display.UniformScale
        end
        sx, sy, sz = sx or 1, sy or 1, sz or 1
        local usable = sx > 0 and sy > 0 and sz > 0 and sx <= 1000 and sy <= 1000 and sz <= 1000
        if not usable then
            sx, sy, sz = 1, 1, 1
        end
        prop:SetScale(base * sx, base * sy, base * sz)
    end

    Callbacks.EdSpawnProp = function(data)
        local y = data.y
        if not y then
            y = GetTerrainHeight(data.x, data.z)
        end
        local prop = CreateProp(Vector(data.x, y, data.z), data.bp)
        if prop then
            if data.heading and data.heading ~= 0 then
                -- a rotation about the up axis, the same quaternion the map record keeps (x, y, z, w). EulerToQuaternion(heading, 0, 0)
                -- turned the prop about its x axis onto its side, so the props of a brush with random heading sank into the ground
                prop:SetOrientation(Quaternion(0, math.sin(data.heading * 0.5), 0, math.cos(data.heading * 0.5)), true)
            end
            ApplyPropScale(prop, data.sx, data.sy, data.sz)
            edProps[data.key] = prop
        end
    end

    local function NearestProp(data)
        local best, bestDistance = nil, 1.5
        local props = GetReclaimablesInRect(Rect(data.x - 2, data.z - 2, data.x + 2, data.z + 2))
        if props then
            for _, e in props do
                if e and not e:BeenDestroyed() then
                    local p = e:GetPosition()
                    local d = math.sqrt((p[1] - data.x) * (p[1] - data.x) + (p[3] - data.z) * (p[3] - data.z))
                    if d < bestDistance then
                        best, bestDistance = e, d
                    end
                end
            end
        end
        return best
    end

    --- Removes a prop entity: one the editor created (by key), else the nearest one of that blueprint.
    Callbacks.EdRemovePropAt = function(data)
        local best = NearestProp(data)
        if best then
            best:Destroy()
        end
    end

    --- Rescales the prop entity standing at (x, z).
    Callbacks.EdScalePropAt = function(data)
        local best = NearestProp(data)
        if best then
            ApplyPropScale(best, data.sx, data.sy, data.sz)
        end
    end
    --- Test / tooling helper: creates one unit.
    Callbacks.EdSpawnUnit = function(data)
        local army = data.army or 'ARMY_1'
        local y = data.y or GetTerrainHeight(data.x, data.z)
        -- an army that was added after the sim started has no brain yet: the unit appears after the map is saved and reopened
        local ok, unit = pcall(function() return CreateUnitHPR(data.bp, army, data.x, y, data.z, 0, data.heading or 0, 0) end)
        if ok and unit then FreezeUnit(unit) end
        if ok and unit and data.group == '_view' then unit.EdViewUnit = true end      -- the unit viewer's own units (EdClearLab takes them down)
        -- units of the mission's own groups are shown while editing only: the script spawns them when the mission plays
        if ok and unit and data.group and data.group ~= 'INITIAL' and string.sub(data.group, 1, 8) ~= 'INITIAL/' then
            ScenarioInfo.EditorGroupUnits = ScenarioInfo.EditorGroupUnits or {}
            table.insert(ScenarioInfo.EditorGroupUnits, unit)
        end
    end

    --- Map load: EdSpawnUnit for a list of units (data.list, each one the Args of an EdSpawnUnit call): one callback for a few hundred units instead of one each.
    Callbacks.EdSpawnUnits = function(data)
        for _, u in data.list or {} do
            Callbacks.EdSpawnUnit(u)
        end
    end

    --- Effect preview: plays every emitter of the list at a point (on an entity that is destroyed after `seconds`).
    Callbacks.EdEffect = function(data)
        local ent = import('/lua/sim/Entity.lua').Entity({})
        ent:SetPosition(Vector(data.x, data.y, data.z), true)
        ScenarioInfo.EdViewTemp = ScenarioInfo.EdViewTemp or {}
        table.insert(ScenarioInfo.EdViewTemp, ent)           -- the unit viewer takes it down with everything else it made (viewer.lua, EdViewClear)
        for _, path in data.emitters or {} do
            local ok, err = pcall(function() CreateEmitterAtEntity(ent, 1, path) end)
            if not ok then WARN('EdEffect: ' .. tostring(path) .. ': ' .. tostring(err)) end
        end
        ForkThread(function()
            WaitSeconds(data.seconds or 6)
            if not ent:BeenDestroyed() then ent:Destroy() end
        end)
    end

    --- Projectile preview: fires a projectile blueprint from the unit of blueprint `bp` standing at (x, z).
    Callbacks.EdFire = function(data)
        local units = GetUnitsInRect(Rect(data.x - 1.5, data.z - 1.5, data.x + 1.5, data.z + 1.5))
        for _, u in units or {} do
            if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                local ok, proj = pcall(function() return u:CreateProjectile(data.projectile, 0, 2, 0.5, 0, 0, 1) end)
                if ok and proj then
                    proj:SetVelocity(data.speed or 15)
                    ScenarioInfo.EdViewTemp = ScenarioInfo.EdViewTemp or {}
                    table.insert(ScenarioInfo.EdViewTemp, proj)
                    proj:SetLifetime(8)
                else
                    WARN('EdFire: ' .. tostring(data.projectile) .. ': ' .. tostring(proj))
                end
                return
            end
        end
    end

    --- Unit viewer: animation control of the unit of blueprint `bp` standing at (x, z). Fields: path + loop (play), rate, fraction (jump to a point of the animation and hold), stop.
    Callbacks.EdAnim = function(data)
        local units = GetUnitsInRect(Rect(data.x - 1.5, data.z - 1.5, data.x + 1.5, data.z + 1.5))
        for _, u in units or {} do
            if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                if data.stop then
                    if u.EdAnimator then u.EdAnimator:Destroy() u.EdAnimator = nil end
                    return
                end
                if data.path then
                    if u.EdAnimator then u.EdAnimator:Destroy() end
                    u.EdAnimator = CreateAnimator(u)
                    u.EdAnimator:PlayAnim(data.path, data.loop)
                end
                if u.EdAnimator then
                    if data.fraction then
                        u.EdAnimator:SetRate(0)
                        u.EdAnimator:SetAnimationFraction(data.fraction)
                    elseif data.rate then
                        u.EdAnimator:SetRate(data.rate)
                    end
                end
                return
            end
        end
    end

    --- Destroys the unit of blueprint `bp` standing at (x, z) (the editor's own entity of a unit it removed or moved).
    Callbacks.EdRemoveUnitAt = function(data)
        local units = GetUnitsInRect(Rect(data.x - 1.5, data.z - 1.5, data.x + 1.5, data.z + 1.5))
        if units then
            for _, u in units do
                if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                    u:Destroy()
                    return
                end
            end
        end
    end

    --- Test helper: writes the checksum of the SIM's height field over a rectangle (after applying queued edits).
    Callbacks.EdSimChecksum = function(data)
        ed_sim_apply_pending()
        ed_write_file(data.path, ed_sim_checksum(data.x0, data.z0, data.x1, data.z1))
    end

    --- Test helper: writes `x z y terrainY` of every unit of the given blueprint to a file.
    Callbacks.EdDumpUnits = function(data)
        local lines = {}
        local units = GetUnitsInRect(Rect(0, 0, 4096, 4096))
        if units then
            for _, u in units do
                if not u.Dead and (not data.bp or u:GetBlueprint().BlueprintId == data.bp) then
                    local p = u:GetPosition()
                    table.insert(lines, string.format('%s %.3f %.3f %.3f %.3f', u:GetBlueprint().BlueprintId,
                        p[1], p[3], p[2], GetTerrainHeight(p[1], p[3])))
                end
            end
        end
        ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
    end
    --- Test helper: can the first unit of a blueprint path to (x, z)? Writes 'yes' / 'no' to a file.
    Callbacks.EdCanPath = function(data)
        local answer = 'nounit'
        local units = GetUnitsInRect(Rect(0, 0, 4096, 4096))
        if units then
            for _, u in units do
                if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                    local ok, target = u:CanPathTo(Vector(data.x, GetTerrainHeight(data.x, data.z), data.z))
                    answer = (ok and 'yes' or 'no') .. ' target=' ..
                        (target and string.format('%.1f,%.1f', target[1], target[3]) or 'none')
                    break
                end
            end
        end
        ed_write_file(data.path, answer .. '\n')
    end
    --- Diagnostics: terrain height and whether a power generator fits, at a list of points.
    Callbacks.EdProbe = function(data)
        local lines = {}
        local brain = ArmyBrains[1]
        for _, pt in data.points do
            local y = GetTerrainHeight(pt[1], pt[2])
            local fits = brain:CanBuildStructureAt('ueb1101', Vector(pt[1], y, pt[2])) and 'fits' or 'blocked'
            table.insert(lines, string.format('%d,%d h=%.2f %s', pt[1], pt[2], y, fits))
        end
        ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
    end
    --- Test helper: orders the first unit of a blueprint to move to (x, z).
    Callbacks.EdMoveUnit = function(data)
        local units = GetUnitsInRect(Rect(0, 0, 4096, 4096))
        if units then
            for _, u in units do
                if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                    IssueClearCommands({u})
                    IssueMove({u}, Vector(data.x, GetTerrainHeight(data.x, data.z), data.z))
                    return
                end
            end
        end
    end
end

-- Resource marker validation (UI side: lua/editor/validate.lua): can the structure of each Mass / Hydrocarbon marker be built where the
-- marker is? The editing sim has no deposits of its own, so they are recreated from the markers first (ed_sim_clear_deposits, then
-- CreateResourceDeposit like ScenarioUtilities.CreateResources); then the sim's own build check answers, and for a "no" a reason is
-- added when one is visible (water). The answer goes into a result file the UI polls: first line "gen <n>", then one line
-- "<marker name>|<1 ok, 0 blocked>|<reason>" per marker.
do
    local STRUCTURE = { Mass = 'ueb1103', Hydrocarbon = 'ueb1102' }

    Callbacks.EdValidateBuild = function(data)
        ed_sim_apply_pending()   -- terrain edits queued by the UI thread
        local brain = ArmyBrains[1]
        local lines = { 'gen ' .. tostring(data.gen) }
        ed_sim_clear_deposits()
        for _, it in data.items do
            CreateResourceDeposit(it.type, it.x, GetTerrainHeight(it.x, it.z), it.z, it.depositSize or 1)
        end
        for _, it in data.items do
            local y = GetTerrainHeight(it.x, it.z)
            local ok = true
            if brain and STRUCTURE[it.type] then
                ok = brain:CanBuildStructureAt(STRUCTURE[it.type], Vector(it.x, y, it.z)) and true or false
            end
            local reason = ''
            if not ok then
                -- a marker that already carries its extractor (Mass) or generator (Hydrocarbon) is in use, not blocked: the structure standing there is what makes the build check say no
                local reach = (it.type == 'Hydrocarbon') and 4 or 2
                local list = GetUnitsInRect(Rect(it.x - reach, it.z - reach, it.x + reach, it.z + reach))
                local want = (it.type == 'Hydrocarbon') and categories.HYDROCARBON or categories.MASSEXTRACTION
                for _, u in list or {} do
                    if not u.Dead and EntityCategoryContains(want, u) then
                        local p = u:GetPosition()
                        if math.abs(p[1] - it.x) <= reach and math.abs(p[3] - it.z) <= reach then ok = true break end
                    end
                end
            end
            if not ok then
                local half = it.size / 2
                local wet = false
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        local px, pz = it.x + dx * half, it.z + dz * half
                        if GetSurfaceHeight(px, pz) > GetTerrainHeight(px, pz) + 0.01 then wet = true end
                    end
                end
                local size = ScenarioInfo and ScenarioInfo.size
                if size and (it.x - half < 0 or it.z - half < 0 or it.x + half > size[1] or it.z + half > size[2]) then
                    reason = 'the footprint reaches over the map edge'
                elseif wet then
                    reason = 'under water'
                else
                    reason = 'something is in the way (terrain, props or structures)'
                end
            end
            table.insert(lines, string.format('%s|%d|%s', it.name, ok and 1 or 0, reason))
        end
        ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
    end
end

-- Feature files: every /lua/editorsim/*.lua defines `function Register(Callbacks)` and adds its own `Callbacks.EdXxx` there, so a new editor feature does not edit this file
-- (parallel feature branches would collide at its end). A broken file is reported and skipped.
do
    for _, file in DiskFindFiles('/lua/editorsim', '*.lua') do
        local ok, err = pcall(function() import(file).Register(Callbacks) end)
        if not ok then WARN('editor sim callbacks ' .. tostring(file) .. ': ' .. tostring(err)) end
    end
end
