-- The Water bodies and Shore waves panels of the Environment workspace.
--
-- Water bodies: lakes, pools and rivers at their own levels, and dry ground below the sea (faf-re docs/WATER_BODIES.md): the list of the map's bodies, the level and shading of the chosen
-- body, its seed and outline (picked on the map with the Water body tool), its bounds, and what the game's fill made of it. The open map shows the bodies as the game fills them.
-- Shore waves: wave generators along the shore of the sea (the wave section of the .scmap) made with upstream's rules, and FAForeverMapEditor's .scmwaves files.
-- Both live in water.lua; every change is an undo step.
--
-- Lua 5.0 dialect.

local Rows = import('/lua/editor/gui/envrows.lua')
local Water = import('/lua/editor/water.lua')

local STACK = { workspace = 'Environment', with = 'water' }

local function UI() return import('/lua/editor/ui.lua') end

local function Body()
    return Water.Bodies()[Water.Selected]
end

local function MapSize()
    local w, h = ed_terrain_info()
    return (w or 257) - 1, (h or 257) - 1
end

local function ToolOn(mode)
    if not Body() then return end
    Water.Mode = mode
    pcall(function() UI().SelectTool('waterbody') end)
    Water.Draw()
end

--- A number field of the chosen body as a slider entry; `shown` is what the slider shows while the body does not have the field.
local function Field(label, name, min, max, step, shown)
    return { label, min, max, step, '%.1f',
        function()
            local b = Body()
            if not b then return 0 end
            local v = b[name]
            if v == nil then return shown and shown(b) or 0 end
            return v
        end,
        function(v) if Body() then Water.Set(Water.Selected, name, v) end end }
end

local function BoundsField(label, k, max)
    return { label, 0, max, 1, '%d',
        function()
            local b = Body()
            return b and b.Bounds and b.Bounds[k] or 0
        end,
        function(v)
            local b = Body()
            if not b or not b.Bounds then return end
            local r = { b.Bounds[1], b.Bounds[2], b.Bounds[3], b.Bounds[4] }
            r[k] = v
            Water.SetBounds(Water.Selected, r[1], r[2], r[3], r[4])
        end }
end

local function Describe(i, b)
    local text = tostring(i) .. ': '
    if b.Dry then text = text .. 'dry below ' .. string.format('%.1f', b.FillTo or 0)
    else text = text .. 'water at ' .. string.format('%.1f', b.Elevation or 0) end
    return text
end

local function ReportLine(k)
    return function()
        local lines = {}
        local r = Water.Report[Water.Selected]
        if r then
            if r.cells then
                table.insert(lines, string.format('%d cells, x %d-%d, z %d-%d', r.cells, r.x0 or 0, r.x1 or 0, r.z0 or 0, r.z1 or 0))
            end
            if r.message and r.message ~= '' then table.insert(lines, r.message) end
        end
        for _, o in Water.Other do table.insert(lines, o) end
        if table.getn(lines) == 0 and Body() then table.insert(lines, 'not filled yet') end
        return lines[k] or ''
    end
end

local rows = {
    { 'section', 'Water bodies' },
    { 'note', function()
        local n = Water.Count()
        if n == 0 then return 'No water bodies: the map has its sea only.' end
        local b = Body()
        return string.format('Body %d of %d   %s', Water.Selected, n, b and Describe(Water.Selected, b) or '')
    end },
    { 'buttons',
        { 'Add', 56, function() Water.Add() end },
        { 'Copy', 56, function() if Body() then Water.Duplicate(Water.Selected) end end },
        { 'Remove', 64, function() if Body() then Water.Remove(Water.Selected) end end },
        { '< Prev', 60, function() Water.Select(Water.Selected - 1) end },
        { 'Next >', 60, function() Water.Select(Water.Selected + 1) end },
    },
    { 'toggle', 'Dry (no water)', function() local b = Body(); return b and b.Dry == true or false end,
        function(on) if Body() then Water.SetDry(Water.Selected, on) end end },
    { 'single', 'Water level', -100, 500, 0.5, '%.1f',
        function() local b = Body(); return b and b.Elevation or 0 end,
        function(v) if Body() then Water.Set(Water.Selected, 'Elevation', v) end end },
    { 'single', 'Fill below', -100, 500, 0.5, '%.1f',
        function() local b = Body(); return b and (b.FillTo or b.Elevation) or 0 end,
        function(v) if Body() then Water.Set(Water.Selected, 'FillTo', v) end end },
    { 'group',
        Field('Deep', 'Deep', -100, 500, 0.5, function(b) return (b.Elevation or 0) - 2.5 end),
        Field('Abyss', 'Abyss', -100, 500, 0.5, function(b) return (b.Elevation or 0) - 15 end) },
    { 'buttons',
        { 'Level fills', 74, function() if Body() then Water.Clear(Water.Selected, 'FillTo') end end },
        { 'Default shading', 110, function() if Body() then Water.Clear(Water.Selected, 'Deep'); Water.Clear(Water.Selected, 'Abyss') end end },
    },
    { 'section', 'Where it fills' },
    { 'note', function()
        local b = Body()
        if not b then return '' end
        local s = b.Seed and string.format('seed at %d, %d', b.Seed[1], b.Seed[2]) or 'no seed'
        local o = b.Outline and string.format('outline of %d points', table.getn(b.Outline)) or 'no outline'
        return s .. '   ' .. o
    end },
    { 'buttons',
        { 'Pick seed', 80, function() ToolOn('seed') end },
        { 'Draw outline', 96, function() ToolOn('outline') end },
        { 'Clear outline', 96, function() if Body() then Water.ClearOutline(Water.Selected) end end },
        { 'No seed', 64, function() if Body() then Water.ClearSeed(Water.Selected) end end },
    },
    { 'toggle', 'Bounds', function() local b = Body(); return b and b.Bounds ~= nil or false end,
        function(on)
            local b = Body()
            if not b then return end
            if on then
                local mw, mh = MapSize()
                local cx, cz = b.Seed and b.Seed[1] or mw / 2, b.Seed and b.Seed[2] or mh / 2
                Water.SetBounds(Water.Selected, cx - 64, cz - 64, cx + 64, cz + 64)
            else
                Water.ClearBounds(Water.Selected)
            end
        end },
    { 'group', BoundsField('x from', 1, 4096), BoundsField('z from', 2, 4096) },
    { 'group', BoundsField('x to', 3, 4096), BoundsField('z to', 4, 4096) },
    { 'section', 'What the game fills' },
    { 'note', ReportLine(1) },
    { 'note', ReportLine(2) },
    { 'note', ReportLine(3) },
    { 'toggle', 'Show guides', function() return Water.Guides end,
        function(on) Water.Guides = on; Water.Draw() end },
}

