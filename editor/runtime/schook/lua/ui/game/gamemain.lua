do
    local baseOnFirstUpdate = OnFirstUpdate
    function OnFirstUpdate()
        -- The game's own first update builds the score UI, the army lines ... from the armies of the map. A map whose armies do not fit it (an army without a faction icon, a
        -- campaign script that creates UI) makes it raise: with the editor's start after it, the session came up as a plain game without the editor (found 2026-10-19 by
        -- scripts/editor_sim_stress.py: Play then Stop / Open on a map with a second army). The editor starts whatever happens to the game's UI.
        local ok, err = pcall(baseOnFirstUpdate)
        if not ok then WARN('EDITOR: the game\'s OnFirstUpdate failed, the editor starts anyway: ' .. tostring(err)) end
        if HasCommandLineArg('/editor') then
            import('/lua/editor/control.lua').Start()
        end
    end
end
