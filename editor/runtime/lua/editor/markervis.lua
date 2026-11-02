-- Marker visuals, drawn in the UI lane so they follow the pointer every frame while a marker is dragged: the template's prop mesh
-- (what the GPG editor showed) as a WorldMesh, chosen by marker TYPE and tinted by the type's colour (Style below), except for Mass / Hydrocarbon, which show what the game shows instead: the deposit mesh (the little rock) and the
-- ground splat of ScenarioUtilities.CreateResources (the splat is a ground decal of the overlay renderer, laid onto the terrain). Called every frame by overlay.lua
-- while editing. (They used to be sim props: every move waited for a sim tick, and moved splats were left behind.)
-- The game makes its own copy of the rock and the splat when a map loads; they cannot be moved or removed afterwards, so the editing sim does not make them
-- (schook/lua/sim/scenarioutilities.lua CreateResources) and a test run gets them for the markers as they are then (simcallbacks.lua EdSetPlay, DepositList below):
-- there is exactly one representation of a resource marker at any time.

local Map = import('/lua/editor/map.lua')
local MC = import('/lua/editor/markercheck.lua')
local MeshView = import('/lua/editor/meshview.lua')
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
local syncAt, netAt = 0, 0      -- clock of the last height sync (2 s net) and of the last full look at the markers (1 s net): clocks, not frame counts (an unlimited frame rate ran the nets 5 times as often)
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')
local Tools = import('/lua/editor/tools.lua')
local syncedEpoch, seenChanged = -1, -1      -- what the last height sync and the last walk over the markers were done for
local filterMod = false
local Sig = import('/lua/editor/markersig.lua')
local fullAt, sigA, sigB, sigC = 0, 0, 0, 0              -- the clock of the last full walk over the markers, and the fingerprint of the positions it saw
local Perf = import('/lua/editor/perf.lua')
local SYNC_SLICE = 400                      -- markers whose height is synced per frame
local syncMoved = false                      -- a height moved in the pass under way
local syncNames, syncN, syncPos = {}, 0, 0   -- the names of the pass under way, how many, the next one (0: no pass)
local ended = false      -- Shutdown ran: the session is ending, nothing is built any more

--- '/env/common/props/markers/M_Mass_prop.bp' -> '/env/common/props/markers/M_Mass_lod0.scm' (false for the mesh-less path marker).
local function MeshOf(propBp)
    if not propBp or string.find(propBp, 'M_Path_prop', 1, true) then return false end
    local mesh = string.gsub(propBp, '_prop%.bp$', '_lod0.scm')
    return mesh
end

