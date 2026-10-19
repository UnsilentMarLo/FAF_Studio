-- The Sky panels of the Environment workspace: Sky (the colours of the dome, its size and shape, the cirrus cloud layers) and Sky textures (the atlases of the sun / moon / planet billboards, cirrus and
-- cumulus textures, the sky cube and the background). Numbers are sliders with - / + buttons and a field; every change is an undo step (a drag is one); the engine draws the result at once.
-- See environment.lua (the model), EdEnv.cpp (the engine side) and panels_skyobjects.lua (the billboards themselves).
--
-- Lua 5.0 dialect.

local Rows = import('/lua/editor/gui/envrows.lua')
local Env = import('/lua/editor/environment.lua')

local Num = Rows.Num
local STACK = { workspace = 'Environment', with = 'lighting' }

--- The direction of a cirrus layer as an angle: the engine stores a vector (dx, dz).
local function Direction(i)
    local kx, kz = 'cirrus' .. i .. '_dx', 'cirrus' .. i .. '_dz'
    return { 'Direction (degrees)', 0, 360, 5, '%d',
        function()
            local a = math.deg(math.atan2(Env.Value(kz), Env.Value(kx)))
            if a < 0 then a = a + 360 end
            return a
        end,
        function(v)
            local num = {}
            num[kx] = math.cos(math.rad(v))
            num[kz] = math.sin(math.rad(v))
            Env.Apply({ num = num }, { label = 'cirrus direction', merge = 'dir' .. i })
        end }
end

local function Layer(i)
    return {
        { 'section', 'Cirrus layer ' .. i },
        { 'group', Num('Frequency x', 'cirrus' .. i .. '_fx', 0, 0.01, 0.00005, '%.5f'), Num('Frequency z', 'cirrus' .. i .. '_fz', 0, 0.01, 0.00005, '%.5f') },
        { 'group', Num('Speed', 'cirrus' .. i .. '_speed', 0, 12, 0.05), Direction(i) },
    }
end

local rows = {
    { 'section', 'Colours' },
    { 'group', Num('Horizon R', 'horizon_r', 0, 2), Num('Horizon G', 'horizon_g', 0, 2), Num('Horizon B', 'horizon_b', 0, 2) },
    { 'group', Num('Sky R', 'sky_r', 0, 2), Num('Sky G', 'sky_g', 0, 2), Num('Sky B', 'sky_b', 0, 2) },
    { 'single', 'Horizon band size', 0, 8000, 1, '%d', function() return Env.Value('horizon_size') end, function(v) Env.SetNumber('horizon_size', v, 'horizon size') end },
    { 'single', 'Sun, moon and planet glow', 0, 2, 0.01, '%.2f', function() return Env.Value('horizon_blend') end, function(v) Env.SetNumber('horizon_blend', v, 'sky glow') end },
    { 'section', 'Dome' },
    { 'single', 'Dome height (the horizon)', -1000, 1000, 0.5, '%.1f', function() return Env.Value('dome_height') end, function(v) Env.SetNumber('dome_height', v, 'dome height') end },
    { 'single', 'Dome radius', 50, 40000, 10, '%d', function() return Env.Value('dome_radius') end, function(v) Env.SetNumber('dome_radius', v, 'dome radius') end },
    { 'single', 'Dome start angle', 0, 1.5, 0.01, '%.2f', function() return Env.Value('dome_start') end, function(v) Env.SetNumber('dome_start', v, 'dome angle') end },
    { 'group', Num('Segments around', 'dome_w', 4, 64, 1, '%d'), Num('Segments up', 'dome_h', 2, 32, 1, '%d') },
    { 'section', 'Cirrus clouds' },
    { 'single', 'Cirrus strength', 0, 4, 0.05, '%.2f', function() return Env.Value('cirrus_mult') end, function(v) Env.SetNumber('cirrus_mult', v, 'cirrus strength') end },
    { 'group', Num('Cirrus R', 'cirrus_r', 0, 3), Num('Cirrus G', 'cirrus_g', 0, 3), Num('Cirrus B', 'cirrus_b', 0, 3) },
}
for i = 1, 4 do
    for _, r in Layer(i) do table.insert(rows, r) end
end

Rows.Build{ id = 'sky', title = 'Sky', rows = rows, stack = STACK, minW = 240, minH = 160 }

local ENVIRONMENT = { { '/textures/environment', '*.dds' } }

Rows.Build{ id = 'skytex', title = 'Sky textures', stack = STACK, minW = 240, minH = 160, rows = {
    { 'section', 'Billboards (sun, moon, planets)' },
    { 'texture', 'Billboard atlas', 'sky_billboards', ENVIRONMENT, { none = 'no billboards texture' } },
    { 'texture', 'Billboard glow atlas', 'sky_glow', ENVIRONMENT, { none = 'no glow texture' } },
    { 'section', 'Clouds' },
    { 'texture', 'Cirrus', 'sky_cirrus', ENVIRONMENT, { none = 'no cirrus texture' } },
    { 'texture', 'Cumulus 1', 'sky_cumulus1', ENVIRONMENT, { none = 'none' } },
    { 'texture', 'Cumulus 2', 'sky_cumulus2', ENVIRONMENT, { none = 'none' } },
    { 'texture', 'Cumulus 3', 'sky_cumulus3', ENVIRONMENT, { none = 'none' } },
    { 'section', 'Cube map and background' },
    { 'texture', 'Sky cube (reflected by everything shiny)', 'skycube', ENVIRONMENT, { thumbs = false,
        match = function(p) return string.find(string.lower(p), 'cube', 1, true) ~= nil end } },
    { 'texture', 'Background', 'background', ENVIRONMENT, { match = function(p) return not string.find(string.lower(p), 'cube', 1, true) end } },
} }
