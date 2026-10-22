-- Props: the catalog of prop blueprints, the prop brush (single click or scatter by density, random scale and heading) and the prop eraser.
-- The map keeps its props through Map.AddProp / Map.RemoveProp (scmap list + the sim's entity); this module only decides where and what.
--
--   Catalog()                list of { path, name, group } of every /env/**/*_prop.bp (marker props excluded), sorted by group and name
--   Active                   the blueprint path placed with the prop brush
--   Settings                 density (props per 100 square units), minDist, scaleMin / scaleMax (percent), randomHeading, onlyActive (eraser)
--   BeginStroke() / Dab(cx, cz, brush, slot, image) / EndStroke(); TakeEntry() -> the undo entry of the finished stroke
--   Mode                     'place' or 'erase' (set by the tool, ui.lua / terrain.lua)
--   Selection                list of { bp, x, z } (the Prop select tool); SelRevision changes with it; Pick(wx, wz, radius), Select(p, mode), ClearSelection(),
--                            Press(wx, wz, event) (the tool's click), DeleteSelected(), MoveSelected(dx, dz), MoveTo(x, z), RotateSelected(deg), ScaleSelected(factor),
--                            Info() -> data of the single selected prop; DragOffset while a drag is under way
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local MeshView = import('/lua/editor/meshview.lua')
local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

Active = false

Settings = {
    density = 4,           -- props per 100 square units under the brush (a stroke places this many on newly covered ground)
    minDist = 2,           -- no two props of one stroke closer than this
    scaleMin = 80,         -- percent
    scaleMax = 120,
    randomHeading = true,
    onlyActive = false,    -- the eraser removes only props of the active blueprint
}

local catalog = false
local stroke = false
local pending = false

Selection = {}
SelRevision = 0
DragOffset = false      -- { dx, dz } while the selection is dragged
Revision = 0            -- bumped by every change of the prop list (the pick index follows it)
local Dragger = import('/lua/maui/dragger.lua').Dragger
local History = import('/lua/editor/history.lua')

local function Changed()
    Revision = Revision + 1
end

local function Group(path)
    local parts = {}
    for p in string.gfind(path, '[^/]+') do table.insert(parts, p) end
    -- /env/<env>/props/.../<file>
    return parts[2] or ''
end

--- Every prop blueprint of the game data (and the active mods).
function Catalog()
    if catalog then return catalog end
    local list = {}
    local files = DiskFindFiles('/env', '*_prop.bp') or {}
    for _, f in files do
        local lower = string.lower(f)
        if not string.find(lower, '/markers/', 1, true) then
            local name = string.gsub(string.gsub(f, '^.*/', ''), '_prop%.bp$', '')
            table.insert(list, { path = f, name = name, group = Group(lower) })
        end
    end
    table.sort(list, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.name < b.name
    end)
    catalog = list
    return list
end

local function Ground(x, z)
    local h = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
    return MeshView.GroundAt(x, z, h)          -- props stand on the mesh of a mesh map (convert.py does the same)
end

local function Size()
    local w, h = ed_terrain_info()
    return (w or 257) - 1, (h or 257) - 1
end

function BeginStroke()
    stroke = { added = {}, removed = {}, grid = {}, first = {} }
end

local function NearOther(x, z)
    local d = Settings.minDist
    if d <= 0 then return false end
    local gx, gz = math.floor(x / d), math.floor(z / d)
    for ix = gx - 1, gx + 1 do
        for iz = gz - 1, gz + 1 do
            local cell = stroke.grid[ix * 100003 + iz]
            if cell then
                for _, p in cell do
                    local dx, dz = p[1] - x, p[2] - z
                    if dx * dx + dz * dz < d * d then return true end
                end
            end
        end
    end
    return false
end

local function Remember(x, z)
    local d = math.max(0.01, Settings.minDist)
    local key = math.floor(x / d) * 100003 + math.floor(z / d)
    local cell = stroke.grid[key]
    if not cell then
        cell = {}
        stroke.grid[key] = cell
    end
    table.insert(cell, { x, z })
end

local function Place(x, z, heading)
    local maxX, maxZ = Size()
    if x < 1 or z < 1 or x > maxX - 1 or z > maxZ - 1 then return false end
    if NearOther(x, z) then return false end
    local lo, hi = Settings.scaleMin / 100, Settings.scaleMax / 100
    if hi < lo then lo, hi = hi, lo end
    local scale = lo + (hi - lo) * math.random()
    local y = Ground(x, z)
    local index = Map.AddProp(Active, x, y, z, heading, scale)
    if not index then return false end
    Remember(x, z)
    table.insert(stroke.added, { bp = Active, x = x, y = y, z = z, heading = heading, scale = scale })
    return true
end

--- One dab of the prop brush at (cx, cz). `image` is the symmetry image record (its heading rule). Returns the number of props placed or removed.
function Dab(cx, cz, brush, slot, image)
    if not stroke then BeginStroke() end
    local r = brush.radius
    if Mode == 'erase' then
        local count = ed_prop_count()
        local n = 0
        -- walk backwards: removing shifts the indices above
        for i = count, 1, -1 do
            local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
            if bp then
                local dx, dz = x - cx, z - cz
                if dx * dx + dz * dz <= r * r and ((not Settings.onlyActive) or bp == Active) then
                    table.insert(stroke.removed, { bp = bp, x = x, y = y, z = z, heading = 2 * math.atan2(qy, qw), sx = sx, sy = sy, sz = sz })
                    Map.RemoveProp(i)
                    n = n + 1
                end
            end
        end
        return n
    end
    if not Active then return 0 end
    local placed = 0
    local function Heading()
        local h = Settings.randomHeading and import('/lua/editor/toolopts.lua').RandomHeading('props') or 0
        if image then h = Symmetry.Heading(h, image) end
        return h
    end
    if not stroke.first[slot or 1] then
        stroke.first[slot or 1] = true
        if Place(cx, cz, Heading()) then placed = placed + 1 end        -- the click itself places one at the centre
    end
    -- newly covered ground of a dab at spacing radius / 3: a strip 2r wide and r / 3 long
    local want = Settings.density / 100 * (2 * r) * (r / 3)
    local count = math.floor(want)
    if math.random() < want - count then count = count + 1 end
    for i = 1, count do
        local a = math.random() * 6.2831853
        local d = r * math.sqrt(math.random())
        if Place(cx + math.cos(a) * d, cz + math.sin(a) * d, Heading()) then placed = placed + 1 end
    end
    return placed
end

--- Index of the prop at (bp, x, z), searched from the end (where fresh props are).
local function FindIndex(bp, x, z)
    for i = ed_prop_count(), 1, -1 do
        local b, px, py, pz = ed_prop_get(i)
        if b == bp and math.abs(px - x) < 0.01 and math.abs(pz - z) < 0.01 then return i end
    end
    return nil
end

local function Entry(label, added, removed)
    return {
        label = label,
        undo = function()
            for i = table.getn(added), 1, -1 do
                local p = added[i]
                local idx = FindIndex(p.bp, p.x, p.z)
                if idx then Map.RemoveProp(idx) end
            end
            for _, p in removed do
                Map.AddProp(p.bp, p.x, p.y, p.z, p.heading, { p.sx, p.sy, p.sz })
            end
            Changed()
        end,
        redo = function()
            for _, p in added do Map.AddProp(p.bp, p.x, p.y, p.z, p.heading, p.scale) end
            for i = table.getn(removed), 1, -1 do
                local p = removed[i]
                local idx = FindIndex(p.bp, p.x, p.z)
                if idx then Map.RemoveProp(idx) end
            end
            Changed()
        end,
    }
end

function EndStroke()
    local s = stroke
    stroke = false
    pending = false
    if not s then return end
    Changed()
    local na, nr = table.getn(s.added), table.getn(s.removed)
    if na == 0 and nr == 0 then return end
    if na > 0 and nr == 0 then
        pending = Entry('place ' .. na .. ' props', s.added, s.removed)
    elseif nr > 0 and na == 0 then
        pending = Entry('erase ' .. nr .. ' props', s.added, s.removed)
    else
        pending = Entry('props', s.added, s.removed)
    end
end

function TakeEntry()
    local e = pending
    pending = false
    return e
end

--- Tool settings (toolopts.lua): whether props snap to the build grid (default on: half a unit, as placing always did), and the step in degrees of a stepped rotation (0 = free).
function SnapToGrid() return import('/lua/editor/toolopts.lua').SnapToGrid('props') end
function RotationStep() return import('/lua/editor/toolopts.lua').RotationStep('props') end

--- A move of the selection by (dx, dz) put on the grid like a placed prop: the first selected prop goes to the nearest half unit, the others move by the same amount (a group keeps its layout).
--- Unchanged when snapping is off. For drags only; typed coordinates (MoveTo) stay exact.
function SnapDelta(dx, dz)
    if not SnapToGrid() then return dx, dz end
    local p = Selection[1]
    if not p then return dx, dz end
    return math.floor((p.x + dx) * 2 + 0.5) / 2 - p.x, math.floor((p.z + dz) * 2 + 0.5) / 2 - p.z
end

--- Drops one prop of `bp` at (x, z) and at every symmetry image (heading and size from the brush settings), as one undo step: what the asset browser does when an entry is dragged into the viewport.
--- Returns the number placed.
function PlaceAt(bp, x, z)
    Active = bp
    BeginStroke()
    local n = 0
    for _, p in Symmetry.Points(x, z) do
        local h = Settings.randomHeading and import('/lua/editor/toolopts.lua').RandomHeading('props') or 0
        if Place(p.x, p.z, Symmetry.Heading(h, p)) then n = n + 1 end
    end
    EndStroke()
    local entry = TakeEntry()
    if entry then History.Push(entry) end
    return n
end


-- ---- picking ------------------------------------------------------------------------------------------------------------------------------

local pickIndex = { rev = -1, count = -1, cells = {} }
local CELL = 8

local function Ground2(x, z)
    local h = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
    return MeshView.GroundAt(x, z, h)
end

local function EnsureIndex()
    local count = ed_prop_count()
    if pickIndex.rev == Revision and pickIndex.count == count then return end
    pickIndex = { rev = Revision, count = count, cells = {} }
    for i = 1, count do
        local bp, x, y, z = ed_prop_get(i)
        if bp then
            local key = math.floor(x / CELL) * 100003 + math.floor(z / CELL)
            local cell = pickIndex.cells[key]
            if not cell then
                cell = {}
                pickIndex.cells[key] = cell
            end
            table.insert(cell, { bp = bp, x = x, z = z })
        end
    end
end

--- The prop nearest to (wx, wz) within `radius` world units: { bp, x, z }, or nil.
function Pick(wx, wz, radius)
    radius = radius or 2.5
    EnsureIndex()
    local best, bestD
    local r = math.ceil(radius / CELL)
    local gx, gz = math.floor(wx / CELL), math.floor(wz / CELL)
    for ix = gx - r, gx + r do
        for iz = gz - r, gz + r do
            local cell = pickIndex.cells[ix * 100003 + iz]
            if cell then
                for _, p in cell do
                    local dx, dz = p.x - wx, p.z - wz
                    local d = dx * dx + dz * dz
                    if d <= radius * radius and (not bestD or d < bestD) then best, bestD = p, d end
                end
            end
        end
    end
    return best
end

-- ---- selection ----------------------------------------------------------------------------------------------------------------------------

local function Same(a, b)
    return a.bp == b.bp and math.abs(a.x - b.x) < 0.01 and math.abs(a.z - b.z) < 0.01
end

function IsSelected(p)
    for _, q in Selection do
        if Same(p, q) then return true end
    end
    return false
end

function ClearSelection()
    if table.getn(Selection) > 0 then
        Selection = {}
        SelRevision = SelRevision + 1
    end
end

--- mode: nil / 'set' replaces the selection, 'add', 'toggle'.
function Select(p, mode)
    if not p then
        ClearSelection()
        return
    end
    if mode == 'toggle' and IsSelected(p) then
        local rest = {}
        for _, q in Selection do
            if not Same(p, q) then table.insert(rest, q) end
        end
        Selection = rest
    else
        if mode ~= 'add' and mode ~= 'toggle' then Selection = {} end
        if not IsSelected(p) then table.insert(Selection, { bp = p.bp, x = p.x, z = p.z }) end
    end
    SelRevision = SelRevision + 1
end

--- Everything about the prop at index i: { bp, x, y, z, heading (radians), sx, sy, sz }.
local function Read(i)
    local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
    if not bp then return nil end
    return { bp = bp, x = x, y = y, z = z, heading = 2 * math.atan2(qy, qw), sx = sx, sy = sy, sz = sz }
end

--- Heading (radians) of a selected prop { bp, x, z } (0 when it cannot be found).
function SelectedHeading(p)
    local idx = FindIndex(p.bp, p.x, p.z)
    local d = idx and Read(idx)
    return d and d.heading or 0
end

function Info()
    if table.getn(Selection) ~= 1 then return nil end
    local idx = FindIndex(Selection[1].bp, Selection[1].x, Selection[1].z)
    return idx and Read(idx) or nil
end

local function ReAdd(d)
    return Map.AddProp(d.bp, d.x, d.y, d.z, d.heading, { d.sx, d.sy, d.sz })
end

--- Applies `change(old) -> new` to every selected prop (remove + add: the sim's entity moves with it) as one undo entry.
local function Transform(label, change)
    if table.getn(Selection) == 0 then return false end
    local pairsList = {}
    for _, p in Selection do
        local idx = FindIndex(p.bp, p.x, p.z)
        if idx then
            local old = Read(idx)
            local new = change(old)
            if new then
                Map.RemoveProp(idx)
                new.y = Ground2(new.x, new.z)
                ReAdd(new)
                table.insert(pairsList, { old = old, new = new })
            end
        end
    end
    if table.getn(pairsList) == 0 then return false end
    Changed()
    Selection = {}
    for _, e in pairsList do table.insert(Selection, { bp = e.new.bp, x = e.new.x, z = e.new.z }) end
    SelRevision = SelRevision + 1
    local function Apply(from, to)
        for _, e in pairsList do
            local idx = FindIndex(e[from].bp, e[from].x, e[from].z)
            if idx then Map.RemoveProp(idx) end
            ReAdd(e[to])
        end
        Selection = {}
        for _, e in pairsList do table.insert(Selection, { bp = e[to].bp, x = e[to].x, z = e[to].z }) end
        SelRevision = SelRevision + 1
        Changed()
    end
    History.Push({ label = label, undo = function() Apply('new', 'old') end, redo = function() Apply('old', 'new') end })
    return true
end

local function MoveSelectedOnly(dx, dz)
    return Transform('move props', function(o)
        local n = {}
        for k, v in o do n[k] = v end
        n.x, n.z = o.x + dx, o.z + dz
        return n
    end)
end

local function RotateSelectedOnly(deg)
    local rad = math.rad(deg)
    return Transform('rotate props', function(o)
        local n = {}
        for k, v in o do n[k] = v end
        n.heading = o.heading + rad
        return n
    end)
end

--- The props that stand at the mirror images of the selected ones (same blueprint, with symmetry on): groups, see symmetry.lua Plan.
local function MirrorPlan()
    if Symmetry.Mode == 'off' or table.getn(Selection) == 0 then return nil end
    local found = {}
    for _, p in Selection do
        for _, img in Symmetry.Points(p.x, p.z) do
            if img.kind ~= 'id' then
                local c = Pick(img.x, img.z, 1.5)
                if c and c.bp == p.bp then table.insert(found, c) end
            end
        end
    end
    if table.getn(found) == 0 then return nil end
    return Symmetry.Plan(Selection, function(p) return p.x, p.z end, found, function(a, b) return a.bp == b.bp end, function(c) return IsSelected(c) end)
end

local function WithMirrors(plan, act, label)
    local main = Selection
    local pushed = 1
    for _, g in plan do
        Selection = {}
        for _, c in g.targets do table.insert(Selection, { bp = c.bp, x = c.x, z = c.z }) end
        if act(g) then pushed = pushed + 1 end
    end
    Selection = main
    SelRevision = SelRevision + 1
    if pushed > 1 then History.Merge(pushed, label) end
end

function MoveSelected(dx, dz)
    local plan = MirrorPlan()
    local ok = MoveSelectedOnly(dx, dz)
    if ok and plan then
        local main = Selection
        WithMirrors(plan, function(g)
            local mdx, mdz = Symmetry.ImageDelta(g.key, g.refX, g.refZ, dx, dz)
            return MoveSelectedOnly(mdx, mdz)
        end, 'move props (with mirror)')
        Selection = main
    end
    return ok
end

--- One selected prop to an absolute position.
function MoveTo(x, z)
    local info = Info()
    if not info then return false end
    return MoveSelected(x - info.x, z - info.z)
end

function RotateSelected(deg)
    local plan = MirrorPlan()
    local ok = RotateSelectedOnly(deg)
    if ok and plan then
        local main = Selection
        WithMirrors(plan, function(g) return RotateSelectedOnly(Symmetry.ImageTurn(g.kind, deg)) end, 'turn props (with mirror)')
        Selection = main
    end
    return ok
end

--- Sets the heading of the single selected prop (degrees).
function SetHeading(deg)
    local info = Info()
    if not info then return false end
    return RotateSelected(deg - math.deg(info.heading))
end

function ScaleSelected(factor)
    return Transform('scale props', function(o)
        local n = {}
        for k, v in o do n[k] = v end
        n.sx, n.sy, n.sz = o.sx * factor, o.sy * factor, o.sz * factor
        return n
    end)
end

function DeleteSelected()
    if table.getn(Selection) == 0 then return false end
    local removed = {}
    for _, p in Selection do
        local idx = FindIndex(p.bp, p.x, p.z)
        if idx then
            table.insert(removed, Read(idx))
            Map.RemoveProp(idx)
        end
    end
    if table.getn(removed) == 0 then return false end
    Selection = {}
    SelRevision = SelRevision + 1
    Changed()
    History.Push({
        label = 'delete ' .. table.getn(removed) .. ' props',
        undo = function()
            for _, d in removed do ReAdd(d) end
            Changed()
        end,
        redo = function()
            for _, d in removed do
                local idx = FindIndex(d.bp, d.x, d.z)
                if idx then Map.RemoveProp(idx) end
            end
            ClearSelection()
            Changed()
        end,
    })
    return true
end

-- ---- the tool ----------------------------------------------------------------------------------------------------------------------------

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- Selects every prop inside the selection box (tools.lua BoxHas: a rectangle on the screen, or the world box { x0, z0, x1, z1 }; replacing the selection, or adding to it);
--- nil box = a click on empty ground.
function SelectBox(box, additive)
    if not box then
        if not additive then ClearSelection() end
        return
    end
    local BoxHas = import('/lua/editor/tools.lua').BoxHas
    if not additive then Selection = {} end
    for i = 1, ed_prop_count() do
        local bp, x, y, z = ed_prop_get(i)
        if bp and BoxHas(box, x, z, y) then
            local p = { bp = bp, x = x, z = z }
            if not IsSelected(p) then table.insert(Selection, p) end
        end
    end
    SelRevision = SelRevision + 1
end

--- Click of the Prop select tool: picks a prop (Shift adds / removes), a click on empty ground clears and a drag from empty ground selects the props in the
--- box; dragging a selected prop moves the selection.
function Press(wx, wz, event)
    local shift = IsKeyDown and IsKeyDown('Shift')
    local hit = Pick(wx, wz, 3)
    if not hit then
        import('/lua/editor/tools.lua').BeginBoxSelect(wx, wz, event, shift and true or false, SelectBox)
        return true
    end
    if shift then
        Select(hit, 'toggle')
        return true
    end
    if not IsSelected(hit) then Select(hit, 'set') end
    DragOffset = { 0, 0 }
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if mx then DragOffset = { mx - wx, mz - wz } end
    end
    local function Done(self)
        local off = DragOffset
        DragOffset = false
        if off and (math.abs(off[1]) + math.abs(off[2])) > 0.2 then MoveSelected(SnapDelta(off[1], off[2])) end
        self:Destroy()
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end


--- Everything about every selected prop (for the clipboard): list of { bp, x, y, z, heading, sx, sy, sz }.
function SelectedData()
    local list = {}
    for _, p in Selection do
        local idx = FindIndex(p.bp, p.x, p.z)
        if idx then
            local d = Read(idx)
            if d then table.insert(list, d) end
        end
    end
    return list
end

--- Adds copies of `list` (SelectedData entries) moved by (dx, dz) as one undo entry and selects them. Returns the number added.
function Paste(list, dx, dz, label)
    local added = {}
    for _, d in list do
        local n = {}
        for k, v in d do n[k] = v end
        n.x, n.z = d.x + dx, d.z + dz
        n.y = Ground2(n.x, n.z)
        if ReAdd(n) then table.insert(added, n) end
    end
    if table.getn(added) == 0 then return 0 end
    Changed()
    Selection = {}
    for _, n in added do table.insert(Selection, { bp = n.bp, x = n.x, z = n.z }) end
    SelRevision = SelRevision + 1
    History.Push({
        label = label or ('paste ' .. table.getn(added) .. ' props'),
        undo = function()
            for i = table.getn(added), 1, -1 do
                local n = added[i]
                local idx = FindIndex(n.bp, n.x, n.z)
                if idx then Map.RemoveProp(idx) end
            end
            ClearSelection()
            Changed()
        end,
        redo = function()
            for _, n in added do ReAdd(n) end
            Changed()
        end,
    })
    return table.getn(added)
end

--- Find / replace: every prop of blueprint `from` becomes a prop of blueprint `to` (same place, heading and scale), one undo step. Returns how many.
function ReplaceBlueprint(from, to)
    Selection = {}
    for i = 1, ed_prop_count() do
        local bp, x, y, z = ed_prop_get(i)
        if bp == from then table.insert(Selection, { bp = bp, x = x, z = z }) end
    end
    local n = table.getn(Selection)
    if n == 0 then return 0 end
    SelRevision = SelRevision + 1
    local ok = Transform('replace props ' .. (string.gsub(from, '^.*/', '')) .. ' with ' .. (string.gsub(to, '^.*/', '')), function(o)
        local c = {}
        for k, v in o do c[k] = v end
        c.bp = to
        return c
    end)
    return ok and n or 0
end

--- Adds the props of `list` (SelectedData entries, positions and headings final) as one undo entry and selects them. Returns the number added.
function PasteExact(list, label)
    return Paste(list, 0, 0, label)
end
