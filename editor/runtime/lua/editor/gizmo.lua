-- The transform gizmo of the select tools: at the middle of the selection, a red arrow along x, a blue arrow along z and a yellow ring. Dragging an arrow moves the selection
-- along that axis only, dragging the ring turns every selected object about its own centre by the angle the pointer travelled around the gizmo. Works for the selections of the Select
-- (markers, areas), Select props, Select decals and Select units tools; the press is taken before the tool sees it, so a drag on the arrows never starts a box select or a free move.
--
-- A small square at the centre moves the selection freely on the ground (x and z at once); the arrows stay on their axis, the ring turns. Markers and areas follow
-- the pointer live (tools.NewLiveMove: one undo entry when the drag ends); props, decals and units show their preview through `offset`.
--
--   Active()              -> provider or nil: what the gizmo would act on right now
--   Press(wx, wz, event)  the world click hook calls it first; true when a handle was hit (a drag is started)
--   Shapes()              the lines for the overlay (overlay.lua draws them)
--
-- Lua 5.0 dialect.

local Dragger = import('/lua/maui/dragger.lua').Dragger

Dragging = false      -- 'x' | 'z' | 'free' | 'ring' while a handle is dragged
Preview = false       -- { dx, dz } or { turn = degrees } while dragging

local ARROW_PX = 56
local RING_PX = 30
local HIT_PX = 9
local CENTER_PX = 13    -- half side of the centre square (outside a marker icon, which is 22 px)

local function Providers()
    local Tools = import('/lua/editor/tools.lua')
    local Props = import('/lua/editor/props.lua')
    local Decals = import('/lua/editor/decals.lua')
    local Units = import('/lua/editor/units.lua')
    local Paths = import('/lua/editor/paths.lua')
    return {
        paths = {
            live = true,
            yield = function(wx, wz)
                local kind = import('/lua/editor/pathtool.lua').HitTest(wx, wz)
                return kind == 'handle_out' or kind == 'handle_in' or kind == 'point'
            end,
            count = function()
                local n = table.getn(Paths.SelectedIndices())
                if n > 0 then return n end
                local p = Paths.CurrentPath()
                return p and table.getn(p.points) or 0
            end,
            center = function() return Paths.SelectionCenter() end,
            move = function(dx, dz) return Paths.MoveSelected(dx, dz) end,
            rotate = function(deg) return Paths.RotateSelected(-deg) end,
            offset = function(o) Paths.GizmoOffset(o) end,          -- the model follows the drag live
            turnLive = function(t) Paths.GizmoTurn(t) end,
        },
        select = {
            count = function() return Tools.SelectionCount() end,
            center = function() return Tools.SelectionCenter() end,
            move = function(dx, dz) return Tools.MoveSelectionBy(dx, dz) end,
            rotate = function(deg) return Tools.RotateSelectionBy(deg) end,
            liveMove = function() return Tools.NewLiveMove() end,
        },
        prop_select = {
            count = function() return table.getn(Props.Selection) end,
            center = function()
                local sx, sz, n = 0, 0, 0
                for _, p in Props.Selection do sx, sz, n = sx + p.x, sz + p.z, n + 1 end
                if n == 0 then return nil end
                return sx / n, sz / n
            end,
            move = function(dx, dz) return Props.MoveSelected(dx, dz) end,
            rotate = function(deg) return Props.RotateSelected(deg) end,
            offset = function(o) Props.DragOffset = o end,
        },
        decal_select = {
            count = function() return table.getn(Decals.Selection) end,
            center = function()
                local sx, sz, n = 0, 0, 0
                for _, p in Decals.Selection do sx, sz, n = sx + p.x, sz + p.z, n + 1 end
                if n == 0 then return nil end
                return sx / n, sz / n
            end,
            move = function(dx, dz) return Decals.MoveSelected(dx, dz) end,
            rotate = function(deg) return Decals.RotateSelected(deg) end,
            offset = function(o) Decals.DragOffset = o end,
        },
        unit_select = {
            count = function() return table.getn(Units.Selection) end,
            center = function()
                local sx, sz, n = 0, 0, 0
                for _, sel in Units.Selection do
                    for _, u in Units.All() do
                        if u.army == sel.army and u.name == sel.name then sx, sz, n = sx + u.x, sz + u.z, n + 1 end
                    end
                end
                if n == 0 then return nil end
                return sx / n, sz / n
            end,
            move = function(dx, dz) return Units.MoveSelected(dx, dz) end,
            rotate = function(deg) return Units.RotateSelected(deg) end,
            offset = function(o) Units.DragOffset = o end,
        },
    }
end

--- The provider of the active tool when it has a selection, with the gizmo's origin: provider, cx, cz.
function Active()
    local ok, id = pcall(function()
        local ui = import('/lua/editor/ui.lua')
        return ui.ActiveTool() and ui.State.tool
    end)
    if not ok or not id then return nil end
    if id == 'area_select' then id = 'select' end          -- the Select area tool moves the same objects as Select marker: the document's selection
    local p = Providers()[id]
    if not p or p.count() == 0 then return nil end
    local ro = import('/lua/editor/tools.lua').ReadOnly
    if ro then return nil end
    local cx, cz = p.center()
    if not cx then return nil end
    return p, cx, cz
