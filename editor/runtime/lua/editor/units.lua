-- Units placed on the map (the army's initial units of the save file): catalog of the unit blueprints, the Unit tool (a click puts the chosen unit down for the chosen army),
-- selecting, moving, rotating and deleting them, all with undo. The editing sim shows each unit as an entity (callbacks EdSpawnUnit / EdRemoveUnitAt in schook/lua/simcallbacks.lua);
-- the save file keeps `Armies[<army>].Units.Units.INITIAL.Units[<name>] = { type, orders, platoon, Position, Orientation }`, which the scenario script spawns when the map is
-- played or opened. An army that is new in this session (a start position added a moment ago) is not in the running sim: its units appear after saving and reopening.
--
--   Catalog()               list of { id, desc, name, faction } of every unit blueprint, sorted by id
--   Active                  the blueprint id the Unit tool places          ArmyName      the army it is placed for
--   Armies()                the army names of the save file
--   Place(x, z)             puts the unit down (with symmetry: every image); Selection / Pick / Select / Press / MoveSelected / RotateSelected / DeleteSelected / Info
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local History = import('/lua/editor/history.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Dragger = import('/lua/maui/dragger.lua').Dragger

Active = false
ArmyName = 'ARMY_1'
Group = 'INITIAL'       -- the group the Unit tool puts units into (INITIAL spawns with the map, the others are for the mission's Spawn nodes)
Selection = {}          -- list of { army, name }
SelRevision = 0
DragOffset = false

local catalog = false

--- Bumped by every store / unstore of a unit (Add, Remove and so every edit, paste, undo and redo): the cached list of All() and the overlay's rings compare it.
Rev = 0

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Vec3(x, y, z)
    return { x, y, z, type = 'VECTOR3' }
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

--- UEF / Aeon / Cybran / Seraphim from the blueprint categories (the 2nd letter of the id is the fallback: uel = UEF, ual = Aeon, url = Cybran, xsl = Seraphim), else 'Other'.
function FactionOf(id, bp)
    local found = {}
    for _, cat in bp.Categories or {} do found[cat] = true end
    if found.UEF then return 'UEF' elseif found.AEON then return 'Aeon' elseif found.CYBRAN then return 'Cybran' elseif found.SERAPHIM then return 'Seraphim' end
    local f = string.sub(id, 2, 2)
    return (f == 'e' and 'UEF') or (f == 'a' and 'Aeon') or (f == 'r' and 'Cybran') or (f == 's' and 'Seraphim') or 'Other'
end

--- Every unit blueprint the UI knows.
function Catalog()
    if catalog then return catalog end
    local list = {}
    for id, bp in __blueprints or {} do
        if type(id) == 'string' and string.sub(id, 1, 1) ~= '/' and bp.BlueprintId == id and bp.Physics and bp.Categories then
            local desc = bp.Description and LOC(bp.Description) or ''
            local name = bp.General and bp.General.UnitName and LOC(bp.General.UnitName) or ''
            local faction = FactionOf(id, bp)
            table.insert(list, { id = id, desc = desc, name = name, faction = faction })
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    catalog = list
    return list
end

function Armies()
    local names = {}
    if Map.Doc then
        for name, _ in Map.Doc.save.Armies or {} do table.insert(names, name) end
    end
    table.sort(names)
    return names
end

--- The GROUP table of a group path ('INITIAL', 'M2_Transition/M2_Dostya_Base_Defenders': groups of a mission map nest to any depth; the path joins the names with '/'),
--- created on the way when `create`. nil when it does not exist.
local function GroupNode(army, path, create)
    if not Map.Doc then return nil end
    local a = Map.Doc.save.Armies and Map.Doc.save.Armies[army]
    if not a then return nil end
    if create then a.Units = a.Units or { type = 'GROUP', orders = '', platoon = '', Units = {} } end
    local node = a.Units
    if not node then return nil end
    for seg in string.gfind(path or 'INITIAL', '[^/]+') do
        node.Units = node.Units or (create and {} or nil)
        local child = node.Units and node.Units[seg]
        if type(child) ~= 'table' or (child.type ~= 'GROUP' and not create) then child = nil end
        if not child then
            if not create then return nil end
            child = { type = 'GROUP', orders = '', platoon = '', Units = {} }
            node.Units[seg] = child
        end
        node = child
    end
    return node
end

--- The table of the units of an army's group (INITIAL by default; created when `create`), or nil when the army or group does not exist.
local function UnitTable(army, create, group)
    local node = GroupNode(army, group or 'INITIAL', create)
    if not node then return nil end
    if create then node.Units = node.Units or {} end
    return node.Units
end

--- The group paths of an army (INITIAL first, then every group below it and the others, nested ones as 'outer/inner', sorted).
function Groups(army)
    local list = {}
    local a = Map.Doc and Map.Doc.save.Armies and Map.Doc.save.Armies[army]
    local function Walk(node, prefix)
        for name, g in node.Units or {} do
            if type(g) == 'table' and g.type == 'GROUP' then
                local path = prefix .. name
                if path ~= 'INITIAL' then table.insert(list, path) end
                Walk(g, path .. '/')
            end
        end
    end
    if a and a.Units then Walk(a.Units, '') end
    table.sort(list)
    table.insert(list, 1, 'INITIAL')
    return list
end

--- Does the game create the units of this group by itself when the map starts (INITIAL and everything below it)? The script spawns the others.
function GameSpawns(group)
    return group == 'INITIAL' or string.sub(group or '', 1, 8) == 'INITIAL/'
end

--- All units of the map: list of { army, group, name, bp, x, z, y, heading }.
function All()
    local list = {}
    for _, army in Armies() do
        for _, group in Groups(army) do
            for name, u in UnitTable(army, false, group) or {} do
                if type(u) == 'table' and u.type and u.Position then
                    table.insert(list, { army = army, group = group, name = name, bp = u.type, x = u.Position[1], y = u.Position[2], z = u.Position[3],
                                         heading = (u.Orientation and u.Orientation[2]) or 0 })
                end
            end
        end
    end
    return list
end

-- All() builds a table per unit (2100 on a mission map) and walks and sorts every group: per-frame callers (the overlay's rings, the gizmo, range rings, hover) and the
-- loops that look up each selected unit use this cached copy instead. It is rebuilt when a unit was stored or removed here (Rev), when the history moved (an edit made
-- elsewhere), when another document was opened, and at the latest after 1.5 s (a writer that bypasses all three). The entries are shared: read them, do not change them.
local cache = { doc = false, rev = -1, hist = -1, at = -100, list = false, index = false }

local function CacheFresh()
    local now = GetSystemTimeSeconds()
    local hist = History.Version
    if cache.list and cache.doc == Map.Doc and cache.rev == Rev and cache.hist == hist and now - cache.at < 1.5 then return end
    cache.list, cache.index = All(), false
    cache.doc, cache.rev, cache.hist, cache.at = Map.Doc, Rev, hist, now
end

--- All() from the cache (see above).
function CachedAll()
    CacheFresh()
    return cache.list
end

--- The unit { army, name } of a selection entry (the first in the order of All()), from the cache; nil when there is none.
function Lookup(army, name)
    CacheFresh()
    local index = cache.index
    if not index then
        index = {}
        for _, u in cache.list do
            local key = u.army .. '\1' .. u.name
            if index[key] == nil then index[key] = u end
        end
        cache.index = index
    end
    return index[army .. '\1' .. name]
end

--- A stamp that changes whenever the cached list would be rebuilt for another reason than its age: for callers that want to skip their own work (the overlay's key).
function Stamp()
    return Rev .. ':' .. History.Version
end

-- ---- the sim's entity ----------------------------------------------------------------------------------------------------------------------

local function SpawnEntity(u)
    SimCallback({ Func = 'EdSpawnUnit', Args = { bp = u.bp, army = u.army, x = u.x, y = u.y, z = u.z, heading = u.heading, group = u.group or 'INITIAL' } }, false)
end

local function RemoveEntity(u)
    SimCallback({ Func = 'EdRemoveUnitAt', Args = { bp = u.bp, army = u.army, x = u.x, z = u.z } }, false)
end

local function Store(u)
    local tbl = UnitTable(u.army, true, u.group)
    if not tbl then return false end
    Rev = Rev + 1
    tbl[u.name] = { type = u.bp, orders = '', platoon = '', Position = Vec3(u.x, u.y, u.z), Orientation = Vec3(0, u.heading, 0) }
    return true
end

local function Unstore(u)
    local tbl = UnitTable(u.army, false, u.group)
    Rev = Rev + 1
    if tbl then tbl[u.name] = nil end
end

local function Add(u)
    if not Store(u) then return false end
    SpawnEntity(u)
    return true
end

local function Remove(u)
    Unstore(u)
    RemoveEntity(u)
end

--- Bulk edits that keep their own undo entry (mirrorhalf.lua): store and spawn / unstore and remove a unit { army, group, name, bp, x, y, z, heading } without history.
function AddRaw(u) return Add(u) end
function RemoveRaw(u) Remove(u) end

--- A function that hands out unit names (UNIT_<n>) without scanning every unit each time.
function NameCounter()
    local max = 0
    for _, u in All() do
        local n = tonumber(string.sub(u.name, 6))
        if string.find(u.name, '^UNIT_%d+$') and n and n > max then max = n end
    end
    return function() max = max + 1 return 'UNIT_' .. max end
end

-- ---- placing --------------------------------------------------------------------------------------------------------------------------------

--- Puts the active unit down at (x, z) for the active army (and at the symmetry images); one undo step. Returns the number placed.
function Place(x, z)
    if not Map.Doc or not Active then
        Say(Active and 'no map' or 'pick a unit in the Units panel first')
        return 0
    end
    if not (Map.Doc.save.Armies and Map.Doc.save.Armies[ArmyName]) then
        Say('the army ' .. tostring(ArmyName) .. ' does not exist in this map')
        return 0
    end
    local placed = {}
    local names = NameCounter()
    for _, p in Symmetry.Points(x, z) do
        local u = { army = ArmyName, group = Group, name = names(), bp = Active, x = p.x, z = p.z, y = Ground(p.x, p.z), heading = Symmetry.Heading(0, p) }
        if Add(u) then table.insert(placed, u) end
    end
    if table.getn(placed) == 0 then return 0 end
    History.Push({
        label = 'place ' .. table.getn(placed) .. ' unit(s)',
        undo = function() for _, u in placed do Remove(u) end end,
        redo = function() for _, u in placed do Add(u) end end,
    })
    return table.getn(placed)
end

-- ---- selection and editing -----------------------------------------------------------------------------------------------------------------

local function Same(a, b)
    return a.army == b.army and a.name == b.name
end

-- the selection as a set (army, name), rebuilt when the list, its length or SelRevision changed: IsSelected is asked for many units in a row
local selSet, selSetOf, selSetN, selSetRev = {}, false, -1, -1

function IsSelected(u)
    local n = table.getn(Selection)
    if selSetOf ~= Selection or selSetN ~= n or selSetRev ~= SelRevision then
        selSet = {}
        for _, q in Selection do selSet[q.army .. '\1' .. q.name] = true end
        selSetOf, selSetN, selSetRev = Selection, n, SelRevision
    end
    return selSet[u.army .. '\1' .. u.name] == true
end

function ClearSelection()
    if table.getn(Selection) > 0 then
        Selection = {}
        SelRevision = SelRevision + 1
    end
end

--- The unit nearest to (wx, wz) within `radius` units.
function Pick(wx, wz, radius)
    radius = radius or 3
    local best, bestD
    for _, u in CachedAll() do
        local dx, dz = u.x - wx, u.z - wz
        local d = dx * dx + dz * dz
        if d <= radius * radius and (not bestD or d < bestD) then best, bestD = u, d end
    end
    return best
end

function Select(u, mode)
    if not u then
        ClearSelection()
        return
    end
    if mode == 'toggle' and IsSelected(u) then
        local rest = {}
        for _, q in Selection do
            if not Same(q, u) then table.insert(rest, q) end
        end
        Selection = rest
    else
        if mode ~= 'add' and mode ~= 'toggle' then Selection = {} end
        if not IsSelected(u) then table.insert(Selection, { army = u.army, name = u.name }) end
    end
    SelRevision = SelRevision + 1
end

local function Find(sel)
    return Lookup(sel.army, sel.name)
end

--- Data of the single selected unit, or nil.
function Info()
    if table.getn(Selection) ~= 1 then return nil end
    return Find(Selection[1])
end

local function Copy(o)
    local n = {}
    for k, v in o do n[k] = v end
    return n
end

local function Transform(label, change)
    local pairsList = {}
    -- every selected unit is looked up before the first one changes (a change makes the cache rebuild: once per unit would be one All() each)
    local olds = {}
    for i, sel in Selection do olds[i] = Find(sel) end
    for i, sel in Selection do
        local old = olds[i]
        if old then
            local new = change(Copy(old))
            if new then
                new.y = Ground(new.x, new.z)
                Remove(old)
                Add(new)
                table.insert(pairsList, { old = old, new = new })
            end
        end
    end
    if table.getn(pairsList) == 0 then return false end
    Selection = {}
    for _, e in pairsList do table.insert(Selection, { army = e.new.army, name = e.new.name }) end
    SelRevision = SelRevision + 1
    local function Apply(from, to)
        for _, e in pairsList do Remove(e[from]) end
        for _, e in pairsList do Add(e[to]) end
        Selection = {}
        for _, e in pairsList do table.insert(Selection, { army = e[to].army, name = e[to].name }) end
        SelRevision = SelRevision + 1
    end
    History.Push({ label = label, undo = function() Apply('new', 'old') end, redo = function() Apply('old', 'new') end })
    return true
end

--- Tool settings (toolopts.lua): whether units snap to the build grid (default on), and the step in degrees of a stepped rotation (0 = free).
function SnapToGrid() return import('/lua/editor/toolopts.lua').SnapToGrid('units') end
function RotationStep() return import('/lua/editor/toolopts.lua').RotationStep('units') end

--- A move of the selection by (dx, dz) put on the build grid: the first selected unit goes to the nearest grid spot of its footprint (unitfit.Snap: odd footprints on a cell centre, even
--- ones on a corner) and the others move by the same amount, so a group keeps its layout. Without a selection, or when the blueprint is unknown, the delta is kept.
function SnapDelta(dx, dz)
    if not SnapToGrid() then return dx, dz end          -- Tool settings > Units: snapping is off
    for _, sel in Selection do
        local u = Find(sel)
        if u then
            local ok, sx, sz = pcall(function()
                local Fit = import('/lua/editor/unitfit.lua')
                return Fit.Snap(Fit.Blueprint(u.bp), u.x + dx, u.z + dz, u.heading)
            end)
            if ok and sx then return sx - u.x, sz - u.z end
            return dx, dz
        end
    end
    return dx, dz
end

local function MoveSelectedOnly(dx, dz)
    dx, dz = SnapDelta(dx, dz)
    return Transform('move units', function(u) u.x, u.z = u.x + dx, u.z + dz return u end)
end

--- The counterparts of the selected units under the symmetry (units of the same blueprint at the mirror images): list of groups, see symmetry.lua Plan.
local function MirrorPlan()
    if Symmetry.Mode == 'off' or table.getn(Selection) == 0 then return nil end
    local items = {}
    for _, sel in Selection do
        local u = Find(sel)
        if u then table.insert(items, u) end
    end
    return Symmetry.Plan(items, function(u) return u.x, u.z end, All(), function(a, b) return a.bp == b.bp end, function(u) return IsSelected(u) end)
end

--- Runs `act(group)` with the selection set to the counterparts of each group and puts the selection back; merges the undo steps into one.
local function WithMirrors(plan, act, label)
    local main = Selection
    local pushed = 1
    for _, g in plan do
        Selection = {}
        for _, u in g.targets do table.insert(Selection, { army = u.army, name = u.name }) end
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
        local x0, z0 = plan[1].refX, plan[1].refZ
        WithMirrors(plan, function(g)
            local mdx, mdz = Symmetry.ImageDelta(g.key, g.refX, g.refZ, dx, dz)
            return MoveSelectedOnly(mdx, mdz)
        end, 'move units (with mirror)')
        Selection = main
    end
    return ok
end

function MoveTo(x, z)
    local i = Info()
    if not i then return false end
    return MoveSelected(x - i.x, z - i.z)
end

local function RotateSelectedOnly(deg)
    local rad = math.rad(deg)
    return Transform('rotate units', function(u) u.heading = u.heading + rad return u end)
end

function RotateSelected(deg)
    local plan = MirrorPlan()
    local ok = RotateSelectedOnly(deg)
    if ok and plan then
        local main = Selection
        WithMirrors(plan, function(g) return RotateSelectedOnly(Symmetry.ImageTurn(g.kind, deg)) end, 'turn units (with mirror)')
        Selection = main
    end
    return ok
end

function SetHeading(deg)
    local i = Info()
    if not i then return false end
    return RotateSelected(deg - math.deg(i.heading))
end

--- Moves the selected units into another group of their army (created when missing).
function SetGroup(group)
    return Transform('move units to group ' .. tostring(group), function(u) u.group = group return u end)
end

--- At map load: the units of the groups the script does not spawn by itself (everything but INITIAL and WRECKAGE) get their editor entities, so they can be seen and edited.
function SpawnGroupEntities()
    local n = 0
    -- a hundred units per callback (EdSpawnUnits in schook/lua/simcallbacks.lua): a mission map has ~2000 of them, and one callback each cost seconds at load
    local batch = {}
    local function Flush()
        if table.getn(batch) > 0 then
            SimCallback({ Func = 'EdSpawnUnits', Args = { list = batch } }, false)
            batch = {}
        end
    end
    for _, u in All() do
        if not GameSpawns(u.group) and u.group ~= 'WRECKAGE' and string.sub(u.group or '', 1, 9) ~= 'WRECKAGE/' then
            table.insert(batch, { bp = u.bp, army = u.army, x = u.x, y = u.y, z = u.z, heading = u.heading, group = u.group or 'INITIAL' })
            n = n + 1
            if table.getn(batch) >= 100 then Flush() end
        end
    end
    Flush()
    return n
end

--- Gives the selected units to another army.
function SetArmy(army)
    return Transform('change army of units', function(u) u.army = army return u end)
end

function DeleteSelected()
    local removed = {}
    for _, sel in Selection do
        local u = Find(sel)
        if u then table.insert(removed, u) end
    end
    if table.getn(removed) == 0 then return false end
    for _, u in removed do Remove(u) end
    ClearSelection()
    History.Push({
        label = 'delete ' .. table.getn(removed) .. ' unit(s)',
        undo = function() for _, u in removed do Add(u) end end,
        redo = function() for _, u in removed do Remove(u) end ClearSelection() end,
    })
    return true
end

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- Selects every unit inside the world box { x0, z0, x1, z1 } (replacing the selection, or adding to it); nil box = a click on empty ground.
function SelectBox(box, additive)
    if not box then
        if not additive then ClearSelection() end
        return
    end
    local minx, maxx = math.min(box[1], box[3]), math.max(box[1], box[3])
    local minz, maxz = math.min(box[2], box[4]), math.max(box[2], box[4])
    if not additive then Selection = {} end
    local have = {}          -- (the selection grows in the loop: IsSelected would rebuild its set for every unit)
    for _, q in Selection do have[q.army .. '\1' .. q.name] = true end
    for _, u in CachedAll() do
        local key = u.army .. '\1' .. u.name
        if u.x >= minx and u.x <= maxx and u.z >= minz and u.z <= maxz and not have[key] then
            have[key] = true
            table.insert(Selection, { army = u.army, name = u.name })
        end
    end
    SelRevision = SelRevision + 1
end

--- Click of the Unit select tool: picks (Shift toggles), drag moves the selection, empty ground clears, a drag from empty ground selects the units in the box.
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
        if off and (math.abs(off[1]) + math.abs(off[2])) > 0.2 then MoveSelected(off[1], off[2]) end
        self:Destroy()
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end


--- Data of every selected unit (for the clipboard).
function SelectedData()
    local list = {}
    for _, sel in Selection do
        local u = Find(sel)
        if u then table.insert(list, Copy(u)) end
    end
    return list
end

--- Adds copies of `list` moved by (dx, dz) (same army, new names) as one undo entry and selects them. Returns the number added.
function Paste(list, dx, dz)
    local added = {}
    local names = NameCounter()          -- (NewName per unit would look at every unit of the map again each time)
    for _, d in list do
        local u = Copy(d)
        u.x, u.z = d.x + dx, d.z + dz
        u.y = Ground(u.x, u.z)
        u.name = names()
        if Add(u) then table.insert(added, u) end
    end
    if table.getn(added) == 0 then return 0 end
    Selection = {}
    for _, u in added do table.insert(Selection, { army = u.army, name = u.name }) end
    SelRevision = SelRevision + 1
    History.Push({
        label = 'paste ' .. table.getn(added) .. ' unit(s)',
        undo = function() for _, u in added do Remove(u) end ClearSelection() end,
        redo = function() for _, u in added do Add(u) end end,
    })
    return table.getn(added)
end

--- Find / replace: every unit of blueprint `from` becomes a unit of blueprint `to` (same army, group, name, place, heading), one undo step. Returns how many.
function ReplaceBlueprint(from, to)
    Selection = {}
    for _, u in All() do
        if u.bp == from then table.insert(Selection, { army = u.army, name = u.name }) end
    end
    local n = table.getn(Selection)
    if n == 0 then return 0 end
    SelRevision = SelRevision + 1
    local ok = Transform('replace units ' .. from .. ' with ' .. to, function(u)
        u.bp = to
        return u
    end)
    return ok and n or 0
end

--- Adds copies of `list` at their own places (positions, headings, armies and groups final; new names) as one undo entry and selects them: Paste without the move. Returns the number added.
function PasteExact(list, label)
    local added = {}
    local names = NameCounter()
    for _, d in list do
        local u = Copy(d)
        u.y = Ground(u.x, u.z)
        u.name = names()
        if Add(u) then table.insert(added, u) end
    end
    if table.getn(added) == 0 then return 0 end
    Selection = {}
    for _, u in added do table.insert(Selection, { army = u.army, name = u.name }) end
    SelRevision = SelRevision + 1
    History.Push({
        label = label or ('paste ' .. table.getn(added) .. ' unit(s)'),
        undo = function() for _, u in added do Remove(u) end ClearSelection() end,
        redo = function() for _, u in added do Add(u) end end,
    })
    return table.getn(added)
end
