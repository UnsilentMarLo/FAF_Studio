-- Editor UI shell: tool bar, brush panel, status line, mouse tools, in-world markers / areas.
--
-- Built from the game's own Maui controls (plain coloured bitmaps and text), so it needs no skin files. All
-- editing goes through the editor modules (terrain.lua, map.lua); this file only turns mouse and button input
-- into calls on them. The tool entry points (SelectTool, StrokeAt, PlaceMarkerAt, MakeArea ...) take world
-- coordinates, so the same code is driven by the mouse handler and by tests.
--
--   import('/lua/editor/ui.lua').Create()    build the UI (called from control.lua when /editor runs)

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local UIUtil = import('/lua/ui/uiutil.lua')

local Terrain = import('/lua/editor/terrain.lua')
local Map = import('/lua/editor/map.lua')
local Mods = import('/lua/editor/mods.lua')
local History = import('/lua/editor/history.lua')
local MeshView = import('/lua/editor/meshview.lua')
local Strata = import('/lua/editor/strata.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local TerrainType = import('/lua/editor/terraintype.lua')
local Props = import('/lua/editor/props.lua')
local Decals = import('/lua/editor/decals.lua')
local ObjectTools = import('/lua/editor/tools.lua')
local Overlay = import('/lua/editor/overlay.lua')
local Perf = import('/lua/editor/perf.lua')
local Safe = import('/lua/editor/safe.lua')

local COLOR_PANEL = 'e0101820'
local COLOR_BTN = 'ff2a3a4a'
local COLOR_HOVER = 'ff3d566c'
local COLOR_SELECTED = 'ff1f7a4d'
local COLOR_TEXT = 'ffe8f0f8'
local COLOR_MARKER = 'ffffc830'
local COLOR_AREA = 'ff30c8ff'

--- Tools. kind 'brush' = terrain brush mode of terrain.lua; 'marker' / 'area' / 'none' are document tools; kind 'select' with `pick = 'marker' | 'area'` selects only that kind of object;
--- 'custom' calls tool.OnPress(wx, wz, event) (return false to let the click through; a raising OnPress is caught, logged and lets the click through). Editor mods add tools by
--- appending to this table from a hook on /lua/editor/ui.lua (api.lua Mod(name).Tool(Tools, def) also names the mod and turns the tool off after its first failure).
Tools = {
    { id = 'select',  label = 'Select marker',  kind = 'select', pick = 'marker' },
    { id = 'raise',   label = 'Raise',   kind = 'brush' },
    { id = 'lower',   label = 'Lower',   kind = 'brush' },
    { id = 'flatten', label = 'Flatten', kind = 'brush' },
    { id = 'smooth',  label = 'Smooth',  kind = 'brush' },
    { id = 'plateau', label = 'Plateau', kind = 'brush' },
    { id = 'erode',   label = 'Erode',   kind = 'brush' },
    { id = 'rain',    label = 'Rain',    kind = 'brush' },
    { id = 'deposit', label = 'Deposit', kind = 'brush' },
    { id = 'noise',   label = 'Noise',   kind = 'brush' },
    { id = 'stamp',   label = 'Stamp',   kind = 'brush', workspaces = { Terrain = true } },
    { id = 'stamp_paint', label = 'Stamp texture', kind = 'brush', workspaces = { Terrain = true } },
    { id = 'paint',   label = 'Paint layer', kind = 'brush' },
    { id = 'erase',   label = 'Erase layer', kind = 'brush' },
    { id = 'ttype',   label = 'Terrain type', kind = 'brush' },
    { id = 'ramp',    label = 'Ramp', kind = 'custom', workspaces = { Terrain = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/ramp.lua').Press(wx, wz, event) end },
    { id = 'paths',   label = 'Paths', kind = 'custom', workspaces = { Terrain = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/pathtool.lua').Press(wx, wz, event) end },
    { id = 'prop',    label = 'Prop brush', kind = 'brush', workspaces = { Objects = true } },
    { id = 'prop_erase', label = 'Erase props', kind = 'brush', workspaces = { Objects = true } },
    { id = 'decal',   label = 'Decal brush', kind = 'brush', workspaces = { Objects = true } },
    { id = 'decal_erase', label = 'Erase decals', kind = 'brush', workspaces = { Objects = true } },
    { id = 'unit',    label = 'Place unit', kind = 'custom', workspaces = { Objects = true, Mission = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/placer.lua').Press('unit', wx, wz, event) end },
    { id = 'prop_place', label = 'Place prop', kind = 'custom', workspaces = { Objects = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/placer.lua').Press('prop_place', wx, wz, event) end },
    { id = 'decal_place', label = 'Place decal', kind = 'custom', workspaces = { Objects = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/placer.lua').Press('decal_place', wx, wz, event) end },
    { id = 'unit_select', label = 'Select units', kind = 'custom', workspaces = { Objects = true, Mission = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/units.lua').Press(wx, wz, event) end },
    { id = 'decal_select', label = 'Select decals', kind = 'custom', workspaces = { Objects = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/decals.lua').Press(wx, wz, event) end },
    { id = 'prop_select', label = 'Select props', kind = 'custom', workspaces = { Objects = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/props.lua').Press(wx, wz, event) end },
    { id = 'marker',  label = 'Place marker',  kind = 'marker' },
    { id = 'army',    label = 'Start position', kind = 'custom', workspaces = { Objects = true, Mission = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/armies.lua').Place(wx, wz) ~= nil end },
    { id = 'area',    label = 'Place area',    kind = 'area' },
    { id = 'ruler',   label = 'Ruler',   kind = 'custom', workspaces = { Terrain = true, Objects = true, Environment = true, Mission = true, Review = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/ruler.lua').Press(wx, wz, event) end },
    { id = 'camera',  label = 'Camera',  kind = 'none' },
    -- (added after the older tools so the digit slots of the workspaces keep their tools)
    { id = 'area_select', label = 'Select area', kind = 'select', pick = 'area' },
    { id = 'chain',   label = 'Draw chain', kind = 'custom', workspaces = { Objects = true, Mission = true },
      OnPress = function(wx, wz, event) return import('/lua/editor/chains.lua').DrawPress(wx, wz, event) end },
}

--- Workspaces own their tools (the shell tells ui.lua which workspace is showing, SetWorkspace): a tool belongs to a workspace by its kind
--- (or by `tool.workspaces = { Terrain = true }` for tools that need something else), the tool panel lists only those, a tool of another
--- workspace cannot be selected, and switching to a workspace whose tools exclude the current one selects its default tool. `readOnly`
--- workspaces inspect only: nothing in the document can be changed there.
Workspaces = {
    Terrain = { default = 'raise',  kinds = { brush = true, none = true } },
    Objects = { default = 'select', kinds = { select = true, marker = true, area = true, custom = true, none = true } },
    Environment = { default = 'camera', kinds = { none = true } },
    Mod = { default = 'camera', kinds = { none = true } },
    Generate = { default = 'camera', kinds = { none = true } },
    Mission = { default = 'select', kinds = { select = true, marker = true, area = true, none = true } },
    Review  = { default = 'select', kinds = { select = true, none = true }, readOnly = true },
}

--- GUI shell hook: set by gui/shell.lua; called with 'edit' or 'play' after the mode changed (false = none).
OnModeChange = false

State = {
    mode = 'edit',          -- 'edit' (game HUD hidden, tools active) or 'play' (game HUD shown, test run)
    backup = nil,           -- scenario path of the autosave taken when Play was pressed
    tool = 'select',
    workspace = false,      -- set by the shell (SetWorkspace); false = no workspace rules (the old fixed panel)
    markerCount = 0,
    areaCount = 0,
    lastDab = nil,
    areaStart = nil,
    areaEnd = nil,
    message = '',
    savedAs = nil,
    modsOpen = false,       -- mod browser dialog shown
    modsPending = nil,      -- uid set being edited in the browser (applied by Apply & reload)
    modsPage = 1,
}

local ui = {}          -- controls, filled by Create()
local panels = {}      -- panel bitmaps (clicks inside them are never tool clicks)

-- ---- small widgets ------------------------------------------------------------------------------------------

local function Label(parent, text, size)
    local t = UIUtil.CreateText(parent, text, size or 13, UIUtil.bodyFont)
    t:SetColor(COLOR_TEXT)
    t:DisableHitTest()
    return t
end

local function MakeButton(parent, label, width, height, onClick)
    local b = Bitmap(parent)
    b:SetSolidColor(COLOR_BTN)
    LayoutHelpers.SetDimensions(b, width, height)
    b.label = Label(b, label, 13)
    LayoutHelpers.AtCenterIn(b.label, b)
    b.selected = false
    b.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            self:SetSolidColor(COLOR_HOVER)
            return true
        elseif event.Type == 'MouseExit' then
            self:SetSolidColor(self.selected and COLOR_SELECTED or COLOR_BTN)
            return true
        elseif event.Type == 'ButtonPress' then
            onClick(self)
            return true
        end
        return false
    end
    b.SetSelected = function(self, selected)
        self.selected = selected
        self:SetSolidColor(selected and COLOR_SELECTED or COLOR_BTN)
    end
    return b
end

-- ---- state / tool operations (world coordinates in, no mouse) ------------------------------------------------------

--- The message of the status line. A module function (not a local): 40 callers in other modules use ui.lua's Say (maps, units, clipboard, panels ...), and every one of them
--- was silently dropped under its pcall (and raised where it had none) while this was local.
function Say(text)
    State.message = text
    -- the Console panel lists the status line messages too (consolelog.lua; a repeat of the newest line only raises its count)
    if text ~= nil and text ~= '' then Safe.Try('ui:fn170', function() import('/lua/editor/consolelog.lua').Add('status', text, 'status') end) end
end

local function FindTool(id)
    for _, t in Tools do
        if t.id == id then
            return t
        end
    end
    return nil
end

local function RefreshToolButtons()
    if not ui.toolButtons then
        return
    end
    for id, b in ui.toolButtons do
        b:SetSelected(id == State.tool)
    end
end

function ToolAllowed(tool, workspace)
    workspace = workspace or State.workspace
    local ws = workspace and Workspaces[workspace]
    if not ws then
        return true
    end
    if tool.workspaces then
        return tool.workspaces[workspace] == true
    end
    return ws.kinds[tool.kind] == true
end

--- The tools of the showing workspace, in table order.
function AllowedTools()
    local list = {}
    for _, t in Tools do
        if ToolAllowed(t) then
            table.insert(list, t)
        end
    end
    return list
end

-- ---- brush settings per kind of brush -------------------------------------------------------------------------------------------------------------
-- Terrain.Brush is the live brush every tool reads. Each kind of brush keeps its own radius, strength, sign and falloff: changing tools swaps them in and out, so a big prop brush
-- does not make the height brush big.

BRUSH_KIND = {
    raise = 'terrain', lower = 'terrain', flatten = 'terrain', smooth = 'terrain', plateau = 'terrain', noise = 'terrain', ramp = 'terrain',
    erode = 'erosion', rain = 'erosion', deposit = 'erosion',
    stamp = 'stamp', stamp_paint = 'texture', paint = 'texture', erase = 'texture', ttype = 'texture',
    prop = 'props', prop_erase = 'props', decal = 'decals', decal_erase = 'decals',
}
BrushProfiles = {}      -- kind -> { radius, strength, sign, falloff }
local BRUSH_DEFAULT = {
    terrain = { radius = 12, strength = 2.0, sign = 1, falloff = 1.0 }, erosion = { radius = 16, strength = 2.0, sign = 1, falloff = 1.0 },
    stamp = { radius = 16, strength = 2.0, sign = 1, falloff = 1.0 }, texture = { radius = 8, strength = 5.0, sign = 1, falloff = 0.6 },
    props = { radius = 10, strength = 2.0, sign = 1, falloff = 1.0 }, decals = { radius = 10, strength = 2.0, sign = 1, falloff = 1.0 },
}

--- Stores the live brush under the kind of the tool that was active and loads the settings of the kind of the tool that becomes active.
function SwitchBrushKind(oldId, newId)
    local oldKind, newKind = BRUSH_KIND[oldId], BRUSH_KIND[newId]
    if oldKind == newKind then return end
    local B = Terrain.Brush
    if oldKind then BrushProfiles[oldKind] = { radius = B.radius, strength = B.strength, sign = B.sign or 1, falloff = B.falloff } end
    if newKind then
        local p = BrushProfiles[newKind] or BRUSH_DEFAULT[newKind]
        B.radius, B.strength, B.sign, B.falloff = p.radius, p.strength, p.sign, p.falloff
    end
end

--- The profiles as they are now (the live brush included), for saving.
function BrushSnapshot()
    local snap = {}
    for kind, p in BrushProfiles do snap[kind] = { radius = p.radius, strength = p.strength, sign = p.sign, falloff = p.falloff } end
    local kind = BRUSH_KIND[State.tool]
    if kind then
        local B = Terrain.Brush
        snap[kind] = { radius = B.radius, strength = B.strength, sign = B.sign or 1, falloff = B.falloff }
    end
    return snap
end

function SelectTool(id)
    local tool = FindTool(id)
    if not tool then
        return false
    end
    if not ToolAllowed(tool) then
        Say(tool.label .. ' is not available in the ' .. tostring(State.workspace) .. ' workspace')
        return false
    end
    SwitchBrushKind(State.tool, id)
    State.tool = id
    if tool.kind == 'brush' then
        Terrain.Brush.mode = id
    end
    RefreshToolButtons()
    Say('tool: ' .. tool.label)
    return true
end

local function EnsureDoc()
    if not Map.Doc then
        Map.Load()
    end
    return Map.Doc
end

--- Loads the map document if it is not loaded yet (the shell does this at start, so markers show from the first frame).
function EnsureDocument()
    return EnsureDoc()
end

--- The tool that may act now: the selected one, but only when the showing workspace offers it (nil otherwise).
function ActiveTool()
    local tool = FindTool(State.tool)
    if tool and ToolAllowed(tool) then return tool end
    return nil
end

--- Makes sure the selected tool belongs to the showing workspace: when it does not, the workspace's default tool is selected (the tool panel follows).
--- Returns true when it had to change the tool.
function EnforceTool()
    local ws = State.workspace and Workspaces[State.workspace]
    if not ws or ActiveTool() then return false end
    local old = State.tool
    SwitchBrushKind(old, ws.default)
    State.tool = ws.default
    local tool = FindTool(ws.default)
    if tool and tool.kind == 'brush' then Terrain.Brush.mode = ws.default end
    State.areaStart, State.areaEnd, State.dragPointer, State.holdPointer = nil, nil, nil, nil
    RefreshToolButtons()
    Say('tool: ' .. (tool and tool.label or ws.default))
    return old ~= State.tool
end

--- The shell switched workspace: apply its tool rules.
function SetWorkspace(name)
    State.workspace = name
    local ws = Workspaces[name]
    ObjectTools.ReadOnly = (ws and ws.readOnly) and true or false
    EnforceTool()
end

local function GroundHeight(x, z)
    local h = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
    return MeshView.GroundAt(x, z, h)          -- the visible ground of a mesh map
end

--- One brush dab at a world position (inside a stroke the caller opened).
function StrokeAt(x, z)
    return Terrain.Dab(x, z)
end

function BeginStroke()
    -- the native command stack counts a stroke at its first write, not when it ends: remember the depth from before it
    State.strokeDepth = Terrain.UndoDepth()
    Terrain.BeginStroke()
    State.lastDab = nil
    State.strokeTarget = nil
    State.dabTime = 0
end

--- Records an edit made outside the tools (the layers panel): { label, undo, redo }.
function PushEdit(entry)
    if entry then
        History.Push(entry)
    end
end

function EndStroke()
    PumpStroke(true)          -- the distance the frame budget left over: the stroke ends where the mouse was released
    State.strokeTarget = nil
    Terrain.EndStroke()
    local notice = Strata.TakeNotice()
    if notice then
        Say(notice)
    end
    local paint = Strata.TakeEntry()      -- a texture layer stroke has its own undo entry (the native stack only knows heights)
    if paint then
        History.Push(paint)
    end
    local ttype = TerrainType.TakeEntry()    -- so has a terrain type stroke
    if ttype then
        History.Push(ttype)
    end
    local props = Props.TakeEntry()          -- and a prop stroke
    if props then
        History.Push(props)
    end
    local decals = Decals.TakeEntry()        -- and a decal stroke
    if decals then
        History.Push(decals)
    end
    if State.strokeDepth ~= nil and Terrain.UndoDepth() ~= State.strokeDepth then
        History.PushTerrain()
    end
    State.strokeDepth = nil
    State.lastDab = nil
end

local STROKE_BUDGET = 0.006       -- seconds of dabs per frame: a fast mouse never stalls a frame, the rest of the distance is dabbed in the next frames
local STROKE_MAX_DABS = 60        -- and at most this many in one go (the clock of a long session has a coarse resolution)

local function Clock()
    local now = rawget(_G, 'GetSystemTimeSeconds')
    return now and now() or 0
end

--- Lays the dabs between the last dab and the stroke's target (the latest mouse position) at an even spacing, for as long as this frame's time budget lasts.
--- What is left over stays between `State.lastDab` and `State.strokeTarget`; the per-frame tick (FinishCreate) calls this again. `unlimited` (the end of a stroke)
--- dabs everything that is left (up to 200 dabs). Returns the samples changed.
function PumpStroke(unlimited)
    local target, last = State.strokeTarget, State.lastDab
    if not target or not last then
        return 0
    end
    local used = State.dabTime or 0
    if not unlimited and used >= STROKE_BUDGET then
        return 0
    end
    -- Dabs are laid along the path of the mouse at an even spacing, however fast it moved (one dab per mouse event left gaps and a staircase edge);
    -- the texture brush dabs closer (it is soft, and its mask has coarse cells).
    local r = Terrain.Brush.radius
    local mode = Terrain.Brush.mode
    -- the texture brush takes the strongest weight of the stroke per cell (strata.lua), so its dab density does not change the result: r / 4
    local isStamp = (mode == 'stamp' or mode == 'stamp_paint')
    local spacing = math.max(1, ((mode == 'paint' or mode == 'erase') and r / 4) or r / 3)
    if isStamp then spacing = import('/lua/editor/stamp.lua').Spacing() end         -- the stamp's own spacing (percent of its width)
    local dx = target[1] - last[1]
    local dz = target[2] - last[2]
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < spacing then
        return 0
    end
    local count = math.min(200, math.floor(dist / spacing))
    local ux, uz = dx / dist * spacing, dz / dist * spacing
    local ax, az = last[1], last[2]
    local total = 0
    local done = 0
    local t0 = Clock()
    while done < count do
        done = done + 1
        total = total + Terrain.Dab(ax + ux * done, az + uz * done)
        if not unlimited and done < count and (done >= STROKE_MAX_DABS or used + (Clock() - t0) >= STROKE_BUDGET) then
            break
        end
    end
    State.dabTime = used + (Clock() - t0)
    State.lastDab = { ax + ux * done, az + uz * done }
    if mode == 'paint' or mode == 'erase' or mode == 'stamp_paint' then Strata.Flush() end
    return total
end

--- Continues a stroke: the first call dabs at once, later ones only note where the mouse is and dab along the way within the frame's time budget (PumpStroke).
function StrokeMove(x, z)
    local mode = Terrain.Brush.mode
    if not State.lastDab then
        State.lastDab = { x, z }
        State.strokeTarget = { x, z }
        local first = Terrain.Dab(x, z)
        if mode == 'paint' or mode == 'erase' or mode == 'stamp_paint' then Strata.Flush() end
        return first
    end
    State.strokeTarget = { x, z }
    return PumpStroke(false)
end

function PlaceMarkerAt(x, z)
    if not EnsureDoc() then
        Say('no map document')
        return nil
    end
    -- with symmetry on, the marker is placed at every image of the point; the copies are one undo step
    local points = Symmetry.Points(x, z)
    local name
    local count = 0
    for i, p in points do
        local placed = ObjectTools.PlaceMarker(p.x, p.z)
        if i == 1 then name = placed end
        if placed then count = count + 1 end
    end
    if count > 1 then History.Merge(count, 'place ' .. tostring(name) .. ' and copies') end
    Say('added ' .. tostring(name) .. (count > 1 and (' and ' .. (count - 1) .. ' copies') or ''))
    return name
end

function MakeArea(x0, z0, x1, z1)
    if not EnsureDoc() then
        Say('no map document')
        return nil
    end
    local rects = Symmetry.Rect(x0, z0, x1, z1)
    local name
    local count = 0
    for i, r in rects do
        local placed = ObjectTools.NewArea(r[1], r[2], r[3], r[4])
        if i == 1 then name = placed end
        if placed then count = count + 1 end
    end
    if count > 1 then History.Merge(count, 'add ' .. tostring(name) .. ' and copies') end
    Say('added ' .. tostring(name))
    return name
end

function SetRadius(r)
    Terrain.Brush.radius = math.max(1, math.min(64, r))
    Say('radius ' .. Terrain.Brush.radius)
end

function SetStrength(s)
    Terrain.Brush.strength = math.max(0.1, math.min(10, s))
    Say('strength ' .. string.format('%d%%', (Terrain.Brush.sign or 1) * Terrain.Brush.strength * 10))
end

--- The brush strength as the panels show it: percent, -100..100 (negative = inverted).
function GetStrengthPercent()
    return (Terrain.Brush.sign or 1) * Terrain.Brush.strength * 10
end

function SetStrengthPercent(pct)
    pct = math.max(-100, math.min(100, pct))
    Terrain.Brush.sign = (pct < 0) and -1 or 1
    Terrain.Brush.strength = math.max(0.1, math.abs(pct) / 10)
end

function DoUndo()
    local label = History.Undo()
    if label then
        Say('undo: ' .. label)
    else
        Say('nothing to undo')
    end
end

function DoRedo()
    local label = History.Redo()
    if label then
        Say('redo: ' .. label)
    else
        Say('nothing to redo')
    end
end

--- Saves into <folder>/<stem> (a disk folder). Default target: <bin>/../mapout/<stem>.v0001 next to the exe.
function DoSave(diskDir, stem)
    if not diskDir then
        -- no target given: back to where the map was saved before, or ask (maps.lua)
        return import('/lua/editor/maps.lua').Save()
    end
    stem = stem or 'editor_map'
    local scenario, why = Map.SaveAs(diskDir, stem)
    if scenario then
        State.savedAs = scenario
        Say('saved ' .. scenario)
    else
        Say('save failed: ' .. tostring(why))
    end
    return scenario, why
end

-- ---- mouse ---------------------------------------------------------------------------------------------------

local function InPanel(x, y)
    if State.modsOpen and ui.modDialog then
        local d = ui.modDialog
        if x >= d.Left() and x <= d.Right() and y >= d.Top() and y <= d.Bottom() then
            return true
        end
    end
    for _, p in panels do
        if x >= p.Left() and x <= p.Right() and y >= p.Top() and y <= p.Bottom() then
            return true
        end
    end
    return false
end

local function MouseWorld()
    local pos = GetMouseScreenPos()
    local x, y, z = MeshView.ScreenRay((pos and (pos[1] or pos.x)) or 0, (pos and (pos[2] or pos.y)) or 0)
    if x then
        return x, z
    end
    local p = GetMouseWorldPos()
    if p then
        return p[1], p[3]
    end
    return nil
end

-- World position under a window position. While a drag is captured the view no longer tracks the hover
-- position, so drags unproject the window coordinates the dragger reports.
-- Calibrated in the engine: UnProject takes window coordinates, but view:Project returns coordinates local to the view
-- (they differ once the docking shell puts the view into the viewport hole), so overlays add the view's Left / Top.
local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then
        return nil
    end
    local hx, _, hz = MeshView.ScreenRay(x, y)       -- on a mesh map the point on the visible ground
    if hx then
        return hx, hz
    end
    local p = UnProject(view, Vector2(x, y))
    if p then
        return p[1], p[3]
    end
    return nil
end

function OnWorldPress(event)
    -- a tool the showing workspace does not offer never acts: the default tool is selected instead and this click is dropped
    if not ActiveTool() then
        EnforceTool()
        return false
    end
    local tool = FindTool(State.tool)
    if not tool or tool.kind == 'none' then
        return false
    end
    local wx, wz = ScreenToWorld(event.MouseX, event.MouseY)
    if not wx then
        return false
    end

    -- the transform gizmo of the select tools takes its handles before the tool sees the click
    if import('/lua/editor/gizmo.lua').Press(wx, wz, event) then
        return true
    end

    if tool.kind == 'select' then
        return ObjectTools.OnSelectPress(wx, wz, event, tool.pick)
    elseif tool.kind == 'brush' then
        BeginStroke()
        StrokeMove(wx, wz)
        State.dragPointer = { wx, wz }        -- the overlay's brush preview follows this while the button is down
        local dragger = Dragger()
        dragger.OnMove = function(self, x, y)
            local mx, mz = ScreenToWorld(x, y)
            if mx then
                State.dragPointer = { mx, mz }
                StrokeMove(mx, mz)
            end
        end
        -- After the button is released the engine's hover position is still the one from before the drag (it is not tracked while the dragger
        -- holds the mouse): the brush would jump back to where the stroke began. The last dab position is held until the real mouse moves.
        local function Finish()
            local last = State.dragPointer
            State.dragPointer = nil
            local pos = GetMouseScreenPos()
            if last and pos then
                State.holdPointer = { last[1], last[2], pos[1] or pos.x or 0, pos[2] or pos.y or 0 }
            end
            EndStroke()
        end
        dragger.OnRelease = function(self, x, y)
            Finish()
            self:Destroy()
        end
        dragger.OnCancel = function(self)
            Finish()
            self:Destroy()
        end
        PostDragger(GetFrame(0), event.KeyCode, dragger)
        return true
    elseif tool.kind == 'custom' and tool.OnPress then
        return import('/lua/editor/api.lua').RunTool(tool, wx, wz, event)          -- protected: a tool that raises lets the click through (api.lua)
    elseif tool.kind == 'marker' then
        PlaceMarkerAt(wx, wz)
        return true
    elseif tool.kind == 'area' then
        State.areaStart = { ObjectTools.ClampAreaPoint(wx, wz) }       -- (kept on the map while 'Limit to map bounds' is on)
        State.areaEnd = { ObjectTools.ClampAreaPoint(wx, wz) }
        local dragger = Dragger()
        dragger.OnMove = function(self, x, y)
            local mx, mz = ScreenToWorld(x, y)
            if mx then
                State.areaEnd = { ObjectTools.ClampAreaPoint(mx, mz) }
            end
        end
        dragger.OnRelease = function(self, x, y)
            local s, e = State.areaStart, State.areaEnd
            State.areaStart, State.areaEnd = nil, nil
            if s and e and (math.abs(e[1] - s[1]) > 1 or math.abs(e[2] - s[2]) > 1) then
                MakeArea(s[1], s[2], e[1], e[2])
            end
            self:Destroy()
        end
        dragger.OnCancel = function(self)
            State.areaStart, State.areaEnd = nil, nil
            self:Destroy()
        end
        PostDragger(GetFrame(0), event.KeyCode, dragger)
        return true
    end
    return false
end

--- Called by the world view hook (schook/lua/ui/controls/worldview.lua) for every button press on a world view.
--- Returns true when the active tool used the click.
function HandleWorldPress(view, event)
    if not ui.root or State.mode ~= 'edit' then
        return false
    end
    if view._cameraName ~= 'WorldCamera' then
        return false
    end
    if InPanel(event.MouseX, event.MouseY) then
        return false
    end
    -- camera gestures (rotate, pan, zoom drags; rebindable) come before the tools
    local Camera = import('/lua/editor/camera.lua')
    if Camera.OnPress(view, event) then
        return true
    end
    if not (event.Modifiers and event.Modifiers.Left) then
        return false
    end
    -- In edit mode the left button never reaches the game: no selection box, no orders. A tool that cannot use
    -- the click (camera tool, no ground under the cursor) still swallows it.
    OnWorldPress(event)
    return true
end

-- ---- edit / play ----------------------------------------------------------------------------------------------

local function GameUIHidden(hidden)
    -- (called every frame while editing: the module is kept in `ui`, no import per call)
    local gm = ui.gameMainMod
    if not gm then
        gm = import('/lua/ui/game/gamemain.lua')
        ui.gameMainMod = gm
    end
    if gm.gameUIHidden ~= hidden then
        gm.HideGameUI()
    end
end

--- The unit life / fuel bars and the selection box are game HUD (gamemain.lua switches them on at the start of a game): off while editing (placed units, the unit viewer's unit), on in a test run.
local function UnitBars(on)
    Safe.Try('ui:ConExecute', ConExecute, 'UI_RenderUnitBars ' .. (on and 'true' or 'false'))
    Safe.Try('ui:ConExecute', ConExecute, 'ren_SelectBoxes ' .. (on and 'true' or 'false'))       -- the game's selection / hover box of a unit (the editor draws its own selection)
    Safe.Try('ui:ConExecute', ConExecute, 'ren_Ranges ' .. (on and 'true' or 'false'))            -- the game's range rings of a unit (the editor draws its own: unitrings.lua)
end

local dots = {}      -- pool of { dot = Bitmap, text = Text }
local edges = {}     -- pool of Bitmaps for area rectangles (4 per area)

local function ShowEditorUI(show)
    for _, p in panels do
        if show then p:Show() else p:Hide() end
    end
    if ui.overlay then
        if show then ui.overlay:Show() else ui.overlay:Hide() end
    end
    if ui.modDialog then
        if show and State.modsOpen then ui.modDialog:Show() else ui.modDialog:Hide() end
    end
    if not show then
        Overlay.Clear()
        -- the pooled marker dots / area edges are shown one by one by the overlay update: hide them here
        for _, d in dots do
            d.dot:Hide()
            d.text:Hide()
        end
        for _, e in edges do
            e:Hide()
        end
    end
    if ui.playBar then
        if show then ui.playBar:Hide() else ui.playBar:Show() end
    end
end

--- Switches between the editing view and an in-game test run.
function SetMode(mode)
    if mode == State.mode then
        return
    end
    State.mode = mode
    -- (a test run also gets the rock and splat of every resource marker: the editing sim leaves them out, markervis.lua)
    Safe.Try('ui:fn755', function() SimCallback({ Func = 'EdSetPlay', Args = { on = (mode == 'play'), deposits = (mode == 'play') and import('/lua/editor/markervis.lua').DepositList() or nil } }, false) end)       -- mission scripts start their first stage on Play
    if mode == 'play' then
        GameUIHidden(false)
        UnitBars(true)
        ShowEditorUI(false)
        Say('playing')
        -- like a game: the camera goes to the commander the run spawned (EdSetPlay in schook/lua/simcallbacks.lua) and selects it
        ForkThread(function()
            for i = 1, 25 do
                WaitSeconds(0.2)
                if State.mode ~= 'play' then return end
                Safe.Try('ui:UISelectionByCategory', UISelectionByCategory, 'COMMAND', false, false, false, false)
                local sel = GetSelectedUnits()
                if sel and table.getn(sel) > 0 then
                    Safe.Try('ui:UIZoomTo', UIZoomTo, sel, 0.4)
                    return
                end
            end
        end)
    else
        if SessionIsPaused and SessionIsPaused() then
            SessionRequestPause()
        end
        GameUIHidden(true)
        UnitBars(false)
        ShowEditorUI(true)
        Say('editing')
    end
    if OnModeChange then
        Safe.Try('ui:OnModeChange', OnModeChange, mode)
    end
end

--- Play: autosave the document (so Stop can restore exactly this state), then run the world with the game UI.
--- Has the mission (stages, bases, strings) changed since this session loaded its map? The running sim has the script of the load, so a play test would run an old mission (or none).
function MissionChanged()
    local ok, changed = pcall(function()
        local M = import('/lua/editor/mission.lua')
        return M.NeedsReload()       -- edited since the load, or loaded from a saved map (whose script has no test hooks)
    end)
    return ok and changed
end

function Play(stage)
    if State.mode == 'play' then
        return
    end
    Safe.Try('ui:fn802', function() import('/lua/editor/unitview.lua').Close() end)        -- nothing the unit viewer made belongs in a test run
    local Mission = import('/lua/editor/mission.lua')
    Mission.TestRun = true       -- (the mission script of this copy gets the test hooks: skip / speed / state / trace; a saved or released map never does)
    local saved, scenario, why = pcall(Map.SaveAs, '../mapout/_playtest.v0001', '_playtest')
    Mission.TestRun = false
    if not saved then scenario, why = nil, scenario end
    if not scenario then
        Say('play: autosave failed: ' .. tostring(why))
        return
    end
    State.backup = scenario
    if MissionChanged() then
        -- a new session with the saved copy, which then starts in play mode (gui/shell.lua Start reads these keys)
        local Control = import('/lua/editor/control.lua')
        Control.SessionExtra = { autoplay = 1, backup = scenario, stage = stage or 1 }
        Say('the mission changed: reloading the map for the test run ...')
        Control.LoadMap(scenario)
        return
    end
    if stage and stage > 1 then
        Safe.Try('ui:fn818', function() SimCallback({ Func = 'EdMissionStartAt', Args = { stage = stage } }, false) end)
    end
    SetMode('play')
end

--- Play test that starts the mission at stage `stage` (the stages before it do not run): to try one stage, one cutscene or one trigger without playing the mission up to it.
function PlayFromStage(stage)
    Play(stage)
end

function PauseToggle()
    if State.mode == 'play' then
        SessionRequestPause()
    end
end

--- Stop: leave the test run and open the autosave again, so everything the run changed is gone.
function Stop()
    if State.mode ~= 'play' or not State.backup then
        return
    end
    import('/lua/editor/control.lua').LoadMap(State.backup)
end

-- ---- world click hook ------------------------------------------------------------------------------------------

local wrappedWorldView = nil

--- Puts the editor in front of the world view's own mouse handling: the active tool gets the left press, and in edit
--- mode nothing else does (no selection box, no orders). Installed on the final WorldView class after every hook,
--- so a mod that wraps WorldView.HandleEvent (and maybe drops its return value) cannot get in front of it.
local function InstallWorldHook()
    local W = import('/lua/ui/controls/worldview.lua').WorldView
    if wrappedWorldView == W then
        return
    end
    wrappedWorldView = W
    local baseHandleEvent = W.HandleEvent
    W.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' and HandleWorldPress(self, event) then
            return true
        end
        return baseHandleEvent(self, event)
    end
end

-- ---- mod browser ------------------------------------------------------------------------------------------------

local MODS_PER_PAGE = 10

local function ModPages(list)
    return math.max(1, math.ceil(table.getn(list) / MODS_PER_PAGE))
end

local function RefreshModDialog()
    if not ui.modDialog then
        return
    end
    local list = Mods.Browsable()
    local pages = ModPages(list)
    State.modsPage = math.max(1, math.min(State.modsPage, pages))
    local pending = State.modsPending or {}
    local extra = Mods.DependencyOnly(pending)
    for row = 1, MODS_PER_PAGE do
        local mod = list[(State.modsPage - 1) * MODS_PER_PAGE + row]
        local b = ui.modRows[row]
        if mod then
            local text = tostring(mod.name)
            if string.len(text) > 48 then
                text = string.sub(text, 1, 47) .. '~'
            end
            if extra[mod.uid] then
                text = text .. '  [required]'
            end
            b.uid = mod.uid
            b.label:SetText(text)
            b:SetSelected(pending[mod.uid] == true or extra[mod.uid] == true)
            b:Show()
        else
            b.uid = nil
            b:Hide()
        end
    end
    ui.modPage:SetText(string.format('page %d / %d   (%d mods)', State.modsPage, pages, table.getn(list)))
    local always = {}
    for _, mod in Mods.EditorMods() do
        table.insert(always, tostring(mod.name))
    end
    ui.modEditorMods:SetText('editor mods (always loaded): ' .. (table.getn(always) > 0 and table.concat(always, ', ') or 'none'))
end

function ToggleModDialog()
    -- with the docking GUI the mod list is a panel of the dock, not a dialog
    local ok, shell = pcall(import, '/lua/editor/gui/shell.lua')
    if ok and shell.IsEditor and shell.IsEditor() and shell.FocusPanel and shell.FocusPanel('mods') then
        return
    end
    State.modsOpen = not State.modsOpen
    if State.modsOpen then
        State.modsPending = Mods.GetSelection()
        RefreshModDialog()
        ui.modDialog:Show()
    else
        ui.modDialog:Hide()
    end
end

--- Saves the selection, autosaves the map and reopens it: mods are applied when a session starts.
function ApplyMods()
    local pending = State.modsPending
    if not pending then
        return
    end
    local before = Mods.GetSelection()
    Mods.SetSelection(pending)
    local scenario, why = Map.SaveAs('../mapout/_modreload.v0001', '_modreload')
    if not scenario then
        Mods.SetSelection(before)
        Say('mods: autosave failed: ' .. tostring(why))
        return
    end
    State.modsOpen = false
    Mods.BeginTrial(before)
    Say('reloading with the new mod list ...')
    import('/lua/editor/control.lua').LoadMap(scenario)
end

local function BuildModDialog(frame)
    local d = Bitmap(ui.root)
    d:SetSolidColor(COLOR_PANEL)
    LayoutHelpers.SetDimensions(d, 450, 20 + 24 + 24 + MODS_PER_PAGE * 26 + 44)
    -- in the middle of the window and above the GUI shell's panels (they sit at depth 5000); it used to hide behind the tool panel
    d.Left:Set(function() return math.floor((frame.Width() - d.Width()) / 2) end)
    d.Top:Set(function() return math.floor((frame.Height() - d.Height()) / 3) end)
    d.Depth:Set(frame.Depth() + 5600)
    ui.modDialog = d

    local title = Label(d, 'Mods for this map', 15)
    LayoutHelpers.AtLeftTopIn(title, d, 10, 6)
    ui.modEditorMods = Label(d, '', 11)
    LayoutHelpers.AtLeftTopIn(ui.modEditorMods, d, 10, 28)

    ui.modRows = {}
    for row = 1, MODS_PER_PAGE do
        local b = MakeButton(d, '', 430, 22, function(self)
            if self.uid then
                local pending = State.modsPending or {}
                pending[self.uid] = not pending[self.uid] or nil
                State.modsPending = pending
                RefreshModDialog()
            end
        end)
        LayoutHelpers.AtLeftTopIn(b, d, 10, 50 + (row - 1) * 26)
        ui.modRows[row] = b
    end

    local y = 50 + MODS_PER_PAGE * 26 + 6
    local prev = MakeButton(d, '<', 30, 24, function()
        State.modsPage = State.modsPage - 1
        RefreshModDialog()
    end)
    LayoutHelpers.AtLeftTopIn(prev, d, 10, y)
    local nextPage = MakeButton(d, '>', 30, 24, function()
        State.modsPage = State.modsPage + 1
        RefreshModDialog()
    end)
    LayoutHelpers.AtLeftTopIn(nextPage, d, 46, y)
    ui.modPage = Label(d, '', 12)
    LayoutHelpers.AtLeftTopIn(ui.modPage, d, 86, y + 5)
    local apply = MakeButton(d, 'Apply & reload', 110, 24, function() ApplyMods() end)
    LayoutHelpers.AtLeftTopIn(apply, d, 220, y)
    local close = MakeButton(d, 'Close', 80, 24, function() ToggleModDialog() end)
    LayoutHelpers.AtLeftTopIn(close, d, 360, y)
    d:Hide()
end

-- ---- overlays: markers and areas drawn over the world ---------------------------------------------------------


local function Dot(i)
    if not dots[i] then
        local d = Bitmap(ui.overlay)
        d:SetSolidColor(COLOR_MARKER)
        LayoutHelpers.SetDimensions(d, 8, 8)
        d:DisableHitTest()
        local t = Label(ui.overlay, '', 11)
        t:SetColor(COLOR_MARKER)
        dots[i] = { dot = d, text = t }
    end
    return dots[i]
end

local function Edge(i)
    if not edges[i] then
        local e = Bitmap(ui.overlay)
        e:SetSolidColor(COLOR_AREA)
        LayoutHelpers.SetDimensions(e, 3, 3)
        e:DisableHitTest()
        edges[i] = e
    end
    return edges[i]
end

-- An area edge is drawn as a row of small squares: a rotated line cannot be made from axis-aligned bitmaps.
local EDGE_SAMPLES = 14

local function Line(first, view, ax, az, bx, bz)
    for s = 0, EDGE_SAMPLES - 1 do
        local f = s / (EDGE_SAMPLES - 1)
        local x = ax + (bx - ax) * f
        local z = az + (bz - az) * f
        local p = view:Project(Vector(x, GroundHeight(x, z), z))
        local e = Edge(first + s)
        e.Left:Set(view.Left() + p.x - 1)
        e.Top:Set(view.Top() + p.y - 1)
        e:Show()
    end
    return first + EDGE_SAMPLES
end

-- One failing frame no longer ends the engine overlay for the whole session: it is skipped for 3 seconds (the dots below stand in) and tried again; the same error text is logged once.
local overlayBrokenUntil = 0
local overlayLastError = false

local function UpdateOverlay()
    -- (every frame: the two modules are kept in `ui`, no import call per frame)
    local wvMod = ui.worldViewMod
    if not wvMod then
        wvMod = import('/lua/ui/game/worldview.lua')
        ui.worldViewMod = wvMod
    end
    local worldView = wvMod.viewLeft
    if not worldView then
        return
    end

    -- the engine's line overlay (overlay.lua) draws markers' highlights, areas and the pointer; the pooled dots below are the
    -- fallback for an engine without it
    if GetSystemTimeSeconds() >= overlayBrokenUntil then
        local self = ui.selfMod
        if not self then
            self = import('/lua/editor/ui.lua')
            ui.selfMod = self
        end
        local ok, handled = pcall(Overlay.Update, self)
        if not ok then
            overlayBrokenUntil = GetSystemTimeSeconds() + 3
            if tostring(handled) ~= overlayLastError then
                overlayLastError = tostring(handled)
                LOG('EDITOR overlay failed (tried again in 3 s): ' .. overlayLastError)
            end
        elseif handled then
            for _, d in dots do
                d.dot:Hide()
                d.text:Hide()
            end
            for _, e in edges do
                e:Hide()
            end
            return
        end
    end

    if not Map.Doc then
        return
    end
    local used = 0
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        used = used + 1
        if used > 300 then
            break
        end
        local p = worldView:Project(Vector(m.position[1], m.position[2], m.position[3]))
        local d = Dot(used)
        local ox, oy = worldView.Left(), worldView.Top()   -- view-local projection to window coordinates
        d.dot.Left:Set(ox + p.x - 4)
        d.dot.Top:Set(oy + p.y - 4)
        d.dot:Show()
        d.text:SetText(name)
        d.text.Left:Set(ox + p.x + 6)
        d.text.Top:Set(oy + p.y - 8)
        d.text:Show()
    end
    for i = used + 1, table.getn(dots) do
        dots[i].dot:Hide()
        dots[i].text:Hide()
    end

    local edgeCount = 0
    local function Rectangle(x0, z0, x1, z1)
        local n = edgeCount + 1
        n = Line(n, worldView, x0, z0, x1, z0)
        n = Line(n, worldView, x1, z0, x1, z1)
        n = Line(n, worldView, x0, z1, x1, z1)
        n = Line(n, worldView, x0, z0, x0, z1)
        edgeCount = n - 1
    end
    for name, a in Map.Doc.save.Areas do
        if edgeCount < 600 and a.rectangle then
            Rectangle(a.rectangle[1], a.rectangle[2], a.rectangle[3], a.rectangle[4])
        end
    end
    if State.areaStart and State.areaEnd then
        Rectangle(State.areaStart[1], State.areaStart[2], State.areaEnd[1], State.areaEnd[2])
    end
    for i = edgeCount + 1, table.getn(edges) do
        edges[i]:Hide()
    end
end

-- ---- construction ------------------------------------------------------------------------------------------

--- The status line text (also shown by the GUI shell's status bar).
function StatusText()
    local wx, wz = MouseWorld()
    local pos = wx and string.format('x %.0f  z %.0f  h %.1f', wx, wz, GroundHeight(wx, wz)) or 'x -  z -'
    local undo, redo = History.Depth()
    local brush = ''
    local tool = ActiveTool()
    if tool and tool.kind == 'brush' then
        brush = string.format('   radius %d  strength %d%%', Terrain.Brush.radius, (Terrain.Brush.sign or 1) * Terrain.Brush.strength * 10)
    end
    local slope = import('/lua/editor/slope.lua').Readout()
    if slope ~= '' then
        brush = brush .. '   |   ' .. slope
    end
    local sel = ObjectTools.SelectionText()
    if sel ~= '' then
        brush = brush .. '   |   ' .. sel
    end
    -- why the preview of a unit being placed or moved is red (placer.lua)
    local why = import('/lua/editor/placer.lua').Hint()
    if why ~= '' then
        brush = brush .. '   |   ' .. why
    end
    return string.format('%s   |   %s%s   |   undo %d redo %d   |   %s', pos, tool and tool.label or '?',
        brush, undo, redo, State.message)
end

local function UpdateStatus()
    if ui.status then
        ui.status:SetText(StatusText())
    end
end

--- Per-frame tick (status, overlays), the world click hook and the initial tool: shared by both UI flavours.
local function FinishCreate(frame)
    -- per-frame: status text and overlays
    ui.tick = Bitmap(ui.root)
    ui.tick:SetSolidColor('00000000')
    ui.tick.Left:Set(0)
    ui.tick.Top:Set(0)
    LayoutHelpers.SetDimensions(ui.tick, 1, 1)   -- all four edges set: an unset pair is a circular LazyVar the engine evaluates every frame
    ui.tick:DisableHitTest()
    ui.tick:SetNeedsFrameUpdate(true)
    ui.tick.OnFrame = function(self, delta)
        local tAll = Perf.Begin()
        -- a brush stroke in progress: dab what the last frames' time budget left over between the last dab and the mouse (PumpStroke)
        State.dabTime = 0
        if State.strokeTarget then
            local tStroke = Perf.Begin()
            PumpStroke(false)
            Perf.End('ui: brush stroke pump', tStroke)
        end
        -- the game's own start-up (layout, expand animations) can re-show the HUD after Create(): keep it hidden
        if State.mode == 'edit' then
            GameUIHidden(true)
            UpdateStatus()
            UpdateOverlay()
        end
        Perf.End('ui: frame tick (all)', tAll)
    end

    InstallWorldHook()
    SelectTool(State.tool)
    Say('ready')

    -- The editor has no game HUD (resources, orders, minimap, score ...): only an in-game test run shows it.
    GameUIHidden(true)
    UnitBars(false)
end

--- Builds the editor UI. `opts.shell = true`: only the machinery (overlays, world click hook, mode switching, mod dialog); the
--- panels come from the GUI shell (gui/shell.lua, gui/panels_editor.lua), and the overlay sits below the shell's panels.
function Create(opts)
    if ui.root then
        return
    end
    local frame = GetFrame(0)

    -- The root is a 1x1 group in the corner: every child is placed in absolute frame coordinates, and a
    -- full-screen root would swallow the clicks meant for the world and the camera.
    ui.root = Group(frame)
    LayoutHelpers.AtLeftTopIn(ui.root, frame, 0, 0)
    LayoutHelpers.SetDimensions(ui.root, 1, 1)
    ui.root.Depth:Set(frame.Depth() + 8000)

    ui.overlay = Group(ui.root)
    LayoutHelpers.AtLeftTopIn(ui.overlay, ui.root, 0, 0)
    LayoutHelpers.SetDimensions(ui.overlay, 1, 1)

    if opts and opts.shell then
        ui.root.Depth:Set(frame.Depth() + 4000)   -- below the shell (depth 5000): markers and areas never draw over its panels
        ui.toolButtons = {}
        BuildModDialog(frame)
        FinishCreate(frame)
        return
    end

    -- tool panel (left)
    local panel = Bitmap(ui.root)
    panel:SetSolidColor(COLOR_PANEL)
    panel.Left:Set(10)
    panel.Top:Set(200)
    panel.Width:Set(150)
    panel.Height:Set(460)
    panel.Depth:Set(ui.root.Depth() + 1)
    table.insert(panels, panel)
    ui.panel = panel

    local title = Label(panel, 'Editor', 15)
    LayoutHelpers.AtLeftTopIn(title, panel, 10, 6)

    ui.toolButtons = {}
    local y = 30
    for _, tool in Tools do
        local id = tool.id
        local b = MakeButton(panel, tool.label, 130, 24, function() SelectTool(id) end)
        LayoutHelpers.AtLeftTopIn(b, panel, 10, y)
        ui.toolButtons[id] = b
        y = y + 28
    end

    y = y + 6
    local brushTitle = Label(panel, 'Brush', 13)
    LayoutHelpers.AtLeftTopIn(brushTitle, panel, 10, y)
    y = y + 20

    local function Stepper(name, onMinus, onPlus)
        local l = Label(panel, name, 12)
        LayoutHelpers.AtLeftTopIn(l, panel, 10, y + 4)
        local minus = MakeButton(panel, '-', 26, 22, onMinus)
        LayoutHelpers.AtLeftTopIn(minus, panel, 82, y)
        local plus = MakeButton(panel, '+', 26, 22, onPlus)
        LayoutHelpers.AtLeftTopIn(plus, panel, 114, y)
        y = y + 26
    end
    Stepper('Radius', function() SetRadius(Terrain.Brush.radius - 2) end, function() SetRadius(Terrain.Brush.radius + 2) end)
    Stepper('Strength', function() SetStrength(Terrain.Brush.strength - 0.5) end,
        function() SetStrength(Terrain.Brush.strength + 0.5) end)

    y = y + 8
    local undo = MakeButton(panel, 'Undo', 62, 24, DoUndo)
    LayoutHelpers.AtLeftTopIn(undo, panel, 10, y)
    local redo = MakeButton(panel, 'Redo', 62, 24, DoRedo)
    LayoutHelpers.AtLeftTopIn(redo, panel, 78, y)
    y = y + 32
    local save = MakeButton(panel, 'Save map', 130, 24, function() DoSave() end)
    LayoutHelpers.AtLeftTopIn(save, panel, 10, y)
    y = y + 28
    local play = MakeButton(panel, 'Play test', 130, 24, function() Play() end)
    LayoutHelpers.AtLeftTopIn(play, panel, 10, y)
    y = y + 28
    local modsButton = MakeButton(panel, 'Mods', 130, 24, function() ToggleModDialog() end)
    LayoutHelpers.AtLeftTopIn(modsButton, panel, 10, y)
    y = y + 28
    panel.Height:Set(y + 8)

    BuildModDialog(frame)

    -- play bar (shown instead of the editor panels while a test run is on)
    ui.playBar = Bitmap(ui.root)
    ui.playBar:SetSolidColor(COLOR_PANEL)
    LayoutHelpers.SetDimensions(ui.playBar, 170, 34)
    ui.playBar.Left:Set(function() return math.floor((frame.Width() - ui.playBar.Width()) / 2) end)
    ui.playBar.Top:Set(100)
    ui.playBar.Depth:Set(ui.root.Depth() + 1)
    local pauseButton = MakeButton(ui.playBar, 'Pause', 76, 24, function() PauseToggle() end)
    LayoutHelpers.AtLeftTopIn(pauseButton, ui.playBar, 6, 5)
    local stopButton = MakeButton(ui.playBar, 'Stop', 76, 24, function() Stop() end)
    LayoutHelpers.AtLeftTopIn(stopButton, ui.playBar, 88, 5)
    ui.playBar:Hide()

    -- status line (top centre)
    local bar = Bitmap(ui.root)
    bar:SetSolidColor(COLOR_PANEL)
    LayoutHelpers.SetDimensions(bar, 760, 22)
    bar.Left:Set(function() return math.floor((frame.Width() - bar.Width()) / 2) end)
    bar.Top:Set(100)
    bar.Depth:Set(ui.root.Depth() + 1)
    table.insert(panels, bar)
    ui.status = Label(bar, '', 13)
    LayoutHelpers.AtLeftCenterIn(ui.status, bar, 8)

    FinishCreate(frame)
end

function Destroy()
    if ui.root then
        ui.root:Destroy()
    end
    ui = {}
    panels = {}
    dots = {}
    edges = {}
end
