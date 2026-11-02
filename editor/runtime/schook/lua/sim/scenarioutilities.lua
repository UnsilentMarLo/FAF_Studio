-- Editor worlds have no commanders: the map's own INITIAL groups are map content and stay, but no ACU is
-- created for any army and the armies get no AI. Nothing fires while editing: units hold fire and the armies are neutral (CreateResources below, editorsim/peace.lua).
-- baseline: CreateInitialArmyGroup, CreateResources
do
    local baseCreateInitialArmyGroup = CreateInitialArmyGroup
    pcall(function() import('/lua/editor/hookcheck.lua').Expect('scenarioutilities', getfenv(1), { 'CreateInitialArmyGroup', 'CreateResources' }) end)

    function CreateInitialArmyGroup(strArmy, createCommander)
        if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
            local group, cdr = baseCreateInitialArmyGroup(strArmy, false)
            -- the map's units stand still while it is edited (a test run releases them: EdSetPlay in schook/lua/simcallbacks.lua)
            for _, u in group or {} do
                if u and not u.Dead and u.SetImmobile then
                    u.EdFrozen = true
                    pcall(function() u:SetImmobile(true) end)
                    -- ... and does not fire (hold fire; the armies are made neutral in CreateResources below, editorsim/peace.lua)
                    pcall(function() import('/lua/editorsim/peace.lua').Hold(u) end)
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
            -- Editing is quiet: nothing fires. BeginSession calls this after InitializeArmies, the map script's OnPopulate / OnStart and BeginSessionTeams (the places that set the
            -- diplomacy), so this is the first point where every army pair can be made neutral for good; Callbacks.EdSetPlay (simcallbacks.lua) gives the scenario's own diplomacy back
            -- for a test run. No wait inside the pcall (Enter only forks its sweep thread).
            local ok, err = pcall(function() import('/lua/editorsim/peace.lua').Enter() end)
            if not ok then WARN('editor: armies could not be made neutral: ' .. tostring(err)) end
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
