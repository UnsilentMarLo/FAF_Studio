-- Marker visuals, drawn in the UI lane so they follow the pointer every frame while a marker is dragged: the template's prop mesh
-- (what the GPG editor showed) as a WorldMesh, except for Mass / Hydrocarbon, which show what the game shows instead: the deposit mesh (the little rock) and the
-- ground splat of ScenarioUtilities.CreateResources (the splat is a ground decal of the overlay renderer, laid onto the terrain). Called every frame by overlay.lua
-- while editing. (They used to be sim props: every move waited for a sim tick, and moved splats were left behind.)
-- The game makes its own copy of the rock and the splat when a map loads; they cannot be moved or removed afterwards, so the editing sim does not make them
-- (schook/lua/sim/scenarioutilities.lua CreateResources) and a test run gets them for the markers as they are then (simcallbacks.lua EdSetPlay, DepositList below):
-- there is exactly one representation of a resource marker at any time.

local Map = import('/lua/editor/map.lua')
local MC = import('/lua/editor/markercheck.lua')
local WorldMesh = import('/lua/ui/controls/worldmesh.lua').WorldMesh

local MARKER_ALBEDO = '/env/common/props/marker01_albedo.dds'
local MARKER_SCALE = 0.05          -- UniformScale of the M_*_prop blueprints
local LOD_CUTOFF = 400

-- from massDeposit01_prop.bp / hydrocarbonDeposit01_prop.bp
local DEPOSITS = {
    Mass = {
        mesh = '/env/common/props/massDeposit01_lod0.scm', albedo = '/env/common/props/massDeposit01_albedo.dds',
        scale = 0.06, splat = '/env/common/splats/mass_marker.dds', splatSize = 2,
    },
    Hydrocarbon = {
        mesh = '/env/common/props/hydrocarbonDeposit01_lod0.scm', albedo = '/env/common/props/hydrocarbonDeposit01_albedo.dds',
        scale = 0.4, splat = '/env/common/splats/hydrocarbon_marker.dds', splatSize = 6,
    },
}

local entries = {}      -- marker name -> { shape, x, y, z, yaw, prop = WorldMesh | false, deposit = WorldMesh | false }
local lastDoc = false
local syncFrame = 0
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')
local Tools = import('/lua/editor/tools.lua')
local syncedEpoch, seenChanged = -1, -1      -- what the last height sync and the last walk over the markers were done for
local ended = false      -- Shutdown ran: the session is ending, nothing is built any more

--- '/env/common/props/markers/M_Mass_prop.bp' -> '/env/common/props/markers/M_Mass_lod0.scm' (false for the mesh-less path marker).
local function MeshOf(propBp)
    if not propBp or string.find(propBp, 'M_Path_prop', 1, true) then return false end
    local mesh = string.gsub(propBp, '_prop%.bp$', '_lod0.scm')
    return mesh
end

local function NameHash(name)
    local h = 0
    for i = 1, string.len(name) do
        h = math.mod(h * 31 + string.byte(name, i), 100003)
    end
    return h
end

local function Destroy(e)
    if e.prop then e.prop:Destroy() end
    if e.deposit then e.deposit:Destroy() end
end

local function Build(name, m)
    local x, y, z = MC.DisplayPos(m)
    local yaw = (m.orientation and m.orientation[2]) or 0
    local dep = DEPOSITS[m.type]
    local e = { shapeProp = m.prop, shapeType = m.type, x = x, y = y, z = z, yaw = yaw, prop = false, deposit = false }
    local pos = Vector(x, y, z)

    local meshName = MeshOf(m.prop)
    if meshName and not dep then          -- a resource marker is its deposit mesh and splat, no marker prop on top
        local mesh = WorldMesh()
        mesh:SetMesh({ MeshName = meshName, TextureName = MARKER_ALBEDO, ShaderName = 'EditorMarker', UniformScale = MARKER_SCALE, LODCutoff = LOD_CUTOFF })
        mesh:SetStance(pos, EulerToQuaternion(0, yaw, 0))
        mesh:SetHidden(false)
        e.prop = mesh
    end
    if dep then
        local mesh = WorldMesh()
        mesh:SetMesh({ MeshName = dep.mesh, TextureName = dep.albedo, ShaderName = 'NormalMappedAlpha', UniformScale = dep.scale, LODCutoff = LOD_CUTOFF })
        mesh:SetStance(pos, EulerToQuaternion(0, math.rad(math.mod(NameHash(name), 360)), 0))
        mesh:SetHidden(false)
        e.deposit = mesh
        ed_overlay_decal('sp:' .. name, x, y + 0.05, z, dep.splat, dep.splatSize, 'FFFFFFFF', 0)
    end
    entries[name] = e
end

local function Move(name, e, m)
    local x, y, z = MC.DisplayPos(m)
    local yaw = (m.orientation and m.orientation[2]) or 0
    if x == e.x and y == e.y and z == e.z and yaw == e.yaw then return end
    e.x, e.y, e.z, e.yaw = x, y, z, yaw
    local pos = Vector(x, y, z)
    if e.prop then e.prop:SetStance(pos, EulerToQuaternion(0, yaw, 0)) end
    if e.deposit then
        e.deposit:SetStance(pos, EulerToQuaternion(0, math.rad(math.mod(NameHash(name), 360)), 0))
        local dep = DEPOSITS[m.type]
        if dep then ed_overlay_decal('sp:' .. name, x, y + 0.05, z, dep.splat, dep.splatSize, 'FFFFFFFF', 0) end
    end
end

local ghosts = {}          -- pool of WorldMesh: the previews of the Start position tool (see Ghost)
local ghostMesh = false       -- the mesh the pool was made for
local ghostShown = 0

