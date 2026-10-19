-- Editor worlds have no commanders: the map's own INITIAL groups are map content and stay, but no ACU is
-- created for any army and the armies get no AI.
do
    local baseCreateInitialArmyGroup = CreateInitialArmyGroup

    function CreateInitialArmyGroup(strArmy, createCommander)
        if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
            local group, cdr = baseCreateInitialArmyGroup(strArmy, false)
            -- the map's units stand still while it is edited (a test run releases them: EdSetPlay in schook/lua/simcallbacks.lua)
            for _, u in group or {} do
                if u and not u.Dead and u.SetImmobile then
                    u.EdFrozen = true
                    pcall(function() u:SetImmobile(true) end)
                end
            end
            return group, cdr
        end
        return baseCreateInitialArmyGroup(strArmy, createCommander)
    end
end
