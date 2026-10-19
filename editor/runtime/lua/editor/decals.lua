-- Terrain decals: the catalog of decal textures, the decal brush (click = one, drag = scatter by density; random size and heading; an albedo decal can bring its
-- matching normals decal) and the decal eraser.
--
--   Catalog()            list of { path, name, group } of every /env/**/decals/*_albedo.dds, sorted by group and name
--   Active               the albedo texture the brush places
--   Settings             size (world units), sizeVar (percent), density (decals per 100 square units), minDist, randomHeading, withNormals, cutoff (LOD distance),
--                        onlyActive (eraser)
--   Mode                 'place' | 'erase'
--   BeginStroke() / Dab(cx, cz, brush, slot, image) / EndStroke(); TakeEntry()
--   Selection                the Decal select tool's selection: list of { tex, x, z } (an albedo decal and its normals decal are picked together);
--                            SelRevision; Pick(wx, wz), Select(d, mode), ClearSelection(), Press(wx, wz, event), MoveSelected(dx, dz), MoveTo(x, z), RotateSelected(deg),
--                            SetHeading(deg), SetSize(size), DeleteSelected(), Info(), SelectedData(), Paste(list, dx, dz); DragOffset while dragging
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local History = import('/lua/editor/history.lua')

Active = false

Settings = {
    size = 12,
    sizeVar = 30,
    density = 0.5,
    minDist = 6,
    randomHeading = true,
    withNormals = true,
    cutoff = 1000,
    onlyActive = false,
}

local catalog = false
local stroke = false
local pending = false

local function Group(path)
    local parts = {}
    for p in string.gfind(path, '[^/]+') do table.insert(parts, p) end
    return parts[2] or ''
end

function Catalog()
    if catalog then return catalog end
    local list = {}
    for _, f in DiskFindFiles('/env', '*_albedo.dds') or {} do
        local lower = string.lower(f)
        if string.find(lower, '/decals/', 1, true) then
            local name = string.gsub(string.gsub(f, '^.*/', ''), '_albedo%.dds$', '')
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

--- The matching normals texture of an albedo decal, or nil.
local function NormalsOf(path)
    local n = string.gsub(path, '_[aA][lL][bB][eE][dD][oO]%.dds$', '_normals.dds')
    if n ~= path and DiskGetFileInfo(n) then return n end
    return nil
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

function BeginStroke()
    stroke = { added = {}, removed = {}, grid = {}, first = {} }
end

local function Near(x, z)
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
    stroke.grid[key] = stroke.grid[key] or {}
    table.insert(stroke.grid[key], { x, z })
end

local function AddOne(tex, kind, x, z, heading, size)
    local index = Map.AddDecal(tex, kind, x, Ground(x, z), z, heading, size, Settings.cutoff)
    if index then
        table.insert(stroke.added, { tex = tex, kind = kind, x = x, y = Ground(x, z), z = z, heading = heading, size = size, cutoff = Settings.cutoff })
    end
    return index
end

local function Place(x, z, heading)
    local w, h = ed_terrain_info()
    if x < 1 or z < 1 or x > (w or 257) - 2 or z > (h or 257) - 2 then return false end
    if Near(x, z) then return false end
    local var = Settings.sizeVar / 100
    local size = Settings.size * (1 + var * (math.random() * 2 - 1))
    if size < 0.5 then size = 0.5 end
    AddOne(Active, 'albedo', x, z, heading, size)
    if Settings.withNormals then
        local n = NormalsOf(Active)
        if n then AddOne(n, 'normals', x, z, heading, size) end
    end
    Remember(x, z)
    return true
end

--- Index of the decal (map decal ordinal) with this texture at this place.
local function FindIndex(tex, x, z)
    for i = ed_decal_count(), 1, -1 do
        local t0, t1, kind, px, py, pz = ed_decal_get(i)
        if t0 == tex and math.abs(px - x) < 0.01 and math.abs(pz - z) < 0.01 then return i end
    end
    return nil
end

