-- Editor sim callbacks of the mission run panel (lua/editor/missionrun.lua): loaded by the loader at the end of schook/lua/simcallbacks.lua.
-- The generated mission script exposes its state as ScenarioInfo.EditorMission = { Stage = {functions}, V = {variables}, Objectives = {objective handles} } and its waits and timers
-- honour ScenarioInfo.EditorSkip (a counter: every waiting thread returns when it changes) and ScenarioInfo.EditorTimeScale (1 = real time).
--- Called by the script of a test run (ScenarioInfo.Options.EditorMode): the campaign launcher's EndOperation needs ScenarioInfo.Options.ScenarioFile and an operation file, which an
--- editor session does not have (it raised in string.gsub), so a test run records the result instead: ScenarioInfo.EditorMissionResult, shown by the run panel and the dump.
function Attach()
    local SF = import('/lua/ScenarioFramework.lua')
    if rawget(SF, 'EdOriginalEndOperation') then return end
    SF.EdOriginalEndOperation = SF.EndOperation
    SF.EndOperation = function(success, allPrimary, allSecondary, allBonus)
        ScenarioInfo.EditorMissionResult = { success = success and true or false, allPrimary = allPrimary and true or false, allSecondary = allSecondary and true or false, tick = GetGameTick() }
        ScenarioInfo.OpEnded = true
        LOG('EDMISSION ended success=' .. tostring(success and true or false) .. ' tick=' .. tostring(GetGameTick()))
    end
end

function Register(Callbacks)
    --- Writes the mission state to `path` (plain text, one fact per line) for the UI to read:
    --   tick N / stage N / playing 0|1 / scale S / flag NAME 0|1 / obj <title>|<active 0|1> / var NAME <number of units alive, or kind>
    Callbacks.EdMissionDump = function(data)
        local lines = {}
        local function Add(text) table.insert(lines, text) end
        Add('tick ' .. tostring(GetGameTick()))
        Add('stage ' .. tostring(ScenarioInfo.MissionNumber or 0))
        Add('playing ' .. (ScenarioInfo.EditorPlaying and '1' or '0'))
        Add('scale ' .. tostring(ScenarioInfo.EditorTimeScale or 1))
        for name, value in ScenarioInfo.VarTable or {} do
            Add('flag ' .. tostring(name) .. ' ' .. (value and '1' or '0'))
        end
        local m = ScenarioInfo.EditorMission
        if m then
            for _, obj in m.Objectives or {} do
                local title = obj.Title or obj.Tag or '?'
                Add('obj ' .. tostring(title) .. '|' .. (obj.Active and '1' or '0'))
            end
            for name, v in m.V or {} do
                if type(v) == 'table' and v.Active ~= nil then
                    -- an objective handle (listed above)
                elseif type(v) == 'table' then
                    local alive = 0
                    for _, u in v do
                        if type(u) == "table" and not u.Dead then alive = alive + 1 end
                    end
                    Add('var ' .. tostring(name) .. ' ' .. tostring(alive))
                else
                    Add('var ' .. tostring(name) .. ' ' .. type(v))
                end
            end
        end
        -- the test hooks of the script: how the operation ended, every node the script reached, what the armies have, how they stand to each other, the playable area
        local result = ScenarioInfo.EditorMissionResult
        Add('ended ' .. (result and '1' or '0') .. ' ' .. ((result and result.success) and '1' or '0'))
        if m then
            for _, id in m.Trace or {} do Add('trace ' .. tostring(id)) end
        end
        local ok, err = pcall(function()
            for index, brain in ArmyBrains do
                Add('army ' .. index .. ' ' .. tostring(brain.Name))
                Add('units ' .. tostring(brain.Name) .. ' ' .. tostring(brain:GetCurrentUnits(categories.ALLUNITS)))
                Add('eco ' .. tostring(brain.Name) .. ' ' .. string.format('%d %d', brain:GetEconomyStored('MASS'), brain:GetEconomyStored('ENERGY')))
                for other, _ in ArmyBrains do
                    if other ~= index then
                        Add('rel ' .. index .. ' ' .. other .. ' ' .. (IsAlly(index, other) and 'ally' or (IsEnemy(index, other) and 'enemy' or 'neutral')))
                    end
                end
            end
            local rect = ScenarioInfo.MapData and ScenarioInfo.MapData.PlayableRect
            if rect then Add('playable ' .. string.format('%d %d %d %d', rect[1], rect[2], rect[3], rect[4])) end
        end)
        if not ok then Add('dumperror ' .. string.gsub(tostring(err), '\n', ' ')) end
        ed_write_file(data.path, table.concat(lines, '\n') .. '\n')
    end

    --- Starts stage `stage` now (the stage before is set as current so the stage's own guard lets it run; triggers of other stages go quiet).
    Callbacks.EdMissionJump = function(data)
        local m = ScenarioInfo.EditorMission
        local fn = m and m.Stage and m.Stage[data.stage]
        if not fn then
            WARN('EdMissionJump: no stage ' .. tostring(data.stage))
            return
        end
        ScenarioInfo.EditorPlaying = true
        ScenarioInfo.MissionNumber = data.stage - 1
        ForkThread(fn)
    end

    --- The stage the next play test starts at (the mission script reads it when Play starts it); 1 = the first.
    Callbacks.EdMissionStartAt = function(data)
        ScenarioInfo.EditorStartStage = data.stage or 1
    end

    --- Sets a mission flag (ScenarioInfo.VarTable, read by OpAI conditions and Set a flag nodes).
    Callbacks.EdMissionFlag = function(data)
        ScenarioInfo.VarTable = ScenarioInfo.VarTable or {}
        ScenarioInfo.VarTable[data.name] = data.value and true or false
    end

    --- Ends every running wait and timer of the mission script once.
    Callbacks.EdMissionSkip = function(data)
        ScenarioInfo.EditorSkip = (ScenarioInfo.EditorSkip or 0) + 1
    end

    --- Speed of the mission script's waits and timers (1 = real time).
    Callbacks.EdMissionScale = function(data)
        ScenarioInfo.EditorTimeScale = data.scale or 1
    end
end
