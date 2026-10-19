do
    -- editor: after SessionEndGame() the engine asks for the front end; open the queued map instead
    local baseStartFrontEndUI = StartFrontEndUI
    function StartFrontEndUI()
        if HasCommandLineArg('/editor') then
            if rawget(_G, 'ed_overlay_clear') then ed_overlay_clear() end         -- the previous session's overlay objects (icons, lines) outlive it
            local file = 'editor_next_map.txt'
            local nextMap = ed_read_file(file)
            if nextMap and nextMap ~= '' then
                ed_write_file(file, '')
                LOG('EDITOR: opening ' .. tostring(nextMap))
                -- UI modules keep per-session state in file-level locals (score.lua caches the scenario
                -- table). A new game normally starts from a fresh Lua state; here the state is reused, so drop
                -- the module cache and let everything load again for the new session.
                __modules = {}
                import('/lua/SinglePlayerLaunch.lua').StartCommandLineSession(nextMap, false)
                return
            end
        end
        -- editor started without /map: the front end would show the game's menu. The editor opens its blank map instead; the start screen (gui/feature_start.lua)
        -- then offers what to do. After that, an empty queue means the session was ended for some other reason: the front end as before.
        if HasCommandLineArg('/editor') and not HasCommandLineArg('/map') and ed_read_file('editor_boot.txt') == '0' then
            LOG('EDITOR: no map given, opening the blank map with the start screen')
            __modules = {}
            import('/lua/SinglePlayerLaunch.lua').StartCommandLineSession('editor_blank', false)
            return
        end
        return baseStartFrontEndUI()
    end
end
