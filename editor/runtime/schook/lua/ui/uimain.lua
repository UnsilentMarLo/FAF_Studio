-- baseline: StartFrontEndUI
do
    -- editor: after SessionEndGame() the engine asks for the front end; open the queued map instead
    local baseStartFrontEndUI = StartFrontEndUI

    -- The editor modules of the session that just ended free what they made in the engine (world meshes, overlay objects) before the module cache is dropped: a WorldMesh keeps its
    -- own Lua table alive, so dropping the module that holds it does not free it (lua/editor/control.lua Teardown; it only looks at modules that are loaded).
    local function EditorTeardown()
        local control = __modules and __modules['/lua/editor/control.lua']
        if control and control.Teardown then
            local ok, err = pcall(control.Teardown)
            if not ok then WARN('EDITOR: the teardown of the last session failed: ' .. tostring(err)) end
        end
    end
    -- The engine calls this from its own startup / teardown code with nothing around it: a Lua error that escapes ends in the engine's fatal path ("index expected but got boolean" killed the
    -- process there once: faf_crash_20261019_211727.txt; that one was the engine's import stub answering `false` before globalInit.lua replaced it, engine side). An error while the editor opens
    -- the next map is caught, logged, and the game's own front end is the fallback: the process lives and the log says why.
    local function EditorOpen(map)
        local ok, err = pcall(function() import('/lua/SinglePlayerLaunch.lua').StartCommandLineSession(map, false) end)
        if not ok then WARN('EDITOR: opening ' .. tostring(map) .. ' failed: ' .. tostring(err)) end
        return ok
    end
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
                EditorTeardown()
                __modules = {}
                if EditorOpen(nextMap) then return end
            end
        end
        -- editor started without /map: the front end would show the game's menu. The editor opens its blank map instead; the start screen (gui/feature_start.lua)
        -- then offers what to do. After that, an empty queue means the session was ended for some other reason: the front end as before.
        -- (ed_launch_error is native, in engine builds that catch a failed launch themselves instead of a modal box that stopped the main loop; keep = true leaves the text for the start screen)
        local launchFailed = rawget(_G, 'ed_launch_error') and ed_launch_error(true) ~= nil
        if HasCommandLineArg('/editor') and (not HasCommandLineArg('/map') or launchFailed) and ed_read_file('editor_boot.txt') == '0' then
            LOG('EDITOR: no map given or the map could not be opened, opening the blank map with the start screen')
            EditorTeardown()
            __modules = {}
            if EditorOpen('editor_blank') then return end
        end
        return baseStartFrontEndUI()
    end
end
