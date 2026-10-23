-- The slope view: the engine's own terrain ratings as a colour gradient over the ground (drawn natively, EdOverlay.cpp, from the live height
-- field with the same formulas the sim uses), so the mapper sees what slope does to gameplay. Details and data: docs/projects/editor/SLOPE_VIEW.md.
--
--   Kind 'path'   mobile units. A footprint of N x N cells may stand on a place when the steepest height difference between neighbouring height
--                 samples inside its window is at most MaxSlope (0.75 for every land, amphibious and hover footprint, lua/footprints.lua), in world
--                 units per cell. Bigger footprints look at a bigger window, so they are blocked by slopes the small ones cross.
--   Kind 'build'  structures, with two rules (Rule), both against the blueprint's Physics.MaxGroundVariation (1.0 for most structures and for every blueprint
--                 that does not say, 1.1 for 63 blueprints such as factories, 1.2 for 5; walls 50 and mass extractors / hydrocarbon plants 512 ignore slope):
--      'ring'     Physics.FlattenSkirt = true, nearly every building (OCCUPY_CheckEdgeFlatness): only the ring of samples one cell outside the skirt is
--                 looked at; the deviation is measured from ceil(the last ring sample), the height the skirt gets levelled to.
--      'area'     FlattenSkirt = false (point defence, radar, naval factories, ...; OCCUPY_CheckAreaFlatness): highest minus lowest sample over the skirt.
--   Skirt: the skirt of the structure in cells (Physics.SkirtSizeX / Z, at least the footprint), chosen from the sizes real blueprints have (SKIRT_STOPS).
--   The native kind names are 'path', 'build' (the area rule) and 'ring'; an editor build without the ring rule shows the area rule instead (NativeKind).
-- Terrain-type "blocking" cells and water depth are separate rules and not part of this view yet.

Visible = false
Kind = 'path'     -- 'path' | 'build'
Rule = 'ring'     -- structures: 'ring' | 'area'
Window = 1        -- the footprint or skirt in cells that is being shown (Footprint for 'path', Skirt for 'build'); what the native layer gets
Limit = 0.75      -- the limit that is being shown
Footprint = 1     -- remembered for the mobile-unit view
Skirt = 2         -- remembered for the structure view
BuildLimit = { ring = 1.0, area = 1.0 }    -- remembered per structure rule (1.0 is the MaxGroundVariation of most structure blueprints under either rule)

PATH_LIMIT = 0.75

--- Footprints of mobile units (cells) that have a slope rule: lua/footprints.lua gives MaxSlope to Vehicle 1x1, 2x2, 5x5, Amphibious 1x1, 3x3, 6x6 and WaterLand 1x1 .. 4x4. The
--- bigger water footprints (Water8x8, SurfacingSub12x12 ...) have no MaxSlope.
FOOTPRINT_STOPS = { 1, 2, 3, 4, 5, 6 }

--- Skirt sizes of structures (cells), chosen by how many structure blueprints have them (scripts/skirt_stats.py, SLOPE_VIEW.md): 1 (point defence, radar), 2 (power, T2 defence),
--- 3, 5, 6 (shields, missile launchers), 8 (factories, T3 power / artillery), 10 (gateways, Paragon), 12 and 15 (naval factories are 12 x 15).
SKIRT_STOPS = { 1, 2, 3, 5, 6, 8, 10, 12, 15 }

--- Limits worth offering for structures (the MaxGroundVariation values that matter; 50 (walls) and 512 (extractors) mean "no slope rule").
BUILD_LIMITS = { 1.0, 1.1, 1.2 }

--- What structures have a skirt of this size (a short hint under the slider; from the blueprint data).
SKIRT_HINTS = {
    [1] = 'Tech 1 point defence, anti-air and torpedo launchers, radar and sonar. (Walls have a 1 x 1 skirt too but ignore slope.)',
    [2] = 'Power generators, mass storage and fabricators, tech 2 point defence, anti-air, artillery and missile launchers, radars, engineering stations.',
    [3] = 'Tech 2 torpedo launchers and other tech 2 / 3 defences (strategic missile defence, counter-intelligence).',
    [5] = 'A few campaign structures.',
    [6] = 'Shields, nuclear missile launchers, air staging platforms, tech 3 mass fabricators, tech 2 power.',
    [8] = 'Land and air factories of all tech levels, tech 3 power, tech 3 and experimental artillery, nuclear experimentals.',
    [10] = 'Quantum gateways, the Paragon, the Aeon experimental artillery.',
    [12] = 'Naval factories are 12 x 15 cells: this is their short side (a square window cannot show both; 15 covers the long side).',
    [15] = 'Naval factories are 12 x 15 cells: this is their long side (12 covers the short side).',
}

Persist = true    -- false: the choices are not written to the user settings (selftest_slope.lua)

--- The MaxGroundVariation the buildings (ring rule) of a skirt size usually have (blueprint data, SLOPE_VIEW.md); sizes not listed have no pattern.
RING_LIMIT_HINTS = {
    [1] = '1.0', [2] = '1.0', [3] = '1.0', [6] = '1.0 or 1.1', [8] = '1.1', [10] = '1.0 or 1.2',
}

