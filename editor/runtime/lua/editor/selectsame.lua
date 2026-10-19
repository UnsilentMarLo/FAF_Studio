-- "Select the same" (parity audit row "select by type / by group / same blueprint"): from the object that is selected now, selects every object of the same kind.
--
--   Describe()           -> kind, value, text  what Same() would select ('marker type', 'Mass', 'markers of type Mass'), or nil without a selection
--   Same()               selects every marker of that type / prop of that blueprint / unit of that blueprint / decal of that texture; returns the count
--   UnitGroup()          selects every unit of the army group of the selected unit (INITIAL, WAVE1 ...); returns the count
--   Everything(kind)     selects every object of one kind: 'marker' | 'area' | 'unit' | 'prop' | 'decal'; returns the count
--
-- The selection that is looked at is the one of the showing select tool (units, props, decals, else markers and areas). Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local FR = import('/lua/editor/findreplace.lua')

local function Units() return import('/lua/editor/units.lua') end
local function Props() return import('/lua/editor/props.lua') end
local function Decals() return import('/lua/editor/decals.lua') end

local function FirstUnit()
    for _, sel in Units().Selection do
        for _, u in Units().All() do
            if u.army == sel.army and u.name == sel.name then return u end
        end
    end
    return nil
end

function Describe()
    if not Map.Doc then return nil end
    local u = FirstUnit()
    if u then return 'unit blueprint', u.bp, 'units of blueprint ' .. tostring(u.bp) end
    local p = Props().Selection[1]
    if p then return 'prop blueprint', p.bp, 'props of ' .. tostring(string.gsub(string.gsub(tostring(p.bp), '^.*/', ''), '_prop%.bp$', '')) end
    local d = Decals().Selection[1]
    if d then return 'decal texture', d.tex, 'decals of ' .. tostring(string.gsub(tostring(d.tex), '^.*/', '')) end
    for _, it in Tools.Items do
        if it.kind == 'marker' then
            local m = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[it.name]
            if m then return 'marker type', m.type, 'markers of type ' .. tostring(m.type) end
        end
    end
    return nil
end

function Same()
    local kind, value = Describe()
    if not kind then return 0 end
    return FR.Select(kind, value)
end

function UnitGroup()
    local u = FirstUnit()
    if not u then return 0 end
    local U = Units()
    U.Selection = {}
    local n = 0
    for _, e in U.All() do
        if e.army == u.army and e.group == u.group then
            table.insert(U.Selection, { army = e.army, name = e.name })
            n = n + 1
        end
    end
    U.SelRevision = U.SelRevision + 1
    return n
end

function Everything(kind)
    if not Map.Doc then return 0 end
    local n = 0
    if kind == 'marker' or kind == 'area' then
        local list = {}
        if kind == 'marker' then
            for _, name in Map.MarkerNames() do table.insert(list, { kind = 'marker', name = name }) end
        else
            for _, name in Map.AreaNames() do table.insert(list, { kind = 'area', name = name }) end
        end
        Tools.SelectMany(list, false)
        n = table.getn(list)
    elseif kind == 'unit' then
        local U = Units()
        U.Selection = {}
        for _, e in U.All() do table.insert(U.Selection, { army = e.army, name = e.name }) n = n + 1 end
        U.SelRevision = U.SelRevision + 1
    elseif kind == 'prop' then
        local P = Props()
        P.Selection = {}
        for i = 1, ed_prop_count() do
            local bp, x, y, z = ed_prop_get(i)
            table.insert(P.Selection, { bp = bp, x = x, z = z })
            n = n + 1
        end
        P.SelRevision = P.SelRevision + 1
    elseif kind == 'decal' then
        local D = Decals()
        D.Selection = {}
        for i = 1, ed_decal_count() do
            local tex, t1, k, x, y, z = ed_decal_get(i)
            table.insert(D.Selection, { tex = tex, x = x, z = z })
            n = n + 1
        end
        D.SelRevision = D.SelRevision + 1
    end
    return n
end
