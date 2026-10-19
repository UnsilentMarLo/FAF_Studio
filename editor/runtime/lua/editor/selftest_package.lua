-- Self test of the packaging branch (docs/projects/editor/PACKAGING.md): user data files, layout sanitising, help content and search, tooltips coverage, the scmap preview
-- parser, crash report detection, the autosave marker, the tour, the start screen. Through /edcmd:
--   return import('/lua/editor/selftest_package.lua').Run()      a string that starts with PASS or FAIL
--
-- Everything that writes uses a folder of its own (`userdata_selftest` next to the exe) instead of the user's: UserData.SetDirForTest.
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')
local Workspace = import('/lua/editor/gui/workspace.lua')
local Help = import('/lua/editor/help.lua')
local Tips = import('/lua/editor/tooltips.lua')
local Thumbs = import('/lua/editor/thumbs.lua')
local Crash = import('/lua/editor/crash.lua')

local failures = {}

local function Check(name, ok)
    if not ok then table.insert(failures, name) end
end

local function Has(list, value)
    for _, v in list do
        if v == value then return true end
    end
    return false
end

local function Second(a, b)
    return b
end

local function LE32(n)
    return string.char(math.mod(n, 256), math.mod(math.floor(n / 256), 256), math.mod(math.floor(n / 65536), 256), math.mod(math.floor(n / 16777216), 256))
end

