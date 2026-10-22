-- Where a unit blueprint stands and whether it fits there: the footprint and skirt rectangles at a position, the spacing two of them need, the build grid, and the
-- placement rules the game applies, as far as the editor can tell them from the blueprint and the live terrain (the preview of the Unit tool and of moving units colours
-- itself by the answer; placing is never refused because of it). Pure computation, nothing is drawn here.
--
--   Blueprint(id)                          -> the unit blueprint or nil
--   IsStructure(bp)                        -> true for a unit that stands still (Physics.MotionType RULEUMT_None)
--   Rects(bp, x, z, heading)               -> foot, skirt: { x0, z0, x1, z1 } of the footprint and of the skirt (nil when the blueprint has none); the footprint of a
--                                             structure turns with the heading in steps of 90 degrees (a 3 x 5 footprint turned a quarter is 5 x 3)
--   Spacing(bp)                            -> sx, sz: the distance two units of this blueprint need along x / z not to overlap (skirt, else footprint, else collision box)
--   Snap(bp, x, z, heading)                -> x, z on the build grid (structures: the footprint's corners on whole cells; mobile units: halves)
--   Context(skip)                          -> ctx for Check: water level, playable area and the structures of the map (skip: set of 'army|name' keys to leave out, the units being moved)
--   Check(bp, x, z, heading, ctx)          -> ok, reason, kind   the game's rules, ported from the engine (STIMap.cpp OCCUPY_Check): inside the map and the playable area; a structure's
--                                             ground (FlattenSkirt: the ring round the skirt against ceil(last sample), else highest minus lowest over the skirt, both against
--                                             Physics.MaxGroundVariation) and layer caps against the water; a mobile unit's footprint against the water depth and the steepest step
--                                             between neighbouring samples; skirts of structures overlapping. reason is a sentence with the numbers, kind one of 'map', 'area',
--                                             'water', 'slope', 'layer', 'overlap'
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local function Units() return import('/lua/editor/units.lua') end

--- The unit blueprint of an id (any case).
function Blueprint(id)
    if not id or not __blueprints then return nil end
    return __blueprints[id] or __blueprints[string.lower(id)]
end

function IsStructure(bp)
    return bp and bp.Physics and bp.Physics.MotionType == 'RULEUMT_None' and true or false
end

--- True when the heading turns a footprint a quarter (its x and z sizes swap).
local function Quarter(heading)
    return math.abs(math.sin(heading or 0)) > 0.7071
end

--- The footprint and the skirt as ground rectangles around (x, z) (unitview.FootprintRects: the skirt starts at the footprint's corner plus SkirtOffsetX / Z), turned by the heading.
function Rects(bp, x, z, heading)
    local fp = bp.Footprint or {}
    local ph = bp.Physics or {}
    local fx, fz = fp.SizeX or 1, fp.SizeZ or 1
    local sx, sz, ox, oz = ph.SkirtSizeX, ph.SkirtSizeZ, ph.SkirtOffsetX or 0, ph.SkirtOffsetZ or 0
    if Quarter(heading) then
        fx, fz = fz, fx
        sx, sz = sz, sx
        ox, oz = oz, ox
    end
    local foot = { x - fx / 2, z - fz / 2, x + fx / 2, z + fz / 2 }
    local skirt
    if sx and sz then
        local x0, z0 = foot[1] + ox, foot[2] + oz
        skirt = { x0, z0, x0 + sx, z0 + sz }
    end
    return foot, skirt
end

--- Spacing along x and z (in cells) that keeps two units of the blueprint from overlapping.
function Spacing(bp)
    if not bp then return 1, 1 end
    local fp = bp.Footprint or {}
    local ph = bp.Physics or {}
    if IsStructure(bp) then
        return math.max(1, fp.SizeX or 1, ph.SkirtSizeX or 0), math.max(1, fp.SizeZ or 1, ph.SkirtSizeZ or 0)
    end
    local s = math.max(1, math.ceil(math.max(bp.SizeX or 1, bp.SizeZ or 1, fp.SizeX or 1, fp.SizeZ or 1) + 0.25))
    return s, s
end

--- The build grid: the corners of a structure's footprint lie on whole cells, so an odd size is centred on a cell centre and an even size on a cell corner (per axis);
--- units that move freely snap to half a cell.
function Snap(bp, x, z, heading)
    if IsStructure(bp) then
        local foot = Rects(bp, 0, 0, heading)
        local w, d = foot[3] - foot[1], foot[4] - foot[2]
        local function One(v, size)
            if math.mod(math.floor(size + 0.5), 2) == 1 then return math.floor(v) + 0.5 end
            return math.floor(v + 0.5)
        end
        return One(x, w), One(z, d)
    end
    return math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
end

-- ---- the rules --------------------------------------------------------------------------------------------------------------------

local TILE = 32

--- What the checks need to know about the map: the water level, the playable area and the rectangles of the structures already there (skip: set of 'army|name' to leave out).
--- Reading every unit of the map is not cheap: callers keep the context for a few frames.
function Context(skip)
    local ctx = { rects = {}, waterOn = false, waterElev = 0 }
    local w = ed_world_get and ed_world_get()
    if w then
        ctx.waterOn = (w.water_on or 0) ~= 0
        ctx.waterElev = w.water_elev or 0
    end
    local mw, mh = ed_terrain_info()
    ctx.w, ctx.h = (mw or 257) - 1, (mh or 257) - 1
    local ok, x0, z0, x1, z1 = pcall(function() return import('/lua/editor/playable.lua').Get() end)
    if ok and x0 then ctx.play = { x0, z0, x1, z1 } else ctx.play = { 0, 0, ctx.w, ctx.h } end
    ctx.grid = {}
    local n = 0
    for _, u in Units().CachedAll() do
        local bp = Blueprint(u.bp)
        if bp and IsStructure(bp) and not (skip and skip[u.army .. '|' .. u.name]) then
            local foot, skirt = Rects(bp, u.x, u.z, u.heading)
            n = n + 1
            if n > 6000 then break end
            local r = { skirt or foot, foot }
            table.insert(ctx.rects, r)
            -- bucket by 32 x 32 unit tiles so a check looks at the neighbours only
            local a = r[1]
            for tx = math.floor(a[1] / TILE), math.floor(a[3] / TILE) do
                for tz = math.floor(a[2] / TILE), math.floor(a[4] / TILE) do
                    local key = tx * 4096 + tz
                    local list = ctx.grid[key]
                    if not list then list = {} ctx.grid[key] = list end
                    table.insert(list, r)
                end
            end
        end
    end
    return ctx
end

--- Calls Visit(r) for the structures whose bucket the rectangle touches (a structure can come up twice).
local function Near(ctx, a, Visit)
    for tx = math.floor(a[1] / TILE), math.floor(a[3] / TILE) do
        for tz = math.floor(a[2] / TILE), math.floor(a[4] / TILE) do
            local list = ctx.grid[tx * 4096 + tz]
            if list then
                for _, r in list do
                    if Visit(r) then return true end
                end
            end
        end
    end
    return false
end

local function Overlap(a, b)
    return math.min(a[3], b[3]) - math.max(a[1], b[1]) > 0.01 and math.min(a[4], b[4]) - math.max(a[2], b[2]) > 0.01
end

local function Caps(bp)
    return bp.Physics and bp.Physics.BuildOnLayerCaps
end

-- ---- terrain samples and layer rules (ports of the engine's own checks: STIMap.cpp OCCUPY_Check / OCCUPY_CheckAreaFlatness / OCCUPY_CheckEdgeFlatness / OCCUPY_MobileCheck) ----

--- The height of a height sample (world units); positions outside the field answer with the edge sample (CHeightField::GetHeightAt clamps).
local function Sample(ctx, x, z)
    if x < 0 then x = 0 elseif x > ctx.w then x = ctx.w end
    if z < 0 then z = 0 elseif z > ctx.h then z = ctx.h end
    return ed_terrain_get(x, z) or 0
end

--- Lowest and highest sample of the cells x0..x1 / z0..z1 (inclusive).
local function MinMax(ctx, x0, z0, x1, z1)
    local lo, hi = 1e30, -1e30
    for cz = z0, z1 do
        for cx = x0, x1 do
            local v = Sample(ctx, cx, cz)
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    return lo, hi
end

--- OCCUPY_CheckEdgeFlatness: only the ring one cell outside the rectangle is looked at, and the deviation is measured from ceil(the last sample read), the height the skirt is
--- levelled to when the structure goes up (FlattenSkirt structures: every ordinary building). Returns ok, lowest, highest, deviation.
local function EdgeFlat(ctx, x0, z0, x1, z1, limit)
    local lo, hi, last = 1e30, -1e30, 0
    for cx = x0 - 1, x1 + 1 do
        local a, b = Sample(ctx, cx, z0 - 1), Sample(ctx, cx, z1 + 1)
        last = b
        lo = math.min(lo, a, b)
        hi = math.max(hi, a, b)
    end
    for cz = z0, z1 do
        local a, b = Sample(ctx, x0 - 1, cz), Sample(ctx, x1 + 1, cz)
        last = b
        lo = math.min(lo, a, b)
        hi = math.max(hi, a, b)
    end
    local pivot = math.ceil(last)
    local dev = math.max(hi - pivot, pivot - lo)
    return limit >= dev, lo, hi, dev
end

--- The moving rules of a motion type, from lua/footprints.lua and the engine's footprint caps: caps (land, seabed, sub, water), the deepest water a land footprint may stand in,
--- the least water a water footprint needs, and the steepest step between neighbouring samples (nil: none checked). nil for units that are not checked against the ground.
local function MobileRules(mt, size)
    if mt == 'RULEUMT_Land' or mt == 'RULEUMT_Biped' then
        return { land = true, maxDepth = 0.05, minDepth = 0, slope = 0.75 }
    elseif mt == 'RULEUMT_Amphibious' then
        return { land = true, seabed = true, maxDepth = 25, minDepth = 0, slope = 0.75 }
    elseif mt == 'RULEUMT_Hover' or mt == 'RULEUMT_AmphibiousFloating' then
        if size <= 2 then return { land = true, water = true, maxDepth = 1, minDepth = 0.1, slope = 0.75 } end
        return { land = true, water = true, maxDepth = 5, minDepth = 0, slope = 0.75 }
    elseif mt == 'RULEUMT_Water' then
        return { water = true, maxDepth = 1e9, minDepth = (size == 3) and 0.25 or 1.5 }
    elseif mt == 'RULEUMT_SurfacingSub' then
        return { sub = true, water = true, maxDepth = 1e9, minDepth = 1.5 }
    end
    return nil
end

--- Round to the nearest whole number, halves to the even one (lrintf, as the engine finds the origin cell of a footprint).
local function Rint(v)
    local f = math.floor(v)
    local d = v - f
    if d < 0.5 then return f end
    if d > 0.5 then return f + 1 end
    if math.mod(f, 2) == 0 then return f end
    return f + 1
end

local function Fmt1(v) return string.format('%.1f', v) end

--- A structure: skirt inside the map, flatness (area or edge rule), layer caps against the water, in the engine's order. Returns true, or false, reason, kind.
local function CheckStructure(bp, ctx, area)
    local ph = bp.Physics or {}
    local limit = ph.MaxGroundVariation or 1.0
    -- the integer rectangle of samples the engine looks at (the skirt, truncated: positions are not negative here, the map edge was checked)
    local x0, z0, x1, z1 = math.floor(area[1]), math.floor(area[2]), math.floor(area[3]), math.floor(area[4])
    local flatOk, lo, hi, dev
    local edge = ph.FlattenSkirt and true or false
    if edge then
        flatOk, lo, hi, dev = EdgeFlat(ctx, x0, z0, x1, z1, limit)
    else
        lo, hi = MinMax(ctx, x0, z0, x1, z1)
        dev = hi - lo
        flatOk = limit >= dev
    end
    local caps = Caps(bp)
    local land, seabed, sub, water
    if caps then
        land, seabed, sub, water = caps.LAYER_Land, caps.LAYER_Seabed, caps.LAYER_Sub, caps.LAYER_Water
    else
        land = true
    end
    local wet0 = seabed or sub or water
    local wl = ctx.waterOn and ctx.waterElev or -10000
    local minDepth = (bp.Footprint and bp.Footprint.MinWaterDepth) or 0
    local flatBlock = not flatOk and (land or seabed)
    local landBlock = land and wl > lo
    local wetBlock = wet0 and hi > wl - minDepth
    if not flatOk then land, seabed = false, false end
    if wl > lo then land = false end
    if hi > wl - minDepth then seabed, sub, water = false, false, false end
    if land or seabed or sub or water then return true end
    local landOnly = (not caps) or (caps.LAYER_Land and not wet0)
    if landOnly then
        if landBlock then
            return false, 'under water (the water is at ' .. Fmt1(wl) .. ', the ground reaches down to ' .. Fmt1(lo) .. ')', 'water'
        end
    elseif wetBlock then
        if not ctx.waterOn then return false, 'needs water (this map has none)', 'water' end
        return false, 'water too shallow (the ground reaches up to ' .. Fmt1(hi) .. ', the water is at ' .. Fmt1(wl) .. ')', 'water'
    end
    if flatBlock then
        if edge then
            return false, string.format('ground around it too uneven (%.1f from the levelling height, the limit is %.1f)', dev, limit), 'slope'
        end
        return false, string.format('ground too uneven (%.1f across it, the limit is %.1f)', dev, limit), 'slope'
    end
    return false, 'neither the ground nor the water here fits its layer rules', 'layer'
end

--- A mobile unit (OCCUPY_MobileCheck): the footprint's samples against the water and the steepness of the ground. Returns true, or false, reason, kind.
local function CheckMobile(bp, x, z, ctx)
    local ph = bp.Physics or {}
    local fp = bp.Footprint or {}
    local sx, sz = math.max(1, math.floor((fp.SizeX or 1) + 0.5)), math.max(1, math.floor((fp.SizeZ or 1) + 0.5))
    local rules = MobileRules(ph.MotionType, math.max(sx, sz))
    if not rules then return true end
    local x0, z0 = Rint(x - sx / 2), Rint(z - sz / 2)
    local x1, z1 = x0 + sx, z0 + sz
    if x0 < 0 or z0 < 0 or x1 > ctx.w or z1 > ctx.h then return false, 'outside the map', 'map' end
    local lo, hi = MinMax(ctx, x0, z0, x1, z1)
    local wl = ctx.waterOn and ctx.waterElev or -10000
    local land, seabed, sub, water = rules.land, rules.seabed, rules.sub, rules.water
    local tooDeep = (wl - lo) > rules.maxDepth
    local tooShallow = rules.minDepth > (wl - hi)
    if tooShallow then seabed, sub, water = false, false, false end
    if tooDeep then land, seabed = false, false end
    local steep, maxStep = false, 0
    if (land or seabed) and rules.slope then
        for cz = z0, z1 do
            for cx = x0, x1 - 1 do maxStep = math.max(maxStep, math.abs(Sample(ctx, cx + 1, cz) - Sample(ctx, cx, cz))) end
        end
        for cx = x0, x1 do
            for cz = z0, z1 - 1 do maxStep = math.max(maxStep, math.abs(Sample(ctx, cx, cz + 1) - Sample(ctx, cx, cz))) end
        end
        if maxStep > rules.slope then
            steep = true
            land, seabed = false, false
        end
    end
    if land or seabed or sub or water then return true end
    if steep then
        return false, string.format('too steep to stand (a step of %.2f between neighbouring points, the limit is %.2f)', maxStep, rules.slope), 'slope'
    end
    if rules.land and tooDeep then
        return false, 'too deep for this unit (water ' .. string.format('%.2f', wl - lo) .. ' deep, the limit is ' .. string.format('%.2f', rules.maxDepth) .. ')', 'water'
    end
    if not ctx.waterOn then return false, 'needs water (this map has none)', 'water' end
    return false, 'water too shallow (' .. string.format('%.2f', wl - hi) .. ' deep, it needs ' .. string.format('%.2f', rules.minDepth) .. ')', 'water'
end

--- Can the blueprint stand at (x, z) with the heading? Returns true, '' or false, reason, kind (kind: 'map', 'area', 'water', 'slope', 'layer' or 'overlap'). The rules are the game's own
--- (see above); what the editor cannot see (props, trees, deposits, the terrain blocking map) is not part of the answer.
function Check(bp, x, z, heading, ctx)
    if not bp then return true, '' end
    ctx = ctx or Context()
    local foot, skirt = Rects(bp, x, z, heading)
    local area = skirt or foot
    if x < 0 or z < 0 or x > ctx.w or z > ctx.h or area[1] < -0.01 or area[2] < -0.01 or area[3] > ctx.w + 0.01 or area[4] > ctx.h + 0.01 then
        return false, 'outside the map', 'map'
    end
    local p = ctx.play
    if x < p[1] or z < p[2] or x > p[3] or z > p[4] then
        return false, 'outside the playable area', 'area'
    end
    local structure = IsStructure(bp)
    local ok, why, kind
    if structure then
        ok, why, kind = CheckStructure(bp, ctx, area)
    else
        ok, why, kind = CheckMobile(bp, x, z, ctx)
    end
    if not ok then return false, why, kind end

    -- other structures
    if structure then
        if Near(ctx, area, function(r) return Overlap(area, r[1]) end) then return false, 'overlaps another structure', 'overlap' end
    else
        local probe = { x, z, x, z }
        if Near(ctx, probe, function(r)
            local f = r[2]
            return x > f[1] and x < f[3] and z > f[2] and z < f[4]
        end) then return false, 'inside a structure', 'overlap' end
    end
    return true, ''
end
