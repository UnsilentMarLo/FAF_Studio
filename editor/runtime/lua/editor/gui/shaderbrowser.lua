-- The terrain shader browser (Layers panel > Shader): every terrain shader of the game's shader file with a search, the family it belongs to, what it does, the layout its textures have
-- to follow and notes on how to use it. Data: shaders.lua (descriptions, discovery of new shaders). One modal dialog like the other browsers.
--
--   Open(done)       done(shaderId) is called after the user chose one and the map uses it
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

function Open(done)
    local d = Dialog.Open('Terrain shader', 800, 560)
    local c = Skin.color
    local all = Shaders.List()
    local state = { all = all, shown = all, sel = false, info = {}, current = Shaders.Current() }
    for i, s in all do
        if s.id == state.current then state.sel = i end
    end
    last = state

    d:Label('Search', 14, 34, { color = c.textDim })
    local list, say
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
    local function Para(text, x, y, w, opts, bottom)
        local lines, after = W.Paragraph(d.group, text, Skin.S(x), Skin.S(y), Skin.S(w), opts, Skin.S(16), Skin.S(bottom))
        for _, l in lines do
            d:Raise(l)
            table.insert(state.info, l)
        end
        return math.floor(after / Skin.S(1)) + 4
    end

    local function ShowInfo()
        ClearInfo()
        local s = Selected()
        local x, w = 332, 454
        if not s then
            Text('No shader matches the search.', x, 64, { color = c.textDim })
            return
        end
        local y = 62
        Text(s.name .. (s.id == state.current and '   (used by this map)' or ''), x, y, { color = (s.id == state.current) and c.accent or c.text })
        y = y + 22
        Text(FamilyLabel(s.family), x, y, { color = c.textDim, size = 'small' })
        y = y + 20
        y = Para(s.summary, x, y, w, { color = c.text }, 470) + 6
        if s.layout ~= '' then
            Text('Textures', x, y, { color = c.textDim, size = 'small' })
            y = y + 18
            y = Para(s.layout, x, y, w, { color = c.text, size = 'small' }, 470) + 6
        end
        Text('How to use it', x, y, { color = c.textDim, size = 'small' })
        y = y + 18
        Para(s.instructions, x, y, w, { color = c.text, size = 'small' }, 480)
        if not s.listed then
            -- (a shader the editor has no notes about: still usable)
            Text('Not described by the editor yet.', x, 482, { color = c.warn, size = 'small' })
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
            list:SetSelected(index)
            ShowInfo()
        end,
        bgColor = c.panel,
    })
    list:SetRect(Skin.S(14), Skin.S(62), Skin.S(304), Skin.S(432))
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

    say = d:Label('', 150, 512, { color = c.error, size = 'small' })
    local use = d:Button('Use this shader', 14, 506, 128, 28, function()
        local s = Selected()
        if not s then return end
        local ok, why = Shaders.Set(s.id)
        if not ok then say:SetText(tostring(why)) return end
        Dialog.Close()
        if done then done(s.id) end
    end, { tip = 'Make the map draw its terrain with the chosen shader.' })
    d:Button('Close', 690, 506, 96, 28, function() Dialog.Close() end, { tip = 'Close without changing the shader.' })

    if state.sel then list:SetSelected(state.sel) list:ScrollTo(state.sel) end
    ShowInfo()
    return state
end
