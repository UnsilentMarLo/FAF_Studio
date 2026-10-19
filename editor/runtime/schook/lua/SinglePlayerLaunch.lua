-- Editor session start (hook on /lua/SinglePlayerLaunch.lua, appended to the base chunk).
-- `main_x64_la.exe /init init_editor.lua /editor /map <name-or-scenario>` opens the map as a plain single
-- player world: one human army, every other army a passive civilian, no AI brain, no victory condition (campaign maps: the other armies are AI armies with the campaign brain).
do
    local baseStartCommandLineSession = StartCommandLineSession

    function StartCommandLineSession(mapName, isPerfTest)
        if not HasCommandLineArg('/editor') then
            return baseStartCommandLineSession(mapName, isPerfTest)
        end

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
        local EditorMods = import('/lua/editor/mods.lua')
        if not EditorMods.RecoverAtLaunch() then
            EditorMods.ApplySidecar(scenario.file)
        end

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
end
