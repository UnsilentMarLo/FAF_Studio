-- Range rings of the selected units (GPG and Unity editors show weapon ranges): for every selected unit (up to 8) the longest weapon range in red, the shortest non-zero minimum
-- range in dark red, the vision radius in white and the radar radius in green, from the unit blueprint. Drawn on the terrain by the overlay each frame (overlay.lua calls Draw).
--
--   Radii(blueprintId)   -> list of { kind = 'weapon' | 'minimum' | 'vision' | 'radar' | 'sonar', radius, color }
--   Show                 switch (View panel)
--   Draw(ui) / Forget()
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

Show = true
local MAX_UNITS = 8

local drawn = {}
local drawKey = ''

local COLORS = { weapon = 'FFFF3030', minimum = 'FF901818', vision = 'FFFFFFFF', radar = 'FF40E040', sonar = 'FF4090FF' }

--- Rings of a unit blueprint, longest first inside each kind.
function Radii(bpId)
    local bp = __blueprints and __blueprints[bpId]
    local list = {}
    if not bp then return list end
    local maxR, minR = 0, nil
    for _, w in bp.Weapon or {} do
        local r = tonumber(w.MaxRadius) or 0
        if r > maxR then maxR = r end
        local m = tonumber(w.MinRadius) or 0
        if m > 0 and (not minR or m < minR) then minR = m end
    end
    if maxR > 0 then table.insert(list, { kind = 'weapon', radius = maxR, color = COLORS.weapon }) end
    if minR then table.insert(list, { kind = 'minimum', radius = minR, color = COLORS.minimum }) end
    local intel = bp.Intel or {}
    local vision = tonumber(intel.VisionRadius) or 0
    if vision > 0 then table.insert(list, { kind = 'vision', radius = vision, color = COLORS.vision }) end
    local radar = tonumber(intel.RadarRadius) or 0
    if radar > 0 then table.insert(list, { kind = 'radar', radius = radar, color = COLORS.radar }) end
    local sonar = tonumber(intel.SonarRadius) or 0
    if sonar > 0 then table.insert(list, { kind = 'sonar', radius = sonar, color = COLORS.sonar }) end
    return list
end

function Forget()
    drawn = {}
    drawKey = ''
end

local function RemoveAll()
    for id, _ in drawn do ed_overlay_remove(id) end
    drawn = {}
    drawKey = ''
end

local function Ring(cx, cz, r)
    local pts = {}
    local segs = math.max(32, math.min(96, math.floor(r * 1.2)))
    for i = 0, segs do
        local a = 2 * math.pi * i / segs
        local x, z = cx + r * math.cos(a), cz + r * math.sin(a)
        table.insert(pts, x)
        table.insert(pts, (ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0) + 0.4)
        table.insert(pts, z)
    end
    return pts
end

function Draw(ui)
    if rawget(_G, 'ed_overlay_set') == nil or not Map.Doc then return end
    local Units = import('/lua/editor/units.lua')
    local mode = ui and ui.State and ui.State.mode
    if not Show or mode == 'play' or table.getn(Units.Selection) == 0 then
        if next(drawn) ~= nil then RemoveAll() end
        return
    end
    local picks = {}
    for _, sel in Units.Selection do
        if table.getn(picks) >= MAX_UNITS then break end
        -- (a lookup in the cached unit list: this runs every frame, and All() builds a table for each of the map's units)
        local u = Units.Lookup(sel.army, sel.name)
        if u then table.insert(picks, u) end
    end
    local key = ''
    for _, u in picks do key = key .. string.format('%s|%s|%.1f|%.1f;', u.army, u.name, u.x, u.z) end
    if key == drawKey then return end
    drawKey = key
    local keep = {}
    for _, u in picks do
        for i, ring in Radii(u.bp) do
            local id = 'ur:' .. u.army .. ':' .. u.name .. ':' .. ring.kind
            ed_overlay_set(id, Ring(u.x, u.z, ring.radius), ring.color, 0.12, 1, 3, false, true)
            keep[id] = true
            drawn[id] = true
        end
    end
    for id, _ in drawn do
        if not keep[id] then ed_overlay_remove(id) drawn[id] = nil end
    end
end
