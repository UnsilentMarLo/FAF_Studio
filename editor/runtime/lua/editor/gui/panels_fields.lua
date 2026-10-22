-- The Fields panel: a first debug front end of the native field engine (fields.lua, docs/projects/editor/TERRAIN_GEN_DESIGN.md stage T1).
--
-- GENERATE (top of the panel): the usual way to make terrain. A preset (Hills, Mountains, Badlands, Dunes, Plains detail, Rocks) makes a RELIEF, a zero-mean field whose largest rise or dip is
-- the chosen amplitude in world units, and mixes it into the heights that are there (fieldgen.lua): Blend (add, multiply, raise only, lower only, replace), Strength, an optional mask (whole map,
-- playable area, selected area, with a soft border), protected spots around start positions and resource markers, and a water level clamp. The picture shows the new terrain or the change, the
-- text below it says how much changes. Apply to terrain writes it as ONE undo step. The map is never replaced by a bare field.
--
-- FIELD OPERATIONS (below): a debug front end of the native field engine. A working field is shaped step by step: pick an op, set its sliders, Preview (live: every slider change re-runs the op on the current field and shows the result), Apply to make the result the
-- working field. Generators start a new field, filters work on the current one, binary ops (min, max, add, sub, mul, blend) combine it with the field before it. "Map heights" loads the terrain,
-- "Commit" writes the working field into the heights (one undo step), "To layer" into the paint mask of a texture layer (one undo step). Everything runs in the native engine; the thumbnail is a
-- down-sampled picture of the field.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Fields = import('/lua/editor/fields.lua')
local Gen = import('/lua/editor/fieldgen.lua')

live = {}

-- ---- the op table ---------------------------------------------------------------------------------------------------------------------------------

local function P(key, label, min, max, step, fmt, default) return { key = key, label = label, min = min, max = max, step = step, fmt = fmt, default = default } end

