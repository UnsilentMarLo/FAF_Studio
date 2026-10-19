-- Releasing a map: the checks a map must pass before it goes to players, the next free version folder, and the release itself (a complete copy of the map under a new
-- `<stem>.v<N>` folder with `map_version = N` in the scenario file; the working map stays as it is). `scripts/pack_map.py` zips such a folder for the vault.
--
--   Findings()            list of { sev = 'E' | 'W' | 'I', text }: scenario information, start positions, markers, script, army setup, mission, mesh terrain, mods
--   Target()              -> disk folder of the next release, stem, version number
--   Release()             -> folder, version   | nil, reason   (refuses while Findings() has an error)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local Map = import('/lua/editor/map.lua')
local Maps = import('/lua/editor/maps.lua')

local function Dirname(p) return (string.gsub(string.gsub(p, '\\', '/'), '/[^/]*$', '')) end
local function Basename(p) return (string.gsub(string.gsub(p, '\\', '/'), '^.*/', '')) end

function Findings()
    local list = {}
    local function Add(sev, text) table.insert(list, { sev = sev, text = text }) end
    if not Map.Doc then Map.Load() end
    local doc = Map.Doc
    if not doc then Add('E', 'no map is open') return list end
    local info = doc.info
    if not info.name or info.name == '' then Add('E', 'the map has no name (File > Map info)') end
    if not info.description or string.len(info.description) < 10 then Add('W', 'the description is empty or very short (File > Map info)') end
    if not info.type then Add('E', "the scenario has no type (usually 'skirmish')") end
    local w = ed_terrain_info()
    if w and info.size and info.size[1] and info.size[1] ~= w - 1 then Add('E', 'the scenario size ' .. tostring(info.size[1]) .. ' differs from the terrain size ' .. (w - 1)) end

    -- start positions: ARMY_1 .. ARMY_n without gaps
    local numbers = {}
    for name, _ in doc.save.MasterChain._MASTERCHAIN_.Markers do
        local s, _, n = string.find(name, '^ARMY_(%d+)$')
        if s then numbers[tonumber(n)] = true end
    end
    local count = 0
    for _ in numbers do count = count + 1 end
    if count < 2 then Add('E', 'a skirmish map needs at least 2 start positions (it has ' .. count .. ')') end
    for i = 1, count do
        if not numbers[i] then Add('E', 'start positions must be numbered ARMY_1 .. ARMY_' .. count .. ' without gaps: ARMY_' .. i .. ' is missing') break end
    end
    if count > 16 then Add('W', 'more than 16 start positions: the lobby shows 16') end

    -- the script must load
    if doc.scriptPath then
        local disk = ed_vfs_to_disk(doc.scriptPath)
        local text = disk and ed_read_file(disk)
        if text then
            local ok, f, err = pcall(loadstring, text)
            if not ok then err = f f = nil end
            if not f then Add('E', 'the map script does not compile: ' .. tostring(err)) end
        end
    end

    -- what the live validators and the army / mission / mesh checks say
    local okV, Validate = pcall(import, '/lua/editor/validate.lua')
    if okV then
        for _, i in Validate.MapIssues() do
            Add(i.kind == 'prop' and 'E' or 'W', i.text)
        end
        for _, i in Validate.Issues do
            if i.kind ~= 'map' and i.kind ~= 'start' and i.kind ~= 'water' and i.kind ~= 'prop' then Add('W', i.text) end
        end
    end
    if info.TerrainSystem == 'mesh' then
        local Mesh = import('/lua/editor/meshmap.lua')
        local m, why = Mesh.Load()
        if not m then
            Add('E', 'mesh terrain: ' .. tostring(why))
        else
            for _, i in Mesh.Check(m) do
                if i.sev == 'E' then Add('E', 'mesh terrain ' .. i.code .. ': ' .. i.text) end
            end
        end
    end
    local okM, Mods = pcall(import, '/lua/editor/mods.lua')
    if okM then
        local n = 0
        for _ in Mods.GetSelection() do n = n + 1 end
        if n > 0 then Add('W', 'the map was made with ' .. n .. ' mod(s) loaded in the editor: players need them too (the lobby does not enable them for the map)') end
    end
    local _, _, _, _, exists = import('/lua/editor/playable.lua').Get()
    Add('I', exists and 'the map has a playable area (AREA_1)' or 'no playable area: the whole map can be played')
    return list
end

--- Number of errors and warnings of a findings list.
function Count(list)
    local e, w = 0, 0
    for _, i in list do
        if i.sev == 'E' then e = e + 1 elseif i.sev == 'W' then w = w + 1 end
    end
    return e, w
end

local function Exists(path) return ed_file_exists(path) end

--- The folder of the next release: `<maps folder>/<stem>.v<N>` with N one above every version of that stem the game knows or the disk has.
function Target()
    if not Map.Doc then Map.Load() end
    local dir, stem = Maps.saveDir, Maps.saveStem
    stem = stem or Maps.Sanitize(Map.Doc and Map.Doc.info.name or 'my_map')
    local parent
    if dir then
        parent = Dirname(dir)
    else
        local base = Maps.UserMapsDir()
        parent = base and (string.sub(base, -1) == '/' and string.sub(base, 1, -2) or base) or '../mapout'
    end
    local lower = string.lower(stem)
    local escaped = string.gsub(lower, '(%W)', '%%%1')
    local max = 0
    for _, m in Maps.List() do
        local s, _, v = string.find(string.lower(m.folder), '^' .. escaped .. '%.v(%d+)$')
        if s and tonumber(v) > max then max = tonumber(v) end
    end
    local n = max + 1
    while Exists(parent .. '/' .. stem .. '.v' .. string.format('%04d', n) .. '/' .. stem .. '_scenario.lua') do n = n + 1 end
    return parent .. '/' .. stem .. '.v' .. string.format('%04d', n), stem, n
end

function Release()
    local list = Findings()
    local errors = Count(list)
    if errors > 0 then return nil, errors .. ' error(s) to fix first' end
    local dir, stem, n = Target()
    local previous = Map.Doc.info.map_version
    Map.Doc.info.map_version = n
    local scenario, why = Map.SaveAs(dir, stem, { preview = true })
    if not scenario then
        Map.Doc.info.map_version = previous
        return nil, tostring(why)
    end
    -- the working map keeps the version too, so its next release is the next number
    return dir, n
end
