-- The transform gizmo of the select tools, at the middle of the selection. It is drawn flat on the ground at a constant size on screen (viewscale.PixelSize) and has four handles:
--
--   red arrow along +x     drag: move the selection along x only                ("Move X")
--   blue arrow along +z    drag: move the selection along z only                ("Move Z")
--   green square           drag: move the selection on the ground, x and z      ("Move on ground"); it sits between the two arrows, away from the selected object
--   one thin yellow ring   drag: turn the selection about the vertical axis,    ("Rotate"); every object turns about its own centre by the angle the pointer
--                          travelled around the gizmo (two small chevrons on the ring show the direction)
--
-- The handle under the pointer lights up and a small label beside the pointer names what dragging it will do; while dragging the label shows the amount. The gizmo has no height
-- handle: objects stand on the terrain (markers, areas, props, decals and units are all placed by x and z). Works for the selections of the Select (markers, areas), Select props,
-- Select decals and Select units tools; the press is taken before the tool sees it, so a drag on a handle never starts a box select. The centre is left free: dragging the
-- selected object itself still moves it. Markers and areas follow the pointer live (tools.NewLiveMove: one undo entry when the drag ends); props, decals and units show their
-- preview through `offset` (placer.lua draws the ghosts).
--
--   Active()              -> provider or nil: what the gizmo would act on right now
--   Press(wx, wz, event)  the world click hook calls it first; true when a handle was hit (a drag is started)
--   HandleAt(wx, wz)      -> 'x' | 'z' | 'free' | 'ring' | nil   the handle at a world point
--   Shapes()              the lines for the overlay (overlay.lua draws them; each shape may carry px, closed, fill and width, see DrawGizmo); also moves the label
--   Hover / Dragging      the handle under the pointer / being dragged;   Forget()  hides the label
--
-- Lua 5.0 dialect.

local Dragger = import('/lua/maui/dragger.lua').Dragger

Dragging = false      -- 'x' | 'z' | 'free' | 'ring' while a handle is dragged
Preview = false       -- { dx, dz } or { turn = degrees } while dragging
Hover = false         -- the handle under the pointer (not while dragging)
StartAngle = false    -- the angle (degrees, x towards z) the pointer had around the centre when a ring drag began

-- sizes in screen pixels, measured from the middle of the selection
local ARROW_FROM = 10       -- the arrows start a little outside the selected object
local ARROW_PX = 62         -- length of the arrows
local HEAD_PX = 12          -- length of the arrowheads
local PLANE_LO, PLANE_HI = 18, 38     -- the square between the arrows
local RING_PX = 86          -- radius of the ring (outside the arrows, so the two never cross)
local ARROW_HIT = 10        -- how far from an arrow the pointer may be to grab it
local ARROW_HIT_FROM = 18   -- the grab zone of an arrow starts here, so the object at the centre is still grabbed by the tool itself
local PLANE_HIT = 4         -- margin around the square
local RING_HIT = 10         -- margin around the ring

local COLOR = { x = 'FFFF4040', z = 'FF4080FF', free = 'FF50E070', ring = 'FFFFE040' }
local LIT = { x = 'FFFFA0A0', z = 'FFA0C4FF', free = 'FFB8FFC4', ring = 'FFFFFFA0' }
local NAME = { x = 'Move X', z = 'Move Z', free = 'Move on ground', ring = 'Rotate' }

local providers = false      -- built once: Active() asks every frame, and the table is ~40 closures

local function Providers()
    if providers then return providers end
    local Tools = import('/lua/editor/tools.lua')
    local Props = import('/lua/editor/props.lua')
    local Decals = import('/lua/editor/decals.lua')
    local Units = import('/lua/editor/units.lua')
    local Paths = import('/lua/editor/paths.lua')
    providers = {
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
                    -- (every frame: a lookup in the cached list, not a pass over All() per selected unit)
                    local u = Units.Lookup(sel.army, sel.name)
                    if u then sx, sz, n = sx + u.x, sz + u.z, n + 1 end
                end
                if n == 0 then return nil end
                return sx / n, sz / n
            end,
            move = function(dx, dz) return Units.MoveSelected(dx, dz) end,
            rotate = function(deg) return Units.RotateSelected(deg) end,
            offset = function(o) Units.DragOffset = o end,
        },
    }
    return providers
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

