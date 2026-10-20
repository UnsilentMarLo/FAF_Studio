-- Editor sim callbacks of the unit viewer (unitview.lua). Loaded by the loader at the end of schook/lua/simcallbacks.lua.
--
--   EdViewSpawn   makes the unit the viewer shows (protected: it cannot take damage or be killed, so a naval unit on land does not die and leave a wreck), remembers what stood around the spot first
--   EdViewClear   takes everything the viewer made down: its units, the wrecks / props that appeared around the spot since, the effect and projectile entities of the Effects panel
--   EdViewInfo    writes what the UI cannot know: the entity id of the shown unit (for ed_unit_bones), its collision extents and position
--   EdBones       (kept for tools that want the sim's view) one line per bone: index name x y z dx dy dz
function Register(Callbacks)
    local function Around(x, z, r)
        return GetReclaimablesInRect(Rect(x - r, z - r, x + r, z + r)) or {}
    end

    local function WriteInfo(u, path)
        local lines = {}
        local ok, id = pcall(function() return u:GetEntityId() end)
        table.insert(lines, 'id ' .. tostring(ok and id or -1))
        local p = u:GetPosition()
        table.insert(lines, string.format('pos %.3f %.3f %.3f', p[1], p[2], p[3]))
        local good, ext = pcall(function() return u:GetCollisionExtents() end)
        if good and ext and ext.Min and ext.Max then
            table.insert(lines, string.format('ext %.3f %.3f %.3f %.3f %.3f %.3f', ext.Min[1], ext.Min[2], ext.Min[3], ext.Max[1], ext.Max[2], ext.Max[3]))
        end
        ed_write_file(path, table.concat(lines, '\n') .. '\n')
    end

    Callbacks.EdViewSpawn = function(data)
        local army = data.army or 'ARMY_1'
        local r = data.radius or 90
        if not ScenarioInfo.EdViewBase then
            local base = {}
            for _, e in Around(data.x, data.z, r) do
                local ok, id = pcall(function() return e:GetEntityId() end)
                if ok and id then base[id] = true end
            end
            ScenarioInfo.EdViewBase = base
        end
        local ok, unit = pcall(function() return CreateUnitHPR(data.bp, army, data.x, data.y, data.z, 0, data.heading or 0, 0) end)
        if not (ok and unit) then
            ed_write_file(data.path, 'error ' .. tostring(unit) .. '\n')
            return
        end
        unit.EdViewUnit = true
        -- a naval unit on land would be killed (and leave a wreck that nothing can select or remove): the viewer's unit takes no damage and cannot die, and is left alone by every order
        for _, call in {
            function() unit:SetCanTakeDamage(false) end, function() unit:SetCanBeKilled(false) end, function() unit:SetDoNotTarget(true) end,
            function() unit:SetReclaimable(false) end, function() unit:SetCapturable(false) end, function() unit:SetUnSelectable(true) end,
            -- an aircraft would take off and drift away from the stage: it stays where it was made
            function() unit:SetImmobile(true) end,
        } do
            pcall(call)
        end
        -- belt and braces for a unit that is somewhere it does not belong (a ship on land, a submarine in shallow water): whatever the engine or the unit's scripts do to its health, it is put back
        unit:ForkThread(function(self)
            while not self.Dead do
                pcall(function()
                    local max = self:GetMaxHealth()
                    if self:GetHealth() < max then self:SetHealth(self, max) end
                end)
                WaitTicks(5)
            end
        end)
        WriteInfo(unit, data.path)
    end

    Callbacks.EdViewInfo = function(data)
        local units = GetUnitsInRect(Rect(data.x - 2, data.z - 2, data.x + 2, data.z + 2))
        for _, u in units or {} do
            if not u.Dead and u.EdViewUnit then
                WriteInfo(u, data.path)
                return
            end
        end
        ed_write_file(data.path, 'none\n')
    end

    Callbacks.EdViewClear = function(data)
        local r = data.radius or 90
        for _, u in GetUnitsInRect(Rect(data.x - r, data.z - r, data.x + r, data.z + r)) or {} do
            if u.EdViewUnit then
                u:Destroy()
            end
        end
        -- wrecks and props that were not there before the first spawn
        local base = ScenarioInfo.EdViewBase or {}
        for _, e in Around(data.x, data.z, r) do
            local ok, id = pcall(function() return e:GetEntityId() end)
            if ok and id and not base[id] and not e.EdViewUnit then
                local bp = e.GetBlueprint and e:GetBlueprint()
                local bid = bp and bp.BlueprintId
                if bid and string.find(bid, '^/props/') then
                    pcall(function() e:Destroy() end)
                end
            end
        end
        for _, e in ScenarioInfo.EdViewTemp or {} do
            pcall(function() if not e:BeenDestroyed() then e:Destroy() end end)
        end
        ScenarioInfo.EdViewTemp = {}
        if data.final then ScenarioInfo.EdViewBase = nil end
    end

    --- Test helper: a wreckage prop at (x, y, z), as a unit that died on the stage would leave one.
    Callbacks.EdViewTestProp = function(data)
        pcall(function() CreateProp(Vector(data.x, data.y, data.z), '/props/defaultwreckage/defaultwreckage_prop.bp') end)
    end

    --- Writes one line per bone of the unit of blueprint `bp` standing at (x, z) to `path`: `index name x y z dx dy dz` (world position and the direction the bone points along).
    Callbacks.EdBones = function(data)
        local units = GetUnitsInRect(Rect(data.x - 1.5, data.z - 1.5, data.x + 1.5, data.z + 1.5))
        for _, u in units or {} do
            if not u.Dead and u:GetBlueprint().BlueprintId == data.bp then
                local lines = {}
                for i = 0, u:GetBoneCount() - 1 do
                    local name = u:GetBoneName(i)
                    if name then
                        local p = u:GetPosition(i)
                        local dx, dy, dz = u:GetBoneDirection(i)
                        table.insert(lines, string.format('%d %s %.3f %.3f %.3f %.3f %.3f %.3f', i, string.gsub(name, '%s', '_'), p[1], p[2], p[3], dx or 0, dy or 0, dz or 0))
                    end
                end
                ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
                return
            end
        end
        ed_write_file(data.path, '')
    end
end
