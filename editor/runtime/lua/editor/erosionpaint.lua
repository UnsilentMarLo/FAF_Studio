-- Erosion paint: the texture masks made from what the water did, the way a World Machine / Gaea project paints its map (docs/projects/editor/GRAPH_TEXTURING.md).
--
-- A hand made or noise made paint is random: patches and soft blobs that have nothing to do with the land. A project built on erosion reads the paint off the erosion itself:
--     wear     where the flow stripped the ground          -> bare rock, the strongest wear is a second kind of rock
--     deposit  where the sediment settled (flat, downstream) -> sand / dirt, the thick sediment is a second kind
--     flow     the drainage network (channels, tributaries)  -> wet or dark ground along the channels, the core of the channel is a second kind
--     slope, curvature, height above the surroundings         -> cliffs, cavities, ridge tops
-- Every mask is a threshold at a SHARE of the map (the 12 percent of the ground with the most wear ...), so it means the same on any map, with an edge as narrow as `edge` says (a share of the
-- mask's range: crisp, not a blur of tens of units). The kinds that have several layers (rock, dirt, wet, grass) are split by BANDS of those masks, not by noise: the second rock is where the wear
-- is strongest, the second dirt where the sediment is thickest, the second wet ground the channel core, the second grass the ridge tops.
--
--   Masks(S, H, given) -> { wear, deposit, flow }   0..1 fields on the grid of H; the given ones (imported from Gaea / World Machine, or made by an erosion node) are used as they are, a missing one is made
--                                                   from the heights (rockiness, topographic wetness, D8 drainage): a solver free stand-in
--   Override(S, c, sel, groups, k, given)           replaces the selections of rock, dirt and wet in `sel` (role -> field) by the erosion ones and adds the variants sel['rock#1'], sel['rock#2'],
--                                                   sel['dirt#1'], sel['wet#1'], sel['grass#1']: the share (0..1) of the kind's region that goes to its second, third ... layer
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

local function Mean(f) local _, _, m = Fields.Stats(f) return m end

--- The value that `share` of the cells lie above (bisection on the mask's range, ~14 cheap native passes).
function Above(S, f, share)
    local lo, hi = Fields.Stats(f)
    if hi <= lo then return hi end
    share = math.max(0.0005, math.min(0.9995, share))
    local a, b = lo, hi
    for _ = 1, 14 do
        local mid = (a + b) * 0.5
        if Mean(S:Op('threshold', { a = f, value = mid })) > share then a = mid else b = mid end
    end
    return (a + b) * 0.5
end

--- 1 above `t`, 0 below, with an edge of +- `w` (in the units of the mask).
local function Band(S, f, t, w, sharpen)
    local m = S:Op('smoothstep', { a = f, edge0 = t - w, edge1 = t + w })
    -- an erosion mask is a smooth gradient (and an imported one has often a lower resolution than the map): a threshold of it keeps a wide transition. Each extra pass squeezes the transition
    -- to a third of its width, so the edge of a band is where the mask crosses the threshold, not a blur around it.
    for _ = 1, (sharpen or 2) do m = S:Op('smoothstep', { a = m, edge0 = 0.3, edge1 = 0.7 }) end
    return m
end

local function Norm(S, f)
    return S:Op('normalize', { a = f, lo = 0, hi = 1 })
end

--- The three erosion masks on the grid of H.
function Masks(S, H, given)
    given = given or {}
    local m = {}
    local function Fit(f) return f and S:Op('resample', { a = f, like = H }) or nil end
    m.flow = Fit(given.flow)
    if not m.flow then
        local ok, f = pcall(function() return S:Op('flow', { a = H }) end)
        if ok and f then m.flow = Norm(S, f) end
    end
    m.wear = Fit(given.wear)
    if not m.wear then
        local ok, f = pcall(function() return S:Op('rockiness', { a = H }) end)
        if ok and f then m.wear = Norm(S, f) end
    end
    m.deposit = Fit(given.deposit)
    if not m.deposit then
        local ok, f = pcall(function() return S:Op('wetness', { a = H }) end)
        if ok and f then
            local slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 })
            local flat = S:Op('invert', { a = S:Op('smoothstep', { a = slope, edge0 = 4, edge1 = 10 }), lo = 0, hi = 1 })
            m.deposit = Norm(S, S:Op('mul', { a = Norm(S, f), b = flat }))
        end
    end
    return m
end

--- Replaces the selections of rock, dirt and wet ground by the erosion ones and adds the bands for the kinds with several layers (see the header). k: the knobs (wear, sed, chan, edge, rock, cliff).
function Override(S, c, sel, groups, k, given)
    local H = c.H
    local m = Masks(S, H, given)
    local edge = k.edge or 0.04
    local slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 })
    local function BandAt(f, share)
        if not f then return nil end
        local lo, hi = Fields.Stats(f)
        return Band(S, f, Above(S, f, share), math.max(1e-4, (hi - lo) * edge), k.sharpen or 2)
    end
    local function Have(id) return groups[id] ~= nil end
    -- rock: the cliffs by slope, and the worn ground where it leans at all
    if Have('rock') then
        local cliff = S:Op('smoothstep', { a = slope, edge0 = k.rock or 28, edge1 = (k.cliff or 46) })
        local worn = BandAt(m.wear, k.wear or 0.12)
        local rock = cliff
        if worn then rock = S:Op('max', { a = cliff, b = S:Op('mul', { a = worn, b = S:Op('smoothstep', { a = slope, edge0 = 3, edge1 = 8 }) }) }) end
        sel.rock = rock
        local core = BandAt(m.wear, (k.wear or 0.12) * 0.35)
        if core then sel['rock#1'] = core end
        local curv = S:Op('curvature', { a = H, radius = 4, gain = 25 })
        sel['rock#2'] = S:Op('mul', { a = S:Op('smoothstep', { a = S:Op('invert', { a = curv, lo = 0, hi = 1 }), edge0 = 0.56, edge1 = 0.64 }), b = S:Op('smoothstep', { a = slope, edge0 = 10, edge1 = 20 }) })
    end
    -- dirt: where the sediment settled on flat ground
    if Have('dirt') then
        local dep = BandAt(m.deposit, k.sed or 0.22)
        if dep then
            local flat = S:Op('invert', { a = S:Op('smoothstep', { a = slope, edge0 = 6, edge1 = 12 }), lo = 0, hi = 1 })
            sel.dirt = S:Op('mul', { a = dep, b = flat })
            local thick = BandAt(m.deposit, (k.sed or 0.22) * 0.35)
            if thick then sel['dirt#1'] = thick end
        end
    end
    -- wet ground: the drainage network, its core as a second kind
    if Have('wet') then
        local chan = BandAt(m.flow, k.chan or 0.07)
        if chan then
            sel.wet = chan
            local core = BandAt(m.flow, (k.chan or 0.07) * 0.4)
            if core then sel['wet#1'] = core end
        end
    end
    -- the open ground: ridge tops (higher than their surroundings) as the second texture of the base kind
    local relief = S:Op('sub', { a = H, b = S:Op('blur', { a = H, radius = 24 }) })
    sel['grass#1'] = BandAt(relief, 0.2)
    return sel
end
