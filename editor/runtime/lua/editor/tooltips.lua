-- Short descriptions of tools, panels and workspaces: the tooltips (hover a button or a panel tab) and the "Tools and panels" topic of the help (F1). One sentence each,
-- written for someone who has not used the editor before. A tool or panel that has no entry here still works; it just has no tooltip (selftest_package lists the gaps).
--
--   ForTool(id) / ForPanel(id) / ForWorkspace(name) -> text | nil
--   ForWidget(panelId, label) -> text | nil    a button / slider / text field of a panel: tipdata.lua Widget['<panel>/<label>'], else Widget['*/<label>'] (a label that means the same in
--                                              every panel: Clear, Apply ...); labels are matched without case, without what follows a ':' and without a trailing '...' or number
--   ForCommand(id) -> text | nil               a command (menu entries, the palette): tipdata.lua Command[id], else a rule for the families ('panel.open.<id>', 'workspace.<name>' ...)
--   ForMenuItem(item) -> text | nil            a resolved menu item: its own `tip`, else the command's text, else tipdata.lua Menu[<normalised title>]
--   Hotkey(commandId) -> 'Ctrl+Z' | nil        the key binding the command has now (hotkeys.lua may have changed it);   WithHotkey(text, commandId) -> text + a "Shortcut: ..." line
--   Norm(label)                                the matching form of a label
--
-- Lua 5.0 dialect.

Tool = {
    select = 'Click a marker or area to select it; drag on empty ground to draw a selection box; Shift adds. Drag a selection to move it.',
    raise = 'Raises the ground under the brush. Hold Shift to lower instead. Radius and strength are in the Brush panel.',
    lower = 'Lowers the ground under the brush.',
    flatten = 'Levels the ground to the height under the first click of the stroke.',
    smooth = 'Smooths bumps by averaging the heights under the brush.',
    plateau = 'Pulls the ground under the brush to one level in a single go; the falloff shapes the shoulder.',
    erode = 'Erosion brush: wears the ground away under the brush. Its settings are in the Erosion panel.',
    rain = 'Erosion brush: simulated rainfall under the brush. Its settings are in the Erosion panel.',
    deposit = 'Erosion brush: lets loose material settle under the brush. Its settings are in the Erosion panel.',
    noise = 'Adds random bumps under the brush.',
    stamp = 'Presses the picture of the chosen stamp into the ground along a stroke (add, subtract, max, min, replace). Pick the stamp in the Stamps panel.',
    stamp_paint = 'Paints the active terrain layer through the picture of the chosen stamp. Pick the stamp in the Stamps panel.',
    paint = 'Paints the chosen texture layer (Layers panel) on the ground.',
    erase = 'Removes the chosen texture layer under the brush, so the layer below shows.',
    ttype = 'Paints terrain types: how the ground sounds and how units treat it (Terrain type panel).',
    ramp = 'Drag from one point to another: the ground between them becomes a straight slope, as wide as the brush.',
    paths = 'Draws spline paths (roads, rivers, ridges) on the terrain. Click to add points; the Paths panel sets what they do.',
    prop = 'Brush that places props (trees, rocks, wrecks). Pick the prop in the Props panel.',
    prop_erase = 'Removes props under the brush.',
    decal = 'Brush that places decals (ground details). Pick the decal in the Decals panel.',
    decal_erase = 'Removes decals under the brush.',
    unit = 'Places the unit chosen in the Units panel for the army shown there. A ghost shows where; drag for a line of units along the build grid, hold Shift and click for a line with corners.',
    prop_place = 'Places the prop chosen in the Props panel, one at a time, with a ghost; drag for a line of props, Shift and click for corners.',
    decal_place = 'Places the decal chosen in the Decals panel, one at a time, with a preview; drag for a line of decals, Shift and click for corners.',
    unit_select = 'Click units to select them, Shift adds, drag on empty ground for a box. Drag a selection to move it.',
    decal_select = 'Click decals to select them, Shift adds, drag on empty ground for a box. Drag a selection to move it.',
    prop_select = 'Click props to select them, Shift adds, drag on empty ground for a box. Drag a selection to move it.',
    marker = 'Places the marker type chosen in the Markers panel (mass, hydrocarbon, expansion, rally points ...).',
    army = 'Places the next start position (ARMY_1, ARMY_2 ...).',
    area = 'Drag a rectangle on the ground: areas are used by missions and scripts.',
    ruler = 'Drag to measure a distance over the terrain. Shift continues the line.',
    camera = 'No tool: the mouse only moves the camera.',
    crater = 'Example tool of the editor_example mod (a sample of how mods add tools).',
}

