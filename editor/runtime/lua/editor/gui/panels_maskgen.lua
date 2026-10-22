-- The Mask generator panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2; logic in maskgen.lua).
--
-- A rule list makes a 0..1 mask from the terrain: slope, the engine's unit-class slope rule, height, curvature, aspect, water, noise, drainage, position, texture layers ... combined with AND / OR /
-- multiply / difference / add, then shaped with blur, grow, shrink, threshold ... Every number is a slider. The result shows live as a thumbnail and as red squares on the map around the camera
-- ("Show on map"); "Apply to layer" writes it into the paint mask of a texture layer (replace, add to, subtract from; "layers above take away" keeps it to the visible ground), "Apply to terrain
-- type" sets a terrain type where the mask is above a threshold. Each apply is ONE undo step.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fields = import('/lua/editor/fields.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Strata = import('/lua/editor/strata.lua')

NoAutoRefresh = true       -- the sliders would lose what is being typed
live = {}

state = { sel = 1, addType = 1, preset = 1, live = true, text = '', coverage = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Def() return MaskGen.Def end

local function Selected()
    return Def().rules[state.sel]
end

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

local function OpLabel(rule)
    for _, o in MaskGen.Ops do
        if o.id == rule.op then return o.label end
    end
    return rule.op
end

local function TypeNames()
    local list = {}
    for _, id in MaskGen.Order do table.insert(list, id) end
    return list
end

Panels.Register{
    id = 'maskgen', title = 'Mask generator', minW = 260, minH = 220, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = { sliders = {}, out = {} }
        live.maskgen = Pn
        Pn.group = group
        local c = Skin.color

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.pic = Bitmap(group)
        Pn.frame = Bitmap(group)
        Pn.frame:SetSolidColor(c.panelAlt)
        Pn.frame.Depth:Set(function() return group.Depth() + 4 end)
        Pn.pic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.pic:DisableHitTest()
        Pn.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.ruleLabel = W.Label(group, '', 0, 0, { color = c.text })
        Pn.outLabel = W.Label(group, 'Output', 0, 0, { color = c.text })
        Pn.typeLabel = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.layerNote = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })      -- why the Texture layer slider stops below 8 (the map's shader)

        -- ---- evaluation and thumbnail -------------------------------------------------------------------------------------------------------------

        --- The text beside the thumbnail (cheap: called by every refresh) ...
        local function ShowInfo()
            local f = MaskGen.Preview.field
            if not f then
                W.Fit(Pn.info, state.text ~= '' and state.text or 'no mask yet: add a rule or load a preset', (Pn.w or 300) - Skin.S(160))
                return
            end
            local mn, mx, mean = Fields.Stats(f)
            W.Fit(Pn.info, string.format('covers %.1f%% of the map (max %.2f)', mean * 100, mx), (Pn.w or 300) - Skin.S(160))
        end

        --- ... and the thumbnail picture (a new file every time: only after an evaluation).
        local function Show()
            local f = MaskGen.Preview.field
            if not f then
                Pn.pic:Hide()
            else
                local path = Fields.Preview(f, 128, { ramp = 'grey', lo = 0, hi = 1 })
                if path then
                    Pn.pic:SetTexture(path)
                    Pn.pic:Show()
                end
            end
            ShowInfo()
        end

        function Pn:Evaluate()
            if table.getn(Def().rules) == 0 then
                MaskGen.ClearPreview()
                state.text = 'no rules'
                Show()
                return
            end
            local t0 = ed_field_clock()
            local f, err = MaskGen.PreviewDef(Def())
            if f then
                state.text = string.format('%.0f ms', (ed_field_clock() - t0) * 1000)
            else
                state.text = tostring(err)
            end
            Show()
        end

        local function Changed()
            -- a slider that is being dragged changes many times a second: the preview is evaluated at most once per 80 ms, the last setting always (throttle.lua)
            if state.live then MaskGen.Defer(function() Pn:Evaluate() Pn:Refresh() end) end
            Pn:Refresh()
        end

        -- ---- the rule list --------------------------------------------------------------------------------------------------------------------------

        Pn.list = W.VirtualList(group, {
            rowH = 18,
            getCount = function() return table.getn(Def().rules) end,
            bind = function(row, index)
                local rule = Def().rules[index]
                local text = index .. '. '
                if index > 1 and MaskGen.Types[rule.type].kind == 'source' then
                    text = text .. string.upper(string.sub(rule.op, 1, 3)) .. (rule.invert and ' NOT ' or ' ')
                elseif rule.invert then
                    text = text .. 'NOT '
                end
                if rule.enabled == false then text = text .. '(off) ' end
                text = text .. MaskGen.Describe(rule)
                W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(index == state.sel and c.accent or (rule.enabled == false and c.textDim or c.text))
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                state.sel = index
                Pn:BuildSliders()
                Pn:OnResize(Pn.w, Pn.h)
                Pn:Refresh()
            end,
        })

        -- ---- buttons --------------------------------------------------------------------------------------------------------------------------------

        Pn.bPreview = Btn('Preview', 60, function() Pn:Evaluate() Pn:Refresh() end)
        Pn.bLive = Btn('Live', 40, function(self) state.live = self.on end, { toggle = true })
        Pn.bShow = Btn('Show on map', 90, function(self)
            MaskGen.Preview.show = self.on
            MaskGen.Preview.revision = MaskGen.Preview.revision + 1
        end, { toggle = true })
        Pn.bClear = Btn('Clear rules', 74, function()
            Def().rules = {}
            state.sel = 1
            Pn:BuildSliders()
            Pn:OnResize(Pn.w, Pn.h)
            Changed()
        end)
        Pn.bPreset = Btn('', 190, function()
            state.preset = math.mod(state.preset, table.getn(MaskGen.Presets)) + 1
            Pn:Refresh()
        end, { tip = 'The ready-made set of rules to start from. Click to step to the next one; Load preset takes it.' })
        Pn.bLoad = Btn('Load preset', 80, function()
            MaskGen.LoadPreset(Def(), state.preset)
            state.sel = 1
            Pn:BuildSliders()
            Pn:OnResize(Pn.w, Pn.h)
            Changed()
        end)
        Pn.bType = Btn('', 150, function()
            state.addType = math.mod(state.addType, table.getn(MaskGen.Order)) + 1
            Pn:Refresh()
        end, { tip = 'The kind of rule that Add makes (slope, height, curvature ...). Click to step to the next kind.' })
        Pn.bAdd = Btn('Add', 40, function()
            local rule = MaskGen.NewRule(MaskGen.Order[state.addType])
            local at = state.sel + 1
            if table.getn(Def().rules) == 0 then at = 1 end
            table.insert(Def().rules, at, rule)
            state.sel = at
            Pn:BuildSliders()
            Pn:OnResize(Pn.w, Pn.h)
            Changed()
        end)
        Pn.bDelete = Btn('Delete', 50, function()
            if not Selected() then return end
            table.remove(Def().rules, state.sel)
            state.sel = math.max(1, math.min(state.sel, table.getn(Def().rules)))
            Pn:BuildSliders()
            Pn:OnResize(Pn.w, Pn.h)
            Changed()
        end)
        local function Move(dir)
            local j = state.sel + dir
            local rules = Def().rules
            if not rules[state.sel] or not rules[j] then return end
            rules[state.sel], rules[j] = rules[j], rules[state.sel]
            state.sel = j
            Changed()
        end
        Pn.bUp = Btn('Up', 32, function() Move(-1) end)
        Pn.bDown = Btn('Down', 40, function() Move(1) end)
        Pn.bOn = Btn('On', 34, function(self)
            local r = Selected()
            if r then r.enabled = self.on end
            Changed()
        end, { toggle = true })
        Pn.bInvert = Btn('Not', 36, function(self)
            local r = Selected()
            if r then r.invert = self.on end
            Changed()
        end, { toggle = true })
        Pn.bOp = Btn('', 190, function()
            local r = Selected()
            if not r then return end
            local ops = MaskGen.Ops
            for i, o in ops do
                if o.id == r.op then
                    r.op = ops[math.mod(i, table.getn(ops)) + 1].id
                    break
                end
            end
            Changed()
        end, { tip = 'How the selected rule is combined with the rules above it (multiply, add, subtract ...). Click to step to the next way.' })

        -- ---- output ---------------------------------------------------------------------------------------------------------------------------------

        local T = MaskGen.Target
        Pn.out.layer = W.Slider(group, { label = 'Texture layer', compact = true, min = 1, max = 8, step = 1, fmt = '%d',
            get = function() return T.layer end, set = function(v) T.layer = v end })
        Pn.out.strength = W.Slider(group, { label = 'Strength', compact = true, min = 0, max = 1, step = 0.05, fmt = '%.2f',
            get = function() return T.strength end, set = function(v) T.strength = v end })
        Pn.out.code = W.Slider(group, { label = 'Terrain type (list position)', compact = true, min = 1, max = 99, step = 1, fmt = '%d',
            get = function() return T.typeIndex or 1 end,
            set = function(v)
                local types = import('/lua/editor/terraintype.lua').Types()
                v = math.max(1, math.min(table.getn(types), v))
                T.typeIndex = v
                if types[v] then T.typeCode = types[v].code end
                Pn:Refresh()
            end })
        Pn.out.threshold = W.Slider(group, { label = 'Terrain type where the mask is above', compact = true, min = 0.05, max = 0.95, step = 0.05, fmt = '%.2f',
            get = function() return T.threshold end, set = function(v) T.threshold = v end })
        Pn.bMode = Btn('', 130, function()
            T.mode = math.mod(T.mode, table.getn(MaskGen.MODES)) + 1
            Pn:Refresh()
        end, { tip = 'How the mask is written into the layer: replace what is there, add to it, or take away. Click to step to the next way.' })
        Pn.bAway = Btn('Layers above take away', 150, function(self) T.takeAway = self.on end, { toggle = true })
        -- the layer's texture by kind from the map's texture set (texsets.lua): so the mask shows as grass, rock, sand ... instead of an empty layer
        local TS = import('/lua/editor/texsets.lua')
        local roleIds, roleLabels = TS.RoleChoices()
        local function RoleIndex()
            for i, id in roleIds do
                if id == (T.texture or 'keep') then return i end
            end
            return 1
        end
        Pn.bTexture = Btn('', 170, function()
            local i = RoleIndex() + 1
            if i > table.getn(roleIds) then i = 1 end
            T.texture = roleIds[i]
            Pn:Refresh()
        end, { tip = 'Gives the layer a texture of this kind from the map\'s texture set when the mask is applied (Layers panel > Texture set). Keep leaves the texture the layer has. Click to step to the next kind.' })
        Pn.TextureText = function() return 'Texture: ' .. ((T.texture or 'keep') == 'keep' and 'keep' or TS.RoleLabels[T.texture]) end
        Pn.bApplyLayer = Btn('Apply to layer', 100, function()
            local n, err = MaskGen.ApplyToLayer(Def(), T)
            state.text = n and (n .. ' mask cells changed (layer ' .. T.layer .. ')') or ('not applied: ' .. tostring(err))
            Say(state.text)
            Changed()
        end)
        Pn.bApplyType = Btn('Apply to terrain type', 140, function()
            local n, err = MaskGen.ApplyToTypes(Def(), T)
            state.text = n and (n .. ' terrain type cells changed') or ('not applied: ' .. tostring(err))
            Say(state.text)
            Pn:Refresh()
        end)
        Pn.bWKind = Btn('', 150, function()
            T.wmask = math.mod(T.wmask, 3) + 1
            Pn:Refresh()
        end, { tip = 'Which water mask the mask is applied to: foam, flatness or depth bias. Click to step to the next.' })
        Pn.bApplyWater = Btn('Apply to water mask', 140, function()
            local n, err = MaskGen.ApplyToWaterMask(Def(), T)
            state.text = n and (n .. ' water mask cells changed (' .. Fields.WATER_MASKS[T.wmask] .. ', ' .. MaskGen.MODES[T.mode] .. ')') or ('not applied: ' .. tostring(err))
            Say(state.text)
            Pn:Refresh()
        end)
        Pn.bGenTypes = Btn('Types from layers', 110, function()
            local TT = import('/lua/editor/terraintype.lua')
            local entry, n = TT.Generate()
            if entry then
                UI.PushEdit(entry)
                state.text = n .. ' terrain type cells changed'
            else
                state.text = 'terrain types already match the layers'
            end
            Say(state.text)
            Pn:Refresh()
        end)

        -- ---- sliders of the selected rule -----------------------------------------------------------------------------------------------------------

        function Pn:BuildSliders()
            for _, s in self.sliders do DestroySlider(s) end
            self.sliders = {}
            local rule = Selected()
            if not rule then return end
            for _, p in MaskGen.Types[rule.type].params do
                local param = p
                local s = W.Slider(group, { label = param.label, compact = true, min = param.min, max = param.max, step = param.step, fmt = param.fmt,
                    get = function()
                        local r = Selected()
                        local v = r and r.v[param.key]
                        if v == nil then v = param.default end
                        return v
                    end,
                    set = function(v)
                        local r = Selected()
                        if r then r.v[param.key] = v end
                        Changed()
                    end })
                table.insert(self.sliders, s)
            end
        end

        function Pn:Refresh()
            local rule = Selected()
            self.list:Refresh()
            self.bPreset:SetText('Preset: ' .. MaskGen.Presets[state.preset].name)
            -- the preset names are long: cut to the button
            W.Fit(self.bPreset.label, 'Preset: ' .. MaskGen.Presets[state.preset].name, math.max(Skin.S(40), self.bPreset.Width() - Skin.S(10)))
            W.Center(self.bPreset.label, self.bPreset, 0, 0, self.bPreset.Width(), self.bPreset.Height())
            self.bType:SetText('New rule: ' .. MaskGen.Types[MaskGen.Order[state.addType]].label)
            self.bLive:SetOn(state.live)
            self.bShow:SetOn(MaskGen.Preview.show)
            self.bOn:SetOn(rule ~= nil and rule.enabled ~= false)
            self.bInvert:SetOn(rule ~= nil and rule.invert == true)
            self.bOp:SetText(rule and ('Combine: ' .. OpLabel(rule)) or 'Combine')
            self.bMode:SetText('Mode: ' .. MaskGen.MODES[T.mode])
            self.bTexture:SetText(self.TextureText())
            self.bAway:SetOn(T.takeAway)
            self.bWKind:SetText('Water mask: ' .. Fields.WATER_MASKS[T.wmask])
            -- only the layers the map's shader paints with a mask can be chosen (strata.lua PaintCap, as in recipes.lua)
            local cap = Strata.PaintCap()
            if cap ~= self.cap then
                self.cap = cap
                self.out.layer:SetRange(1, cap, 1)
                self.out.layer.drawnKey = nil
            end
            if T.layer > cap then T.layer = cap end
            local why = Strata.WhyNotPaintable(cap + 1)
            W.Fit(self.layerNote, cap < 8 and why and ('Layers above ' .. cap .. ' cannot be chosen. ' .. why .. '.') or '', (self.w or 300) - Skin.S(16))
            for _, s in self.sliders do s:Refresh() end
            for _, s in self.out do s:Refresh() end
            local TT = import('/lua/editor/terraintype.lua')
            local types = TT.Types()
            local ty = types[T.typeIndex or 1]
            if ty then
                T.typeCode = ty.code
                W.Fit(self.typeLabel, 'Terrain type: ' .. ty.name .. '  (code ' .. ty.code .. ')', (self.w or 300) - Skin.S(16))
            end
            W.Fit(self.ruleLabel, rule and ('Rule ' .. state.sel .. ': ' .. MaskGen.Types[rule.type].label) or 'No rule selected', (self.w or 300) - Skin.S(16))
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
            ShowInfo()
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
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
            local size = Skin.S(128)
            W.Place(self.frame, group, pad, y, size, size)
            W.Place(self.pic, group, pad, y, size, size)
            -- beside the thumbnail: the buttons of the view, then the presets
            local bx = size + 2 * pad
            local by = y
            local function Beside(b)
                local bw = b.Width()
                if bx > size + 2 * pad and bx + bw > w - pad then
                    bx = size + 2 * pad
                    by = by + Skin.S(26)
                end
                W.Place(b, group, bx, by, bw, Skin.S(22))
                bx = bx + bw + Skin.S(4)
            end
            for _, b in { self.bPreview, self.bLive, self.bShow, self.bClear } do Beside(b) end
            bx = size + 2 * pad
            by = by + Skin.S(26)
            Beside(self.bPreset)
            bx = size + 2 * pad
            by = by + Skin.S(26)
            Beside(self.bLoad)
            W.Place(self.info, group, size + 2 * pad, by + Skin.S(28))
            y = y + size + pad
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(18 * 6))
            y = y + Skin.S(18 * 6) + pad
            Flow({ self.bType, self.bAdd, self.bDelete, self.bUp, self.bDown, self.bOn, self.bInvert, self.bOp })
            W.Place(self.ruleLabel, group, pad, y)
            y = y + Skin.S(22)
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(210) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            local function Sliders(list)
                local i = 0
                for _, sl in list do
                    sl:Place(pad + math.mod(i, cols) * (colW + pad), y + math.floor(i / cols) * Skin.S(46), colW)
                    i = i + 1
                end
                y = y + math.ceil(i / cols) * Skin.S(46)
            end
            Sliders(self.sliders)
            y = y + Skin.S(6)
            W.Place(self.outLabel, group, pad, y)
            y = y + Skin.S(22)
            Sliders({ self.out.layer, self.out.strength })
            W.Place(self.layerNote, group, pad, y)
            y = y + Skin.S(16)
            Flow({ self.bMode, self.bAway, self.bTexture, self.bApplyLayer })
            Sliders({ self.out.code, self.out.threshold })
            W.Place(self.typeLabel, group, pad, y)
            y = y + Skin.S(20)
            Flow({ self.bApplyType, self.bGenTypes })
            Flow({ self.bWKind, self.bApplyWater })
            W.Place(self.status, group, pad, y)
            self:Refresh()
        end

        Pn:BuildSliders()
        if MaskGen.Preview.field then Show() end          -- the panel was rebuilt (a window move): show the preview that is there
        local types = import('/lua/editor/terraintype.lua').Types()
        if types[1] and not MaskGen.Target.typeIndex then MaskGen.Target.typeIndex = 1 MaskGen.Target.typeCode = types[1].code end
        if table.getn(types) > 0 then Pn.out.code:SetRange(1, table.getn(types), 1) end
        return Pn
    end,
}

--- Frees the preview (leaving the editor / a module reload).
function Release()
    MaskGen.ClearPreview()
end
