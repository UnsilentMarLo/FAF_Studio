-- Commands and menu items of the parity audit's additions (docs/projects/editor/PARITY_AUDIT.md): Edit > Align / Distribute / Arrange in a circle / Snap selection to grid /
-- Find and replace..., File > Export > Preview image (PNG)... . A self-registering feature module (gui/feature_*.lua are imported by the shell). Logic: arrange.lua, findreplace.lua,
-- preview.lua, png.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Tools = import('/lua/editor/tools.lua')
local Arrange = import('/lua/editor/arrange.lua')
local FR = import('/lua/editor/findreplace.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

-- ---- align / distribute / snap ---------------------------------------------------------------------------------------------------------------------

local function Do(label, fn)
    local n = fn()
    Say(label .. ': ' .. tostring(n) .. ' moved')
end

local ALIGN = {
    { 'left', 'Align left (west)' }, { 'centerx', 'Align centre horizontally' }, { 'right', 'Align right (east)' },
    { 'top', 'Align top (north)' }, { 'centerz', 'Align centre vertically' }, { 'bottom', 'Align bottom (south)' },
}
for _, a in ALIGN do
    local mode = a[1]
    Commands.Register{ id = 'edit.align.' .. mode, title = 'Edit: ' .. a[2], run = function() Do(a[2], function() return Arrange.Align(mode) end) end }
end
Commands.Register{ id = 'edit.distribute.x', title = 'Edit: distribute horizontally', run = function() Do('Distribute', function() return Arrange.Distribute('x') end) end }
Commands.Register{ id = 'edit.distribute.z', title = 'Edit: distribute vertically', run = function() Do('Distribute', function() return Arrange.Distribute('z') end) end }
Commands.Register{ id = 'edit.circle', title = 'Edit: arrange in a circle', run = function() Do('Circle', function() return Arrange.Circle() end) end }
for _, step in { 1, 2, 4, 8 } do
    Commands.Register{ id = 'edit.snap.' .. step, title = 'Edit: snap selection to a ' .. step .. ' unit grid', run = function() Do('Snap', function() return Arrange.Snap(step) end) end }
end

local function NeedsSelection(n)
    return function() return not Tools.ReadOnly and Arrange.Count() >= n end
end

Menu.Extend('menubar.Edit', function()
    return {
        { title = 'Align', submenu = {
            { command = 'edit.align.left', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
            { command = 'edit.align.centerx', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
            { command = 'edit.align.right', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
            { command = 'edit.align.top', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
            { command = 'edit.align.centerz', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
            { command = 'edit.align.bottom', nokeys = true, enabled = NeedsSelection(2), why = 'select two or more objects' },
        } },
        { title = 'Distribute', submenu = {
            { command = 'edit.distribute.x', nokeys = true, enabled = NeedsSelection(3), why = 'select three or more objects' },
            { command = 'edit.distribute.z', nokeys = true, enabled = NeedsSelection(3), why = 'select three or more objects' },
        } },
        { command = 'edit.circle', nokeys = true, enabled = NeedsSelection(3), why = 'select three or more objects' },
        { title = 'Snap selection to grid', submenu = {
            { command = 'edit.snap.1', nokeys = true, enabled = NeedsSelection(1), why = 'nothing selected' },
            { command = 'edit.snap.2', nokeys = true, enabled = NeedsSelection(1), why = 'nothing selected' },
            { command = 'edit.snap.4', nokeys = true, enabled = NeedsSelection(1), why = 'nothing selected' },
            { command = 'edit.snap.8', nokeys = true, enabled = NeedsSelection(1), why = 'nothing selected' },
        } },
        { command = 'edit.mirror', enabled = function() return not Tools.ReadOnly and import('/lua/editor/mirror.lua').Available() and import('/lua/editor/gui/panels_objects.lua').AnySelection() end,
          why = function() if not import('/lua/editor/mirror.lua').Available() then return 'set a symmetry mode first' end return 'nothing selected' end },
        { command = 'edit.findreplace', enabled = function() return not Tools.ReadOnly end, why = 'read-only workspace' },
    }
end, 40)

Commands.Register{ id = 'edit.mirror', title = 'Edit: mirror selection through the symmetry', run = function()
    local n, why = import('/lua/editor/mirror.lua').Mirror()
    Say(n > 0 and ('mirror: ' .. n .. ' copies') or ('mirror: ' .. tostring(why)))
end }

-- ---- find and replace ---------------------------------------------------------------------------------------------------------------------------

local state = { kind = 'marker type', from = false, to = false, message = '' }

local function Label(v)
    if not v then return '(choose)' end
    local s = tostring(v)
    if string.len(s) > 34 then s = '...' .. string.sub(s, string.len(s) - 30) end
    return s
end

function FindDialog()
    local d = Dialog.Open('Find and replace objects', 520, 270)
    local c = Skin.color
    local Names = import('/lua/editor/gui/dialogs_mission.lua')
    local present = FR.Present(state.kind)
    local matches = state.from and FR.Count(state.kind, state.from) or 0
    d:Label('Objects', 14, 38, { color = c.textDim })
    d:Button(state.kind, 120, 34, 380, 24, function()
        local at = 1
        for i, k in FR.KINDS do if k == state.kind then at = i end end
        state.kind = FR.KINDS[math.mod(at, table.getn(FR.KINDS)) + 1]
        state.from, state.to, state.message = false, false, ''
        FindDialog()
    end, { tip = 'What kind of object to look for. Click to step to the next kind.' })
    d:Label('Find', 14, 74, { color = c.textDim })
    d:Button(Label(state.from) .. (state.from and ('   (' .. matches .. ')') or ''), 120, 70, 380, 24, function()
        local names, byLabel = {}, {}
        for _, e in present do
            local label = e.value .. '   (' .. e.count .. ')'
            table.insert(names, label)
            byLabel[label] = e.value
        end
        Names.PickName('Find: ' .. state.kind, names, nil, function(label)
            state.from = byLabel[label]
            state.message = ''
            FindDialog()
        end)
    end, { tip = 'Choose the value to look for; the number in brackets is how often it is in the map.' })
    d:Label('Replace with', 14, 110, { color = c.textDim })
    d:Button(Label(state.to), 120, 106, 380, 24, function()
        Names.PickName('Replace with', FR.Candidates(state.kind), state.to, function(value)
            state.to = value
            state.message = ''
            FindDialog()
        end)
    end, { tip = 'Choose what every match is replaced with.' })
    d:Label(state.message ~= '' and state.message or (state.from and (matches .. ' match(es) in the map') or 'choose what to find'), 14, 150, { color = c.text })
    d:Button('Select matches', 14, 190, 130, 28, function()
        if not state.from then state.message = 'choose what to find' FindDialog() return end
        local n = FR.Select(state.kind, state.from)
        state.message = n .. ' selected (use the matching select tool to see them)'
        FindDialog()
    end)
    d:Button('Replace all', 154, 190, 110, 28, function()
        if not (state.from and state.to) then state.message = 'choose both values' FindDialog() return end
        local n, why = FR.Replace(state.kind, state.from, state.to)
        if n > 0 then state.from = false end
        state.message = (n > 0) and (n .. ' replaced (one undo step)') or ('nothing replaced' .. (why and (': ' .. why) or ''))
        FindDialog()
    end)
    d:Button('Close', 274, 190, 90, 28, function() Dialog.Close() end)
end

Commands.Register{ id = 'edit.findreplace', title = 'Edit: find and replace objects...', run = function() FindDialog() end }

-- ---- preview image export ---------------------------------------------------------------------------------------------------------------------------

local function ExportPreview(size)
    local path = ed_file_dialog(true, 'Export preview image', 'PNG image (*.png)|*.png', 'preview.png')
    if not path then return end
    local ok, why = import('/lua/editor/preview.lua').ExportPng(path, size)
    Say(ok and ('preview image written: ' .. path) or ('preview export failed: ' .. tostring(why)))
end

Commands.Register{ id = 'file.export_preview256', title = 'File: export preview image (256 px)...', run = function() ExportPreview(256) end }
Commands.Register{ id = 'file.export_preview512', title = 'File: export preview image (512 px)...', run = function() ExportPreview(512) end }

Menu.Extend('menu.export', function()
    return {
        { title = 'Preview image (256 px)...', command = 'file.export_preview256' },
        { title = 'Preview image (512 px)...', command = 'file.export_preview512' },
    }
end, 20)

-- ---- environment styles ----------------------------------------------------------------------------------------------------------------------------

Commands.Register{ id = 'map.style_save', title = 'Map: save the environment style...', run = function()
    local path = ed_file_dialog(true, 'Save environment style', 'Environment style (*.lua)|*.lua', 'style.lua')
    if not path then return end
    local ok, why = import('/lua/editor/styles.lua').Save(path, false)
    Say(ok and ('style saved: ' .. path) or ('style not saved: ' .. tostring(why)))
end }
Commands.Register{ id = 'map.style_load', title = 'Map: load an environment style...', run = function()
    local path = ed_file_dialog(false, 'Load environment style', 'Environment style (*.lua)|*.lua', '')
    if not path then return end
    local n, why = import('/lua/editor/styles.lua').Load(path, false)
    Say(n > 0 and ('style loaded: ' .. n .. ' values (one undo step)') or ('style not loaded: ' .. tostring(why)))
end }

Menu.Extend('menubar.Map', function()
    return {
        { command = 'map.style_save', enabled = function() return not Tools.ReadOnly or true end },
        { command = 'map.style_load', enabled = function() return not Tools.ReadOnly end, why = 'read-only workspace' },
    }
end, 60)
