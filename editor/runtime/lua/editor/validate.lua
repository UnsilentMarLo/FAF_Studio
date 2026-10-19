-- Resource marker validation: every Mass and Hydrocarbon marker must have room for the structure that goes on it.
--
--   unaligned a resource marker or a structure unit that is off the build grid (grid.lua): the structure would not stand where it is
--             placed, and for markers it would not match the footprint shown in the editor
--   stacked   two resource markers whose structure footprints overlap (they can never both be built)
--   blocked   the structure cannot be built at the marker: the sim's own build check says no (terrain, water, slope, props, ...)
--
-- Stacking is checked here from the unit blueprints' skirt sizes; buildability is asked of the editing sim (simcallbacks.lua,
-- EdValidateBuild) which answers through a small result file. Runs by itself a moment after the markers or the terrain changed
-- (Update, called every frame by overlay.lua) and on demand (Run). Results: Issues (list), ByName (marker name -> 'stacked' |
-- 'blocked'), Revision (bumped when the results change).

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Grid = import('/lua/editor/grid.lua')
local MC = import('/lua/editor/markercheck.lua')

Issues = {}
ByName = {}
Revision = 0
State = 'idle'      -- 'idle' | 'running' | 'done'

local generation = 0
local resultPath = 'ed_validate_result.txt'
local pendingGen = false
local pollFrame = 0
local lastSig = ''
local quiet = 0
local dirty = true
local stackedIssues = {}
local gridIssues = {}
local blockedIssues = {}
local blockedByName = {}
local mapIssues = {}

-- ---- map level checks (start positions, resources, water, props, scenario info) ----------------------------------------------------------------

local function Issue(kind, names, x, z, text)
    return { kind = kind, names = names or {}, x = x or 0, z = z or 0, text = text }
end