--- The prop of a marker about to be placed, at each { x, y, z } of `spots` (the Start position tool: pointer and symmetry images); nil or an empty list hides them.
--- `propBp` is the template's prop blueprint path, as a placed marker's `prop` field.
function Ghost(spots, propBp)
    if ended then return end
    local n = spots and table.getn(spots) or 0
    local meshName = n > 0 and MeshOf(propBp)
    if n == 0 or not meshName then
        if ghostShown > 0 then
            for i = 1, table.getn(ghosts) do ghosts[i]:SetHidden(true) end
            ghostShown = 0
        end
        return
    end
    if ghostMesh ~= meshName then
        for i = 1, table.getn(ghosts) do ghosts[i]:Destroy() end
        ghosts = {}
        ghostMesh = meshName
    end
    for i = 1, n do
        local g = ghosts[i]
        if not g then
            g = WorldMesh()
            g:SetMesh({ MeshName = meshName, TextureName = MARKER_ALBEDO, ShaderName = 'EditorMarker', UniformScale = MARKER_SCALE, LODCutoff = LOD_CUTOFF })
            ghosts[i] = g
        end
        g:SetStance(Vector(spots[i][1], spots[i][2], spots[i][3]), EulerToQuaternion(0, 0, 0))
        g:SetHidden(false)
    end
    for i = n + 1, table.getn(ghosts) do ghosts[i]:SetHidden(true) end
    ghostShown = n
end

--- The resource markers of the document as { type, x, y, z } (Mass / Hydrocarbon): what a test run needs to create the deposit props and splats the editing sim
--- left out (ui.lua SetMode sends them with EdSetPlay).
function DepositList()
    local list = {}
    local doc = Map.Doc
    if not doc then return list end
    for _, m in doc.save.MasterChain._MASTERCHAIN_.Markers do
        if DEPOSITS[m.type] and m.position then
            table.insert(list, { type = m.type, x = m.position[1], y = m.position[2], z = m.position[3] })
        end
    end
    return list
end

--- Drops every marker object (play mode, shutdown).
function Clear()
    for name, e in entries do
        Destroy(e)
        ed_overlay_remove('sp:' .. name)
    end
    entries = {}
    lastDoc = false
    syncedEpoch, seenChanged = -1, -1
    for i = 1, table.getn(ghosts) do ghosts[i]:Destroy() end
    ghosts, ghostMesh, ghostShown = {}, false, 0
end

--- The session is ending (control.lua Teardown: another map is opened, the editor leaves): destroys every mesh and splat and builds no more. A WorldMesh is an engine object that
--- keeps its Lua table alive itself, so it is NOT freed when this module is dropped with the Lua modules of the next session (uimain.lua): without Destroy the rocks of the
--- previous map's resource markers stayed in the world of the next one, at their old heights.
function Shutdown()
    Clear()
    ended = true
end

--- Takes the editor back into use after Shutdown (the self test only: a real session that shut down is replaced).
function Resume()
    ended = false
end

--- How many marker objects (resource meshes, marker props, ghosts) are alive: { entries, meshes }.
function Count()
    local n, meshes = 0, 0
    for _, e in entries do
        n = n + 1
        if e.prop then meshes = meshes + 1 end
        if e.deposit then meshes = meshes + 1 end
    end
    return n, meshes + table.getn(ghosts)
end

function Update()
    if ended then return end
    local doc = Map.Doc
    if not doc then
        return
    end
    if doc ~= lastDoc then
        Clear()
        lastDoc = doc
    end
    local markers = doc.save.MasterChain._MASTERCHAIN_.Markers
    -- a marker stands on the terrain: when the terrain under it changed (brush, undo) its stored height follows. That is one terrain read per marker, so it is done when the
    -- ground may have changed (TerrainEpoch: a finished stroke, an undo; at the latest every 5 s) and every 2 s, not ten times a second.
    syncFrame = syncFrame + 1
    local synced = false
    if syncedEpoch ~= TerrainEpoch.Epoch or math.mod(syncFrame, 120) == 0 then
        syncedEpoch = TerrainEpoch.Epoch
        synced = true
        for name, m in markers do
            local px, pz = m.position[1], m.position[3]
            if px and pz and px > -1e6 and px < 1e6 and pz > -1e6 and pz < 1e6 then      -- (NaN fails both tests)
                local ground = ed_terrain_get(math.floor(px + 0.5), math.floor(pz + 0.5))
                if ground and math.abs(ground - m.position[2]) > 0.01 then m.position[2] = ground end
            end
        end
    end
    -- The meshes are brought in line with the markers when the objects changed (Tools.Changed: a move, a type, a layer switch), when heights were synced, and about once a
    -- second as a net for an edit that does not announce itself. A frame in which nothing happened costs nothing (it walked every marker and built a string for each, every frame).
    local changed = Tools.Changed
    if not synced and changed == seenChanged and math.mod(syncFrame, 60) ~= 0 then
        return
    end
    seenChanged = changed
    local Filter = import('/lua/editor/markerfilter.lua')
    for name, m in markers do
        local e = entries[name]
        local hidden = Filter.IsHidden(m.type)       -- marker layers: a hidden category has no prop in the world
        if e and (hidden or e.shapeProp ~= m.prop or e.shapeType ~= m.type) then
            Destroy(e)
            ed_overlay_remove('sp:' .. name)
            entries[name] = nil
            e = nil
        end
        if hidden then
            -- nothing to show
        elseif e then
            Move(name, e, m)
        else
            Build(name, m)
        end
    end
    for name, e in entries do
        if markers[name] == nil then
            Destroy(e)
            ed_overlay_remove('sp:' .. name)
            entries[name] = nil
        end
    end
end
