-- The Settings panel (File > Settings...): graphics quality (a preset and every setting behind it) and the size of the interface. The values live in graphics.lua / skin.lua; the panel keeps
-- nothing but its controls. It is only ever shown in a window of its own (windowOnly: closing the window does not dock it into the main window). Every control is made again for
-- the width the panel has (Build), so the buttons stretch with the window.
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
    id = 'settings', title = 'Settings', minW = 280, minH = 240, windowOnly = true,
    create = function(group, host)
        local P = { items = {}, rows = {}, presetButtons = {}, w = 0 }
        live.settings = P
        local c = Skin.color

        local function Keep(ctl) table.insert(P.items, ctl) return ctl end

        function P:Clear()
            for _, ctl in self.items do ctl:Destroy() end
            self.items, self.rows, self.presetButtons = {}, {}, {}
        end

        --- The lines of the display report under its button (cut to the panel width).
        function P:ShowDisplay()
            if not self.displayLabels then return end
            for i, l in self.displayLabels do
                local text = self.displayText and self.displayText[i] or ''
                W.Fit(l, text, (self.textW or Skin.S(300)))
            end
        end

        function P:Refresh()
            if not self.built then return end
            local preset = Graphics.PresetName()
            for name, b in self.presetButtons do b:SetOn(name == preset) end
            for _, row in self.rows do row.button:SetText(Graphics.StateText(row.key)) end
            self.scaleValue:SetText(string.format('%d%%', math.floor(Skin.scale * 100 + 0.5)))
            if self.gpuLine1 then
                local l1, l2 = Graphics.GpuStatus(false)
                if self.gpuResult then l2 = self.gpuResult end
                if l1 ~= self.gpuShown1 or l2 ~= self.gpuShown2 then         -- Refresh runs four times a second: measure text only when it changed
                    self.gpuShown1, self.gpuShown2 = l1, l2
                    W.Fit(self.gpuLine1, l1, self.textW)
                    W.Fit(self.gpuLine2, l2, self.textW)
                end
            end
        end

        --- Makes every control for a panel `w` pixels wide and puts it in place.
        function P:Build(w)
            self:Clear()
            local pad = Skin.S(12)
            local gap = Skin.S(6)
            local rowH = Skin.S(24)
            local y = pad
            local function Btn(text, x, yy, bw, fn, opts)
                return Keep(W.Button(group, text, x, yy, bw, rowH, fn, opts))
            end
            W.BeginLayout(group)

            Keep(W.Label(group, 'Graphics', pad, y, { color = c.text }))
            y = y + Skin.S(28)
            Keep(W.Label(group, 'Quality preset', pad, y, { color = c.textDim }))
            y = y + Skin.S(22)
            local count = table.getn(Graphics.PresetOrder)
            -- one row of buttons, or two rows when the panel is too narrow for the longest label ("Medium") in a quarter of the width
            local cols = count
            if math.floor((w - 2 * pad - (count - 1) * gap) / count) < Skin.S(72) then cols = math.ceil(count / 2) end
            local bw = math.floor((w - 2 * pad - (cols - 1) * gap) / cols)
            for i, name in Graphics.PresetOrder do
                local preset = name
                local col, row = math.mod(i - 1, cols), math.floor((i - 1) / cols)
                self.presetButtons[preset] = Btn(Graphics.PresetLabels[preset], pad + col * (bw + gap), y + row * (rowH + gap), bw, function()
                    Graphics.SetPreset(preset)
                    P:Refresh()
                end, { toggle = true, tip = 'Sets every graphics setting below to the ' .. Graphics.PresetLabels[preset] .. ' preset.' })
            end
            y = y + (math.ceil(count / cols)) * (rowH + gap) - gap + Skin.S(12)

            local cw = math.max(Skin.S(110), math.floor((w - 2 * pad) * 0.4))
            local labelW = math.max(Skin.S(60), w - 2 * pad - cw - gap)
            for _, d in Graphics.Defs do
                local key = d.key
                local label = Keep(W.Label(group, d.label, pad, y + Skin.S(4), { color = c.text }))
                W.Fit(label, d.label, labelW)
                local button = Btn(Graphics.StateText(key), w - pad - cw, y, cw, function()
                    Graphics.Cycle(key)
                    P:Refresh()
                end, { tip = d.tip })
                table.insert(self.rows, { key = key, button = button })
                y = y + rowH + Skin.S(6)
            end
            -- GPU compute: the adapter and the state (one line each, cut to the panel width) and a button that runs the native self test
            self.textW = w - 2 * pad
            self.gpuShown1, self.gpuShown2 = nil, nil
            self.gpuLine1 = Keep(W.Label(group, '', pad, y, { color = c.textDim, size = 'small' }))
            y = y + Skin.S(18)
            self.gpuLine2 = Keep(W.Label(group, '', pad, y, { color = c.textDim, size = 'small' }))
            y = y + Skin.S(24)
            Btn('Test GPU compute', pad, y, math.min(w - 2 * pad, Skin.S(180)), function()
                local summary, lines = Graphics.GpuTest()
                for _, l in lines do LOG('EDITOR gpu: ' .. l) end
                LOG('EDITOR gpu: ' .. summary)
                P.gpuResult = summary
                P:Refresh()
            end, { tip = 'Checks the graphics card: runs small compute programs and compares the results with the processor. Details go to the Console panel.' })
            y = y + rowH + Skin.S(12)
            Btn('Restore defaults', pad, y, math.min(w - 2 * pad, Skin.S(160)), function()
                Graphics.Reset()
                P:Refresh()
            end, { tip = 'Back to the highest quality (Ultra); anti-aliasing off and vertical sync on.' })
            y = y + rowH + Skin.S(10)
            local lines, bottom = W.Paragraph(group, 'Anti-aliasing and vertical sync take effect at once; the window may flicker for a moment.', pad, y, w - 2 * pad,
                                              { color = c.textDim, size = 'small' }, Skin.S(16))
            for _, l in lines do Keep(l) end
            y = (bottom or (y + Skin.S(16))) + Skin.S(18)

            Keep(W.Label(group, 'Interface', pad, y, { color = c.text }))
            y = y + Skin.S(28)
            local scaleLabel = Keep(W.Label(group, 'Size of the interface', pad, y + Skin.S(4), { color = c.textDim }))
            local sx = pad + scaleLabel.Width() + Skin.S(14)
            Btn('-', sx, y, Skin.S(32), function() Commands.Run('ui.scale.down') end, { tip = 'Make the interface smaller.' })
            self.scaleValue = Keep(W.Label(group, '100%', sx + Skin.S(40), y + Skin.S(4), { color = c.text }))
            Btn('+', sx + Skin.S(40) + Skin.S(56), y, Skin.S(32), function() Commands.Run('ui.scale.up') end, { tip = 'Make the interface larger.' })
            y = y + rowH + pad

            -- Display: the window size, the measured frame rate, the saved graphics settings and the camera, as one report (also in the Console panel and the log): what to send when the picture misbehaves
            Keep(W.Label(group, 'Display', pad, y, { color = c.text }))
            y = y + Skin.S(28)
            Btn('Display report', pad, y, math.min(w - 2 * pad, Skin.S(180)), function()
                local lines = import('/lua/editor/display.lua').Report()
                for _, l in lines do LOG('EDITOR display: ' .. l) end
                P.displayText = lines
                P:ShowDisplay()
            end, { tip = 'Measures the frame rate and lists the window size, the graphics settings and the camera. Take a screenshot of it, or find the same lines in the Console panel.' })
            y = y + rowH + Skin.S(8)
            self.displayLabels = {}
            for i = 1, 9 do
                self.displayLabels[i] = Keep(W.Label(group, '', pad, y, { color = c.textDim, size = 'small' }))
                y = y + Skin.S(16)
            end
            self:ShowDisplay()

            W.EndLayout(group)
            self.built, self.w = true, w
            self:Refresh()
        end

        function P:OnResize(w, h)
            if not w then return end
            self:Build(w)
        end

        function P:Destroy()
            live.settings = nil
        end

        return P
    end,
}
