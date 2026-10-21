-- Settings: File > Settings... opens the Settings panel (graphics quality, size of the interface) in a window of its own. The saved graphics settings are applied by feature_start.lua
-- when a session starts (graphics.lua; the editor defaults to the highest quality). Self-registering (gui/feature_*.lua are imported by the shell).
--
-- Commands: settings.open.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'settings.open', title = 'File: settings...', run = function()
    import('/lua/editor/gui/shell.lua').OpenPanelWindow('settings', 560, 700)
end }

Menu.Extend('menubar.File', function()
    return {
        { command = 'settings.open' },
    }
end, 60)
