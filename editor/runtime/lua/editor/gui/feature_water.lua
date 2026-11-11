-- File > Import / Export of the shore wave generators (.scmwaves, FAForeverMapEditor's waves file), beside the FAFME block of feature_fafme.lua. A self-registering feature module
-- (gui/feature_*.lua are imported by the shell). The water bodies and the wave generators themselves: water.lua, panels_waterbodies.lua. `.scmwtr` (the water settings) is fafme.lua's.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

local function W()
    return import('/lua/editor/water.lua')
end

Commands.Register{ id = 'file.import_waves', title = 'File: import wave generators (.scmwaves)...', run = function() pcall(function() W().ImportWaves() end) end }
Commands.Register{ id = 'file.export_waves', title = 'File: export wave generators (.scmwaves)...', run = function() pcall(function() W().ExportWaves() end) end }

Menu.Extend('menu.import', function()
    return { { header = true, title = 'Water' }, { title = 'Shore waves (.scmwaves)...', command = 'file.import_waves' } }
end, 31)

Menu.Extend('menu.export', function()
    return { { header = true, title = 'Water' }, { title = 'Shore waves (.scmwaves)...', command = 'file.export_waves' } }
end, 31)
