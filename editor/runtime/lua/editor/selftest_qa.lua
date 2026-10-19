-- Logic bugs found in the 2026-10 QA pass (docs/projects/editor/QA_2026-10.md), each pinned by a check. Through /edcmd:
--   return import('/lua/editor/selftest_qa.lua').Run()      returns a string that starts with PASS or FAIL

local Units = import('/lua/editor/units.lua')
local Maps = import('/lua/editor/maps.lua')
local History = import('/lua/editor/history.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap

local failures = {}

local function Check(name, ok)
    if not ok then table.insert(failures, name) end
end

function Run()
    failures = {}

    -- the unit palette named every u* unit "UEF" (first letter) and everything else "Other"
    Check('faction by category', Units.FactionOf('xyz0001', { Categories = { 'LAND', 'CYBRAN' } }) == 'Cybran')
    Check('faction UEF category beats the id', Units.FactionOf('url0001', { Categories = { 'UEF' } }) == 'UEF')
    Check('faction fallback uel', Units.FactionOf('uel0106', { Categories = {} }) == 'UEF')
    Check('faction fallback ual', Units.FactionOf('ual0106', { Categories = {} }) == 'Aeon')
    Check('faction fallback url', Units.FactionOf('url0106', { Categories = {} }) == 'Cybran')
    Check('faction fallback xsl', Units.FactionOf('xsl0106', { Categories = {} }) == 'Seraphim')
    Check('faction fallback none', Units.FactionOf('zzz0001', { Categories = {} }) == 'Other')
    local aeon = 0
    for _, e in Units.Catalog() do
        if e.id == 'ual0106' then aeon = aeon + 1 Check('catalog ual0106 is Aeon', e.faction == 'Aeon') end
        if e.id == 'uel0106' then Check('catalog uel0106 is UEF', e.faction == 'UEF') end
        if e.id == 'url0106' then Check('catalog url0106 is Cybran', e.faction == 'Cybran') end
    end
    Check('catalog has ual0106', aeon == 1)

    -- File > Open / New silently dropped unsaved work: Maps.Dirty() is what the guard dialog asks
    local was = Maps.Dirty()
    Maps.MarkClean()
    Check('clean after MarkClean', not Maps.Dirty())
    History.Push({ label = 'qa', undo = function() end, redo = function() end })
    Check('dirty after an edit', Maps.Dirty())
    History.Undo()
    Check('still dirty after undo (conservative)', Maps.Dirty())
    Maps.MarkClean()
    Check('clean again', not Maps.Dirty())
    History.Redo()
    Check('dirty after redo', Maps.Dirty())
    History.Undo()
    History.Clear()
    if not was then Maps.MarkClean() end

    -- panels did not scroll: what does not fit was hidden. Content group + whole-control culling + clamped offset
    local frame = GetFrame(0)
    local holder = Group(frame)
    holder.Left:Set(0) holder.Top:Set(0) holder.Width:Set(100) holder.Height:Set(100)
    W.scrollMemory['qa-scroll'] = nil
    local content = W.ScrollContent(holder, 'qa-scroll')
    local function Box(y, h)
        local b = Bitmap(content)
        W.Place(b, content, 4, y, 40, h)
        return b
    end
    local near, far, edge = Box(10, 20), Box(200, 20), Box(90, 20)
    W.EndLayout(content)
    local ctx = content.scroll
    local pad = Skin.S(8)
    Check('scroll: content height is the lowest edge', ctx.extent == 220)
    Check('scroll: range = content + pad - panel', ctx.maxOff == 220 + pad - 100)
    Check('scroll: control inside is placed', near.Top() == 10)
    Check('scroll: control below is off screen', far.Top() == -20000)
    Check('scroll: control across the edge is off screen', edge.Top() == -20000)
    ctx:Scroll(40)
    Check('scroll: offset applied', ctx.off == 40 and near.Top() == -20000 and edge.Top() == 50)
    ctx:Scroll(100000)
    Check('scroll: offset clamped to the range', ctx.off == ctx.maxOff and far.Top() == 200 - ctx.maxOff)
    Check('scroll: position remembered per panel id', W.scrollMemory['qa-scroll'] == ctx.maxOff)
    ctx:Scroll(-100000)
    Check('scroll: offset clamped at the top', ctx.off == 0 and near.Top() == 10)
    -- a rebuild measures the content anew; an offset beyond the new range is pulled back
    ctx:Scroll(60)
    W.BeginLayout(content)
    Box(20, 30)
    W.EndLayout(content)
    Check('scroll: a panel that now fits does not scroll', ctx.maxOff == 0 and ctx.off == 0)
    -- a panel that overshoots by a few pixels (a list that ends at the padding) does not scroll
    W.BeginLayout(content)
    Box(90, 15)
    W.EndLayout(content)
    Check('scroll: small overshoot is not scrollable', ctx.maxOff == 0)
    -- a slider is culled as one piece
    W.BeginLayout(content)
    local sl = W.Slider(content, { label = 'qa', min = 0, max = 10, step = 1, get = function() return 5 end, set = function() end })
    sl:Place(4, 70, 90)
    ctx:Update()
    Check('scroll: slider parts leave together', sl.label.Top() == -20000 and sl.field.frame.Top() == -20000 and sl.track.Top() == -20000)
    W.ScrollRelease(content)
    holder:Destroy()
    W.scrollMemory['qa-scroll'] = nil

    -- no box select for props / decals / units: SelectBox takes what lies in a world rectangle, additive keeps the rest
    local Props = import('/lua/editor/props.lua')
    local Map = import('/lua/editor/map.lua')
    local before = ed_prop_count()
    local bp = '/env/Aeon/Props/Aeon_Car_02_prop.bp'
    Props.ClearSelection()
    local ia = Map.AddProp(bp, 40, 25, 40, 0, 1)
    local ib = Map.AddProp(bp, 44, 25, 44, 0, 1)
    local ic = Map.AddProp(bp, 60, 25, 60, 0, 1)
    Props.SelectBox({ 38, 38, 46, 46 }, false)
    Check('box select: props inside the box', table.getn(Props.Selection) == 2)
    Props.SelectBox({ 58, 58, 62, 62 }, true)
    Check('box select: additive keeps the old selection', table.getn(Props.Selection) == 3)
    Props.SelectBox({ 46, 46, 38, 38 }, false)
    Check('box select: a box dragged backwards and not additive replaces', table.getn(Props.Selection) == 2)
    Props.SelectBox(nil, false)
    Check('box select: a click on empty ground clears', table.getn(Props.Selection) == 0)
    Props.SelectBox({ 38, 38, 46, 46 }, false)
    Props.SelectBox(nil, true)
    Check('box select: a shift click on empty ground keeps the selection', table.getn(Props.Selection) == 2)
    Props.ClearSelection()
    for i = ed_prop_count(), before + 1, -1 do Map.RemoveProp(i) end
    Check('box select: test props removed', ed_prop_count() == before)

    -- the gizmo / group drag moves objects live and commits one undo entry (tools.NewLiveMove)
    do
        local Tools = import('/lua/editor/tools.lua')
        local Map = import('/lua/editor/map.lua')
        local m = Map.Doc and Map.Doc.save.MasterChain['_MASTERCHAIN_'].Markers.ARMY_1
        if m then
            Tools.Select('marker', 'ARMY_1')
            local x0, z0 = m.position[1], m.position[3]
            local u0 = History.Depth()
            local live = Tools.NewLiveMove()
            live.Move(10, 5)
            Check('live move applied at once', math.abs(m.position[1] - (x0 + 10)) < 0.6 and math.abs(m.position[3] - (z0 + 5)) < 0.6)
            live.Move(20, 0)
            Check('live move is absolute, not cumulative', math.abs(m.position[1] - (x0 + 20)) < 0.6 and math.abs(m.position[3] - z0) < 0.6)
            live.Cancel()
            Check('cancel restores', math.abs(m.position[1] - x0) < 0.01 and math.abs(m.position[3] - z0) < 0.01)
            Check('cancel pushes nothing', History.Depth() == u0)
            live = Tools.NewLiveMove()
            live.Move(30, 0)
            live.Move(12, 8)
            Check('commit pushes one entry', live.Commit() and History.Depth() == u0 + 1)
            History.Undo()
            Check('undo restores the start', math.abs(m.position[1] - x0) < 0.01 and math.abs(m.position[3] - z0) < 0.01)
            History.Clear()
            Tools.Select(false)
        end
        Check('pixel size follows the camera only', import('/lua/editor/viewscale.lua').PixelSize() > 0)
    end

    -- a tool the showing workspace does not offer is deselected and can never act
    do
        local UI = import('/lua/editor/ui.lua')
        local ws0, tool0 = UI.State.workspace, UI.State.tool
        UI.SetWorkspace('Terrain')
        UI.State.tool = 'raise'
        Check('raise acts in Terrain', UI.ActiveTool() and UI.ActiveTool().id == 'raise')
        UI.SetWorkspace('Objects')
        Check('workspace switch deselects the brush', UI.State.tool == 'select')
        UI.State.tool = 'raise'        -- as if something left it behind
        Check('a foreign tool has no active tool', UI.ActiveTool() == nil)
        Check('a foreign click is dropped', UI.OnWorldPress({ MouseX = 100, MouseY = 100 }) == false)
        Check('and the default tool is back', UI.State.tool == 'select' and UI.ActiveTool() ~= nil)
        UI.SetWorkspace('Environment')
        Check('Environment offers no brush: camera', UI.State.tool == 'camera')
        UI.SetWorkspace('Review')
        Check('Review keeps an allowed tool (camera)', UI.ActiveTool() ~= nil)
        UI.SetWorkspace(ws0 or 'Objects')
        if tool0 then UI.State.tool = tool0 end
        UI.EnforceTool()
    end

    -- context menus: every item is wired, and the ones that act do what they say
    do
        local Menu = import('/lua/editor/gui/menu.lua')
        import('/lua/editor/gui/menus.lua')
        local Tools = import('/lua/editor/tools.lua')
        local Units = import('/lua/editor/units.lua')
        local Camera = import('/lua/editor/camera.lua')
        local Clipboard = import('/lua/editor/clipboard.lua')
        local Map = import('/lua/editor/map.lua')
        local UI = import('/lua/editor/ui.lua')
        local ws0 = UI.State.workspace
        UI.SetWorkspace('Objects')
        History.Clear()
        local function Wired(menu, what)
            for _, it in menu do
                if not (it.run or it.command or it.submenu or it.header or it.separator) then Check(what .. ': item without an action: ' .. tostring(it.title), false) end
            end
        end
        local function Find(menu, prefix)
            for _, it in menu do
                local t = it.title
                if type(t) == 'function' then t = t() end
                if t and string.sub(t, 1, string.len(prefix)) == prefix then return it end
            end
            return nil
        end
        local function Count() local n = 0 for _ in Map.Doc.save.MasterChain['_MASTERCHAIN_'].Markers do n = n + 1 end return n end

        -- earlier self tests leave selections behind (units, props): the focus checks average over everything selected
        Tools.Select(false) Units.ClearSelection() import('/lua/editor/props.lua').ClearSelection() import('/lua/editor/decals.lua').ClearSelection()
        local name = Tools.PlaceMarker(170, 170, 'Mass')
        local n0 = Count()
        local base = History.Depth()      -- the placement itself is the first entry
        local ctx = { wx = 170, wz = 170, height = 25, hit = { kind = 'marker', name = name } }
        local menu = Menu.Build('context.world', ctx)
        Wired(menu, 'marker')
        local focus = Find(menu, 'Focus camera on ' .. name)
        Check('marker menu has Focus camera on <marker>', focus ~= nil)
        if focus then
            Camera.FocusOn(60, 60)
            focus.run()
            local fx, fz = Camera.SelectionCenter()
            Check('focus on a marker selects it', fx and math.abs(fx - 170) < 1.5 and math.abs(fz - 170) < 1.5)
        end
        local dup = Find(menu, 'Duplicate')
        Check('marker menu has Duplicate', dup ~= nil)
        if dup then dup.run() Check('duplicate adds a marker', Count() == n0 + 1) end
        local del = Find(menu, 'Delete ' .. name)
        if del then del.run() end
        Check('delete removes the marker', Map.Doc.save.MasterChain['_MASTERCHAIN_'].Markers[name] == nil)
        while History.Depth() > base do History.Undo() end
        Check('undo brings the marker back', Map.Doc.save.MasterChain['_MASTERCHAIN_'].Markers[name] ~= nil and Count() == n0)

        -- an area under the pointer
        local area = Tools.NewArea(10, 10, 30, 30)
        local amenu = Menu.Build('context.world', { wx = 20, wz = 20, height = 25, hit = { kind = 'area', name = area } })
        Wired(amenu, 'area')
        local af = Find(amenu, 'Focus camera on ' .. tostring(area))
        Check('area menu has Focus camera', af ~= nil)
        if af then
            Camera.FocusOn(200, 200)
            af.run()
            local ax, az = Camera.SelectionCenter()
            Check('focus on an area uses its middle', ax and math.abs(ax - 20) < 1.5 and math.abs(az - 20) < 1.5)
        end

        -- a unit
        Units.Active = 'uel0106'
        Units.ArmyName = 'ARMY_1'
        Units.Place(60, 90)
        local unit
        for _, u in Units.All() do if u.x > 59 and u.x < 61 and u.z > 89 and u.z < 91 then unit = u end end
        Check('a unit was placed', unit ~= nil)
        if unit then
            local umenu = Menu.Build('context.world', { wx = 60, wz = 90, height = 25, unit = unit })
            Wired(umenu, 'unit')
            Check('unit menu: set army and move to group', Find(umenu, 'Set army') ~= nil and Find(umenu, 'Move to group') ~= nil)
            local before = table.getn(Units.All())
            local ud = Find(umenu, 'Delete')
            if ud then ud.run() end
            Check('unit delete removes it', table.getn(Units.All()) == before - 1)
            History.Undo()
            Check('and undo restores it', table.getn(Units.All()) == before)
        end

        -- the world menu: paste follows the clipboard
        local wmenu = Menu.Build('context.world', { wx = 100, wz = 100, height = 25 })
        Wired(wmenu, 'world')
        Check('world menu has Focus camera here', Find(wmenu, 'Focus camera here') ~= nil)
        Check('world menu has Place here (Objects)', Find(wmenu, 'Place ') ~= nil and Find(wmenu, 'Add start position here') ~= nil)
        Tools.Select('marker', name)
        Clipboard.Copy()
        wmenu = Menu.Build('context.world', { wx = 100, wz = 100, height = 25 })
        local paste = Find(wmenu, 'Paste here')
        Check('paste here is offered', paste ~= nil)
        if paste then
            local n1 = Count()
            paste.run()
            Check('paste here puts the marker at the pointer', Count() == n1 + 1)
        end
        while History.Depth() > 0 do History.Undo() end
        History.Clear()
        Tools.Select(false)
        UI.SetWorkspace(ws0 or 'Objects')
    end

    -- the world view must never follow a parked viewport holder off screen (the D3D device failed for good: black editor)
    do
        local Shell = import('/lua/editor/gui/shell.lua')
        local ws0 = Shell.S.current
        Shell.ShowWorkspace('Generate')
        Shell.S.main:ShowPanel('console')          -- the console tab sits in the stack of the viewport
        local view = import('/lua/ui/game/worldview.lua').viewLeft
        Check('world view stays on screen while its tab is hidden', view and view.Left() > -5000 and view.Top() > -5000)
        Shell.S.main:ShowPanel('viewport')
        Check('and follows the viewport again', view and view.Left() > -5000 and view.Width() > 50)
        Shell.ShowWorkspace(ws0 or 'Objects')
    end

    -- the mission compiler never produces a script that does not load
    do
        local M = import('/lua/editor/mission.lua')
        local saved = M.Data
        local function Loads(text) local ok, f = pcall(loadstring, text) return ok and f ~= nil end
        M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
        M.AddStage('S')
        M.AddNode(1, 'ready', 'obj_kill')                       -- no variable chosen yet
        Check('an unset variable still compiles', Loads(M.Compile(true)))
        local found = false
        for _, p in M.Check() do if string.find(p.text, 'variable chosen', 1, true) then found = true end end
        Check('and Check names it', found)
        M.RemoveNode(1, 'ready', 1)
        M.AddNode(1, 'ready', 'restrict')
        M.SetParam(1, 'ready', 1, 'army', 'ARMY_1')
        M.SetParam(1, 'ready', 1, 'categories', 'categories.TECH3 and "broken')
        Check('a broken category expression falls back and still compiles', Loads(M.Compile(true)))
        found = false
        for _, p in M.Check() do if string.find(p.text, 'not a Lua expression', 1, true) then found = true end end
        Check('and Check names the expression', found)
        M.RemoveNode(1, 'ready', 1)
        M.AddNode(1, 'ready', 'raw')
        M.SetParam(1, 'ready', 1, 'code', 'this is not lua')
        local patched, how = M.PatchScript('function OnPopulate() end\nfunction OnStart(self) end\n')
        Check('a Raw Lua syntax error is written as a stub that loads', Loads(patched) and how == 'written' and string.find(patched, 'MISSION_ERROR', 1, true) ~= nil)
        M.Data = saved
    end

    -- the status line message API other modules call (ui.lua's Say was a local: all 40 callers did nothing or raised)
    do
        local UI = import('/lua/editor/ui.lua')
        Check('ui.lua exports Say', type(UI.Say) == 'function')
        local before = UI.State.message
        UI.Say('qa message')
        Check('Say sets the status message', UI.State.message == 'qa message')
        UI.State.message = before
    end

    -- the DEFAULT key bindings: every key text parses and no key belongs to two commands (a read-only check: the user's saved bindings are not touched)
    do
        local Cmd = import('/lua/editor/gui/commands.lua')
        local HK = import('/lua/editor/gui/hotkeys.lua')
        local seen = {}
        for _, id in Cmd.order do
            local def = Cmd.registry[id]
            for _, k in { def.defKeys or def.keys or '', def.defKeys2 or def.keys2 or '' } do
                if k ~= '' then
                    local ok, c = pcall(HK.Canonical, k)
                    Check('key text parses: ' .. id .. ' ' .. k, ok and c ~= '')
                    if ok and c ~= '' then
                        Check('key ' .. c .. ' is bound twice (' .. tostring(seen[c]) .. ', ' .. id .. ')', seen[c] == nil or seen[c] == id)
                        seen[c] = id
                    end
                end
            end
        end
    end

    if table.getn(failures) == 0 then return 'PASS qa' end
    return 'FAIL ' .. table.concat(failures, '; ')
end
