-- The map document: everything of the open map that is not height / texture data.
--
--   Load()                   read `_scenario.lua` + `_save.lua` of the open session into this module
--   markers / areas / props / decals CRUD (props and decals live in the .scmap and go through the natives)
--   SaveAs(diskDir, stem)    write a complete map folder (scmap, scenario, save, script) and mount it
--
-- Markers, areas and armies are plain Lua tables inside `Doc.save` (the `Scenario` table of `_save.lua`);
-- `luaser.lua` writes them back. Nothing here talks to the engine except the ed_* natives and SimCallback.

local Ser = import('/lua/editor/luaser.lua')

Doc = false   -- { info = ScenarioInfo table, save = Scenario table, scenarioPath, savePath, scriptPath }

local function Vec3(x, y, z)
    return { x, y, z, type = 'VECTOR3' }
end
function MakeVec3(x, y, z) return Vec3(x, y, z) end

local function LoadChunk(vfsPath)
    local env = {}
    doscript('/lua/dataInit.lua', env)
    doscript(vfsPath, env)
    return env
end

--- Reads the open session's map files. Returns the document or nil + a reason.
function Load()
    local session = SessionGetScenarioInfo()
    if not session or not session.file then
        return nil, 'no scenario file on the session'
    end
    local scenarioEnv = LoadChunk(session.file)
    local info = scenarioEnv.ScenarioInfo
    if not info then
        return nil, 'scenario file has no ScenarioInfo'
    end
    local saveEnv = {}
    if info.save and DiskGetFileInfo(info.save) then
        saveEnv = LoadChunk(info.save)
    end
    local save = saveEnv.Scenario
    if not save then
        save = {
            next_area_id = '0', Props = {}, Areas = {},
            MasterChain = { _MASTERCHAIN_ = { Markers = {} } },
            Chains = {}, Orders = {}, next_queue_id = '1', Platoons = {}, next_platoon_id = '1',
            next_chain_id = '1', next_marker_id = '1', Armies = {},
        }
    end
    Doc = { info = info, save = save, scenarioPath = session.file, savePath = info.save, scriptPath = info.script }
    pcall(function() import('/lua/editor/maps.lua').ApplyPending(Doc) end)
    pcall(function() import('/lua/editor/terraintype.lua').LoadSidecar(session.file) end)       -- terrain types assigned to texture layers
    pcall(function() import('/lua/editor/mission.lua').LoadSidecar(session.file) end)           -- stages, objectives and actions of a mission map
    pcall(function() import('/lua/editor/mission.lua').ImportScript(Doc) end)                   -- a hand-written mission script (MissionNumber stages) is shown read-only, never rewritten
    pcall(function() import('/lua/editor/graph.lua').LoadSidecar(session.file) end)             -- the terrain graph (nodes, wires, parameters)
    pcall(function() import('/lua/editor/paths.lua').LoadSidecar(session.file) end)             -- spline paths of the terrain tool
    pcall(function() import('/lua/editor/interop.lua').LoadSidecar(session.file) end)           -- import / export settings for external terrain tools
    pcall(function() import('/lua/editor/texsets.lua').ApplyIfNew() end)       -- a new map's empty layers get the default texture set
    if Doc.resizePayload then pcall(function() import('/lua/editor/resize.lua').ApplyPending(Doc) end) end     -- a resized map: heights, masks, props, decals (Map > Resize)
    pcall(function() import('/lua/editor/meshview.lua').OnMapLoaded() end)                      -- mesh terrain of a TerrainSystem = 'mesh' map
    pcall(function() import('/lua/editor/units.lua').SpawnGroupEntities() end)                    -- units of the mission's own groups are shown while editing
    return Doc
end

local function Markers()
    return Doc.save.MasterChain._MASTERCHAIN_.Markers
end

-- ---- markers ------------------------------------------------------------------------------------------------

function AddMarker(name, kind, x, y, z, fields)
    local m = {
        type = kind or 'Blank Marker',
        position = Vec3(x, y, z),
        orientation = Vec3(0, 0, 0),
        color = 'ff800080',
        prop = '/env/common/props/markers/M_Blank_prop.bp',
    }
    -- resource markers need the fields the sim's CreateResourceDeposit reads (size is an integer)
    if m.type == 'Mass' or m.type == 'Hydrocarbon' then
        m.resource = true
        m.amount = (m.type == 'Mass') and 100 or 100
        m.size = 1
        m.editorIcon = (m.type == 'Mass') and '/textures/editor/marker_mass.bmp' or '/textures/editor/marker_hydrocarbon.bmp'
        m.prop = (m.type == 'Mass') and '/env/common/props/markers/M_Mass_prop.bp'
                                     or '/env/common/props/markers/M_Hydrocarbon_prop.bp'
    end
    if fields then
        for k, v in fields do
            m[k] = v
        end
    end
    Markers()[name] = m
    return m