function Dab(cx, cz, brush, slot, image)
    if not stroke then BeginStroke() end
    local r = brush.radius
    if Mode == 'erase' then
        local n = 0
        for i = ed_decal_count(), 1, -1 do
            local t0, t1, kind, x, y, z, sx, sy, sz, ox, oy, oz, cutoff = ed_decal_get(i)
            if t0 then
                local dx, dz = x - cx, z - cz
                local match = (not Settings.onlyActive) or t0 == Active or t0 == NormalsOf(Active or '')
                if dx * dx + dz * dz <= r * r and match then
                    table.insert(stroke.removed, { tex = t0, kind = kind, x = x, y = y, z = z, heading = oy, size = sx, cutoff = cutoff })
                    Map.RemoveDecal(i)
                    n = n + 1
                end
            end
        end
        return n
    end
    if not Active then return 0 end
    local placed = 0
    local function Heading()
        local h = Settings.randomHeading and (math.random() * 6.2831853) or 0
        if image then h = Symmetry.Heading(h, image) end
        return h
    end
    if not stroke.first[slot or 1] then
        stroke.first[slot or 1] = true
        if Place(cx, cz, Heading()) then placed = placed + 1 end
    end
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

local KINDS = { 'albedo', 'normals', 'watermask', 'wateralbedo', 'waternormals', 'glow', 'normalsalpha', 'glowmask', 'albedoxp' }

local function ReAdd(d)
    local kind = KINDS[d.kind] or d.kind or 'albedo'
    return Map.AddDecal(d.tex, kind, d.x, d.y, d.z, d.heading, d.size, d.cutoff)
end

local function Entry(label, added, removed)
    return {
        label = label,
        undo = function()
            for i = table.getn(added), 1, -1 do
                local d = added[i]
                local idx = FindIndex(d.tex, d.x, d.z)
                if idx then Map.RemoveDecal(idx) end
            end
            for _, d in removed do ReAdd(d) end
        end,
        redo = function()
            for _, d in added do ReAdd(d) end
            for i = table.getn(removed), 1, -1 do
                local d = removed[i]
                local idx = FindIndex(d.tex, d.x, d.z)
                if idx then Map.RemoveDecal(idx) end
            end
        end,
    }
end

function EndStroke()
    local s = stroke
    stroke = false
    pending = false
    if not s then return end
    local na, nr = table.getn(s.added), table.getn(s.removed)
    if na == 0 and nr == 0 then return end
    local label = (na > 0 and nr == 0) and ('place ' .. na .. ' decals') or ((nr > 0 and na == 0) and ('erase ' .. nr .. ' decals') or 'decals')
    pending = Entry(label, s.added, s.removed)
end

function TakeEntry()
    local e = pending
    pending = false
    return e
end

--- Drops one decal of `tex` at (x, z) and at every symmetry image (heading and size from the brush settings), as one undo step: what the asset browser does when an entry is dragged into the viewport.
--- Returns the number placed.
function PlaceAt(tex, x, z)
    Active = tex
    BeginStroke()
    local n = 0
    for _, p in Symmetry.Points(x, z) do
        local h = Settings.randomHeading and (math.random() * 6.2831853) or 0
        if Place(p.x, p.z, Symmetry.Heading(h, p)) then n = n + 1 end
    end
    EndStroke()
    local entry = TakeEntry()
    if entry then History.Push(entry) end
    return n
end


-- ---- selection ----------------------------------------------------------------------------------------------------------------------------

local Dragger = import('/lua/maui/dragger.lua').Dragger

Selection = {}
SelRevision = 0
DragOffset = false

local function Read(i)
    local t0, t1, kind, x, y, z, sx, sy, sz, ox, oy, oz, cutoff = ed_decal_get(i)
    if not t0 then return nil end
    return { tex = t0, kind = kind, x = x, y = y, z = z, size = sx, sy = sy, heading = oy, cutoff = cutoff }
end

local function Same(a, b)
    return a.tex == b.tex and math.abs(a.x - b.x) < 0.01 and math.abs(a.z - b.z) < 0.01
end

function IsSelected(d)
    for _, q in Selection do
        if Same(d, q) then return true end
    end
    return false
end

function ClearSelection()
    if table.getn(Selection) > 0 then
        Selection = {}
        SelRevision = SelRevision + 1
    end
end

