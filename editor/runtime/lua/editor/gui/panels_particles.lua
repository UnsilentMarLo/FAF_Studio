-- The Particle editor panel (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP8_PARTICLES.md): an emitter, beam or trail file as the game's own editor shows it. The model is
-- fxparticle.lua (the logic upstream's, bound as ed_fx_*); the preview is the Particle preview panel (panels_particleview.lua), the files come from the Particle browser (panels_particlebrowser.lua).
--
--   Curves     the 21 curves of an emitter: a list, the curve with its keys (drag a key, click empty plot to add one, right click / Ctrl+click to delete: gui/curvewidget.lua), the spread of the selected
--              key as a band, and the selected key's time, value and spread as sliders
--   Settings   lifetime, repeat time, frames, strips, blend mode, the on / off switches, the three fidelity levels, the textures
--   Beam/Trail the catalogue of a beam's or trail's keys (numbers, colours, textures); a key the file lacks shows the engine's default and is written when it is changed
--
-- The preview follows every edit within a frame (Fx.Apply). `Write` puts the file into the open mod project or the map's folder (`effects/emitters/<name>`).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fx = import('/lua/editor/fxparticle.lua')
local CurveWidget = import('/lua/editor/gui/curvewidget.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function ShowControl(c, shown)
    local parts = c.track and { c.label, c.track, c.fill, c.thumb, c.minus, c.plus, c.field and c.field.frame } or { c }
    for _, part in parts do
        if part then
            if shown then part:Show() else part:Hide() end
        end
    end
end

-- the emitter's numeric settings: key, label, min, max, step, format
local NUMBERS = {
    { 'lifetime', 'Lifetime (ticks, -1 = for ever)', -1, 600, 1, '%d' },
    { 'repeatTime', 'Repeat time (ticks)', 1, 600, 1, '%d' },
    { 'textureFrameCount', 'Texture frames', 1, 64, 1, '%d' },
    { 'textureStripCount', 'Texture strips', 1, 64, 1, '%d' },
    { 'lodCutoff', 'LOD cutoff', 0, 1000, 5, '%d' },
    { 'sortOrder', 'Sort order', -20, 20, 1, '%d' },
}

local FLAG_LABELS = {
    LocalVelocity = 'Local velocity', LocalAcceleration = 'Local acceleration', Gravity = 'Gravity', AlignRotation = 'Align rotation', AlignToBone = 'Align to bone',
    Flat = 'Flat', EmitIfVisible = 'Emit if visible', CatchupEmit = 'Catch-up emit', CreateIfVisible = 'Create if visible', SnapToWaterline = 'Snap to waterline',
    OnlyEmitOnWater = 'Only emit on water', ParticleResistance = 'Particle resistance', InterpolateEmission = 'Interpolate emission',
}

local function Fmt(v)
    if v == math.floor(v) then return string.format('%d', v) end
    return string.format('%.2f', v)
end

Panels.Register{
    id = 'particles', title = 'Particle editor',
    stack = { workspace = 'Mod', with = 'effects' },
    minW = 260,
    create = function(group, host)
        local P = { tab = 'curves', curve = 1, sel = 1, dest = 1, rev = -1, w = 300, h = 400 }
        live.particles = P
        local info = Fx.Info()

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        -- ---- the file row ----------------------------------------------------------------------------------------------------------------------------
        P.bNewE = Btn('New emitter', 84, function() Fx.New('emitter') P:Refresh() end)
        P.bNewB = Btn('New beam', 70, function() Fx.New('beam') P:Refresh() end)
        P.bNewT = Btn('New trail', 66, function() Fx.New('trail') P:Refresh() end)
        P.bUndo = Btn('Undo', 46, function() Fx.Undo() P:Refresh() end)
        P.bRedo = Btn('Redo', 46, function() Fx.Redo() P:Refresh() end)
        P.nameLabel = W.Label(group, 'File', 0, 0, { color = Skin.color.textDim })
        P.name = W.TextField(group, 0, 0, 100, Skin.S(22), { onEnter = function(text) Fx.SetName(text) P:Refresh() end })
        P.bDest = Btn('', 150, function()
            local list = Fx.Destinations()
            if table.getn(list) > 0 then P.dest = math.mod(P.dest, table.getn(list)) + 1 end
            P:Refresh()
        end, { tip = 'Where Write file puts the file: the open map or a mod project. Click for the next place.' })
        P.bWrite = Btn('Write file', 74, function()
            local list = Fx.Destinations()
            local d = list[P.dest] or list[1]
            if not d then Say('particles: open a mod project in the Unit lab, or save the map first') return end
            local path, why = Fx.Save(d.id)
            Say(path and ('particles: wrote ' .. path) or ('particles: ' .. tostring(why)))
            P:Refresh()
        end)
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        -- ---- tabs ------------------------------------------------------------------------------------------------------------------------------------
        P.bCurves = Btn('Curves', 60, function() P.tab = 'curves' P:OnResize(P.w, P.h) end)
        P.bSettings = Btn('Settings', 64, function() P.tab = 'settings' P:OnResize(P.w, P.h) end)
        P.bFlat = Btn('Beam / trail', 80, function() P.tab = 'flat' P:OnResize(P.w, P.h) end)

        -- ---- curves ----------------------------------------------------------------------------------------------------------------------------------
        local groupOf = {}
        do
            local current = ''
            for i, c in info.curves do
                if c.group ~= '' then current = c.group end
                groupOf[i] = current
            end
        end
        P.clist = W.VirtualList(group, {
            extra = true, rowH = 18,
            getCount = function() return Fx.Emitter and table.getn(info.curves) or 0 end,
            bind = function(row, index)
                local c = Skin.color
                local ci = info.curves[index]
                local curve = Fx.Curve(index)
                if not ci or not curve then return end
                local label = ci.caption
                W.Fit(row.text, label, math.max(Skin.S(30), row.bg.Width() - Skin.S(90)))
                row.text:SetColor(index == P.curve and c.accent or c.text)
                local n = table.getn(curve.keys)
                local plain = n == 1 and curve.keys[1].y == ci.initialValue and curve.keys[1].z == ci.initialSpread
                row.extra:SetText(n .. (n == 1 and ' key' or ' keys'))
                row.extra:SetColor(plain and c.textDim or c.warn)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index) P.curve, P.sel = index, 1 P:Refresh() end,
            bgColor = Skin.color.panel,
        })

        local function Keys() local cv = Fx.Curve(P.curve) return cv and cv.keys or {} end
        local function RangeOf()
            local ci = info.curves[P.curve]
            local lo, hi = ci and ci.viewMin or 0, ci and ci.viewMax or 1
            for _, k in Keys() do
                lo = math.min(lo, k.y - k.z * 0.5)
                hi = math.max(hi, k.y + k.z * 0.5)
            end
            if hi - lo < 1e-3 then hi = lo + 1 end
            local pad = (hi - lo) * 0.06
            return lo - pad, hi + pad
        end
        local function PlotSet(list)
            local cv = Fx.Curve(P.curve)
            if not cv then return end
            local old = cv.keys
            local keys = {}
            local added = table.getn(list) - table.getn(old)
            local at = 0
            if added == 1 then
                -- the plot inserted one: the first place where the times no longer line up
                at = table.getn(list)
                for i, k in old do
                    if math.abs(list[i][1] * cv.xRange - k.x) > 1e-3 or math.abs(list[i][2] - k.y) > 1e-3 then at = i break end
                end
            end
            for i, p in list do
                local z = 0
                if added == 0 then z = old[i] and old[i].z or 0
                elseif added == 1 then
                    if i < at then z = old[i] and old[i].z or 0 elseif i > at then z = old[i - 1] and old[i - 1].z or 0 end
                else
                    -- one deleted: the plot lists the keys that are left, in order; the deleted one is the first that differs
                    local gone = table.getn(old)
                    for j, k in old do
                        if not list[j] or math.abs(list[j][1] * cv.xRange - k.x) > 1e-3 then gone = j break end
                    end
                    local src = i < gone and i or i + 1
                    z = old[src] and old[src].z or 0
                end
                keys[i] = { x = p[1] * cv.xRange, y = p[2], z = z }
            end
            Fx.SetKeys(P.curve, keys)
            P.sel = math.max(1, math.min(P.sel, table.getn(keys)))
        end
        P.plotSet = PlotSet
        P.plot = CurveWidget.Curve(group, {
            leftText = ' ', rightText = 'time', fixedLabels = true, freeEnds = true,
            get = function()
                local cv = Fx.Curve(P.curve)
                local points = {}
                if cv then
                    for i, k in cv.keys do points[i] = { cv.xRange > 0 and k.x / cv.xRange or 0, k.y } end
                end
                return points, false, false
            end,
            set = PlotSet,
            onDragEnd = function() P:Refresh() end,
            range = RangeOf,
            sample = function(n)
                local cv = Fx.Curve(P.curve)
                local s = cv and ed_fx_curve_samples(cv.keys, cv.xRange, n)
                return s and s.mid or nil
            end,
            band = function(n)
                local cv = Fx.Curve(P.curve)
                local s = cv and ed_fx_curve_samples(cv.keys, cv.xRange, n)
                if not s then return nil end
                for _, k in cv.keys do
                    if k.z > 0 then return s.lo, s.hi end
                end
                return nil
            end,
            refs = function()
                local lo, hi = RangeOf()
                return { { 0, '0' }, { hi, Fmt(math.floor(hi * 100 + 0.5) / 100) }, { lo, Fmt(math.floor(lo * 100 + 0.5) / 100) } }
            end,
            selected = function() return P.sel end,
            onSelect = function(index) P.sel = index P:Refresh() end,
        })
        P.rangeSlider = W.Slider(group, { label = 'Curve length (ticks)', min = 1, max = 600, step = 1, fmt = '%d',
            get = function() local cv = Fx.Curve(P.curve) return cv and cv.xRange or 1 end,
            set = function(v) Fx.SetRange(P.curve, v) P:Refresh() end })
        P.keyTime = W.Slider(group, { label = 'Key time', min = 0, max = 1, step = 0.01, fmt = '%.2f',
            get = function() local k = Keys()[P.sel] return k and k.x or 0 end,
            set = function(v) P.sel = Fx.SetKey(P.curve, P.sel, v, nil, nil) P:Refresh() end })
        P.keyValue = W.Slider(group, { label = 'Key value', min = -1, max = 1, step = 0.01, fmt = '%.2f',
            get = function() local k = Keys()[P.sel] return k and k.y or 0 end,
            set = function(v) Fx.SetKey(P.curve, P.sel, nil, v, nil) P:Refresh() end })
        P.keySpread = W.Slider(group, { label = 'Key spread (random +-half)', min = 0, max = 1, step = 0.01, fmt = '%.2f',
            get = function() local k = Keys()[P.sel] return k and k.z or 0 end,
            set = function(v) Fx.SetKey(P.curve, P.sel, nil, nil, v) P:Refresh() end })
        P.bAddKey = Btn('Add key', 64, function()
            local cv = Fx.Curve(P.curve)
            if not cv then return end
            local k = Keys()[P.sel]
            local x = k and math.min(cv.xRange, k.x + cv.xRange * 0.1) or 0
            P.sel = Fx.AddKey(P.curve, x) or P.sel
            P:Refresh()
        end)
        P.bDelKey = Btn('Delete key', 76, function()
            if Fx.RemoveKey(P.curve, P.sel) then P.sel = math.max(1, P.sel - 1) end
            P:Refresh()
        end)
        P.bResetCurve = Btn('Reset curve', 80, function()
            local ci = info.curves[P.curve]
            if ci then
                Fx.SetKeys(P.curve, { { x = 0, y = ci.initialValue, z = ci.initialSpread } })
                P.sel = 1
            end
            P:Refresh()
        end)

        -- ---- settings --------------------------------------------------------------------------------------------------------------------------------
        P.numbers = {}
        for i, n in NUMBERS do
            local key = n[1]
            P.numbers[i] = W.Slider(group, { label = n[2], min = n[3], max = n[4], step = n[5], fmt = n[6],
                get = function() return Fx.Emitter and Fx.Emitter[key] or 0 end,
                set = function(v) Fx.SetNumber(key, v) P:Refresh() end })
        end
        P.blend = W.Slider(group, { label = 'Blend mode', min = 0, max = 5, step = 1, fmt = '%d',
            get = function() return Fx.Emitter and Fx.Emitter.blendMode or 0 end,
            set = function(v) Fx.SetNumber('blendMode', v) P:Refresh() end })
        P.blendName = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.flags = {}
        for i, name in info.flags do
            local flag = name
            P.flags[i] = Btn(FLAG_LABELS[name] or name, 120, function()
                if Fx.Emitter then Fx.SetFlag(flag, not Fx.Emitter.flags[flag]) end
                P:Refresh()
            end, { toggle = true, tip = 'Switch ' .. (FLAG_LABELS[name] or name) .. ' of the emitter.' })
        end
        P.fidelity = {}
        for i, f in { { 'lowFidelity', 'Low' }, { 'medFidelity', 'Medium' }, { 'highFidelity', 'High' } } do
            local key = f[1]
            P.fidelity[i] = Btn(f[2] .. ' fidelity', 100, function()
                if Fx.Emitter then Fx.SetBool(key, not Fx.Emitter[key]) end
                P:Refresh()
            end, { toggle = true, tip = 'Whether the emitter exists at the ' .. string.lower(f[2]) .. ' graphics fidelity.' })
        end
        P.texLabel = W.Label(group, 'Texture', 0, 0, { color = Skin.color.textDim })
        P.tex = W.TextField(group, 0, 0, 100, Skin.S(22), { onEnter = function(text) Fx.SetText('texture', text) P:Refresh() end })
        P.rampLabel = W.Label(group, 'Ramp texture', 0, 0, { color = Skin.color.textDim })
        P.ramp = W.TextField(group, 0, 0, 100, Skin.S(22), { onEnter = function(text) Fx.SetText('rampTexture', text) P:Refresh() end })
        P.idLabel = W.Label(group, 'Blueprint id (kept as the file has it)', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.id = W.TextField(group, 0, 0, 100, Skin.S(22), { onEnter = function(text) Fx.SetText('blueprintId', text) P:Refresh() end })

        -- ---- beam / trail ----------------------------------------------------------------------------------------------------------------------------
        P.flatList = W.VirtualList(group, {
            extra = true, rowH = 18,
            getCount = function() return Fx.Flat and table.getn(Fx.FlatFields()) or 0 end,
            bind = function(row, index)
                local c = Skin.color
                local f = Fx.FlatFields()[index]
                if not f then return end
                local v = Fx.FlatField(f.key)
                W.Fit(row.text, f.key, math.max(Skin.S(30), row.bg.Width() - Skin.S(130)))
                row.text:SetColor(index == P.flatSel and c.accent or (v and c.warn or c.text))
                local shown
                if f.kind == 'number' then shown = Fmt(v and v.number or f.initial)
                elseif f.kind == 'bool' then shown = (v and v.flag or false) and 'true' or 'false'
                elseif f.kind == 'color' then
                    local col = v and v.color or f.color
                    shown = string.format('%.2f %.2f %.2f %.2f', col[1], col[2], col[3], col[4])
                else shown = string.gsub(v and v.text or '', '^.*/', '') end
                W.Fit(row.extra, shown, Skin.S(120), true)
                row.extra:SetColor(v and c.warn or c.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index) P.flatSel = index P:Refresh() end,
            bgColor = Skin.color.panel,
        })
        P.flatSel = 1
        P.flatValue = W.Slider(group, { label = 'Value', min = -100, max = 100, step = 0.01, fmt = '%.2f',
            get = function()
                local f = Fx.FlatFields()[P.flatSel]
                local v = f and Fx.FlatField(f.key)
                return v and v.number or (f and f.initial) or 0
            end,
            set = function(x)
                local f = Fx.FlatFields()[P.flatSel]
                if f and f.kind == 'number' then Fx.SetFlat(f.key, 'number', x) P:Refresh() end
            end })
        P.flatToggle = Btn('Toggle', 60, function()
            local f = Fx.FlatFields()[P.flatSel]
            if f and f.kind == 'bool' then
                local v = Fx.FlatField(f.key)
                Fx.SetFlat(f.key, 'bool', not (v and v.flag or false))
                P:Refresh()
            end
        end)
        P.flatText = W.TextField(group, 0, 0, 100, Skin.S(22), { onEnter = function(text)
            local f = Fx.FlatFields()[P.flatSel]
            if not f then return end
            if f.kind == 'text' then Fx.SetFlat(f.key, 'text', text)
            elseif f.kind == 'color' then
                local r, g, b, a = string.gfind(text, '([%-%d%.]+)[ ,]+([%-%d%.]+)[ ,]+([%-%d%.]+)[ ,]+([%-%d%.]+)')()
                if r then Fx.SetFlat(f.key, 'color', { tonumber(r), tonumber(g), tonumber(b), tonumber(a) }) end
            end
            P:Refresh()
        end })
        P.flatHelp = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        local function Tab()
            if not Fx.IsOpen() then return 'none' end
            if Fx.Kind == 'emitter' then return P.tab == 'settings' and 'settings' or 'curves' end
            return 'flat'
        end

        function P:Refresh()
            P.rev = Fx.Revision
            local tab = Tab()
            P.bCurves:SetOn(tab == 'curves')
            P.bSettings:SetOn(tab == 'settings')
            P.bFlat:SetOn(tab == 'flat')
            P.bUndo:SetOn(Fx.CanUndo())
            P.bRedo:SetOn(Fx.CanRedo())
            P.name:SetText(Fx.Name)
            local dests = Fx.Destinations()
            if P.dest > table.getn(dests) then P.dest = 1 end
            P.bDest:SetText(dests[P.dest] and dests[P.dest].label or 'no destination')
            local text = Fx.IsOpen() and ((Fx.Dirty and '* ' or '') .. Fx.FileName() .. '   ' .. Fx.Kind .. (Fx.Source ~= '' and ('   from ' .. Fx.Source) or '   new')) or 'No file open: New, or pick one in the Particle browser'
            W.Fit(P.status, text, P.w - Skin.S(16))
            if tab == 'curves' then
                P.clist:Refresh()
                local cv = Fx.Curve(P.curve)
                local keys = cv and cv.keys or {}
                if P.sel > table.getn(keys) then P.sel = table.getn(keys) end
                if P.sel < 1 then P.sel = 1 end
                local ci = info.curves[P.curve]
                local k = keys[P.sel]
                if cv and ci then
                    local span = ci.viewMax - ci.viewMin
                    for _, key in keys do span = math.max(span, math.abs(key.y) * 2) end
                    P.rangeSlider:Refresh()
                    P.keyTime:SetRange(0, cv.xRange, 0.01, '%.2f')
                    P.keyTime.label:SetText('Key time (key ' .. P.sel .. ' of ' .. table.getn(keys) .. ')')
                    P.keyValue:SetRange(math.min(ci.viewMin, -span), math.max(ci.viewMax, span), math.max(0.001, span / 1000), '%.2f')
                    P.keyValue.label:SetText('Key value: ' .. ci.caption .. ' (' .. (groupOf[P.curve] or '') .. ')')
                    P.keySpread:SetRange(0, math.max(1, span), math.max(0.001, span / 1000), '%.2f')
                    P.keyTime:Refresh() P.keyValue:Refresh() P.keySpread:Refresh()
                end
                P.plot:Refresh()
            elseif tab == 'settings' then
                for _, s in P.numbers do s:Refresh() end
                P.blend:Refresh()
                P.blendName:SetText(info.blendModes[(Fx.Emitter.blendMode or 0) + 1] or '')
                for i, name in info.flags do P.flags[i]:SetOn(Fx.Emitter.flags[name] and true or false) end
                for i, key in { 'lowFidelity', 'medFidelity', 'highFidelity' } do P.fidelity[i]:SetOn(Fx.Emitter[key] and true or false) end
                P.tex:SetText(Fx.Emitter.texture or '')
                P.ramp:SetText(Fx.Emitter.rampTexture or '')
                P.id:SetText(Fx.Emitter.blueprintId or '')
            elseif tab == 'flat' then
                P.flatList:Refresh()
                local f = Fx.FlatFields()[P.flatSel]
                if f then
                    P.flatHelp:SetText(f.help or '')
                    if f.kind == 'number' then
                        local v = Fx.FlatField(f.key)
                        local x = v and v.number or f.initial
                        P.flatValue:SetRange(math.min(-10, x * 2), math.max(10, x * 2, f.initial * 2), 0.01, '%.2f')
                        P.flatValue.label:SetText(f.key)
                        P.flatValue:Refresh()
                    elseif f.kind == 'text' or f.kind == 'color' then
                        local v = Fx.FlatField(f.key)
                        if f.kind == 'text' then P.flatText:SetText(v and v.text or '')
                        else
                            local col = v and v.color or f.color
                            P.flatText:SetText(string.format('%.2f %.2f %.2f %.2f', col[1], col[2], col[3], col[4]))
                        end
                    end
                end
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            local tab = Tab()
            local y = pad
            -- a row that wraps at a big UI scale pushes the next one down (W.Flow answers the bottom of its last row)
            y = W.Flow(group, { { P.bNewE, Skin.S(84) }, { P.bNewB, Skin.S(70) }, { P.bNewT, Skin.S(66) }, { P.bUndo, Skin.S(46) }, { P.bRedo, Skin.S(46) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)
            W.Place(P.nameLabel, group, pad, y + Skin.S(3))
            local nameW = math.max(Skin.S(60), w - 2 * pad - Skin.S(34))
            W.Place(P.name.frame, group, pad + Skin.S(34), y, nameW, Skin.S(22))
            P.name.Width:Set(nameW - 2)
            y = y + Skin.S(28)
            y = W.Flow(group, { { P.bDest, Skin.S(150) }, { P.bWrite, Skin.S(74) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            W.Place(P.status, group, pad, y)
            y = y + Skin.S(18)
            y = W.Flow(group, { { P.bCurves, Skin.S(60) }, { P.bSettings, Skin.S(64) }, { P.bFlat, Skin.S(80) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)

            local c, s, f = tab == 'curves', tab == 'settings', tab == 'flat'
            for _, l in { P.clist.root } do if c then l:Show() else l:Hide() end end
            for _, ctl in { P.rangeSlider, P.keyTime, P.keyValue, P.keySpread } do ShowControl(ctl, c) end
            for _, ctl in { P.bAddKey, P.bDelKey, P.bResetCurve } do ShowControl(ctl, c) end
            for _, ctl in P.numbers do ShowControl(ctl, s) end
            for _, ctl in { P.blend, P.blendName, P.texLabel, P.rampLabel, P.idLabel } do ShowControl(ctl, s) end
            for _, ctl in P.flags do ShowControl(ctl, s) end
            for _, ctl in P.fidelity do ShowControl(ctl, s) end
            for _, fld in { P.tex, P.ramp, P.id } do ShowControl(fld.frame, s) end
            P.flatList.root:Hide()
            if f then P.flatList.root:Show() end
            for _, ctl in { P.flatValue, P.flatToggle, P.flatHelp } do ShowControl(ctl, f) end
            ShowControl(P.flatText.frame, f)
            if tab == 'curves' then
                local lh = Skin.S(18) * 6 + Skin.S(4)
                P.clist:SetRect(pad, y, w - 2 * pad, lh)
                y = y + lh + Skin.S(6)
                local ph = math.max(Skin.S(120), math.min(Skin.S(220), math.floor((w - 2 * pad) * 0.6)))
                P.plot:Place(pad, y, w - 2 * pad, ph)
                y = y + ph + Skin.S(8)
                P.rangeSlider:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(50)
                P.keyTime:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(50)
                P.keyValue:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(50)
                P.keySpread:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(54)
                W.Flow(group, { { P.bAddKey, Skin.S(64) }, { P.bDelKey, Skin.S(76) }, { P.bResetCurve, Skin.S(80) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
            else
                P.plot:Place(-20000, -20000, 10, 10)
                P.clist:SetRect(-20000, -20000, 10, 10)
            end
            if tab == 'settings' then
                for _, sl in P.numbers do
                    sl:Place(pad, y, w - 2 * pad)
                    y = y + Skin.S(50)
                end
                P.blend:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(46)
                W.Place(P.blendName, group, pad, y)
                y = y + Skin.S(20)
                local cols = math.max(1, math.floor((w - 2 * pad) / Skin.S(124)))
                local bw = math.floor((w - 2 * pad - (cols - 1) * Skin.S(4)) / cols)
                for i, b in P.flags do
                    local col, row = math.mod(i - 1, cols), math.floor((i - 1) / cols)
                    W.Place(b, group, pad + col * (bw + Skin.S(4)), y + row * Skin.S(26), bw, Skin.S(22))
                end
                y = y + math.ceil(table.getn(P.flags) / cols) * Skin.S(26) + Skin.S(6)
                for i, b in P.fidelity do
                    W.Place(b, group, pad + (i - 1) * (Skin.S(100) + Skin.S(4)), y, Skin.S(100), Skin.S(22))
                end
                y = y + Skin.S(30)
                W.Place(P.texLabel, group, pad, y)
                W.Place(P.tex.frame, group, pad, y + Skin.S(18), w - 2 * pad, Skin.S(22))
                P.tex.Width:Set(w - 2 * pad - 2)
                y = y + Skin.S(48)
                W.Place(P.rampLabel, group, pad, y)
                W.Place(P.ramp.frame, group, pad, y + Skin.S(18), w - 2 * pad, Skin.S(22))
                P.ramp.Width:Set(w - 2 * pad - 2)
                y = y + Skin.S(48)
                W.Place(P.idLabel, group, pad, y)
                W.Place(P.id.frame, group, pad, y + Skin.S(18), w - 2 * pad, Skin.S(22))
                P.id.Width:Set(w - 2 * pad - 2)
            else
                for _, sl in P.numbers do sl:Place(-20000, -20000, 10) end
                P.blend:Place(-20000, -20000, 10)
            end
            if tab == 'flat' then
                local lh = Skin.S(18) * 12 + Skin.S(4)
                P.flatList:SetRect(pad, y, w - 2 * pad, lh)
                y = y + lh + Skin.S(6)
                P.flatValue:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(50)
                W.Place(P.flatText.frame, group, pad, y, w - 2 * pad - Skin.S(66), Skin.S(22))
                P.flatText.Width:Set(w - 2 * pad - Skin.S(66) - 2)
                W.Place(P.flatToggle, group, w - pad - Skin.S(60), y, Skin.S(60), Skin.S(22))
                y = y + Skin.S(28)
                W.Place(P.flatHelp, group, pad, y)
            else
                P.flatList:SetRect(-20000, -20000, 10, 10)
            end
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: the panel follows the file when it was changed elsewhere (the browser opened another).
function Refresh()
    local P = live.particles
    if P and P.rev ~= Fx.Revision then pcall(P.Refresh, P) end
end