end

function MoveMarker(name, x, y, z)
    local m = Markers()[name]
    if not m then
        return false
    end
    m.position = Vec3(x, y, z)
    return true
end

function RemoveMarker(name)
    if Markers()[name] == nil then
        return false
    end
    Markers()[name] = nil
    return true
end

function MarkerNames()
    local names = {}
    for k, _ in Markers() do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

function GetMarker(name)
    return Markers()[name]
end

-- ---- areas --------------------------------------------------------------------------------------------------

function AddArea(name, x0, z0, x1, z1)
    Doc.save.Areas[name] = { rectangle = { x0, z0, x1, z1, type = 'RECTANGLE' } }
end

function RemoveArea(name)
    if Doc.save.Areas[name] == nil then
        return false
    end
    Doc.save.Areas[name] = nil
    return true
end

function AreaNames()
    local names = {}
    for k, _ in Doc.save.Areas do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

-- ---- armies -------------------------------------------------------------------------------------------------

function ArmyNames()
    local names = {}
    for k, _ in Doc.save.Armies do
        table.insert(names, k)
    end
    table.sort(names)
    return names
end

-- ---- props (scmap list through the natives + the simulation's entity through a callback) -----------------------

local propKey = 0

--- scale: nil (1), one number (uniform) or { sx, sy, sz }. It is stored in the map file's per-prop scale lanes.
function AddProp(blueprint, x, y, z, heading, scale)
    local sx, sy, sz = 1, 1, 1
    if type(scale) == 'table' then
        sx, sy, sz = scale[1], scale[2], scale[3]
    elseif scale then
        sx, sy, sz = scale, scale, scale
    end
    local index = ed_prop_add(blueprint, x, y, z, heading or 0, sx, sy, sz)
    if index then
        propKey = propKey + 1
        SimCallback({ Func = 'EdSpawnProp', Args = { key = 'ed' .. propKey, bp = blueprint, x = x, y = y, z = z,
                                                     heading = heading or 0, sx = sx, sy = sy, sz = sz } }, false)
    end
    return index
end

--- Sets the scale of prop `index` (map data and the entity standing at its place).
function SetPropScale(index, sx, sy, sz)
    sy = sy or sx
    sz = sz or sx
    local bp, x, y, z = ed_prop_get(index)
    if not bp or not ed_prop_scale(index, sx, sy, sz) then
        return false
    end
    SimCallback({ Func = 'EdScalePropAt', Args = { bp = bp, x = x, z = z, sx = sx, sy = sy, sz = sz } }, false)
    return true
end

function RemoveProp(index)
    local bp, x, y, z = ed_prop_get(index)
    if not bp then
        return false
    end
    ed_prop_remove(index)
    SimCallback({ Func = 'EdRemovePropAt', Args = { bp = bp, x = x, z = z } }, false)
    return true
end

-- ---- decals -------------------------------------------------------------------------------------------------

DECAL_TYPES = { albedo = 1, normals = 2, watermask = 3, wateralbedo = 4, waternormals = 5, glow = 6,
                normalsalpha = 7, glowmask = 8, albedoxp = 9 }

function AddDecal(texture, kind, x, y, z, rotY, size, cutoff)
    local t = DECAL_TYPES[kind or 'albedo'] or 1
    size = size or 10
    return ed_decal_add(texture, t, x, y, z, 0, rotY or 0, 0, size, 1, size, cutoff or 1000)
end

function RemoveDecal(index)
    return ed_decal_remove(index)
end

-- ---- save ---------------------------------------------------------------------------------------------------

local HEADER = "--[[                                                                           ]]--\n" ..
               "--[[  Generated by FAF Studio                                                 ]]--\n" ..
               "--[[                                                                           ]]--\n" ..
               "--[[                                                                           ]]--\n" ..
               "--[[  Scenario                                                                 ]]--\n" ..
               "--[[                                                                           ]]--\n"

local function Basename(path)
    local base = string.gsub(path, '\\', '/')
    base = string.gsub(base, '/+$', '')
    return string.gsub(base, '^.*/', '')
end

--- Writes a complete map folder under `diskDir` (created if needed), mounts it at /maps/<folder> and returns
--- the scenario file's virtual path, ready for control.LoadMap(). `stem` is the file name stem.
--- Writes the map. An environment preview (envlib.lua: a look or theme being tried) is taken off while the files are written and put back afterwards: a saved map never carries it.
function SaveAs(diskDir, stem, opts)
    local resume = false
    pcall(function() resume = import('/lua/editor/envlib.lua').SuspendPreviews() end)
    local scenario, why = SaveAsCore(diskDir, stem, opts)
    if resume then pcall(resume) end
    return scenario, why
end

--- The game looks the environment cube of every model up by name and falls back to the `<default>` entry; a map without that entry crashes the game at tick 0 (ACCESS_VIOLATION in
--- CWldTerrainRes::GetEnvLookup, which copies the texture of the end of an empty lookup). The blank templates had no entry at all: every map is given one before it is written.
function EnsureDefaultEnvCube()
    if not (rawget(_G, 'ed_env_lookups') and rawget(_G, 'ed_env_set_lookups')) then return end
    local ok, flat = pcall(ed_env_lookups)
    if not ok or type(flat) ~= 'table' then return end
    for i = 1, table.getn(flat), 2 do
        if flat[i] == '<default>' then return end
    end
    table.insert(flat, '<default>')
    table.insert(flat, '/textures/environment/defaultenvcube.dds')
    pcall(ed_env_set_lookups, flat)
end

function SaveAsCore(diskDir, stem, opts)
    if not Doc then
        local d, why = Load()
        if not d then
            return nil, why
        end
    end
    diskDir = string.gsub(diskDir, '\\', '/')
    diskDir = string.gsub(diskDir, '/+$', '')
    local mount = '/maps/' .. string.lower(Basename(diskDir))
    local vfs = mount .. '/' .. stem
    pcall(function() import('/lua/editor/armies.lua').Sync(Doc) end)       -- the army list follows the start position markers

    -- scenario info points at the new files
    local info = {}
    for k, v in Doc.info do
        info[k] = v
    end
    info.file = nil           -- set by the loader, never stored
    info.map = vfs .. '.scmap'
    info.save = vfs .. '_save.lua'
    info.script = vfs .. '_script.lua'
    pcall(function() import('/lua/editor/mission.lua').PrepareArmies() end)
    pcall(function() info.type = import('/lua/editor/mission.lua').ScenarioType(info.type) end)       -- coop and both-mode missions are campaign_coop
    if info.TerrainMesh then info.TerrainMesh = mount .. '/terrain/terrain.lua' end       -- mesh terrain maps name their manifest by folder

    -- script: keep the original text when there is one
    local script = nil
    if Doc.scriptPath then
        local disk = ed_vfs_to_disk(Doc.scriptPath)
        if disk then
            script = ed_read_file(disk)
        end
    end
    if not script then
        script = "local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')\n\n" ..
                 "function OnPopulate()\n    ScenarioUtils.InitializeArmies()\nend\n\nfunction OnStart(self)\nend\n"
    end
    local patched = import('/lua/editor/mission.lua').PatchScript(script)       -- the generated mission region (when the map has stages)
    script = patched
    if not import('/lua/editor/mission.lua').IsImported() then       -- (the script of an imported hand-written mission is not edited behind the user's back)
        script = import('/lua/editor/playable.lua').PatchScript(script)       -- AREA_1 is applied as the playable area
    end

    EnsureDefaultEnvCube()
    if not ed_map_save(diskDir .. '/' .. stem .. '.scmap') then
        return nil, 'ed_map_save failed'
    end
    if opts and opts.preview then
        -- the lobby picture inside the .scmap: a top-down render of the map (preview.lua)
        local ok, res, why = pcall(function() return import('/lua/editor/preview.lua').Apply(diskDir .. '/' .. stem .. '.scmap') end)
        if not ok or not res then LOG('EDITOR map preview not written: ' .. tostring(ok and why or res)) end
    end
    local ok = ed_write_file(diskDir .. '/' .. stem .. '_scenario.lua',
                             Ser.ScenarioChunk(info))
    ok = ed_write_file(diskDir .. '/' .. stem .. '_save.lua', HEADER .. Ser.Chunk({ { 'Scenario', Doc.save } })) and ok
    ok = ed_write_file(diskDir .. '/' .. stem .. '_script.lua', script) and ok
    if info.TerrainMesh then
        local copied, why = import('/lua/editor/meshmap.lua').CopyTerrain(diskDir)
        if not copied then LOG('EDITOR mesh terrain not copied: ' .. tostring(why)) ok = false end
    end
    ok = ed_write_file(diskDir .. '/' .. stem .. '_editor.lua', import('/lua/editor/mods.lua').SidecarText()) and ok
    if not ok then
        return nil, 'writing the map files failed'
    end
    ed_vfs_mount(diskDir, mount)
    return vfs .. '_scenario.lua'
end
