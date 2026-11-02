-- A stress document for the frame-cost measurements (PERFORMANCE.md "Frame cost budgets", selftest_perfbudget.lua, scripts/editor_nightly.py step `perf`):
-- thousands of markers, a few dozen areas and hundreds of units, put into the open map by the editor's own document calls (no history entries, nothing is saved).
-- Positions come from a fixed pseudo-random sequence, so two runs build the same map.
--
--   Build(opts)     opts = { markers = 3000, areas = 40, units = 600, seed = 1 }; returns a text with the numbers made. Calling it again first removes what the last call made.
--   Remove()        takes the objects of Build away again
--   Frames(n)       runs overlay.Update n times in a row (as the frame tick does) and returns { ms = ms per frame, kb = Lua garbage made per frame (KB), worst = slowest frame (ms) }
--   Paced(secs, fps)  runs overlay.Update at `fps` frames per second for `secs` seconds of wall time (the editor stands still meanwhile) and returns
--                   { perSecond = Lua ms per second spent in it, worst = slowest frame (ms), kb = garbage per frame (KB), frames = n, growth = KB the heap grew over the run (both ends after a collection) }
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')

local TYPES = { 'Mass', 'Hydrocarbon', 'Blank Marker', 'Combat Zone', 'Land Path Node', 'Land Path Node', 'Defensive Point', 'Expansion Area', 'Rally Point', 'Air Path Node' }
local UNIT_BPS = { 'uel0106', 'url0106', 'ual0106', 'xsl0201', 'uel0201', 'url0107' }

local madeMarkers, madeAreas, madeUnits = {}, {}, {}

-- (Lua numbers are 32-bit floats: a generator whose products pass 2^24 degenerates; this one stays below 5 million. Two numbers are mixed per call so that x and z do not line up.)
local seed = 1
local function Rand()
    seed = math.mod(seed * 75 + 74, 65537)
    local a = seed
    seed = math.mod(seed * 75 + 74, 65537)
    return (a + seed / 65537) / 65537
end

function Remove()
    local doc = Map.Doc
    if not doc then return end
    local markers = doc.save.MasterChain._MASTERCHAIN_.Markers
    for _, name in madeMarkers do markers[name] = nil end
    for _, name in madeAreas do doc.save.Areas[name] = nil end
    local Units = import('/lua/editor/units.lua')
    for _, u in madeUnits do Units.RemoveRaw(u) end
    madeMarkers, madeAreas, madeUnits = {}, {}, {}
    Tools.Changed = Tools.Changed + 1
end

function Build(opts)
    opts = opts or {}
    if not Map.Doc then return 'no map' end
    Remove()
    seed = opts.seed or 1
    local nm, na, nu = opts.markers or 3000, opts.areas or 40, opts.units or 600
    local sx, sz = ed_terrain_info()
    sx, sz = (sx or 257) - 1, (sz or 257) - 1
    local margin = math.min(40, sx / 10)
    for i = 1, nm do
        local name = 'PS_' .. i
        local x, z = margin + Rand() * (sx - 2 * margin), margin + Rand() * (sz - 2 * margin)
        local kind = TYPES[1 + math.mod(i, table.getn(TYPES))]
        if kind == 'Mass' or kind == 'Hydrocarbon' then x, z = math.floor(x) + 0.5, math.floor(z) + 0.5 end
        local y = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
        Map.AddMarker(name, kind, x, y, z, nil)
        table.insert(madeMarkers, name)
    end
    for i = 1, na do
        local name = 'PS_AREA_' .. i
        local w, h = 20 + Rand() * 120, 20 + Rand() * 120
        local x0, z0 = margin + Rand() * (sx - 2 * margin - w), margin + Rand() * (sz - 2 * margin - h)
        Map.AddArea(name, x0, z0, x0 + w, z0 + h)
        table.insert(madeAreas, name)
    end
    local Units = import('/lua/editor/units.lua')
    local armies = Units.Armies()
    local army = armies[1]
    local made = 0
    if army and nu > 0 then
        for i = 1, nu do
            local x, z = margin + Rand() * (sx - 2 * margin), margin + Rand() * (sz - 2 * margin)
            local u = { army = army, group = 'INITIAL', name = 'PS_UNIT_' .. i, bp = UNIT_BPS[1 + math.mod(i, table.getn(UNIT_BPS))], x = x, z = z,
                        y = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0, heading = Rand() * 6.28 }
            if Units.AddRaw(u) then
                table.insert(madeUnits, u)
                made = made + 1
            end
        end
    end
    Tools.Changed = Tools.Changed + 1
    return string.format('%d markers, %d areas, %d units (army %s)', nm, na, made, tostring(army))
end

function Frames(n)
    local Overlay = import('/lua/editor/overlay.lua')
    local ui = import('/lua/editor/ui.lua')
    local clock = GetSystemTimeSeconds
    local worst, total, garbage = 0, 0, 0
    local last = gcinfo()
    for _ = 1, n do
        local t0 = clock()
        Overlay.Update(ui)
        local dt = clock() - t0
        total = total + dt
        if dt > worst then worst = dt end
        local now = gcinfo()
        if now > last then garbage = garbage + (now - last) end
        last = now
    end
    return { ms = total * 1000 / n, worst = worst * 1000, kb = garbage / n }
end

function Paced(secs, fps)
    local Overlay = import('/lua/editor/overlay.lua')
    local ui = import('/lua/editor/ui.lua')
    local clock = GetSystemTimeSeconds
    local step = 1 / (fps or 60)
    collectgarbage(0)
    collectgarbage(0)
    local heap0 = gcinfo()
    local start = clock()
    local total, worst, garbage, frames = 0, 0, 0, 0
    local last = gcinfo()
    local nextAt = start
    while clock() - start < secs do
        local t0 = clock()
        Overlay.Update(ui)
        local dt = clock() - t0
        total = total + dt
        if dt > worst then worst = dt end
        frames = frames + 1
        local now = gcinfo()
        if now > last then garbage = garbage + (now - last) end
        last = now
        nextAt = nextAt + step
        while clock() < nextAt do end          -- (the frame's other work, the render and the wait for the display, are not ours: spin)
    end
    local elapsed = clock() - start
    collectgarbage(0)
    collectgarbage(0)
    return { perSecond = total * 1000 / elapsed, worst = worst * 1000, kb = garbage / math.max(1, frames), frames = frames, growth = gcinfo() - heap0 }
end