-- ---- what a marker looks like, by type --------------------------------------------------------------------------------------------------------
-- Most saved markers carry the blank prop whatever their type (many FAF maps store only type, position and colour), so the stored `prop` cannot say what a marker is. The look is
-- chosen by TYPE from this table (display only, nothing is written back to the save data): prop = the game's marker mesh, scale = factor on the blueprints' UniformScale
-- (MARKER_SCALE), color = tint (default: the type's colour in /lua/MarkerTemplates.lua, shown through Tools.Templates). Game data has meshes for Blank, Camera, Combatzone, Defensive,
-- Expansion, Mass and Hydrocarbon only (M_Path has none: path nodes are drawn by the overlay); the types sharing a mesh differ by tint and size.
-- A type that is not in the table (a mod's) takes the stored prop, then its template's prop, then the blank marker.
local PROPS = '/env/common/props/markers/M_'
local BLANK_PROP = PROPS .. 'Blank_prop.bp'
local STYLES = {
    ['Blank Marker']                        = { prop = 'Blank', scale = 1.0 },
    ['Mass']                                = { prop = 'Mass', scale = 1.0 },
    ['Hydrocarbon']                         = { prop = 'Hydrocarbon', scale = 1.0 },
    ['Combat Zone']                         = { prop = 'Combatzone', scale = 1.4 },
    ['Island']                              = { prop = 'Combatzone', scale = 1.1 },
    ['Naval Exclude']                       = { prop = 'Combatzone', scale = 0.9 },
    ['Defensive Point']                     = { prop = 'Defensive', scale = 1.0 },
    ['Naval Defensive Point']               = { prop = 'Defensive', scale = 1.0 },
    ['Rally Point']                         = { prop = 'Defensive', scale = 0.8 },
    ['Naval Rally Point']                   = { prop = 'Defensive', scale = 0.8 },
    ['Effect']                              = { prop = 'Defensive', scale = 0.6 },
    ['Weather Definition']                  = { prop = 'Defensive', scale = 1.3 },
    ['Weather Generator']                   = { prop = 'Defensive', scale = 1.6 },
    ['Expansion Area']                      = { prop = 'Expansion', scale = 1.0 },
    ['Large Expansion Area']                = { prop = 'Expansion', scale = 1.7 },
    ['Naval Area']                          = { prop = 'Expansion', scale = 1.0 },
    ['Protected Experimental Construction'] = { prop = 'Expansion', scale = 1.3 },
    ['Camera Info']                         = { prop = 'Camera', scale = 1.0 },
    ['Transport Marker']                    = { prop = 'Blank', scale = 1.3 },
    ['Naval Link']                          = { prop = 'Blank', scale = 0.8 },
    ['Land Path Node']                      = { prop = 'Path', scale = 1.0 },
    ['Water Path Node']                     = { prop = 'Path', scale = 1.0 },
    ['Air Path Node']                       = { prop = 'Path', scale = 1.0 },
    ['Amphibious Path Node']                = { prop = 'Path', scale = 1.0 },
}
local ARMY_STYLE = { prop = 'Blank', scale = 1.8, color = 'ffffd040' }      -- start positions (ARMY_<n>: Blank Marker type, told apart by name)
local TINT_BOOST = 1.5          -- the templates' colours are half intensity (0x80): the lit mesh would look dull on the terrain
local FALLBACK_COLOR = 'ff808080'

local function IsBlankProp(propBp)
    return not propBp or propBp == '' or string.find(string.lower(propBp), 'm_blank_prop', 1, true) ~= nil
end

--- 'ffRRGGBB' (or 'RRGGBB') brightened by TINT_BOOST, as 'ffRRGGBB'.
local function Tint(argb)
    local s = argb or FALLBACK_COLOR
    local hex = string.sub(s, -6)
    local r, g, b = tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16)
    if not (r and g and b) then return FALLBACK_COLOR end
    return string.format('ff%02x%02x%02x', math.min(255, math.floor(r * TINT_BOOST)), math.min(255, math.floor(g * TINT_BOOST)), math.min(255, math.floor(b * TINT_BOOST)))
end

--- The look of a marker: { prop = prop blueprint path (MeshOf turns it into the mesh), scale = UniformScale, color = 'ffRRGGBB' tint }. `markerType` / `storedProp` / `storedColor`
--- are the marker's own fields, `markerName` its name (start positions are told by ARMY_<n>). Never nil; the fields of a marker are not changed.
function Style(markerType, storedProp, storedColor, markerName)
    local st = STYLES[markerType]
    if markerName and string.find(markerName, '^ARMY_%d+$') and (not st or st.prop == 'Blank') then st = ARMY_STYLE end
    local tpl = Tools.Templates()[markerType]
    local prop, factor, color = false, 1.0, false
    if st then
        prop = PROPS .. st.prop .. '_prop.bp'
        factor = st.scale or 1.0
        color = st.color
    end
    if not prop and not IsBlankProp(storedProp) then prop = storedProp end
    if not prop and tpl and tpl.prop then prop = tpl.prop end
    if not prop then prop = BLANK_PROP end
    color = color or (tpl and tpl.color) or storedColor or FALLBACK_COLOR
    return { prop = prop, scale = MARKER_SCALE * factor, color = Tint(color) }
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

local function Build(name, m, sizeX, sizeZ)
    local x, y, z = MC.DisplayPos(m, sizeX, sizeZ)
    local yaw = (m.orientation and m.orientation[2]) or 0
    local dep = DEPOSITS[m.type]
    local e = { shapeProp = m.prop, shapeType = m.type, x = x, y = y, z = z, yaw = yaw, prop = false, deposit = false }
    local pos = Vector(x, y, z)

    local style = Style(m.type, m.prop, m.color, name)
    local meshName = MeshOf(style.prop)
    if meshName and not dep then          -- a resource marker is its deposit mesh and splat, no marker prop on top
        local mesh = WorldMesh()
        mesh:SetMesh({ MeshName = meshName, TextureName = MARKER_ALBEDO, ShaderName = 'EditorMarker', UniformScale = style.scale, Color = style.color, LODCutoff = LOD_CUTOFF })
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

local function Move(name, e, m, sizeX, sizeZ)
    local x, y, z, kind = MC.DisplayPos(m, sizeX, sizeZ)
    e.outside = kind ~= nil
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
local ghostMesh = false       -- what the pool was made for: mesh, scale and tint
local ghostShown = 0

--- The prop of a marker about to be placed, at each { x, y, z } of `spots` (the Start position tool: pointer and symmetry images); nil or an empty list hides them.
--- `propBp` is the template's prop blueprint path, as a placed marker's `prop` field; `markerType` / `markerName` (optional) give the look the marker will have once placed (Style).
function Ghost(spots, propBp, markerType, markerName)
    if ended then return end
    local n = spots and table.getn(spots) or 0
    local style = n > 0 and Style(markerType, propBp, nil, markerName)
    local meshName = style and MeshOf(style.prop)
    if n == 0 or not meshName then
        if ghostShown > 0 then
            for i = 1, table.getn(ghosts) do ghosts[i]:SetHidden(true) end
            ghostShown = 0
        end
        return
    end
    local key = meshName .. '|' .. style.scale .. '|' .. style.color
    if ghostMesh ~= key then
        for i = 1, table.getn(ghosts) do ghosts[i]:Destroy() end
        ghosts = {}
        ghostMesh = key
    end
    for i = 1, n do
        local g = ghosts[i]
        if not g then
            g = WorldMesh()
            g:SetMesh({ MeshName = meshName, TextureName = MARKER_ALBEDO, ShaderName = 'EditorMarker', UniformScale = style.scale, Color = style.color, LODCutoff = LOD_CUTOFF })
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
    syncPos = 0
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
    local clock = GetSystemTimeSeconds()
    local synced = false
    -- The pass is cut into slices of SYNC_SLICE markers, one slice per frame: 3000 terrain reads in one frame were a 3-5 ms hitch every 2 s. It starts when the ground may
    -- have changed or after 2 s and the meshes follow (`synced`) when the last slice is done.
    local tSync = Perf.Begin()
    if syncPos == 0 and (syncedEpoch ~= TerrainEpoch.Epoch or clock - syncAt >= 2) then
        syncAt = clock
        syncedEpoch = TerrainEpoch.Epoch
        syncN = 0
        for name in markers do
            syncN = syncN + 1
            syncNames[syncN] = name
        end
        syncPos = 1
    end
    if syncPos > 0 then
        local last = math.min(syncN, syncPos + SYNC_SLICE - 1)
        local get, floor, abs = ed_terrain_get, math.floor, math.abs
        for i = syncPos, last do
            local m = markers[syncNames[i]]
            local pos = m and m.position
            if pos then
                local px, pz = pos[1], pos[3]
                if px and pz and px > -1e6 and px < 1e6 and pz > -1e6 and pz < 1e6 then      -- (NaN fails both tests)
                    local ground = get(floor(px + 0.5), floor(pz + 0.5))
                    if ground and abs(ground - pos[2]) > 0.01 then
                        pos[2] = ground
                        syncMoved = true
                    end
                end
            end
        end
        syncPos = last + 1
        if syncPos > syncN then
            syncPos = 0
            synced = syncMoved          -- (the meshes follow when a height moved)
            syncMoved = false
        end
    end
    Perf.End('markervis: height sync', tSync)
    -- The meshes are brought in line with the markers when the objects changed (Tools.Changed: a move, a type, a layer switch), when heights were synced, and about once a
    -- second as a net for an edit that does not announce itself. A frame in which nothing happened costs nothing (it walked every marker and built a string for each, every frame).
    -- The net: once a second a fingerprint of the marker positions (markersig.lua), a walk only when it moved or the markers changed in a way the fingerprint cannot see (type, prop:
    -- all of them announce themselves through Tools.Changed; the full walk every 10 s is for a writer that does not).
    local changed = Tools.Changed
    local walk = synced or changed ~= seenChanged or clock - fullAt >= 10
    if not walk and clock - netAt >= 1 then
        netAt = clock
        local a, b, c = Sig.Sums(clock)
        if a ~= sigA or b ~= sigB or c ~= sigC then walk = true end
    end
    if not walk then return end
    fullAt = clock
    netAt = clock
    sigA, sigB, sigC = Sig.Sums(clock)
    seenChanged = changed
    local tWalk = Perf.Begin()
    if not filterMod then filterMod = import('/lua/editor/markerfilter.lua') end
    local Filter = filterMod
    local sizeX, sizeZ = ed_terrain_info()           -- (once for the walk: DisplayPos asks the engine for it per marker when it is not given)
    sizeX, sizeZ = (sizeX or 257) - 1, (sizeZ or 257) - 1
    local anyHidden = next(Filter.Hidden) ~= nil
    local meshOn = MeshView.Active()
    for name, m in markers do
        local e = entries[name]
        local hidden = anyHidden and Filter.IsHidden(m.type)       -- marker layers: a hidden category has no prop in the world
        if e and (hidden or e.shapeProp ~= m.prop or e.shapeType ~= m.type) then
            Destroy(e)
            ed_overlay_remove('sp:' .. name)
            entries[name] = nil
            e = nil
        end
        if hidden then
            -- nothing to show
        elseif e then
            -- (a marker that stands where it stood, on a map without a mesh terrain, needs no DisplayPos: it is the stored position)
            local p, o = m.position, m.orientation
            if meshOn or e.rx ~= p[1] or e.ry ~= p[2] or e.rz ~= p[3] or e.rYaw ~= (o and o[2]) or e.outside then
                e.rx, e.ry, e.rz, e.rYaw = p[1], p[2], p[3], o and o[2]
                Move(name, e, m, sizeX, sizeZ)
            end
        else
            Build(name, m, sizeX, sizeZ)
        end
    end
    for name, e in entries do
        if markers[name] == nil then
            Destroy(e)
            ed_overlay_remove('sp:' .. name)
            entries[name] = nil
        end
    end
    Perf.End('markervis: mesh walk', tWalk)
end
