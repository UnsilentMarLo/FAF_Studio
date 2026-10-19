-- The Water motion and Strategic view panels of the Environment workspace.
--
-- Water motion: the water ramp, the water cube map and the four wave normal maps (the files), the size of each wave pattern and how fast and in which direction it moves, with a few starting points
-- (calm lake, choppy, ocean swell, the engine default). Strategic view: the contour spacing and the five colours of the zoomed out map (the engine's "cartographic" settings).
-- Colour and shading of the water stay in the Water look panel (panels_world.lua). All of it is saved in the .scmap by the engine; every change is an undo step.
--
-- Lua 5.0 dialect.

local Rows = import('/lua/editor/gui/envrows.lua')
local Env = import('/lua/editor/environment.lua')

local Num = Rows.Num
local STACK = { workspace = 'Environment', with = 'lighting' }

-- name -> repeat rates (waves 1..4) and movements (x, z per wave)
local PATTERNS = {
    { 'Engine default', { 0.009, 0.009, 0.05, 0.01 }, { 0.5, -0.95, 0.5, 0.95, 0, 0, 0, 0 } },
    { 'Calm lake', { 0.009, 0.009, 0.05, 0.5 }, { 0.037, -0.071, 0.05, -0.095, 0.01, 0.03, 0.0005, 0.0009 } },
    { 'Choppy', { 0.014, 0.011, 0.06, 0.02 }, { 0.9, -0.5, 0.7, 0.8, 0.2, 0.1, 0.05, 0.05 } },
    { 'Ocean swell', { 0.004, 0.006, 0.03, 0.01 }, { 0.3, 0.2, -0.25, 0.3, 0.1, -0.1, 0.02, 0.02 } },
}

local function ApplyPattern(p)
    local num = {}
    for i = 1, 4 do
        num['w_repeat_' .. (i - 1)] = p[2][i]
        num['w_move' .. i .. '_x'] = p[3][2 * i - 1]
        num['w_move' .. i .. '_z'] = p[3][2 * i]
    end
    Env.Apply({ num = num }, { label = 'wave pattern ' .. p[1] })
end

local rows = {
    { 'section', 'Textures' },
    { 'texture', 'Water ramp (colour by depth)', 'water_ramp', { { '/textures/engine', '*ramp*.dds' } }, {} },
    { 'texture', 'Water cube map (sky reflection)', 'water_cubemap', { { '/textures/engine', '*.dds' }, { '/textures/environment', '*.dds' } },
        { thumbs = false, match = function(p) return string.find(string.lower(p), 'cube', 1, true) ~= nil end } },
}
for i = 1, 4 do
    table.insert(rows, { 'texture', 'Wave normal map ' .. i, 'water_wave' .. i, { { '/textures/engine', '*.dds' } },
        { match = function(p) return string.find(string.lower(p), 'wave', 1, true) ~= nil end } })
end
table.insert(rows, { 'section', 'Starting points' })
local buttons = { 'buttons' }
for _, p in PATTERNS do
    local pattern = p
    table.insert(buttons, { pattern[1], 110, function() ApplyPattern(pattern) end })
end
table.insert(rows, buttons)
for i = 1, 4 do
    table.insert(rows, { 'section', 'Wave ' .. i })
    table.insert(rows, { 'group', Num('Scale', 'w_repeat_' .. (i - 1), 0, 0.5, 0.0005, '%.4f'),
        Num('Move x', 'w_move' .. i .. '_x', -2, 2, 0.005, '%.3f'), Num('Move z', 'w_move' .. i .. '_z', -2, 2, 0.005, '%.3f') })
end

Rows.Build{ id = 'watermotion', title = 'Water motion', rows = rows, stack = STACK, minW = 240, minH = 160 }

local NAMES = { 'Deep water', 'Contour lines', 'Shore', 'Land (low)', 'Land (high)' }
local imager = {
    { 'section', 'Contours' },
    { 'single', 'Contour lines (samples)', 0, 128, 1, '%d', function() return Env.Value('topo_samples') end, function(v) Env.SetNumber('topo_samples', v, 'contour lines') end },
    { 'single', 'Height offset', -200, 200, 0.5, '%.1f', function() return Env.Value('imager_offset') end, function(v) Env.SetNumber('imager_offset', v, 'imager offset') end },
}
for i = 0, 4 do
    table.insert(imager, { 'section', NAMES[i + 1] })
    table.insert(imager, { 'group', Num('R', 'hypso' .. i .. '_r', 0, 1, 0.01), Num('G', 'hypso' .. i .. '_g', 0, 1, 0.01),
        Num('B', 'hypso' .. i .. '_b', 0, 1, 0.01), Num('A', 'hypso' .. i .. '_a', 0, 1, 0.01) })
end

Rows.Build{ id = 'imager', title = 'Strategic view', rows = imager, stack = STACK, minW = 240, minH = 160 }
