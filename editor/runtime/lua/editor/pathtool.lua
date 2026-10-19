-- The Paths tool: draw and edit the spline paths of paths.lua in the viewport.
--
--   Draw mode   a click on the ground appends a point to the current path (a new path when none is selected), a click on the path's own line inserts a point, a click on the first
--               point of an open path with three points or more closes it
--   Edit mode   click a point to select it (Shift toggles), drag it to move it (all selected points move together), drag a tangent handle (Bezier paths; Alt breaks the mirror),
--               Ctrl+click a line to insert a point, click a line to select the path, click empty ground to deselect the points. The transform gizmo (arrows and ring) moves / turns the selected
--               points, or the whole path when no point is selected. Delete removes the selected points. Snap (paths.lua) rounds positions to the grid step.
--
--   Press(wx, wz, event)     the tool's click (ui.lua tool.OnPress)
--   Draw(ui)                 called every frame by overlay.lua: the lines of the paths (and takes a live preview away when the tool is left)
--   Forget()                 the overlay was cleared
--
-- Lua 5.0 dialect.

local Dragger = import('/lua/maui/dragger.lua').Dragger
local Paths = import('/lua/editor/paths.lua')

Show = true            -- draw the paths while another tool is active, too
NewMode = 'carve'      -- the mode of a path started by a click in draw mode
NewKind = 'catmull'
Hover = false          -- { id, index } point under the pointer

local HIT_PX = 9          -- pick distance of a point or handle, in screen pixels
local LINE_PX = 5         -- pick distance of the path line
local drawn = {}       -- overlay ids drawn
local drawKey = ''
local dense = {}       -- path id -> { rev, S }
local dragging = false
Box = false            -- { x0, z0, x1, z1 } of the marquee while it is dragged

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- World size of one screen pixel at the middle of the view (the camera distance only).
local function PixelSize()
    return import('/lua/editor/viewscale.lua').PixelSize()
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function Dense(path)
    local d = dense[path.id]
    if not d or d.rev ~= Paths.Revision then
        d = { rev = Paths.Revision, S = Paths.Sample(path, 2) }
        dense[path.id] = d
    end
    return d.S
end

-- ---- hit testing --------------------------------------------------------------------------------------------------------------------------------

local function Dist(ax, az, bx, bz)
    return math.sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz))
end

local function DistToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len2 = dx * dx + dz * dz
    local t = len2 > 0 and ((px - ax) * dx + (pz - az) * dz) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return Dist(px, pz, ax + dx * t, az + dz * t)
end

--- World size of one screen pixel (the camera distance only), for tests.
function PixelSizeForTest()
    return PixelSize()
end

--- For tests: how near the closest sample of any path's dense line is to the world point, the pick distance, the number of paths and the pixel size.
function NearestForTest(wx, wz)
    local px = PixelSize()
    local best, id = 1e9, nil
    for _, path in Paths.List do
        local S = Dense(path)
        for k = 1, S.n do
            local d = Dist(wx, wz, S.x[k], S.z[k])
            if d < best then best, id = d, path.id end
        end
    end
    return string.format('nearest sample %.3f of %s, pick %.3f, px %.4f, paths %d, rev %d', best, tostring(id), LINE_PX * px, px, table.getn(Paths.List), Paths.Revision)
end

--- What is under the world point: kind ('handle_out' | 'handle_in' | 'point' | 'segment'), path id, index (point, or the control point the segment starts at).
function HitTest(wx, wz)
    local px = PixelSize()
    local hit = HIT_PX * px
    local cur = Paths.CurrentPath()
    if cur and cur.kind == 'bezier' then
        local out, inn = Paths.HandleVectorsOf(cur)
        for _, i in Paths.SelectedIndices() do
            local p = cur.points[i]
            if Dist(wx, wz, p.x + out[i][1], p.z + out[i][2]) <= hit then return 'handle_out', cur.id, i end
            if Dist(wx, wz, p.x + inn[i][1], p.z + inn[i][2]) <= hit then return 'handle_in', cur.id, i end
        end
    end
    local order = {}
    if cur then table.insert(order, cur) end
    for _, p in Paths.List do
        if not cur or p.id ~= cur.id then table.insert(order, p) end
    end
    for _, path in order do
        local best, bi = hit, nil
        for i, p in path.points do
            local d = Dist(wx, wz, p.x, p.z)
            if d <= best then best, bi = d, i end
        end
        if bi then return 'point', path.id, bi end
    end
    for _, path in order do
        local S = Dense(path)
        local best, bs = LINE_PX * px, nil
        -- the distance to the polyline, not to its samples: the samples lie 2 units apart, which is more than the pick distance when the camera is close (5 px = 0.5 units
        -- at a close zoom): a click right beside the line fell between two samples and missed
        for k = 1, S.n do
            local d
            if k < S.n then d = DistToSegment(wx, wz, S.x[k], S.z[k], S.x[k + 1], S.z[k + 1]) else d = Dist(wx, wz, S.x[k], S.z[k]) end
            if d <= best then best, bs = d, S.seg[k] end
        end
        if bs then return 'segment', path.id, bs end
    end
    return nil
