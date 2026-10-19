-- The Lighting presets panel (Environment workspace): a library of looks - sun, ambient, shadow fill, fog, bloom, water colour and waves, sky colours, clouds and billboards - with a thumbnail of each
-- (every thumbnail is the same test scene rendered with that look). Shipped: moods (dawn, noon, sunset, overcast, night ...), biomes and the looks of the retail campaign maps; yours: "Save current
-- as look" and "Import from map" (reads the look of any map file on disk). Click a look to TRY it on the open map (nothing is recorded, "Revert" or another look takes it off, and it is never saved with
-- the map), "Apply" makes it permanent as ONE undo step. Which groups of settings a look changes and how far (blend 0..1 from what the map has now) is up to you.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Env = import('/lua/editor/environment.lua')
local Lib = import('/lua/editor/envlib.lua')
local Dialogs = import('/lua/editor/gui/envdialogs.lua')

live = {}

state = { sel = false, filter = '', try = true, blend = 1, text = '', on = { light = true, water = true, waves = true, sky = true, skyshape = true, cubes = true } }

local function Say(text)
    state.text = text
    pcall(function() UI.Say(text) end)
end

local function Sections()
    local list = {}
    for _, id in Lib.LOOK_SECTIONS do
        if state.on[id] then table.insert(list, id) end
    end
    return list
end

local function Entry()
    if not state.sel then return nil end
    return Lib.FindLook(state.sel)
end

--- Tries the selected look (replaces a look tried before).
local function Try()
    local entry = Entry()
    if not entry then return end
    local sections, blend = Sections(), state.blend
    local ok, revert = Lib.ApplyLook(entry, { sections = sections, blend = blend, preview = true })
    if ok then
        Lib.SetPreview('look', revert, function()
            local ok2, revert2 = Lib.ApplyLook(entry, { sections = sections, blend = blend, preview = true })
            return revert2
        end)
        state.text = 'trying ' .. entry.name .. '  (Apply keeps it, Revert takes it off)'
    else
        state.text = 'cannot try: ' .. tostring(revert)
    end
end

local function Visible()
    local list = {}
    local f = string.lower(state.filter or '')
    for _, l in Lib.Looks() do
        if f == '' or string.find(string.lower(l.name), f, 1, true) or string.find(string.lower(l.group), f, 1, true) then table.insert(list, l) end
    end
    return list
end

local function Swatch(entry)
    local sky = entry.t and entry.t.sky
    local r, g, b = 0.4, 0.45, 0.5
    if sky and sky.horizon_r then r, g, b = sky.horizon_r, sky.horizon_g, sky.horizon_b end
    local function H(x) return string.format('%02X', math.floor(math.max(0, math.min(1, x)) * 255 + 0.5)) end
    return 'FF' .. H(r) .. H(g) .. H(b)
end

