-- File > Import / Export (external tools) and Terrain > Live link: opens the Interop panel (panels_interop.lua) on the right page. A self-registering feature module (gui/feature_*.lua
-- are imported by the shell): it adds its own commands and menu items, so no shared file has to be edited.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

local function ShowPage(page)
    local Shell = import('/lua/editor/gui/shell.lua')
    local Panel = import('/lua/editor/gui/panels_interop.lua')
    Panel.state.page = page
    Panel.state.rebuild = true
    if Shell.S.main and not Shell.S.main:ShowPanel('interop') then Shell.S.main:AddPanel('interop') end
end

Commands.Register{ id = 'terrain.import', title = 'Terrain: import heightmap...', run = function()
    ShowPage('heightmap')
    import('/lua/editor/gui/panels_interop.lua').BrowseFile()
end }
Commands.Register{ id = 'terrain.importmasks', title = 'Terrain: import masks...', run = function() ShowPage('masks') end }
Commands.Register{ id = 'terrain.export', title = 'Terrain: export for external tools...', run = function() ShowPage('export') end }
Commands.Register{ id = 'terrain.livelink', title = 'Terrain: live link to Gaea / World Machine...', run = function() ShowPage('link') end }

-- File > Import / Export (menus.lua builds the submenus from these providers) and Terrain > Live link
Menu.Extend('menu.import', function()
    return {
        { title = 'Heightmap from an external tool...', command = 'terrain.import' },
        { title = 'Masks from an external tool...', command = 'terrain.importmasks' },
    }
end, 20)
Menu.Extend('menu.export', function()
    return {
        { title = 'For external tools...', command = 'terrain.export' },
    }
end, 20)
Menu.Extend('menubar.Terrain', function()
    return {
        { command = 'terrain.livelink' },
    }
end, 40)
