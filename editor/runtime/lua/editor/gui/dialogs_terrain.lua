-- Terrain dialogs: Generate terrain (fractal noise over the whole map, terraingen.lua on the field engine) and Flatten map (one height everywhere).
--
--   Generate() / FlattenMap()      open the dialog; the Terrain menu calls these
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Gen = import('/lua/editor/terraingen.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Slider(d, label, key, min, max, step, fmt, x, y, w, params)
    local s = W.Slider(d.group, { label = label, min = min, max = max, step = step, fmt = fmt, compact = true,
        get = function() return params[key] end, set = function(v) params[key] = v end })
    s:Place(Skin.S(x), Skin.S(y), Skin.S(w))
    for _, c in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(c) end
    d:Raise(s.field) d:Raise(s.field.frame)
    return s
end

function Generate()
    local P = {}
    for k, v in Gen.Params do P[k] = v end
    local d = Dialog.Open('Generate terrain (replaces or adds to the heights of the whole map; undo restores them)', 520, 360)
    local c = Skin.color
    local sliders = {}
    table.insert(sliders, Slider(d, 'Seed', 'seed', 0, 9999, 1, '%d', 14, 36, 240, P))
    table.insert(sliders, Slider(d, 'Feature size (units)', 'scale', 10, 600, 5, '%d', 266, 36, 240, P))
    table.insert(sliders, Slider(d, 'Octaves', 'octaves', 1, 8, 1, '%d', 14, 88, 240, P))
    table.insert(sliders, Slider(d, 'Persistence', 'persistence', 0.2, 0.9, 0.05, '%.2f', 266, 88, 240, P))
    table.insert(sliders, Slider(d, 'Height range (units)', 'amplitude', 0, 300, 1, '%d', 14, 140, 240, P))
    table.insert(sliders, Slider(d, 'Base height (units)', 'base', 0, 200, 1, '%d', 266, 140, 240, P))
    table.insert(sliders, Slider(d, 'Island % (border to base)', 'island', 0, 100, 1, '%d', 14, 192, 240, P))

    local modes = { 'fbm', 'ridged', 'billow' }
    local labels = { fbm = 'Rolling', ridged = 'Ridged', billow = 'Billow' }
    local buttons = {}
    d:Label('Style', 266, 196, { color = c.textDim })
    for i, m in modes do
        local mode = m
        buttons[mode] = d:Button(labels[mode], 310 + (i - 1) * 66, 192, 62, 24, function()
            P.mode = mode
            for k, b in buttons do b:SetOn(k == mode) end
        end, { toggle = true })
    end
    buttons[P.mode]:SetOn(true)
    local replace = d:Button('Replace the heights (off: add to them)', 14, 244, 300, 24, function(self) P.replace = self.on end, { toggle = true })
    replace:SetOn(P.replace)
    d:Label('Runs in the native field engine (fields.lua): a 20 km map takes a fraction of a second.', 14, 276, { color = c.textDim, size = 'small' })
    d:Button('Generate', 14, 316, 110, 28, function()
        for k, v in P do Gen.Params[k] = v end
        Dialog.Close()
        local n = Gen.Generate()
        Say('generated terrain: ' .. n .. ' samples')
    end)
    d:Button('Cancel', 134, 316, 100, 28, function() Dialog.Close() end)
end

function FlattenMap()
    local d = Dialog.Open('Flatten the whole map', 420, 150)
    local P = { height = 30 }
    local s = W.Slider(d.group, { label = 'Height (units)', min = 0, max = 300, step = 1, fmt = '%d',
        get = function() return P.height end, set = function(v) P.height = v end })
    s:Place(Skin.S(14), Skin.S(34), Skin.S(390))
    for _, c in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(c) end
    d:Raise(s.field) d:Raise(s.field.frame)
    d:Button('Flatten', 14, 106, 100, 28, function()
        Dialog.Close()
        Gen.Flatten(P.height)
        Say('flattened the map to ' .. P.height)
    end)
    d:Button('Cancel', 124, 106, 100, 28, function() Dialog.Close() end)
end

--- A list of the terrain types (swatch, name, code) with a filter; `done(code)` gets the chosen TypeCode, or false for "the default of the texture".
function PickType(title, current, done)
    local TT = import('/lua/editor/terraintype.lua')
    local d = Dialog.Open(title, 420, 440)
    local c = Skin.color
    local all = { { code = false, name = '(default of the texture)', blocking = false } }
    for _, t in TT.Types() do table.insert(all, t) end
    local state = { shown = all }
    local list
    local field = d:Field(14, 30, 392, 22, {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, t in all do
                if f == '' or string.find(string.lower(t.name), f, 1, true) or (t.code and string.find(tostring(t.code), f, 1, true)) then
                    table.insert(state.shown, t)
                end
            end
            list:Refresh()
        end,
        onEscape = function() Dialog.Close() end,
    })
    list = W.VirtualList(d.group, {
        rowH = 22,
        extra = true,
        thumb = true,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local t = state.shown[index]
            if t.code then row.thumb:SetSolidColor('FF' .. TT.ColorOf(t.code)) else row.thumb:SetSolidColor(c.panelAlt) end
            row.extra:SetText(t.code and tostring(t.code) or '')
            local tx = row.bg.Height() + Skin.S(6)
            W.Fit(row.text, t.name .. (t.blocking and '  (blocks)' or ''), math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(50)))
            row.text:SetColor((t.code == current) and c.accent or c.text)
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + tx end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local t = state.shown[index]
            if t then
                Dialog.Close()
                done(t.code)
            end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), Skin.S(404), Skin.S(366))
    field:AcquireFocus()
