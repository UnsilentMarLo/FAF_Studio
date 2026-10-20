-- The Settings panel (File > Settings...): graphics quality (a preset and every setting behind it) and the size of the interface. The values live in graphics.lua / skin.lua; the panel keeps
-- nothing but its controls.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Graphics = import('/lua/editor/graphics.lua')

live = {}

function Refresh()
    local P = live.settings
    if P and P.Refresh then pcall(function() P:Refresh() end) end
end

Panels.Register{
    id = 'settings', title = 'Settings', minW = 280, minH = 240,
    create = function(group, host)
        local P = { rows = {}, presetButtons = {}, w = 300 }
        live.settings = P
        local c = Skin.color

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        P.gfxTitle = W.Label(group, 'Graphics', 0, 0, { color = c.text })
        P.presetLabel = W.Label(group, 'Quality preset', 0, 0, { color = c.textDim })
        for _, name in Graphics.PresetOrder do
            local preset = name
            P.presetButtons[preset] = Btn(Graphics.PresetLabels[preset], 64, function()
                Graphics.SetPreset(preset)
                P:Refresh()
            end, { toggle = true, tip = 'Sets every graphics setting below to the ' .. Graphics.PresetLabels[preset] .. ' preset.' })
        end
        for _, d in Graphics.Defs do
            local key = d.key
            local row = { key = key }
            row.label = W.Label(group, d.label, 0, 0, { color = c.text })
            row.button = Btn(Graphics.StateText(key), 110, function()
                Graphics.Cycle(key)
                P:Refresh()
            end, { tip = d.tip })
            table.insert(P.rows, row)
        end
        P.reset = Btn('Restore defaults', 120, function()
            Graphics.Reset()
            P:Refresh()
        end, { tip = 'Back to the highest quality (Ultra); anti-aliasing off and vertical sync on.' })
        P.note = W.Label(group, 'Anti-aliasing and vertical sync take effect at once; the window may flicker for a moment.', 0, 0, { color = c.textDim, size = 'small' })

        P.uiTitle = W.Label(group, 'Interface', 0, 0, { color = c.text })
        P.scaleLabel = W.Label(group, 'Size of the interface', 0, 0, { color = c.textDim })
        P.scaleDown = Btn('-', 30, function() Commands.Run('ui.scale.down') end, { tip = 'Make the interface smaller.' })
        P.scaleUp = Btn('+', 30, function() Commands.Run('ui.scale.up') end, { tip = 'Make the interface larger.' })
        P.scaleValue = W.Label(group, '', 0, 0, { color = c.text })

        function P:Refresh()
            local preset = Graphics.PresetName()
            for name, b in self.presetButtons do b:SetOn(name == preset) end
            for _, row in self.rows do row.button:SetText(Graphics.StateText(row.key)) end
            self.scaleValue:SetText(string.format('%d%%', math.floor(Skin.scale * 100 + 0.5)))
        end

        function P:OnResize(w, h)
            if not w then return end
            self.w = w
            local pad = Skin.S(10)
            local y = pad
            W.BeginLayout(group)
            W.Place(self.gfxTitle, group, pad, y)
            y = y + Skin.S(26)
            W.Place(self.presetLabel, group, pad, y)
            y = y + Skin.S(20)
            local x = pad
            for _, name in Graphics.PresetOrder do
                local b = self.presetButtons[name]
                local bw = b.Width()
                if x > pad and x + bw > w - pad then
                    x = pad
                    y = y + Skin.S(26)
                end
                W.Place(b, group, x, y, bw, Skin.S(22))
                x = x + bw + Skin.S(4)
            end
            y = y + Skin.S(32)
            local bw = Skin.S(110)
            local labelW = math.max(Skin.S(60), w - 2 * pad - bw - Skin.S(8))
            for _, row in self.rows do
                W.Fit(row.label, row.label:GetText(), labelW)
                W.Place(row.label, group, pad, y + Skin.S(3))
                W.Place(row.button, group, w - pad - bw, y, bw, Skin.S(22))
                y = y + Skin.S(28)
            end
            y = y + Skin.S(4)
            W.Place(self.reset, group, pad, y, self.reset.Width(), Skin.S(22))
            y = y + Skin.S(30)
            W.Fit(self.note, self.note:GetText(), w - 2 * pad)
            W.Place(self.note, group, pad, y)
            y = y + Skin.S(34)
            W.Place(self.uiTitle, group, pad, y)
            y = y + Skin.S(26)
            W.Place(self.scaleLabel, group, pad, y + Skin.S(3))
            local sx = pad + self.scaleLabel.Width() + Skin.S(12)
            W.Place(self.scaleDown, group, sx, y, Skin.S(30), Skin.S(22))
            W.Place(self.scaleValue, group, sx + Skin.S(36), y + Skin.S(3))
            W.Place(self.scaleUp, group, sx + Skin.S(36) + Skin.S(52), y, Skin.S(30), Skin.S(22))
            y = y + Skin.S(30)
            W.EndLayout(group)
            self:Refresh()
        end

        function P:Destroy()
            live.settings = nil
        end

        return P
    end,
}
