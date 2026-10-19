-- The slope view: the engine's own terrain ratings as a colour gradient over the ground (drawn natively, EdOverlay.cpp, from the live height
-- field with the same formulas the sim uses), so the mapper sees what slope does to gameplay.
--
--   'path'   mobile units. A footprint of N x N cells may stand on a place when the steepest height difference between neighbouring height
--            samples inside its window is at most MaxSlope (0.75 for every land, amphibious and hover footprint, lua/footprints.lua), in world
--            units per cell. Bigger footprints look at a bigger window, so they are blocked by slopes the small ones cross.
--   'build'  structures. The height range (highest minus lowest sample) over the skirt may not exceed the blueprint's Physics.MaxGroundVariation:
--            1.1 for most structures, 1.0 when a blueprint does not say, 1.2 and 50 for a few; mass extractors and hydrocarbon plants
--            allow 512 (they ignore slope).
-- Terrain-type "blocking" cells and water depth are separate rules and not part of this view yet.

Visible = false
Kind = 'path'
Window = 1       -- footprint / skirt size in cells
Limit = 0.75

--- Limits worth offering for structures (MaxGroundVariation values found in the unit blueprints).
BUILD_LIMITS = { 1.0, 1.1, 1.2, 50 }

local DEFAULTS = { path = { window = 1, limit = 0.75 }, build = { window = 2, limit = 1.1 } }

function SetKind(kind)
    if kind ~= 'path' and kind ~= 'build' then return end
    Kind = kind
    Window = DEFAULTS[kind].window
    Limit = DEFAULTS[kind].limit
end

function SetWindow(n)
    Window = math.max(1, math.min(12, n))
end

--- Steps through the structure limits.
function NextBuildLimit()
    for i, v in BUILD_LIMITS do
        if math.abs(v - Limit) < 0.001 then
            Limit = BUILD_LIMITS[math.mod(i, table.getn(BUILD_LIMITS)) + 1]
            return
        end
    end
    Limit = BUILD_LIMITS[1]
end

--- 'slope 0.62 of 0.75' for the cell under the pointer, or ''.
function Readout()
    if not Visible then return '' end
    local p = GetMouseWorldPos()
    if not p or not rawget(_G, 'ed_slope_at') then return '' end
    local v = ed_slope_at(Kind, p[1], p[3], Window)
    if not v then return '' end
    local what = (Kind == 'path') and 'slope' or 'ground variation'
    local verdict = (v > Limit) and '  BLOCKED' or ''
    return string.format('%s %.2f / %.2f (%dx%d)%s', what, v, Limit, Window, Window, verdict)
end
