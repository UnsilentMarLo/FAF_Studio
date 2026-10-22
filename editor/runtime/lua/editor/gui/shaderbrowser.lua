-- The terrain shader browser (Layers panel > Shader): every terrain shader of the game's shader file with a search, the family it belongs to, what it does, a table of what each layer holds for
-- it (albedo and normal map) and notes on how to use it. Data: shaders.lua (descriptions, layer tables, discovery of new shaders). One modal dialog like the other browsers.
-- The info column keeps its title and tabs fixed; everything below scrolls (textview.lua), so nothing leaves the dialog. The dialog is clamped to the window.
-- "Use this shader" only switches the shader; "Convert layers..." (convertdialog.lua) also converts the paint masks, the layer slots and the Upper layer to the shader's format.
--
--   Open(done[, opts])   done(shaderId) is called after the user chose one and the map uses it (or converted the layers to it); opts.convert: the browser is for choosing the shader to convert to
--
-- Lua 5.0 dialect.

local Dialog = import('/lua/editor/gui/dialog.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Shaders = import('/lua/editor/shaders.lua')
local TextView = import('/lua/editor/gui/textview.lua')

last = false      -- the open browser: for the self test

local function Words(query)
    local words = {}
    for w in string.gfind(string.lower(query or ''), '%S+') do table.insert(words, w) end
    return words
end

--- The shaders that contain every word of the query (in the name, the family, the summary or the notes).
function Filter(all, query)
    local words = Words(query)
    if table.getn(words) == 0 then return all end
    local out = {}
    for _, s in all do
        local hay = string.lower(s.name .. ' ' .. s.family .. ' ' .. s.summary .. ' ' .. s.instructions)
        local ok = true
        for _, w in words do
            if not string.find(hay, w, 1, true) then ok = false break end
        end
        if ok then table.insert(out, s) end
    end
    return out
end

local function FamilyLabel(id)
    for _, f in Shaders.Families do
        if f.id == id then return f.label end
    end
    return id
end

function Open(done, opts)
    opts = opts or {}
    -- the dialog follows the window: never taller or wider than the screen (logical pixels)
    local frame = GetFrame(0)
    local WIDTH = math.max(600, math.min(800, math.floor(frame.Width() / Skin.scale) - 40))
    local HEIGHT = math.max(420, math.min(590, math.floor(frame.Height() / Skin.scale) - 60))
    local d = Dialog.Open(opts.convert and 'Terrain shader: choose the one to convert the layers to' or 'Terrain shader', WIDTH, HEIGHT)
    local c = Skin.color
    local all = Shaders.List()
    local state = { all = all, shown = all, sel = false, info = {}, fixed = {}, say = {}, current = Shaders.Current(), tab = 'layers', dialog = d, width = WIDTH, height = HEIGHT }
    for i, s in all do
        if s.id == state.current then state.sel = i end
    end
    last = state

    -- the info column (right of the list): title, family and the two tabs stay put, the text below them scrolls
    local X = 332
    local INFOW = WIDTH - X - 14
    local VIEW_Y, VIEW_BOTTOM = 136, HEIGHT - 140
    local SAY_Y = HEIGHT - 134

    d:Label('Search', 14, 34, { color = c.textDim })
    local list, tabLayers, tabNotes, convert, use, view
    local function Selected()
        return state.sel and state.shown[state.sel] or nil
    end
    local function Own(ctl)
        table.insert(state.fixed, ctl)
        if ctl.label then table.insert(state.fixed, ctl.label) end
        return ctl
    end

    --- Controls that exist now, for the layout self test.
    function state.controls()
        local out = {}
        for _, t in { state.fixed, state.info, state.say, view:Controls() } do
            for _, ctl in t do table.insert(out, ctl) end
        end
        return out
    end

    local function ClearInfo()
        for _, ctl in state.info do ctl:Destroy() end
        state.info = {}
    end
    local function Text(text, x, y, o)
        local l = d:Label(text, x, y, o)
        W.Fit(l, text, Skin.S(INFOW))
        table.insert(state.info, l)
        return y + 18
    end
    --- A message under the info column (an error of a button): wrapped, at most three lines.
    local function Say(text)
        for _, l in state.say do l:Destroy() end
        state.say = {}
        if text and text ~= '' then
            local lines = W.Paragraph(d.group, text, Skin.S(X), Skin.S(SAY_Y), Skin.S(INFOW), { color = c.error, size = 'small' }, Skin.S(14), Skin.S(SAY_Y + 43))
            for _, l in lines do
                d:Raise(l)
                table.insert(state.say, l)
            end
        end
    end

    -- the layer table: one row per layer, aligned columns; a row is as tall as its tallest wrapped cell
    local function DrawTable(rows)
        local inner = view.innerW
        local layerW = 56
        local albedoW = math.floor((inner - layerW - 12) * 0.54)
        local normalW = inner - layerW - albedoW - 12
        local dim = c.textDim
        view:Row({ { 'Layer', layerW, dim }, { 'Albedo (colour)', albedoW, dim }, { 'Normal map', normalW, dim } }, { before = 12 })
        for _, row in rows do
            view:Row({ { row.layer, layerW, dim }, { row.albedo, albedoW, c.text }, { row.normal, normalW, c.text } })
        end
    end

    local function ShowInfo()
        ClearInfo()
        view:Clear()
        local s = Selected()
        if not s then
            tabLayers:SetHidden(true)
            tabNotes:SetHidden(true)
            convert:SetHidden(true)
            Text('No shader matches the search.', X, 64, { color = c.textDim })
            view:Show()
            return
        end
        tabLayers:SetHidden(false)
        tabNotes:SetHidden(false)
        convert:SetHidden(false)
        Text(s.name .. (s.id == state.current and '   (used by this map)' or ''), X, 62, { color = (s.id == state.current) and c.accent or c.text })
        Text(FamilyLabel(s.family), X, 82, { color = c.textDim, size = 'small' })
        tabLayers:SetOn(state.tab == 'layers')
        tabNotes:SetOn(state.tab == 'notes')
        W.Flow(d.group, { { tabLayers, 110 }, { tabNotes, 110 } }, Skin.S(X), Skin.S(104), Skin.S(INFOW), Skin.S(24), Skin.S(6))
        if not s.listed then
            -- (a shader the editor has no notes about: still usable)
            view:Text('Not described by the editor yet.', { color = c.warn })
        end
        if state.tab == 'layers' then
            view:Text(s.summary, { size = 'text' })
            -- the masks of the map are in the encoding of its shader: a shader that reads them the other way changes the picture
            local mis = Shaders.Mismatch()           -- masks left in the range of the shader they were made for by an earlier plain switch
            local maskRange = mis and mis.range or Shaders.RangeOf(state.current)
            if s.profile and Shaders.RangeOf(s.id) ~= maskRange then
                view:Text('This shader reads paint masks in the ' .. s.profile.range .. ' range, the map\'s are in the ' .. maskRange .. ' range: "Use this shader" changes how the paint looks; "Convert layers..." keeps the picture.',
                    { color = c.warn })
            end
            if s.rows then
                DrawTable(s.rows)
                for _, line in s.notes or {} do
                    view:Text(line, { color = c.textDim, before = 8 })
                end
            else
                view:Text('The editor has no layer table for this shader. Read the comment above it in effects/terrain.fx.', { color = c.textDim, before = 8 })
            end
        else
            if s.layout ~= '' then
                view:Heading('Textures', { before = 0 })
                view:Text(s.layout)
            end
            view:Heading('How to use it')
            view:Text(s.instructions)
        end
        view:Show()
    end
    state.show = ShowInfo

    list = W.VirtualList(d.group, {
        extra = true, rowH = 34,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local s = state.shown[index]
            local active = s.id == state.current
            W.Fit(row.text, s.name, math.max(Skin.S(40), row.bg.Width() - Skin.S(20)))
            row.text:SetColor(active and c.accent or c.text)
            W.Fit(row.extra, FamilyLabel(s.family), math.max(Skin.S(40), row.bg.Width() - Skin.S(20)))
            row.extra:SetColor(c.textDim)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.text.Top:Set(function() return row.bg.Top() + Skin.S(3) end)
            row.extra.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + Skin.S(18) end)
        end,
        onSelect = function(index)
            state.sel = index
            list:SetSelected(index)
            ShowInfo()
        end,
        bgColor = c.panel,
    })
    list:SetRect(Skin.S(14), Skin.S(62), Skin.S(304), Skin.S(HEIGHT - 150))
    state.list = list
    d:Raise(list.root)

    local field = d:Field(70, 30, 248, 22, { text = '', onChange = function(text)
        local keep = Selected()
        state.shown = Filter(state.all, text)
        state.sel = false
        for i, s in state.shown do
            if keep and s.id == keep.id then state.sel = i end
        end
        if not state.sel and table.getn(state.shown) > 0 then state.sel = 1 end
        list:Refresh()
        if state.sel then list:SetSelected(state.sel) end
        ShowInfo()
    end })
    table.insert(state.fixed, field.frame)

    use = Own(d:Button('Use this shader', 14, HEIGHT - 84, 128, 28, function()
        local s = Selected()
        if not s then return end
        local ok, why = Shaders.Set(s.id)
        if not ok then Say(tostring(why)) return end
        Dialog.Close()
        if done then done(s.id) end
    end, { tip = 'Make the map draw its terrain with the chosen shader. Only the shader changes: paint masks, textures and layers stay as they are (use Convert layers... to adapt them).' }))
    convert = Own(d:Button('Convert layers...', 150, HEIGHT - 84, 140, 28, function()
        local s = Selected()
        if not s then return end
        if s.id == state.current and not Shaders.Mismatch() then Say('The map already uses ' .. s.id) return end
        if not (s.profile and s.profile.supported) then Say('The editor cannot convert layers to ' .. s.id .. (s.profile and s.profile.reason and (': ' .. s.profile.reason) or '')) return end
        Say('')
        import('/lua/editor/gui/convertdialog.lua').Open(s.id, function() if done then done(s.id) end end)
    end, { tip = 'Change the shader and convert the map\'s layers to its format in one undo step: paint masks re-encoded where the mask range differs, layer 8 handled, the Upper layer replaced where it must be. A dialog lists what is done and what is not.' }))
    if opts.convert then convert:SetOn(true) end
    Own(d:Button('Close', WIDTH - 110, HEIGHT - 84, 96, 28, function() Dialog.Close() end, { tip = 'Close without changing the shader.' }))

    tabLayers = Own(d:Button('Layers', X, 104, 110, 24, function()
        state.tab = 'layers'
        ShowInfo()
    end, { toggle = true, tip = 'A table of what each layer (Base, layers 1 to 8, Upper) holds for this shader: the albedo (colour) texture and the normal map.' }))
    tabNotes = Own(d:Button('Notes', X + 116, 104, 110, 24, function()
        state.tab = 'notes'
        ShowInfo()
    end, { toggle = true, tip = 'How the textures of this shader have to be made and how to use it.' }))
    view = TextView.New(d, X, VIEW_Y, INFOW, VIEW_BOTTOM - VIEW_Y)
    state.view = view

    if state.sel then list:SetSelected(state.sel) list:ScrollTo(state.sel) end
    ShowInfo()
    return state
end
