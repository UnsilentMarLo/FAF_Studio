-- Edit > Mirror the whole half...: copies everything of one region of the symmetry to the other regions (mirrorhalf.lua, dialogs_mirror.lua). A self-registering feature module
-- (gui/feature_*.lua are imported by the shell).
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Tools = import('/lua/editor/tools.lua')

Commands.Register{ id = 'edit.mirror.half', title = 'Edit: mirror one half onto the other...', run = function()
    import('/lua/editor/gui/dialogs_mirror.lua').Open()
end }

Menu.Extend('menubar.Edit', function()
    return {
        { command = 'edit.mirror.half', nokeys = true, enabled = function() return not Tools.ReadOnly and import('/lua/editor/mirror.lua').Available() end,
          why = function() if Tools.ReadOnly then return 'read-only workspace' end return 'set a symmetry mode first' end },
    }
end, 41)