Rows.Build{ id = 'waterbodies', title = 'Water bodies', rows = rows, stack = STACK, minW = 260, minH = 200 }

-- ---- shore waves ---------------------------------------------------------------------------------------------------------------------------------

local waves = { pattern = 1, depth = 1.5, density = 0.5, spacing = 12, seed = 1, centre = 180, range = 180, patterns = false }

local function Patterns()
    if not waves.patterns then
        waves.patterns = (rawget(_G, 'ed_waves_patterns') and ed_waves_patterns()) or {}
    end
    return waves.patterns
end

local function Options()
    local p = Patterns()[waves.pattern]
    return { pattern = p, depth = waves.depth, density = waves.density, spacing = waves.spacing, seed = waves.seed, centre = waves.centre, range = waves.range }
end

local wrows = {
    { 'section', 'Shore waves' },
    { 'note', function() return string.format('%d wave generators on the map', Water.WaveCount()) end },
    { 'note', function()
        local p = Patterns()[waves.pattern]
        return 'Pattern: ' .. (p and p.name or '(none)')
    end },
    { 'buttons',
        { '< Pattern', 76, function() waves.pattern = math.max(1, waves.pattern - 1) end },
        { 'Pattern >', 76, function() waves.pattern = math.min(math.max(1, table.getn(Patterns())), waves.pattern + 1) end },
    },
    { 'single', 'Shore depth', 0.2, 12, 0.1, '%.1f', function() return waves.depth end, function(v) waves.depth = v end },
    { 'single', 'Density', 0.02, 1, 0.02, '%.2f', function() return waves.density end, function(v) waves.density = v end },
    { 'group',
        { 'Spacing', 1, 80, 1, '%d', function() return waves.spacing end, function(v) waves.spacing = v end },
        { 'Seed', 1, 9999, 1, '%d', function() return waves.seed end, function(v) waves.seed = math.floor(v) end } },
    { 'group',
        { 'Shore facing', 0, 360, 5, '%d', function() return waves.centre end, function(v) waves.centre = v end },
        { 'Range', 5, 180, 5, '%d', function() return waves.range end, function(v) waves.range = v end } },
    { 'buttons',
        { 'Make (replace)', 100, function() Water.Generate(Options(), 'replace') end },
        { 'Make (add)', 84, function() Water.Generate(Options(), 'add') end },
        { 'Remove all', 84, function() Water.SetWaves({}, 'remove the wave generators') end },
    },
    { 'section', 'Files' },
    { 'buttons',
        { 'Import .scmwaves...', 130, function() Water.ImportWaves() end },
        { 'Export .scmwaves...', 130, function() Water.ExportWaves() end },
    },
    { 'toggle', 'Show generators', function() return Water.WaveGuides end,
        function(on) Water.WaveGuides = on; Water.DrawWaves() end },
}

Rows.Build{ id = 'waves', title = 'Shore waves', rows = wrows, stack = STACK, minW = 260, minH = 200 }

-- the rows read the module's values: they follow its changes (selection, edits, undo)
Water.Listen(function()
    for _, id in { 'waterbodies', 'waves' } do
        local P = Rows.live[id]
        if P and P.Refresh then pcall(P.Refresh, P) end
    end
end)
