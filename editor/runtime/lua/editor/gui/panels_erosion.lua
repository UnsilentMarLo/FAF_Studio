-- The Erosion panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3): presets, solver parameters (every number a field + slider + minus / plus), a live preview at low resolution
-- on the real terrain with Revert, Apply as ONE undo step (optionally writing the wear, deposit and flow masks into texture layers), and the values of the Erode / Rain / Deposit brushes.
-- The solvers run in the native field engine (erosion.lua, moho/editor/EdErosion.cpp).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fields = import('/lua/editor/fields.lua')
local Erosion = import('/lua/editor/erosion.lua')
local EroBrush = import('/lua/editor/erosionbrush.lua')

live = {}

-- the brush sliders: key of EroBrush.Values, label, min, max, step, format
local BRUSH = {
    { 'iterations', 'Drop rounds per strength', 1, 12, 1, '%d' },
    { 'rain', 'Rain amount', 0.0005, 0.05, 0.0005, '%.4f' },
    { 'capacity', 'Sediment capacity', 0.05, 4, 0.05, '%.2f' },
    { 'erosion', 'Dissolving rate', 0.01, 0.6, 0.01, '%.2f' },
    { 'deposition', 'Settling rate', 0.01, 0.6, 0.01, '%.2f' },
    { 'inertia', 'Inertia', 0, 0.9, 0.05, '%.2f' },
    { 'conserve', 'Keep volume', 0, 1, 0.05, '%.2f' },
    { 'thermal', 'Thermal slides', 0, 1, 0.05, '%.2f' },
    { 'reach', 'Rain run-off reach', 0.1, 2, 0.05, '%.2f' },
    { 'amount', 'Deposit amount (units)', 0.05, 5, 0.05, '%.2f' },
    { 'vary', 'Hardness variation', 0, 1, 0.05, '%.2f' },
    { 'vary_scale', 'Hardness feature size (units)', 4, 200, 2, '%d' },
}

pv = { result = false, text = '', seconds = 0, dirty = false, last = 0 }      -- the coarse result of the last preview (module level: the controls come and go)

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Clock()
    return rawget(_G, 'ed_field_clock') and ed_field_clock() or 0
end

local function DropResult()
    if pv.result then Erosion.Free(pv.result) pv.result = false end
end

--- Runs the coarse preview with the panel values; shows the thumbnail (and the real terrain when "On terrain" is on).
local function RunPreview(Pn)
    local ok, err = pcall(function()
        local t0 = Clock()
        DropResult()
        local step = Erosion.PreviewStep()
        pv.result = Erosion.Run(Erosion.state.solver, Erosion.ValuesOf(Erosion.state.solver), { step = step })
        if Erosion.state.onTerrain then Erosion.ShowPreview(pv.result) end
        pv.seconds = Clock() - t0
        pv.text = string.format(step > 1 and 'preview on every %d. sample: %.0f ms' or 'preview at full resolution: %.0f ms', step > 1 and step or pv.seconds * 1000, pv.seconds * 1000)
    end)
    pv.dirty = false
    pv.last = Clock()
    if not ok then pv.text = 'preview failed: ' .. tostring(err) end
    if Pn then Pn:Show() end
end

--- A value changed: run the preview now when live (at most four times a second; the tick catches up).
local function Changed(Pn)
    if not Pn or not Pn.bLive or not Pn.bLive.on then return end
    pv.dirty = true
    if Clock() - pv.last > 0.25 then RunPreview(Pn) end
end

--- Module level tick: a change that came too soon after the last preview is caught up here.
function Refresh()
    local Pn = live.erosion
    if Pn and pv.dirty and Pn.bLive and Pn.bLive.on and Clock() - pv.last > 0.25 then RunPreview(Pn) end
end

