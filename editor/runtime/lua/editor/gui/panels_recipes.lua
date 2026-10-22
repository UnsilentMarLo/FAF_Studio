-- The Stratum recipes panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2; logic in recipes.lua).
--
-- Pick a preset (temperate, alpine, desert, arctic, rocky): it lists the kinds of ground from the bottom up and makes each one's mask from slope / height / curvature / water / noise rules.
-- Give every role a texture layer (0 = skip it; the base role is the Base layer), tune the knobs, look at one role on the map ("Show role"), then Apply: the paint masks of the layers and the
-- terrain-type grid are written in ONE undo step. The layers above take away, so a cliff covers rock covers dirt covers grass; the terrain types follow what is seen most in each cell.
-- The panel shows the shader of the map (how many layers it paints, which mask range) and warns when a kind sits on a layer the shader cannot paint: it is moved to a free layer (recipes.lua).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Recipes = import('/lua/editor/recipes.lua')
local MaskGen = import('/lua/editor/maskgen.lua')

live = {}

state = { text = '', summary = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

local function Texture(layer)
    if layer < 1 then return layer == 0 and 'Base layer' or '' end
    local albedo = ed_stratum_layer(layer)
    if not albedo or albedo == '' then return 'no texture' end
    return (string.gsub(albedo, '^.*/', ''))
end

Panels.Register{
    id = 'recipes', title = 'Stratum recipes', minW = 260, minH = 220, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = { knobSliders = {}, roles = {} }
        live.recipes = Pn
        local c = Skin.color
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.shaderLine = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.warns = {}
        for i = 1, 3 do Pn.warns[i] = W.Label(group, '', 0, 0, { color = c.warn, size = 'small' }) end
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.note = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.rolesLabel = W.Label(group, 'Kinds of ground, bottom to top', 0, 0, { color = c.text })
        Pn.knobsLabel = W.Label(group, 'Settings of the preset', 0, 0, { color = c.text })
        Pn.summaryLabels = {}

        local function Fresh()
            Pn.roles = Recipes.Roles()
            local layers = Recipes.State.layers
            if not layers or table.getn(layers) ~= table.getn(Pn.roles) then Recipes.State.layers = Recipes.AutoLayers(Pn.roles) end
            Recipes.State.selected = math.max(1, math.min(Recipes.State.selected or 1, table.getn(Pn.roles)))
        end

        Pn.bPreset = Btn('', 280, function()
            Recipes.State.preset = math.mod(Recipes.State.preset, table.getn(Recipes.Presets)) + 1
            Recipes.State.layers = nil
            Recipes.State.selected = 1
            Fresh()
            Pn:BuildKnobs()
            Pn:OnResize(Pn.w, Pn.h)
        end, { tip = 'The recipe (grass, desert, snow ... ). Click to step to the next one.' })

        Pn.list = W.VirtualList(group, {
            rowH = 20,
            getCount = function() return table.getn(Pn.roles) end,
            bind = function(row, index)
                local role = Pn.roles[index]
                local layer = Recipes.State.layers[index] or 0
                local fit = Recipes.FitLayers(Recipes.State.layers)[index] or layer
                local text = string.format('%d. %s  ->  %s', index, role.label, (index == 1) and 'Base layer' or (layer >= 1 and ((fit ~= layer and ('layer ' .. layer .. ' > ' .. fit) or ('layer ' .. layer)) .. '  ' .. Texture(fit)) or 'skipped'))
                W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(index == Recipes.State.selected and c.accent or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                Recipes.State.selected = index
                Pn:Refresh()
            end,
        })

        Pn.layer = W.Slider(group, { label = 'Texture layer of the selected kind (0 = skip)', compact = true, min = 0, max = Recipes.Cap(), step = 1, fmt = '%d',
            get = function() return Recipes.State.layers[Recipes.State.selected] or 0 end,
            set = function(v)
                if Recipes.State.selected == 1 then return end        -- the base role stays on the Base layer
                Recipes.State.layers[Recipes.State.selected] = math.min(v, Recipes.Cap())
                Pn:Refresh()
            end })

        Pn.bShow = Btn('Show kind on map', 120, function()
            local f, err = Recipes.PreviewRole(Recipes.State.selected)
            state.text = f and ('showing ' .. Pn.roles[Recipes.State.selected].label .. ' (red squares on the map)') or tostring(err)
            MaskGen.Preview.show = true
            Pn:Refresh()
        end)
        Pn.bHide = Btn('Hide', 44, function()
            MaskGen.ClearPreview()
            state.text = ''
            Pn:Refresh()
        end)
        Pn.bAuto = Btn('Layers in order', 100, function()
            Recipes.State.layers = Recipes.AutoLayers(Pn.roles)
            Pn:Refresh()
        end)
        Pn.bMatch = Btn('Match textures', 100, function()
            Recipes.State.layers = Recipes.MatchTextures(Pn.roles)
            state.text = 'layers picked by the texture names'
            Pn:Refresh()
        end)
        Pn.bTypes = Btn('Terrain types too', 110, function(self) Recipes.State.types = self.on end, { toggle = true })
        Pn.bApply = Btn('Apply recipe', 100, function()
            Fresh()
            local summary, cells = Recipes.Apply()
            if summary then
                state.summary = summary
                state.text = cells .. ' cells changed (one undo step)'
            else
                state.summary = false
                state.text = 'not applied: ' .. tostring(cells)
            end
            Say(state.text)
            Pn:Refresh()
        end)

        function Pn:BuildKnobs()
            for _, s in self.knobSliders do DestroySlider(s) end
            self.knobSliders = {}
            local uses = Recipes.Presets[Recipes.State.preset].uses
            for _, info in Recipes.KnobInfo do
                local wanted = false
                for _, k in uses do if k == info.key then wanted = true end end
                if wanted then
                    local i = info
                    local s = W.Slider(group, { label = i.label, compact = true, min = i.min, max = i.max, step = i.step, fmt = i.fmt,
                        get = function() return Recipes.Knobs[i.key] end,
                        set = function(v)
                            Recipes.Knobs[i.key] = v
                            Fresh()
                            Pn.list:Refresh()
                        end })
                    table.insert(self.knobSliders, s)
                end
            end
        end

        function Pn:Refresh()
            self.bPreset:SetText('Preset: ' .. Recipes.Presets[Recipes.State.preset].name)
            self.bTypes:SetOn(Recipes.State.types)
            -- the shader decides how many layers have a mask: the layer choice follows it, and a kind left on a layer it cannot paint is shown moved
            self.layer:SetRange(0, Recipes.Cap(), 1, '%d')
            self.list:Refresh()
            self.layer:Refresh()
            local line, warnings = Recipes.Notes(self.roles)
            W.Fit(self.shaderLine, line, (self.w or 300) - Skin.S(16))
            for i = 1, 3 do
                W.Fit(self.warns[i], warnings[i] or '', (self.w or 300) - Skin.S(16))
            end
            for _, s in self.knobSliders do s:Refresh() end
            local role = self.roles[Recipes.State.selected]
            W.Fit(self.note, role and ((Recipes.State.selected == 1) and 'The base role has no mask: it is what the other kinds leave free.' or 'Mask of this kind: ' .. table.getn(role.rules) .. ' rules (open them in the Mask generator by copying)') or '', (self.w or 300) - Skin.S(16))
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
            local lines = {}
            if state.summary then
                for _, e in state.summary do
                    table.insert(lines, string.format('%-24s %5.1f%%   %s', e.label, e.share * 100, e.layer >= 1 and ('layer ' .. e.layer) or 'Base'))
                end
            end
            for i = 1, 8 do
                local lab = self.summaryLabels[i]
                if not lab then
                    lab = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
                    self.summaryLabels[i] = lab
                end
                lab:SetText(lines[i] or '')
            end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            self:Refresh()          -- also makes the summary labels, placed below
            local pad = Skin.S(8)
            local y = pad
            W.Place(self.bPreset, group, pad, y, math.min(Skin.S(280), w - 2 * pad), Skin.S(22))
            y = y + Skin.S(30)
            W.Place(self.shaderLine, group, pad, y)
            y = y + Skin.S(16)
            for i = 1, 3 do
                W.Place(self.warns[i], group, pad, y)
                y = y + Skin.S(16)
            end
            y = y + Skin.S(4)
            W.Place(self.rolesLabel, group, pad, y)
            y = y + Skin.S(22)
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(20 * math.max(3, math.min(6, table.getn(self.roles)))))
            y = y + Skin.S(20 * math.max(3, math.min(6, table.getn(self.roles)))) + pad
            self.layer:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(48)
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
            Flow({ self.bShow, self.bHide, self.bAuto, self.bMatch })
            W.Place(self.note, group, pad, y)
            y = y + Skin.S(22)
            W.Place(self.knobsLabel, group, pad, y)
            y = y + Skin.S(22)
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(210) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            for i, sl in self.knobSliders do
                sl:Place(pad + math.mod(i - 1, cols) * (colW + pad), y + math.floor((i - 1) / cols) * Skin.S(46), colW)
            end
            y = y + math.ceil(table.getn(self.knobSliders) / cols) * Skin.S(46) + Skin.S(4)
            Flow({ self.bTypes, self.bApply })
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(20)
            for i = 1, 8 do
                if self.summaryLabels[i] then W.Place(self.summaryLabels[i], group, pad, y) end
                y = y + Skin.S(16)
            end
        end

        Fresh()
        Pn:BuildKnobs()
        return Pn
    end,
}

--- The shell calls this four times a second: the panel only follows a change of the map's shader (its sliders would lose what is being typed if it refreshed everything every time).
function Refresh()
    local Pn = live.recipes
    if not Pn or not Pn.w or not rawget(_G, 'ed_stratum_shader') then return end
    local name = ed_stratum_shader() or ''
    if name ~= Pn.shaderShown then
        Pn.shaderShown = name
        Pn:Refresh()
    end
end