end

-- ---- the click ----------------------------------------------------------------------------------------------------------------------------------

local KEYS = { Shift = 16, Control = 17, Alt = 18 }

local function Held(name)
    return IsKeyDown and IsKeyDown(KEYS[name]) and true or false
end

local function DragPoints(wx, wz, event, index)
    local path = Paths.CurrentPath()
    local before = Paths.Begin()
    local grab = path.points[index]
    local gx, gz = grab.x, grab.z
    local lastX, lastZ = gx, gz
    dragging = true
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if not mx then return end
        local nx, nz = Paths.SnapPoint(gx + (mx - wx), gz + (mz - wz))
        Paths.MoveBy(nx - lastX, nz - lastZ)
        lastX, lastZ = nx, nz
    end
    local function Done(self)
        dragging = false
        self:Destroy()
        if math.abs(lastX - gx) + math.abs(lastZ - gz) > 0.01 then Paths.End('move path points', before) end
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

local function DragHandle(wx, wz, event, index, which)
    local path = Paths.CurrentPath()
    local before = Paths.Begin()
    local p = path.points[index]
    local breakMirror = Held('Alt')
    local moved = false
    dragging = true
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if not mx then return end
        local v = { mx - p.x, mz - p.z }
        if which == 'out' then
            if breakMirror and not p.hi then
                local out, inn = Paths.HandleVectorsOf(path)
                p.hi = { inn[index][1], inn[index][2] }
            end
            p.ho = v
            if not breakMirror and not p.hi then p.hi = nil end
        else
            if breakMirror and not p.ho then
                local out = Paths.HandleVectorsOf(path)
                p.ho = { out[index][1], out[index][2] }
            end
            p.hi = v
        end
        moved = true
        Paths.Touch()
    end
    local function Done(self)
        dragging = false
        self:Destroy()
        if moved then Paths.End('edit tangent', before) end
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

--- The end of a marquee drag (or of a click on empty ground: moved = false): the selection it makes.
function ApplyMarquee(box, how, moved)
    if moved and box then
        Paths.SelectInRect(box, how)
    elseif how == 'set' then
        Paths.Sel = {}
    end
    Paths.Redraw()
end

local function MarqueeDrag(wx, wz, event)
    local how = Held('Shift') and 'add' or (Held('Control') and 'toggle' or 'set')
    local px = PixelSize()
    local moved = false
    dragging = true
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if not mx then return end
        if math.abs(mx - wx) + math.abs(mz - wz) > 4 * px then moved = true end
        if moved then
            Box = { wx, wz, mx, mz }
            Paths.Redraw()
        end
    end
    local function Done(self)
        dragging = false
        self:Destroy()
        local box = Box
        Box = false
        ApplyMarquee(box, how, moved)
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