Panels.Register{
    id = 'erosion', title = 'Erosion', minW = 240, minH = 200, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = {}
        live.erosion = Pn
        Pn.group = group
        local c = Skin.color
        local st = Erosion.state

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.pic = Bitmap(group)
        Pn.frame = Bitmap(group)
        Pn.frame:SetSolidColor(c.panelAlt)
        Pn.frame.Depth:Set(function() return group.Depth() + 4 end)
        Pn.pic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.pic:DisableHitTest()
        Pn.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.solverLabel = W.Label(group, '', 0, 0, { color = c.text })
        Pn.brushLabel = W.Label(group, 'Brushes: Erode, Rain, Deposit (Terrain tools)', 0, 0, { color = c.text })
        Pn.masksLabel = W.Label(group, 'Write masks into texture layers on Apply', 0, 0, { color = c.text })
        Pn.sliders = {}
        Pn.maskSliders = {}
        Pn.maskButtons = {}
        Pn.brushSliders = {}

        function Pn:Show()
            local f = pv.result and pv.result.height
            if not f then
                self.pic:Hide()
                W.Fit(self.info, 'no preview yet', (self.w or 300) - Skin.S(16))
            else
                local path = Fields.Preview(f, 128, { ramp = 'terrain' })
                if path then
                    self.pic:SetTexture(path)
                    self.pic:Show()
                end
                local mn, mx, mean = Fields.Stats(f)
                W.Fit(self.info, string.format('preview  min %.1f  max %.1f  mean %.1f', mn, mx, mean), (self.w or 300) - Skin.S(16))
            end
            self:Refresh()
        end

        -- presets and solvers
        Pn.presetButtons = {}
        for _, preset in Erosion.Presets do
            local id = preset.id
            local b = Btn(preset.label, 78, function()
                Erosion.UsePreset(id)
                Pn:Build()
                Pn:OnResize(Pn.w, Pn.h)
                Changed(Pn)
                Pn:Refresh()
            end)
            table.insert(Pn.presetButtons, b)
        end
        Pn.solverButtons = {}
        for _, name in Erosion.SolverOrder do
            local solver = name
            local b = Btn(Erosion.Solvers[name].label, 130, function()
                st.solver = solver
                st.preset = ''
                Pn:Build()
                Pn:OnResize(Pn.w, Pn.h)
                Changed(Pn)
                Pn:Refresh()
            end, { toggle = true })
            table.insert(Pn.solverButtons, { name = name, button = b })
        end

        -- actions
        Pn.bPreview = Btn('Preview', 62, function() RunPreview(Pn) end)
        Pn.bLive = Btn('Live', 44, function(self) if self.on then Changed(Pn) end end, { toggle = true })
        Pn.bLive:SetOn(true)
        Pn.bTerrain = Btn('On terrain', 74, function(self)
            st.onTerrain = self.on
            if self.on then
                if pv.result then
                    pcall(Erosion.ShowPreview, pv.result)
                else
                    RunPreview(Pn)
                end
            else
                Erosion.Revert()
            end
            Pn:Refresh()
        end, { toggle = true })
        Pn.bTerrain:SetOn(Erosion.IsShown())
        Pn.bRevert = Btn('Revert', 54, function()
            Erosion.Revert()
            st.onTerrain = false
            Pn.bTerrain:SetOn(false)
            pv.text = 'reverted'
            Pn:Refresh()
        end)
        Pn.bApply = Btn('Apply', 54, function()
            local ok, changed = pcall(function()
                local t0 = Clock()
                local solver = st.solver
                local n = Erosion.Apply(solver, Erosion.ValuesOf(solver), { label = 'Erosion (' .. (st.preset ~= '' and st.preset or solver) .. ')' })
                pv.seconds = Clock() - t0
                return n
            end)
            st.onTerrain = false
            Pn.bTerrain:SetOn(false)
            if ok then
                pv.text = string.format('applied: %d samples changed in %.1f s (one undo step)', changed or 0, pv.seconds)
            else
                pv.text = 'apply failed: ' .. tostring(changed)
            end
            Say(pv.text)
            Pn:Refresh()
        end)
        Pn.bSeed = Btn('New seed', 66, function()
            local v = Erosion.ValuesOf(st.solver)
            if v.seed then
                v.seed = math.mod(math.floor(v.seed * 7 + 13), 9999) + 1
                Pn:Refresh()
                Changed(Pn)
            end
        end)

        --- Sliders of the selected solver.
        function Pn:Build()
            for _, s in self.sliders do
                for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
                s.field:Destroy()
                if s.field.frame then s.field.frame:Destroy() end
            end
            self.sliders = {}
            for _, p in Erosion.Solvers[st.solver].params do
                local param = p
                local s = W.Slider(group, { label = param.label, tip = param.tip, compact = true, min = param.min, max = param.max, step = param.step, fmt = param.fmt,
                    get = function() return Erosion.ValuesOf(st.solver)[param.key] end,
                    set = function(v)
                        Erosion.ValuesOf(st.solver)[param.key] = v
                        Changed(Pn)
                    end })
                table.insert(self.sliders, s)
            end
        end

        -- mask outputs: a toggle and a layer slider per mask
        for _, key in { 'wear', 'deposit', 'flow', 'accum' } do
            local k = key
            local m = st.masks[k]
            local b = Btn(string.upper(string.sub(k, 1, 1)) .. string.sub(k, 2), 64, function(self) m.on = self.on end, { toggle = true })
            b:SetOn(m.on)
            table.insert(Pn.maskButtons, b)
            table.insert(Pn.maskSliders, W.Slider(group, { label = 'Layer for ' .. k, compact = true, min = 1, max = 8, step = 1, fmt = '%d',
                get = function() return m.layer end, set = function(v) m.layer = v end }))
        end

        -- brush values
        for _, def in BRUSH do
            local d = def
            table.insert(Pn.brushSliders, W.Slider(group, { label = d[2], compact = true, min = d[3], max = d[4], step = d[5], fmt = d[6],
                get = function() return EroBrush.Values[d[1]] end, set = function(v) EroBrush.Values[d[1]] = v end }))
        end

        function Pn:Refresh()
            W.Fit(self.status, pv.text, (self.w or 300) - Skin.S(16))
            W.Fit(self.solverLabel, 'Solver: ' .. Erosion.Solvers[st.solver].label .. (st.preset ~= '' and ('   preset: ' .. st.preset) or ''), (self.w or 300) - Skin.S(16))
            for _, s in self.sliders do s:Refresh() end
            for _, s in self.maskSliders do s:Refresh() end
            for _, s in self.brushSliders do s:Refresh() end
            for _, e in self.solverButtons do e.button:SetOn(e.name == st.solver) end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.BeginLayout(group)
            local function Flow(buttons)
                local bx = pad
                for _, b in buttons do
                    local bw = b.Width()
                    if bx > pad and bx + bw > w - pad then
                        bx = pad
                        y = y + Skin.S(26)
                    end
                    W.Place(b, group, bx, y, bw, Skin.S(22))
                    bx = bx + bw + Skin.S(4)
                end
                y = y + Skin.S(26)
            end
            Flow(self.presetButtons)
            local solvers = {}
            for _, e in self.solverButtons do table.insert(solvers, e.button) end
            Flow(solvers)
            Flow({ self.bPreview, self.bLive, self.bTerrain, self.bRevert, self.bApply, self.bSeed })
            local size = Skin.S(128)
            W.Place(self.frame, group, pad, y, size, size)
            W.Place(self.pic, group, pad, y, size, size)
            local rightX = size + 2 * pad
            W.Place(self.info, group, rightX, y)
            W.Place(self.status, group, rightX, y + Skin.S(18))
            y = y + size + Skin.S(6)
            W.Place(self.solverLabel, group, pad, y)
            y = y + Skin.S(22)
            local function Grid(list)
                local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(190) + pad)))
                local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
                local i = 0
                local rows = 0
                for _, sl in list do
                    local col = math.mod(i, cols)
                    local row = math.floor(i / cols)
                    sl:Place(pad + col * (colW + pad), y + row * Skin.S(46), colW)
                    rows = row + 1
                    i = i + 1
                end
                y = y + rows * Skin.S(46) + Skin.S(4)
            end
            Grid(self.sliders)
            W.Place(self.masksLabel, group, pad, y)
            y = y + Skin.S(22)
            Flow(self.maskButtons)
            Grid(self.maskSliders)
            W.Place(self.brushLabel, group, pad, y)
            y = y + Skin.S(22)
            Grid(self.brushSliders)
            W.EndLayout(group)
            self:Refresh()
        end

        function Pn:Destroy()
            live.erosion = nil
        end

        Pn:Build()
        Pn:Show()
        return Pn
    end,
}

--- Frees what the panel holds (a module reload or leaving the editor).
function Release()
    Erosion.Release()
    DropResult()
end
