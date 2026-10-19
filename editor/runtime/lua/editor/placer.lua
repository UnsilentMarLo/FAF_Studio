-- Placing single things with a preview, like the game's build mode: the Unit tool, Place prop and Place decal.
--
--   * a translucent ghost of the thing (the game's own "UnitPlace" look: green, or red where it cannot go) follows the pointer, snapped to the build grid
--   * press and drag: a line of things at the spacing of their footprint, from where you pressed to the pointer; they are placed when you let go (one undo step)
--   * Shift: every click adds a corner to the line; the things go along all of them when Shift is released (or on the next click without Shift)
--   * with symmetry on every image gets its own ghost
--
--   Press(tool, wx, wz, event)   the tool's OnPress: true (the click is taken)
--   Update(ui, view)             called every frame by overlay.lua: draws the ghosts, ends a Shift line
--   Clear()                      removes the ghosts (tool changed, play mode)
--
-- Lua 5.0 dialect.

local WorldMesh = import('/lua/ui/controls/worldmesh.lua').WorldMesh
local Dragger = import('/lua/maui/dragger.lua').Dragger

local KIND = { unit = 'unit', prop_place = 'prop', decal_place = 'decal' }      -- tool id -> what it places

local corners = {}          -- the corners of the line being made: { x, z }
local dragging = false
local lastTool = false
local ghosts = {}           -- pool of WorldMesh
local ghostKey = false      -- the mesh the pool was set for
local decalIds = {}         -- overlay decal ids in use
local MAX_GHOSTS = 80

local function Units() return import('/lua/editor/units.lua') end
local function Props() return import('/lua/editor/props.lua') end
local function Decals() return import('/lua/editor/decals.lua') end
local function Symmetry() return import('/lua/editor/symmetry.lua') end

-- ---- what is being placed -------------------------------------------------------------------------------------------------------------------

local function Blueprint(id)
    if not id then return nil end
    return __blueprints and (__blueprints[id] or __blueprints[string.lower(id)])
end

--- The mesh of a unit or prop blueprint: { MeshName, TextureName, UniformScale } or nil.
local function MeshOf(id)
    local bp = Blueprint(id)
    if not bp or not bp.Display then return nil end
    local mesh = bp.Display.MeshBlueprint
    local mb = mesh and (__blueprints[mesh] or __blueprints[string.lower(mesh)])
    local lod = mb and mb.LODs and mb.LODs[1]
    if not lod or not lod.MeshName then return nil end
    return { MeshName = lod.MeshName, TextureName = lod.AlbedoName or '', UniformScale = bp.Display.UniformScale or 1 }
end

--- Footprint size in cells of a unit blueprint (structures: the footprint; mobile units: their collision box) and whether it is a structure.
local function UnitSize(id)
    local bp = Blueprint(id)
    if not bp then return 1, false end
    local structure = bp.Physics and bp.Physics.MotionType == 'RULEUMT_None'
    if structure and bp.Footprint then
        return math.max(1, bp.Footprint.SizeX or 1, bp.Footprint.SizeZ or 1), true, (math.mod(bp.Footprint.SizeX or 1, 2) == 1)
    end
    return math.max(1, math.ceil(math.max(bp.SizeX or 1, bp.SizeZ or 1) + 0.25)), false, false
end

local function Info(kind)
    if kind == 'unit' then
        local id = Units().Active
        if not id then return nil end
        local size, structure, odd = UnitSize(id)
        return { id = id, mesh = MeshOf(id), spacing = size, structure = structure, odd = odd }
    elseif kind == 'prop' then
        local id = Props().Active
        if not id then return nil end
        return { id = id, mesh = MeshOf(id), spacing = 2 }
    else
        local tex = Decals().Active
        if not tex then return nil end
        return { id = tex, decal = true, spacing = math.max(2, Decals().Settings.size * 0.8) }
    end
end

--- The build grid: structures with an odd footprint stand on cell centres, the others on cell corners; things that move freely snap to half a unit.
local function Snap(info, x, z)
    if info.structure then
        if info.odd then return math.floor(x) + 0.5, math.floor(z) + 0.5 end
        return math.floor(x + 0.5), math.floor(z + 0.5)
    end
    return math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
end

local function InMap(x, z)
    local w, h = ed_terrain_info()
    return x >= 1 and z >= 1 and x <= (w or 257) - 2 and z <= (h or 257) - 2
end

-- ---- the line -------------------------------------------------------------------------------------------------------------------------------

local function Dist(a, b)
    local dx, dz = b[1] - a[1], b[2] - a[2]
    return math.sqrt(dx * dx + dz * dz)
end

--- Positions along the corners at the spacing: evenly spread so both ends have one.
local function Along(info, verts)
    local out = {}
    if table.getn(verts) == 1 then
        local x, z = Snap(info, verts[1][1], verts[1][2])
        return { { x, z } }
    end
    local total = 0
    for i = 2, table.getn(verts) do
        total = total + Dist(verts[i - 1], verts[i])
    end
    local n = math.max(1, math.floor(total / info.spacing + 0.5))
    local step = total / n
    local seg, at = 1, 0
    for k = 0, n do
        local want = k * step
        -- walk to the segment holding the distance `want`
        while seg < table.getn(verts) - 1 do
            local len = Dist(verts[seg], verts[seg + 1])
            if at + len >= want - 0.0001 then break end
            at = at + len
            seg = seg + 1
        end
        local a, b = verts[seg], verts[seg + 1]
        local len = Dist(a, b)
        local f = (len > 0) and math.min(1, math.max(0, (want - at) / len)) or 0
        local x, z = Snap(info, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)
        local dup = false
        for _, q in out do if q[1] == x and q[2] == z then dup = true end end
        if not dup then table.insert(out, { x, z }) end
    end
    return out
end

local dragPos = false        -- { x, z } of the pointer in the world while a line is dragged (from the dragger's own events)

local function WorldAtScreen(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    local p = view and UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

local function Cursor(info)
    if dragging and dragPos then return Snap(info, dragPos[1], dragPos[2]) end
    local pos = GetMouseWorldPos()
    if not pos then return nil end
    return Snap(info, pos[1], pos[3])
end

-- ---- ghosts ---------------------------------------------------------------------------------------------------------------------------------

function Clear()
    for _, g in ghosts do g:SetHidden(true) end
    for id in decalIds do ed_overlay_remove(id) end
    decalIds = {}
end

local function Ghost(i, info, valid)
    local key = info.id .. (valid and '|ok' or '|no')
    if ghostKey ~= key then
        for _, g in ghosts do g:Destroy() end
        ghosts = {}
        ghostKey = key
    end
    if not ghosts[i] then
        local g = WorldMesh()
        g:SetMesh({ MeshName = info.mesh.MeshName, TextureName = info.mesh.TextureName, ShaderName = 'UnitPlace', UniformScale = info.mesh.UniformScale,
                    LODCutoff = 2000, Color = valid and 'ff50ff50' or 'ffff4040' })
        ghosts[i] = g
    end
    return ghosts[i]
end

local function Draw(info, positions)
    local Sym = Symmetry()
    local used, decalUsed = 0, {}
    for _, pos in positions do
        for _, p in Sym.Points(pos[1], pos[2]) do
            if used >= MAX_GHOSTS then break end
            used = used + 1
            local y = ed_terrain_get(math.floor(p.x + 0.5), math.floor(p.z + 0.5)) or 0
            local valid = InMap(p.x, p.z)
            if info.decal then
                local id = 'plc:' .. used
                ed_overlay_decal(id, p.x, y + 0.1, p.z, info.id, Decals().Settings.size, valid and 'A050FF50' or 'A0FF4040', 0)
                decalUsed[id] = true
            elseif info.mesh then
                local g = Ghost(used, info, valid)
                g:SetStance(Vector(p.x, y, p.z), EulerToQuaternion(0, 0, Sym.Heading(0, p)))
                g:SetHidden(false)
            else
                -- no mesh known: a ring on the ground
                local id = 'plc:' .. used
                local pts = {}
                for k = 0, 16 do
                    local a = k / 16 * 6.2831853
                    table.insert(pts, p.x + math.cos(a) * info.spacing * 0.5)
                    table.insert(pts, p.z + math.sin(a) * info.spacing * 0.5)
                end
                ed_overlay_set(id, pts, valid and 'FF50FF50' or 'FFFF4040', 0.15, 2, 3, false, true)
                decalUsed[id] = true
            end
        end
    end
    for i = used + 1, table.getn(ghosts) do ghosts[i]:SetHidden(true) end
    for id in decalIds do
        if not decalUsed[id] then ed_overlay_remove(id) end
    end
    decalIds = decalUsed
end

-- ---- placing --------------------------------------------------------------------------------------------------------------------------------

local function Commit(kind, info, positions)
    local History = import('/lua/editor/history.lua')
    local pushed, placed = 0, 0
    if kind == 'unit' then
        for _, pos in positions do
            if InMap(pos[1], pos[2]) then
                local n = Units().Place(pos[1], pos[2])
                if n > 0 then pushed = pushed + 1 placed = placed + n end
            end
        end
    else
        -- a line of props / decals ignores the brush's minimum distance: the spacing of the line decides
        local S = (kind == 'prop') and Props().Settings or Decals().Settings
        local old = S.minDist
        S.minDist = 0.01
        for _, pos in positions do
            local n = (kind == 'prop') and Props().PlaceAt(info.id, pos[1], pos[2]) or Decals().PlaceAt(info.id, pos[1], pos[2])
            if n > 0 then pushed = pushed + 1 placed = placed + n end
        end
        S.minDist = old
    end
    if pushed > 1 then History.Merge(pushed, 'place ' .. placed .. ' ' .. kind .. 's') end
    pcall(function() import('/lua/editor/ui.lua').Say('placed ' .. placed .. ' ' .. kind .. (placed == 1 and '' or 's')) end)
    return placed
end

local function Finish(kind, info, extraCorner)
    local verts = {}
    for _, c in corners do table.insert(verts, c) end
    if extraCorner then table.insert(verts, extraCorner) end
    corners = {}
    dragging = false
    if table.getn(verts) == 0 then return end
    Commit(kind, info, Along(info, verts))
end

function Press(tool, wx, wz, event)
    local kind = KIND[tool]
    local info = kind and Info(kind)
    if not info then
        pcall(function() import('/lua/editor/ui.lua').Say('choose what to place first (Units / Props / Decals panel)') end)
        return true
    end
    local x, z = Snap(info, wx, wz)
    local shift = IsKeyDown and IsKeyDown('Shift')
    if shift then
        table.insert(corners, { x, z })          -- a corner of the line; Shift released places along all of them
        return true
    end
    if table.getn(corners) > 0 then
        Finish(kind, info, { x, z })             -- a click without Shift ends the line there
        return true
    end
    corners = { { x, z } }
    dragging = true
    dragPos = { wx, wz }
    local dragger = Dragger()
    dragger.OnMove = function(self, px, py)
        local mx, mz = WorldAtScreen(px, py)
        if mx then dragPos = { mx, mz } end
    end
    local function Done(self)
        if dragging then
            local cx, cz = Cursor(info)
            dragging = false
            if cx and (math.abs(cx - corners[1][1]) + math.abs(cz - corners[1][2])) >= 0.75 then
                Finish(kind, info, { cx, cz })
            else
                Finish(kind, info, nil)          -- a click: one thing
            end
        end
        self:Destroy()
    end
    dragger.OnRelease = function(self, px, py)
        local mx, mz = WorldAtScreen(px, py)
        if mx then dragPos = { mx, mz } end
        Done(self)
    end
    dragger.OnCancel = function(self)
        corners = {}
        dragging = false
        self:Destroy()
    end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end

--- Every frame: the ghosts at the pointer / along the line.
function Update(ui, view)
    local tool = ui.State.tool
    local kind = KIND[tool]
    if tool ~= lastTool then
        corners = {}
        dragging = false
        lastTool = tool
        Clear()
    end
    if not kind or ui.State.mode ~= 'edit' then
        if kind == nil and ghostKey then Clear() end
        return
    end
    local info = Info(kind)
    if not info then Clear() return end
    -- a Shift line ends when Shift is let go
    if not dragging and table.getn(corners) > 0 and not (IsKeyDown and IsKeyDown('Shift')) then
        Finish(kind, info, nil)
        return
    end
    if not view.CursorOverWorld then
        if not dragging and table.getn(corners) == 0 then Clear() return end
    end
    local cx, cz = Cursor(info)
    local verts = {}
    for _, c in corners do table.insert(verts, c) end
    if cx and (dragging or table.getn(corners) > 0) then table.insert(verts, { cx, cz }) end
    if table.getn(verts) == 0 then
        if not cx then Clear() return end
        verts = { { cx, cz } }
    end
    Draw(info, Along(info, verts))
end

-- ---- ghosts of what is being moved or turned ---------------------------------------------------------------------------------------------------
-- While a selected prop or unit is dragged (the pointer, the gizmo's arrows, its centre or its ring) its ghost follows at once; the real object moves when the drag ends
-- (one undo step), because an entity of the running sim cannot be moved 30 times a second without leaving a trail in the map data.

local moveGhosts = {}
local moveKeys = {}

local function MoveGhost(i, key, mesh)
    if moveKeys[i] ~= key then
        if moveGhosts[i] then moveGhosts[i]:Destroy() end
        local g = WorldMesh()
        g:SetMesh({ MeshName = mesh.MeshName, TextureName = mesh.TextureName, ShaderName = 'UnitPlace', UniformScale = mesh.UniformScale, LODCutoff = 2000, Color = 'ff70d8ff' })
        moveGhosts[i] = g
        moveKeys[i] = key
    end
    return moveGhosts[i]
end

--- Shows ghosts for list of { id, x, z, heading } (blueprint ids of units or props); an empty list hides them.
function ShowMoves(list)
    local n = 0
    for _, it in list do
        if n >= MAX_GHOSTS then break end
        local mesh = MeshOf(it.id)
        if mesh then
            n = n + 1
            local g = MoveGhost(n, it.id, mesh)
            local y = ed_terrain_get(math.floor(it.x + 0.5), math.floor(it.z + 0.5)) or 0
            g:SetStance(Vector(it.x, y, it.z), EulerToQuaternion(0, 0, it.heading or 0))
            g:SetHidden(false)
        end
    end
    for i = n + 1, table.getn(moveGhosts) do moveGhosts[i]:SetHidden(true) end
end

--- What the select tools are dragging right now, as ghosts: called every frame by overlay.lua.
function UpdateMoves(ui)
    local tool = ui.State.tool
    local Gizmo = import('/lua/editor/gizmo.lua')
    local turn = Gizmo.Preview and Gizmo.Preview.turn
    local list = {}
    if tool == 'prop_select' then
        local off = Props().DragOffset
        if off or turn then
            for _, p in Props().Selection do
                table.insert(list, { id = p.bp, x = p.x + (off and off[1] or 0), z = p.z + (off and off[2] or 0), heading = Props().SelectedHeading(p) + math.rad(-(turn or 0)) })
            end
        end
    elseif tool == 'unit_select' then
        local off = Units().DragOffset
        if off or turn then
            for _, sel in Units().Selection do
                for _, u in Units().All() do
                    if u.army == sel.army and u.name == sel.name then
                        table.insert(list, { id = u.bp, x = u.x + (off and off[1] or 0), z = u.z + (off and off[2] or 0), heading = u.heading + math.rad(-(turn or 0)) })
                    end
                end
            end
        end
    end
    if table.getn(list) > 0 or table.getn(moveGhosts) > 0 then ShowMoves(list) end
end