Panel = {
    viewport = 'The live map. Zoom with the wheel, pan with the middle button, rotate with the right button.',
    outliner = 'Every marker and area of the map. Click to select, right-click for a menu.',
    properties = 'Values of the selected object, or the settings of the active tool.',
    console = 'Messages from the editor.',
    tools = 'The tools of this workspace, and Undo, Redo, Save, Play test and Mods.',
    brush = 'Radius, strength and falloff of the brush, and the shape of its weight.',
    texbrush = 'Settings of the texture painting brush.',
    shapes = 'A mask or shape for the brushes instead of the round falloff.',
    layers = 'The ten terrain texture layers: pick one to paint with, change its texture and tile size.',
    ttype = 'Terrain types and the grid that shows them on the map.',
    ttlayers = 'Fills the terrain types from the textures of the layers.',
    symmetry = 'Mirrors brushes, markers and units. Set it before you start.',
    view = 'Overlays: the build grid and the slope view.',
    markers = 'Palette of marker types. Pick one, then click in the viewport.',
    props = 'List of props for the prop brush.',
    decals = 'List of decals for the decal brush.',
    units = 'List of unit blueprints and the army the unit tool places for.',
    armies = 'The armies of a mission: faction, colour, economy and who is allied or hostile.',
    stages = 'The stages of a mission and the nodes (actions and triggers) of each.',
    bases = 'AI bases of a mission: define one from an area.',
    run = 'A test run of the mission: stage, objectives, flags, warnings; jump to a stage.',
    strings = 'Dialogue text of the mission.',
    validation = 'Checks resource markers and mods. Check now runs it; click a problem to go there.',
    terrainchecks = 'Checks ground around the bases, paths between start positions, symmetry.',
    mods = 'The mods loaded for this map; Apply & reload restarts the session with them.',
    hotkeys = 'Every key and mouse gesture, with their current bindings. Click to change.',
    lighting = 'Sun and bloom of the map.',
    ambient = 'Ambient light and fog.',
    water = 'Water surface settings of the map.',
    waterlook = 'Look of the water: colours, reflection, sun highlights and waves.',
    meshmap = 'Settings of a mesh terrain map (terrain/terrain.lua).',
    meshimport = 'Imports a 3D model (OBJ) as terrain patches.',
    unitlab = 'Mod project and the stats of one unit; writes merge blueprints.',
    unitview = 'The unit on a stage: ranges, hit box, bones, animations.',
    effects = 'Effect templates and projectiles; edit their numbers into the project.',
    icons = 'Renders the strategic icon of a unit and writes it into the project.',
    interop = 'Import and export of heightmaps and masks (Gaea, World Machine, Blender ...).',
    erosion = 'Erosion presets and solvers, with a live preview; Apply is one undo step.',
    fields = 'Low level field engine: step-by-step terrain shaping.',
    maskgen = 'Makes masks from slope, height, curvature and more, and applies them to layers.',
    recipes = 'Terrain texturing presets: grass, dirt, rock, snow from slope and height rules.',
    scatter = 'Fills the map with props by rules: density, slope, spacing.',
    sctools = 'Base pads and resource rings, symmetry, slope limits, skeleton generator.',
    paths = 'Spline paths: list, points, profile and what they carve or paint.',
    graphcanvas = 'The terrain graph: nodes and wires that generate terrain.',
    graphgallery = 'Six variations of the graph for different seeds.',
    graphinspector = 'Parameters of the selected graph node.',
    graphpalette = 'All node types and the graph library; click to add.',
    help = 'Help topics, search and the list of shortcuts.',
    assets = 'Every unit, prop, decal, marker, texture, effect and mod project in one place, with pictures, search and favourites. Drag an entry into the viewport to place it.',
    chains = 'Chains of markers: the paths that patrol orders and mission nodes follow.',
    history = 'The list of everything you did; click an entry to go back to that point.',
    stamps = 'Pictures to press into the ground or paint through, with their settings.',
    stats = 'Counts of the objects of the map and of what they cost the game.',
    looks = 'A library of lighting looks (sun, ambient, fog, water, sky) with pictures; click one to try it, Apply makes it permanent.',
    platoons = 'Platoon templates, order queues and platoon builders of the armies.',
    sky = 'Colours of the sky dome, its size and shape and the cirrus clouds.',
    skytex = 'The textures of the sky: billboard atlases, cirrus and cumulus clouds, the sky cube and the background.',
    skyobjects = 'The sun, moon and planet billboards of the sky: direction, distance, size and rotation.',
    themes = 'A library of terrain texture sets; click one to try it, Apply makes it permanent.',
    watermotion = 'The water ramp, cube map and wave normal maps, and how fast and where the waves move; also the strategic view colours.',
    imager = 'The strategic view: contour spacing and the colours of the zoomed out map.',
    unitwiz = 'The wizard that makes a new unit or changes a unit step-by-step.',
    brushes = 'A sample panel list of brush names (framework demo).',
}

