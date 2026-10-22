-- The local erosion brushes (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3): Erode, Rain and Deposit on the native erosion session (moho/editor/EdErosion.cpp, EdErosionLua.cpp).
--
-- One stroke = one session: Begin() copies the heights as floats; every dab releases water drops at random places inside the brush (a few hundred per dab), they run downhill on the
-- real terrain with inertia, dissolve ground where they are fast on a slope and settle it where they slow down. Everything a drop digs or settles is multiplied by the brush weight of the
-- sample it lands on, so the ground never changes outside the brush radius (the Rain brush: up to its reach) and the effect follows the falloff inside. No water is left behind between
-- dabs, so nothing stands as a pattern along the window of a dab. All writes go through the document's open stroke (terrain.lua opens it), so a stroke is one undo step. Symmetry is
-- handled by terrain.lua (one dab per image, the state is shared).
--
--   Erode    drops run downhill from everywhere in the brush and carve it; what runs out of the brush is carried away, a share (Keep volume) is put back low in the brush
--   Rain     the same, but the drops keep digging up to the reach past the brush while they run on downhill
--   Deposit  every drop first dumps its share of the sediment where it is released (an even heap), then runs on and carries off what it picks up from the loose heap
--
-- Values (sliders in the Erosion panel): drop rounds per strength unit, rain (how many drops a round releases), capacity, erosion (dissolving), deposition (settling), inertia, thermal
-- slides, rain reach, hardness variation, keep volume. (An exe without the droplet brush solves a window with the grid solver and ignores inertia, keep volume and the reach of
-- the Rain brush's window rule: the same calls work.)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Brushes = import('/lua/editor/brushes.lua')

--- The brush values; the Erosion panel edits them.
Values = {
    iterations = 4,        -- rounds of drops per strength unit (Brush.strength 2 = 8 rounds); also the number of thermal slide steps / 2
    rain = 0.006,          -- how many drops a round releases (0.006 = the default density, twice as much = twice the drops)
    evaporation = 0.02,    -- share of its water a drop loses per step (a drop that has dried up carries and digs nothing)
    gain = 0.08,           -- (grid solver of an exe without the droplet brush)
    capacity = 1.0,        -- how much sediment a fast drop on a slope can carry
    erosion = 0.2,         -- share of the missing sediment a drop dissolves per step
    deposition = 0.1,      -- share of the surplus sediment a drop settles per step
    inertia = 0.3,         -- how much a drop keeps its direction (0 = straight down the steepest way, 0.9 = hardly turns): more gives longer, more meandering gullies
    conserve = 0.7,        -- Keep volume: the share of the sediment that runs out of the brush that is put back low in the brush (0 = all of it is carried away)
    thermal = 0.15,        -- thermal slide rate (0 = off): steep ground under the brush slides to the talus angle
    talus = 0.8,
    reach = 0.8,           -- Rain brush only: how far past its radius it digs, as a share of the radius (the water runs on downhill)
    amount = 0.5,          -- deposit brush: sediment depth dumped at the centre per dab (world units)
    vary = 0.5,            -- hard and soft ground under the brush (0 = even): noise on the erodibility and the drops, the same pattern for every dab
    vary_scale = 24,       -- feature size of that pattern (samples)
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
                                thermal = v.thermal, talus = v.talus, vary = v.vary, vary_scale = v.vary_scale, inertia = v.inertia, conserve = v.conserve })
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
    -- only the Rain brush has a margin (its reach past the radius); for the others the window is the brush itself (no margin = the exe's own rule)
    local margin = nil
    if mode == 'rain' then margin = v.reach * radius + 3 end
    return {
        iterations = n,
        strength = 1,
        falloff = brush.falloff,
        mode = mode,
        margin = margin,
        amount = v.amount,
    }
end

--- One dab. `weight`: optional, for shaped brushes. A table { id = shape id, turn = degrees } (terrain.lua): the exe builds the window's weights from the shape mask
--- (opts.shape / opts.angle, ed_brush_shape_set), or, without those natives, Brushes.Fill makes the list in a tight loop. A function (dx, dz) -> weight is the old callback
--- (one Lua call per sample of the window), kept for other callers. Returns the samples changed and the changed window.
function Dab(cx, cz, brush, mode, inverted, weight)
    if not active then return 0 end
    local opts = DabOptions(brush, mode, inverted)
    if type(weight) == 'table' then
        local handle = Brushes.NativeShape(weight.id)
        if handle then
            opts.shape = handle
            opts.angle = (Brushes.Angle or 0) + (weight.turn or 0)
        else
            local x0, z0, x1, z1 = ed_erode_window(cx, cz, brush.radius, { mode = opts.mode, margin = opts.margin })
            opts.weights = Brushes.Fill(weight.id, brush.radius, weight.turn, cx, cz, x0, z0, x1, z1)
        end
    elseif weight then
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