--- The decal under (wx, wz): the smallest one whose disc contains the point (albedo ones first). Returns the data table or nil.
function Pick(wx, wz)
    local best, bestSize
    for i = 1, ed_decal_count() do
        local d = Read(i)
        if d then
            local dx, dz = d.x - wx, d.z - wz
            local r = d.size / 2
            if dx * dx + dz * dz <= r * r and (not bestSize or d.size < bestSize or (d.size == bestSize and d.kind == 1)) then
                best, bestSize = d, d.size
            end
        end
    end
    return best
end

--- Every decal at the same place as d (its albedo and normals decals).
local function Group(d)
    local list = {}
    for i = 1, ed_decal_count() do
        local e = Read(i)
        if e and math.abs(e.x - d.x) < 0.01 and math.abs(e.z - d.z) < 0.01 then table.insert(list, e) end
    end
    return list
end

function Select(d, mode)
    if not d then
        ClearSelection()
        return
    end
    local group = Group(d)
    if mode == 'toggle' and IsSelected(d) then
        local rest = {}
        for _, q in Selection do
            local drop = false
            for _, g in group do
                if Same(q, g) then drop = true end
            end
            if not drop then table.insert(rest, q) end
        end
        Selection = rest
    else
        if mode ~= 'add' and mode ~= 'toggle' then Selection = {} end
        for _, g in group do
            if not IsSelected(g) then table.insert(Selection, { tex = g.tex, x = g.x, z = g.z }) end
        end
    end
    SelRevision = SelRevision + 1
end

--- Data of the first selected decal (the panel edits the group through it) and how many decals are selected.
function Info()
    if table.getn(Selection) == 0 then return nil end
    local idx = FindIndex(Selection[1].tex, Selection[1].x, Selection[1].z)
    local d = idx and Read(idx)
    if d then d.count = table.getn(Selection) end
    return d
end

function SelectedData()
    local list = {}
    for _, p in Selection do
        local idx = FindIndex(p.tex, p.x, p.z)
        local d = idx and Read(idx)
        if d then table.insert(list, d) end
    end
    return list
end

local function Transform(label, change)
    if table.getn(Selection) == 0 then return false end
    local pairsList = {}
    for _, p in Selection do
        local idx = FindIndex(p.tex, p.x, p.z)
        if idx then
            local old = Read(idx)
            local new = change(old)
            if new then
                Map.RemoveDecal(idx)
                new.y = Ground(new.x, new.z)
                ReAdd(new)
                table.insert(pairsList, { old = old, new = new })
            end
        end
    end
    if table.getn(pairsList) == 0 then return false end
    Selection = {}
    for _, e in pairsList do table.insert(Selection, { tex = e.new.tex, x = e.new.x, z = e.new.z }) end
    SelRevision = SelRevision + 1
    local function Apply(from, to)
        for _, e in pairsList do
            local idx = FindIndex(e[from].tex, e[from].x, e[from].z)
            if idx then Map.RemoveDecal(idx) end
            ReAdd(e[to])
        end
        Selection = {}
        for _, e in pairsList do table.insert(Selection, { tex = e[to].tex, x = e[to].x, z = e[to].z }) end
        SelRevision = SelRevision + 1
    end
    History.Push({ label = label, undo = function() Apply('new', 'old') end, redo = function() Apply('old', 'new') end })
    return true
end

local function Copy(o)
    local n = {}
    for k, v in o do n[k] = v end
    return n
end

function MoveSelected(dx, dz)
    return Transform('move decals', function(o)
        local n = Copy(o)
        n.x, n.z = o.x + dx, o.z + dz
        return n
    end)
end

function MoveTo(x, z)
    local info = Info()
    if not info then return false end
    return MoveSelected(x - info.x, z - info.z)
end

function RotateSelected(deg)
    local rad = math.rad(deg)
    return Transform('rotate decals', function(o)
        local n = Copy(o)
        n.heading = o.heading + rad
        return n
    end)
end

function SetHeading(deg)
    local info = Info()
    if not info then return false end
    return RotateSelected(deg - math.deg(info.heading))
end

--- Size (world units) of every selected decal.
function SetSize(size)
    if size < 0.5 then size = 0.5 end
    return Transform('resize decals', function(o)
        local n = Copy(o)
        n.size = size
        return n
    end)
