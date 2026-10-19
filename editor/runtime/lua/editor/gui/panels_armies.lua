-- The Armies panel (mission maps): the army list in index order with the faction, colour, economy and alliances of the selected army (armysetup.lua).
-- "Setup" shows the settings, "Alliances" the state the selected army holds towards every other army (click a row to cycle Enemy / Ally / Neutral;
-- "Both ways" sets the other side as well).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Army = import('/lua/editor/armysetup.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function ColorOf(index)
    if not index or index < 1 then return nil end
    local ok, colors = pcall(function() return import('/lua/GameColors.lua').GameColors.ArmyColors end)
    return ok and colors and colors[index]
end

local function AddDialog(P)
    local d = Dialog.Open('Add army', 360, 130)
    d:Label('Name (letters, digits, _), e.g. Player1, UEF, Civilians', 14, 34, { color = Skin.color.textDim, size = 'small' })
    local field = d:Field(14, 56, 330, 22, { text = '' })
    local function Make()
        local ok, why = Army.Add(field:GetText())
        Dialog.Close()
        if ok then Say('army added') P.sel = table.getn(Army.Names()) else Say('army: ' .. tostring(why)) end
        P:Refresh()
    end
    d:Button('Add', 14, 92, 90, 28, Make)
    d:Button('Cancel', 114, 92, 90, 28, function() Dialog.Close() end)
    field.OnEnterPressed = function(self, text) Make() return true end      -- typing starts at once, Enter adds (like the other name dialogs)
    field:AcquireFocus()
end

Panels.Register{
    id = 'armies', title = 'Armies',
    create = function(group, host)
        local P = { sel = 1, view = 'setup', both = true, rev = -1 }
        live.armies = P

        local function Names() return Army.Names() end
        local function Current()
            local names = Names()
            if P.sel > table.getn(names) then P.sel = table.getn(names) end
            if P.sel < 1 then P.sel = 1 end
            return names[P.sel], names
        end

        P.list = W.VirtualList(group, {
            extra = true, thumb = true, rowH = 22,
            getCount = function()
                if P.view == 'alliances' then return math.max(0, table.getn(Names()) - 1) end
                return table.getn(Names())
            end,
            bind = function(row, index)
                local c = Skin.color
                local names = Names()
                if P.view == 'alliances' then
                    local me = Current()
                    local others = {}
                    for _, n in names do if n ~= me then table.insert(others, n) end end
                    local other = others[index]
                    local state = me and other and Army.AllianceOf(me, other)
                    local back = me and other and Army.AllianceOf(other, me)
                    local text = state or 'default'
                    if back ~= state then text = text .. ' (back: ' .. tostring(back or 'default') .. ')' end
                    row.thumb:SetSolidColor(state == 'Ally' and c.ok or (state == 'Neutral' and c.warn or c.error))
                    W.Fit(row.text, tostring(other), math.max(Skin.S(30), row.bg.Width() - Skin.S(150)))
                    row.extra:SetText(text)
                    row.text:SetColor(c.text)
                else
                    local name = names[index]
                    local a = Army.Get(name)
                    local col = a and ColorOf(a.color)
                    row.thumb:SetSolidColor(col or c.panelAlt)
                    W.Fit(row.text, index .. '  ' .. tostring(name), math.max(Skin.S(30), row.bg.Width() - Skin.S(110)))
                    row.extra:SetText(a and Army.Factions[(a.faction or 0) + 1] or '?')
                    row.text:SetColor(index == P.sel and c.accent or c.text)
                end
                row.extra:SetColor(c.textDim)
                local tx = row.bg.Height() + Skin.S(4)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                if P.view == 'alliances' then
                    local me, names = Current()
                    local others = {}
                    for _, n in names do if n ~= me then table.insert(others, n) end end
                    local other = others[index]
                    if not other then return end
                    local state = Army.AllianceOf(me, other) or 'Enemy'
                    local nextState = 'Enemy'
                    for i, s in Army.States do if s == state then nextState = Army.States[math.mod(i, 3) + 1] end end
                    Army.SetAlliance(me, other, nextState, P.both)
                else
                    P.sel = index
                end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })

        P.view1 = W.Button(group, 'Setup', 0, 0, Skin.S(60), Skin.S(22), function() P.view = 'setup' P:OnResize(P.vw, P.vh) end)
        P.view2 = W.Button(group, 'Alliances', 0, 0, Skin.S(76), Skin.S(22), function() P.view = 'alliances' P:OnResize(P.vw, P.vh) end)
        P.add = W.Button(group, 'Add', 0, 0, Skin.S(44), Skin.S(22), function() AddDialog(P) end)
        P.remove = W.Button(group, 'Remove', 0, 0, Skin.S(64), Skin.S(22), function()
            local name = Current()
            if not name then return end
            local ok, why = Army.Remove(name)
            Say(ok and ('army ' .. name .. ' removed') or ('army: ' .. tostring(why)))
            P:Refresh()
        end)
        P.up = W.Button(group, 'Up', 0, 0, Skin.S(34), Skin.S(22), function()
            local name = Current()
            if name and Army.Move(name, -1) then P.sel = P.sel - 1 end
            P:Refresh()
        end)
        P.down = W.Button(group, 'Down', 0, 0, Skin.S(44), Skin.S(22), function()
            local name = Current()
            if name and Army.Move(name, 1) then P.sel = P.sel + 1 end
            P:Refresh()
        end)

        P.faction = {}
        local function FactionButton(index, text)      -- a function of its own: closures in a for loop share the loop variable
            P.faction[index] = W.Button(group, text, 0, 0, Skin.S(62), Skin.S(22), function()
                local name = Current()
                if name then Army.Set(name, 'faction', index - 1, 'army ' .. name .. ' faction') end
                P:Refresh()
            end)
        end
        for i, f in Army.Factions do FactionButton(i, f) end
        local function Field(label, field, min, max, step, fmt)
            return W.Slider(group, { label = label, min = min, max = max, step = step, fmt = fmt,
                get = function()
                    local a = Army.Get((Current()))
                    if not a then return min end
                    if field == 'mass' or field == 'energy' then return (a.Economy and a.Economy[field]) or 0 end
                    return a[field] or 0
                end,
                set = function(v)
                    local name = Current()
                    if name then Army.Set(name, field, v, 'army ' .. name .. ' ' .. field) end
                    P.list:Refresh()
                end })
        end
        P.color = Field('Colour (0 = default, 1-19 = lobby colours)', 'color', 0, 19, 1, '%d')
        P.mass = Field('Start mass', 'mass', 0, 20000, 100, '%d')
        P.energy = Field('Start energy', 'energy', 0, 100000, 500, '%d')
        P.bothBtn = W.Button(group, 'Both ways', 0, 0, Skin.S(86), Skin.S(22), function(self) P.both = self.on end, { toggle = true })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.rev = Army.Revision
            P.view1:SetOn(P.view == 'setup')
            P.view2:SetOn(P.view == 'alliances')
            P.bothBtn:SetOn(P.both)
            P.list:Refresh()
            local name = Current()
            local a = name and Army.Get(name)
            for i, b in P.faction do b:SetOn(a ~= nil and (a.faction or 0) == i - 1) end
            P.color:Refresh() P.mass:Refresh() P.energy:Refresh()
            local problems = Army.Check()
            local e, w = 0, 0
            for _, p in problems do if p.sev == 'E' then e = e + 1 elseif p.sev == 'W' then w = w + 1 end end
            W.Fit(P.status, string.format('%d armies, %d errors, %d warnings%s', table.getn(Names()), e, w, (e + w > 0) and (': ' .. problems[1].text) or ''), (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            P.vw, P.vh = w, h
            local top = W.Flow(group, { { P.view1, Skin.S(60) }, { P.view2, Skin.S(76) }, { P.add, Skin.S(44) }, { P.remove, Skin.S(64) }, { P.up, Skin.S(34) }, { P.down, Skin.S(44) } },
                pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)
            local facItems = {}
            for _, b in P.faction do table.insert(facItems, { b, Skin.S(62) }) end
            local facRows = (W.Flow(group, facItems, 0, 0, w - 2 * pad, Skin.S(22), Skin.S(4), true) - Skin.S(22)) / Skin.S(26)
            local extra = math.floor(facRows + 0.5) * Skin.S(26)      -- the faction buttons wrap in a narrow panel
            local foot = P.view == 'setup' and (Skin.S(250) + extra) or Skin.S(60)
            local listH = math.max(Skin.S(60), h - pad - top - foot)
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            local y = math.max(h - foot + Skin.S(2), top + listH + Skin.S(6))      -- a short panel scrolls instead of laying the controls over each other
            if P.view == 'setup' then
                W.Flow(group, facItems, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
                y = y + extra
                P.color:Place(pad, y + Skin.S(28), w - 2 * pad)
                P.mass:Place(pad, y + Skin.S(76), w - 2 * pad)
                P.energy:Place(pad, y + Skin.S(124), w - 2 * pad)
                W.Place(P.bothBtn, group, -20000, -20000, Skin.S(86), Skin.S(22))
                W.Place(P.status, group, pad, y + Skin.S(176))
            else
                for _, b in P.faction do W.Place(b, group, -20000, -20000, Skin.S(62), Skin.S(22)) end
                for _, s in { P.color, P.mass, P.energy } do s:Place(-20000, -20000, Skin.S(100)) end
                W.Place(P.bothBtn, group, pad, y, Skin.S(86), Skin.S(22))
                W.Place(P.status, group, pad, y + Skin.S(28))
            end
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: redraws when the army setup changed (undo, redo, another panel).
function Refresh()
    local P = live.armies
    if P and P.rev ~= Army.Revision then pcall(P.Refresh, P) end
end
