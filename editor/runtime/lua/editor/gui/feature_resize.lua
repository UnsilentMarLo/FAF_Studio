-- Map > Resize map...: crop, expand or scale the map to another size (resize.lua, dialogs_resize.lua). A self-registering feature module (gui/feature_*.lua are imported by the shell).
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Tools = import('/lua/editor/tools.lua')

Commands.Register{ id = 'map.resize', title = 'Map: resize map...', run = function()
    import('/lua/editor/gui/dialogs_resize.lua').Open()
end }

Menu.Extend('menubar.Map', function()
    return {
        { command = 'map.resize', enabled = function() return not Tools.ReadOnly end, why = 'read-only workspace' },
    }
end, 12)
