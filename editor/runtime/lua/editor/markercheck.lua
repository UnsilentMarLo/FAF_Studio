-- Where the markers of a map stand relative to the map and the terrain (the "markers in the void / in the air" findings).
--
--   Analyse(markers, sizeX, sizeZ, playable, ground [, opts]) -> stats
--       markers   name -> marker table (position = { x, y, z })
--       playable  { x0, z0, x1, z1 } or nil
--       ground    function(x, z) -> terrain height or nil (nil outside the terrain); may be nil (then no height checks)
--       stats     { total, outsideMap, outsidePlayable, above, below, nonFinite, names = { outsideMap = {...}, ... }, maxAbove, maxBelow }
--   opts.heightTol (default 3): a marker further than this from the ground counts as above / below
--   opts.limit (default 20): names kept per category
--
--   Categories (a marker is in the first that applies): nonFinite (NaN / huge), outsideMap (x or z outside 0..size), outsidePlayable (inside the map, outside the
--   playable area), then above / below (height difference to the terrain beyond the tolerance).
--
--   DisplayPos(m [, sizeX, sizeZ]) -> x, y, z, kind: where the editor draws a marker. A marker outside the map is drawn at the terrain height of the nearest map
--       edge point (its stored height means nothing there: it hung in the air), kind = 'map'; a marker with NaN / huge coordinates is drawn at the map corner
--       (kind = 'bad'); other markers are drawn at their stored position (their height follows the terrain, markervis.lua), kind = nil.
--   Survey(scenarioPath [, opts]) -> stats of a map's save file without opening it (size from the scenario, playable area AREA_1, no height checks), plus
--       sizeX, sizeZ, minY, maxY; SurveyAll(outPath [, filter]) writes one line per map of the maps folders (path|size|total|outsideMap|outsidePlayable|minY|maxY)
--   SnapY(markers, names, ground) -> number moved: sets y to the ground height for the named markers (those outside the terrain are skipped).
--
-- Lua 5.0 dialect.

local MeshView = import('/lua/editor/meshview.lua')

local function Finite(v)
    return v ~= nil and v == v and v > -1e7 and v < 1e7
end

function Analyse(markers, sizeX, sizeZ, playable, ground, opts)
    opts = opts or {}
    local tol = opts.heightTol or 3
    local limit = opts.limit or 20
    local st = { total = 0, outsideMap = 0, outsidePlayable = 0, above = 0, below = 0, nonFinite = 0, maxAbove = 0, maxBelow = 0,
                 names = { outsideMap = {}, outsidePlayable = {}, above = {}, below = {}, nonFinite = {} } }
    local function Note(kind, name)
        st[kind] = st[kind] + 1
        local list = st.names[kind]
        if table.getn(list) < limit then table.insert(list, name) end
    end
    for name, m in markers do
        local p = m.position
        st.total = st.total + 1
        if not (p and Finite(p[1]) and Finite(p[2]) and Finite(p[3])) then
            Note('nonFinite', name)
        else
            local x, y, z = p[1], p[2], p[3]
            if x < 0 or z < 0 or x > sizeX or z > sizeZ then
                Note('outsideMap', name)
            elseif playable and (x < playable[1] or z < playable[2] or x > playable[3] or z > playable[4]) then
                Note('outsidePlayable', name)
            elseif ground then
                local g = ground(x, z)
                if g then
                    local d = y - g
                    if d > tol then
                        Note('above', name)
                        if d > st.maxAbove then st.maxAbove = d end
                    elseif d < -tol then
                        Note('below', name)
                        if -d > st.maxBelow then st.maxBelow = -d end
                    end
                end
            end
        end
    end
    return st
end

--- The sizes of the open map's terrain in world units.
local function TerrainSize()
    local w, h = ed_terrain_info()
    return (w or 257) - 1, (h or 257) - 1
end

function DisplayPos(m, sizeX, sizeZ)
    local p = m.position
    if not sizeX then sizeX, sizeZ = TerrainSize() end
    if not (p and Finite(p[1]) and Finite(p[2]) and Finite(p[3])) then
        return 0, ed_terrain_get(0, 0) or 0, 0, 'bad'
    end
    local x, y, z = p[1], p[2], p[3]
    if x < 0 or z < 0 or x > sizeX or z > sizeZ then
        local cx, cz = math.max(0, math.min(sizeX, x)), math.max(0, math.min(sizeZ, z))
        return x, ed_terrain_get(math.floor(cx + 0.5), math.floor(cz + 0.5)) or y, z, 'map'
    end
    -- the sim's height (the stored one) is the height field's; on a mesh map the marker is drawn on the visible ground
    return x, MeshView.GroundAt(x, z, y), z, nil
end

--- Sets the height of the named markers to the terrain height under them. -> how many were changed.
function SnapY(markers, names, ground)
    local n = 0
    for _, name in names do
        local m = markers[name]
        local p = m and m.position
        if p and Finite(p[1]) and Finite(p[3]) then
            local g = ground(p[1], p[3])
            if g and (not Finite(p[2]) or math.abs(p[2] - g) > 0.01) then
                p[2] = g
                n = n + 1
            end
        end
    end
    return n
end

-- ---- surveys of map files ---------------------------------------------------------------------------------------------------------------------

local function LoadChunk(vfsPath)
    local env = {}
    doscript('/lua/dataInit.lua', env)
    doscript(vfsPath, env)
    return env
end

function Survey(scenarioPath, opts)
    local info = LoadChunk(scenarioPath).ScenarioInfo
    if not info then return nil, 'no ScenarioInfo' end
    local sx, sz = 0, 0
    if info.size then sx, sz = info.size[1], info.size[2] end
    local save
    if info.save and DiskGetFileInfo(info.save) then save = LoadChunk(info.save).Scenario end
    local chain = save and save.MasterChain and save.MasterChain._MASTERCHAIN_
    local markers = chain and chain.Markers or {}
    local play
    local a = save and save.Areas and save.Areas.AREA_1
    if a and a.rectangle then play = { a.rectangle[1], a.rectangle[2], a.rectangle[3], a.rectangle[4] } end
    local st = Analyse(markers, sx, sz, play, nil, opts)
    st.sizeX, st.sizeZ = sx, sz
    for _, m in markers do
        local y = m.position and m.position[2]
        if Finite(y) then
            if not st.minY or y < st.minY then st.minY = y end
            if not st.maxY or y > st.maxY then st.maxY = y end
        end
    end
    return st
end

local NL = string.char(10)

function SurveyAll(outPath, filter)
    local rows = {}
    local files = DiskFindFiles('/maps', '*_scenario.lua') or {}
    table.sort(files)
    for _, f in files do
        if not filter or string.find(f, filter, 1, true) then
            local ok, st = pcall(Survey, f, { limit = 3 })
            if ok and st then
                table.insert(rows, string.format('%s|%d|%d|%d|%d|%s|%s', f, st.sizeX, st.total, st.outsideMap, st.outsidePlayable, tostring(st.minY), tostring(st.maxY)))
            else
                table.insert(rows, f .. '|ERR|' .. tostring(st))
            end
        end
    end
    if outPath then ed_write_file(outPath, table.concat(rows, NL)) end
    return rows
end