--- Checks that do not need the sim: returns a list of issues. kinds: 'map' (what the map lacks), 'start' (a start position), 'water' (under water), 'prop' (a prop problem).
local function CheckMap()
    local issues = {}
    if not Map.Doc then return issues end
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    local w, h = ed_terrain_info()
    local size = (w or 257) - 1
    local waterOn = false
    local waterElev = 0
    local t = ed_world_get and ed_world_get()
    if t then
        waterOn = (t.water_on or 0) ~= 0
        waterElev = t.water_elev or 0
    end
    -- start positions
    local starts, masses, hydros = {}, 0, 0
    local outside, outsidePlay, bad = {}, {}, {}
    local px0, pz0, px1, pz1, hasPlay = import('/lua/editor/playable.lua').Get()
    for name, m in markers do
        if string.find(name, '^ARMY_%d+$') then table.insert(starts, name) end
        if m.type == 'Mass' then masses = masses + 1 elseif m.type == 'Hydrocarbon' then hydros = hydros + 1 end
        local x, z = m.position[1], m.position[3]
        local _, _, _, kind = MC.DisplayPos(m, size, size)
        if kind == 'bad' then
            table.insert(bad, name)
        elseif x < 0 or z < 0 or x > size or z > size then
            table.insert(outside, name)
        elseif hasPlay and (x < px0 or z < pz0 or x > px1 or z > pz1) then
            table.insert(outsidePlay, name)
        elseif waterOn and (m.type == 'Mass' or m.type == 'Hydrocarbon' or string.find(name, '^ARMY_')) and m.position[2] < waterElev then
            table.insert(issues, Issue('water', { name }, x, z, name .. ' is under water (ground ' .. string.format('%.1f', m.position[2]) .. ', water ' .. string.format('%.1f', waterElev) .. ')'))
        end
    end
    -- markers outside the map / the playable area / with broken coordinates: one entry each (a converted map can have thousands); selecting the entry selects them
    local function Group(names, text)
        table.sort(names)
        local first = markers[names[1]].position
        local fx, fz = first[1], first[3]
        if not (fx and fx > -1e6 and fx < 1e6) then fx = 0 end
        if not (fz and fz > -1e6 and fz < 1e6) then fz = 0 end
        local i = Issue('map', names, fx, fz, text)
        return i
    end
    if table.getn(outside) == 1 then
        table.insert(issues, Group(outside, outside[1] .. ' is outside the map (drawn grey at the map edge; Pull inside moves it onto the map)'))
    elseif table.getn(outside) > 1 then
        local i = Group(outside, string.format('%d markers are outside the map (first: %s; drawn grey at the map edge; Pull inside moves them onto the map)', table.getn(outside), outside[1]))
        table.insert(issues, i)
    end
    if table.getn(outside) > 0 then issues[table.getn(issues)].outside = true end
    if table.getn(outsidePlay) > 0 then
        table.insert(issues, Group(outsidePlay, string.format('%d marker(s) outside the playable area AREA_1 (first: %s; drawn grey)', table.getn(outsidePlay), outsidePlay[1])))
    end
    if table.getn(bad) > 0 then
        table.insert(issues, Group(bad, string.format('%d marker(s) with a broken position (NaN or huge; first: %s)', table.getn(bad), bad[1])))
    end
    table.sort(starts)
    if table.getn(starts) == 0 then
        table.insert(issues, Issue('map', {}, size / 2, size / 2, 'the map has no start positions (use the Start position tool)'))
    elseif table.getn(starts) == 1 then
        table.insert(issues, Issue('map', { starts[1] }, markers[starts[1]].position[1], markers[starts[1]].position[3], 'only one start position'))
    end
    -- the scenario's army list against the markers
    local listed = {}
    local std = Map.Doc.info.Configurations and Map.Doc.info.Configurations.standard
    local team = std and std.teams and std.teams[1]
    for _, a in (team and team.armies) or {} do listed[a] = true end
    for _, name in starts do
        if not listed[name] then
            table.insert(issues, Issue('start', { name }, markers[name].position[1], markers[name].position[3], name .. ' is not in the scenario army list yet (saving adds it)'))
        end
    end
    if table.getn(starts) > 0 and masses == 0 then
        table.insert(issues, Issue('map', {}, size / 2, size / 2, 'the map has no mass markers'))
    elseif table.getn(starts) > 0 and masses < table.getn(starts) * 4 then
        table.insert(issues, Issue('map', {}, size / 2, size / 2, string.format('%d mass markers for %d start positions (usually at least 4 each)', masses, table.getn(starts))))
    end
    -- props with a blueprint that does not exist
    local seen = {}
    local missing = {}
    for i = 1, ed_prop_count() do
        local bp, x, y, z = ed_prop_get(i)
        if bp and seen[bp] == nil then
            seen[bp] = (DiskGetFileInfo(bp) ~= nil and DiskGetFileInfo(bp) ~= false)
            if not seen[bp] then missing[bp] = { x, z } end
        end
    end
    for bp, pos in missing do
        table.insert(issues, Issue('prop', {}, pos[1], pos[2], 'prop blueprint not found: ' .. bp))
    end
    -- the army setup (army list against the save file, indices, alliances)
    local okA, problems = pcall(function() return import('/lua/editor/armysetup.lua').Check() end)
    if okA then
        for _, p in problems do
            if p.sev == 'E' or p.sev == 'W' then table.insert(issues, Issue('map', {}, size / 2, size / 2, p.text)) end
        end
    end
    -- the mission (stages, nodes and what they refer to)
    local okM, mproblems = pcall(function() return import('/lua/editor/mission.lua').Check() end)
    if okM then
        for _, p in mproblems do
            if p.sev == 'E' or p.sev == 'W' then table.insert(issues, Issue('map', {}, size / 2, size / 2, 'mission: ' .. p.text)) end
        end
    end
    -- the marker chains (patrol / move orders): too short, dead members
    local okC, cproblems = pcall(function() return import('/lua/editor/chains.lua').Problems() end)
    if okC then
        for _, p in cproblems do table.insert(issues, Issue('chain', p.names, p.x, p.z, p.text)) end
    end
    -- platoon templates, order queues and platoon builders
    local okP, pproblems = pcall(function() return import('/lua/editor/platoons.lua').Problems() end)
    if okP then
        for _, p in pproblems do
            if p.sev == 'E' or p.sev == 'W' then table.insert(issues, Issue('map', {}, size / 2, size / 2, 'platoons: ' .. p.text)) end
        end
    end
    -- the scenario's own information
    local info = Map.Doc.info
    if not info.name or info.name == '' then table.insert(issues, Issue('map', {}, size / 2, size / 2, 'the map has no name (File > Map info)')) end
    if not info.description or info.description == '' then table.insert(issues, Issue('map', {}, size / 2, size / 2, 'the map has no description (File > Map info)')) end
    return issues
