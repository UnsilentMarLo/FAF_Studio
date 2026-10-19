-- The Strata themes panel (Environment workspace; also useful in the Terrain workspace): a library of terrain texture themes - the albedo and normal textures and tile sizes of the Base layer, the
-- eight painted layers and the Upper layer. Shipped: hand picked sets (grassland, alpine, snow, desert, tropical, volcanic, red barrens, swamp, crystal, geothermal, industrial ...) and the texture
-- sets of the retail campaign maps; yours: "Save current as theme" and "Import from map". Click a theme to TRY it (nothing is recorded; "Revert" or another theme takes it off, and it is never saved
-- with the map), "Apply" makes it permanent as ONE undo step. The paint masks stay as they are: a theme changes what the layers look like, not where they are. "Clear unused layers" removes the
-- texture (and the paint) of every layer the theme leaves empty.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Lib = import('/lua/editor/envlib.lua')
local Dialogs = import('/lua/editor/gui/envdialogs.lua')

live = {}

state = { sel = false, filter = '', try = true, clear = false, text = '' }

local function Say(text)
    state.text = text
    pcall(function() UI.Say(text) end)
end

local function Entry()
    if not state.sel then return nil end
    for _, t in Lib.Themes() do
        if t.id == state.sel then return t end
    end
    return nil
end

local function Try()
    local entry = Entry()
    if not entry then return end
    local clear = state.clear
    local ok, revert, missing = Lib.ApplyTheme(entry, { preview = true, clearUnused = clear })
    if ok then
        Lib.SetPreview('theme', revert, function()
            local ok2, revert2 = Lib.ApplyTheme(entry, { preview = true, clearUnused = clear })
            return revert2
        end)
        state.text = 'trying ' .. entry.name .. '  (Apply keeps it, Revert takes it off)' .. ((missing and table.getn(missing) > 0) and ('  - ' .. table.getn(missing) .. ' textures not found') or '')
    else
        state.text = 'cannot try: ' .. tostring(revert)
    end
end

local function Visible()
    local list = {}
    local f = string.lower(state.filter or '')
    for _, t in Lib.Themes() do
        if f == '' or string.find(string.lower(t.name), f, 1, true) or string.find(string.lower(t.group), f, 1, true) then table.insert(list, t) end
    end
    return list
end