end

function DeleteSelected()
    if table.getn(Selection) == 0 then return false end
    local removed = {}
    for _, p in Selection do
        local idx = FindIndex(p.tex, p.x, p.z)
        if idx then
            table.insert(removed, Read(idx))
            Map.RemoveDecal(idx)
        end
    end
    if table.getn(removed) == 0 then return false end
    ClearSelection()
    History.Push({
        label = 'delete ' .. table.getn(removed) .. ' decals',
        undo = function() for _, d in removed do ReAdd(d) end end,
        redo = function()
            for _, d in removed do
                local idx = FindIndex(d.tex, d.x, d.z)
                if idx then Map.RemoveDecal(idx) end
            end
            ClearSelection()
        end,
    })
    return true
end

--- Adds copies of `list` (SelectedData entries) moved by (dx, dz) as one undo entry and selects them. Returns the number added.
function Paste(list, dx, dz, label)
    local added = {}
    for _, d in list do
        local n = Copy(d)
        n.x, n.z = d.x + dx, d.z + dz
        n.y = Ground(n.x, n.z)
        if ReAdd(n) then table.insert(added, n) end
    end
    if table.getn(added) == 0 then return 0 end
    Selection = {}
    for _, n in added do table.insert(Selection, { tex = n.tex, x = n.x, z = n.z }) end
    SelRevision = SelRevision + 1
    History.Push({
        label = label or ('paste ' .. table.getn(added) .. ' decals'),
        undo = function()
            for i = table.getn(added), 1, -1 do
                local n = added[i]
                local idx = FindIndex(n.tex, n.x, n.z)
                if idx then Map.RemoveDecal(idx) end
            end
            ClearSelection()
        end,
        redo = function() for _, n in added do ReAdd(n) end end,
    })
    return table.getn(added)
end

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- Selects every decal whose centre lies inside the world box { x0, z0, x1, z1 } (a decal and its normals decal count as one; replaces the
--- selection, or adds to it); nil box = a click on empty ground.
function SelectBox(box, additive)
    if not box then
        if not additive then ClearSelection() end
        return
    end
    local minx, maxx = math.min(box[1], box[3]), math.max(box[1], box[3])
    local minz, maxz = math.min(box[2], box[4]), math.max(box[2], box[4])
    if not additive then Selection = {} end
    for i = 1, ed_decal_count() do
        local d = Read(i)
        if d and d.x >= minx and d.x <= maxx and d.z >= minz and d.z <= maxz and not IsSelected(d) then
            table.insert(Selection, { tex = d.tex, x = d.x, z = d.z })
        end
    end
    SelRevision = SelRevision + 1
end

--- Click of the Decal select tool (like the prop select tool: Shift toggles, a drag moves the selection, empty ground clears, a drag from empty ground
--- selects the decals in the box).
function Press(wx, wz, event)
    local shift = IsKeyDown and IsKeyDown('Shift')
    local hit = Pick(wx, wz)
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
        if off and (math.abs(off[1]) + math.abs(off[2])) > 0.2 then MoveSelected(off[1], off[2]) end
        self:Destroy()
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end

--- Find / replace: every decal with texture `from` gets texture `to` (same place, heading, size), one undo step. Returns how many.
function ReplaceTexture(from, to)
    Selection = {}
    for i = 1, ed_decal_count() do
        local d = Read(i)
        if d and d.tex == from then table.insert(Selection, { tex = d.tex, x = d.x, z = d.z }) end
    end
    local n = table.getn(Selection)
    if n == 0 then return 0 end
    SelRevision = SelRevision + 1
    local ok = Transform('replace decals ' .. (string.gsub(from, '^.*/', '')) .. ' with ' .. (string.gsub(to, '^.*/', '')), function(o)
        local c = {}
        for k, v in o do c[k] = v end
        c.tex = to
        return c
    end)
    return ok and n or 0
end

--- Adds copies of `list` (SelectedData entries, positions and headings final) as one undo entry and selects them. Returns the number added.
function PasteExact(list, label)
    return Paste(list, 0, 0, label)
end
