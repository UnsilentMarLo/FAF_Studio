-- Erosion suite front end (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3): solvers, parameters, presets, preview on the real terrain and Apply.
-- The solvers are native ops of the field engine (moho/editor/EdErosion.cpp): erode_hydraulic (pipe / shallow water grid model with sediment capacity, evaporation and thermal
-- coupling), erode_droplet (particle erosion) and erode_stream (stream power incision on a drainage network). Every run gives the new height and the masks wear, deposit, flow, water,
-- sediment (fields), computed in one go.
--
--   Solvers[name] = { op, label, params = { { key, label, min, max, step, fmt, default }, ... } }       the sliders of a solver
--   Presets = { { id, label, solver, values = {...} }, ... }                                           mountain, hills, canyon, alpine, desert, river valley
--   state                                                      the panel's choices: solver, values per solver, outputs
--   Run(solver, values, opts)       -> result { height, wear, deposit, flow, water, sediment, base } fields; opts: step (> 1 = a coarse run on every step-th sample), mask, seed
--   Free(result)
--   ShowPreview(result) / Revert()  puts a coarse result on the real terrain (upsampled difference, native undo step only) / takes it back
--   Apply(solver, values, opts)     full resolution run + commit: heights and, when chosen, masks to texture layers as ONE history entry
--   Masks(result)                   -> { wear = f, deposit = f, flow = f } normalised to 0..1
--
-- Settings every solver shares (see Shared() below): Hardness variation + feature size (hard and soft ground), Rain variation, Protect ridges, Keep height range, Largest change,
-- Keep volume, and per solver Downhill acceleration + Droplet variation (droplets), Flow jitter (stream), Seed (all). A key a node or a saved graph does not have simply takes the
-- `default` below (there is no separate value for old graphs: the editor is not in production, graphs saved with older defaults change their result). The defaults were tuned on purpose:
--   hydraulic   iterations 150 (was 200), rain 0.004 (0.006), dissolving 0.08 (0.12), settling 0.05 (0.06): a default run changes the ground moderately instead of filling the valleys and
--               smoothing the hills (the old defaults lowered the relief by a quarter on the test terrain)
--   droplet     2 droplets per cell (1), life 40 (30), 1 filter pass (2), downhill acceleration 1 (0: with the old rule droplets slowed down on slopes and dug almost nothing)
--   all         hardness variation 0.4, rain variation 0.5, protect ridges 0.5, keep height range on
-- The map edge: the solvers no longer pin the outer ring (edge = open in the native ops); the old behaviour left a wall of untouched ground at the map border (EdErosion.h).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Terrain = import('/lua/editor/terrain.lua')

--- A solver parameter. `default` is what a new node / the panel starts with, and what a node or graph without the key gets; `tip` is the tooltip.
local function P(key, label, min, max, step, fmt, default, tip) return { key = key, label = label, min = min, max = max, step = step, fmt = fmt, default = default, tip = tip } end