Workspace = {
    Terrain = 'Height and texture brushes, layers, symmetry.',
    Objects = 'Markers, start positions, props, decals and units.',
    Environment = 'Sun, fog and water.',
    Generate = 'Terrain from rules, masks and node graphs.',
    Mission = 'Armies, stages, objectives and triggers.',
    Mod = 'Units and their blueprints: unit lab, viewer, effects, icons.',
    Review = 'Look at the map, validate it and release it.',
}

function ForTool(id) return Tool[id] end
function ForPanel(id) return Panel[id] end
function ForWorkspace(name) return Workspace[name] end

-- ---- widgets, commands, menu items ---------------------------------------------------------------------------------------------------------------

local data = false

local function Data()
    if not data then
        local ok, mod = pcall(import, '/lua/editor/tipdata.lua')
        data = ok and mod or { Widget = {}, Command = {}, Menu = {} }
        if not ok then WARN('tooltips: tipdata.lua failed: ' .. tostring(mod)) end
    end
    return data
end

--- The matching form of a label: lower case, without what follows a ':', a trailing '...' or ' (...)', and with digit runs as '#'.
function Norm(label)
    local t = string.lower(tostring(label or ''))
    t = string.gsub(t, ':.*$', '')
    t = string.gsub(t, '%s*%(.*$', '')
    t = string.gsub(t, '%.%.%.$', '')
    t = string.gsub(t, '%d+', '#')
    t = string.gsub(t, '^%s+', '')
    t = string.gsub(t, '%s+$', '')
    return t
end

function ForWidget(panelId, label)
    local d = Data().Widget
    local key = Norm(label)
    if key == '' then return nil end
    if panelId then
        local v = d[panelId .. '/' .. key]
        if v then return v end
    end
    return d['*/' .. key]
end

function Hotkey(commandId)
    local ok, Commands = pcall(import, '/lua/editor/gui/commands.lua')
    local def = ok and Commands.registry and Commands.registry[commandId]
    if not def then return nil end
    local keys = def.keys
    if (not keys or keys == '') and def.keys2 and def.keys2 ~= '' then keys = def.keys2 end
    if not keys or keys == '' then return nil end
    return (string.gsub(keys, '%-', '+'))
end

function WithHotkey(text, commandId)
    if not text then return nil end
    local k = Hotkey(commandId)
    if not k then return text end
    return text .. '\n@Shortcut: ' .. k
end

--- Rules for the command families whose text follows from their id.
local function CommandRule(id)
    local _, _, pid = string.find(id, '^panel%.open%.(.+)$')
    if pid then
        local t = Panel[pid]
        return 'Shows the ' .. ((import('/lua/editor/gui/panels.lua').Title(pid)) or pid) .. ' panel.' .. (t and (' ' .. t) or '')
    end
    local _, _, ws = string.find(id, '^workspace%.(.+)$')
    if ws then
        for name, text in Workspace do
            if string.lower(name) == string.lower(ws) then return 'Switches to the ' .. name .. ' workspace. ' .. text end
        end
    end
    return nil
end

function ForCommand(id)
    local v = Data().Command[id]
    if v then return v end
    return CommandRule(id)
end

function ForMenuItem(r)
    if r.tip and r.tip ~= '' then return r.tip end
    if r.command then
        local t = ForCommand(r.command)
        if t then return t end
    end
    local key = Norm(r.title)
    local menu = Data().Menu
    if menu[key] then return menu[key] end
    for pattern, text in menu do
        if string.sub(pattern, 1, 1) == '^' and string.find(key, pattern) then return text end
    end
    return nil
end