local SEED = P('seed', 'Seed', 0, 9999, 1, '%d', 1)
local function Noise(scale)
    return { SEED, P('scale', 'Feature size (units)', 2, 600, 2, '%d', scale or 120), P('octaves', 'Octaves', 1, 10, 1, '%d', 5),
             P('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5) }
end

--- kind: gen (starts a field), filter (works on the current one), binary (current + the one before), special.
OPS = {
    perlin = { kind = 'gen', params = Noise() },
    simplex = { kind = 'gen', params = Noise() },
    ridged = { kind = 'gen', params = Noise() },
    billow = { kind = 'gen', params = Noise() },
    fractal = { kind = 'gen', params = { SEED, P('scale', 'Feature size (units)', 2, 600, 2, '%d', 120), P('octaves', 'Octaves', 1, 12, 1, '%d', 8), P('finest', 'Smallest detail (units)', 0, 200, 1, '%d', 8),
                                        P('persistence', 'Persistence', 0.2, 0.9, 0.05, '%.2f', 0.5), P('warp', 'Warp (units)', 0, 300, 1, '%d', 0),
                                        P('slope_detail', 'Detail on slopes', -1, 1, 0.05, '%.2f', 0), P('sharpness', 'Ridge sharpness', 1, 5, 0.1, '%.1f', 2),
                                        P('modeIndex', 'Shape (1 rolling, 2 hills, 3 ridged)', 1, 3, 1, '%d', 1) } },
    voronoi = { kind = 'gen', params = { SEED, P('scale', 'Cell size (units)', 4, 400, 2, '%d', 60), P('jitter', 'Jitter', 0, 1, 0.05, '%.2f', 1) } },
    gradient = { kind = 'gen', params = { P('angle', 'Angle (deg)', 0, 360, 5, '%d', 0), P('lo', 'Start value', 0, 1, 0.05, '%.2f', 0), P('hi', 'End value', 0, 1, 0.05, '%.2f', 1) } },
    radial = { kind = 'gen', params = { P('radius', 'Radius (units)', 4, 6000, 4, '%d', 400) } },
    const = { kind = 'gen', params = { P('value', 'Value', 0, 300, 1, '%d', 30) } },
    white = { kind = 'gen', params = { SEED } },
    blur = { kind = 'filter', params = { P('radius', 'Sigma (units)', 0.5, 80, 0.5, '%.1f', 4) } },
    box = { kind = 'filter', params = { P('radius', 'Half width (units)', 1, 80, 1, '%d', 4) } },
    clamp = { kind = 'filter', params = { P('lo', 'Low', -100, 400, 1, '%d', 0), P('hi', 'High', -100, 400, 1, '%d', 1) } },
    invert = { kind = 'filter', params = { P('lo', 'Low', -100, 400, 1, '%d', 0), P('hi', 'High', -100, 400, 1, '%d', 1) } },
    abs = { kind = 'filter', params = {} },
    amplitude = { kind = 'filter', params = { P('amplitude', 'Amplitude (units)', 0, 200, 0.5, '%.1f', 20) } },
    gamma = { kind = 'filter', params = { P('gamma', 'Gamma', 0.2, 4, 0.05, '%.2f', 1.5) } },
    affine = { kind = 'filter', params = { P('mul', 'Multiply', -100, 300, 0.5, '%.1f', 40), P('add', 'Add', -100, 300, 1, '%d', 20) } },
    smoothstep = { kind = 'filter', params = { P('edge0', 'Edge 0', -100, 300, 0.05, '%.2f', 0.3), P('edge1', 'Edge 1', -100, 300, 0.05, '%.2f', 0.7) } },
    threshold = { kind = 'filter', params = { P('value', 'Threshold', -100, 300, 0.05, '%.2f', 0.5) } },
    normalize = { kind = 'filter', params = { P('lo', 'Lowest', -100, 300, 1, '%d', 0), P('hi', 'Highest', -100, 300, 1, '%d', 1) } },
    quantize = { kind = 'filter', params = { P('step', 'Step', 0.0078125, 10, 0.0078125, '%.3f', 1) } },
    remap = { kind = 'special', params = { P('mid', 'Mid point', 0.05, 0.95, 0.05, '%.2f', 0.5), P('bend', 'Bend', 0, 1, 0.05, '%.2f', 0.2) } },
    levels = { kind = 'filter', params = { P('in_lo', 'In low', -100, 300, 0.05, '%.2f', 0.2), P('in_hi', 'In high', -100, 300, 0.05, '%.2f', 0.8),
                                          P('gamma', 'Gamma', 0.2, 4, 0.05, '%.2f', 1), P('out_lo', 'Out low', -100, 300, 0.05, '%.2f', 0), P('out_hi', 'Out high', -100, 300, 0.05, '%.2f', 1) } },
    terrace = { kind = 'filter', params = { P('steps', 'Steps', 1, 30, 1, '%d', 6), P('sharpness', 'Sharpness', 0, 1, 0.05, '%.2f', 0.7),
                                           P('lo', 'Low', -100, 400, 1, '%d', 0), P('hi', 'High', -100, 400, 1, '%d', 1) } },
    warp = { kind = 'special', params = { P('strength', 'Strength (units)', 1, 200, 1, '%d', 30), P('scale', 'Noise size (units)', 5, 400, 5, '%d', 80), SEED } },
    offset = { kind = 'filter', params = { P('move_x', 'Move x (units)', -2000, 2000, 1, '%d', 50), P('move_z', 'Move z (units)', -2000, 2000, 1, '%d', 0) } },
    rotate = { kind = 'filter', params = { P('angle', 'Angle (deg)', -180, 180, 1, '%d', 30) } },
    scale = { kind = 'filter', params = { P('factor', 'Zoom', 0.25, 4, 0.05, '%.2f', 1.5) } },
    mirror = { kind = 'filter', params = { P('modeIndex', 'Mode (x z xz rot2 rot4 diag adiag)', 1, 7, 1, '%d', 3), P('side', 'Side', 0, 1, 1, '%d', 0) } },
    min = { kind = 'binary', params = {} },
    max = { kind = 'binary', params = {} },
    add = { kind = 'binary', params = {} },
    sub = { kind = 'binary', params = {} },
    mul = { kind = 'binary', params = {} },
    blend = { kind = 'binary', params = { P('opacity', 'Opacity', 0, 1, 0.05, '%.2f', 0.5) } },
    slope = { kind = 'filter', params = { P('modeIndex', 'Mode (1 degrees, 2 gradient, 3 rating, 4 variation)', 1, 4, 1, '%d', 1), P('window', 'Window (samples)', 1, 12, 1, '%d', 1) } },
    height_band = { kind = 'filter', params = { P('lo', 'Low', -100, 400, 1, '%d', 20), P('hi', 'High', -100, 400, 1, '%d', 40), P('soft', 'Soft edge', 0, 100, 1, '%d', 6) } },
    curvature = { kind = 'filter', params = { P('radius', 'Radius (samples)', 1, 16, 1, '%d', 2), P('gain', 'Gain', 1, 200, 1, '%d', 20) } },
    water_below = { kind = 'filter', params = { P('level', 'Water level', -100, 300, 0.5, '%.1f', 25), P('soft', 'Soft edge', 0, 50, 0.5, '%.1f', 2) } },
    water_above = { kind = 'filter', params = { P('level', 'Water level', -100, 300, 0.5, '%.1f', 25), P('soft', 'Soft edge', 0, 50, 0.5, '%.1f', 2) } },
    water_depth = { kind = 'filter', params = { P('level', 'Water level', -100, 300, 0.5, '%.1f', 25) } },
    shore = { kind = 'filter', params = { P('level', 'Water level', -100, 300, 0.5, '%.1f', 25), P('width', 'Width', 0, 50, 0.5, '%.1f', 2), P('soft', 'Soft edge', 0, 50, 0.5, '%.1f', 2) } },
    distance = { kind = 'filter', params = { P('threshold', 'Threshold', -100, 400, 0.5, '%.1f', 0.5), P('range', 'Range (units, 0 = raw)', 0, 1000, 5, '%d', 100) } },
    thermal = { kind = 'filter', params = { P('iterations', 'Iterations', 1, 300, 1, '%d', 30), P('talus', 'Talus (rise / run)', 0.05, 2, 0.05, '%.2f', 0.6),
                                           P('rate', 'Rate', 0.05, 1, 0.05, '%.2f', 0.5) } },
    aspect = { kind = 'filter', params = { P('azimuth', 'Facing (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 225), P('flat', 'Level below (rise / run)', 0.005, 1, 0.005, '%.3f', 0.05) } },
    flow = { kind = 'filter', params = { P('range', 'Catchment that reads 1 (units squared)', 1000, 10000000, 1000, '%d', 1000000) } },
    crop = { kind = 'skip' }, resize = { kind = 'skip' }, resample = { kind = 'skip' },
}

local MODES = { 'x', 'z', 'xz', 'rot2', 'rot4', 'diag', 'adiag' }
local FRACTALS = { 'fbm', 'billow', 'ridged' }
local SLOPES = { 'degrees', 'gradient', 'rating', 'variation' }
local RAMPS = { 'terrain', 'grey', 'heat' }

-- ---- model (module level: the controls come and go) ------------------------------------------------------------------------------------------------

state = { op = 'perlin', values = {}, stack = {}, result = false, live = true, ramp = 1, layer = 1, text = '', lo = 0, hi = 1, serial = 0, confirmAt = -1 }

--- The Generate section: the last generated result (a native terrain field and the change), what the text line says, and which picture is shown.
gen = { result = false, text = '', showChange = false }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function ValueOf(op, p)
    local store = state.values[op]
    if not store then store = {} state.values[op] = store end
    if store[p.key] == nil then store[p.key] = p.default end
    return store[p.key]
end

local function Names()
    local list = {}
    for name, def in OPS do
        if def.kind ~= 'skip' then table.insert(list, name) end
    end
    table.sort(list)
    return list
end

local function Work() return state.stack[table.getn(state.stack)] end

local function Drop(f) if f then Fields.Free(f) end end

local function Params(op)
    local def = OPS[op]
    local params = {}
    for _, p in def.params do params[p.key] = ValueOf(op, p) end
    if op == 'mirror' then
        params.mode = MODES[math.floor(params.modeIndex + 0.5)]
        params.modeIndex = nil
    elseif op == 'slope' then
        params.mode = SLOPES[math.floor(params.modeIndex + 0.5)]
        params.modeIndex = nil
    elseif op == 'remap' then
        local mid = params.mid
        params.points = { 0, 0, mid, mid - params.bend * math.min(mid, 1 - mid), 1, 1 }
        params.smooth = 1
        params.mid, params.bend = nil, nil
    elseif op == 'warp' then
        params.scale, params.seed, params.strength = nil, nil, params.strength
    elseif op == 'fractal' then
        params.kind = FRACTALS[math.floor(params.modeIndex + 0.5)]
        params.modeIndex = nil
    elseif op == 'amplitude' then
        params.mode = 'peak'
    elseif op == 'perlin' or op == 'simplex' or op == 'ridged' or op == 'billow' then
        params.rotate = 1          -- every octave in its own frame: no lattice seams (EdFieldCore.h OctaveFrame)
    end
    return params
end

--- Runs the selected op on the current field; the result (a new field, not yet applied) is kept for the preview.
local function Evaluate()
    local op = state.op
    local def = OPS[op]
    Drop(state.result)
    state.result = false
    local work = Work()
    local params = Params(op)
    local f, err
    if def.kind == 'gen' then
        local w, h = ed_terrain_info()
        if not params.width and work then params.like = work end
        f, err = Fields.TryOp(op, params)
    elseif not work then
        state.text = op .. ' needs a field: load the map heights or apply a generator first'
        return false
    elseif def.kind == 'binary' then
        local before = state.stack[table.getn(state.stack) - 1]
        if not before then
            state.text = op .. ' combines the field with the one before it: apply a second one first'
            return false
        end
        params.a, params.b = before, work
        f, err = Fields.TryOp(op, params)
    elseif op == 'warp' then
        local s = Params(op)
        local nz = ValueOf(op, OPS.warp.params[2])
        local seed = ValueOf(op, OPS.warp.params[3])
        local dx = Fields.TryOp('perlin', { like = work, seed = seed, scale = nz, octaves = 3, rotate = 1 })
        local dz = Fields.TryOp('perlin', { like = work, seed = seed + 1, scale = nz, octaves = 3, rotate = 1 })
        if dx and dz then f, err = Fields.TryOp('warp', { a = work, dx = dx, dz = dz, strength = s.strength }) else err = 'noise failed' end
        Drop(dx) Drop(dz)
    else
        params.a = work
        f, err = Fields.TryOp(op, params)
    end
    if not f then
        state.text = op .. ': ' .. tostring(err)
        return false
    end
    state.result = f
    return true
end

local function Ramp()
    return RAMPS[state.ramp]
end

local function Show(P)
    local f = state.result or Work()
    if not f then
        P.pic:Hide()
        P.info:SetText('no field')
        return
    end
    local path, lo, hi = Fields.Preview(f, 128, { ramp = Ramp() })
    if path then
        P.pic:SetTexture(path)
        P.pic:Show()
    end
    local mn, mx, mean, sd = Fields.Stats(f)
    local w, h, cell = Fields.Info(f)
    W.Fit(P.info, string.format('%s%dx%d  cell %g   min %.2f  max %.2f  mean %.2f', state.result and 'preview  ' or 'field  ', w, h, cell, mn, mx, mean), (P.w or 300) - Skin.S(16))
end

--- The Generate section's picture: the new terrain, or the change (red up, blue down).
local function ShowGen(P)
    local r = gen.result
    if not r then
        P.gpic:Hide()
        return
    end
    local f, opts = r.terrain, { ramp = 'terrain' }
    if gen.showChange then
        local m = math.max(0.01, r.stats.max)
        f, opts = r.change, { ramp = 'heat', lo = -m, hi = m }
    end
    local path = Fields.Preview(f, 128, opts)
    if path then
        P.gpic:SetTexture(path)
        P.gpic:Show()
    end
end

--- Makes the result of the Generate settings on the map as they are now (kept for the picture and for Apply to terrain).
local function GenEval()
    if gen.result then
        Gen.Free(gen.result)
        gen.result = false
    end
    local r, why = Gen.Build()
    if r then
        gen.result = r
        gen.text = ''
    else
        gen.text = tostring(why)
    end
    return r ~= nil
end

--- The three statistics lines under the picture.
local function GenLines()
    local r = gen.result
    if not r then return 'No preview yet', '', '' end
    local s = r.stats
    if s.max < 0.05 then return 'No change: nothing moves', 'by more than 0.05 units', '' end
    return string.format('Changes heights by up to %.1f units', s.max), string.format('on average %.1f units', s.mean), string.format('%d%% of the map moves', math.floor(s.share * 100 + 0.5))
end

Panels.Register{
    id = 'fields', title = 'Fields', minW = 240, minH = 200, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = {}
        live.fields = Pn
        Pn.group = group
        local c = Skin.color

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        Pn.pic = Bitmap(group)
        Pn.frame = Bitmap(group)
        Pn.frame:SetSolidColor(c.panelAlt)
        Pn.frame.Depth:Set(function() return group.Depth() + 4 end)
        Pn.pic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.pic:DisableHitTest()
        Pn.gpic = Bitmap(group)
        Pn.gframe = Bitmap(group)
        Pn.gframe:SetSolidColor(c.panelAlt)
        Pn.gframe.Depth:Set(function() return group.Depth() + 4 end)
        Pn.gpic.Depth:Set(function() return group.Depth() + 6 end)
        Pn.gpic:DisableHitTest()
        Pn.gpic:Hide()
        Pn.gHead = W.Label(group, 'Generate', 0, 0, { color = c.text })
        Pn.gLines = { W.Label(group, '', 0, 0, { color = c.text, size = 'small' }), W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' }),
                      W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' }) }
        Pn.gMsg = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.oHead = W.Label(group, 'Field operations (advanced)', 0, 0, { color = c.text })
        Pn.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.opLabel = W.Label(group, '', 0, 0, { color = c.text })
        Pn.sliders = {}

        local function Sync()
            state.serial = state.serial + 1
            Pn:Refresh()
            Show(Pn)
            ShowGen(Pn)
        end

        Pn.actions = {}
        Pn.actions.map = function()
            local ok, f = pcall(Fields.Height, 1)
            if not ok then state.text = 'map heights: ' .. tostring(f) Sync() return end
            Drop(state.result) state.result = false
            table.insert(state.stack, f)
            state.text = 'loaded the map heights'
            Sync()
        end
        Pn.bMap = Btn('Map heights', 84, function() Pn.actions.map() end)
        Pn.actions.apply = function()
            if not state.result and not Evaluate() then Sync() return end
            table.insert(state.stack, state.result)
            state.result = false
            while table.getn(state.stack) > 6 do Drop(table.remove(state.stack, 1)) end
            state.text = 'applied ' .. state.op
            Sync()
        end
        Pn.bApply = Btn('Apply', 54, function() Pn.actions.apply() end)
        Pn.actions.preview = function()
            Evaluate()
            Sync()
        end
        Pn.bPreview = Btn('Preview', 56, function() Pn.actions.preview() end)
        Pn.bBack = Btn('Back', 44, function()
            if state.result then
                Drop(state.result) state.result = false
            elseif table.getn(state.stack) > 0 then
                Drop(table.remove(state.stack))
            end
            state.text = 'stepped back'
            Sync()
        end)
        Pn.bClear = Btn('Clear', 44, function()
            Drop(state.result) state.result = false
            for _, f in state.stack do Drop(f) end
            state.stack = {}
            state.text = 'cleared'
            Sync()
        end)
        Pn.bLive = Btn('Live preview', 84, function(self)
            state.live = self.on
        end, { toggle = true })
        Pn.bLive:SetOn(state.live)
        Pn.bRamp = Btn('Colours: ' .. Ramp(), 100, function(self)
            state.ramp = math.mod(state.ramp, table.getn(RAMPS)) + 1
            self:SetText('Colours: ' .. Ramp())
            Sync()
        end)
        Pn.bCommit = Btn('Commit to heights', 110, function()
            local f = state.result or Work()
            if not f then Say('no field to commit') return end
            -- this REPLACES the heights of the whole map with the field (a generator field is 0..1: the map would become flat): ask once. Generate / Apply to terrain mixes instead.
            if state.confirmAt ~= state.serial then
                Sync()
                state.confirmAt = state.serial
                Pn.bCommit:SetOn(true)
                state.text = 'This replaces the heights of the whole map with the field. Click Commit to heights again to do it (Generate above mixes into the map instead).'
                Pn:Refresh()
                return
            end
            local n, err = Fields.CommitHeight(f, { label = 'Field to terrain' })
            state.text = n and (n .. ' samples changed') or ('commit failed: ' .. tostring(err))
            Say(state.text)
            Sync()
        end, { tip = 'Replaces the heights of the whole map with the working field (one undo step). Click twice: the first click only asks. To mix a generated relief into the map, use Generate (Apply to terrain) at the top.' })
        Pn.bMask = Btn('Commit to layer', 100, function()
            local f = state.result or Work()
            if not f then Say('no field to commit') return end
            local why = import('/lua/editor/strata.lua').WhyNotPaintable(state.layer)
            if why then state.text = 'mask not changed: ' .. why Say(state.text) Sync() return end
            local entry, n = Fields.CommitMask(f, state.layer, { label = 'Field to layer ' .. state.layer })
            state.text = entry and (n .. ' mask cells changed (layer ' .. state.layer .. ')') or ('mask not changed: ' .. tostring(n))
            Say(state.text)
            Sync()
        end)
        Pn.sLayer = W.Slider(group, { label = 'Texture layer', compact = true, min = 1, max = 8, step = 1, fmt = '%d',
            get = function() return state.layer end, set = function(v) state.layer = v end })

        -- ---- Generate -------------------------------------------------------------------------------------------------------------------------

        local GS = Gen.Settings

        --- A setting changed: with Live preview on the result is made again at once, otherwise the text says the picture is old.
        local function GenChanged()
            if state.live then
                GenEval()
            elseif gen.result then
                gen.text = 'Settings changed: press Refresh preview'
            end
            Sync()
        end

        Pn.gPresets = {}
        for _, def in Gen.Presets do
            local d = def
            local b = Btn(d.label, 7 * string.len(d.label) + 22, function()
                Gen.Choose(d.id)
                GenEval()
                Sync()
            end, { tip = d.tip })
            table.insert(Pn.gPresets, { def = d, button = b })
        end

        local function Next(list, value)
            for i, v in list do
                if v == value then return list[math.mod(i, table.getn(list)) + 1] end
            end
            return list[1]
        end
        local blendTip = 'How the generated relief meets the ground that is there (click to cycle).'
        for _, name in Gen.Blends do blendTip = blendTip .. '\n' .. Gen.BlendNames[name] .. ': ' .. Gen.BlendTips[name] end
        Pn.bBlend = Btn('Blend: Add', 138, function()
            GS.blend = Next(Gen.Blends, GS.blend)
            GenChanged()
        end, { tip = blendTip })
        Pn.bMaskSel = Btn('Mask: Whole map', 150, function()
            GS.mask = math.mod(GS.mask, table.getn(Gen.Masks)) + 1
            GenChanged()
        end, { tip = 'Where the generator may change the map (click to cycle). Whole map; the playable area; or the area that is selected in the editor. The border fades out over the mask border.' })
        Pn.bFlat = Btn('Keep flat areas', 106, function(self)
            GS.keepFlat = self.on
            GenChanged()
        end, { toggle = true })
        Pn.bWater = Btn('Keep water level', 116, function(self)
            GS.keepWater = self.on
            GenChanged()
        end, { toggle = true })
        Pn.bRandom = Btn('Random seed', 92, function()
            GS.seed = math.random(1, 9999)
            GenChanged()
        end)
        Pn.bRefresh = Btn('Refresh preview', 106, function()
            GenEval()
            Sync()
        end)
        Pn.bShowGen = Btn('Show: Terrain', 104, function()
            gen.showChange = not gen.showChange
            Sync()
        end)
        Pn.bGApply = Btn('Apply to terrain', 114, function()
            if not gen.result and not GenEval() then Say(gen.text) Sync() return end
            local n, err = Gen.Commit(gen.result)
            Gen.Free(gen.result)
            gen.result = false
            if n and n > 0 then
                gen.text = string.format('Applied: %d samples changed. Undo (Ctrl+Z) takes it back in one step.', n)
            elseif n then
                gen.text = 'Nothing changed'
            else
                gen.text = 'Not applied: ' .. tostring(err)
            end
            Say(gen.text)
            Sync()
        end)
        Pn.gSliders = {}
        local function GSlider(label, key, min, max, step, fmt)
            local s = W.Slider(group, { label = label, compact = true, min = min, max = max, step = step, fmt = fmt,
                get = function() return GS[key] end,
                set = function(v)
                    GS[key] = v
                    GenChanged()
                end })
            table.insert(Pn.gSliders, s)
        end
        GSlider('Amplitude (units)', 'amplitude', 0, 100, 0.5, '%.1f')
        GSlider('Strength', 'strength', 0, 1, 0.05, '%.2f')
        GSlider('Feature size (units)', 'scale', 10, 800, 5, '%d')
        GSlider('Detail', 'detail', 0, 1, 0.05, '%.2f')
        GSlider('Warp', 'warp', 0, 1, 0.05, '%.2f')
        GSlider('Gullies', 'gullies', 0, 1, 0.05, '%.2f')
        GSlider('Seed', 'seed', 0, 9999, 1, '%d')
        GSlider('Mask border (units)', 'feather', 0, 200, 2, '%d')
        GSlider('Flat radius (units)', 'flatRadius', 0, 120, 2, '%d')
        Pn.bFlat:SetOn(GS.keepFlat)
        Pn.bWater:SetOn(GS.keepWater)

        -- the op list
        Pn.list = W.VirtualList(group, {
            rowH = 18,
            getCount = function() return table.getn(Names()) end,
            bind = function(row, index)
                local name = Names()[index]
                W.Fit(row.text, name .. '  (' .. OPS[name].kind .. ')', math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(name == state.op and c.accent or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                state.op = Names()[index]
                Drop(state.result) state.result = false
                Pn:Build()
                Pn:OnResize(Pn.w, Pn.h)
                if state.live then Evaluate() end
                Sync()
            end,
        })

        --- Makes the sliders of the selected op.
        function Pn:Build()
            for _, s in self.sliders do
                for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
                s.field:Destroy()
                if s.field.frame then s.field.frame:Destroy() end
            end
            self.sliders = {}
            for _, p in OPS[state.op].params do
                local param = p
                local s = W.Slider(group, { label = param.label, compact = true, min = param.min, max = param.max, step = param.step, fmt = param.fmt,
                    get = function() return ValueOf(state.op, param) end,
                    set = function(v)
                        state.values[state.op][param.key] = v
                        if state.live then
                            Evaluate()
                            Sync()
                        end
                    end })
                table.insert(self.sliders, s)
            end
        end

        function Pn:Refresh()
            local work = Work()
            local text = string.gsub(tostring(state.text or ''), '[%c]+', ' ')      -- one line: an error text with line breaks must not make the label taller
            W.Fit(self.status, 'fields ' .. table.getn(state.stack) .. '   ' .. text, (self.w or 300) - Skin.S(16))
            W.Fit(self.opLabel, 'Op: ' .. state.op .. '  -  ' .. OPS[state.op].kind, (self.w or 300) - Skin.S(16))
            for _, s in self.sliders do s:Refresh() end
            self.sLayer:Refresh()
            self.bCommit:SetOn(state.confirmAt == state.serial)
            -- Generate
            local GS = Gen.Settings
            for _, s in self.gSliders do s:Refresh() end
            for _, e in self.gPresets do e.button:SetOn(e.def.id == GS.preset) end
            self.bBlend:SetText('Blend: ' .. Gen.BlendNames[GS.blend])
            self.bMaskSel:SetText('Mask: ' .. Gen.MaskNames[Gen.Masks[GS.mask]])
            self.bFlat:SetOn(GS.keepFlat)
            self.bWater:SetOn(GS.keepWater)
            self.bShowGen:SetText(gen.showChange and 'Show: Change' or 'Show: Terrain')
            local l1, l2, l3 = GenLines()
            local tw = (self.gTextW or 300)
            W.Fit(self.gLines[1], l1, tw)
            W.Fit(self.gLines[2], l2, tw)
            W.Fit(self.gLines[3], l3, tw)
            W.Fit(self.gMsg, string.gsub(tostring(gen.text or ''), '[%c]+', ' '), (self.w or 300) - Skin.S(16))
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            -- The scroll host only ever raises the content height it has seen (widgets.lua Extent): without this the height of the narrowest layout, or of the op with the most sliders, stayed
            -- after the panel got wider or another op was picked, and the panel scrolled on into empty space below the status line.
            W.BeginLayout(group)
            local pad = Skin.S(8)
            local rowH, gap = Skin.S(22), Skin.S(4)
            local y = pad
            local size = Skin.S(128)

            --- Sliders in as many columns as fit (at least 190 px each); returns the y below the last row.
            local function Columns(list, sx, sy, sw)
                local cols = math.max(1, math.floor((sw + pad) / (Skin.S(190) + pad)))
                local colW = math.floor((sw - (cols - 1) * pad) / cols)
                local rows = 0
                local i = 0
                for _, sl in list do
                    local col = math.mod(i, cols)
                    local row = math.floor(i / cols)
                    sl:Place(sx + col * (colW + pad), sy + row * Skin.S(46), colW)
                    rows = row + 1
                    i = i + 1
                end
                return sy + rows * Skin.S(46)
            end

            -- ---- Generate: picture and statistics, presets, choices, sliders ----
            W.Place(self.gHead, group, pad, y)
            y = y + Skin.S(22)
            W.Place(self.gframe, group, pad, y, size, size)
            W.Place(self.gpic, group, pad, y, size, size)
            local rx = size + 2 * pad
            local rw = w - rx - pad
            local statsY = y
            if rw < Skin.S(150) then
                -- narrow panel: the statistics and the buttons go below the picture
                rx, rw, statsY = pad, w - 2 * pad, y + size + gap
            end
            self.gTextW = math.max(Skin.S(60), rw)
            for i, label in self.gLines do
                W.Place(label, group, rx, statsY + (i - 1) * Skin.S(16))
            end
            local btnY = statsY + 3 * Skin.S(16) + gap
            local flowEnd = W.Flow(group, { { self.bRefresh, Skin.S(106) }, { self.bGApply, Skin.S(114) }, { self.bShowGen, Skin.S(104) } }, rx, btnY, rw, rowH, gap)
            y = math.max(flowEnd, rx == pad and flowEnd or (y + size)) + gap
            local items = {}
            for _, e in self.gPresets do table.insert(items, { e.button, e.button.Width() }) end
            y = W.Flow(group, items, pad, y, w - 2 * pad, rowH, gap) + gap
            y = W.Flow(group, { { self.bBlend, Skin.S(138) }, { self.bMaskSel, Skin.S(150) }, { self.bFlat, Skin.S(106) }, { self.bWater, Skin.S(116) }, { self.bRandom, Skin.S(92) } },
                pad, y, w - 2 * pad, rowH, gap) + gap
            y = Columns(self.gSliders, pad, y, w - 2 * pad)
            W.Place(self.gMsg, group, pad, y)
            y = y + Skin.S(26)

            -- ---- Field operations (the debug front end of the engine) ----
            W.Place(self.oHead, group, pad, y)
            y = y + Skin.S(24)
            -- buttons flow into as many rows as the width needs
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
            Flow({ self.bMap, self.bApply, self.bPreview, self.bBack, self.bClear, self.bLive, self.bRamp, self.bCommit, self.bMask })
            W.Place(self.frame, group, pad, y, size, size)
            W.Place(self.pic, group, pad, y, size, size)
            local wide = w >= Skin.S(620)
            local listW = wide and Skin.S(190) or math.max(Skin.S(80), w - size - 3 * pad)
            self.list:SetRect(size + 2 * pad, y, listW, size)
            local sx, sy, sw
            if wide then
                sx, sy, sw = size + listW + 3 * pad, y, w - (size + listW + 3 * pad) - pad
                W.Place(self.opLabel, group, sx, sy)
                sy = sy + Skin.S(22)
            else
                y = y + size + Skin.S(4)
                W.Place(self.opLabel, group, pad, y)
                y = y + Skin.S(22)
                sx, sy, sw = pad, y, w - 2 * pad
            end
            local all = {}
            for _, sl in self.sliders do table.insert(all, sl) end
            table.insert(all, self.sLayer)
            local below = Columns(all, sx, sy, sw)
            local top = wide and (y + size + Skin.S(4)) or below
            y = math.max(top, below)
            W.Place(self.info, group, pad, y)
            y = y + Skin.S(18)
            W.Place(self.status, group, pad, y)
            self:Refresh()
            W.EndLayout(group)
        end

        Pn:Build()
        return Pn
    end,
}

--- Frees the panel's fields (a module reload or leaving the editor).
function Release()
    Gen.Free(gen.result) gen.result = false
    Drop(state.result) state.result = false
    for _, f in state.stack do Drop(f) end
    state.stack = {}
end
