-- The build grid of the game and the rules that follow from it.
--
-- Structures are placed by their footprint on the 1 x 1 cell grid: the centre of a footprint with an odd number of cells lies on a
-- cell centre (n + 0.5), the centre of an even one on a cell corner (n). Mass extractors (1 x 1) and hydrocarbon plants (3 x 3) are
-- odd, so a Mass / Hydrocarbon marker only matches the structure that will stand on it when x and z end in .5.
--
--   Grid.SnapMarker(markerType, x, z) -> x, z      snapped for resource markers, unchanged for the others
--   Grid.IsAligned(markerType, x, z)  -> bool
--   Grid.FootprintOf(unitId)          -> cells x, cells z      from the unit blueprint (1 when it has none)
--   Grid.Visible                      the build grid view (drawn by overlay.lua)

Visible = false

--- The structure each resource marker stands for: unit, footprint cells and skirt size (the blueprint wins when it can be read).
Structure = {
    Mass = { unit = 'ueb1103', footprint = 1, skirt = 2 },
    Hydrocarbon = { unit = 'ueb1102', footprint = 3, skirt = 6 },
}

local function Blueprint(id)
    local all = rawget(_G, '__blueprints')
    return all and all[string.lower(id or '')]
end

--- Footprint of a unit in cells (x, z); structures without a Footprint table are 1 x 1.
function FootprintOf(unitId)
    local bp = Blueprint(unitId)
    local fp = bp and bp.Footprint
    return (fp and fp.SizeX) or 1, (fp and fp.SizeZ) or 1
end

--- Footprint and skirt of the structure on a resource marker type, or nil for other marker types.
local infoCache = {}      -- marker type -> { bp, info }: asked for every marker on every overlay rebuild and for every snap of the pointer

function ResourceInfo(markerType)
    local s = Structure[markerType]
    if not s then return nil end
    local bp = Blueprint(s.unit)
    local c = infoCache[markerType]
    if c and c.bp == bp and c.s == s then return c.info end
    local fx, fz = FootprintOf(s.unit)
    local skirt = bp and bp.Physics and bp.Physics.SkirtSizeX
    local info = { unit = s.unit, fx = (bp and fx) or s.footprint, fz = (bp and fz) or s.footprint, skirt = skirt or s.skirt }
    infoCache[markerType] = { bp = bp, s = s, info = info }
    return info
end

--- Nearest centre for a footprint `cells` wide: n + 0.5 for odd, n for even.
function SnapCentre(v, cells)
    if math.mod(cells, 2) == 1 then
        return math.floor(v) + 0.5
    end
    return math.floor(v + 0.5)
end

function SnapMarker(markerType, x, z)
    local info = ResourceInfo(markerType)
    if not info then return x, z end
    return SnapCentre(x, info.fx), SnapCentre(z, info.fz)
end

function IsAligned(markerType, x, z)
    local sx, sz = SnapMarker(markerType, x, z)
    return math.abs(sx - x) < 0.02 and math.abs(sz - z) < 0.02
end

--- True when the blueprint is a structure (the only units the grid applies to).
function IsStructure(unitId)
    local bp = Blueprint(unitId)
    if not bp then return false end
    if bp.CategoriesHash then return bp.CategoriesHash.STRUCTURE == true end
    for _, c in bp.Categories or {} do
        if c == 'STRUCTURE' then return true end
    end
    return false
end
