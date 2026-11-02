-- Editor session start (hook on /lua/SinglePlayerLaunch.lua, appended to the base chunk).
-- `main_x64_la.exe /init init_editor.lua /editor /map <name-or-scenario>` opens the map as a plain single
-- player world: one human army, every other army a passive civilian, no AI brain, no victory condition (campaign maps: the other armies are AI armies with the campaign brain).
-- baseline: FixupMapName, VerifyScenarioConfiguration, LaunchSinglePlayerSession, LoadScenario
do
    local baseStartCommandLineSession = StartCommandLineSession

    -- the editor's session start; raises when the map cannot be opened (the caller below catches it)
    local function EditorStartSession(mapName)
        local hookcheck = import('/lua/editor/hookcheck.lua')
        hookcheck.Check()
        hookcheck.Expect('SinglePlayerLaunch', getfenv(1), { 'FixupMapName', 'VerifyScenarioConfiguration' })       -- (warns; LaunchSinglePlayerSession is a local of the base file)
        if not mapName then
            error('editor: a map is required (/map <name>)')
        end
        mapName = FixupMapName(mapName)
        local scenario = import('/lua/ui/maputil.lua').LoadScenario(mapName)
        if not scenario then
            error('editor: unable to load map ' .. mapName)
        end
        VerifyScenarioConfiguration(scenario)

        -- the map's own list of loaded mods becomes the session's selection (lua/editor/mods.lua)
        -- (a sidecar that cannot be read must not stop the map from opening: ApplySidecar reads it protected, and a failure here only costs the map's mod list)
        local EditorMods = import('/lua/editor/mods.lua')
        local okMods, errMods = pcall(function()
            EditorMods.BeginEditorTrial()
            if not EditorMods.RecoverAtLaunch() then
                EditorMods.ApplySidecar(scenario.file)
            end
        end)
        if not okMods then WARN('EDITOR: the mod list of the map could not be applied: ' .. tostring(errMods)) end

        scenario.Options = {
            FogOfWar = 'none',
            NoRushOption = 'Off',
            PrebuiltUnits = 'Off',
            Difficulty = 2,
            DoNotShareUnitCap = true,
            Timeouts = -1,
            GameSpeed = 'normal',
            UnitCap = '1000',
            Victory = 'sandbox',
            CheatsEnabled = 'true',
            CivilianAlliance = 'enemy',
            TeamShareOverflow = 'enabled',
            Share = 'ShareUntilDeath',
            EditorMode = true,
        }

        local playerName = import('/lua/user/prefs.lua').GetFromCurrentProfile('Name') or 'Editor'
        local GetDefaultPlayerOptions = import('/lua/ui/lobby/lobbycomm.lua').GetDefaultPlayerOptions
        local armies = scenario.Configurations.standard.teams[1].armies

        local sessionInfo = {
            playerName = playerName,
            createReplay = false,
            scenarioInfo = scenario,
            teamInfo = {},
            scenarioMods = import('/lua/mods.lua').GetCampaignMods(scenario),
        }

        local player = GetDefaultPlayerOptions(playerName)
        player.PlayerName = playerName
        player.Faction = 1
        player.Human = true
        player.ArmyName = armies[1]
        player.PlayerColor = 1
        player.ArmyColor = 1
        sessionInfo.teamInfo[1] = player

        for index = 2, table.getn(armies) do
            local civilian = GetDefaultPlayerOptions('civilian')
            civilian.PlayerName = 'civilian'
            civilian.Civilian = true
            civilian.Human = false
            civilian.ArmyName = armies[index]
            -- a campaign map (map info type) has real AI armies: a civilian has no economy and no brain, so BaseManager bases and OpAI attacks of the mission
            -- (lua/editor/mbase.lua) would never build anything. Armies named like civilians stay passive.
            if (scenario.type == 'campaign' or scenario.type == 'campaign_coop') and not string.find(string.lower(armies[index]), 'civilian', 1, true)
                and not string.find(string.lower(armies[index]), '^player%d+$') then       -- the other human slots of a coop mission stay passive
                civilian.Civilian = false
                civilian.AIPersonality = ''
            end
            sessionInfo.teamInfo[index] = civilian
        end

        LaunchSinglePlayerSession(sessionInfo)
    end

    -- Opening a map can fail before a session exists (the scenario file is not there, it does not load, FixupMapName raises: "Error launching session: Map scenario file does not
    -- exist"). The engine then logs the error and has no session to show: the editor window stays dead (found 2026-11-02 with /map /maps/nope/nope_scenario.lua). The editor opens its blank
    -- map instead and leaves the reason in editor_launch_error.txt; the start screen shows it (lua/editor/gui/feature_launcherror.lua).
    function StartCommandLineSession(mapName, isPerfTest)
        if not HasCommandLineArg('/editor') then
            return baseStartCommandLineSession(mapName, isPerfTest)
        end
        local ok, err = pcall(EditorStartSession, mapName)
        if ok then return end
        WARN('EDITOR: the map ' .. tostring(mapName) .. ' could not be opened: ' .. tostring(err))
        if mapName == 'editor_blank' or not rawget(_G, 'ed_write_file') then error(err) end
        ed_write_file('editor_launch_error.txt', tostring(mapName) .. '\n' .. tostring(err))
        local ok2, err2 = pcall(EditorStartSession, 'editor_blank')
        if not ok2 then error('editor: neither the map nor the blank map could be opened: ' .. tostring(err2)) end
    end
end