Panels.Register{
    id = 'themes', title = 'Strata themes', minW = 260, minH = 220, stack = { workspace = 'Environment', with = 'lighting' },
    create = function(group, host)
        local P = { shown = {}, w = 280, h = 400 }
        live.themes = P
        local c = Skin.color
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(24), fn, opts) end

        local function Reload()
            P.shown = Visible()
            P.list:Refresh()
        end

        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { text = state.filter, onChange = function(text) state.filter = text Reload() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = c.textDim })
        P.list = W.VirtualList(group, {
            rowH = 50, thumb = true, extra = true,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local t = P.shown[index]
                local tx = Skin.S(50 + 10) + Skin.S(2)
                local thumb = Lib.Thumb('theme', t.id)
                local base = t.layers[0] or t.layers[1]
                if thumb then
                    row.thumb:SetTexture(thumb)
                elseif base and base.albedo then
                    row.thumb:SetTexture(base.albedo)
                else
                    row.thumb:SetSolidColor(c.panelAlt)
                end
                W.Fit(row.text, t.name, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(10)))
                row.text:SetColor(t.id == state.sel and c.accent or c.text)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + Skin.S(8) end)
                local count = 0
                for _, _ in t.layers do count = count + 1 end
                row.extra:SetText(t.group .. '  -  ' .. count .. ' layers')
                row.extra:SetColor(c.textDim)
                row.extra.Left:Set(function() return row.bg.Left() + tx end)
                row.extra.Top:Set(function() return row.bg.Top() + Skin.S(28) end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                local t = P.shown[index]
                if not t then return end
                state.sel = t.id
                if state.try then Try() end
                P:Refresh()
            end,
        })
        P.bTry = Btn('Try on click', 90, function(self)
            state.try = self.on
            if not self.on then Lib.RevertPreview('theme') state.text = 'try is off' elseif Entry() then Try() end
            P:Refresh()
        end, { toggle = true })
        P.bClear = Btn('Clear unused layers', 140, function(self)
            state.clear = self.on
            if state.try and Lib.HasPreview('theme') then Try() end
            P:Refresh()
        end, { toggle = true })
        P.bApply = Btn('Apply', 60, function()
            local entry = Entry()
            if not entry then Say('pick a theme first') return end
            Lib.RevertPreview('theme')
            local ok, _, missing = Lib.ApplyTheme(entry, { clearUnused = state.clear })
            Say(ok and ('applied ' .. entry.name .. ' (one undo step)' .. ((missing and table.getn(missing) > 0) and ('  - ' .. table.getn(missing) .. ' textures not found') or '')) or 'not applied')
            P:Refresh()
        end)
        P.bRevert = Btn('Revert', 60, function()
            Lib.RevertPreview('theme')
            state.text = 'the layers are as they were'
            P:Refresh()
        end)
        P.bSave = Btn('Save current...', 110, function()
            Dialogs.AskName('Save the present layers as a theme', '', function(name)
                Lib.RevertPreview('theme')
                local entry = Lib.SaveTheme(name)
                state.sel = entry.id
                Say('saved the theme ' .. name)
                Reload()
                P:Refresh()
            end)
        end)
        P.bImport = Btn('Import from map...', 130, function()
            Dialogs.PickMap('Import the texture layers of a map', function(map, path, why)
                if not path then Say(tostring(why)) P:Refresh() return end
                local entry, err = Lib.ImportTheme(path, map.name)
                if entry then
                    state.sel = entry.id
                    Say('imported the layers of ' .. map.name)
                    Reload()
                    if state.try then Try() end
                else
                    Say('cannot read ' .. map.name .. ': ' .. tostring(err))
                end
                P:Refresh()
            end)
        end)
        P.bDelete = Btn('Delete', 60, function()
            local entry = Entry()
            if entry and entry.user then
                Lib.RevertPreview('theme')
                Lib.DeleteTheme(entry.id)
                state.sel = false
                Reload()
                Say('deleted ' .. entry.name)
            else
                Say('only your own themes can be deleted')
            end
            P:Refresh()
        end)
        P.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            self.list:Refresh()
            self.bTry:SetOn(state.try)
            self.bClear:SetOn(state.clear)
            local entry = Entry()
            W.Fit(self.info, entry and (entry.name .. '  -  ' .. (entry.desc or '')) or 'Pick a theme', (self.w or 300) - Skin.S(16))
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.Place(self.filterLabel, group, pad, y + Skin.S(3))
            W.Place(self.filter.frame, group, pad + Skin.S(34), y, w - 2 * pad - Skin.S(34), Skin.S(22))
            self.filter.Width:Set(w - 2 * pad - Skin.S(34) - 2)
            y = y + Skin.S(28)
            local listH = math.max(Skin.S(100), math.min(Skin.S(50 * 6), h - Skin.S(200)))
            self.list:SetRect(pad, y, w - 2 * pad, listH)
            y = y + listH + pad
            local function Flow(buttons)
                local bx = pad
                for _, b in buttons do
                    local bw = b.Width()
                    if bx > pad and bx + bw > w - pad then bx = pad y = y + Skin.S(28) end
                    W.Place(b, group, bx, y, bw, Skin.S(24))
                    bx = bx + bw + Skin.S(4)
                end
                y = y + Skin.S(32)
            end
            Flow({ self.bTry, self.bClear, self.bApply, self.bRevert })
            Flow({ self.bSave, self.bImport, self.bDelete })
            W.Place(self.info, group, pad, y)
            W.Place(self.status, group, pad, y + Skin.S(18))
            self:Refresh()
        end

        Reload()
        return P
    end,
}

function Release()
    pcall(function() Lib.RevertPreview('theme') end)
end
