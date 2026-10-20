-- The Paths panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T4): the list of spline paths, the properties of the selected path and point, the cross-section profile curve, the
-- grade check, strata / props / decals along the path, and Preview / Apply / Bake. The model and all editing live in paths.lua, the viewport tool in pathtool.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Paths = import('/lua/editor/paths.lua')
local Tool = import('/lua/editor/pathtool.lua')
local CurveWidget = import('/lua/editor/gui/curvewidget.lua')

live = {}

state = { live = false, all = false, lastKey = '', lastPreview = -1, lastTime = 0, text = '', pathable = false, listIndex = 0, snapIndex = 1 }

local SNAPS = { 0, 1, 2, 4, 8 }
local SIDES = { 'both', 'left', 'right', 'center' }
local KINDS = { 'core', 'bank', 'reach' }

local function Say(text)
    state.text = text
    pcall(function() UI.State.message = text end)
end

local function Tick()
    return GetSystemTimeSeconds()
end

--- The paths a preview shows: every path (All paths switched on) or the selected one; nil when there is none.
function PreviewIds()
    if state.all then
        local ids = {}
        for _, p in Paths.List do table.insert(ids, p.id) end
        if table.getn(ids) > 0 then return ids end
        return nil
    end
    return Paths.Current and Paths.Current or nil
end

--- What the live preview depends on besides the model: which path is selected (unless every path is shown).
function PreviewKey()
    if state.all then return 'all' end
    return 'one:' .. tostring(Paths.Current)
end

local function PointValue(key, default)
    local path = Paths.CurrentPath()
    if not path or table.getn(path.points) == 0 then return default end
    local idx = Paths.SelectedIndices()
    local p = path.points[idx[1] or 1]
    local v = p and p[key]
    if v == nil then return default end
    return v
end

local function PathValue(key, default)
    local path = Paths.CurrentPath()
    local v = path and path[key]
    if v == nil then return default end
    return v
end

local function SubValue(group, key, default)
    local path = Paths.CurrentPath()
    local v = path and path[group] and path[group][key]
    if v == nil then return default end
    return v
end

local function StrataValue(index, key, default)
    local path = Paths.CurrentPath()
    local e = path and path.strata and path.strata[index]
    if not e or e[key] == nil then return default end
    return e[key]
end

local function Modes()
    return Paths.ModeOrder
end

local function CycleIn(list, value, step)
    for i, v in list do
        if v == value then
            return list[math.mod(i - 1 + step + table.getn(list), table.getn(list)) + 1]
        end
    end
    return list[1]
end

