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

-- Resource markers in the editor are drawn by the editor itself (lua/editor/markervis.lua: the deposit mesh and the ground splat follow the marker when it is moved).
-- The game's CreateResources also makes a prop (massDeposit01_prop / hydrocarbonDeposit01_prop) and a splat per marker at load; those stay where they were made when the
-- marker moves, so a moved marker showed two of everything. In an editor session only the deposits (what the build rules read) are created; a test run gets the props and
-- splats from the edited markers (EdSetPlay in simcallbacks.lua).
--   base: function CreateResources()   (no arguments, no return value)
do
    local baseCreateResources = CreateResources

    function CreateResources()
        if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
            for _, tblData in GetMarkers() do
                if tblData.resource then
                    local x, y, z = unpack(tblData.position)
                    CreateResourceDeposit(tblData.type, x, y, z, tblData.size)
                end
            end
            return
        end
        return baseCreateResources()
    end
end