function Run()
    failures = {}
    local notes = {}

    -- ---- user data -------------------------------------------------------------------------------------------------------------------------
    UserData.SetDirForTest('userdata_selftest')
    UserData.Reset()
    Check('userdata: a missing file reads as missing', Second(UserData.ReadTable('nothing.lua')) == 'missing')
    Check('userdata: write ok', UserData.WriteTable('t1.lua', { a = 1, b = 'two', c = true, d = { 1, 2, 3 }, e = { x = 0.5 } }))
    local t, status = UserData.ReadTable('t1.lua')
    Check('userdata: round trip', status == 'ok' and t.a == 1 and t.b == 'two' and t.c == true and t.d[3] == 3 and t.e.x == 0.5 and t.format == UserData.FORMAT)
    ed_write_file(UserData.Path('t2.lua'), 'return { this is not lua')
    local bad, status2 = UserData.ReadTable('t2.lua')
    Check('userdata: a broken file is reported bad', bad == nil and status2 == 'bad')
    Check('userdata: a broken file is kept as .bad', (ed_read_file(UserData.Path('t2.lua.bad')) or '') == 'return { this is not lua')
    Check('userdata: a broken file is emptied so it is read as missing next time', Second(UserData.ReadTable('t2.lua')) == 'missing')
    ed_write_file(UserData.Path('t3.lua'), 'return { format = 999, keep = 5 }')
    local newer, status3 = UserData.ReadTable('t3.lua')
    Check('userdata: a newer format is read', status3 == 'newer' and newer.keep == 5)
    Check('userdata: a newer format is not overwritten', UserData.WriteTable('t3.lua', { keep = 6 }) == false and string.find(ed_read_file(UserData.Path('t3.lua')), 'keep = 5', 1, true) ~= nil)
    UserData.Set('qa_value', 42)
    UserData.Set('qa_table', { 1, 2 })
    UserData.Flush()
    local stored = UserData.ReadTable('settings.lua')
    Check('userdata: settings are written by Flush', stored and stored.qa_value == 42 and stored.qa_table[2] == 2)
    Check('userdata: Get with a default', UserData.Get('qa_missing', 'dflt') == 'dflt' and UserData.Get('qa_value', 0) == 42)
    local cleared = UserData.Reset()
    Check('userdata: reset empties the files it knows', Has(cleared, 'settings.lua') and Second(UserData.ReadTable('settings.lua')) == 'missing')
    Check('userdata: reset forgets the loaded values', UserData.Get('qa_value', 'gone') == 'gone')

    -- ---- layouts ---------------------------------------------------------------------------------------------------------------------------
    local layout = {
        tree = { kind = 'split', dir = 'row', ratio = 7, a = { kind = 'stack', tabs = { 'tools', 'no_such_panel' }, active = 5 },
                 b = { kind = 'split', dir = 'col', ratio = 0.4, a = { kind = 'stack', tabs = { 'also_not_there' }, active = 1 }, b = { kind = 'stack', tabs = { 'viewport' }, active = 1 } } },
        popouts = {
            { tree = { kind = 'stack', tabs = { 'console' }, active = 1 }, x = 10, y = 20, w = 300, h = 200 },
            { tree = { kind = 'stack', tabs = { 'console' }, active = 1 } },                                   -- no geometry
            { tree = { kind = 'stack', tabs = { 'gone' }, active = 1 }, x = 0, y = 0, w = 10, h = 10 },      -- nothing left in it
        },
    }
    local clean = Workspace.Sanitize(layout)
    Check('layout: sanitise keeps a tree', clean ~= nil and clean.tree ~= nil)
    if clean then
        Check('layout: unknown panels are dropped from a stack', table.getn(clean.tree.a.tabs) == 1 and clean.tree.a.tabs[1] == 'tools')
        Check('layout: active tab is brought into range', clean.tree.a.active == 1)
        Check('layout: a split ratio out of range is reset', clean.tree.ratio == 0.5)
        Check('layout: an emptied stack collapses into its sibling', clean.tree.b.kind == 'stack' and clean.tree.b.tabs[1] == 'viewport')
        Check('layout: only complete pop-outs with panels stay', table.getn(clean.popouts) == 1 and clean.popouts[1].w == 300)
    end
    Check('layout: nothing known left means nil', Workspace.Sanitize({ tree = { kind = 'stack', tabs = { 'zzz' }, active = 1 }, popouts = {} }) == nil)
    local kept = { tree = { kind = 'split', dir = 'row', ratio = 0.3, a = { kind = 'stack', tabs = { 'tools' }, active = 1 }, b = { kind = 'stack', tabs = { 'viewport' }, active = 1 } }, popouts = {} }
    Check('layout: kept layout is written', Workspace.SaveKept('QaSpace', kept))
    local back = Workspace.LoadKept('QaSpace')
    Check('layout: kept layout round trip', back and back.tree.ratio > 0.299 and back.tree.ratio < 0.301 and back.tree.b.tabs[1] == 'viewport' and back.format == UserData.FORMAT)
    Workspace.ForgetKept('QaSpace')
    Check('layout: forgetting a kept layout', Workspace.LoadKept('QaSpace') == nil)

    -- ---- remembered working state ----------------------------------------------------------------------------------------------------------
    local Terrain = import('/lua/editor/terrain.lua')
    local Persist = import('/lua/editor/persist.lua')
    local oldRadius = Terrain.Brush.radius
    Terrain.Brush.radius = 33
    Persist.Tick()
    local saved = UserData.Get('brush', false)
    Check('persist: a changed brush is noted', type(saved) == 'table' and saved.radius == 33)
    Terrain.Brush.radius = 5
    Persist.Restore()
    Check('persist: restore puts the brush back', Terrain.Brush.radius == 33)
    Terrain.Brush.radius = oldRadius
    Persist.Tick()

    -- ---- help ------------------------------------------------------------------------------------------------------------------------------
    local topics = Help.Topics()
    Check('help: topics exist', table.getn(topics) >= 11)
    local kinds = { h = true, p = true, li = true, step = true, kv = true }
    local shapeOk = true
    for _, topic in topics do
        if not topic.id or not topic.title or table.getn(topic.blocks) == 0 then shapeOk = false end
        for _, b in topic.blocks do
            if not kinds[b[1]] or type(b[2]) ~= 'string' then shapeOk = false end
        end
    end
    Check('help: every topic has an id, a title and well formed blocks', shapeOk)
    Check('help: an empty search lists every topic', table.getn(Help.Search('')) == table.getn(topics))
    local found = Help.Search('terrain from nothing')
    Check('help: search finds a topic by its title', table.getn(found) >= 1 and found[1].topic.id == 'terrain_from_nothing')
    Check('help: search matches text', Help.Search('autosave')[1] ~= nil)
    Check('help: every word must match', table.getn(Help.Search('autosave qqqzzz')) == 0)
    Check('help: nothing found is an empty list', table.getn(Help.Search('qqqzzzxxx')) == 0)
    local sc = Help.Find('shortcuts')
    local hasUndo, hasPalette = false, false
    for _, b in sc.blocks do
        if b[1] == 'kv' and b[2] == 'Undo' and string.find(b[3], 'Ctrl+Z', 1, true) then hasUndo = true end
        if b[1] == 'kv' and string.find(b[3], 'Ctrl+Shift+P', 1, true) then hasPalette = true end
    end
    Check('help: the shortcut sheet is built from the command registry', hasUndo and hasPalette)
    local tp = Help.Find('tools_and_panels')
    local listed = 0
    for _, b in tp.blocks do
        if b[1] == 'li' then listed = listed + 1 end
    end
    local UI = import('/lua/editor/ui.lua')
    local Panels = import('/lua/editor/gui/panels.lua')
    Check('help: the tools list names every tool and panel', listed >= table.getn(UI.Tools) + table.getn(Panels.All()))
    -- every `help.open` topic id that the editor itself asks for exists
    Check('help: the topics the editor opens exist', Help.Find('shortcuts') ~= nil and Help.Find('getting_started') ~= nil)

    -- ---- tooltips coverage (reported, not failed: branches add tools and panels without editing tooltips.lua) ---------------------------------
    local missing = {}
    for _, tool in UI.Tools do
        if not Tips.ForTool(tool.id) then table.insert(missing, 'tool ' .. tool.id) end
    end
    for _, def in Panels.All() do
        if not Tips.ForPanel(def.id) then table.insert(missing, 'panel ' .. def.id) end
    end
    for _, name in Workspace.Presets() do
        if not Tips.ForWorkspace(name) then table.insert(missing, 'workspace ' .. name) end
    end
    if table.getn(missing) > 0 then table.insert(notes, 'no tooltip for: ' .. table.concat(missing, ', ')) end
    local Tooltip = import('/lua/editor/gui/tooltip.lua')
    Tooltip.Hover({}, 'a tip', { MouseX = 10, MouseY = 10 })
    Check('tooltip: hovering starts the wait', Tooltip.State() == 'waiting')
    Tooltip.Hide()
    Check('tooltip: hiding clears it', Tooltip.State() == 'idle')

    -- ---- the scmap preview parser ------------------------------------------------------------------------------------------------------------
    local dds = 'DDS ' .. string.rep('x', 124) .. string.rep('y', 16)
    local file = 'Map\026' .. string.rep('a', 26) .. LE32(string.len(dds)) .. dds .. 'rest of the map'
    Check('thumbs: the preview blob is cut out', Thumbs.PreviewBlob(file) == dds)
    Check('thumbs: not a map file', Thumbs.PreviewBlob('hello world, this is long enough to look at but is no map file') == nil)
    Check('thumbs: a count beyond the file', Thumbs.PreviewBlob('Map\026' .. string.rep('a', 26) .. LE32(5000) .. dds) == nil)
    Check('thumbs: a blob that is not a DDS', Thumbs.PreviewBlob('Map\026' .. string.rep('a', 26) .. LE32(130) .. string.rep('z', 140)) == nil)

    -- ---- crash handling --------------------------------------------------------------------------------------------------------------------
    Check('crash: only the unseen reports are new', table.getn(Crash.Unseen({ 'faf_crash_1_1.txt', 'faf_crash_2_2.txt' }, { 'faf_crash_1_1.txt' })) == 1)
    Check('crash: nothing new', table.getn(Crash.Unseen({ 'faf_crash_1_1.txt' }, { 'faf_crash_1_1.txt', 'x' })) == 0)
    Check('crash: no autosave marker at first', Crash.PendingAutosave() == nil)
    Crash.NoteAutosave('My map')
    local pending = Crash.PendingAutosave()
    Check('crash: an autosave is remembered', pending ~= nil and pending.map == 'My map')
    Crash.ClearAutosave()
    Check('crash: saving clears the marker', Crash.PendingAutosave() == nil)
    local diag = Crash.Diagnostics()
    Check('crash: diagnostics start with the version', string.find(diag, 'FAF Studio', 1, true) ~= nil and string.find(diag, 'user folder', 1, true) ~= nil)
    Check('crash: the installation folder has no ..', string.find(Crash.Root(), '/..', 1, true) == nil)

    UserData.SetDirForTest(nil)

    -- ---- tour and start screen ----------------------------------------------------------------------------------------------------------------
    local Tour = import('/lua/editor/gui/tour.lua')
    local complete = table.getn(Tour.Steps) == 8
    for _, s in Tour.Steps do
        if not s.title or not s.text or not s.target then complete = false end
    end
    Check('tour: eight steps with a title, a text and a target', complete)
    local shell = import('/lua/editor/gui/shell.lua')
    local before = shell.S.current
    UserData.SetDirForTest('userdata_selftest')
    Tour.Start()
    Check('tour: starts', Tour.IsOpen())
    Tour.Stop(true)
    Check('tour: stops', not Tour.IsOpen())
    Check('tour: finishing is remembered', UserData.Get('tourDone', false) == true)
    UserData.Reset()
    UserData.SetDirForTest(nil)
    if shell.S.current ~= before then shell.ShowWorkspace(before) end
    local Start = import('/lua/editor/gui/startscreen.lua')
    Start.Open()
    Check('start screen: opens', Start.IsOpen())
    Start.Close()
    Check('start screen: closes', not Start.IsOpen())

    local text = 'PASS package'
    if table.getn(failures) > 0 then text = 'FAIL ' .. table.concat(failures, '; ') end
    if table.getn(notes) > 0 then text = text .. '\nNOTE ' .. table.concat(notes, '; ') end
    return text
end
