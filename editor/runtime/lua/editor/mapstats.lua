-- Map statistics (GPG editor's statistics dialog): what is in the map and how it is shared between the start positions. Counts of markers by type, areas, chains, props, decals and
-- units per army; mass points and hydrocarbon points per start position (every resource marker belongs to the nearest start position), the reclaim value of the props (mass and
-- energy from the prop blueprints) per start position and in total, the spread of the shares (a fair map has equal ones).
--
--   Compute()                -> stats table: { size, starts = { { name, x, z, mass, hydro, reclaimMass, reclaimEnergy } }, masses, hydros, markers = { type = n }, areas, chains, props, decals,
--                               units = { army = n }, reclaimMass, reclaimEnergy, massSpread, reclaimSpread }
--   Rows(stats)              -> list of { text, value, header } for the panel
--   ReclaimOf(blueprintPath) -> mass, energy (the Economy.ReclaimMassMax / ReclaimEnergyMax of a prop blueprint; 0, 0 when it has none or cannot be read)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

local reclaimCache = {}

--- Reclaim values of a prop blueprint file (text Lua: `PropBlueprint { Economy = { ReclaimMassMax = ..., ReclaimEnergyMax = ... } }`).
function ReclaimOf(bp)
    local c = reclaimCache[bp]
    if c then return c[1], c[2] end
    local mass, energy = 0, 0
    local result
    local env = {}
    setmetatable(env, { __index = function(t, k)
        if k == 'PropBlueprint' then return function(spec) result = spec end end
        return function(x) return x end          -- Sound { ... }, categories ... : whatever else a blueprint calls
    end })
    local ok = pcall(function() doscript(bp, env) end)
    if ok and result and type(result.Economy) == 'table' then
        mass = tonumber(result.Economy.ReclaimMassMax) or 0
        energy = tonumber(result.Economy.ReclaimEnergyMax) or 0
    end
    reclaimCache[bp] = { mass, energy }
    return mass, energy
end

local function Spread(values)
    local lo, hi
    for _, v in values do
        if not lo or v < lo then lo = v end
        if not hi or v > hi then hi = v end
    end
    if not lo or hi == 0 then return 0 end
    return (hi - lo) / hi
end

function Compute()
    local doc = Map.Doc
    local stats = { starts = {}, markers = {}, units = {}, masses = 0, hydros = 0, areas = 0, chains = 0, props = 0, decals = 0, reclaimMass = 0, reclaimEnergy = 0, massSpread = 0, reclaimSpread = 0 }
    if not doc then return stats end
    local w = ed_terrain_info()
    stats.size = w and (w - 1) or 0
    local markers = doc.save.MasterChain._MASTERCHAIN_.Markers
    for name, m in markers do
        local t = tostring(m.type)
        stats.markers[t] = (stats.markers[t] or 0) + 1
        if string.find(name, '^ARMY_%d+$') then
            table.insert(stats.starts, { name = name, x = m.position[1], z = m.position[3], mass = 0, hydro = 0, reclaimMass = 0, reclaimEnergy = 0 })
        end
    end
    table.sort(stats.starts, function(a, b) return a.name < b.name end)
    local function Nearest(x, z)
        local best, bd
        for _, s in stats.starts do
            local dx, dz = s.x - x, s.z - z
            local d = dx * dx + dz * dz
            if not bd or d < bd then best, bd = s, d end
        end
        return best
    end
    for _, m in markers do
        if m.type == 'Mass' then
            stats.masses = stats.masses + 1
            local s = Nearest(m.position[1], m.position[3])
            if s then s.mass = s.mass + 1 end
        elseif m.type == 'Hydrocarbon' then
            stats.hydros = stats.hydros + 1
            local s = Nearest(m.position[1], m.position[3])
            if s then s.hydro = s.hydro + 1 end
        end
    end
    for _ in doc.save.Areas or {} do stats.areas = stats.areas + 1 end
    for _ in doc.save.Chains or {} do stats.chains = stats.chains + 1 end
    stats.props = ed_prop_count() or 0
    for i = 1, stats.props do
        local bp, x, y, z = ed_prop_get(i)
        if bp then
            local rm, re = ReclaimOf(bp)
            if rm > 0 or re > 0 then
                stats.reclaimMass = stats.reclaimMass + rm
                stats.reclaimEnergy = stats.reclaimEnergy + re
                local s = Nearest(x, z)
                if s then
                    s.reclaimMass = s.reclaimMass + rm
                    s.reclaimEnergy = s.reclaimEnergy + re
                end
            end
        end
    end
    stats.decals = ed_decal_count() or 0
    for _, u in import('/lua/editor/units.lua').All() do
        stats.units[u.army] = (stats.units[u.army] or 0) + 1
    end
    local massShares, reclaimShares = {}, {}
    for _, s in stats.starts do
        table.insert(massShares, s.mass)
        table.insert(reclaimShares, s.reclaimMass)
    end
    stats.massSpread = Spread(massShares)
    stats.reclaimSpread = Spread(reclaimShares)
    return stats
end

--- The statistics as rows for a list: header rows ({ header = true }) and { text, value }.
function Rows(stats)
    local rows = {}
    local function Head(text) table.insert(rows, { text = text, header = true }) end
    local function Add(text, value) table.insert(rows, { text = text, value = tostring(value) }) end
    Head('Map')
    Add('Size', string.format('%d x %d units (%.1f km)', stats.size or 0, stats.size or 0, (stats.size or 0) / 51.2))
    Add('Start positions', table.getn(stats.starts))
    Add('Mass points', stats.masses)
    Add('Hydrocarbon points', stats.hydros)
    Add('Props', stats.props)
    Add('Decals', stats.decals)
    Add('Areas / chains', stats.areas .. ' / ' .. stats.chains)
    Add('Reclaim, all props', string.format('%d mass, %d energy', stats.reclaimMass, stats.reclaimEnergy))
    Head('Per start position (nearest start)')
    for _, s in stats.starts do
        Add(s.name, string.format('%d mass, %d hydro, reclaim %d / %d', s.mass, s.hydro, s.reclaimMass, s.reclaimEnergy))
    end
    if table.getn(stats.starts) > 1 then
        Add('Mass point spread', string.format('%.0f %% (0 = equal)', stats.massSpread * 100))
        Add('Reclaim spread', string.format('%.0f %% (0 = equal)', stats.reclaimSpread * 100))
    end
    local armies = {}
    for army, n in stats.units do table.insert(armies, army) end
    table.sort(armies)
    if table.getn(armies) > 0 then
        Head('Units per army')
        for _, a in armies do Add(a, stats.units[a]) end
    end
    local types = {}
    for t, n in stats.markers do table.insert(types, t) end
    table.sort(types)
    Head('Markers by type')
    for _, t in types do Add(t, stats.markers[t]) end
    return rows
end