--- Which handle is at the world point, for the provider `p` whose gizmo is centred on (cx, cz): 'free', 'x', 'z', 'ring' or nil. The square is tried first, then the arrows, then the ring.
local function Hit(p, cx, cz, wx, wz)
    if p.yield and p.yield(wx, wz) then return nil end      -- a handle of the tool itself lies under the pointer: the tool takes the click
    local px = PixelSize()
    local dx, dz = (wx - cx) / px, (wz - cz) / px            -- in screen pixels from the centre
    if dx >= PLANE_LO - PLANE_HIT and dx <= PLANE_HI + PLANE_HIT and dz >= PLANE_LO - PLANE_HIT and dz <= PLANE_HI + PLANE_HIT then return 'free' end
    if DistToSegment(dx, dz, ARROW_HIT_FROM, 0, ARROW_PX, 0) <= ARROW_HIT then return 'x' end
    if DistToSegment(dx, dz, 0, ARROW_HIT_FROM, 0, ARROW_PX) <= ARROW_HIT then return 'z' end
    local d = math.sqrt(dx * dx + dz * dz)
    if math.abs(d - RING_PX) <= RING_HIT then return 'ring' end
    return nil
end

--- Which handle is at the world point: 'x', 'z', 'free' (the ground square), 'ring' or nil.
function HandleAt(wx, wz)
    local p, cx, cz = Active()
    if not p then return nil end
    return Hit(p, cx, cz, wx, wz)
end

-- ---- the label beside the pointer -----------------------------------------------------------------------------------------------------------

