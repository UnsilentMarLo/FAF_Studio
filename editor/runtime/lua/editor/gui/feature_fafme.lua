-- File > Import / Export of the FAFME preset files (markers, units, prop paint sets, texture layers and layer sets, lighting, sky, water). A self-registering feature module
-- (gui/feature_*.lua are imported by the shell): the commands run fafme.lua, which asks for the file, converts it with upstream's logic and says what it did on the status line.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')

local function F()
    return import('/lua/editor/fafme.lua')
end

local function Run(fn)
    return function() pcall(function() F()[fn]() end) end
end

local KINDS = {
    { id = 'markers', import = 'ImportMarkers', export = 'ExportMarkers', title = 'Markers (.fafmapmarkers)...' },
    { id = 'units', import = 'ImportUnits', export = 'ExportUnits', title = 'Units (.scunits)...' },
    { id = 'paintset', import = 'ImportPaintSet', export = 'ExportPaintSet', title = 'Prop paint set (.proppaintset)...' },
    { id = 'layers', import = 'ImportLayers', export = 'ExportLayers', title = 'Texture layer set (.scmst)...' },
    { id = 'lighting', import = 'ImportLighting', export = 'ExportLighting', title = 'Lighting (.scmlighting)...' },
    { id = 'sky', import = 'ImportSky', export = 'ExportSky', title = 'Sky (.scmskybox)...' },
    { id = 'water', import = 'ImportWater', export = 'ExportWater', title = 'Water (.scmwtr)...' },
}

for _, k in KINDS do
    local kind = k
    Commands.Register{ id = 'file.import_' .. kind.id, title = 'File: import ' .. kind.title, run = Run(kind.import) }
    Commands.Register{ id = 'file.export_' .. kind.id, title = 'File: export ' .. kind.title, run = Run(kind.export) }
end

-- one texture layer (.scmsl): the layer is part of the command
local LAYER_NAMES = { [0] = 'Base', 'Layer 1', 'Layer 2', 'Layer 3', 'Layer 4', 'Layer 5', 'Layer 6', 'Layer 7', 'Layer 8', 'Upper' }
for i = 0, 9 do
    local layer = i
    Commands.Register{ id = 'file.import_layer' .. layer, title = 'File: import texture layer (' .. LAYER_NAMES[layer] .. ')...', run = function() pcall(function() F().ImportLayer(layer) end) end }
    Commands.Register{ id = 'file.export_layer' .. layer, title = 'File: export texture layer (' .. LAYER_NAMES[layer] .. ')...', run = function() pcall(function() F().ExportLayer(layer) end) end }
end

local function LayerItems(prefix)
    local items = {}
    for i = 0, 9 do
        table.insert(items, { title = LAYER_NAMES[i], command = prefix .. i })
    end
    return items
end

Menu.Extend('menu.import', function()
    local items = { { header = true, title = 'FAFME files' } }
    for _, k in KINDS do
        table.insert(items, { title = k.title, command = 'file.import_' .. k.id })
    end
    table.insert(items, { title = 'Texture layer (.scmsl)', submenu = LayerItems('file.import_layer') })
    return items
end, 30)

Menu.Extend('menu.export', function()
    local items = { { header = true, title = 'FAFME files' } }
    for _, k in KINDS do
        table.insert(items, { title = k.title, command = 'file.export_' .. k.id })
    end
    table.insert(items, { title = 'Texture layer (.scmsl)', submenu = LayerItems('file.export_layer') })
    return items
end, 30)
