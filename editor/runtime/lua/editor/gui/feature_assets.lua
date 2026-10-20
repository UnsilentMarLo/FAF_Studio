-- The asset browser's commands and menu entry: Window > Asset browser opens the Assets panel (in a window of its own the first time: the browser likes room), Window > Asset browser in a
-- window always opens a pop-out. Self-registering (gui/feature_*.lua are imported by the shell). Panel: panels_assets.lua; logic: assetcat.lua, assetthumbs.lua.
--
-- Commands: assets.open (Ctrl+Alt+A), assets.window, assets.prune.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'assets.open', title = 'Window: asset browser', keys = 'Ctrl+Alt+A', run = function()
    local Shell = import('/lua/editor/gui/shell.lua')
    if Shell.FindPanelHost('assets') then
        Shell.FocusPanel('assets')
    else
        Shell.OpenPanelWindow('assets', 900, 560)
    end
end }

Commands.Register{ id = 'assets.window', title = 'Window: asset browser in its own window', run = function()
    import('/lua/editor/gui/shell.lua').OpenPanelWindow('assets', 900, 560)
end }

Commands.Register{ id = 'assets.prune', title = 'Window: delete outdated asset browser thumbnails', run = function()
    local n = import('/lua/editor/assetthumbs.lua').PruneOldVersions()
    pcall(function() import('/lua/editor/ui.lua').Say('deleted ' .. n .. ' old picture file(s)') end)
end }

Menu.Extend('menubar.Window', function()
    return {
        { command = 'assets.open' },
        { command = 'assets.window' },
        { command = 'assets.prune' },
    }
end, 20)
