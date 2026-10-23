-- Settings: File > Settings... opens the Settings panel (graphics quality, size of the interface) in a window of its own. The saved graphics settings are applied by feature_start.lua
-- when a session starts (graphics.lua; the editor defaults to the highest quality). Self-registering (gui/feature_*.lua are imported by the shell).
--
-- Commands: settings.open, dev.gpu.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

Commands.Register{ id = 'settings.open', title = 'File: settings...', run = function()
    import('/lua/editor/gui/shell.lua').OpenPanelWindow('settings', 560, 700)
end }

-- dev.gpu: the state of the GPU compute backend and the result of its self test, in the Console panel (and the log). Run this first on a new machine.
Commands.Register{ id = 'dev.gpu', title = 'GPU compute: show the adapter and run the self test (results in the Console panel)', run = function()
    local Graphics = import('/lua/editor/graphics.lua')
    local lines = Graphics.GpuReport(true)
    local captured = false
    pcall(function() captured = import('/lua/editor/consolelog.lua').Installed() end)
    for _, text in lines do
        LOG('EDITOR gpu: ' .. text)
        -- the Console panel records LOG itself once consolelog.lua is installed: a second copy through Model.Log would show every line twice
        if not captured then pcall(function() import('/lua/editor/gui/model.lua').Log(text) end) end
    end
    local last = lines[table.getn(lines)]
    if last then pcall(function() import('/lua/editor/ui.lua').Say(last) end) end
end }

Menu.Extend('menubar.File', function()
    return {
        { command = 'settings.open' },
    }
end, 60)
