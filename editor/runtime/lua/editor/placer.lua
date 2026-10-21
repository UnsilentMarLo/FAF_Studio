-- Placing single things with a preview, like the game's build mode: the Unit tool, Place prop and Place decal.
--
--   * a translucent ghost of the thing (the game's own "UnitPlace" look: green, or red where it cannot go) follows the pointer, snapped to the build grid
--   * units also show their footprint (solid) and skirt (faint) on the ground under the ghost, green or red like the ghost (the rules are in unitfit.lua); a red spot can still be clicked
--   * press and drag: a line of things from where you pressed to the pointer; units stand a full footprint (skirt) apart on x or on z, so they never overlap, props and decals at a fixed
--     spacing; they are placed when you let go (one undo step)
--   * Shift: every click adds a corner to the line; the things go along all of them when Shift is released (or on the next click without Shift)
--   * with symmetry on every image gets its own ghost
--
--   Press(tool, wx, wz, event)   the tool's OnPress: true (the click is taken)
--   Update(ui, view)             called every frame by overlay.lua: draws the ghosts, ends a Shift line
--   Clear()                      removes the ghosts (tool changed, play mode)
--   ShowMoves(list, skip)        the ghosts (and, for units, footprints) of what the select tools drag;  UpdateMoves(ui) collects them every frame
--
-- Lua 5.0 dialect.

local WorldMesh = import('/lua/ui/controls/worldmesh.lua').WorldMesh
local Dragger = import('/lua/maui/dragger.lua').Dragger

local KIND = { unit = 'unit', prop_place = 'prop', decal_place = 'decal' }      -- tool id -> what it places

local corners = {}          -- the corners of the line being made: { x, z }
local dragging = false
local lastTool = false
local ghosts = {}           -- pool of WorldMesh
local ghostKeys = {}        -- ghost number -> what it was made for (blueprint and colour)
local anyShown = false      -- something of the placement preview is on screen
local decalIds = {}         -- overlay decal ids in use
local footIds = {}          -- overlay ids of the footprint quads in use
local MAX_GHOSTS = 80
local FOOT_MAX = 60         -- footprints are drawn for the first ones only
local frame = 0
local ctxs = {}             -- name -> { frame, rev, ctx }: unitfit contexts (the structures of the map), re-read a few times a second

local GREEN, RED = 'ff50ff50', 'ffff4040'

local function Units() return import('/lua/editor/units.lua') end
local function Props() return import('/lua/editor/props.lua') end
local function Decals() return import('/lua/editor/decals.lua') end
local function Symmetry() return import('/lua/editor/symmetry.lua') end
local function Fit() return import('/lua/editor/unitfit.lua') end

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

local function Info(kind)
    if kind == 'unit' then
        local id = Units().Active
        if not id then return nil end
        local bp = Blueprint(id)
        local sx, sz = Fit().Spacing(bp)
        return { id = id, unit = true, bp = bp, mesh = MeshOf(id), sx = sx, sz = sz, spacing = math.max(sx, sz) }
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

--- The build grid: a unit stands where its footprint's corners lie on whole cells (unitfit.Snap), things that move freely snap to half a unit.
local function Snap(info, x, z)
    if info.unit and info.bp then return Fit().Snap(info.bp, x, z, 0) end
    return math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
end

local function InMap(x, z)
    local w, h = ed_terrain_info()
    return x >= 1 and z >= 1 and x <= (w or 257) - 2 and z <= (h or 257) - 2
end

--- The unitfit context (water, playable area, the structures of the map) for `name`, re-read every 15 frames or when the selection changed (rev); skip: units left out.
local function Ctx(name, rev, skip)
    local c = ctxs[name]
    -- Context() reads every unit of the map and works out the footprint of each structure: with the pointer moving over a mission map it ran four times a second. It is read
    -- again when a unit was stored or removed or the history moved (Units.Stamp), when the selection changed (rev), and every 2 seconds as a net.
    local stamp = Units().Stamp()
    if not c or frame - c.frame >= 120 or c.rev ~= rev or c.stamp ~= stamp then
        c = { frame = frame, rev = rev, stamp = stamp, ctx = Fit().Context(skip) }
        ctxs[name] = c
    end
    return c.ctx
end

--- A heading about the vertical axis. EulerToQuaternion(roll, pitch, yaw) turns about the vertical (y) axis with its SECOND argument: (0, 0, h) tilts the thing about z,
--- which is how the preview of a turned unit used to lie on its side.
local function Yaw(heading)
    return EulerToQuaternion(0, heading or 0, 0)
end

-- ---- the line -------------------------------------------------------------------------------------------------------------------------------

local function Dist(a, b)
    local dx, dz = b[1] - a[1], b[2] - a[2]
    return math.sqrt(dx * dx + dz * dz)
end

--- Positions along the corners at the spacing: evenly spread so both ends have one (props and decals).
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

--- Positions along the corners for units: one at the start, then walking the line in small steps a new one wherever the snapped point is a whole footprint (skirt) away from the
--- last one on x or on z. Two units are then never closer than their footprints are wide, on a straight line and on a diagonal (the old even spread rounded each position to the
--- grid on its own and left gaps of one cell less than the footprint).
local function AlongUnits(info, verts)
    local x, z = Snap(info, verts[1][1], verts[1][2])
    local out = { { x, z } }
    local lx, lz = x, z
    for i = 2, table.getn(verts) do
        local a, b = verts[i - 1], verts[i]
        local n = math.max(1, math.ceil(Dist(a, b) / 0.25))
        if n > 4000 then n = 4000 end
        for k = 1, n do
            local f = k / n
            local px, pz = Snap(info, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)
            if math.abs(px - lx) >= info.sx - 0.001 or math.abs(pz - lz) >= info.sz - 0.001 then
                table.insert(out, { px, pz })
                lx, lz = px, pz
                if table.getn(out) >= 400 then return out end
            end
        end
    end
    return out
end

local function Positions(info, verts)
    if info.unit then return AlongUnits(info, verts) end
    return Along(info, verts)
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

-- ---- footprints -----------------------------------------------------------------------------------------------------------------------------

local function GroundAt(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

--- The outline of a ground rectangle { x0, z0, x1, z1 } as overlay points (x, y, z, ...): every side sampled about every 2 units so it follows the terrain.
local function RectLine(r)
    local pts = {}
    local function Side(ax, az, bx, bz)
        local n = math.max(1, math.ceil(math.max(math.abs(bx - ax), math.abs(bz - az)) / 2))
        for i = 0, n - 1 do
            local f = i / n
            local px, pz = ax + (bx - ax) * f, az + (bz - az) * f
            table.insert(pts, px)
            table.insert(pts, GroundAt(px, pz) + 0.25)
            table.insert(pts, pz)
        end
    end
    Side(r[1], r[2], r[3], r[2])
    Side(r[3], r[2], r[3], r[4])
    Side(r[3], r[4], r[1], r[4])
    Side(r[1], r[4], r[1], r[2])
    return pts
end

--- A filled rectangle as one wide ribbon along its middle (points and the ribbon's width in world units).
local function RectFill(r)
    local pts = {}
    local zc = (r[2] + r[4]) / 2
    local n = math.max(1, math.ceil((r[3] - r[1]) / 2))
    for i = 0, n do
        local px = r[1] + (r[3] - r[1]) * i / n
        table.insert(pts, px)
        table.insert(pts, GroundAt(px, zc) + 0.2)
        table.insert(pts, zc)
    end
    return pts, r[4] - r[2]
end

--- Draws the footprint (green or red quad with an outline) and the skirt (a fainter outline) of a unit blueprint at (x, z) under the preview; `prefix` + `i` name the overlay
--- objects, `used` collects them for SweepFootprints.
local function ShowFootprint(prefix, i, bp, x, z, heading, valid, used)
    local foot, skirt = Fit().Rects(bp, x, z, heading)
    local line = valid and 'FF50FF50' or 'FFFF4040'
    local fill = valid and '4050FF50' or '48FF4040'
    local faint = valid and '9050FF50' or '90FF4040'
    local idF, idO, idS = prefix .. 'f:' .. i, prefix .. 'o:' .. i, prefix .. 's:' .. i
    local pts, width = RectFill(foot)
    ed_overlay_set(idF, pts, fill, width, 1, 800, false, false, false)
    ed_overlay_set(idO, RectLine(foot), line, 0.15, 2, 3, true, true)
    used[idF] = true
    used[idO] = true
    footIds[idF] = true
    footIds[idO] = true
    if skirt and (math.abs(skirt[1] - foot[1]) > 0.01 or math.abs(skirt[2] - foot[2]) > 0.01 or math.abs(skirt[3] - foot[3]) > 0.01 or math.abs(skirt[4] - foot[4]) > 0.01) then
        ed_overlay_set(idS, RectLine(skirt), faint, 0.1, 1, 1.5, true, true)
        used[idS] = true
        footIds[idS] = true
    end
end

--- Removes the footprint objects of `prefix` that were not drawn this time.
local function SweepFootprints(prefix, used)
    for id in footIds do
        if string.sub(id, 1, string.len(prefix)) == prefix and not used[id] then
            ed_overlay_remove(id)
            footIds[id] = nil
        end
    end
end

-- ---- ghosts ---------------------------------------------------------------------------------------------------------------------------------

local lastDrawSig = false      -- what the ghosts were last drawn for (Update draws again only when it changed)

function Clear()
    lastDrawSig = false
    for _, g in ghosts do g:SetHidden(true) end
    for id in decalIds do ed_overlay_remove(id) end
    decalIds = {}
    for id in footIds do ed_overlay_remove(id) end
    footIds = {}
    anyShown = false
end

--- Ghost number i for the thing being placed, in green or red; a ghost is made again when the blueprint or the colour changes.
local function Ghost(i, info, valid)
    local key = info.id .. (valid and '|ok' or '|no')
    if ghostKeys[i] ~= key then
        if ghosts[i] then ghosts[i]:Destroy() end
        local g = WorldMesh()
        g:SetMesh({ MeshName = info.mesh.MeshName, TextureName = info.mesh.TextureName, ShaderName = 'UnitPlace', UniformScale = info.mesh.UniformScale,
                    LODCutoff = 2000, Color = valid and GREEN or RED })
        ghosts[i] = g
        ghostKeys[i] = key
    end
    return ghosts[i]
end

local function Draw(info, positions)
    local Sym = Symmetry()
    local used, decalUsed, footUsed = 0, {}, {}
    local ctx = info.unit and info.bp and Ctx('place', 0, nil) or nil
    local why = ''
    for _, pos in positions do
        for _, p in Sym.Points(pos[1], pos[2]) do
            if used >= MAX_GHOSTS then break end
            used = used + 1
            local y = GroundAt(p.x, p.z)
            local heading = Sym.Heading(0, p)
            local valid = InMap(p.x, p.z)
            if valid and ctx then
                local ok, fits, reason = pcall(Fit().Check, info.bp, p.x, p.z, heading, ctx)
                if ok and not fits then
                    valid = false
                    if why == '' then why = reason end
                end
            end
            if info.decal then
                local id = 'plc:' .. used
                ed_overlay_decal(id, p.x, y + 0.1, p.z, info.id, Decals().Settings.size, valid and 'A050FF50' or 'A0FF4040', 0)
                decalUsed[id] = true
            elseif info.mesh then
                local g = Ghost(used, info, valid)
                g:SetStance(Vector(p.x, y, p.z), Yaw(heading))
                g:SetHidden(false)
            else
                -- no mesh known: a ring on the ground
                local id = 'plc:' .. used
                local pts = {}
                for k = 0, 16 do
                    local a = k / 16 * 6.2831853
                    local rx, rz = p.x + math.cos(a) * info.spacing * 0.5, p.z + math.sin(a) * info.spacing * 0.5
                    table.insert(pts, rx)
                    table.insert(pts, GroundAt(rx, rz) + 0.2)
                    table.insert(pts, rz)
                end
                ed_overlay_set(id, pts, valid and 'FF50FF50' or 'FFFF4040', 0.15, 2, 3, false, true)
                decalUsed[id] = true
            end
            if info.unit and info.bp and used <= FOOT_MAX then
                ShowFootprint('pl:', used, info.bp, p.x, p.z, heading, valid, footUsed)
            end
        end
    end
    for i = used + 1, table.getn(ghosts) do ghosts[i]:SetHidden(true) end
    for id in decalIds do
        if not decalUsed[id] then ed_overlay_remove(id) end
    end
    decalIds = decalUsed
    SweepFootprints('pl:', footUsed)
    anyShown = true
end

-- ---- placing --------------------------------------------------------------------------------------------------------------------------------

local function Commit(kind, info, positions)
    local History = import('/lua/editor/history.lua')
    local pushed, placed = 0, 0
    local refused, why = 0, ''
    if kind == 'unit' then
        -- a spot the game's rules refuse is still placed (the mapper decides); the message says how many
        local ctx
        if info.bp then
            local ok, c = pcall(Fit().Context)
            if ok then ctx = c end
        end
        for _, pos in positions do
            if InMap(pos[1], pos[2]) then
                if ctx then
                    local ok, fits, reason = pcall(Fit().Check, info.bp, pos[1], pos[2], 0, ctx)
                    if ok and not fits then
                        refused = refused + 1
                        if why == '' then why = reason end
                    end
                end
                local n = Units().Place(pos[1], pos[2])
                if n > 0 then pushed = pushed + 1 placed = placed + n end
            end
        end
        ctxs.place = nil
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
    local text = 'placed ' .. placed .. ' ' .. kind .. (placed == 1 and '' or 's')
    if refused > 0 then
        text = text .. ' (' .. refused .. ' where the game would not allow it: ' .. why .. ')'
    end
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    return placed
end

local function Finish(kind, info, extraCorner)
    local verts = {}
    for _, c in corners do table.insert(verts, c) end
    if extraCorner then table.insert(verts, extraCorner) end
    corners = {}
    dragging = false
    if table.getn(verts) == 0 then return end
    Commit(kind, info, Positions(info, verts))
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
    frame = frame + 1
    local tool = ui.State.tool
    local kind = KIND[tool]
    if tool ~= lastTool then
        corners = {}
        dragging = false
        lastTool = tool
        Clear()
    end
    if not kind or ui.State.mode ~= 'edit' then
        if kind == nil and anyShown then Clear() end
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
    -- With the pointer at rest over the same thing nothing needs to be worked out or sent to the engine again (a line of units was snapped step by step, and every footprint was
    -- laid onto the terrain, on every frame).
    local Sym = Symmetry()
    local cs = ''
    for _, c in corners do cs = cs .. string.format('%.2f,%.2f;', c[1], c[2]) end
    local scx, scz = Sym.Centre()
    local sig = string.format('%s|%s|%s|%.2f|%.2f|%s|%.1f|%.1f|%s|%d|%s', info.id, cs, tostring(dragging), cx or 0, cz or 0, tostring(Sym.Mode), scx or 0, scz or 0, Units().Stamp(),
        math.floor(frame / 120), tostring(info.decal and Decals().Settings.size))
    if sig == lastDrawSig and anyShown then return end
    lastDrawSig = sig
    Draw(info, Positions(info, verts))
end

-- ---- ghosts of what is being moved or turned ---------------------------------------------------------------------------------------------------
-- While a selected prop or unit is dragged (the pointer, the gizmo's arrows, its plane square or its ring) its ghost follows at once; the real object moves when the drag ends
-- (one undo step), because an entity of the running sim cannot be moved 30 times
-- a second without leaving a trail in the map data. A moved unit also shows its footprint at the target, green or red by the same rules as a new one (the units being moved
-- do not count as in the way).

local moveGhosts = {}
local moveKeys = {}
local moveFoot = false      -- footprints of a move are on screen

local function MoveGhost(i, key, mesh, color)
    if moveKeys[i] ~= key then
        if moveGhosts[i] then moveGhosts[i]:Destroy() end
        local g = WorldMesh()
        g:SetMesh({ MeshName = mesh.MeshName, TextureName = mesh.TextureName, ShaderName = 'UnitPlace', UniformScale = mesh.UniformScale, LODCutoff = 2000, Color = color })
        moveGhosts[i] = g
        moveKeys[i] = key
    end
    return moveGhosts[i]
end

--- Shows ghosts for list of { id, x, z, heading, unit } (blueprint ids of units or props); an empty list hides them. skip: set of 'army|name' of the units being moved.
function ShowMoves(list, skip)
    local n = 0
    local footUsed = {}
    local ctx
    for _, it in list do
        if n >= MAX_GHOSTS then break end
        n = n + 1
        local heading = it.heading or 0
        local valid = true
        local bp = it.unit and Fit().Blueprint(it.id) or nil
        if bp then
            ctx = ctx or Ctx('move', Units().SelRevision, skip)
            local ok, fits = pcall(Fit().Check, bp, it.x, it.z, heading, ctx)
            if ok and not fits then valid = false end
        end
        local mesh = MeshOf(it.id)
        if mesh then
            local color = bp and (valid and GREEN or RED) or 'ff70d8ff'
            local g = MoveGhost(n, it.id .. color, mesh, color)
            g:SetStance(Vector(it.x, GroundAt(it.x, it.z), it.z), Yaw(heading))
            g:SetHidden(false)
        elseif moveGhosts[n] then
            moveGhosts[n]:SetHidden(true)
        end
        if bp and n <= FOOT_MAX then
            ShowFootprint('mv:', n, bp, it.x, it.z, heading, valid, footUsed)
        end
    end
    for i = n + 1, table.getn(moveGhosts) do moveGhosts[i]:SetHidden(true) end
    SweepFootprints('mv:', footUsed)
    moveFoot = next(footUsed) ~= nil
end

--- What the select tools are dragging right now, as ghosts: called every frame by overlay.lua.
function UpdateMoves(ui)
    local tool = ui.State.tool
    local Gizmo = import('/lua/editor/gizmo.lua')
    local turn = Gizmo.Preview and Gizmo.Preview.turn
    local list = {}
    local skip
    if tool == 'prop_select' then
        local off = Props().DragOffset
        if off or turn then
            for _, p in Props().Selection do
                table.insert(list, { id = p.bp, x = p.x + (off and off[1] or 0), z = p.z + (off and off[2] or 0), heading = Props().SelectedHeading(p) + math.rad(-(turn or 0)) })
            end
        end
    elseif tool == 'unit_select' then
        local off = Units().DragOffset
        if off then off = { Units().SnapDelta(off[1], off[2]) } end        -- the preview stands where the unit will land: on the build grid
        if off or turn then
            skip = {}
            for _, sel in Units().Selection do
                skip[sel.army .. '|' .. sel.name] = true
                -- (every frame while dragging: the cached lookup, not a pass over every unit of the map)
                local u = Units().Lookup(sel.army, sel.name)
                if u then
                    table.insert(list, { id = u.bp, unit = true, x = u.x + (off and off[1] or 0), z = u.z + (off and off[2] or 0), heading = u.heading + math.rad(-(turn or 0)) })
                end
            end
        end
    end
    if table.getn(list) > 0 or table.getn(moveGhosts) > 0 or moveFoot then ShowMoves(list, skip) end
end
