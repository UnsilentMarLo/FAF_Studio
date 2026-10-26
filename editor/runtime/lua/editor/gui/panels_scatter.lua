-- The Props scatter panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2; logic in scatter.lua).
--
-- Fills the map with props: a list of blueprints (add the one selected in the Props panel; each has a weight), a density mask (the Mask generator's rules, switch "Density from the mask rules"),
-- slope and height limits, a minimum distance between props (Poisson disc), a seed and a count. With a symmetry mode on, every prop comes with its images. "Count" shows what would be placed,
-- "Scatter" places it as ONE undo step.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Scatter = import('/lua/editor/scatter.lua')
local Props = import('/lua/editor/props.lua')
local Decals = import('/lua/editor/decals.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

NoAutoRefresh = true
live = {}

state = { sel = 1, text = '', useMask = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Name(path)
    return (string.gsub(string.gsub(string.gsub(path or '', '^.*/', ''), '_prop%.bp$', ''), '_albedo%.dds$', ''))
end

--- The entries of the current mode (props or decals).
local function Cur()
    return Scatter.Settings.mode == 'decals' and Scatter.DecalEntries or Scatter.Entries
end

local SLIDERS = {
    { 'seed', 'Seed', 0, 9999, 1, '%d' },
    { 'count', 'Most props', 1, 20000, 1, '%d' },
    { 'minDist', 'Minimum distance (units)', 0.5, 80, 0.5, '%.1f' },
    { 'fill', 'Fill (share of the density used)', 0, 1, 0.05, '%.2f' },
    { 'slopeMin', 'Slope from (degrees)', 0, 89, 1, '%d' },
    { 'slopeMax', 'Slope up to (degrees)', 1, 90, 1, '%d' },
    { 'heightMin', 'Height from (units)', -100, 600, 1, '%d' },
    { 'heightMax', 'Height up to (units)', -100, 600, 1, '%d' },
    { 'scaleMin', 'Scale from (percent)', 20, 300, 5, '%d' },
    { 'scaleMax', 'Scale up to (percent)', 20, 300, 5, '%d' },
    { 'margin', 'Distance from the map edge (units)', 0, 100, 1, '%d' },
    { 'decalSize', 'Decal size at scale 100 (units)', 1, 100, 1, '%d' },
}

Panels.Register{
    id = 'scatter', title = 'Props scatter', minW = 260, minH = 220, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = { sliders = {} }
        live.scatter = Pn
        local c = Skin.color
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.entriesLabel = W.Label(group, 'Props to scatter (pick one in the Props panel, then Add)', 0, 0, { color = c.text })
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.symLabel = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        Pn.list = W.VirtualList(group, {
            rowH = 18,
            getCount = function() return table.getn(Cur()) end,
            bind = function(row, index)
                local e = Cur()[index]
                W.Fit(row.text, string.format('%s   weight %g', Name(e.bp), e.weight or 1), math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(index == state.sel and c.accent or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                state.sel = index
                Pn:Refresh()
            end,
        })

        Pn.bAdd = Btn('Add selected prop', 120, function()
            local decals = Scatter.Settings.mode == 'decals'
            local pick = decals and Decals.Active or Props.Active
            if not pick then
                state.text = decals and 'select a decal in the Decals panel first' or 'select a prop in the Props panel first'
            else
                table.insert(Cur(), { bp = pick, weight = 1 })
                state.sel = table.getn(Cur())
                state.text = 'added ' .. Name(pick)
            end
            Pn:Refresh()
        end)
        Pn.bRemove = Btn('Remove', 60, function()
            if Cur()[state.sel] then table.remove(Cur(), state.sel) end
            state.sel = math.max(1, math.min(state.sel, table.getn(Cur())))
            Pn:Refresh()
        end)
        Pn.weight = W.Slider(group, { label = 'Weight of the selected prop', compact = true, min = 0, max = 20, step = 0.5, fmt = '%.1f',
            get = function()
                local e = Cur()[state.sel]
                return e and e.weight or 1
            end,
            set = function(v)
                local e = Cur()[state.sel]
                if e then e.weight = v end
                Pn.list:Refresh()
            end })

        for _, s in SLIDERS do
            local key = s[1]
            table.insert(Pn.sliders, W.Slider(group, { label = s[2], compact = true, min = s[3], max = s[4], step = s[5], fmt = s[6],
                get = function() return Scatter.Settings[key] end,
                set = function(v) Scatter.Settings[key] = v end }))
        end

        local S = Scatter.Settings
        Pn.bHeading = Btn('Random heading', 110, function(self) S.randomHeading = self.on end, { toggle = true })
        Pn.bExisting = Btn('Keep away from existing props', 190, function(self) S.avoidExisting = self.on end, { toggle = true })
        Pn.bWater = Btn('Allow under water', 120, function(self) S.underWater = self.on end, { toggle = true })
        Pn.bDecals = Btn('Decals instead of props', 160, function(self)
            S.mode = self.on and 'decals' or 'props'
            state.sel = 1
            Pn:Refresh()
        end, { toggle = true })
        Pn.bNormals = Btn('With normals decals', 140, function(self) S.withNormals = self.on end, { toggle = true })
        Pn.bMask = Btn('Density from the mask rules', 170, function(self)
            state.useMask = self.on
            Scatter.Density = self.on and MaskGen.Def or { rules = {} }
            Pn:Refresh()
        end, { toggle = true })
        --- Why nothing can be placed (an empty plan used to say "placed 0 props (one undo step)").
        local function NoGround(report)
            if report and report.open and report.open <= 0.001 then
                return string.format('no ground passes the limits (density, slope, height%s; the water level is %.0f)', S.underWater and '' or ', dry land: "Allow under water" lifts that', report.water or 0)
            end
            return nil
        end
        Pn.bCount = Btn('Count', 54, function()
            local plan, report = Scatter.Plan()
            if plan and table.getn(plan) == 0 and NoGround(report) then
                state.text = 'nothing would be placed: ' .. NoGround(report)
            elseif plan then
                state.text = string.format('would place %d props (%d tries, %d too close, %d off the density)', report.placed, report.attempts, report.tooClose, report.rejected)
            else
                state.text = tostring(report)
            end
            Pn:Refresh()
        end)
        Pn.bDetail = Btn('Detail pass', 90, function()
            local Detail = import('/lua/editor/detail.lua')
            local summary, total = Detail.Run{}
            if summary then
                local parts = {}
                for _, r in summary do table.insert(parts, r.placed .. ' ' .. r.id) end
                state.text = 'detail pass: ' .. total .. ' placed (' .. table.concat(parts, ', ') .. '); one undo step per class'
            else
                state.text = 'detail pass failed: ' .. tostring(total)
            end
            Say(state.text)
            Pn:Refresh()
        end, { tip = 'Small rocks on gentle ground, big rocks on cliffs, crevice, patch and cliff decals: five classes by size and slope, in clusters, for the environment of the current texture set (the measured density of Operation Citadel). Each class is one undo step.' })
        Pn.bDetailDensity = Btn('Detail density: 1x', 130, function(self)
            local Detail = import('/lua/editor/detail.lua')
            local order = { 0.5, 1, 2 }
            local nextScale = 1
            for i, v in order do
                if Detail.Scale == v then nextScale = order[math.mod(i, 3) + 1] end
            end
            Detail.Scale = nextScale
            self:SetText('Detail density: ' .. nextScale .. 'x')
        end, { tip = 'How many things the detail pass places: half, the measured density, or twice.' })
        Pn.bScatter = Btn('Scatter', 70, function()
            local n, report = Scatter.Apply()
            if n == 0 then
                state.text = 'nothing placed: ' .. (NoGround(report) or 'every try was too close to another prop or off the density')
            elseif n then
                state.text = string.format('placed %d %s (one undo step)', n, S.mode == 'decals' and 'decals' or 'props')
            else
                state.text = 'not placed: ' .. tostring(report)
            end
            Say(state.text)
            Pn:Refresh()
        end)

        function Pn:Refresh()
            self.list:Refresh()
            self.weight:Refresh()
            for _, s in self.sliders do s:Refresh() end
            self.bHeading:SetOn(S.randomHeading)
            self.bExisting:SetOn(S.avoidExisting)
            self.bWater:SetOn(S.underWater)
            self.bMask:SetOn(state.useMask)
            self.bDecals:SetOn(S.mode == 'decals')
            self.bNormals:SetOn(S.withNormals)
            self.entriesLabel:SetText(S.mode == 'decals' and 'Decals to scatter (pick one in the Decals panel, then Add)' or 'Props to scatter (pick one in the Props panel, then Add)')
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
            W.Fit(self.symLabel, Symmetry.Mode == 'off' and 'Symmetry is off: props are placed once.' or ('Symmetry: ' .. Symmetry.Mode .. ' - every prop comes with its ' .. (Symmetry.Count() - 1) .. ' image(s).'),
                (self.w or 300) - Skin.S(16))
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.Place(self.entriesLabel, group, pad, y)
            y = y + Skin.S(22)
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(18 * 5))
            y = y + Skin.S(18 * 5) + pad
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
            Flow({ self.bAdd, self.bRemove })
            self.weight:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(48)
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(210) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            for i, sl in self.sliders do
                sl:Place(pad + math.mod(i - 1, cols) * (colW + pad), y + math.floor((i - 1) / cols) * Skin.S(46), colW)
            end
            y = y + math.ceil(table.getn(self.sliders) / cols) * Skin.S(46) + Skin.S(4)
            Flow({ self.bHeading, self.bExisting, self.bWater, self.bMask, self.bDecals, self.bNormals })
            W.Place(self.symLabel, group, pad, y)
            y = y + Skin.S(22)
            Flow({ self.bCount, self.bScatter, self.bDetail, self.bDetailDensity })
            W.Place(self.status, group, pad, y)
            self:Refresh()
        end

        return Pn
    end,
}
