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
--   Check(bp, x, z, heading, ctx)          -> ok, reason   the game's rules: inside the playable area, layer (land / water) against Physics.BuildOnLayerCaps or MotionType,
--                                             ground slope against Physics.MaxGroundVariation (structures) or the pathing limit (mobile units), skirts of structures overlapping
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

local function Height(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

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
    for _, u in Units().All() do
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

--- Can the blueprint stand at (x, z) with the heading? Returns true, or false and a short reason. The answer is an approximation of the game's own build check
--- (CanBuildStructureAt / the pathing footprint): good for colouring a preview, not a promise.
function Check(bp, x, z, heading, ctx)
    if not bp then return true, '' end
    ctx = ctx or Context()
    local foot, skirt = Rects(bp, x, z, heading)
    local area = skirt or foot
    if x < 0 or z < 0 or x > ctx.w or z > ctx.h or area[1] < -0.01 or area[2] < -0.01 or area[3] > ctx.w + 0.01 or area[4] > ctx.h + 0.01 then
        return false, 'outside the map'
    end
    local p = ctx.play
    if x < p[1] or z < p[2] or x > p[3] or z > p[4] then
        return false, 'outside the playable area'
    end
    local ph = bp.Physics or {}
    local structure = IsStructure(bp)

    -- layer: water against land
    local depthAt = function(px, pz)
        if not ctx.waterOn then return -1 end
        return ctx.waterElev - Height(px, pz)
    end
    if structure then
        local caps = Caps(bp)
        local dryOk = (not caps) or caps.LAYER_Land
        local wetOk = caps and (caps.LAYER_Water or caps.LAYER_Seabed)
        for _, pt in { { x, z }, { foot[1], foot[2] }, { foot[3], foot[2] }, { foot[1], foot[4] }, { foot[3], foot[4] } } do
            local d = depthAt(pt[1], pt[2])
            if d > 0 and not wetOk then return false, 'under water' end
            if d <= 0 and not dryOk then return false, 'needs water' end
        end
    else
        local mt = ph.MotionType
        local d = depthAt(x, z)
        if mt == 'RULEUMT_Land' or mt == 'RULEUMT_Biped' then
            if d > (ph.MaxWaterDepth or 1) then return false, 'too deep for a land unit' end
        elseif mt == 'RULEUMT_Water' or mt == 'RULEUMT_SurfacingSub' then
            if d < (ph.MinWaterDepth or 0.5) then return false, 'needs water' end
        end
    end

    -- slope: the engine's own measure (ed_slope_at), against the blueprint's limit
    if rawget(_G, 'ed_slope_at') then
        if structure then
            local limit = ph.MaxGroundVariation or 1.0
            if limit < 100 then
                local n = math.min(16, math.max(1, math.ceil(math.max(area[3] - area[1], area[4] - area[2]) - 0.001)))
                local v = ed_slope_at('build', area[1] + 0.001, area[2] + 0.001, n)
                if v and v > limit + 0.001 then
                    return false, string.format('ground too uneven (%.1f, the limit is %.1f)', v, limit)
                end
            end
        else
            local mt = ph.MotionType
            if mt == 'RULEUMT_Land' or mt == 'RULEUMT_Biped' or mt == 'RULEUMT_Amphibious' or mt == 'RULEUMT_AmphibiousFloating' or mt == 'RULEUMT_Hover' then
                local n = math.min(16, math.max(1, math.ceil(math.max(foot[3] - foot[1], foot[4] - foot[2]) - 0.001)))
                local v = ed_slope_at('path', foot[1] + 0.001, foot[2] + 0.001, n)
                if v and v > 0.75 then
                    return false, string.format('too steep to stand (%.2f, the limit is 0.75)', v)
                end
            end
        end
    end

    -- other structures
    if structure then
        if Near(ctx, area, function(r) return Overlap(area, r[1]) end) then return false, 'overlaps another structure' end
    else
        local probe = { x, z, x, z }
        if Near(ctx, probe, function(r)
            local f = r[2]
            return x > f[1] and x < f[3] and z > f[2] and z < f[4]
        end) then return false, 'inside a structure' end
    end
    return true, ''
end