end


--- The playable area: four numbers (world units), "whole map", Apply. The area AREA_1 is shown in the world with the other areas.
function PlayableArea()
    local Playable = import('/lua/editor/playable.lua')
    local x0, z0, x1, z1, exists = Playable.Get()
    local w, h = ed_terrain_info()
    local size = (w or 257) - 1
    local P = { x0 = x0, z0 = z0, x1 = x1, z1 = z1 }
    local d = Dialog.Open('Playable area (the area AREA_1 of the map)', 440, 250)
    local c = Skin.color
    local sliders = {}
    local function Row(label, key, y)
        local s = W.Slider(d.group, { label = label, min = 0, max = size, step = 1, fmt = '%d', compact = true,
            get = function() return P[key] end, set = function(v) P[key] = v end })
        return s
    end
    local function Place(s, x, y)
        s:Place(Skin.S(x), Skin.S(y), Skin.S(190))
        for _, c2 in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(c2) end
        d:Raise(s.field) d:Raise(s.field.frame)
    end
    local a, b, c1, d1 = Row('Left (x from)', 'x0'), Row('Top (z from)', 'z0'), Row('Right (x to)', 'x1'), Row('Bottom (z to)', 'z1')
    Place(a, 14, 36) Place(c1, 228, 36)
    Place(b, 14, 92) Place(d1, 228, 92)
    d:Label(exists and 'The map has a playable area already.' or 'No playable area yet: the whole map can be played.', 14, 150, { color = c.textDim, size = 'small' })
    d:Button('Whole map', 14, 172, 110, 26, function()
        P.x0, P.z0, P.x1, P.z1 = 0, 0, size, size
        for _, s in { a, b, c1, d1 } do s:Refresh() end
    end)
    d:Button('Apply', 14, 208, 100, 28, function()
        Dialog.Close()
        if Playable.Set(P.x0, P.z0, P.x1, P.z1) then
            Say('playable area set')
        else
            Say('the playable area must be at least 8 x 8 units')
        end
    end)
    d:Button('Cancel', 124, 208, 100, 28, function() Dialog.Close() end)
end
