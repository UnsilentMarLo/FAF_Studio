-- Click sweep: presses every button of the editor's panels and dialogs once, so an error in a click handler (a nil closure variable, a missing function, a
-- wrong argument) shows up without a person clicking through everything. Used by scripts/editor_nightly.py (step `clicks`).
--
--   Run(panelId)     shows the panel, presses each of its buttons (a dialog a press opens is swept too, to depth 2, then closed)
--   Skipped          button texts that are not pressed: they leave the process (file dialogs, play test) or destroy what the sweep is standing on
--
-- A press is the same HandleEvent call the engine makes; an error is caught here and returned (the engine would only log it). Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Menu = import('/lua/editor/gui/menu.lua')

--   Collect          nil, or a function(entries, where) called with the widgets (buttons, sliders, text fields: W.tracking entries) of the panel and of every dialog a press opened (tipcheck.lua)

Collect = false

-- case-insensitive fragments of button texts
Skipped = { 'play test', 'play', 'open map', 'import', 'export', 'browse', 'load', 'release', 'pack', 'exit', 'quit', 'new map', 'save', 'render', 'batch',
            'write', 'recover', 'apply & reload', 'mods', 'test', 'generate', 'build', 'run', 'start', 'launch', 'link', 'live', 'sync', 'jump' }

local function Skip(text)
    text = string.lower(tostring(text or ''))
    for _, frag in Skipped do
        if string.find(text, frag, 1, true) then return true end
    end
    return false
end

-- A native file dialog (ed_file_dialog, ed_files_dialog, ed_folder_dialog: Interop > Add files, Stamps > Import, the export buttons) is modal and blocks the UI thread until
-- a person answers: a press that opens one hangs the whole run (found 2026-10-19: the nightly's stack showed GetOpenFileNameW). While a button is pressed here, the dialogs
-- answer "cancelled" at once.
local DIALOGS = { 'ed_file_dialog', 'ed_files_dialog', 'ed_folder_dialog' }
local function NoDialog() return nil end

local function Press(entry, errors, where)
    if not entry.button or Skip(entry.text) then return false end
    local b = entry.button
    -- a button of a panel part that was rebuilt meanwhile (destroyed) is stale: pressing it proves nothing
    local okParent, parent = pcall(function() return b:GetParent() end)
    if not okParent or parent == nil then return false end      -- (a destroyed control answers nil)
    local real = {}
    for _, name in DIALOGS do
        real[name] = rawget(_G, name)
        if real[name] then rawset(_G, name, NoDialog) end
    end
    local ok, err = pcall(function()
        if b.HandleEvent then b:HandleEvent({ Type = 'ButtonPress', Modifiers = {}, MouseX = 0, MouseY = 0 }) end
    end)
    for name, fn in real do rawset(_G, name, fn) end
    if not ok then table.insert(errors, where .. ' [' .. tostring(entry.text) .. ']: ' .. string.sub(tostring(err), 1, 200)) end
    return true
end

--- Presses the recorded buttons; dialogs they open are swept in turn.
local function Sweep(list, errors, where, depth)
    local pressed = 0
    for _, entry in list do
        local before = table.getn(W.tracking or {})
        local fresh = {}
        local mark = W.tracking
        W.tracking = fresh
        if Press(entry, errors, where) then pressed = pressed + 1 end
        W.tracking = mark
        if Collect and table.getn(fresh) > 0 then pcall(Collect, fresh, where .. ' > ' .. tostring(entry.text)) end
        if Dialog.IsOpen() then
            if depth < 2 and table.getn(fresh) > 0 then
                pressed = pressed + Sweep(fresh, errors, where .. ' > ' .. tostring(entry.text), depth + 1)
            end
            pcall(Dialog.Close)
        end
        pcall(Menu.Close)
    end
    return pressed
end

--- Shows the panel (re-creating it so its buttons are recorded) and presses everything. -> number of presses, list of errors.
function Run(panelId)
    local Shell = import('/lua/editor/gui/shell.lua')
    local errors = {}
    local list = {}
    W.tracking = list
    local ok, err = pcall(function()
        local main = Shell.S.main
        if main and main.instances[panelId] then main:DropInstance(panelId) end
        if main and not main:ShowPanel(panelId) then main:AddPanel(panelId) end
    end)
    W.tracking = false
    if not ok then return 0, { panelId .. ': could not be shown: ' .. tostring(err) } end
    if Collect then pcall(Collect, list, panelId) end
    local n = Sweep(list, errors, panelId, 0)
    pcall(Dialog.Close)
    return n, errors
end

--- A document with something in every list the panels show: a second army with groups, markers, an area, units, a mission (stages, nodes, a trigger with a child,
--- a dialogue), a base with a group and an attack. The panels are swept on this, so the buttons that need a selection have one. Safe to call twice.
function Fixture()
    local Map = import('/lua/editor/map.lua')
    local M = import('/lua/editor/mission.lua')
    local Tools = import('/lua/editor/tools.lua')
    local Units = import('/lua/editor/units.lua')
    local A = import('/lua/editor/armysetup.lua')
    local B = import('/lua/editor/mbase.lua')
    if not Map.Doc then Map.Load() end
    if not A.Get('Enemy') then A.Add('Enemy') end
    local groups = Map.Doc.save.Armies.Enemy.Units.Units
    groups.WAVE1 = groups.WAVE1 or { type = 'GROUP', orders = '', platoon = '', Units = {} }
    groups.DEF1 = groups.DEF1 or { type = 'GROUP', orders = '', platoon = '', Units = {} }
    Tools.PlaceMarker(60, 60, 'Mass', 'FIX_MASS')
    Tools.PlaceMarker(80, 70, 'Defensive Point', 'FIX_DEF')
    Tools.NewArea(100, 100, 140, 130)
    Units.Active = 'uel0106'
    Units.ArmyName = 'Enemy'
    Units.Place(70, 90)
    M.Data = { mode = 'both', stages = {}, bases = {}, dialogues = {} }
    M.AddStage('One') M.AddStage('Two')
    M.AddNode(1, 'ready', 'spawn')
    M.SetParam(1, 'ready', 1, 'army', 'Enemy') M.SetParam(1, 'ready', 1, 'group', 'WAVE1') M.SetParam(1, 'ready', 1, 'var', 'w')
    M.AddNode(1, 'ready', 'obj_kill') M.SetParam(1, 'ready', 2, 'var', 'w')
    local ok, tp = M.AddNode(1, 'ready', 'timer')
    if ok then M.AddNode(1, 'ready', 'text', nil, tp) end
    M.AddNode(2, 'ready', 'end')
    M.AddDialogue('Intro') M.AddLine(1, 'Commander, the enemy is near.')
    B.AddBase('Alpha', 'Enemy')
    B.AddGroup(1, 'DEF1', 100)
    B.AddOpAI(1)
    M.Revision = M.Revision + 1
    Tools.Select('marker', 'FIX_MASS')
    return 'fixture ready'
end
