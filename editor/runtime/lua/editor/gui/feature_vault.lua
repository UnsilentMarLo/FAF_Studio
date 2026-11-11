-- File > FAF vault...: search the FAF map vault, download a map and open it (gui/panels_vault.lua, vault.lua). A self-registering feature module (gui/feature_*.lua are imported by the
-- shell). The start screen has a button for the same page. In an exe without the ed_vault natives the command says so instead of opening anything.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'file.vault', title = 'File: FAF vault (search and download maps)', run = function()
    import('/lua/editor/gui/panels_vault.lua').Open()
end }

Menu.Extend('menubar.File', function()
    return {
        { command = 'file.vault' },
    }
end, 6)