end

--- World size of one screen pixel around (x, z).
local function PixelSize()
    return import('/lua/editor/viewscale.lua').PixelSize()
end

--- Lines of the gizmo for the overlay: list of { id, points = { {x, z}, ... }, color }, or an empty list.
function Shapes()
    local p, cx, cz = Active()
    if not p then return {} end
    local px = PixelSize()
    local L, R = ARROW_PX * px, RING_PX * px
    local ox, oz = 0, 0
    if Preview and Preview.dx and not Preview.live and not p.live then ox, oz = Preview.dx, Preview.dz end
    cx, cz = cx + ox, cz + oz
    local head = 9 * px
    local shapes = {
        { id = 'gz:x', color = 'FFFF4040', points = { { cx, cz }, { cx + L, cz }, { cx + L - head, cz + head * 0.5 }, { cx + L, cz }, { cx + L - head, cz - head * 0.5 } } },
        { id = 'gz:z', color = 'FF4080FF', points = { { cx, cz }, { cx, cz + L }, { cx + head * 0.5, cz + L - head }, { cx, cz + L }, { cx - head * 0.5, cz + L - head } } },
    }
    local ring = {}
    for i = 0, 40 do
        local a = (i / 40) * 6.2831853
        table.insert(ring, { cx + math.cos(a) * R, cz + math.sin(a) * R })
    end
    table.insert(shapes, { id = 'gz:ring', color = 'FFFFE040', points = ring })
    local c = CENTER_PX * px
    table.insert(shapes, { id = 'gz:free', color = 'FFFFFFFF', points = { { cx - c, cz - c }, { cx + c, cz - c }, { cx + c, cz + c }, { cx - c, cz + c }, { cx - c, cz - c } } })
    if Preview and Preview.turn then
        local a = math.rad(Preview.turn)
        table.insert(shapes, { id = 'gz:turn', color = 'FFFFFFFF', points = { { cx, cz }, { cx + math.cos(a) * R, cz + math.sin(a) * R } } })
    end
    return shapes
end

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

local function DistToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len2 = dx * dx + dz * dz
    local t = len2 > 0 and ((px - ax) * dx + (pz - az) * dz) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qz = ax + dx * t, az + dz * t
    return math.sqrt((px - qx) * (px - qx) + (pz - qz) * (pz - qz))
end

--- Which handle is at the world point: 'x', 'z', 'ring' or nil.
function HandleAt(wx, wz)
    local p, cx, cz = Active()
    if not p then return nil end
    if p.yield and p.yield(wx, wz) then return nil end      -- a handle of the tool itself lies under the pointer: the tool takes the click
    local px = PixelSize()
    local L, R, hit = ARROW_PX * px, RING_PX * px, HIT_PX * px
    if math.abs(wx - cx) <= CENTER_PX * px + px and math.abs(wz - cz) <= CENTER_PX * px + px then return 'free' end
    if DistToSegment(wx, wz, cx, cz, cx + L, cz) <= hit then return 'x' end
    if DistToSegment(wx, wz, cx, cz, cx, cz + L) <= hit then return 'z' end
    local d = math.sqrt((wx - cx) * (wx - cx) + (wz - cz) * (wz - cz))
    if math.abs(d - R) <= hit then return 'ring' end
    return nil
end

function Press(wx, wz, event)
    local handle = HandleAt(wx, wz)
    if not handle then return false end
    local p, cx, cz = Active()
    Dragging = handle
    local startAngle = math.deg(math.atan2(wz - cz, wx - cx))
    local live = p.liveMove and p.liveMove() or nil
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if not mx then return end
        if handle == 'x' then
            Preview = { dx = mx - wx, dz = 0 }
        elseif handle == 'z' then
            Preview = { dx = 0, dz = mz - wz }
        elseif handle == 'free' then
            Preview = { dx = mx - wx, dz = mz - wz }
        else
            local a = math.deg(math.atan2(mz - cz, mx - cx))
            local turn = a - startAngle
            -- screen x / world z make the angle run clockwise on screen: the object turns the way the pointer does
            Preview = { turn = turn }
        end
        if live then
            Preview.live = true
            if Preview.turn then live.Turn(-Preview.turn) else live.Move(Preview.dx, Preview.dz) end
        else
            if p.offset and Preview.dx then p.offset({ Preview.dx, Preview.dz }) end
            if p.turnLive and Preview.turn then p.turnLive(Preview.turn) end
        end
    end
    local function Done(self, cancelled)
        local pv = Preview
        Preview = false
        Dragging = false
        if p.offset then p.offset(false) end
        if p.turnLive then p.turnLive(false) end
        self:Destroy()
        if live then
            if cancelled then live.Cancel() else live.Commit() end
            return
        end
        if pv and not cancelled then
            if pv.dx and (math.abs(pv.dx) + math.abs(pv.dz)) > 0.05 then p.move(pv.dx, pv.dz) end
            if pv.turn and math.abs(pv.turn) > 0.5 then p.rotate(-pv.turn) end
        end
    end
    dragger.OnRelease = function(self, x, y) Done(self, false) end
    dragger.OnCancel = function(self) Done(self, true) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end
