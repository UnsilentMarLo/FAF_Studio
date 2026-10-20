-- The editor's own menus: the menu bar (File, Edit, View, Workspace, Window, Help) and the right-click menus of the viewport and of lists.
-- Everything is a provider registered with Menu.Extend (menu.lua), so editor mods add entries the same way; entries run commands
-- (commands.lua), so a menu item, a key, the command palette and a button are the same action.
--
-- Right click in the viewport: a short right click (no drag; a right drag rotates the camera) calls Camera.OnClick, set at the bottom of
-- this file, which opens 'context.world' with { wx, wz, height, hit } where `hit` is the marker / area under the pointer.

local Menu = import('/lua/editor/gui/menu.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Camera = import('/lua/editor/camera.lua')
local UI = import('/lua/editor/ui.lua')
local Tools = import('/lua/editor/tools.lua')
local Map = import('/lua/editor/map.lua')
local Grid = import('/lua/editor/grid.lua')
local Slope = import('/lua/editor/slope.lua')

local function Shell()
    return import('/lua/editor/gui/shell.lua')
end

local function Editable()
    return not Tools.ReadOnly
end

-- ---- menu bar ---------------------------------------------------------------------------------------------------------------------------
-- Structure and reasons: docs/projects/editor/UX_MENUS.md. File = the document on disk, Edit = changing it, View = what is shown, Map = map-wide data and checks,
-- Terrain = height field operations, Workspace = layouts, Window = panels. A disabled item says why (`why`).

local function Objs()
    return import('/lua/editor/gui/panels_objects.lua')
end

local function Selected()
    return Objs().AnySelection()
end

local function ReadOnlyWhy()
    return 'read-only workspace'
end

--- A command that needs the document to be editable and something selected.
local function NeedsSelection(item)
    item.enabled = function() return Editable() and Selected() end
    item.why = function() if not Editable() then return ReadOnlyWhy() end return 'nothing selected' end
    return item
end

local function Editing(item)
    item.enabled = Editable
    item.why = ReadOnlyWhy
    return item
end

Menu.Extend('menubar.File', function()
    return {
        { command = 'file.new' },
        { command = 'file.open' },
    }
end, 5)
-- 'Open recent' is added by feature_release.lua (order 6)
Menu.Extend('menubar.File', function()
    return {
        { command = 'file.recover', enabled = function() return import('/lua/editor/maps.lua').AutosavePath() ~= false end, why = 'there is no autosaved map yet' },
    }
end, 7)
Menu.Extend('menubar.File', function()
    return {
        { command = 'file.save' },
        { command = 'file.saveas' },
    }
end, 10)
Menu.Extend('menubar.File', function()
    return {
        { title = 'Import', submenu = function() return Menu.Build('menu.import') end },
        { title = 'Export', submenu = function() return Menu.Build('menu.export') end },
    }
end, 15)
-- 'Release map...' is added by feature_release.lua (order 20)

Menu.Extend('menu.import', function()
    return { Editing({ title = 'Heightmap file...', command = 'file.import_height' }) }
end, 10)
Menu.Extend('menu.export', function()
    return { { title = 'Heightmap file...', command = 'file.export_height' } }
end, 10)

Menu.Extend('menubar.Edit', function()
    local History = import('/lua/editor/history.lua')
    return {
        { command = 'edit.undo', title = function()
            local top = History.Top()
            return top and ('Undo: ' .. tostring(top.label or 'edit')) or 'Undo'
        end, enabled = function() local u = History.Depth() return Editable() and u > 0 end,
          why = function() if not Editable() then return ReadOnlyWhy() end return 'nothing to undo' end },
        { command = 'edit.redo', title = function()
            local nxt = History.RedoTop()
            return nxt and ('Redo: ' .. tostring(nxt.label or 'edit')) or 'Redo'
        end, enabled = function() local _, r = History.Depth() return Editable() and r > 0 end,
          why = function() if not Editable() then return ReadOnlyWhy() end return 'nothing to redo' end },
    }
end, 10)
Menu.Extend('menubar.Edit', function()
    return {
        NeedsSelection({ command = 'edit.cut' }),
        NeedsSelection({ command = 'edit.copy' }),
        { command = 'edit.paste', enabled = function() return Editable() and import('/lua/editor/clipboard.lua').Count() > 0 end,
          why = function() if not Editable() then return ReadOnlyWhy() end return 'nothing copied' end },
        NeedsSelection({ command = 'edit.duplicate' }),
        NeedsSelection({ command = 'edit.delete' }),
    }
end, 20)
Menu.Extend('menubar.Edit', function()
    return {
        { command = 'edit.selectall', enabled = function() return UI.State.tool == 'select' or UI.State.tool == 'unit_select' end, why = 'use a select tool' },
        { command = 'edit.deselect', enabled = Selected, why = 'nothing selected' },
    }
end, 30)

Menu.Extend('menubar.View', function()
    return {
        { command = 'view.grid', checked = function() return Grid.Visible end },
        { command = 'view.slope', checked = function() return Slope.Visible end },
    }
end, 10)
Menu.Extend('menubar.View', function()
    return {
        { title = 'Camera', submenu = {
            { command = 'camera.reset' },
            { command = 'camera.north' },
            { command = 'camera.topdown' },
            { command = 'camera.focus', enabled = function() return Selected() end, why = 'nothing selected' },
            { title = 'Go to bookmark', submenu = {
                { command = 'camera.go1' }, { command = 'camera.go2' }, { command = 'camera.go3' }, { command = 'camera.go4' }, { command = 'camera.go5' },
                { command = 'camera.go6' }, { command = 'camera.go7' }, { command = 'camera.go8' }, { command = 'camera.go9' },
            } },
            { title = 'Save bookmark', submenu = {
                { command = 'camera.mark1' }, { command = 'camera.mark2' }, { command = 'camera.mark3' }, { command = 'camera.mark4' }, { command = 'camera.mark5' },
                { command = 'camera.mark6' }, { command = 'camera.mark7' }, { command = 'camera.mark8' }, { command = 'camera.mark9' },
            } },
        } },
        { command = 'tool.ruler.clear', enabled = function() return table.getn(import('/lua/editor/ruler.lua').Points) > 0 end, why = 'no measurement' },
    }
end, 20)
Menu.Extend('menubar.View', function()
    return {
        { command = 'ui.scale.up' },
        { command = 'ui.scale.down' },
    }
end, 30)

Menu.Extend('menubar.Map', function()
    return {
        { command = 'file.info' },
        { command = 'file.lobbyslots', tip = 'Choose which factions each start position offers in the game lobby (UEF, Aeon, Cybran, Seraphim).' },
        Editing({ command = 'terrain.playable', title = 'Playable area...' }),
    }
end, 10)
Menu.Extend('menubar.Map', function()
    return {
        { command = 'validate.run' },
        Editing({ command = 'validate.snap' }),
    }
end, 20)
Menu.Extend('menubar.Map', function()
    return {
        { command = 'file.mods' },
        { command = 'file.play' },
    }
end, 30)

Menu.Extend('menubar.Terrain', function()
    return {
        Editing({ command = 'terrain.generate' }),
        Editing({ command = 'terrain.flatten' }),
    }
end, 10)
-- the external tools' entries (feature_interop.lua) follow at order 40

Menu.Extend('menubar.Workspace', function()
    local items = {}
    local W = import('/lua/editor/gui/workspace.lua')
    for _, name in W.Presets() do
        local n = name
        table.insert(items, { title = n, command = 'workspace.' .. n, checked = function() return Shell().S.current == n end })
    end
    return items
end, 10)
Menu.Extend('menubar.Workspace', function()
    return {
        { command = 'view.resetlayout' },
        { command = 'workspace.save' },
        { command = 'workspace.load' },
    }
end, 20)

-- Window: one submenu per area; the panel's own area decides where it is listed.
local PANEL_AREA = {
    General = { 'tools', 'outliner', 'properties', 'console', 'validation', 'history', 'stats', 'mods', 'hotkeys', 'view', 'symmetry' },
    Terrain = { 'brush', 'brushes', 'texbrush', 'shapes', 'layers', 'ttype', 'ttlayers', 'paths', 'erosion', 'fields', 'sctools', 'terrainchecks', 'recipes', 'interop' },
    Objects = { 'markers', 'chains', 'props', 'decals', 'units', 'scatter' },
    World = { 'lighting', 'ambient', 'water', 'waterlook', 'meshmap', 'meshimport' },
    Mission = { 'stages', 'bases', 'run', 'strings', 'armies' },
    Mod = { 'unitlab', 'unitview', 'effects', 'icons' },
    Generate = { 'graphcanvas', 'graphgallery', 'graphinspector', 'graphpalette', 'maskgen' },
}
local AREA_ORDER = { 'General', 'Terrain', 'Objects', 'World', 'Mission', 'Mod', 'Generate' }

local function PanelItem(def)
    local id = def.id
    return { title = def.title, command = 'panel.open.' .. id, nokeys = true, checked = function()
        local main = Shell().S.main
        return main and main.instances[id] ~= nil or false
    end }
end

Menu.Extend('menubar.Window', function()
    local listed = {}
    local items = {}
    for _, area in AREA_ORDER do
        local sub = {}
        for _, id in PANEL_AREA[area] do
            local def = Panels.Get(id)
            if def then
                listed[id] = true
                table.insert(sub, PanelItem(def))
            end
        end
        if table.getn(sub) > 0 then table.insert(items, { title = area, submenu = sub }) end
    end
    -- panels that editor mods added, or that no area claims
    local more = {}
    for _, def in Panels.All() do
        if def.id ~= 'viewport' and not listed[def.id] then table.insert(more, PanelItem(def)) end
    end
    if table.getn(more) > 0 then table.insert(items, { title = 'More', submenu = more }) end
    return items
end, 10)

Menu.Extend('menubar.Help', function()
    return {
        { command = 'help.hotkeys' },
        { command = 'shell.palette' },
    }
end, 10)

-- ---- right-click menus ------------------------------------------------------------------------------------------------------------------
-- 'context.world'  the viewport: ctx = { wx, wz, height, hit, unit, prop, decal } (hit: marker / area, unit / prop / decal: what the pointer is over, when the
--                  showing workspace has the matching select tool); the object menus below are included for whatever is under the pointer
-- 'context.object' a marker or an area (ctx = { kind, name }; also the outliner)       'context.unit' / 'context.prop' / 'context.decal'  (ctx = { unit | prop | decal })
-- Every item runs a command or a function that works on the object the menu was opened on: the object becomes the only selection first, so Copy / Duplicate / Delete
-- never touch something else that was selected before.

local function ObjectText(ctx)
    return tostring(ctx.name)
end

local function Units() return import('/lua/editor/units.lua') end
local function Props() return import('/lua/editor/props.lua') end
local function Decals() return import('/lua/editor/decals.lua') end
local function Clipboard() return import('/lua/editor/clipboard.lua') end

--- Is the tool `id` offered by the showing workspace?
local function HasTool(id)
    for _, t in UI.Tools do
        if t.id == id then return UI.ToolAllowed(t) end
    end
    return false
end

local function ClearAllSelections()
    Tools.Select(false)
    Units().ClearSelection()
    Props().ClearSelection()
    Decals().ClearSelection()
end

--- Makes `what` the only selection; the matching select tool is chosen when the workspace has it (so the Properties panel shows the object).
local function SelectOnly(kind, what)
    ClearAllSelections()
    if kind == 'marker' or kind == 'area' then
        Tools.Select(kind, what)
    elseif kind == 'unit' then
        Units().Select(what, 'set')
        if HasTool('unit_select') then UI.SelectTool('unit_select') end
    elseif kind == 'prop' then
        Props().Select(what, 'set')
        if HasTool('prop_select') then UI.SelectTool('prop_select') end
    elseif kind == 'decal' then
        Decals().Select(what, 'set')
        if HasTool('decal_select') then UI.SelectTool('decal_select') end
    end
end

local function EditItem(title, fn)
    return { title = title, enabled = Editable, why = 'read-only workspace', run = fn }
end

--- The items every object kind shares, after the object became the only selection.
local function CommonItems(kind, what, label)
    local function Do(fn) return function() SelectOnly(kind, what) fn() end end
    return {
        { title = 'Focus camera on ' .. label, run = Do(function() Camera.FocusSelection() end) },
        EditItem('Copy', Do(function() Clipboard().Copy() end)),
        EditItem('Duplicate', Do(function() Clipboard().Duplicate() end)),
        EditItem('Delete ' .. label, Do(function()
            if kind == 'unit' then Units().DeleteSelected()
            elseif kind == 'prop' then Props().DeleteSelected()
            elseif kind == 'decal' then Decals().DeleteSelected()
            else Tools.DeleteSelection() end
        end)),
    }
end

local function ShowProperties(kind, what)
    return { title = 'Properties', run = function()
        SelectOnly(kind, what)
        Shell().FocusPanel('properties')
    end }
end

--- What can be done to a marker or area (the viewport menu, the outliner and anything else showing objects).
Menu.Extend('context.object', function(ctx)
    local label = ObjectText(ctx)
    local selected = Tools.IsSelected(ctx.kind, ctx.name)
    local multi = selected and Tools.SelectionCount() > 1
    local items = {
        { title = 'Select ' .. label, enabled = not selected or Tools.SelectionCount() > 1, why = 'already selected', run = function() SelectOnly(ctx.kind, ctx.name) end },
        { title = multi and ('Focus camera on the selection (' .. Tools.SelectionCount() .. ')') or ('Focus camera on ' .. label), run = function()
            if not Tools.IsSelected(ctx.kind, ctx.name) then SelectOnly(ctx.kind, ctx.name) end
            Camera.FocusSelection()
        end },
        EditItem('Copy', function() if not Tools.IsSelected(ctx.kind, ctx.name) then SelectOnly(ctx.kind, ctx.name) end Clipboard().Copy() end),
        EditItem('Duplicate', function() if not Tools.IsSelected(ctx.kind, ctx.name) then SelectOnly(ctx.kind, ctx.name) end Clipboard().Duplicate() end),
        EditItem(multi and ('Delete ' .. Tools.SelectionCount() .. ' objects') or ('Delete ' .. label), function()
            if not Tools.IsSelected(ctx.kind, ctx.name) then SelectOnly(ctx.kind, ctx.name) end
            Tools.DeleteSelection()
        end),
    }
    local m = ctx.kind == 'marker' and Map.Doc and Map.Doc.save.MasterChain._MASTERCHAIN_.Markers[ctx.name]
    if m and m.resource then
        table.insert(items, EditItem('Snap to build grid', function() Tools.SnapMarkersToGrid({ ctx.name }) end))
    end
    table.insert(items, { title = 'Properties', run = function()
        if not Tools.IsSelected(ctx.kind, ctx.name) then SelectOnly(ctx.kind, ctx.name) end
        Shell().FocusPanel('properties')
    end })
    return items
end, 10)

Menu.Extend('context.unit', function(ctx)
    local u = ctx.unit
    local label = tostring(u.bp) .. ' ' .. tostring(u.name)
    local items = CommonItems('unit', u, label)
    local armies = {}
    for _, a in Units().Armies() do
        local army = a
        table.insert(armies, { title = army, checked = army == u.army, enabled = Editable, run = function()
            SelectOnly('unit', u)
            Units().SetArmy(army)
        end })
    end
    local groups = {}
    for _, g in Units().Groups(u.army) do
        local group = g
        table.insert(groups, { title = group, checked = group == u.group, enabled = Editable, run = function()
            SelectOnly('unit', u)
            Units().SetGroup(group)
        end })
    end
    table.insert(items, { title = 'Set army', submenu = armies, enabled = Editable, why = 'read-only workspace' })
    table.insert(items, { title = 'Move to group', submenu = groups, enabled = Editable, why = 'read-only workspace' })
    table.insert(items, ShowProperties('unit', u))
    return items
end, 10)

Menu.Extend('context.prop', function(ctx)
    local p = ctx.prop
    local items = CommonItems('prop', p, tostring(string.gsub(string.gsub(tostring(p.bp), '^.*/', ''), '_prop%.bp$', '')))
    table.insert(items, ShowProperties('prop', p))
    return items
end, 10)

Menu.Extend('context.decal', function(ctx)
    local d = ctx.decal
    local items = CommonItems('decal', d, tostring(string.gsub(tostring(d.tex), '^.*/', '')))
    table.insert(items, ShowProperties('decal', d))
    return items
end, 10)

Menu.Extend('context.world', function(ctx)
    return { { header = true, title = string.format('x %.1f   z %.1f   height %.1f', ctx.wx, ctx.wz, ctx.height) } }
end, 5)

Menu.Extend('context.world', function(ctx)
    if ctx.hit then
        return Menu.Build('context.object', { kind = ctx.hit.kind, name = ctx.hit.name })
    elseif ctx.unit then
        return Menu.Build('context.unit', ctx)
    elseif ctx.prop then
        return Menu.Build('context.prop', ctx)
    elseif ctx.decal then
        return Menu.Build('context.decal', ctx)
    end
    return nil
end, 10)

--- Placing things at the pointer, for the tools the showing workspace offers.
Menu.Extend('context.world', function(ctx)
    local items = {}
    if HasTool('marker') then
        local markerType = Tools.MarkerType
        table.insert(items, EditItem('Place ' .. tostring(markerType) .. ' here', function() UI.PlaceMarkerAt(ctx.wx, ctx.wz) end))
        local sub = {}
        for _, t in Tools.MarkerTypes() do
            local n = t.name
            table.insert(sub, { title = n, tip = 'Place a ' .. n .. ' marker at the pointer.', enabled = Editable, checked = n == markerType, run = function()
                Tools.SetMarkerType(n)
                UI.PlaceMarkerAt(ctx.wx, ctx.wz)
            end })
        end
        table.insert(items, { title = 'Place marker', submenu = sub })
    end
    if HasTool('army') then
        table.insert(items, EditItem('Add start position here', function() import('/lua/editor/armies.lua').Place(ctx.wx, ctx.wz) end))
    end
    if HasTool('area') then
        table.insert(items, EditItem('Add area here (40 x 40)', function() Tools.NewArea(ctx.wx - 20, ctx.wz - 20, ctx.wx + 20, ctx.wz + 20) end))
    end
    if HasTool('unit') then
        local active = Units().Active
        table.insert(items, { title = active and ('Place ' .. tostring(active) .. ' here') or 'Place unit here', enabled = function() return Editable() and Units().Active ~= false end,
            why = function() if not Editable() then return 'read-only workspace' end return 'pick a unit in the Units panel' end,
            run = function() Units().Place(ctx.wx, ctx.wz) end })
    end
    if table.getn(items) > 0 then return items end
    return nil
end, 20)

Menu.Extend('context.world', function(ctx)
    return {
        { title = 'Paste here', enabled = function() return Editable() and Clipboard().Count() > 0 end,
          why = function() if not Editable() then return 'read-only workspace' end return 'nothing copied' end,
          run = function() Clipboard().Paste(ctx.wx, ctx.wz) end },
    }
end, 30)

Menu.Extend('context.world', function(ctx)
    local items = {}
    if Selected() then
        table.insert(items, { title = 'Focus camera on the selection', run = function() Camera.FocusSelection() end })
    end
    if HasTool('paths') then
        local Paths = import('/lua/editor/paths.lua')
        local cur = Paths.CurrentPath()
        if cur and table.getn(cur.points) > 0 then
            table.insert(items, { title = 'Focus camera on current path', run = function()
                local x, z = Paths.SelectionCenter()
                if x then Camera.FocusOn(x, z) end
            end })
        end
    end
    table.insert(items, { title = 'Focus camera here', run = function() Camera.FocusOn(ctx.wx, ctx.wz) end })
    table.insert(items, { title = 'Camera', submenu = {
        { command = 'camera.topdown' },
        { command = 'camera.north' },
        { command = 'camera.reset' },
    } })
    return items
end, 40)

--- Right click in the viewport (a click, not a drag).
local function WorldContext(view, x, y)
    local p = UnProject(view, Vector2(x, y))
    if not p then return end
    local wx, wz = p[1], p[3]
    local height = ed_terrain_get(math.floor(wx + 0.5), math.floor(wz + 0.5)) or 0
    local ctx = { wx = wx, wz = wz, height = height }
    if Map.Doc then
        local ok, h = pcall(Tools.Pick, wx, wz, x, y)
        if ok then ctx.hit = h end
        if not ctx.hit and HasTool('unit_select') then ctx.unit = Units().Pick(wx, wz, 3) end
        if not ctx.hit and not ctx.unit and HasTool('prop_select') then ctx.prop = Props().Pick(wx, wz) end
        if not ctx.hit and not ctx.unit and not ctx.prop and HasTool('decal_select') then ctx.decal = Decals().Pick(wx, wz) end
    end
    Menu.Context('context.world', ctx, x, y)
end

Camera.OnClick = WorldContext
ContextForWorld = WorldContext      -- for the checks

-- Lists: ctx.list names the panel. Panels that own other lists (hotkeys.lua) extend 'context.list' themselves.
Menu.Extend('context.list', function(ctx)
    if ctx.list == 'outliner' then
        return Menu.Build('context.object', ctx)
    elseif ctx.list == 'markers' then
        return {
            { title = 'Use ' .. tostring(ctx.name) .. ' for placing', run = function()
                Tools.SetMarkerType(ctx.name)
                UI.SelectTool('marker')
            end },
            { title = 'Place ' .. tostring(ctx.name) .. ' at the camera focus', enabled = Editable, why = 'read-only workspace', run = function()
                local s = GetCamera('WorldCamera'):SaveSettings()
                Tools.SetMarkerType(ctx.name)
                UI.PlaceMarkerAt(s.Focus[1], s.Focus[3])
            end },
        }
    end
    return nil
end, 10)