function Press(wx, wz, event)
    local kind, id, index = HitTest(wx, wz)
    if Paths.Mode == 'draw' then
        if kind == 'point' and id == Paths.Current then
            local path = Paths.CurrentPath()
            if index == 1 and table.getn(path.points) >= 3 and not path.closed then
                Paths.SetField('closed', true)
                Paths.Mode = 'edit'
                return true
            end
            Paths.Select(id, index, false)
            return true
        end
        if kind == 'segment' and id == Paths.Current then
            Paths.InsertPoint(index, wx, wz)
            return true
        end
        local cur = Paths.CurrentPath()
        if cur and cur.closed then
            Paths.Current = false
            Paths.Sel = {}
        end
        Paths.AddPoint(wx, wz, NewMode, NewKind)
        return true
    end
    if kind == 'handle_out' then
        DragHandle(wx, wz, event, index, 'out')
        return true
    elseif kind == 'handle_in' then
        DragHandle(wx, wz, event, index, 'in')
        return true
    elseif kind == 'point' then
        if id ~= Paths.Current then
            Paths.Select(id, index, false)
        elseif Held('Shift') then
            Paths.Select(id, index, true)
            return true
        elseif not Paths.Sel[index] then
            Paths.Select(id, index, false)
        end
        DragPoints(wx, wz, event, index)
        return true
    elseif kind == 'segment' then
        if Held('Control') then
            if id ~= Paths.Current then Paths.Select(id, nil, false) end
            local at = Paths.InsertPoint(index, wx, wz)
            if at then DragPoints(wx, wz, event, at) end
        else
            Paths.Select(id, nil, false)
        end
        return true
    end
    -- empty ground: a click clears the point selection, a drag is a marquee (Shift adds, Ctrl toggles)
    MarqueeDrag(wx, wz, event)
    return true
end

-- ---- drawing ------------------------------------------------------------------------------------------------------------------------------------

local function PushXYZ(pts, x, z)
    table.insert(pts, x)
    table.insert(pts, Ground(x, z) + 0.2)
    table.insert(pts, z)
end

local function Set(id, pts, color, width)
    ed_overlay_set(id, pts, color, width or 0.2, 2, 3, false, true)
    drawn[id] = true
end

local function Square(id, x, z, r, color)
    local pts = {}
    PushXYZ(pts, x - r, z - r) PushXYZ(pts, x + r, z - r) PushXYZ(pts, x + r, z + r) PushXYZ(pts, x - r, z + r)
    ed_overlay_set(id, pts, color, 0.25, 2, 4, true, true)
    drawn[id] = true
end

local function Remove(keep)
    for id, _ in drawn do
        if not keep[id] then
            ed_overlay_remove(id)
            drawn[id] = nil
        end
    end
end

function Forget()
    drawn = {}
    drawKey = ''
end