Panels.Register{
    id = 'looks', title = 'Lighting presets', minW = 260, minH = 220, stack = { workspace = 'Environment', with = 'lighting' },
    create = function(group, host)
        local P = { shown = {}, w = 280, h = 400 }
        live.looks = P
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
                local l = P.shown[index]
                local tx = Skin.S(50 + 10) + Skin.S(2)
                local thumb = Lib.Thumb('look', l.id)
                if thumb then row.thumb:SetTexture(thumb) else row.thumb:SetSolidColor(Swatch(l)) end
                W.Fit(row.text, l.name, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(10)))
                row.text:SetColor(l.id == state.sel and c.accent or c.text)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + Skin.S(8) end)
                row.extra:SetText(l.group)
                row.extra:SetColor(c.textDim)
                local ew = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Left() + tx end)
                row.extra.Top:Set(function() return row.bg.Top() + Skin.S(28) end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                local l = P.shown[index]
                if not l then return end
                state.sel = l.id
                if state.try then Try() end
                P:Refresh()
            end,
        })
        P.sections = {}
        local NAMES = { light = 'Lighting', water = 'Water', waves = 'Waves', sky = 'Sky', skyshape = 'Dome shape', cubes = 'Cube maps' }
        for _, id in Lib.LOOK_SECTIONS do
            local sid = id
            local b = Btn(NAMES[sid], 74, function(self)
                state.on[sid] = self.on
                if state.try and Lib.HasPreview('look') then Try() end
                P:Refresh()
            end, { toggle = true })
            P.sections[sid] = b
        end
        P.blend = W.Slider(group, { label = 'Blend (0 = the map as it is, 1 = the look)', compact = true, min = 0, max = 1, step = 0.05, fmt = '%.2f',
            get = function() return state.blend end,
            set = function(v)
                state.blend = v
                if state.try and Lib.HasPreview('look') then Try() end
                P:Refresh()
            end })
        P.bTry = Btn('Try on click', 90, function(self)
            state.try = self.on
            if not self.on then Lib.RevertPreview('look') state.text = 'try is off' elseif Entry() then Try() end
            P:Refresh()
        end, { toggle = true })
        P.bApply = Btn('Apply', 60, function()
            local entry = Entry()
            if not entry then Say('pick a look first') return end
            Lib.RevertPreview('look')
            local ok, why = Lib.ApplyLook(entry, { sections = Sections(), blend = state.blend })
            Say(ok and ('applied ' .. entry.name .. ' (one undo step)') or ('not applied: ' .. tostring(why)))
            P:Refresh()
        end)
        P.bRevert = Btn('Revert', 60, function()
            Lib.RevertPreview('look')
            state.text = 'the map is as it was'
            P:Refresh()
        end)
        P.bSave = Btn('Save current...', 110, function()
            Dialogs.AskName('Save the present environment as a look', '', function(name)
                Lib.RevertPreview('look')
                local entry = Lib.SaveLook(name, Sections())
                state.sel = entry.id
                Say('saved the look ' .. name)
                Reload()
                P:Refresh()
            end)
        end)
        P.bImport = Btn('Import from map...', 130, function()
            Dialogs.PickMap('Import the look of a map', function(map, path, why)
                if not path then Say(tostring(why)) P:Refresh() return end
                local entry, err = Lib.ImportLook(path, map.name)
                if entry then
                    state.sel = entry.id
                    Say('imported the look of ' .. map.name)
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
                Lib.RevertPreview('look')
                Lib.DeleteLook(entry.id)
                state.sel = false
                Reload()
                Say('deleted ' .. entry.name)
            else
                Say('only your own looks can be deleted')
            end
            P:Refresh()
        end)
        P.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            self.list:Refresh()
            for id, b in self.sections do b:SetOn(state.on[id]) end
            self.blend:Refresh()
            self.bTry:SetOn(state.try)
            local entry = Entry()
            W.Fit(self.info, entry and (entry.name .. '  -  ' .. (entry.desc or '')) or 'Pick a look', (self.w or 300) - Skin.S(16))
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
            local listH = math.max(Skin.S(100), math.min(Skin.S(50 * 6), h - Skin.S(250)))
            self.list:SetRect(pad, y, w - 2 * pad, listH)
            y = y + listH + pad
            local bx = pad
            local function Flow(buttons)
                bx = pad
                for _, b in buttons do
                    local bw = b.Width()
                    if bx > pad and bx + bw > w - pad then bx = pad y = y + Skin.S(28) end
                    W.Place(b, group, bx, y, bw, Skin.S(24))
                    bx = bx + bw + Skin.S(4)
                end
                y = y + Skin.S(32)
            end
            local sectionButtons = {}
            for _, id in Lib.LOOK_SECTIONS do table.insert(sectionButtons, self.sections[id]) end
            Flow(sectionButtons)
            self.blend:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(50)
            Flow({ self.bTry, self.bApply, self.bRevert })
            Flow({ self.bSave, self.bImport, self.bDelete })
            W.Place(self.info, group, pad, y)
            W.Place(self.status, group, pad, y + Skin.S(18))
            self:Refresh()
        end

        Reload()
        return P
    end,
}

--- Takes a tried look off the map (leaving the editor, a module reload).
function Release()
    pcall(function() Lib.RevertPreview('look') end)
end
