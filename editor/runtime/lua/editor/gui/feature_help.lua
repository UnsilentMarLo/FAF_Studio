-- Help: F1 opens the help panel (in a window of its own the first time), Help > Tutorial, and the help entries of the Help menu. Self-registering (gui/feature_*.lua are
-- imported by the shell). Content: help.lua, panels_help.lua; the tour: tour.lua.
--
-- Commands: help.open (F1), help.shortcuts, help.tour (Tutorial).
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'help.open', title = 'Help: open help', keys = 'F1', run = function() import('/lua/editor/help.lua').Open() end }
Commands.Register{ id = 'help.shortcuts', title = 'Help: keyboard and mouse shortcuts', run = function() import('/lua/editor/help.lua').Open('shortcuts') end }
Commands.Register{ id = 'help.tour', title = 'Help: tutorial', run = function() import('/lua/editor/gui/tour.lua').Start() end }

Menu.Extend('menubar.Help', function()
    return {
        { command = 'help.open' },
        { command = 'help.shortcuts' },
        { command = 'help.tour' },
    }
end, 5)