end

--- The map level checks (start positions, resources, water, props, scenario information) as a list of issues; also used by the release checks.
function MapIssues()
    return CheckMap()
end

--- Side length of the structure footprint (the skirt) for a resource marker type, from the unit blueprint.
function Size(markerType)
    local info = Grid.ResourceInfo(markerType)
    return info and info.skirt
end

--- The resource markers of the map: list of { name, type, x, z, size }.
function ResourceMarkers()
    local list = {}
    if not Map.Doc then return list end
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        local size = Size(m.type)
        if size then
            table.insert(list, { name = name, type = m.type, x = m.position[1], z = m.position[3], size = size, depositSize = m.size or 1 })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function Publish()
    Issues = {}
    for _, i in mapIssues do table.insert(Issues, i) end
    for _, i in stackedIssues do table.insert(Issues, i) end
    for _, i in blockedIssues do table.insert(Issues, i) end
    for _, i in gridIssues do table.insert(Issues, i) end
    ByName = {}
    for _, i in gridIssues do
        if not i.unit then ByName[i.names[1]] = 'unaligned' end
    end
    for _, i in blockedIssues do ByName[i.names[1]] = 'blocked' end
    for _, i in stackedIssues do
        for _, n in i.names do ByName[n] = 'stacked' end
    end
    Revision = Revision + 1
end

local function CheckStacked(list)
    stackedIssues = {}
    for i = 1, table.getn(list) do
        for j = i + 1, table.getn(list) do
            local a, b = list[i], list[j]
            local reach = (a.size + b.size) / 2
            if math.abs(a.x - b.x) < reach and math.abs(a.z - b.z) < reach then
                table.insert(stackedIssues, {
                    kind = 'stacked', names = { a.name, b.name }, x = (a.x + b.x) / 2, z = (a.z + b.z) / 2,
                    text = string.format('%s and %s are stacked (%.1f apart)', a.name, b.name,
                        math.sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z))),
                })
            end
        end
    end
end

local function Walk(node, depth, visit, path)
    if type(node) ~= 'table' or depth > 8 then return end
    if type(node.type) == 'string' and type(node.Position) == 'table' then
        visit(path, node)
        return
    end
    for key, child in node do
        if type(child) == 'table' then Walk(child, depth + 1, visit, path .. '/' .. tostring(key)) end
    end
end

--- Resource markers and structure units that are off the build grid.
local function CheckAligned(list)
    gridIssues = {}
    for _, r in list do
        if not Grid.IsAligned(r.type, r.x, r.z) then
            local sx, sz = Grid.SnapMarker(r.type, r.x, r.z)
            table.insert(gridIssues, {
                kind = 'unaligned', names = { r.name }, x = r.x, z = r.z,
                text = string.format('%s is off the build grid (%.2f, %.2f; the grid cell centre is %.1f, %.1f)', r.name, r.x, r.z, sx, sz),
            })
        end
    end
    -- structures placed as units of the armies
    if Map.Doc and Map.Doc.save.Armies then
        Walk(Map.Doc.save.Armies, 0, function(path, unit)
            if Grid.IsStructure(unit.type) then
                local fx, fz = Grid.FootprintOf(unit.type)
                local sx, sz = Grid.SnapCentre(unit.Position[1], fx), Grid.SnapCentre(unit.Position[3], fz)
                if math.abs(sx - unit.Position[1]) > 0.02 or math.abs(sz - unit.Position[3]) > 0.02 then
                    table.insert(gridIssues, {
                        kind = 'unaligned', unit = true, names = { path }, x = unit.Position[1], z = unit.Position[3],
                        text = string.format('structure %s (%s) is off the build grid (%.2f, %.2f; cell centre %.1f, %.1f)', path, unit.type,
                            unit.Position[1], unit.Position[3], sx, sz),
                    })
                end
            end
        end, '')
    end
