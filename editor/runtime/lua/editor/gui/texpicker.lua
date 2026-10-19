-- A texture browser for any texture of the game data: a list with a thumbnail on every row, a large preview of the texture under the pointer, a filter field. (The layer texture browser of
-- panels_strata.lua is limited to /env layers; this one takes the folders and patterns of the caller: sky atlases, cirrus, water ramps and wave maps, cube maps ...)
--
--   Open{ title, sources = { { '/textures/environment', '*.dds' }, ... }, match = function(path) -> bool (optional), none = 'text of a "no texture" entry' (optional),
--         thumbs = false (cube maps cannot be shown as a picture), current = path (selected first), done = function(path) }
--   Close()
--
-- A click on a row calls done(path) and closes; Esc or a click outside closes.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')

NONE = '*none*'

open = false

function Close()
    if open then
        open.group:Destroy()
        open = false
    end
end

local function Collect(sources, match)
    local seen, list = {}, {}
    for _, s in sources do
        for _, path in (DiskFindFiles(s[1], s[2]) or {}) do
            local key = string.lower(path)
            if not seen[key] and (not match or match(path)) then
                seen[key] = true
                table.insert(list, path)
            end
        end
    end
    table.sort(list, function(a, b) return string.lower(a) < string.lower(b) end)
    return list
end

function Open(spec)
    Close()
    local frame = GetFrame(0)
    local c = Skin.color
    local rowH, rows = Skin.S(52), 9
    local listW, previewW = Skin.S(500), Skin.S(240)
    local width = listW + previewW + Skin.S(40)
    local height = Skin.S(66) + rowH * rows + Skin.S(16)
    local fw, fh = frame.Width(), frame.Height()
    local x, y = math.floor((fw - width) / 2), math.max(Skin.S(20), math.floor((fh - height) / 3))
    local group = Group(frame)
    group.Depth:Set(9000)
    group.Left:Set(x) group.Top:Set(y) group.Width:Set(width) group.Height:Set(height)
    local shade = Bitmap(group)
    shade.Depth:Set(function() return group.Depth() + 1 end)
    shade:SetSolidColor('60000000')
    shade.Left:Set(0) shade.Top:Set(0) shade.Width:Set(fw) shade.Height:Set(fh)
    shade.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then Close() end
        return true
    end
    local box = Bitmap(group)
    box.Depth:Set(function() return group.Depth() + 2 end)
    box:SetSolidColor(c.line)
    box.Left:Set(function() return group.Left() end) box.Top:Set(function() return group.Top() end)
    box.Width:Set(width) box.Height:Set(height)
    local inner = Bitmap(group)
    inner.Depth:Set(function() return group.Depth() + 3 end)
    inner:SetSolidColor(c.panel)
    inner.Left:Set(function() return group.Left() + 1 end) inner.Top:Set(function() return group.Top() + 1 end)
    inner.Width:Set(width - 2) inner.Height:Set(height - 2)
    W.Label(group, spec.title or 'Texture', Skin.S(10), Skin.S(8), { color = c.textDim }).Depth:Set(function() return group.Depth() + 6 end)

    local all = Collect(spec.sources or {}, spec.match)
    if spec.none then table.insert(all, 1, NONE) end
    local state = { shown = all }
    local thumbs = spec.thumbs ~= false

    local px = listW + Skin.S(24)
    local preview = Bitmap(group)
    preview.Depth:Set(function() return group.Depth() + 6 end)
    preview:SetSolidColor(c.panelAlt)
    W.Place(preview, group, px, Skin.S(34), previewW, previewW)
    preview:DisableHitTest()
    local nameLabel = W.Label(group, '', px, Skin.S(34) + previewW + Skin.S(8), { color = c.text })
    local pathLabel = W.Label(group, '', px, Skin.S(34) + previewW + Skin.S(28), { color = c.textDim, size = 'small' })
    nameLabel.Depth:Set(function() return group.Depth() + 6 end)
    pathLabel.Depth:Set(function() return group.Depth() + 6 end)
    local function ShowPreview(path)
        if not path then return end
        if path == NONE then
            preview:SetSolidColor(c.panelAlt)
            nameLabel:SetText('(none)')
            pathLabel:SetText(spec.none or '')
            return
        end
        if thumbs then preview:SetTexture(path) else preview:SetSolidColor(c.panelAlt) end
        W.Fit(nameLabel, (string.gsub(path, '^.*/', '')), previewW)
        W.Fit(pathLabel, (string.gsub(path, '/[^/]*$', '')), previewW)
    end

    local list
    local field = W.TextField(group, Skin.S(10), Skin.S(30), listW, Skin.S(22), {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, p in all do
                if f == '' or p == NONE or string.find(string.lower(p), f, 1, true) then table.insert(state.shown, p) end
            end
            list:SetSelected(nil)
            list:Refresh()
            ShowPreview(state.shown[1])
        end,
        onEscape = function() Close() end,
    })
    list = W.VirtualList(group, {
        rowH = 52,
        thumb = thumbs,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local path = state.shown[index]
            local tx = (thumbs and (rowH - Skin.S(4) + Skin.S(10))) or Skin.S(10)
            local name, set
            if path == NONE then
                if thumbs then row.thumb:SetSolidColor(c.panelAlt) end
                name, set = '(none)', spec.none or ''
            else
                if thumbs then row.thumb:SetTexture(path) end
                name = string.gsub(path, '^.*/', '')
                set = string.gsub(path, '/[^/]*$', '')
            end
            W.Fit(row.text, name, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(10)))
            row.text:SetColor((spec.current and path == spec.current) and c.accent or c.text)
            row.text.Left:Set(function() return row.bg.Left() + tx end)
            row.text.Top:Set(function() return row.bg.Top() + Skin.S(9) end)
            if not row.sub then
                row.sub = W.Label(row.bg, '', 0, 0, { color = c.textDim, size = 'small' })
            end
            W.Fit(row.sub, set, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(10)))
            row.sub.Left:Set(function() return row.bg.Left() + tx end)
            row.sub.Top:Set(function() return row.bg.Top() + Skin.S(28) end)
        end,
        onSelect = function(index)
            local path = state.shown[index]
            Close()
            if path and spec.done then spec.done(path) end
        end,
        onHover = function(index)
            ShowPreview(state.shown[index])
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), listW + Skin.S(4), rowH * rows)
    ShowPreview(state.shown[1])
    field:AcquireFocus()
    open = { group = group }
end