local label = false
local labelText = false
local Mouse = false         -- window position of the pointer while a handle is dragged (the engine's own position is not tracked then)

local function Label()
    if label then return label end
    pcall(function()
        local UIUtil = import('/lua/ui/uiutil.lua')
        local Group = import('/lua/maui/group.lua').Group
        local g = Group(GetFrame(0))
        g.Depth:Set(GetFrame(0).Depth() + 3995)
        g.Left:Set(0) g.Top:Set(0) g.Width:Set(1) g.Height:Set(1)
        g:DisableHitTest()
        local t = UIUtil.CreateText(g, '', 12, UIUtil.bodyFont)
        t:SetDropShadow(true)
        t:SetColor('FFFFFFFF')
        t:DisableHitTest()
        label = t
    end)
    return label
end

--- Shows `text` beside the pointer, or hides the label when text is nil.
local function SetLabel(text)
    if not text then
        if label and labelText then label:Hide() labelText = false end
        return
    end
    local t = Label()
    if not t then return end
    local mx, my
    if Mouse then
        mx, my = Mouse[1], Mouse[2]
    else
        local pos = GetMouseScreenPos()
        mx, my = pos and (pos[1] or pos.x), pos and (pos[2] or pos.y)
    end
    if not mx then return end
    if labelText ~= text then t:SetText(text) labelText = text end
    t.Left:Set(mx + 18)
    t.Top:Set(my + 16)
    t:Show()
end

--- Hides the label and forgets the hover (play mode, shutdown: overlay.Clear).
function Forget()
    Hover = false
    pcall(SetLabel, nil)
end

--- What dragging the handle does, with the amount while it is dragged.
local function LabelFor(handle)
    if not handle then return nil end
    local pv = Preview
    if Dragging and pv then
        if pv.turn then
            local t = math.mod(pv.turn + 180, 360)
            if t < 0 then t = t + 360 end
            return string.format('Rotate  %+.0f deg', t - 180)
        elseif handle == 'x' then
            return string.format('Move X  %+.1f', pv.dx or 0)
        elseif handle == 'z' then
            return string.format('Move Z  %+.1f', pv.dz or 0)
        else
            return string.format('Move  %+.1f, %+.1f', pv.dx or 0, pv.dz or 0)
        end
    end
    return NAME[handle]
end

-- ---- drawing --------------------------------------------------------------------------------------------------------------------------------

--- Lines of the gizmo for the overlay: list of { id, points = { {x, z}, ... }, color, px (line width on screen), closed, fill, width (fill: width of the ribbon in world units) },
--- or an empty list. Also shows the label and works out which handle is hovered (this runs every frame while the gizmo is on screen).
function Shapes()
    local p, cx, cz = Active()
    if not p then
        Hover = false
        SetLabel(nil)
        return {}
    end
    local px = PixelSize()

    -- the handle under the pointer
    local lit = Dragging
    if not Dragging then
        Hover = false
        local view = import('/lua/ui/game/worldview.lua').viewLeft
        if view and view.CursorOverWorld then
            local mp = GetMouseWorldPos()
            if mp then Hover = Hit(p, cx, cz, mp[1], mp[3]) or false end
        end
        lit = Hover
    end
    pcall(function() SetLabel(LabelFor(lit)) end)

    local ox, oz = 0, 0
    if Preview and Preview.dx and not Preview.live and not p.live then ox, oz = Preview.dx, Preview.dz end
    cx, cz = cx + ox, cz + oz

    local function Col(handle)
        local c = (lit == handle) and LIT[handle] or COLOR[handle]
        if Dragging and Dragging ~= handle then c = '60' .. string.sub(COLOR[handle], 3) end          -- the handles not in use fade
        return c
    end
    local function Width(handle, thin, thick)
        return (lit == handle) and thick or thin
    end

    local shapes = {}
    local head = HEAD_PX * px
    local from, to = ARROW_FROM * px, ARROW_PX * px

    -- the arrows: shaft and a V-shaped head
    local tipx = cx + to
    table.insert(shapes, { id = 'gz:x', color = Col('x'), px = Width('x', 3, 5),
        points = { { cx + from, cz }, { tipx, cz }, { tipx - head, cz + head * 0.5 }, { tipx, cz }, { tipx - head, cz - head * 0.5 } } })
    local tipz = cz + to
    table.insert(shapes, { id = 'gz:z', color = Col('z'), px = Width('z', 3, 5),
        points = { { cx, cz + from }, { cx, tipz }, { cx + head * 0.5, tipz - head }, { cx, tipz }, { cx - head * 0.5, tipz - head } } })

    -- the letters beyond the tips
    local a, gap = 4.5 * px, 11 * px
    local lx, lz = tipx + gap, cz
    table.insert(shapes, { id = 'gz:lx', color = Col('x'), px = 2,
        points = { { lx - a, lz - a }, { lx + a, lz + a }, { lx, lz }, { lx - a, lz + a }, { lx + a, lz - a } } })
    lx, lz = cx, tipz + gap
    table.insert(shapes, { id = 'gz:lz', color = Col('z'), px = 2,
        points = { { lx - a, lz + a }, { lx + a, lz + a }, { lx - a, lz - a }, { lx + a, lz - a } } })

    -- the square for free movement on the ground, between the arrows
    local x0, z0, x1, z1 = cx + PLANE_LO * px, cz + PLANE_LO * px, cx + PLANE_HI * px, cz + PLANE_HI * px
    table.insert(shapes, { id = 'gz:free', color = Col('free'), px = Width('free', 2, 4), closed = true,
        points = { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } } })
    table.insert(shapes, { id = 'gz:freef', color = (lit == 'free') and '70B8FFC4' or '3850E070', fill = true, width = (PLANE_HI - PLANE_LO) * px,
        points = { { x0, (z0 + z1) / 2 }, { x1, (z0 + z1) / 2 } } })

    -- the one ring, thin, with two chevrons that show which way it turns
    local R = RING_PX * px
    local ring = {}
    for i = 0, 47 do
        local ang = (i / 48) * 6.2831853
        table.insert(ring, { cx + math.cos(ang) * R, cz + math.sin(ang) * R })
    end
    table.insert(shapes, { id = 'gz:ring', color = Col('ring'), px = Width('ring', 2, 4), closed = true, points = ring })
    local h = 8 * px
    for k = 0, 1 do
        local ang = 0.6 + k * 3.1415927
        local rx, rz = math.cos(ang), math.sin(ang)          -- radial
        local tx, tz = -rz, rx                                -- tangent, the way the ring turns for a positive angle
        local bx, bz = cx + rx * R, cz + rz * R
        table.insert(shapes, { id = 'gz:rd' .. k, color = Col('ring'), px = Width('ring', 2, 4),
            points = { { bx - tx * h + rx * h * 0.6, bz - tz * h + rz * h * 0.6 }, { bx + tx * h * 0.3, bz + tz * h * 0.3 }, { bx - tx * h - rx * h * 0.6, bz - tz * h - rz * h * 0.6 } } })
    end

    -- while the ring is dragged: where the pointer started and where it is now
    if Preview and Preview.turn and StartAngle then
        local a0 = math.rad(StartAngle)
        local a1 = math.rad(StartAngle + Preview.turn)
        table.insert(shapes, { id = 'gz:turn0', color = '80FFFFFF', px = 2, points = { { cx, cz }, { cx + math.cos(a0) * R, cz + math.sin(a0) * R } } })
        table.insert(shapes, { id = 'gz:turn', color = 'FFFFFFFF', px = 3, points = { { cx, cz }, { cx + math.cos(a1) * R, cz + math.sin(a1) * R } } })
    end
    return shapes
end

-- ---- dragging -------------------------------------------------------------------------------------------------------------------------------

function Press(wx, wz, event)
    local handle = HandleAt(wx, wz)
    if not handle then return false end
    local p, cx, cz = Active()
    Dragging = handle
    Hover = false
    Mouse = { event.MouseX, event.MouseY }
    local startAngle = math.deg(math.atan2(wz - cz, wx - cx))
    StartAngle = startAngle
    local live = p.liveMove and p.liveMove() or nil
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        Mouse = { x, y }
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
        StartAngle = false
        Mouse = false
        pcall(SetLabel, nil)
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