--- The overlay lines for all paths. Rebuilt when the model, the selection or the zoom changes.
function Draw(ui)
    if rawget(_G, 'ed_overlay_set') == nil then return end
    local tool = ui and ui.State and ui.State.tool
    local active = tool == 'paths'
    if not active and Paths.HasPreview() then Paths.RevertPreview() end
    local visible = (active or Show) and table.getn(Paths.List) > 0
    if not visible then
        if next(drawn) ~= nil then Remove({}) drawKey = '' end
        return
    end
    local px = PixelSize()
    local key = string.format('%d|%s|%s|%d|%s', Paths.Revision, tostring(Paths.Current), tostring(active), math.floor(math.log(px) * 6), Paths.Mode)
    if Box then key = key .. string.format('|%.1f,%.1f,%.1f,%.1f', Box[1], Box[2], Box[3], Box[4]) end
    for i, _ in Paths.Sel do key = key .. ',' .. i end
    if key == drawKey then return end
    drawKey = key
    local keep = {}
    local function Mark(id) keep[id] = true end
    for _, path in Paths.List do
        local isCur = path.id == Paths.Current
        local S = Dense(path)
        local base = isCur and 'FFFFE040' or (active and 'FF30C8FF' or '9030C8FF')
        if S.n >= 2 then
            local rep = isCur and Paths.Modes[path.mode] and Paths.Modes[path.mode].grade and Paths.Report(path) or nil
            local line = {}
            for k = 1, S.n do PushXYZ(line, S.x[k], S.z[k]) end
            local id = 'pt:' .. path.id
            Set(id, line, base, isCur and 0.28 or 0.2)
            Mark(id)
            -- the stretches that are too steep for the grade limit
            if rep and path.limitGrade or (rep and rep.max > (path.grade or 0.75)) then
                for n, range in rep.flagged do
                    if n > 12 then break end
                    local pts = {}
                    for k = range[1], range[2] do PushXYZ(pts, S.x[k], S.z[k]) end
                    local bid = 'pt:' .. path.id .. ':bad' .. n
                    Set(bid, pts, 'FFFF3030', 0.45)
                    Mark(bid)
                end
            end
            -- width edges of the selected path: the half width (solid) and the end of the falloff (dim)
            if isCur and active then
                local l1, r1, l2, r2 = {}, {}, {}, {}
                for k = 1, S.n do
                    local j = math.min(S.n, k + 1)
                    local i0 = math.max(1, k - 1)
                    local dx, dz = S.x[j] - S.x[i0], S.z[j] - S.z[i0]
                    local dl = math.sqrt(dx * dx + dz * dz)
                    if dl > 0.0001 then
                        local nx, nz = -dz / dl, dx / dl
                        PushXYZ(l1, S.x[k] + nx * S.w[k], S.z[k] + nz * S.w[k])
                        PushXYZ(r1, S.x[k] - nx * S.w[k], S.z[k] - nz * S.w[k])
                        PushXYZ(l2, S.x[k] + nx * (S.w[k] + S.f[k]), S.z[k] + nz * (S.w[k] + S.f[k]))
                        PushXYZ(r2, S.x[k] - nx * (S.w[k] + S.f[k]), S.z[k] - nz * (S.w[k] + S.f[k]))
                    end
                end
                Set('pt:' .. path.id .. ':l1', l1, 'C0FFFFFF', 0.15) Mark('pt:' .. path.id .. ':l1')
                Set('pt:' .. path.id .. ':r1', r1, 'C0FFFFFF', 0.15) Mark('pt:' .. path.id .. ':r1')
                Set('pt:' .. path.id .. ':l2', l2, '60FFFFFF', 0.12) Mark('pt:' .. path.id .. ':l2')
                Set('pt:' .. path.id .. ':r2', r2, '60FFFFFF', 0.12) Mark('pt:' .. path.id .. ':r2')
            end
            -- an arrow head at the end shows the way of travel
            do
                local e = S.n
                local b = math.max(1, e - math.max(1, math.floor(3 * px / 2)))
                local dx, dz = S.x[e] - S.x[b], S.z[e] - S.z[b]
                local dl = math.sqrt(dx * dx + dz * dz)
                if dl > 0.0001 then
                    dx, dz = dx / dl, dz / dl
                    local h = 8 * px
                    local pts = {}
                    PushXYZ(pts, S.x[e] - dx * h - dz * h * 0.5, S.z[e] - dz * h + dx * h * 0.5)
                    PushXYZ(pts, S.x[e], S.z[e])
                    PushXYZ(pts, S.x[e] - dx * h + dz * h * 0.5, S.z[e] - dz * h - dx * h * 0.5)
                    Set('pt:' .. path.id .. ':arrow', pts, base, 0.25)
                    Mark('pt:' .. path.id .. ':arrow')
                end
            end
        end
        -- control points (every path when it is the tool, the current one otherwise) and tangent handles
        if active or isCur then
            local out, inn
            if path.kind == 'bezier' then out, inn = Paths.HandleVectorsOf(path) end
            for i, p in path.points do
                local selected = isCur and Paths.Sel[i]
                local r = (selected and 5 or 3.5) * px
                local id = string.format('pt:%s:c%d', path.id, i)
                Square(id, p.x, p.z, r, selected and 'FFFFFFFF' or (isCur and 'FFFFE040' or 'FF30C8FF'))
                Mark(id)
                if isCur and selected and out then
                    local o = { p.x + out[i][1], p.z + out[i][2] }
                    local n = { p.x + inn[i][1], p.z + inn[i][2] }
                    local pts = {}
                    PushXYZ(pts, n[1], n[2]) PushXYZ(pts, p.x, p.z) PushXYZ(pts, o[1], o[2])
                    Set(string.format('pt:%s:h%d', path.id, i), pts, 'FF80FF80', 0.15)
                    Mark(string.format('pt:%s:h%d', path.id, i))
                    Square(string.format('pt:%s:ho%d', path.id, i), o[1], o[2], 3.5 * px, 'FF80FF80')
                    Mark(string.format('pt:%s:ho%d', path.id, i))
                    Square(string.format('pt:%s:hi%d', path.id, i), n[1], n[2], 3.5 * px, 'FF80FF80')
                    Mark(string.format('pt:%s:hi%d', path.id, i))
                end
            end
        end
    end
    if Box then
        local pts = {}
        PushXYZ(pts, Box[1], Box[2]) PushXYZ(pts, Box[3], Box[2]) PushXYZ(pts, Box[3], Box[4]) PushXYZ(pts, Box[1], Box[4]) PushXYZ(pts, Box[1], Box[2])
        Set('pt:marquee', pts, 'FFFFFFFF', 0.2)
        Mark('pt:marquee')
    end
    Remove(keep)
end
