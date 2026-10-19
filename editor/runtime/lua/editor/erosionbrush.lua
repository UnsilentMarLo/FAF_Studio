-- The local erosion brushes (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3): Erode, Rain and Deposit on the native erosion session (moho/editor/EdErosion.cpp, EdErosionLua.cpp).
--
-- One stroke = one session: Begin() copies the heights as floats and starts with empty water, every dab runs a few iterations of the hydraulic kernels on a window around the brush
-- (border fixed, the brush falloff weights rain and dissolving), so water and sediment keep flowing from dab to dab; End() lets the remaining sediment settle. All writes go through
-- the document's open stroke (terrain.lua opens it), so a stroke is one undo step. Symmetry is handled by terrain.lua (one dab per image, the state is shared).
--
--   Erode    rain and dissolving under the brush, sediment carried downhill and dropped where the water slows
--   Rain     water only under the brush; it erodes along its way down (outside the brush too, within the window)
--   Deposit  sediment is dumped under the brush and settles (with a little water it also slides downhill)
--
-- Values (sliders in the Erosion panel): iterations per strength unit, rain, evaporation, capacity, erosion, deposition, thermal slides, window margin.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

--- The brush values; the Erosion panel edits them.
Values = {
    iterations = 4,        -- dabs run this many iterations per strength unit (Brush.strength 2 = 8 iterations)
    rain = 0.006,
    evaporation = 0.02,
    gain = 0.08,
    capacity = 1.0,
    erosion = 0.2,
    deposition = 0.1,
    thermal = 0.3,         -- thermal slide rate (0 = off)
    talus = 0.8,
    margin = 0.35,         -- extra window around the brush as a share of the radius
    amount = 0.5,          -- deposit brush: sediment depth dumped at the centre per dab (world units)
}

local active = false

function IsAvailable()
    return rawget(_G, 'ed_erode_begin') ~= nil
end

function IsActive()
    return active
end

--- Brush modes handled here (the tool ids of ui.lua).
function Handles(mode)
    return mode == 'erode' or mode == 'rain' or mode == 'deposit'
end

--- Starts the session of a stroke; false when the natives are missing.
function Begin()
    if not IsAvailable() then return false end
    local v = Values
    local ok = ed_erode_begin({ rain = v.rain, evaporation = v.evaporation, gain = v.gain, capacity = v.capacity, erosion = v.erosion, deposition = v.deposition,
                                thermal = v.thermal, talus = v.talus })
    active = ok and true or false
    return active
end

--- Iterations and options of one dab for the brush `brush` (terrain.lua's Brush): strength sets the iterations.
function DabOptions(brush, mode, inverted)
    local v = Values
    local n = math.floor(math.abs(brush.strength) * v.iterations + 0.5)
    if n < 1 then n = 1 elseif n > 60 then n = 60 end
    if mode == 'erode' and inverted then mode = 'deposit' end
    local radius = brush.radius
    return {
        iterations = n,
        strength = 1,
        falloff = brush.falloff,
        mode = mode,
        margin = (mode == 'rain' and 0.8 or v.margin) * radius + 3,
        amount = v.amount,
    }
end

--- One dab. `weights`: optional function (dx, dz) -> weight for shaped brushes (terrain.lua passes its Weight). Returns the samples changed and the changed window.
function Dab(cx, cz, brush, mode, inverted, weight)
    if not active then return 0 end
    local opts = DabOptions(brush, mode, inverted)
    if weight then
        local x0, z0, x1, z1 = ed_erode_window(cx, cz, brush.radius, { mode = opts.mode, margin = opts.margin })
        local list = {}
        local i = 0
        for z = z0, z1 do
            for x = x0, x1 do
                i = i + 1
                list[i] = weight(x - cx, z - cz)
            end
        end
        opts.weights = list
    end
    local changed, x0, z0, x1, z1 = ed_erode_dab(cx, cz, brush.radius, opts)
    return changed or 0, x0, z0, x1, z1
end

--- Ends the session: the sediment still in the water settles. Returns the samples changed and the window.
function End()
    if not active then return 0 end
    active = false
    local changed, x0, z0, x1, z1 = ed_erode_end(true)
    return changed or 0, x0, z0, x1, z1
end
