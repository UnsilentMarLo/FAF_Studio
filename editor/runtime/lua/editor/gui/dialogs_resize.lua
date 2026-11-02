-- The Resize map dialog (Map > Resize map...): new size, crop / expand or scale, anchor, padding, playable area, and the report of what the resize does. The new bounds are drawn in
-- the viewport while the dialog is open. Logic: resize.lua.
--
--   Open()      the dialog
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local R = import('/lua/editor/resize.lua')

local REPORT_LINES = 10

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function KmLabel(n)
    local km = n / 51.2
    return string.format(km == math.floor(km) and '%d km' or '%.1f km', km) .. '  (' .. n .. ')'
end

function Open()
    local O = R.Options
    local d = Dialog.Open('Resize map  (creates a resized copy; the open map is unchanged)', 620, 468, function() R.ClearBounds() end)
    local c = Skin.color
    local sizeButtons, modeButtons, anchorButtons, fillButtons, playButtons = {}, {}, {}, {}, {}
    local lines = {}
    local ok = false
    local go

    local function Redraw()
        local plan = R.Plan(O)
        ok = not plan.error
        for i = 1, REPORT_LINES do
            local text = ''
            local color = c.text
            if plan.error then
                if i == 1 then text = plan.error color = c.error end
            else
                text = plan.lines[i] or ''
                if string.find(text, 'START POSITIONS DROPPED', 1, true) then color = c.error end
            end
            lines[i]:SetText(text)
            lines[i]:SetColor(color)
        end
        R.ShowBounds(plan)
        for i, n in R.Sizes do sizeButtons[i]:SetOn(O.size == n) end
        modeButtons.canvas:SetOn(O.mode == 'canvas')
        modeButtons.scale:SetOn(O.mode == 'scale')
        for key, b in anchorButtons do
            local ax, az = b.ax, b.az
            b:SetOn(O.mode == 'canvas' and O.ax == ax and O.az == az)
        end
        fillButtons.edge:SetOn(O.fill ~= 'level')
        fillButtons.level:SetOn(O.fill == 'level')
        playButtons.keep:SetOn(O.playable ~= 'whole')
        playButtons.whole:SetOn(O.playable == 'whole')
    end

    -- new size
    d:Label('New size', 14, 40, { color = c.textDim })
    local sizeRow = {}
    for i, n in R.Sizes do
        local size = n
        local available = R.TemplateAvailable(n)
        sizeButtons[i] = d:Button(KmLabel(n), 0, 0, 98, 24, function()
            O.size = size
            Redraw()
        end, { toggle = true })
        sizeRow[i] = { sizeButtons[i], 98 }
        if not available then sizeButtons[i]:SetText(tostring(n) .. ' (missing)') end
    end
    local y = d:Flow(sizeRow, 36, 24, 100) + 12
    -- how
    d:Label('How', 14, y + 4, { color = c.textDim })
    modeButtons.canvas = d:Button('Crop or expand (the terrain stays)', 0, 0, 250, 24, function() O.mode = 'canvas' Redraw() end, { toggle = true })
    modeButtons.scale = d:Button('Scale the whole map', 0, 0, 200, 24, function() O.mode = 'scale' Redraw() end, { toggle = true })
    y = d:Flow({ { modeButtons.canvas, 250 }, { modeButtons.scale, 200 } }, y, 24, 100) + 14
    -- anchor
    local anchorTop = y
    d:Label('Anchor', 14, anchorTop, { color = c.textDim })
    d:Label('where the old map', 14, anchorTop + 18, { color = c.textDim, size = 'small', maxW = function() return Skin.S(80) end })
    d:Label('sits in the new one', 14, anchorTop + 32, { color = c.textDim, size = 'small', maxW = function() return Skin.S(80) end })
    local names = { { 'NW', 0, 0 }, { 'N', 0.5, 0 }, { 'NE', 1, 0 }, { 'W', 0, 0.5 }, { 'C', 0.5, 0.5 }, { 'E', 1, 0.5 }, { 'SW', 0, 1 }, { 'S', 0.5, 1 }, { 'SE', 1, 1 } }
    for i, a in names do
        local col, row = math.mod(i - 1, 3), math.floor((i - 1) / 3)
        local ax, az = a[2], a[3]
        local b = d:Button(a[1], 100 + col * 38, anchorTop - 6 + row * 30, 36, 26, function() O.ax, O.az = ax, az Redraw() end, { toggle = true })
        b.ax, b.az = ax, az
        anchorButtons[i] = b
    end
    -- padding
    d:Label('Padding', 232, anchorTop, { color = c.textDim, maxW = function() return Skin.S(64) end })
    fillButtons.edge = d:Button('Repeat the edge heights', 300, anchorTop - 6, 230, 26, function() O.fill = 'edge' Redraw() end, { toggle = true })
    fillButtons.level = d:Button('Constant height', 300, anchorTop + 24, 230, 26, function() O.fill = 'level' Redraw() end, { toggle = true })
    local s = W.Slider(d.group, { label = 'Padding height (units)', min = 0, max = 300, step = 1, fmt = '%d', compact = true,
        get = function() return O.level end, set = function(v) O.level = v O.fill = 'level' Redraw() end })
    s:Place(Skin.S(232), Skin.S(anchorTop + 54), Skin.S(math.min(300, d:Span(232))))
    for _, ctl in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(ctl) end
    d:Raise(s.field) d:Raise(s.field.frame)
    -- playable area
    local playTop = anchorTop + 106
    d:Label('Playable area', 14, playTop + 4, { color = c.textDim })
    playButtons.keep = d:Button('Keep it (moved with the map)', 0, 0, 230, 24, function() O.playable = 'keep' Redraw() end, { toggle = true })
    playButtons.whole = d:Button('The whole new map', 0, 0, 200, 24, function() O.playable = 'whole' Redraw() end, { toggle = true })
    y = d:Flow({ { playButtons.keep, 230 }, { playButtons.whole, 200 } }, playTop, 24, 100) + 14
    -- report
    d:Label('What happens', 14, y, { color = c.textDim })
    for i = 1, REPORT_LINES do
        lines[i] = d:Label('', 14, y + 18 + (i - 1) * 16, { color = c.text, size = 'small' })
    end
    y = y + 18 + REPORT_LINES * 16 + 6
    local source = import('/lua/editor/maps.lua').saveDir
    y = d:Text('The copy is saved next to your maps as <name>_<size>; ' .. (source and 'this map is not changed.' or 'save this map first if you want to keep it.'), 14, y, { color = c.textDim, size = 'small' })
    go = d:Button('Resize', 0, 0, 110, 26, function()
        if not ok then return end
        local opts = {}
        for k, v in O do opts[k] = v end
        Dialog.Close()
        import('/lua/editor/gui/dialogs_map.lua').Guard(function()
            local started, why = R.Run(opts)
            if not started then Say('resize failed: ' .. tostring(why)) end
        end)
    end)
    local cancel = d:Button('Cancel', 0, 0, 110, 26, function() Dialog.Close() end)
    d:Flow({ { go, 110 }, { cancel, 110 } }, y + 8, 26)
    Redraw()
end