end

--- Moves every unaligned resource marker onto the grid (one undo step). Returns how many moved.
function FixAlignment()
    local names = {}
    for _, i in gridIssues do
        if not i.unit then table.insert(names, i.names[1]) end
    end
    local n = import('/lua/editor/tools.lua').SnapMarkersToGrid(names)
    Run()
    return n
end

--- Moves the markers that stand outside the map onto the nearest point of the map (one undo step). -> how many.
function PullMarkersInside()
    mapIssues = CheckMap()
    local names = {}
    for _, i in mapIssues do
        if i.outside then
            for _, n in i.names do table.insert(names, n) end
        end
    end
    local n = import('/lua/editor/tools.lua').ClampMarkersToMap(names)
    Run()
    return n
end

--- Checks everything now: stacking at once, buildability through the sim (the result arrives within a few frames).
function Run()
    mapIssues = CheckMap()
    local list = ResourceMarkers()
    CheckStacked(list)
    CheckAligned(list)
    dirty = false
    if table.getn(list) == 0 then
        blockedIssues = {}
        State = 'done'
        pendingGen = false
        Publish()
        return
    end
    generation = generation + 1
    pendingGen = generation
    State = 'running'
    local items = {}
    for _, r in list do
        table.insert(items, { name = r.name, type = r.type, x = r.x, z = r.z, size = r.size, depositSize = r.depositSize })
    end
    SimCallback({ Func = 'EdValidateBuild', Args = { items = items, path = resultPath, gen = generation } }, false)
    Publish()
end

local function Poll()
    local text = ed_read_file(resultPath)
    if not text then return end
    local first = true
    local ok = false
    local issues = {}
    local byName = {}
    for line in string.gfind(text, '[^\n]+') do
        if first then
            first = false
            ok = (line == 'gen ' .. tostring(pendingGen))
            if not ok then return end
        else
            local _, _, name, good, reason = string.find(line, '^(.-)|(%d)|(.*)$')
            if name and good == '0' then
                local m = Map.Doc and Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[name]
                table.insert(issues, {
                    kind = 'blocked', names = { name }, x = m and m.position[1] or 0, z = m and m.position[3] or 0,
                    text = name .. ' is blocked: ' .. (reason ~= '' and reason or 'the structure cannot be built here'),
                })
                byName[name] = true
            end
        end
    end
    if ok then
        table.sort(issues, function(a, b) return a.names[1] < b.names[1] end)
        blockedIssues = issues
        blockedByName = byName
        pendingGen = false
        State = 'done'
        Publish()
    end
end

local function Signature()
    local count, acc = 0, 0
    if Map.Doc then
        for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
            if Grid.Structure[m.type] then
                count = count + 1
                acc = acc + m.position[1] * 3.1 + m.position[3] * 7.7 + (m.type == 'Mass' and 1 or 2)
            end
        end
    end
    local undo, redo = History.Depth()
    return string.format('%d|%.2f|%d|%d', count, acc, undo, redo)
end

--- Per-frame: re-validates by itself after the resource markers or the edit history changed and stayed quiet for a moment.
function Update()
    if not Map.Doc then return end
    local sig = Signature()
    if sig ~= lastSig then
        lastSig = sig
        dirty = true
        quiet = 0
    elseif dirty then
        quiet = quiet + 1
        if quiet > 25 then Run() end
    end
    if pendingGen then
        pollFrame = pollFrame + 1
        if math.mod(pollFrame, 8) == 0 then Poll() end
    end
end

function Clear()
    Issues, ByName = {}, {}
    stackedIssues, blockedIssues, gridIssues, mapIssues = {}, {}, {}, {}
    pendingGen = false
    State = 'idle'
    lastSig = ''
    dirty = true
    Revision = Revision + 1
end
