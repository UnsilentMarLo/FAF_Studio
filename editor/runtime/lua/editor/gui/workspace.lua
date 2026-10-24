-- Workspaces: named layouts (the dock tree of the main window plus the pop-out windows) with presets and saving.
--
--   Workspace.Presets()                -> list of preset names
--   Workspace.Fresh(name)              -> { tree = ..., popouts = { { tree, x, y, w, h } } }   a new copy of a preset
--   Workspace.Serialize(table)         -> Lua source text; Workspace.Save(name, layout) / Workspace.Load(name)
-- Saved files live in `workspaces/<name>.lua` next to the engine's working directory (a per-user folder comes with the file dialogs).

local function Stack(tabs) return { kind = 'stack', tabs = tabs, active = 1 } end
local function Split(dir, ratio, a, b) return { kind = 'split', dir = dir, ratio = ratio, a = a, b = b } end

local presets = {
    -- The three workspaces keep the same skeleton (tools top left, the context panel under them, viewport in the middle, properties on the
    -- right, console / validation below) so nothing jumps between them; only the context panel changes: brush, markers, outliner.
    Terrain = function()
        return { tree =
            Split('row', 0.17,
                Split('col', 0.4, Stack({ 'tools' }), Stack({ 'brush', 'texbrush', 'shapes' })),
                Split('row', 0.78,
                    Split('col', 0.72, Stack({ 'viewport' }), Stack({ 'console', 'validation', 'mods', 'hotkeys' })),
                    Split('col', 0.62, Stack({ 'layers', 'ttype', 'ttlayers' }), Stack({ 'properties', 'toolsettings', 'view', 'symmetry' })))),
            popouts = {} }
    end,
    Objects = function()
        return { tree =
            Split('row', 0.17,
                Split('col', 0.42, Stack({ 'tools' }), Stack({ 'markers', 'props', 'decals', 'units' })),
                Split('row', 0.78,
                    Split('col', 0.72, Stack({ 'viewport' }), Stack({ 'console', 'validation', 'mods', 'hotkeys' })),
                    Split('col', 0.4, Stack({ 'outliner' }), Stack({ 'properties', 'toolsettings', 'view', 'symmetry' })))),
            popouts = {} }
    end,
    -- Map-wide settings: lighting, fog and water. The viewport shows the result; the camera is the only tool.
    Environment = function()
        return { tree =
            Split('row', 0.17,
                Split('col', 0.4, Stack({ 'tools' }), Stack({ 'view', 'hotkeys' })),
                Split('row', 0.56,
                    Split('col', 0.72, Stack({ 'viewport' }), Stack({ 'console', 'validation', 'mods' })),
                    Split('col', 0.5, Stack({ 'lighting', 'ambient' }), Stack({ 'water', 'waterlook', 'meshmap' })))),
            popouts = {} }
    end,
    -- Mission maps: armies, alliances and (later) stages, objectives and triggers beside the map.
    Mission = function()
        return { tree =
            Split('row', 0.17,
                Split('col', 0.42, Stack({ 'tools' }), Stack({ 'markers', 'units' })),
                Split('row', 0.56,
                    Split('col', 0.72, Stack({ 'viewport' }), Stack({ 'console', 'validation', 'mods' })),
                    Split('col', 0.62, Stack({ 'stages', 'armies' }), Stack({ 'outliner', 'properties', 'toolsettings', 'view' })))),
            popouts = {} }
    end,
    -- Mod projects: pick a unit, change its stats (merge blueprints), test the project in the editor world.
    Mod = function()
        return { tree =
            Split('row', 0.17,
                Split('col', 0.3, Stack({ 'tools' }), Stack({ 'view', 'hotkeys' })),
                Split('row', 0.56,
                    Split('col', 0.72, Stack({ 'viewport' }), Stack({ 'console', 'validation', 'mods' })),
                    Split('col', 0.5, Stack({ 'units' }), Stack({ 'unitlab', 'unitview', 'effects' })))),
            popouts = {} }
    end,
    -- Terrain generation: the node graph (canvas, node palette and library, inspector, variations) with the viewport below the canvas for the live preview.
    Generate = function()
        return { tree =
            Split('row', 0.16,
                Split('col', 0.3, Stack({ 'tools' }), Stack({ 'graphpalette' })),
                Split('row', 0.74,
                    Split('col', 0.6, Stack({ 'graphcanvas' }), Stack({ 'viewport', 'console' })),
                    Split('col', 0.6, Stack({ 'graphinspector' }), Stack({ 'graphgallery', 'validation', 'view', 'properties' })))),
            popouts = {} }
    end,
    -- Map layout: draw the map in layers on a canvas, turn it into terrain, and place the starts and resources around the bases; the viewport shows the result.
    Layout = function()
        return { tree =
            Split('row', 0.26,
                Split('col', 0.55, Stack({ 'layoutlayers' }), Stack({ 'layoutmarkers', 'tools' })),
                Split('row', 0.58,
                    Split('col', 0.74, Stack({ 'layoutcanvas' }), Stack({ 'console', 'validation' })),
                    Split('col', 0.6, Stack({ 'viewport' }), Stack({ 'view', 'properties', 'toolsettings' })))),
            popouts = {} }
    end,
    -- Review is read-only: the viewport and ONE tab stack with what looking at a map needs (View overlays, checks, statistics, the map's images, the objects, the log). No editing
    -- panels (Properties edits, Mods, Hotkeys); Tools stays last for the Select / Ruler / Camera tools, Save and Play test.
    Review = function()
        return { tree =
            Split('row', 0.68,
                Stack({ 'viewport' }),
                Stack({ 'view', 'validation', 'stats', 'terrainchecks', 'images', 'outliner', 'console', 'tools' })),
            popouts = {} }
    end,
}
local presetOrder = { 'Terrain', 'Objects', 'Environment', 'Layout', 'Generate', 'Mission', 'Mod', 'Review' }

-- A workspace whose preset changed for good gets a revision here: the arrangement the editor kept for it (layouts/<name>.lua, written without a `rev` by older editors) is dropped
-- once, so an old layout does not bring a removed panel arrangement back. Raise the number when a preset is redesigned again.
local LAYOUT_REV = { Review = 2 }

function Presets()
    return presetOrder
end

local function FindStack(node, id)
    if node.kind == 'stack' then
        for _, t in node.tabs do
            if t == id then return node end
        end
        return nil
    end
    if node.kind == 'split' then return FindStack(node.a, id) or FindStack(node.b, id) end
    return nil
end

--- Panels that name their place (`stack = { workspace = 'Mod', with = 'unitlab' }` in Panels.Register) join the tab stack of that panel in that workspace, so adding a
--- panel does not mean editing the presets above (and parallel feature branches do not collide there).
local function AttachPanels(name, layout)
    local ok, Panels = pcall(import, '/lua/editor/gui/panels.lua')
    if not ok or not Panels then return end
    for _, def in Panels.All() do
        -- one hint, or a list of hints ({ { workspace = 'Objects', with = 'x' }, { workspace = 'Terrain', with = 'y' } }) for a panel that belongs in several workspaces
        local hints = def.stack
        if hints and hints.workspace then hints = { hints } end
        for _, hint in hints or {} do
            if hint.workspace == name and not FindStack(layout.tree, def.id) then
                local stack = FindStack(layout.tree, hint.with)
                if stack then table.insert(stack.tabs, def.id) end
            end
        end
    end
end

--- Version of the layouts the editor writes (`layout.version`, apart from the preset revision `rev` above). A panel that came later names the version it came with (`addedInLayout = 2`
--- in Panels.Register, plus its `stack` hints): a layout saved by an older editor (no `version`, or a lower one) gets that panel added once, next to the panel the hints name, and is
--- stamped with the current version when it is written, so a panel the user closes afterwards stays closed.
LAYOUT_VERSION = 2

local function HasPanel(layout, id)
    if FindStack(layout.tree, id) then return true end
    for _, p in layout.popouts or {} do
        if p.tree and FindStack(p.tree, id) then return true end
    end
    return false
end

function Migrate(name, layout)
    local have = layout.version or 1
    if have >= LAYOUT_VERSION then return layout end
    local ok, Panels = pcall(import, '/lua/editor/gui/panels.lua')
    if ok and Panels then
        for _, def in Panels.All() do
            if def.addedInLayout and def.addedInLayout > have and not HasPanel(layout, def.id) then
                local hints = def.stack
                if hints and hints.workspace then hints = { hints } end
                for _, hint in hints or {} do
                    -- the first hint whose neighbour is in the layout wins (the later hints of a workspace are fallbacks)
                    if hint.workspace == name and not FindStack(layout.tree, def.id) then
                        local stack = FindStack(layout.tree, hint.with)
                        if stack then table.insert(stack.tabs, def.id) end
                    end
                end
            end
        end
    end
    layout.version = LAYOUT_VERSION
    return layout
end

function Fresh(name)
    local make = presets[name] or presets.Terrain
    local layout = make()
    AttachPanels(name, layout)
    return layout
end

-- ---- serialization (plain data only: runtime fields set by the dock are skipped) -------------------------------------------------

local skip = { ui = true, rect = true, gap = true, splitter = true }

local function Ser(v, indent)
    local t = type(v)
    if t == 'number' then return tostring(v)
    elseif t == 'boolean' then return tostring(v)
    elseif t == 'string' then return string.format('%q', v)
    elseif t == 'table' then
        local pad = indent .. '  '
        local parts = {}
        local n = table.getn(v)
        for i = 1, n do parts[table.getn(parts) + 1] = pad .. Ser(v[i], pad) end
        for k, val in v do
            if type(k) == 'string' and not skip[k] then
                parts[table.getn(parts) + 1] = pad .. k .. ' = ' .. Ser(val, pad)
            end
        end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

function Serialize(tbl)
    return 'return ' .. Ser(tbl, '') .. '\n'
end

local UserData = import('/lua/editor/userdata.lua')

--- Layout files (`return { format = N, tree = ..., popouts = ... }`). Two kinds in the user folder: `layouts/<name>.lua` is the arrangement the editor keeps for itself
--- (written whenever a panel is moved or resized, restored at the next start), `saved/<name>.lua` is the one the user saved on purpose (Workspace > Save current layout).
local function ReadLayout(rel)
    local text = ed_read_file(UserData.Path(rel))
    if not text or string.find(text, '^%s*$') then return nil end
    local okLoad, chunk = pcall(loadstring, text, '=workspace')     -- (loadstring raises on a syntax error)
    if not okLoad or not chunk then return nil end
    local ok, layout = pcall(chunk)
    if ok and type(layout) == 'table' and layout.tree then return layout end
    return nil
end

local function WriteLayout(rel, layout, name)
    layout.format = UserData.FORMAT
    layout.rev = name and LAYOUT_REV[name] or nil
    layout.version = LAYOUT_VERSION
    return ed_write_file(UserData.Path(rel), Serialize(layout))
end

--- Drops panels the editor does not have (an old file, a removed panel) from a loaded layout, and empty stacks with them. Returns the layout, or nil when nothing is left.
function Sanitize(layout)
    local ok, Panels = pcall(import, '/lua/editor/gui/panels.lua')
    local function Clean(node)
        if type(node) ~= 'table' then return nil end
        if node.kind == 'stack' then
            local kept = {}
            for _, id in node.tabs or {} do
                if not ok or not Panels or Panels.Get(id) then table.insert(kept, id) end
            end
            if table.getn(kept) == 0 then return nil end
            node.tabs = kept
            if not node.active or node.active < 1 or node.active > table.getn(kept) then node.active = 1 end
            return node
        elseif node.kind == 'split' then
            local a, b = Clean(node.a), Clean(node.b)
            if a and b then
                node.a, node.b = a, b
                if type(node.ratio) ~= 'number' or node.ratio < 0.05 or node.ratio > 0.95 then node.ratio = 0.5 end
                return node
            end
            return a or b
        end
        return nil
    end
    layout.tree = Clean(layout.tree)
    if not layout.tree then return nil end
    local pops = {}
    for _, p in layout.popouts or {} do
        local tree = Clean(p.tree)
        if tree and type(p.x) == 'number' and type(p.y) == 'number' and type(p.w) == 'number' and type(p.h) == 'number' then
            p.tree = tree
            table.insert(pops, p)
        end
    end
    layout.popouts = pops
    return layout
end

--- The arrangement kept for the workspace, or nil (first start, reset).
function LoadKept(name)
    local layout = ReadLayout('layouts/' .. name .. '.lua')
    if layout and (layout.rev or 1) < (LAYOUT_REV[name] or 1) then return nil end      -- kept before the preset was redesigned: start from the new preset
    layout = layout and Sanitize(layout)
    return layout and Migrate(name, layout)
end

function SaveKept(name, layout)
    return WriteLayout('layouts/' .. name .. '.lua', layout, name)
end

--- Forgets the kept arrangement (Reset layout of this workspace).
function ForgetKept(name)
    return ed_write_file(UserData.Path('layouts/' .. name .. '.lua'), '')
end

function Save(name, layout)
    return WriteLayout('saved/' .. name .. '.lua', layout, name)
end

function Load(name)
    local layout = ReadLayout('saved/' .. name .. '.lua')
    if not layout then
        -- an older editor saved next to the exe
        local text = ed_read_file('workspaces/' .. name .. '.lua')
        local okLoad, chunk = false, nil
        if text then okLoad, chunk = pcall(loadstring, text, '=workspace') end
        local ok, old = false, nil
        if okLoad and chunk then ok, old = pcall(chunk) end
        if ok and type(old) == 'table' and old.tree then layout = old end
    end
    layout = layout and Sanitize(layout)
    return layout and Migrate(name, layout)
end