local function Remember(key, value)
    if not Persist then return end
    pcall(function() import('/lua/editor/userdata.lua').Set(key, value) end)
end

local function Recall(key, default)
    local ok, v = pcall(function() return import('/lua/editor/userdata.lua').Get(key, default) end)
    if ok and v ~= nil then return v end
    return default
end

--- The stop nearest to `v`.
function NearestStop(stops, v)
    local best, bestD = stops[1], 1e30
    for _, s in stops do
        local d = math.abs(s - v)
        if d < bestD then best, bestD = s, d end
    end
    return best
end

--- Brings Window and Limit in line with the kind, the rule and the remembered sizes.
local function Sync()
    if Kind == 'path' then
        Window = Footprint
        Limit = PATH_LIMIT
    else
        Window = Skirt
        Limit = BuildLimit[Rule] or 1.0
    end
end

--- Restores what the user chose last time (userdata settings.lua). Called once when the module loads.
local function Load()
    Footprint = NearestStop(FOOTPRINT_STOPS, Recall('slope.footprint', Footprint))
    Skirt = NearestStop(SKIRT_STOPS, Recall('slope.skirt', Skirt))
    local rule = Recall('slope.rule', Rule)
    if rule == 'ring' or rule == 'area' then Rule = rule end
    BuildLimit.ring = NearestStop(BUILD_LIMITS, Recall('slope.limit.ring', BuildLimit.ring))
    BuildLimit.area = NearestStop(BUILD_LIMITS, Recall('slope.limit.area', BuildLimit.area))
    Sync()
end

function SetKind(kind)
    if kind ~= 'path' and kind ~= 'build' then return end
    Kind = kind
    Sync()
end

--- The structure rule: 'ring' (FlattenSkirt) or 'area'.
function SetRule(rule)
    if rule ~= 'ring' and rule ~= 'area' then return end
    Rule = rule
    Remember('slope.rule', rule)
    Sync()
end

--- Sets the footprint (mobile units) or the skirt (structures), whichever is shown, to the nearest stop.
function SetWindow(n)
    if Kind == 'path' then
        Footprint = NearestStop(FOOTPRINT_STOPS, n)
        Remember('slope.footprint', Footprint)
    else
        Skirt = NearestStop(SKIRT_STOPS, n)
        Remember('slope.skirt', Skirt)
    end
    Sync()
end

--- Sets the limit of the structure rule that is shown to the nearest offered limit.
function SetLimit(v)
    if Kind ~= 'build' then return end
    BuildLimit[Rule] = NearestStop(BUILD_LIMITS, v)
    Remember('slope.limit.' .. Rule, BuildLimit[Rule])
    Sync()
end

--- Steps through the structure limits.
function NextBuildLimit()
    for i, v in BUILD_LIMITS do
        if math.abs(v - Limit) < 0.001 then
            SetLimit(BUILD_LIMITS[math.mod(i, table.getn(BUILD_LIMITS)) + 1])
            return
        end
    end
    SetLimit(BUILD_LIMITS[1])
end

local ringKnown = nil

--- True when the editor engine has the ring rule (ed_overlay_slope_caps lists 'ring'). An older engine has only 'path' and 'build'.
function HasRing()
    if ringKnown == nil then
        local caps = rawget(_G, 'ed_overlay_slope_caps')
        if not caps then return false end        -- (not remembered: the natives may not be registered yet)
        ringKnown = false
        local ok, list = pcall(caps)
        if ok and type(list) == 'table' then
            for _, k in list do
                if k == 'ring' then ringKnown = true end
            end
        end
    end
    return ringKnown
end

--- Forgets what HasRing found (selftest_slope.lua swaps ed_overlay_slope_caps for a stand-in and back).
function ForgetProbe()
    ringKnown = nil
end

--- The rule name for ed_overlay_slope / ed_slope_at: 'path', 'ring' or 'build' (the area rule). Without the native ring rule the structure view falls back to 'build'.
function NativeKind()
    if Kind == 'path' then return 'path' end
    if Rule == 'ring' and HasRing() then return 'ring' end
    return 'build'
end

--- True when the view shows the area rule although the ring rule was asked for (an engine without it).
function RingMissing()
    return Kind == 'build' and Rule == 'ring' and not HasRing()
end

--- 'slope 0.62 of 0.75' for the cell under the pointer, or ''.
function Readout()
    if not Visible then return '' end
    local p = GetMouseWorldPos()
    if not p or not rawget(_G, 'ed_slope_at') then return '' end
    local v = ed_slope_at(NativeKind(), p[1], p[3], Window)
    if not v then return '' end
    local what = 'slope'
    if Kind == 'build' then what = (NativeKind() == 'ring') and 'ring deviation' or 'ground variation' end
    local verdict = (v > Limit) and '  BLOCKED' or ''
    return string.format('%s %.2f / %.2f (%dx%d)%s', what, v, Limit, Window, Window, verdict)
end

Load()