--- The settings every solver shares (they add variation and keep the terrain's character).
local function Shared()
    return {
        P('vary', 'Hardness variation', 0, 1, 0.05, '%.2f', 0.4, 'Hard and soft ground side by side: the erodibility follows a noise pattern, so the erosion is uneven instead of the same everywhere. 0 = uniform.'),
        P('vary_scale', 'Hardness feature size (units)', 8, 400, 2, '%d', 60, 'Size of the hard and soft patches, and of the rain variation, in map units.'),
        P('rain_vary', 'Rain variation', 0, 1, 0.05, '%.2f', 0.5, 'The water differs from place to place (wetter and drier patches), so channels and gullies come in different sizes. 0 = even rain.'),
        P('protect', 'Protect ridges', 0, 1, 0.05, '%.2f', 0.5, 'Ridges and summits are harder than the slopes: they keep their height and shape while the flanks are carved. 0 = no protection.'),
        P('keep_range', 'Keep height range (0 / 1)', 0, 1, 1, '%d', 1, '1 = the result is stretched so its lowest and highest ground match the input again (erosion no longer flattens the map overall).'),
        P('max_change', 'Largest change (units, 0 = off)', 0, 80, 0.5, '%.1f', 0, 'No sample moves further than this from the input height, up or down. 0 = unlimited.'),
        P('conserve', 'Keep volume', 0, 1, 0.05, '%.2f', 0, 'Puts the share of the removed material that left the map or was carried off back where sediment settles (valleys), so the terrain keeps its mass. 0 = off.'),
    }
end

local function Join(a, b)
    for _, p in b do table.insert(a, p) end
    return a
end

Solvers = {
    hydraulic = {
        op = 'erode_hydraulic', label = 'Hydraulic (grid)',
        params = {
            P('iterations', 'Iterations', 10, 2000, 10, '%d', 150),
            P('rain', 'Rain per step (units)', 0.0005, 0.05, 0.0005, '%.4f', 0.004),
            P('evaporation', 'Evaporation', 0.002, 0.15, 0.002, '%.3f', 0.02),
            P('gain', 'Water speed (pipe gain)', 0.01, 0.25, 0.01, '%.2f', 0.08),
            P('capacity', 'Sediment capacity', 0.05, 4, 0.05, '%.2f', 1),
            P('erosion', 'Dissolving rate', 0.01, 0.6, 0.01, '%.2f', 0.08),
            P('deposition', 'Settling rate', 0.01, 0.6, 0.01, '%.2f', 0.05),
            P('depth_max', 'Full capacity depth (units)', 0.01, 0.5, 0.01, '%.2f', 0.05),
            P('min_slope', 'Minimum slope', 0, 0.2, 0.005, '%.3f', 0.02),
            P('cut_limit', 'Cut limit (0 = off)', 0, 1, 0.05, '%.2f', 0.5),
            P('thermal', 'Thermal slides', 0, 1, 0.05, '%.2f', 0),
            P('talus', 'Talus (rise / run)', 0.1, 2, 0.05, '%.2f', 0.8),
            P('thermal_every', 'Slide every n steps', 1, 10, 1, '%d', 2),
            P('smooth', 'Cell noise filter', 0, 1, 0.05, '%.2f', 1),
            P('smooth_passes', 'Filter passes', 0, 4, 1, '%d', 1),
            P('seed', 'Seed', 0, 9999, 1, '%d', 1, 'The random seed of the hardness and rain variation.'),
        },
    },
    droplet = {
        op = 'erode_droplet', label = 'Droplets (particles)',
        params = {
            P('density', 'Droplets per cell', 0.05, 8, 0.05, '%.2f', 2),
            P('lifetime', 'Droplet life (steps)', 5, 120, 1, '%d', 40),
            P('inertia', 'Inertia', 0, 0.5, 0.01, '%.2f', 0.05),
            P('capacity', 'Sediment capacity', 0.5, 16, 0.25, '%.2f', 4),
            P('erode', 'Dissolving rate', 0.02, 1, 0.02, '%.2f', 0.3),
            P('deposit', 'Settling rate', 0.02, 1, 0.02, '%.2f', 0.3),
            P('evaporate', 'Evaporation', 0, 0.1, 0.005, '%.3f', 0.01),
            P('gravity', 'Gravity', 0.5, 16, 0.5, '%.1f', 4),
            P('radius', 'Erosion radius (cells)', 1, 6, 1, '%d', 3),
            P('min_slope', 'Minimum slope', 0, 0.2, 0.005, '%.3f', 0.01),
            P('drain_pits', 'Drain basins (0 = fill them)', 0, 1, 1, '%d', 1),
            P('thermal', 'Thermal slides', 0, 1, 0.05, '%.2f', 0),
            P('thermal_steps', 'Slide steps', 0, 50, 1, '%d', 0),
            P('talus', 'Talus (rise / run)', 0.1, 2, 0.05, '%.2f', 0.8),
            P('smooth', 'Cell noise filter', 0, 1, 0.05, '%.2f', 1),
            P('smooth_passes', 'Filter passes', 0, 4, 1, '%d', 1),
            P('seed', 'Seed', 0, 9999, 1, '%d', 1),
            P('accel', 'Downhill acceleration', 0, 1, 0.05, '%.2f', 1, 'How much a drop speeds up going downhill. 1 = like a real drop (fast on steep ground, so it digs there); 0 = the old rule, which slowed drops down on slopes so they dug almost nothing.'),
            P('drop_vary', 'Droplet variation', 0, 1, 0.05, '%.2f', 0.5, 'Every drop gets its own size, lifetime, inertia and load, so the gullies are no longer evenly spaced copies of each other. 0 = identical drops.'),
        },
    },
    stream = {
        op = 'erode_stream', label = 'Stream power (rivers)',
        params = {
            P('iterations', 'Iterations', 1, 60, 1, '%d', 10),
            P('k', 'Erodibility', 0.01, 4, 0.01, '%.2f', 0.5),
            P('m', 'Drainage exponent', 0.1, 1, 0.05, '%.2f', 0.5),
            P('area_min', 'Smallest river (catchment cells)', 1, 600, 1, '%d', 40),
            P('spread', 'Flow spreading (low = wide)', 0.3, 4, 0.1, '%.1f', 1),
            P('max_cut', 'Cut per step (share)', 0.05, 1, 0.05, '%.2f', 0.5),
            P('widen', 'Channel widening', 0, 6, 1, '%d', 1),
            P('diffusion', 'Hillslope diffusion', 0, 1, 0.05, '%.2f', 0.2),
            P('talus', 'Talus (rise / run)', 0.1, 2, 0.05, '%.2f', 0.7),
            P('uplift', 'Uplift per step (units)', 0, 2, 0.05, '%.2f', 0),
            P('seed', 'Seed', 0, 9999, 1, '%d', 1, 'The random seed of the flow jitter and the hardness and rain variation.'),
            P('jitter', 'Flow jitter', 0, 1.5, 0.05, '%.2f', 0.4, 'The water is routed over the ground plus a little smooth noise: rivers pick their own paths, branch and bend instead of running side by side straight down the slope. 0 = routed on the plain ground.'),
        },
    },
}
for _, name in { 'hydraulic', 'droplet', 'stream' } do Join(Solvers[name].params, Shared()) end

SolverOrder = { 'hydraulic', 'droplet', 'stream' }

--- The presets: the solver and the values that differ from its defaults.
Presets = {
    -- Values not listed are the solver's defaults (accel 1, drop_vary 0.5, vary 0.4, rain_vary 0.5, protect 0.5, keep_range 1, jitter 0.4). Each preset names the settings that give it its look.
    -- Mountain: tall ridges kept (protect), hard and soft rock side by side, every drop different; max_change stops the faster droplets (accel 1) from cutting the peaks down.
    { id = 'mountain', label = 'Mountain', solver = 'droplet', values = { density = 3, lifetime = 60, inertia = 0.3, capacity = 8, erode = 0.45, deposit = 0.15, gravity = 5, thermal = 0.4, thermal_steps = 3, talus = 0.9, vary = 0.55, protect = 0.7, drop_vary = 0.6, max_change = 25 } },
    -- Hills: soft, rounded; the defaults of the hydraulic solver with a little thermal slumping.
    { id = 'hills', label = 'Hills', solver = 'hydraulic', values = { deposition = 0.08, thermal = 0.3, talus = 0.6 } },
    -- Canyon: straight, deep gorges (low jitter) in a plateau whose rim stays (protect), rock layers of different hardness.
    { id = 'canyon', label = 'Canyon', solver = 'stream', values = { iterations = 14, k = 1.5, max_cut = 0.7, diffusion = 0.05, widen = 2, talus = 1.2, area_min = 40, jitter = 0.3, protect = 0.6, vary = 0.5 } },
    -- Alpine: sharp, strongly protected crests and long steep flanks with scree (thermal), the most varied of the droplet presets.
    { id = 'alpine', label = 'Alpine', solver = 'droplet', values = { density = 2.5, lifetime = 80, inertia = 0.2, capacity = 6, erode = 0.4, deposit = 0.05, gravity = 6, thermal = 0.6, thermal_steps = 6, talus = 0.7, vary = 0.6, protect = 0.8, drop_vary = 0.7, max_change = 30 } },
    -- Desert: dry, rare and patchy rain (flash floods), the ground mostly shaped by slides (thermal every step) and wind-worn mesa rims.
    { id = 'desert', label = 'Desert', solver = 'hydraulic', values = { iterations = 120, rain = 0.002, evaporation = 0.05, capacity = 0.5, deposition = 0.2, thermal = 0.7, thermal_every = 1, talus = 0.35, vary = 0.3, rain_vary = 0.7, protect = 0.3 } },
    -- River valley: wandering rivers (more jitter) with wide soft banks.
    { id = 'river', label = 'River valley', solver = 'stream', values = { iterations = 20, k = 0.5, m = 0.5, diffusion = 0.3, widen = 2, area_min = 60, talus = 0.5, jitter = 0.5, vary = 0.3, protect = 0.3 } },
}

--- The panel's choices (module level: the controls come and go).
state = {
    solver = 'hydraulic',
    values = {},                 -- values[solver][key]
    preset = 'hills',
    masks = { wear = { on = false, layer = 1 }, deposit = { on = false, layer = 2 }, flow = { on = false, layer = 3 }, accum = { on = false, layer = 4 } },
    previewSize = 257,           -- the coarse run uses at most this many samples per side
    onTerrain = false,           -- show the preview on the real terrain
}

function Defaults(solver)
    local v = {}
    for _, p in Solvers[solver].params do v[p.key] = p.default end
    return v
end

function ValuesOf(solver)
    local store = state.values[solver]
    if not store then
        store = Defaults(solver)
        state.values[solver] = store
    end
    return store
end

--- Loads a preset into the panel values (the solver's other values go back to its defaults).
function UsePreset(id)
    for _, preset in Presets do
        if preset.id == id then
            state.solver = preset.solver
            state.preset = id
            local v = Defaults(preset.solver)
            for k, x in preset.values do v[k] = x end
            state.values[preset.solver] = v
            return true
        end
    end
    return false
end

UsePreset('hills')

-- ---- running -----------------------------------------------------------------------------------------------------------------------------------

--- The op parameters of `values` for a run on every `step`-th sample (cell = step). The coarse grid moves water and droplets `step` times farther per iteration, so the rules are
--- scaled to give the same result at lower cost (measured against the full resolution run: correlation of the height change 0.9 for hydraulic, 0.6 for droplets, 0.4 for rivers).
function OpParams(solver, values, step, seed)
    local p = {}
    for k, v in values do p[k] = v end
    step = step or 1
    if step > 1 then
        if solver == 'hydraulic' then
            p.iterations = math.max(10, math.floor(p.iterations / step + 0.5))
            p.rain = p.rain * step
            p.erosion = math.min(0.9, p.erosion * step)
            p.deposition = math.min(0.9, p.deposition * step)
        elseif solver == 'droplet' then
            p.lifetime = math.max(5, math.floor(p.lifetime / step + 0.5))
            p.radius = math.max(1, math.floor(p.radius / step + 0.5))
            p.density = math.max(0.05, p.density / (1.5 * step))
            p.thermal_steps = math.max(0, math.floor(p.thermal_steps / step + 0.5))
        end
        if solver ~= 'stream' then p.smooth_passes = (step >= 4) and 0 or math.max(0, p.smooth_passes - 1) end
    end
    if seed then p.seed = seed end
    return p
end

--- Runs a solver on the map heights. step 1 = full resolution. Returns a result table of fields (free it with Free).
function Run(solver, values, opts)
    opts = opts or {}
    local def = Solvers[solver]
    if not def then error('unknown erosion solver ' .. tostring(solver), 2) end
    local step = opts.step or 1
    local base = Fields.Height(step)
    local params = OpParams(solver, values or ValuesOf(solver), step, opts.seed)
    params.a = base
    if step > 1 or opts.noMasks then params.masks = 0 end      -- a preview needs no wear / deposit / flow
    if opts.mask then params.mask = opts.mask end
    local main, extra = ed_field_op_multi(def.op, params)
    if not main then
        Fields.Free(base)
        error(tostring(extra), 2)
    end
    local result = { height = main, base = base, step = step }
    for k, f in extra do
        if k == 'height' then Fields.Free(f) else result[k] = f end
    end
    return result
end

function Free(result)
    if not result then return end
    for _, f in { 'height', 'base', 'wear', 'deposit', 'flow', 'accum', 'water', 'sediment', 'upsampled' } do
        if result[f] then Fields.Free(result[f]) result[f] = nil end
    end
end

--- A mask field 0..1 from a raw accumulation: scaled to its mean + 3 sd, then a gamma curve. Returns a new field.
local function Normalised(f, gamma)
    local _, mx, mean, sd = Fields.Stats(f)
    local hi = mean + 3 * sd
    if hi <= 1e-9 then hi = math.max(mx, 1e-6) end
    local scaled = Fields.Op('affine', { a = f, mul = 1 / hi, add = 0 })
    local clamped = Fields.Op('clamp', { a = scaled, lo = 0, hi = 1 })
    Fields.Free(scaled)
    local out = Fields.Op('gamma', { a = clamped, gamma = gamma })
    Fields.Free(clamped)
    return out
end

--- The masks of a result as fields 0..1 (the caller frees them): wear, deposit, flow (discharge), accum (drainage accumulation: where rivers run).
function Masks(result)
    return {
        wear = Normalised(result.wear, 0.7),
        deposit = Normalised(result.deposit, 0.7),
        flow = Normalised(result.flow, 0.5),
        accum = Fields.Op('affine', { a = result.accum, mul = 1, add = 0 }),     -- drainage accumulation, already 0..1 (log scale)
    }
end

-- ---- preview on the real terrain ----------------------------------------------------------------------------------------------------------------

local shown = nil      -- { depth = undo depth after the preview was written, step }

--- The step of a coarse run: the smallest step that keeps the grid within `previewSize` samples.
function PreviewStep()
    local w, h = ed_terrain_info()
    local span = math.max(w, h) - 1
    local step = 1
    while math.floor(span / step) + 1 > state.previewSize do step = step + 1 end
    -- prefer a step that divides the map (the coarse grid then ends exactly on the last sample)
    for s = step, step + 3 do
        if math.mod(w - 1, s) == 0 and math.mod(h - 1, s) == 0 then return s end
    end
    return step
end

function IsShown()
    return shown ~= nil
end

--- Takes the preview off the terrain (when nothing else was edited since). Returns true when something was reverted.
function Revert()
    if not shown then return false end
    local info = shown
    shown = nil
    if Terrain.UndoDepth() == info.depth then
        Terrain.Undo()
        return true
    end
    return false      -- the user edited the terrain meanwhile: the preview stays as an ordinary edit
end

--- Writes the coarse `result` into the map as the upsampled difference to the untouched coarse heights (so the fine detail of the terrain stays). One native undo step, not in the history.
function ShowPreview(result)
    Revert()
    local w, h = ed_terrain_info()
    local diff = Fields.Op('sub', { a = result.height, b = result.base })
    local up = Fields.Op('resize', { a = diff, width = w, height = h })
    Fields.Free(diff)
    local full = Fields.Height(1)
    local sum = Fields.Op('add', { a = full, b = up })
    Fields.Free(full)
    Fields.Free(up)
    local depth = Terrain.UndoDepth()
    local changed = Fields.CommitHeight(sum, { label = 'Erosion preview', noHistory = true })
    Fields.Free(sum)
    if changed and changed > 0 then
        shown = { depth = Terrain.UndoDepth() }
    end
    return changed or 0
end

-- ---- apply -------------------------------------------------------------------------------------------------------------------------------------

--- Full resolution run and commit: heights and the chosen masks as ONE history entry. opts: seed, label, mask (erodibility field). Returns the samples changed, the entry.
function Apply(solver, values, opts)
    opts = opts or {}
    Revert()
    local result = Run(solver, values, { seed = opts.seed, mask = opts.mask })
    local masks = {}
    local made = nil
    local want = false
    for _, key in { 'wear', 'deposit', 'flow', 'accum' } do
        if state.masks[key].on then want = true end
    end
    if want then made = Masks(result) end
    if made then
        for _, key in { 'wear', 'deposit', 'flow', 'accum' } do
            local m = state.masks[key]
            if m.on then table.insert(masks, { layer = m.layer, field = made[key], opts = { label = 'Erosion ' .. key } }) end
        end
    end
    local changed, entry = Fields.Apply{ height = result.height, masks = masks, label = opts.label or 'Erosion' }
    if made then for _, f in made do Fields.Free(f) end end
    Free(result)
    return changed, entry
end

--- Frees what the panel may hold (a module reload or leaving the editor).
function Release()
    Revert()
end