Panels.Register{
    id = 'paths', title = 'Paths', minW = 260, minH = 260, stack = { workspace = 'Terrain', with = 'layers' },
    create = function(group, host)
        local Pn = {}
        live.paths = Pn
        Pn.group = group
        local c = Skin.color

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end
        local function Sync() Pn:Refresh() end

        -- ---- the list and the tool state
        Pn.bDraw = Btn('Draw', 50, function()
            Paths.Mode = 'draw'
            UI.SelectTool('paths')
            Say('Draw: click the ground to add points; click the first point to close the path')
            Sync()
        end, { toggle = true })
        Pn.bEdit = Btn('Edit', 44, function()
            Paths.Mode = 'edit'
            UI.SelectTool('paths')
            Sync()
        end, { toggle = true })
        Pn.bNew = Btn('New path', 66, function()
            Paths.Current = false
            Paths.Sel = {}
            Paths.Mode = 'draw'
            UI.SelectTool('paths')
            Say('New ' .. Paths.Modes[Tool.NewMode].label .. ' path: click the ground to add points')
            Sync()
        end)
        Pn.bNewMode = Btn('New: ' .. Paths.Modes[Tool.NewMode].label, 100, function(self)
            Tool.NewMode = CycleIn(Modes(), Tool.NewMode, 1)
            self:SetText('New: ' .. Paths.Modes[Tool.NewMode].label)
        end)
        Pn.bSnap = Btn('Snap: off', 70, function(self)
            state.snapIndex = math.mod(state.snapIndex, table.getn(SNAPS)) + 1
            Paths.Snap = SNAPS[state.snapIndex]
            self:SetText(Paths.Snap > 0 and ('Snap: ' .. Paths.Snap) or 'Snap: off')
        end)
        Pn.bShow = Btn('Show paths', 84, function(self) Tool.Show = self.on Paths.Touch() end, { toggle = true })
        Pn.bShow:SetOn(Tool.Show)

        Pn.list = W.VirtualList(group, {
            rowH = 18,
            getCount = function() return table.getn(Paths.List) end,
            bind = function(row, index)
                local p = Paths.List[index]
                if not p then return end
                local flag = Paths.Results[p.id] and '  *' or ''
                W.Fit(row.text, string.format('%s   (%s, %d pts)%s', p.name or p.id, (Paths.Modes[p.mode] or Paths.Modes.carve).label, table.getn(p.points), flag), math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(p.id == Paths.Current and c.accent or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local p = Paths.List[index]
                if p then
                    Paths.Select(p.id, nil, false)
                    UI.SelectTool('paths')
                end
                Sync()
            end,
        })
        Pn.bDup = Btn('Duplicate', 62, function() if Paths.Current then Paths.Duplicate(Paths.Current) end Sync() end)
        Pn.bDel = Btn('Delete', 50, function() if Paths.Current then Paths.Delete(Paths.Current) end Sync() end)
        Pn.bCopy = Btn('Copy', 40, function() if Paths.CopyCurrent() then Say('path copied') end end)
        Pn.bPaste = Btn('Paste', 44, function() Paths.Paste() Sync() end)

        -- ---- the path
        Pn.title = W.Label(group, '', 0, 0, { color = c.text })
        Pn.name = W.TextField(group, 0, 0, Skin.S(150), Skin.S(22), { onEnter = function(text) Paths.SetField('name', text) Sync() end })
        Pn.bMode = Btn('Mode: carve', 100, function(self)
            local p = Paths.CurrentPath()
            if p then Paths.SetMode(CycleIn(Modes(), p.mode, 1)) end
            Sync()
        end)
        Pn.bKind = Btn('Catmull-Rom', 84, function()
            local p = Paths.CurrentPath()
            if p then Paths.SetField('kind', p.kind == 'bezier' and 'catmull' or 'bezier') end
            Sync()
        end)
        Pn.bClosed = Btn('Closed', 56, function(self) Paths.SetField('closed', self.on) Sync() end, { toggle = true })
        Pn.bSym = Btn('Mirror (symmetry)', 110, function(self) Paths.SetField('sym', self.on) Sync() end, { toggle = true })
        Pn.bInterp = Btn('Interpolate heights', 112, function(self) Paths.SetField('interp', self.on) Sync() end, { toggle = true })
        Pn.sStrength = W.Slider(group, { label = 'Strength', compact = true, min = 0, max = 1, step = 0.05, fmt = '%.2f',
            get = function() return PathValue('strength', 1) end, set = function(v) Paths.SetField('strength', v) end })
        Pn.sErosion = W.Slider(group, { label = 'Bank erosion (thermal passes, 0 = off)', compact = true, min = 0, max = 80, step = 1, fmt = '%d',
            get = function() return PathValue('erosion', 0) end, set = function(v) Paths.SetField('erosion', v) end })
        Pn.sBlend = W.Slider(group, { label = 'Blend into ground (units, 0 = off)', compact = true, min = 0, max = 60, step = 0.5, fmt = '%.1f',
            get = function() return PathValue('blend', 0) end, set = function(v) Paths.SetField('blend', v) end })
        Pn.sTension = W.Slider(group, { label = 'Curve tension', compact = true, min = 0.2, max = 2, step = 0.05, fmt = '%.2f',
            get = function() return PathValue('tension', 1) end, set = function(v) Paths.SetField('tension', v) end })

        -- ---- the selected point(s)
        Pn.pointTitle = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.sW = W.Slider(group, { label = 'Half width (units)', compact = true, min = 0.5, max = 80, step = 0.5, fmt = '%.1f',
            get = function() return PointValue('w', 6) end, set = function(v) Paths.SetPoint('w', v) end })
        Pn.sF = W.Slider(group, { label = 'Falloff width (units)', compact = true, min = 0, max = 80, step = 0.5, fmt = '%.1f',
            get = function() return PointValue('f', 4) end, set = function(v) Paths.SetPoint('f', v) end })
        Pn.sH = W.Slider(group, { label = 'Height', compact = true, min = -100, max = 300, step = 0.25, fmt = '%.2f',
            get = function() return PointValue('h', 0) end, set = function(v) Paths.SetPoint('h', v) end })
        Pn.sBank = W.Slider(group, { label = 'Bank angle (deg)', compact = true, min = -45, max = 45, step = 0.5, fmt = '%.1f',
            get = function() return PointValue('bank', 0) end, set = function(v) Paths.SetPoint('bank', v) end })
        Pn.bAbs = Btn('Absolute height', 100, function(self) Paths.SetAbsolute(self.on) Sync() end, { toggle = true })
        Pn.bSelAll = Btn('Select all points', 100, function()
            local p = Paths.CurrentPath()
            if p then
                Paths.Sel = {}
                for i = 1, table.getn(p.points) do Paths.Sel[i] = true end
                Paths.Touch()
            end
            Sync()
        end)

        -- ---- grade
        Pn.bLimit = Btn('Limit grade', 80, function(self) Paths.SetField('limitGrade', self.on) Sync() end, { toggle = true })
        Pn.sGrade = W.Slider(group, { label = 'Maximum grade (rise / run; 0.75 = land units)', compact = true, min = 0.05, max = 1.5, step = 0.01, fmt = '%.2f',
            get = function() return PathValue('grade', 0.75) end, set = function(v) Paths.SetField('grade', v) end })
        Pn.gradeText = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.bPathable = Btn('Check pathing', 90, function()
            local p = Paths.CurrentPath()
            if p then
                local frac, total = Paths.Pathable(p.id, p.grade)
                if frac then
                    state.pathable = string.format('%.0f%% of the %d corridor samples are steeper than %.2f', frac * 100, total, p.grade or 0.75)
                else
                    state.pathable = 'nothing to check'
                end
            end
            Sync()
        end)

        -- ---- profile
        Pn.profTitle = W.Label(group, 'Cross-section profile', 0, 0, { color = c.text })
        Pn.presets = {}
        for _, pr in Paths.Presets do
            local preset = pr
            table.insert(Pn.presets, Btn(preset.label, 8 + string.len(preset.label) * 6, function()
                Paths.UsePreset(preset.id)
                Sync()
            end))
        end
        Pn.curve = CurveWidget.Curve(group, {
            get = function()
                local p = Paths.CurrentPath()
                if not p then return {}, true, true end
                return p.profile.points, p.profile.smooth, p.profile.symmetric
            end,
            set = function(points)
                local p = Paths.CurrentPath()
                if p then Paths.SetProfile(points, p.profile.smooth, p.profile.symmetric, 'custom') end
            end,
            onDragEnd = function() Sync() end,
        })
        Pn.bSmooth = Btn('Smooth curve', 90, function(self)
            local p = Paths.CurrentPath()
            if p then Paths.SetProfile(p.profile.points, self.on, p.profile.symmetric, p.profile.preset) end
            Sync()
        end, { toggle = true })
        Pn.bSymP = Btn('Symmetric', 74, function(self)
            local p = Paths.CurrentPath()
            if p then Paths.SetProfile(p.profile.points, p.profile.smooth, self.on, p.profile.preset) end
            Sync()
        end, { toggle = true })

        -- ---- surface (strata along the path)
        Pn.surfTitle = W.Label(group, 'Texture along the path (0 = none)', 0, 0, { color = c.text })
        Pn.sLayer1 = W.Slider(group, { label = 'Core layer', compact = true, min = 0, max = 8, step = 1, fmt = '%d',
            get = function() return StrataValue(1, 'layer', 0) end, set = function(v) Paths.SetStrata(1, v, 'core') end })
        Pn.sLayer2 = W.Slider(group, { label = 'Bank layer', compact = true, min = 0, max = 8, step = 1, fmt = '%d',
            get = function() return StrataValue(2, 'layer', 0) end, set = function(v) Paths.SetStrata(2, v, 'bank') end })
        Pn.sLayerStrength = W.Slider(group, { label = 'Texture strength', compact = true, min = 0, max = 1, step = 0.05, fmt = '%.2f',
            get = function() return StrataValue(1, 'strength', 1) end, set = function(v) Paths.SetStrata(1, nil, nil, v) Paths.SetStrata(2, nil, nil, v) end })

        -- ---- props and decals
        Pn.scatTitle = W.Label(group, 'Props and decals along the path', 0, 0, { color = c.text })
        Pn.bProps = Btn('Props', 50, function(self) Paths.SetScatter('scatter', 'on', self.on) Sync() end, { toggle = true })
        Pn.bPropBp = Btn('Use prop brush', 94, function()
            local Props = import('/lua/editor/props.lua')
            if Props.Active then Paths.SetScatter('scatter', 'bp', Props.Active) end
            Sync()
        end)
        Pn.propName = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.sPropSpacing = W.Slider(group, { label = 'Prop spacing (units)', compact = true, min = 1, max = 60, step = 0.5, fmt = '%.1f',
            get = function() return SubValue('scatter', 'spacing', 6) end, set = function(v) Paths.SetScatter('scatter', 'spacing', v) end })
        Pn.sPropOff = W.Slider(group, { label = 'Distance beyond the edge', compact = true, min = -20, max = 40, step = 0.5, fmt = '%.1f',
            get = function() return SubValue('scatter', 'lateral', 1) end, set = function(v) Paths.SetScatter('scatter', 'lateral', v) end })
        Pn.bPropSide = Btn('Side: both', 84, function(self)
            Paths.SetScatter('scatter', 'side', CycleIn(SIDES, SubValue('scatter', 'side', 'both'), 1))
            Sync()
        end)
        Pn.bDecals = Btn('Decals', 54, function(self) Paths.SetScatter('decals', 'on', self.on) Sync() end, { toggle = true })
        Pn.bDecalTex = Btn('Use decal brush', 100, function()
            local Decals = import('/lua/editor/decals.lua')
            if Decals.Active then Paths.SetScatter('decals', 'tex', Decals.Active) end
            Sync()
        end)
        Pn.decalName = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.sDecalSpacing = W.Slider(group, { label = 'Decal spacing (units)', compact = true, min = 1, max = 80, step = 0.5, fmt = '%.1f',
            get = function() return SubValue('decals', 'spacing', 12) end, set = function(v) Paths.SetScatter('decals', 'spacing', v) end })
        Pn.sDecalSize = W.Slider(group, { label = 'Decal size (units)', compact = true, min = 1, max = 60, step = 0.5, fmt = '%.1f',
            get = function() return SubValue('decals', 'size', 6) end, set = function(v) Paths.SetScatter('decals', 'size', v) end })

        -- ---- the result
        Pn.bAll = Btn('All paths', 70, function(self)
            state.all = self.on
            if Paths.HasPreview() then Paths.RevertPreview() end
            state.lastPreview = -1
            Say(self.on and 'previews show every path together' or 'previews show the selected path only')
            Sync()
        end, { toggle = true })
        Pn.bLive = Btn('Live preview', 84, function(self)
            state.live = self.on
            if not self.on then Paths.RevertPreview() end
            state.lastPreview = -1
            Sync()
        end, { toggle = true })
        Pn.bPreview = Btn('Preview', 56, function()
            local ids = PreviewIds()
            if ids then
                local ok, err = Paths.Preview(ids)
                Say(ok and 'preview on the terrain; Apply keeps it, Revert removes it' or ('preview failed: ' .. tostring(err)))
                state.lastPreview = Paths.DataRevision
                state.lastKey = PreviewKey()
            end
            Sync()
        end)
        Pn.bRevert = Btn('Revert preview', 90, function() Paths.RevertPreview() Say('preview removed') Sync() end)
        Pn.bApply = Btn('Apply', 52, function()
            if Paths.Current then
                local n, err = Paths.Apply(Paths.Current)
                if n then Say(string.format('applied: %d height samples changed (one undo step)', n)) else Say('apply failed: ' .. tostring(err)) end
                state.lastPreview = Paths.DataRevision
            end
            Sync()
        end)
        Pn.bBake = Btn('Bake', 44, function()
            if Paths.Current and Paths.Bake(Paths.Current) then Say('baked: the result is frozen, the next Apply adds to the terrain') else Say('nothing to bake') end
            Sync()
        end)
        Pn.bUnapply = Btn('Remove result', 90, function()
            if Paths.Current then
                local n, err = Paths.Unapply(Paths.Current)
                Say(n and 'result removed (one undo step)' or tostring(err))
            end
            Sync()
        end)
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.status2 = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.status3 = W.Label(group, '', 0, 0, { color = c.text, size = 'small' })

        function Pn:Refresh()
            local p = Paths.CurrentPath()
            Pn.bDraw:SetOn(Paths.Mode == 'draw' and UI.State.tool == 'paths')
            Pn.bEdit:SetOn(Paths.Mode == 'edit' and UI.State.tool == 'paths')
            Pn.bShow:SetOn(Tool.Show)
            Pn.bLive:SetOn(state.live)
            Pn.list:Refresh()
            local mode = p and Paths.Modes[p.mode] or Paths.Modes.carve
            W.Fit(Pn.title, p and ('Path: ' .. (p.name or p.id)) or 'No path selected (Draw or pick one in the list)', (Pn.w or 300) - Skin.S(16))
            if p and Pn.nameFor ~= p.id then
                Pn.name:SetText(p.name or '')
                Pn.nameFor = p.id
            end
            Pn.bMode:SetText('Mode: ' .. string.lower(mode.label))
            Pn.bKind:SetText(p and p.kind == 'bezier' and 'Bezier' or 'Catmull-Rom')
            Pn.bClosed:SetOn(p and p.closed and true or false)
            Pn.bSym:SetOn(p and p.sym and true or false)
            Pn.bInterp:SetOn(p and p.interp ~= false)
            Pn.sH.label:SetText(mode.hLabel)
            local sel = Paths.SelectedIndices()
            local n = p and table.getn(p.points) or 0
            W.Fit(Pn.pointTitle, p and string.format('%d point(s), %s selected - changes apply to the selected points (all when none)', n, table.getn(sel) > 0 and (table.getn(sel) .. '') or 'none') or '', (Pn.w or 300) - Skin.S(16))
            Pn.bAbs:SetOn(PointValue('abs', false) and true or false)
            Pn.bLimit:SetOn(p and p.limitGrade and true or false)
            if p and table.getn(p.points) >= 2 then
                local rep = Paths.Report(p)
                local text = string.format('planned grade: max %.2f   %.0f%% of the length over the limit', rep.max, rep.over * 100)
                if state.pathable then text = text .. '   |   ' .. state.pathable end
                W.Fit(Pn.gradeText, text, (Pn.w or 300) - Skin.S(16))
            else
                W.Fit(Pn.gradeText, '', 10)
            end
            if p then
                Pn.bSmooth:SetOn(p.profile.smooth and true or false)
                Pn.bSymP:SetOn(p.profile.symmetric and true or false)
                Pn.bProps:SetOn(SubValue('scatter', 'on', false) and true or false)
                Pn.bDecals:SetOn(SubValue('decals', 'on', false) and true or false)
                Pn.bPropSide:SetText('Side: ' .. SubValue('scatter', 'side', 'both'))
                W.Fit(Pn.propName, 'prop: ' .. (SubValue('scatter', 'bp', '') ~= '' and SubValue('scatter', 'bp', '') or '(pick one with the prop brush first)'), (Pn.w or 300) - Skin.S(16))
                W.Fit(Pn.decalName, 'decal: ' .. (SubValue('decals', 'tex', '') ~= '' and SubValue('decals', 'tex', '') or '(pick one with the decal brush first)'), (Pn.w or 300) - Skin.S(16))
            end
            for _, s in { Pn.sStrength, Pn.sErosion, Pn.sBlend, Pn.sTension, Pn.sW, Pn.sF, Pn.sH, Pn.sBank, Pn.sGrade, Pn.sLayer1, Pn.sLayer2, Pn.sLayerStrength,
                          Pn.sPropSpacing, Pn.sPropOff, Pn.sDecalSpacing, Pn.sDecalSize } do
                s:Refresh()
            end
            Pn.curve:Refresh()
            local res = p and Paths.Results[p.id]
            local line = p and (res and 'applied in this session: Apply replaces it' or (p.wasApplied and 'applied in an earlier session (baked): Apply adds to the terrain' or 'not applied yet')) or ''
            if Paths.HasPreview() then line = 'previewing on the terrain' end
            W.Fit(Pn.status, line, (Pn.w or 300) - Skin.S(16))
            local stats = Paths.StatsText()
            W.Fit(Pn.status2, (state.text and state.text ~= '') and state.text or stats, (Pn.w or 300) - Skin.S(16))
            W.Fit(Pn.status3, stats, (Pn.w or 300) - Skin.S(16))
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
            local function Slider(s)
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(46)
            end
            local function Line(label, gap)
                W.Place(label, group, pad, y)
                y = y + (gap or Skin.S(18))
            end
            Flow({ self.bDraw, self.bEdit, self.bNew, self.bNewMode, self.bSnap, self.bShow })
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(18) * 4)
            y = y + Skin.S(18) * 4 + Skin.S(6)
            Flow({ self.bDup, self.bDel, self.bCopy, self.bPaste })
            Line(self.title, Skin.S(22))
            W.Place(self.name, group, pad, y, Skin.S(150), Skin.S(22))
            W.Place(self.name.frame, group, pad, y, Skin.S(150), Skin.S(22))
            y = y + Skin.S(28)
            Flow({ self.bMode, self.bKind, self.bClosed, self.bSym, self.bInterp })
            Slider(self.sStrength)
            Slider(self.sErosion)
            Slider(self.sBlend)
            Slider(self.sTension)
            Line(self.pointTitle)
            Slider(self.sW)
            Slider(self.sF)
            Slider(self.sH)
            Slider(self.sBank)
            Flow({ self.bAbs, self.bSelAll })
            Flow({ self.bLimit, self.bPathable })
            Slider(self.sGrade)
            Line(self.gradeText, Skin.S(22))
            Line(self.profTitle, Skin.S(20))
            Flow(self.presets)
            local ch = math.max(Skin.S(120), math.min(Skin.S(200), math.floor((w - 2 * pad) * 0.6)))
            self.curve:Place(pad, y, w - 2 * pad, ch)
            y = y + ch + Skin.S(6)
            Flow({ self.bSmooth, self.bSymP })
            Line(self.surfTitle, Skin.S(20))
            Slider(self.sLayer1)
            Slider(self.sLayer2)
            Slider(self.sLayerStrength)
            Line(self.scatTitle, Skin.S(20))
            Flow({ self.bProps, self.bPropBp, self.bPropSide })
            Line(self.propName)
            Slider(self.sPropSpacing)
            Slider(self.sPropOff)
            Flow({ self.bDecals, self.bDecalTex })
            Line(self.decalName)
            Slider(self.sDecalSpacing)
            Slider(self.sDecalSize)
            Flow({ self.bAll, self.bLive, self.bPreview, self.bRevert, self.bApply, self.bBake, self.bUnapply })
            Line(self.status)
            Line(self.status3)
            Line(self.status2)
            self:Refresh()
        end

        return Pn
    end,
}

--- Ticked about four times a second by the shell: the live preview follows the model.
function Refresh()
    local pn = live.paths
    if pn and pn.Refresh then pcall(function() pn:Refresh() end) end
    -- the preview follows the model and the selection: another path selected shows that path at once (no off and on again)
    if state.live and (Paths.DataRevision ~= state.lastPreview or PreviewKey() ~= state.lastKey) and Tick() - state.lastTime > 0.3 then
        state.lastTime = Tick()
        local ids = PreviewIds()
        if ids then
            local ok, err = Paths.Preview(ids)
            if not ok then state.text = 'preview: ' .. tostring(err) end
        else
            Paths.RevertPreview()
        end
        state.lastPreview = Paths.DataRevision
        state.lastKey = PreviewKey()
    end
end
