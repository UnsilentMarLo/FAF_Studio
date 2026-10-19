-- Editor sim callbacks of the unit icon generator (icongen.lua) and the unit viewer (unitview.lua): loaded by the loader at the end of schook/lua/simcallbacks.lua.
function Register(Callbacks)
    --- Icon generator (icongen.lua): the army's team colour for the icon render (r, g, b), and back to a colour index of the army setup afterwards (index).
    Callbacks.EdArmyColor = function(data)
        local army = data.army or 'ARMY_1'
        if data.index then
            pcall(function() SetArmyColorIndex(army, data.index) end)
        else
            pcall(function() SetArmyColor(army, data.r, data.g, data.b) end)
        end
    end

    --- Unit viewer / icon generator: destroys every unit the viewer made (group '_view') within `radius` of (x, z), whatever its blueprint (a unit that moved or spawned parts is not found by position alone).
    Callbacks.EdClearLab = function(data)
        local r = data.radius or 40
        local units = GetUnitsInRect(Rect(data.x - r, data.z - r, data.x + r, data.z + r))
        for _, u in units or {} do
            if not u.Dead and u.EdViewUnit then u:Destroy() end
        end
    end

    --- Test helper: every unit (also dead ones) and prop within 100 of (x, z): blueprint, Dead flag, position, the viewer's tag.
    Callbacks.EdDumpAround = function(data)
        local lines = {}
        local r = data.radius or 100
        local rect = Rect(data.x - r, data.z - r, data.x + r, data.z + r)
        for _, u in GetUnitsInRect(rect) or {} do
            local p = u:GetPosition()
            table.insert(lines, string.format('unit %s dead=%s tag=%s %.1f %.1f %.1f', tostring(u:GetBlueprint().BlueprintId), tostring(u.Dead), tostring(u.EdViewUnit), p[1], p[2], p[3]))
        end
        for _, e in GetReclaimablesInRect(rect) or {} do
            local ok, p = pcall(function() return e:GetPosition() end)
            table.insert(lines, 'reclaimable ' .. tostring(e.GetBlueprint and e:GetBlueprint().BlueprintId or '?') .. ' ' .. (ok and string.format('%.1f %.1f %.1f', p[1], p[2], p[3]) or '?'))
        end
        ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
    end
end
