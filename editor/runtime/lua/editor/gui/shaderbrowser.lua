-- The terrain shader browser (Layers panel > Shader): every terrain shader of the game's shader file with a search, the family it belongs to, what it does, a table of what each layer holds for
-- it (albedo and normal map) and notes on how to use it. Data: shaders.lua (descriptions, layer tables, discovery of new shaders). One modal dialog like the other browsers.
-- "Use this shader" only switches the shader; "Convert layers..." (convertdialog.lua) also converts the paint masks, the layer slots and the Upper layer to the shader's format.
--
--   Open(done[, opts])   done(shaderId) is called after the user chose one and the map uses it (or converted the layers to it); opts.convert: the browser is for choosing the shader to convert to
--
-- Lua 5.0 dialect.

local Dialog = import('/lua/editor/gui/dialog.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Shaders = import('/lua/editor/shaders.lua')

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
    local WIDTH, HEIGHT = 800, 590
    local d = Dialog.Open(opts.convert and 'Terrain shader: choose the one to convert the layers to' or 'Terrain shader', WIDTH, HEIGHT)
    local c = Skin.color
    local all = Shaders.List()
    local state = { all = all, shown = all, sel = false, info = {}, current = Shaders.Current(), tab = 'layers', more = false }
    for i, s in all do
        if s.id == state.current then state.sel = i end
    end
    last = state

    d:Label('Search', 14, 34, { color = c.textDim })
    local list, say, tabLayers, tabNotes, moreBtn, convert, use
    local function Selected()
        return state.sel and state.shown[state.sel] or nil
    end

    local function ClearInfo()
        for _, ctl in state.info do ctl:Destroy() end
        state.info = {}
    end
    local function Text(text, x, y, opts)
        local l = d:Label(text, x, y, opts)
        table.insert(state.info, l)
        return y + 18
    end
    --- A wrapped paragraph; returns the y below it (logical pixels) and whether its text was cut at maxLines / bottom.
    local function Para(text, x, y, w, opts, bottom, lineH)
        local lh = lineH or 16
        local lines, after = W.Paragraph(d.group, text, Skin.S(x), Skin.S(y), Skin.S(w), opts, Skin.S(lh), Skin.S(bottom))
        local cut = false
        for _, l in lines do
            d:Raise(l)
            table.insert(state.info, l)
            if string.sub(l:GetText(), -4) == ' ...' then cut = true end
        end
        return math.floor(after / Skin.S(1)) + 4, cut
    end

    -- the layer table: one row per layer, aligned columns, cells wrap inside their column (Maui does not clip)
    local function DrawTable(rows, x, y, w)
        local layerW = 56
        local albedoW = math.floor((w - layerW - 12) * 0.54)
        local normalW = w - layerW - albedoW - 12
        local ax, nx = x + layerW + 4, x + layerW + albedoW + 8
        Text('Layer', x, y, { color = c.textDim, size = 'small' })
        Text('Albedo (colour)', ax, y, { color = c.textDim, size = 'small' })
        Text('Normal map', nx, y, { color = c.textDim, size = 'small' })
        y = y + 18
        for _, row in rows do
            local small = { color = c.text, size = 'small' }
            Text(row.layer, x, y, { color = c.textDim, size = 'small' })
            local y1 = Para(row.albedo, ax, y, albedoW, small, 2000, 14)
            local y2 = Para(row.normal, nx, y, normalW, small, 2000, 14)
            y = math.max(y1, y2, y + 16)
        end
        return y
    end

    local function ShowInfo()
        ClearInfo()
        local s = Selected()
        local x, w = 332, 454
        moreBtn:SetHidden(true)
        if not s then
            tabLayers:SetHidden(true)
            tabNotes:SetHidden(true)
            convert:SetHidden(true)
            Text('No shader matches the search.', x, 64, { color = c.textDim })
            return
        end
        tabLayers:SetHidden(false)
        tabNotes:SetHidden(false)
        convert:SetHidden(false)
        local y = 62
        Text(s.name .. (s.id == state.current and '   (used by this map)' or ''), x, y, { color = (s.id == state.current) and c.accent or c.text })
        y = y + 22
        Text(FamilyLabel(s.family), x, y, { color = c.textDim, size = 'small' })
        y = y + 20
        y = Para(s.summary, x, y, w, { color = c.text }, 200) + 2
        -- the masks of the map are in the encoding of its shader: a shader that reads them the other way changes the picture
        local mis = Shaders.Mismatch()           -- masks left in the range of the shader they were made for by an earlier plain switch
        local maskRange = mis and mis.range or Shaders.RangeOf(state.current)
        if s.profile and Shaders.RangeOf(s.id) ~= maskRange then
            y = Para('This shader reads paint masks in the ' .. s.profile.range .. ' range, the map\'s are in the ' .. maskRange .. ' range: "Use this shader" changes how the paint looks; "Convert layers..." keeps the picture.',
                x, y, w, { color = c.warn, size = 'small' }, 260, 14) + 2
        end
        y = y + 4
        tabLayers:SetOn(state.tab == 'layers')
        tabNotes:SetOn(state.tab == 'notes')
        W.Place(tabLayers, d.group, Skin.S(x), Skin.S(y), Skin.S(110), Skin.S(24))
        W.Place(tabNotes, d.group, Skin.S(x + 116), Skin.S(y), Skin.S(110), Skin.S(24))
        W.Center(tabLayers.label, tabLayers, 0, 0, Skin.S(110), Skin.S(24))
        W.Center(tabNotes.label, tabNotes, 0, 0, Skin.S(110), Skin.S(24))
        y = y + 32
        local bottom = HEIGHT - 70
        if state.tab == 'layers' then
            if s.rows then
                y = DrawTable(s.rows, x, y, w)
                y = y + 4
                for _, line in s.notes or {} do
                    y = Para(line, x, y, w, { color = c.textDim, size = 'small' }, 2000, 14)
                end
            else
                Text('The editor has no layer table for this shader. Read the comment above it in effects/terrain.fx.', x, y, { color = c.textDim, size = 'small' })
            end
        else
            -- the notes: each paragraph is cut at a few lines until "Show more" is pressed
            local cutAny = false
            local function Section(title, text)
                Text(title, x, y, { color = c.textDim, size = 'small' })
                y = y + 18
                local limit = state.more and bottom or math.min(bottom, y + 5 * 16 + 2)
                local after, cut = Para(text, x, y, w, { color = c.text, size = 'small' }, limit, 16)
                y = after + 6
                if cut then cutAny = true end
            end
            if s.layout ~= '' then Section('Textures', s.layout) end
            Section('How to use it', s.instructions)
            if cutAny or state.more then
                moreBtn:SetText(state.more and 'Show less' or 'Show more')
                W.Place(moreBtn, d.group, Skin.S(x), Skin.S(math.min(y, bottom + 2)), Skin.S(110), Skin.S(24))
                W.Center(moreBtn.label, moreBtn, 0, 0, Skin.S(110), Skin.S(24))
                moreBtn:SetHidden(false)
            end
        end
        if not s.listed then
            -- (a shader the editor has no notes about: still usable)
            Text('Not described by the editor yet.', x, HEIGHT - 60, { color = c.warn, size = 'small' })
        end
    end

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
            state.more = false
            list:SetSelected(index)
            ShowInfo()
        end,
        bgColor = c.panel,
    })
    list:SetRect(Skin.S(14), Skin.S(62), Skin.S(304), Skin.S(HEIGHT - 150))
    d:Raise(list.root)

    local field = d:Field(70, 30, 248, 22, { text = '', onChange = function(text)
        local keep = Selected()
        state.shown = Filter(state.all, text)
        state.sel = false
        for i, s in state.shown do
            if keep and s.id == keep.id then state.sel = i end
        end
        if not state.sel and table.getn(state.shown) > 0 then state.sel = 1 end
        state.more = false
        list:Refresh()
        if state.sel then list:SetSelected(state.sel) end
        ShowInfo()
    end })

    say = d:Label('', 300, HEIGHT - 76, { color = c.error, size = 'small' })
    use = d:Button('Use this shader', 14, HEIGHT - 84, 128, 28, function()
        local s = Selected()
        if not s then return end
        local ok, why = Shaders.Set(s.id)
        if not ok then say:SetText(tostring(why)) return end
        Dialog.Close()
        if done then done(s.id) end
    end, { tip = 'Make the map draw its terrain with the chosen shader. Only the shader changes: paint masks, textures and layers stay as they are (use Convert layers... to adapt them).' })
    convert = d:Button('Convert layers...', 150, HEIGHT - 84, 140, 28, function()
        local s = Selected()
        if not s then return end
        if s.id == state.current and not Shaders.Mismatch() then say:SetText('The map already uses ' .. s.id) return end
        if not (s.profile and s.profile.supported) then say:SetText('The editor cannot convert layers to ' .. s.id .. (s.profile and s.profile.reason and (': ' .. s.profile.reason) or '')) return end
        say:SetText('')
        import('/lua/editor/gui/convertdialog.lua').Open(s.id, function() if done then done(s.id) end end)
    end, { tip = 'Change the shader and convert the map\'s layers to its format in one undo step: paint masks re-encoded where the mask range differs, layer 8 handled, the Upper layer replaced where it must be. A dialog lists what is done and what is not.' })
    if opts.convert then convert:SetOn(true) end
    d:Button('Close', WIDTH - 110, HEIGHT - 84, 96, 28, function() Dialog.Close() end, { tip = 'Close without changing the shader.' })

    tabLayers = d:Button('Layers', 332, 200, 110, 24, function()
        state.tab = 'layers'
        ShowInfo()
    end, { toggle = true, tip = 'A table of what each layer (Base, layers 1 to 8, Upper) holds for this shader: the albedo (colour) texture and the normal map.' })
    tabNotes = d:Button('Notes', 448, 200, 110, 24, function()
        state.tab = 'notes'
        ShowInfo()
    end, { toggle = true, tip = 'How the textures of this shader have to be made and how to use it.' })
    moreBtn = d:Button('Show more', 332, 400, 110, 24, function()
        state.more = not state.more
        ShowInfo()
    end, { tip = 'Show the whole text, or cut it short again.' })


    if state.sel then list:SetSelected(state.sel) list:ScrollTo(state.sel) end
    ShowInfo()
    return state
end
