-- The Stratum recipes panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2; logic in recipes.lua, role detection in roledetect.lua).
--
-- A recipe paints the eight kinds of ground (grass, dirt, wet ground, sand, rock, dark rock, high rock, snow) on the texture layers that hold them. The table lists every layer of the map with
-- its texture, the kind of ground the editor found in it (from the file name, else from the colour of the texture) and how sure it is; click the kind to correct it (remembered per texture).
-- The Base layer can be any kind: it is the default ground, so the recipe leaves that kind to the base and lets the others claim their places. A kind with no layer is skipped; Assign textures
-- fills EMPTY layers with the textures of the missing kinds from the current texture set. "Show" draws one layer's kind on the map (red squares). The settings below are the rules' numbers
-- (cliff angle, snow share, beach width, dirt coverage ...). Apply writes the paint masks and the terrain-type grid in ONE undo step and measures how much of the map each layer covers
-- (mask = the opacity share of the layer's mask, seen = what shows after the layers above took theirs).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Detect = import('/lua/editor/roledetect.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Menu = import('/lua/editor/gui/menu.lua')

live = {}

state = { text = '', summary = false, cov = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

local function Pct(v) return string.format('%.0f%%', (v or 0) * 100) end

--- The text of the role button of a layer: the kind, and how sure the editor is.
local function RoleText(e, cap)
    if not e then return 'empty' end
    if e.layer > cap then return 'not painted' end
    if e.override == 'none' then return 'Not used (set)' end
    if e.override then return Detect.Label(e.override) .. ' (set)' end
    if not e.role then return 'Unknown' end
    return Detect.Label(e.role) .. ' ' .. Pct(e.conf)
end

--- The layers' signature: changes when a texture is swapped (the shell tick compares it).
local function Signature()
    local parts = {}
    for l = 0, 8 do parts[l + 1] = tostring(Detect.Albedo(l) or '') end
    return table.concat(parts, '|')
end

Panels.Register{
    id = 'recipes', title = 'Stratum recipes', minW = 260, minH = 220, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = { knobSliders = {}, roles = {}, rows = {}, plan = false }
        live.recipes = Pn
        local c = Skin.color
        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.shaderLine = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.warns = {}
        for i = 1, 5 do Pn.warns[i] = W.Label(group, '', 0, 0, { color = c.warn, size = 'small' }) end
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.note = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.rolesLabel = W.Label(group, 'Layers and their kind of ground', 0, 0, { color = c.text })
        Pn.covNote = W.Label(group, 'mask: share of the map the mask covers; seen: share that shows', 0, 0, { color = c.textDim, size = 'small' })
        Pn.knobsLabel = W.Label(group, 'Settings of the recipe', 0, 0, { color = c.text })
        Pn.summaryLabels = {}

        local function Fresh()
            Pn.plan = Recipes.Plan()
            Pn.roles = Recipes.Roles()
        end

        Pn.bPreset = Btn('', 280, function()
            local items = {}
            for i, p in Recipes.Presets do
                local index = i
                table.insert(items, { title = p.name, checked = (index == Recipes.State.preset), run = function()
                    Recipes.SelectPreset(index)
                    Fresh()
                    for _, s in Pn.knobSliders do s:Refresh() end
                    Pn:Refresh()
                end })
            end
            Menu.Show(GetFrame(0), Pn.bPreset.Left(), Pn.bPreset.Bottom(), items)
        end, { tip = 'The style of the recipe: the built-in ones (natural, alpine, desert, arctic, rocky, valley, coast) and one per family of maps, measured on the maps of your Maps folder. It sets the numbers below.' })

        -- one row per layer 0..8: texture, kind of ground (a menu), Show, coverage
        for l = 0, 8 do
            local layer = l
            local row = { layer = layer }
            row.name = W.Label(group, '', 0, 0, { color = c.text, size = 'small' })
            row.cov = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
            row.btn = W.Button(group, '', 0, 0, Skin.S(130), Skin.S(22), function()
                local e = Pn.plan and Pn.plan.info[layer]
                if not e then return end
                local items = {}
                local autoText = e.auto and ('Detected: ' .. Detect.Label(e.auto) .. ' ' .. Pct(e.autoConf)) or 'Detected: unknown'
                table.insert(items, { title = autoText .. (e.override == nil and '   (current)' or ''), run = function()
                    Detect.SetOverride(e.albedo, nil)
                    Fresh()
                    Pn:Refresh()
                end })
                local ids, labels = Detect.Choices()
                for i, id in ids do
                    local role = id
                    table.insert(items, { title = labels[i] .. (e.override == role and '   (current)' or ''), run = function()
                        Detect.SetOverride(e.albedo, role)
                        Fresh()
                        Pn:Refresh()
                    end })
                end
                local x, y = row.btn.Left(), row.btn.Bottom()
                Menu.Show(GetFrame(0), x, y, items)
            end, { tip = 'The kind of ground this layer\'s texture shows, found from its file name and colour. Click to choose another kind, or Not used to leave the layer alone.' })
            row.show = W.Button(group, 'Show', 0, 0, Skin.S(44), Skin.S(22), function()
                local e = Pn.plan and Pn.plan.info[layer]
                if not e or not e.role then
                    state.text = 'this layer has no kind of ground'
                    Pn:Refresh()
                    return
                end
                local index
                for i, id in Recipes.Order do
                    if id == e.role then index = i end
                end
                local f, err = Recipes.PreviewRole(index)
                state.text = f and ('showing ' .. Detect.Label(e.role) .. ' (red squares on the map)') or tostring(err)
                MaskGen.Preview.show = true
                Pn:Refresh()
            end, { tip = 'Show where the recipe puts this kind of ground, as red squares on the map.' })
            Pn.rows[l + 1] = row
        end

        Pn.bHide = Btn('Hide', 44, function()
            MaskGen.ClearPreview()
            state.text = ''
            Pn:Refresh()
        end, { tip = 'Hide the red squares.' })
        Pn.bDetect = Btn('Detect again', 100, function()
            Detect.Forget()
            Detect.ClearOverrides()
            Recipes.Invalidate()
            Recipes.State.layers = nil
            Fresh()
            state.text = 'kinds of ground detected again from the textures'
            Pn:Refresh()
        end, { tip = 'Read the textures again and forget the kinds you set by hand.' })
        Pn.bAssign = Btn('Assign textures', 110, function()
            local n, text = Recipes.AssignMissing()
            state.text = text
            Say(text)
            Fresh()
            Pn:Refresh()
        end, { tip = 'Give empty layers the textures of the kinds of ground the map lacks, from the current texture set. Layers that have a texture are not touched.' })
        Pn.bMeasure = Btn('Measure', 70, function()
            state.cov = Recipes.Coverage() or false
            state.text = state.cov and 'coverage measured from the masks on the map' or 'no masks to measure'
            Pn:Refresh()
        end, { tip = 'Measure how much of the map each layer covers now, from its paint mask.' })
        Pn.bTypes = Btn('Terrain types too', 110, function(self) Recipes.State.types = self.on end, { toggle = true, tip = 'Also write the terrain types (how ground sounds and slows units) from the layer seen most in each cell.' })
        Pn.bRough = Btn('Roughness too', 100, function(self) Recipes.State.roughness = self.on end, { toggle = true, tip = 'For the Terrain1xx and Terrain2xx shaders: also set the roughness multiplier of layer 8 from the paint (wet ground, ice and snow shiny, dry rock and sand rough).' })
        Pn.bApply = Btn('Apply recipe', 100, function()
            Fresh()
            local summary, cells = Recipes.Apply()
            if summary then
                state.summary = summary
                state.text = cells .. ' cells changed (one undo step)'
                state.cov = Recipes.Coverage() or false
            else
                state.summary = false
                state.text = 'not applied: ' .. tostring(cells)
            end
            Say(state.text)
            Pn:Refresh()
        end, { tip = 'Paint the map with the recipe. One undo step.' })

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
                            Pn:RefreshRows()
                        end })
                    table.insert(self.knobSliders, s)
                end
            end
        end

        --- The table: one line per layer.
        function Pn:RefreshRows()
            local cap = Recipes.Cap()
            local plan = self.plan
            local cov = state.cov
            for l = 0, 8 do
                local row = self.rows[l + 1]
                local e = plan and plan.info[l]
                local nameW = math.max(Skin.S(60), (self.nameW or Skin.S(120)))
                local label = (l == 0 and 'Base' or ('Layer ' .. l)) .. ': ' .. (e and e.short or 'no texture')
                W.Fit(row.name, label, nameW)
                row.name:SetColor((e and l <= cap) and c.text or c.textDim)
                row.btn:SetText(RoleText(e, cap))
                local text = ''
                if cov and e and l <= cap then
                    if l == 0 then
                        text = 'seen ' .. Pct(cov.seen[0])
                    else
                        text = 'mask ' .. Pct(cov.mask[l]) .. '  seen ' .. Pct(cov.seen[l])
                    end
                end
                W.Fit(row.cov, text, math.max(Skin.S(40), self.covW or Skin.S(120)))
            end
        end

        function Pn:Refresh()
            self.bPreset:SetText('Style: ' .. Recipes.Presets[Recipes.State.preset].name)
            self.bTypes:SetOn(Recipes.State.types)
            self.bRough:SetOn(Recipes.State.roughness ~= false)
            if not self.plan then Fresh() end
            self.sigShown = Signature()
            self:RefreshRows()
            local line, warnings = Recipes.Notes(self.roles)
            W.Fit(self.shaderLine, line, (self.w or 300) - Skin.S(16))
            for i = 1, 5 do
                W.Fit(self.warns[i], warnings[i] or '', (self.w or 300) - Skin.S(16))
            end
            for _, s in self.knobSliders do s:Refresh() end
            W.Fit(self.note, 'Rules of the recipe: select a style, then Apply. Kinds with no layer are skipped.', (self.w or 300) - Skin.S(16))
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
            local lines = {}
            if state.summary then
                for _, e in state.summary do
                    local where = e.layer >= 1 and ('layer ' .. e.layer) or (e.layer == 0 and 'Base' or '')
                    table.insert(lines, string.format('%-30s %5.1f%%   %s', e.label, e.share * 100, where))
                end
            end
            for i = 1, 10 do
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
            local pad = Skin.S(8)
            local gap = Skin.S(4)
            -- table columns: name | kind button | Show | coverage; a narrow panel puts the name on a line of its own
            local btnW, showW = Skin.S(130), Skin.S(44)
            local twoLine = w < Skin.S(420)
            local covW = Skin.S(130)
            self.covW = covW
            self.nameW = twoLine and (w - 2 * pad - covW - gap) or (w - 2 * pad - btnW - showW - covW - 3 * gap)
            self:Refresh()          -- also makes the summary labels, placed below
            local y = pad
            W.Place(self.bPreset, group, pad, y, math.min(Skin.S(300), w - 2 * pad), Skin.S(22))
            y = y + Skin.S(30)
            W.Place(self.shaderLine, group, pad, y)
            y = y + Skin.S(16)
            for i = 1, 5 do
                W.Place(self.warns[i], group, pad, y)
                y = y + Skin.S(16)
            end
            y = y + Skin.S(4)
            W.Place(self.rolesLabel, group, pad, y)
            y = y + Skin.S(20)
            for l = 0, 8 do
                local row = self.rows[l + 1]
                if twoLine then
                    W.Place(row.name, group, pad, y)
                    W.Place(row.cov, group, pad + self.nameW + gap, y)
                    y = y + Skin.S(16)
                    W.Place(row.btn, group, pad, y, btnW, Skin.S(22))
                    W.Place(row.show, group, pad + btnW + gap, y, showW, Skin.S(22))
                    y = y + Skin.S(28)
                else
                    W.Place(row.name, group, pad, y + Skin.S(4))
                    W.Place(row.btn, group, pad + self.nameW + gap, y, btnW, Skin.S(22))
                    W.Place(row.show, group, pad + self.nameW + btnW + 2 * gap, y, showW, Skin.S(22))
                    W.Place(row.cov, group, pad + self.nameW + btnW + showW + 3 * gap, y + Skin.S(4))
                    y = y + Skin.S(26)
                end
            end
            W.Place(self.covNote, group, pad, y)
            y = y + Skin.S(22)
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
            Flow({ self.bHide, self.bDetect, self.bAssign, self.bMeasure })
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
            Flow({ self.bTypes, self.bRough, self.bApply })
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(20)
            for i = 1, 10 do
                if self.summaryLabels[i] then W.Place(self.summaryLabels[i], group, pad, y) end
                y = y + Skin.S(16)
            end
        end

        Fresh()
        Pn:BuildKnobs()
        return Pn
    end,
}

--- The shell calls this four times a second: the panel follows a change of the map's shader or of the layers' textures (its sliders would lose what is being typed if it refreshed everything
--- every time).
function Refresh()
    local Pn = live.recipes
    if not Pn or not Pn.w or not rawget(_G, 'ed_stratum_shader') then return end
    local name = ed_stratum_shader() or ''
    local sig = Signature()
    if name ~= Pn.shaderShown or sig ~= Pn.sigShown then
        Pn.shaderShown = name
        Pn.plan = Recipes.Plan()
        Pn.roles = Recipes.Roles()
        state.cov = false
        Pn:Refresh()
    end
end
