-- Coop support for play tests in the editor. In a real coop game the lobby loads the FAF coop support mod (lobby_coop.cop), which hooks ScenarioFramework (SetSharedUnitCap,
-- PlayerDeath, RemoveRestrictionForAllHumans, SimAnnouncement, ...) and fills ScenarioInfo.HumanPlayers from the armies named Player<N>. A coop or both-mode mission script calls
-- Install() when it runs in the editor (ScenarioInfo.Options.EditorMode): the editor session does not load that mod (its files cannot be read with doscript from the .cop archive; editor mods with
-- ui_only = false DO hook the sim of an editor session, tested 2026-11-02: docs/EDITOR_MODDING.md, Sim state), so this module defines the functions the generated nodes use, with the same names and meaning
-- (simplified: the editor's play test has one real human; the other Player<N> slots are passive armies). Own implementation, not a copy of the mod.
--
-- Lua 5.0 dialect. Runs in the sim state.

--- Defines the coop functions in ScenarioFramework when the module lacks them (a loaded coop mod wins) and fills ScenarioInfo.HumanPlayers.
function Install()
    local SF = import('/lua/ScenarioFramework.lua')

    -- the human slots of a coop mission are the armies Player1 .. PlayerN (the editor's single human, the first army, is one of them only when it is named so)
    local humans = {}
    for index, brain in ArmyBrains do
        if brain.Name and string.find(brain.Name, '^Player') then
            humans[brain.Name] = index
        end
    end
    if next(humans) then ScenarioInfo.HumanPlayers = humans end
    ScenarioInfo.HumanPlayers = ScenarioInfo.HumanPlayers or {}
    if rawget(SF, 'SetSharedUnitCap') then return end

    --- Divides the unit cap among the living human players.
    SF.SetSharedUnitCap = function(number)
        local alive = {}
        for _, index in ScenarioInfo.HumanPlayers do
            if not ArmyBrains[index]:IsDefeated() then table.insert(alive, index) end
        end
        if table.getn(alive) > 0 and number and number > 0 then
            local each = math.floor(number / table.getn(alive))
            for _, index in alive do SetArmyUnitCap(index, each) end
        end
    end

    SF.AddRestrictionForAllHumans = function(categories)
        for _, index in ScenarioInfo.HumanPlayers do SF.AddRestriction(index, categories) end
    end

    SF.RemoveRestrictionForAllHumans = function(categories, unlockDialogue, isSilent)
        for _, index in ScenarioInfo.HumanPlayers do SF.RemoveRestriction(index, categories, isSilent) end
        if unlockDialogue then SF.PlayUnlockDialogue() end
    end

    SF.SimAnnouncement = function(text, secondaryText)
        Sync.CreateSimAnnouncement = { text = text, secondaryText = secondaryText }
    end

    --- A player commander died: when no human commander is left the operation is lost (after the failure dialogue).
    SF.PlayerDeath = function(deadCommander, failureDialogue, currentObjectives)
        if ScenarioInfo.OpEnded then return end
        for _, index in ScenarioInfo.HumanPlayers do
            for _, cdr in ArmyBrains[index]:GetListOfUnits(categories.COMMAND, false) do
                if cdr ~= deadCommander and not cdr.Dead then return end
            end
        end
        ScenarioInfo.OpComplete = false
        for _, obj in currentObjectives or {} do
            if obj and obj.Active then obj:ManualResult(false) end
        end
        local function End() SF.EndOperation(false, false, false, false) end
        if failureDialogue then
            SF.FlushDialogueQueue()
            SF.Dialogue(failureDialogue, End, true)
        else
            End()
        end
    end
end
