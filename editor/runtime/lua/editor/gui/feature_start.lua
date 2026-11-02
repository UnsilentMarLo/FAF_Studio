-- What happens when the editor comes up: the start screen (when no map was given), the notices about the last run (crash report, unsaved autosave), the first-run tour
-- and a command that was queued by the start screen ("Release a map" opens the map first and runs the release afterwards). The shell calls OnStart() at the end of every
-- Start; only the first session of a process (the one the user started) shows the start screen and the notices - opening a map restarts the session, and these must not
-- come back each time (init_editor.lua writes `editor_boot.txt` = 0 at process start, this module sets it to 1).
--
-- Commands: file.start (File > Start screen).
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local UserData = import('/lua/editor/userdata.lua')
local Safe = import('/lua/editor/safe.lua')

local function StartScreen() return import('/lua/editor/gui/startscreen.lua') end

--- Starts the tour when one is waiting (the first run showed the start screen) and nothing else is on the screen.
function MaybeTour()
    if UserData.Get('tourPending', false) and not StartScreen().IsOpen() and not import('/lua/editor/gui/dialog.lua').IsOpen() then
        UserData.Set('tourPending', false)
        UserData.Flush()
        Safe.Try('feature_start:fn21', function() import('/lua/editor/gui/tour.lua').Start() end)
    end
end

function OnStart()
    Safe.Try('feature_start:fn26', function() import('/lua/editor/graphics.lua').Apply(true) end)       -- the saved graphics settings (the editor defaults to the highest quality)
    local boot = ed_read_file('editor_boot.txt')
    local first = (boot == nil or boot == '' or boot == '0')
    ed_write_file('editor_boot.txt', '1')
    -- a map that could not be opened (schook SinglePlayerLaunch.lua opened the blank map instead): say so, then the start screen
    local Launch = import('/lua/editor/gui/feature_launcherror.lua')
    local failedLaunch = Launch.Take()
    -- a failure the engine caught itself (native ed_launch_error, only in builds that have it) before a Lua hook could
    local nativeError = rawget(_G, 'ed_launch_error') and ed_launch_error() or nil
    if nativeError and not failedLaunch then
        local given = GetCommandLineArg('/map', 1)
        failedLaunch = tostring(given and given[1] or 'the requested map') .. '\n' .. tostring(nativeError)
    end
    if failedLaunch then
        Launch.Show(failedLaunch, function() StartScreen().Open{ afterNoMap = true } end)
        return
    end
    if first then
        local noMap = not HasCommandLineArg('/map')
        if noMap and UserData.Get('startScreen', true) ~= false then
            if not UserData.Get('tourDone', false) then UserData.Set('tourPending', true) end
            StartScreen().Open{ afterNoMap = true }
        end
        Safe.Try('feature_start:fn43', function()
            import('/lua/editor/gui/feature_crash.lua').Notices(function() MaybeTour() end)
        end)
    else
        MaybeTour()
    end
    -- a command the start screen queued before it opened a map ("Release a map...")
    local after = UserData.Get('after', false)
    if type(after) == 'string' and after ~= '' then
        UserData.Set('after', false)
        UserData.Flush()
        Safe.Try('feature_start:fn54', function() Commands.Run(after) end)
    end
end

Commands.Register{ id = 'file.start', title = 'File: start screen', run = function() StartScreen().Open() end }

Menu.Extend('menubar.File', function()
    return {
        { command = 'file.start' },
    }
end, 4)

--- File > Exit: the editor's own way out. The game's Escape quit dialog is off in an editor session (schook/lua/ui/dialogs/eschandler.lua); unsaved changes are asked about first.
Commands.Register{ id = 'file.exit', title = 'File: exit', run = function()
    import('/lua/editor/gui/dialogs_map.lua').Guard(function() import('/lua/ui/dialogs/eschandler.lua').SafeQuit() end)
end }

Menu.Extend('menubar.File', function()
    return {
        { command = 'file.exit' },
    }
end, 95)
