-- Map > Adaptive map / Lobby options window: the panels of adaptive maps (gui/panels_adaptive.lua, adaptive.lua). A self-registering feature module (gui/feature_*.lua are imported by
-- the shell): its own commands and menu items, no shared file is edited.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'adaptive.panel', title = 'Map: adaptive map setup', run = function()
    local Shell = import('/lua/editor/gui/shell.lua')
    if Shell.S.main and not Shell.S.main:ShowPanel('adaptive') then Shell.S.main:AddPanel('adaptive') end
end }

Commands.Register{ id = 'adaptive.window', title = 'Map: lobby options window (adaptive maps)', run = function()
    import('/lua/editor/gui/shell.lua').OpenPanelWindow('adaptive_options', 560, 520)
end }

Menu.Extend('menubar.Map', function()
    return {
        { command = 'adaptive.panel' },
        { command = 'adaptive.window' },
    }
end, 32)
