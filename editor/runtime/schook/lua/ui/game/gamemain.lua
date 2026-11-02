-- baseline: OnFirstUpdate, CreateWldUIProvider
do
    local baseOnFirstUpdate = OnFirstUpdate
    pcall(function() import('/lua/editor/hookcheck.lua').Expect('gamemain', getfenv(1), { 'OnFirstUpdate', 'CreateWldUIProvider' }) end)       -- best effort (the check only warns)
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

do
    -- The game's loading dialog (a faction movie, "IN TRANSIT", the game's tips) is replaced by the editor's own loading screen: dark, with the editor's name, version and tips.
    -- Base: CreateWldUIProvider() sets the file's local `provider` (no return value; the hook shares the base chunk, so the local is visible here) whose
    -- StartLoadingDialog / UpdateLoadingDialog / StopLoadingDialog the engine calls.
    local baseCreateWldUIProvider = CreateWldUIProvider
    function CreateWldUIProvider()
        baseCreateWldUIProvider()
        if HasCommandLineArg('/editor') and provider then
            provider.StartLoadingDialog = function(self)
                GetCursor():Hide()
                supressExitDialog = true
                local ok, err = pcall(function() import('/lua/editor/gui/loading.lua').Start() end)
                if not ok then WARN('EDITOR: the loading screen could not start: ' .. tostring(err)) end
            end
            provider.UpdateLoadingDialog = function(self, elapsedTime) end
            provider.StopLoadingDialog = function(self)
                local ok, err = pcall(function() import('/lua/editor/gui/loading.lua').Stop() end)
                if not ok then WARN('EDITOR: the loading screen could not stop: ' .. tostring(err)) end
                GetCursor():Show()
                FlushEvents()
            end
        end
    end
end
