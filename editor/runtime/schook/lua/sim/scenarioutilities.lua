-- Editor worlds have no commanders: the map's own INITIAL groups are map content and stay, but no ACU is
-- created for any army and the armies get no AI.
do
    local baseCreateInitialArmyGroup = CreateInitialArmyGroup

    function CreateInitialArmyGroup(strArmy, createCommander)
        if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
            return baseCreateInitialArmyGroup(strArmy, false)
        end
        return baseCreateInitialArmyGroup(strArmy, createCommander)
    end
end
