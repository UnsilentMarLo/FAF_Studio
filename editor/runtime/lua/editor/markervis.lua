-- Marker visuals, drawn in the UI lane so they follow the pointer every frame while a marker is dragged: the template's prop mesh
-- (what the GPG editor showed) as a WorldMesh, and for Mass / Hydrocarbon the deposit mesh and the ground splat like the game's own
-- ScenarioUtilities.CreateResources (the splat is a ground decal of the overlay renderer). Called every frame by overlay.lua while editing.
-- (They used to be sim props: every move waited for a sim tick, and moved splats were left behind.)

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
    local e = { shape = (m.prop or '') .. '|' .. tostring(m.type), x = x, y = y, z = z, yaw = yaw, prop = false, deposit = false }
    local pos = Vector(x, y, z)

    local meshName = MeshOf(m.prop)
    if meshName then
        local mesh = WorldMesh()
        mesh:SetMesh({ MeshName = meshName, TextureName = MARKER_ALBEDO, ShaderName = 'EditorMarker', UniformScale = MARKER_SCALE, LODCutoff = LOD_CUTOFF })
        mesh:SetStance(pos, EulerToQuaternion(0, 0, yaw))
        mesh:SetHidden(false)
        e.prop = mesh
    end
    if dep then
        local mesh = WorldMesh()
        mesh:SetMesh({ MeshName = dep.mesh, TextureName = dep.albedo, ShaderName = 'NormalMappedAlpha', UniformScale = dep.scale, LODCutoff = LOD_CUTOFF })
        mesh:SetStance(pos, EulerToQuaternion(0, 0, math.rad(math.mod(NameHash(name), 360))))
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
    if e.prop then e.prop:SetStance(pos, EulerToQuaternion(0, 0, yaw)) end
    if e.deposit then
        e.deposit:SetStance(pos, EulerToQuaternion(0, 0, math.rad(math.mod(NameHash(name), 360))))
        local dep = DEPOSITS[m.type]
        if dep then ed_overlay_decal('sp:' .. name, x, y + 0.05, z, dep.splat, dep.splatSize, 'FFFFFFFF', 0) end
    end
end

--- Drops every marker object (play mode, shutdown).
function Clear()
    for name, e in entries do
        Destroy(e)
        ed_overlay_remove('sp:' .. name)
    end
    entries = {}
    lastDoc = false
end

function Update()
    local doc = Map.Doc
    if not doc then
        return
    end
    if doc ~= lastDoc then
        Clear()
        lastDoc = doc
    end
    local markers = doc.save.MasterChain._MASTERCHAIN_.Markers
    -- a marker stands on the terrain: when the terrain under it changed (brush, undo) its stored height follows
    syncFrame = syncFrame + 1
    if math.mod(syncFrame, 10) == 0 then
        for name, m in markers do
            local px, pz = m.position[1], m.position[3]
            if px and pz and px > -1e6 and px < 1e6 and pz > -1e6 and pz < 1e6 then      -- (NaN fails both tests)
                local ground = ed_terrain_get(math.floor(px + 0.5), math.floor(pz + 0.5))
                if ground and math.abs(ground - m.position[2]) > 0.01 then m.position[2] = ground end
            end
        end
    end
    local Filter = import('/lua/editor/markerfilter.lua')
    for name, m in markers do
        local e = entries[name]
        local hidden = Filter.IsHidden(m.type)       -- marker layers: a hidden category has no prop in the world
        local shape = (m.prop or '') .. '|' .. tostring(m.type)
        if e and (hidden or e.shape ~= shape) then
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
