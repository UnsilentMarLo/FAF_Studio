-- GUI shell: top bar (workspace tabs, palette, UI scale), the dock area of the main window, the status bar and the pop-out windows.
--
--   import('/lua/editor/gui/shell.lua').Start('Terrain')     build the shell in the main window (also ShowWorkspace / SetScale)
--
-- Pop-outs: a tab dragged out of the dock area becomes its own window (design B, ed_window_*) holding a dock host of its own; closing
-- that window docks its panels back into the main window. The shell polls ed_window_poll_event() every frame.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Skin = import('/lua/editor/gui/skin.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Dock = import('/lua/editor/gui/dock.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Workspace = import('/lua/editor/gui/workspace.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Model = import('/lua/editor/gui/model.lua')
local Keys = import('/lua/editor/gui/keys.lua')
local Camera = import('/lua/editor/camera.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local UserData = import('/lua/editor/userdata.lua')
import('/lua/editor/gui/menus.lua')
local Perf = import('/lua/editor/perf.lua')
pcall(function() import('/lua/editor/consolelog.lua').Install() end)      -- the Console panel records LOG, WARN, SPEW and print (once per process)
-- Every gui/panels_*.lua registers its panels when imported: a new panel file needs no edit here (builtin first, the rest by file name).
-- A panel module may define a module-level Refresh(), which the tick below calls about four times a second (set NoAutoRefresh = true to opt out).
PanelModules = {}
PanelNames = {}       -- parallel to PanelModules: the file of each module (the timing report names the panel that costs)
do
    local files = {}
    for _, file in DiskFindFiles('/lua/editor/gui', 'panels_*.lua') do table.insert(files, string.lower(file)) end
    table.sort(files)
    table.insert(files, 1, '/lua/editor/gui/panels_builtin.lua')
    local seen = {}
    for _, file in files do
        if not seen[file] then
            seen[file] = true
            local mod = import(file)
            if mod then
                table.insert(PanelModules, mod)
                PanelNames[table.getn(PanelModules)] = file
            end
        end
    end
    -- gui/feature_*.lua register their own commands and menu items when imported (a feature that is not a panel: release, recent maps, ...)
    -- (a feature module may define a module-level Refresh() too: it is ticked like a panel module's)
    for _, file in DiskFindFiles('/lua/editor/gui', 'feature_*.lua') do
        local mod = import(string.lower(file))
        if mod then
            table.insert(PanelModules, mod)
            PanelNames[table.getn(PanelModules)] = string.lower(file)
        end
    end
end
local Hotkeys = import('/lua/editor/gui/hotkeys.lua')

S = {
    layouts = {},
    started = false, current = 'Terrain', main = nil, popouts = {}, tabButtons = {}, bar = nil, status = nil, statusText = nil,
    frameW = 0, frameH = 0, editor = false, playBar = false, sinceRefresh = 0,
}

local function Frame() return GetFrame(0) end

local function BarHeight()
    return Skin.S(Skin.size.menuBar) + Skin.S(Skin.size.topBar)
end

local function MainRect(frame)
    local top, bottom = BarHeight(), Skin.S(Skin.size.status)
    return 0, top, frame.Width(), frame.Height() - top - bottom
end

function Say(text)
    S.message = text
    if S.statusText then S.statusText:SetText(text) end
end

-- ---- layout capture / restore -------------------------------------------------------------------------------------------------

--- Marks the arrangement as changed: the tick writes it to the user folder a moment later (a panel moved, a splitter dragged, a window opened or closed).
function LayoutChanged()
    S.layoutDirty = true
end

function CaptureLayout()
    local layout = { tree = S.main.tree, popouts = {} }
    for id, p in S.popouts do
        local x, y, w, h = ed_window_get_rect(id)
        layout.popouts[table.getn(layout.popouts) + 1] = { tree = p.host.tree, x = x, y = y, w = w, h = h }
    end
    return layout
end

--- Moves a saved pop-out rectangle onto a monitor that exists now (a laptop that lost its second screen, a changed resolution): the window keeps its place when its
--- title bar lies on some monitor, otherwise it comes back onto the main window's monitor.
local function OnScreen(x, y, w, h)
    local n = ed_monitor_count and ed_monitor_count() or 0
    if n == 0 then return x, y, w, h end
    local cx, cy = x + math.floor(w / 2), y + 12
    local fallback
    for i = 1, n do
        local mx, my, mw, mh, wx, wy, ww, wh, primary = ed_monitor_info(i)
        if wx then
            if not fallback or primary == 1 or primary == true then fallback = { wx, wy, ww, wh } end
            if cx >= wx and cx < wx + ww and cy >= wy and cy < wy + wh then
                -- on this monitor: keep it, but not larger than the work area
                return x, y, math.min(w, ww), math.min(h, wh)
            end
        end
    end
    local wx, wy, ww, wh = fallback[1], fallback[2], fallback[3], fallback[4]
    w, h = math.min(w, ww), math.min(h, wh)
    return wx + math.floor((ww - w) / 2), wy + math.floor((wh - h) / 2), w, h
end

local function CloseAllPopouts()
    for id, p in S.popouts do
        p.host:Destroy()
        ed_window_destroy(id)
    end
    S.popouts = {}
end

local function PopoutContext(id)
    return {
        OnDragOut = function(panelId, mx, my, host) end,
    }
end

--- Turns a panel into its own window. (sx, sy) = where the tab was released, in frame coordinates of `fromHost`.
function Detach(panelId, sx, sy, fromHost, rect)
    local ox, oy = 0, 0
    if fromHost == S.main then
        local cx, cy = ed_main_window_rect()
        ox, oy = cx, cy
    else
        for id, p in S.popouts do
            if p.host == fromHost then
                local x, y, w, h, cw, ch = ed_window_get_rect(id)
                ox, oy = x + math.floor((w - cw) / 2), y + (h - ch) - math.floor((w - cw) / 2)
            end
        end
    end
    local x, y, w, h = ox + sx - 60, oy + sy - 12, Skin.S(480), Skin.S(340)
    if rect then x, y, w, h = rect[1], rect[2], rect[3], rect[4] end
    local id, err = ed_window_create(x, y, w, h, Panels.Title(panelId))
    if not id then
        Say('could not open a window: ' .. tostring(err))
        return nil
    end
    ed_window_set_defer_close(id, true)
    local frame = GetFrame(id)
    local host = Dock.NewHost(frame, {
        OnDragOut = function(pid, mx, my, from) Detach(pid, mx, my, from) end,
        OnChange = function() ed_window_invalidate(id) LayoutChanged() end,
    })
    S.popouts[id] = { host = host }
    LayoutChanged()
    host:SetTree({ kind = 'stack', tabs = { panelId }, active = 1 })
    host:SetRect(0, 0, frame.Width(), frame.Height())
    if fromHost then
        fromHost:Remove(panelId)
        if fromHost ~= S.main and table.getn(fromHost:Panels()) == 0 then CloseWindow(fromHost) end
    end
    ed_window_invalidate(id)
    Say('detached ' .. Panels.Title(panelId))
    return id
end

--- Closes a pop-out window and docks its panels back into the main window.
function CloseWindow(host)
    for id, p in S.popouts do
        if p.host == host then
            local panels = host:Panels()
            S.popouts[id] = nil
            LayoutChanged()
            host:Destroy()
            ed_window_destroy(id)
            -- during a test run the editor's main window stays hidden: the panels go back to it when the run ends (OnMode)
            local ok, mode = pcall(function() return import('/lua/editor/ui.lua').State.mode end)
            if ok and mode == 'play' then
                S.pendingDock = S.pendingDock or {}
                for _, panelId in panels do
                    local def = Panels.Get(panelId)
                    if not (def and def.windowOnly) then table.insert(S.pendingDock, panelId) end
                end
            else
                for _, panelId in panels do
                    -- a panel that only lives in a window (Settings) is closed with it, not docked into the main window
                    local def = Panels.Get(panelId)
                    if not (def and def.windowOnly) then S.main:AddPanel(panelId) end
                end
            end
            return
        end
    end
end

-- ---- top bar and status -------------------------------------------------------------------------------------------------------

--- One menu of the menu bar opens under its title; with a menu open, moving over another title switches to it.
local function OpenMenuBarMenu(frame, name, title)
    Menu.Close()
    S.openTitle = name
    local items = Menu.Build('menubar.' .. name, {})
    if title then title:SetSolidColor(Skin.color.buttonHi) end
    Menu.Show(frame, title.Left(), Skin.S(Skin.size.menuBar), items, {
        shadeTop = Skin.S(Skin.size.menuBar),
        onClose = function()
            S.openTitle = false
            if title then title:SetSolidColor(Skin.color.window) end
        end,
    })
end

local function BuildBar(frame)
    local c = Skin.color
    Menu.Close()
    if S.bar then S.bar:Destroy() end
    local fw = frame.Width()
    local bar = Group(frame)
    bar.panelId = 'shell'               -- (the scope of the tooltip texts of the top bar's buttons, tooltips.lua)
    bar.Depth:Set(5100)
    bar.Left:Set(0) bar.Top:Set(0) bar.Width:Set(fw) bar.Height:Set(BarHeight())
    S.bar = bar
    local bg = Bitmap(bar)
    bg.Depth:Set(function() return bar.Depth() + 1 end)
    bg:SetSolidColor(c.window)
    bg.Left:Set(function() return bar.Left() end) bg.Top:Set(function() return bar.Top() end)
    bg.Right:Set(function() return bar.Right() end) bg.Bottom:Set(function() return bar.Bottom() end)

    -- row 1: the menu bar
    local mh = Skin.S(Skin.size.menuBar)
    local mx = Skin.S(4)
    S.openTitle = false
    for _, name in Menu.Titles do
        local n = name
        local tw = Skin.S(24)
        local probe = W.Label(bar, n, 0, 0, {})
        tw = tw + probe.Width()
        probe:Destroy()
        local title = Bitmap(bar)
        title.Depth:Set(function() return bar.Depth() + 3 end)
        title:SetSolidColor(c.window)
        W.Place(title, bar, mx, 0, tw, mh)
        local label = W.Label(title, n, 0, 0, { color = c.text })
        label.Left:Set(function() return title.Left() + math.floor((tw - label.Width()) / 2) end)
        label.Top:Set(function() return title.Top() + math.floor((mh - label.Height()) / 2) end)
        title.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                if Menu.IsOpen() and S.openTitle ~= n then
                    OpenMenuBarMenu(frame, n, self)
                elseif not Menu.IsOpen() then
                    self:SetSolidColor(c.hover)
                end
                return true
            elseif event.Type == 'MouseExit' then
                if S.openTitle ~= n then self:SetSolidColor(c.window) end
                return true
            elseif event.Type == 'ButtonPress' then
                if S.openTitle == n then Menu.Close() else OpenMenuBarMenu(frame, n, self) end
                return true
            end
            return false
        end
        mx = mx + tw
    end

    -- row 2: workspaces and view toggles, UI scale on the right
    local y2 = mh + Skin.S(3)
    local x, bh = Skin.S(6), Skin.S(Skin.size.topBar) - Skin.S(6)
    S.tabButtons = {}
    for i, name in Workspace.Presets() do
        local n, slot = name, i       -- (closures share the loop variable)
        local b = W.Button(bar, n, x, y2, Skin.S(84), bh, function() ShowWorkspace(n) end, { tip = function()
            local t = import('/lua/editor/tooltips.lua').ForWorkspace(n)
            return t and (t .. '  (Alt+' .. tostring(slot) .. ')') or nil
        end })
        b:SetOn(n == S.current)
        S.tabButtons[n] = b
        x = x + Skin.S(88)
    end
    x = x + Skin.S(12)
    local grid = import('/lua/editor/grid.lua')
    local gridButton = W.Button(bar, 'Grid', x, y2, Skin.S(54), bh, function() Commands.Run('view.grid') end, { toggle = true, cmd = 'view.grid' })
    gridButton:SetOn(grid.Visible)
    S.gridButton = gridButton
    x = x + Skin.S(62)
    local slopeButton = W.Button(bar, 'Slope', x, y2, Skin.S(54), bh, function() Commands.Run('view.slope') end, { toggle = true, cmd = 'view.slope' })
    slopeButton:SetOn(import('/lua/editor/slope.lua').Visible)
    S.slopeButton = slopeButton
    local slopeRight = x + Skin.S(54)
    local rx = fw - Skin.S(6) - Skin.S(30)
    W.Button(bar, '+', rx, y2, Skin.S(30), bh, function() SetScale(Skin.scale + 0.25) end, { cmd = 'ui.scale.up', tip = 'Make the interface larger.' })
    rx = rx - Skin.S(34)
    W.Button(bar, '-', rx, y2, Skin.S(30), bh, function() SetScale(Skin.scale - 0.25) end, { cmd = 'ui.scale.down', tip = 'Make the interface smaller.' })
    rx = rx - Skin.S(54)
    -- the scale readout only where it does not run over the Slope button (at 150 % the workspace tabs leave no room for it)
    if rx > slopeRight + Skin.S(8) then
        W.Label(bar, string.format('UI %d%%', math.floor(Skin.scale * 100 + 0.5)), rx, y2 + Skin.S(4), { color = c.textDim })
    end

    if S.status then S.status:Destroy() end
    local st = Group(frame)
    st.Depth:Set(5100)
    local sh = Skin.S(Skin.size.status)
    st.Left:Set(0) st.Top:Set(frame.Height() - sh) st.Width:Set(fw) st.Height:Set(sh)
    S.status = st
    local sbg = Bitmap(st)
    sbg.Depth:Set(function() return st.Depth() + 1 end)
    sbg:SetSolidColor(c.window)
    sbg.Left:Set(function() return st.Left() end) sbg.Top:Set(function() return st.Top() end)
    sbg.Right:Set(function() return st.Right() end) sbg.Bottom:Set(function() return st.Bottom() end)
    S.statusText = W.Label(st, S.message or 'ready', Skin.S(8), Skin.S(3), { color = c.textDim, size = 'small' })
end

-- ---- workspaces, scale, per-frame tick ---------------------------------------------------------------------------------------------

--- Writes the arrangement of the showing workspace to the user folder (when it changed).
local function SaveKept()
    if not (S.main and S.main.tree and S.current) then return end
    S.layoutDirty = false
    local ok, err = pcall(function() Workspace.SaveKept(S.current, CaptureLayout()) end)
    if not ok then LOG('EDITOR gui: layout not saved: ' .. tostring(err)) end
end

function ShowWorkspace(name, layout)
    local frame = Frame()
    if S.layoutDirty then SaveKept() end        -- the arrangement belongs to the workspace being left
    -- what the user arranged in the workspace being left comes back when they return to it
    if S.main and S.main.tree and S.current and not layout then
        S.layouts[S.current] = CaptureLayout()
    end
    S.current = name
    pcall(function() import('/lua/editor/unitview.lua').OnWorkspace(name) end)        -- the unit viewer's stage is for the Mod workspace
    CloseAllPopouts()
    layout = layout or S.layouts[name] or Workspace.LoadKept(name) or Workspace.Fresh(name)
    S.layouts[name] = nil
    UserData.Set('workspace', name)
    local x, y, w, h = MainRect(frame)
    if not S.main then
        S.main = Dock.NewHost(frame, {
            OnDragOut = function(pid, mx, my, host) Detach(pid, mx, my, host) end,
            OnChange = function() LayoutChanged() end,
        })
    end
    S.main:SetRect(x, y, w, h)
    -- the workspace's tools first: its panels (tool list, properties) are built for them
    if S.editor then pcall(function() import('/lua/editor/ui.lua').SetWorkspace(name) end) end
    for id, _ in S.main.instances do S.main:DropInstance(id) end   -- fresh controls: a new scale or workspace must not reuse old ones
    S.main:SetTree(layout.tree)
    -- panels that only live in a window (Settings) are not part of the docked layout, whatever an earlier version kept
    for _, panelId in S.main:Panels() do
        local def = Panels.Get(panelId)
        if def and def.windowOnly then pcall(function() S.main:Remove(panelId) end) end
    end
    for _, p in layout.popouts or {} do
        local panels = {}
        local function Collect(n)
            if n.kind == 'stack' then for _, id in n.tabs do panels[table.getn(panels) + 1] = id end else Collect(n.a) Collect(n.b) end
        end
        Collect(p.tree)
        local px, py, pw, ph = OnScreen(p.x, p.y, p.w, p.h)
        local id = Detach(panels[1], 0, 0, nil, { px, py, pw, ph })
        if id then S.popouts[id].host:SetTree(p.tree) S.popouts[id].host:SetRect(0, 0, GetFrame(id).Width(), GetFrame(id).Height()) end
    end
    BuildBar(frame)
    for n, b in S.tabButtons do b:SetOn(n == name) end
    Say('workspace ' .. name)
    S.layoutDirty = false        -- what was just built (a preset, or the kept arrangement) is not a change
end

function SetScale(s)
    Skin.SetScale(s)
    UserData.Set('uiScale', Skin.scale)
    W.scrollMemory = {}     -- scroll offsets are pixels of the old scale
    local layout = CaptureLayout()
    ShowWorkspace(S.current, layout)
    Say(string.format('UI scale %d%%', math.floor(Skin.scale * 100 + 0.5)))
end

-- ---- editor integration (ui.lua owns the editor state; the shell only shows it) ------------------------------------------------

local function EditorUI()
    return import('/lua/editor/ui.lua')
end

--- The main host when it has the panel in its dock tree (nil otherwise).
function FindPanelHost(panelId)
    if not S.main then return nil end
    for _, pid in S.main:Panels() do
        if pid == panelId then return S.main end
    end
    return nil
end

--- Is a pop-out window showing the panel `panelId`?
local function PopoutWith(panelId)
    for id, p in S.popouts do
        for _, pid in p.host:Panels() do
            if pid == panelId then return id end
        end
    end
    return nil
end

--- The mission Run panel (stage, objectives, flags, warnings, jump / skip) in a window of its own: the docked shell is hidden during a test run, a pop-out stays.
function OpenRunWindow()
    local open = PopoutWith('run')
    if open then
        -- already open: bring it to the front (it may sit behind the main window of a test run)
        if rawget(_G, 'ed_window_raise') then pcall(ed_window_raise, open) end
        return
    end
    local cx, cy = ed_main_window_rect()
    Detach('run', 0, 0, nil, { cx + 24, cy + 90, Skin.S(480), Skin.S(420) })
    local made = PopoutWith('run')
    if made and rawget(_G, 'ed_window_raise') then pcall(ed_window_raise, made) end
end

--- Shows a panel that is not part of a workspace's preset (Help): where it is when it is docked or in a window already, else in a window of its own beside the main window's
--- upper left corner (w, h logical pixels).
function OpenPanelWindow(id, w, h)
    if FindPanelHost(id) then return S.main:ShowPanel(id) end
    if PopoutWith(id) then return true end
    local cx, cy = ed_main_window_rect()
    local x, y, ww, hh = OnScreen(cx + Skin.S(60), cy + Skin.S(60), Skin.S(w), Skin.S(h))
    Detach(id, 0, 0, nil, { x, y, ww, hh })
    return true
end

local function BuildPlayBar(frame)
    if S.playBar then S.playBar:Destroy() end
    local c = Skin.color
    local w, h = Skin.S(262), Skin.S(34)
    local g = Group(frame)
    g.panelId = 'shell'
    g.Depth:Set(5200)
    g.Left:Set(math.floor((frame.Width() - w) / 2)) g.Top:Set(Skin.S(10)) g.Width:Set(w) g.Height:Set(h)
    local bg = Bitmap(g)
    bg.Depth:Set(function() return g.Depth() + 1 end)
    bg:SetSolidColor(c.window)
    bg.Left:Set(function() return g.Left() end) bg.Top:Set(function() return g.Top() end)
    bg.Right:Set(function() return g.Right() end) bg.Bottom:Set(function() return g.Bottom() end)
    W.Button(g, 'Pause', Skin.S(6), Skin.S(5), Skin.S(86), Skin.S(24), function() EditorUI().PauseToggle() end)
    W.Button(g, 'Stop', Skin.S(98), Skin.S(5), Skin.S(86), Skin.S(24), function() EditorUI().Stop() end)
    W.Button(g, 'Run...', Skin.S(190), Skin.S(5), Skin.S(66), Skin.S(24), function() OpenRunWindow() end)
    g:Hide()
    S.playBar = g
end

--- Builds the top bar and the play bar again (tipcheck.lua records their buttons).
function RebuildBars()
    local frame = GetFrame(0)
    BuildBar(frame)
    BuildPlayBar(frame)
end

--- ui.lua switched between editing and a test run: the shell disappears for the run and a Pause / Stop bar takes its place.
function OnMode(mode)
    local playing = (mode == 'play')
    -- the game's key map in a test run, the editor's own while editing
    local Keys = import('/lua/editor/gui/keys.lua')
    if playing then pcall(Keys.UseGame) else pcall(Keys.Apply, { exclusive = true }) end
    if not playing and S.pendingDock then
        local list = S.pendingDock
        S.pendingDock = false
        for _, panelId in list do pcall(function() S.main:AddPanel(panelId) end) end
    end
    if S.main then
        if playing then S.main.root:Hide() else S.main.root:Show() end
    end
    if S.bar then if playing then S.bar:Hide() else S.bar:Show() end end
    if S.status then if playing then S.status:Hide() else S.status:Show() end end
    for id, p in S.popouts do
        -- a window with the mission Run panel stays: it is how a test run of a mission is steered
        local keep = false
        for _, pid in p.host:Panels() do
            if pid == 'run' then keep = true end
        end
        if playing and not keep then p.host.root:Hide() else p.host.root:Show() end
        ed_window_invalidate(id)
    end
    local builtin = import('/lua/editor/gui/panels_builtin.lua')
    if playing then builtin.ReleaseWorldView(true) else builtin.AttachWorldView() end
    local cursors = import('/lua/editor/cursors.lua')
    if playing then cursors.RestoreGameDefault() else cursors.InstallDefault() end
    if playing then
        BuildPlayBar(Frame())
        S.playBar:Show()
    elseif S.playBar then
        S.playBar:Hide()
    end
end

-- Is the editor in edit mode (not a test run)? The ui module is kept in S: this runs every frame (no import, no closure per frame).
local function IsEditing()
    local ui = S.uiMod
    if not ui then
        ui = EditorUI()
        S.uiMod = ui
    end
    return ui.State.mode == 'edit'
end

-- The panels are refreshed about four times a second by the CLOCK, not by a frame count: with 15 frames the rate followed the frame rate (60 fps = 4 Hz, an unlimited
-- frame rate on a small scene = 60 Hz and every panel's Refresh ran that often).
local REFRESH_SECONDS = 0.25

local function Tick()
    local frame = Frame()
    Perf.Tick()
    local tFrame = Perf.Begin()
    -- (the module is kept in S: no import call per frame)
    local builtin = S.builtinMod
    if not builtin then
        builtin = import('/lua/editor/gui/panels_builtin.lua')
        S.builtinMod = builtin
    end
    builtin.EnsureWorldView()
    if S.editor then
        -- held-key camera movement (only while editing; a test run uses the game's own camera keys)
        local ok, editing = pcall(IsEditing)
        if ok and editing then pcall(Perf.Time, 'shell: camera keys', Camera.Update, Commands) end
        local clock = GetSystemTimeSeconds()
        if clock - (S.lastRefresh or 0) >= REFRESH_SECONDS then
            S.lastRefresh = clock
            local tRefresh = Perf.Begin()
            if ok and editing then pcall(Perf.Time, 'shell: autosave check', function() import('/lua/editor/maps.lua').AutosaveTick() end) end
            -- not during a test run: a refresh shows list rows again (VirtualList:Refresh calls Show), and the hidden editor panels leaked onto the game HUD
            if ok and editing then
                local ok2, text = pcall(Perf.Time, 'shell: status text', function() return EditorUI().StatusText() end)
                if ok2 and S.statusText and text ~= S.statusShown then
                    S.statusShown = text
                    S.statusText:SetText(text)
                end
                local timing = Perf.Enabled
                for i, mod in PanelModules do
                    local refresh = rawget(mod, 'Refresh')
                    if refresh and not rawget(mod, 'NoAutoRefresh') then
                        if timing then pcall(Perf.Time, 'refresh ' .. tostring(PanelNames[i]), refresh) else pcall(refresh) end
                    end
                end
                pcall(Perf.Time, 'shell: scroll tick', W.ScrollTick)
                -- what the user arranged is kept: panel changes mark it, pop-out windows are compared here (moving a window is not a dock event)
                if next(S.popouts) ~= nil then
                    local sig = ''
                    for id, _ in S.popouts do
                        local x, y, w, h = ed_window_get_rect(id)
                        sig = sig .. string.format('%d,%d,%d,%d;', x or 0, y or 0, w or 0, h or 0)
                    end
                    if sig ~= S.popSig then S.popSig = sig S.layoutDirty = true end
                elseif S.popSig ~= '' then
                    S.popSig = ''
                    S.layoutDirty = true
                end
                if S.layoutDirty then SaveKept() end
                pcall(Perf.Time, 'shell: persist', function() import('/lua/editor/persist.lua').Tick() end)
                UserData.Flush()
            end
            Perf.End('shell: 4 Hz refresh (all)', tRefresh)
        end
    end
    Perf.End('shell: tick (all)', tFrame)
    if S.main and (frame.Width() ~= S.frameW or frame.Height() ~= S.frameH) then
        S.frameW, S.frameH = frame.Width(), frame.Height()
        local x, y, w, h = MainRect(frame)
        S.main:SetRect(x, y, w, h)
        BuildBar(frame)
    end
    while true do
        local id, kind, a, b = ed_window_poll_event()
        if not id then break end
        local p = S.popouts[id]
        if p then
            if kind == 'size' then
                p.host:SetRect(0, 0, GetFrame(id).Width(), GetFrame(id).Height())
            elseif kind == 'close' then
                -- the window's X button: dock the panels back and close the window. Whatever goes wrong while docking, the window must still go (an error here used to leave it
                -- standing with the event already consumed, so the X seemed to do nothing).
                local ok, err = pcall(CloseWindow, p.host)
                if ok then
                    Say('panels docked back')
                else
                    LOG('EDITOR gui: closing a pop-out failed: ' .. tostring(err))
                    S.popouts[id] = nil
                    pcall(ed_window_destroy, id)
                    Say('window closed (docking its panels back failed, see the log)')
                end
            end
        end
    end
end

--- Shows a panel of the dock (adds it when the current layout does not have it).
function FocusPanel(id)
    if not S.main then return false end
    return S.main:ShowPanel(id)
end

function IsEditor()
    return S.editor
end

--- Destroys the shell's controls and windows (used before a reload and when switching the GUI off).
function Stop()
    CloseAllPopouts()
    if S.main then S.main:Destroy() S.main = nil end
    if S.bar then S.bar:Destroy() S.bar = nil end
    if S.status then S.status:Destroy() S.status = nil end
    if S.poller then S.poller.OnFrame = function() end S.poller:Destroy() S.poller = nil end
    if S.playBar then S.playBar:Destroy() S.playBar = false end
    if S.editor then
        pcall(function() import('/lua/editor/cursors.lua').RestoreGameDefault() end)
        local ok, ui = pcall(import, '/lua/editor/ui.lua')
        if ok then ui.OnModeChange = false end
        S.editor = false
    end
    Commands.ClosePalette()
    S.started = false
end

function Start(name, opts)
    if S.started then Stop() end
    local frame = Frame()
    if opts and opts.remember then
        -- the arrangement of the last run: UI scale and workspace (the layout itself is read by ShowWorkspace)
        local scale = UserData.Get('uiScale', false)
        if type(scale) ~= 'number' then
            -- first run: follow the Windows display scale the exe passed (EdBootstrap) (the editor is DPI aware, so a 125 % display needs UI 125 % to look as large as before)
            local dpi = tonumber(ed_read_file('editor_dpi.txt') or '')
            if dpi and dpi >= 1 and dpi <= 3 then scale = dpi end
        end
        if type(scale) == 'number' then Skin.SetScale(scale) end
        local last = UserData.Get('workspace', false)
        for _, n in Workspace.Presets() do
            if n == last then name = last end
        end
    end
    S.editor = opts and opts.editor or false
    if S.editor then
        EditorUI().OnModeChange = OnMode
        import('/lua/editor/cursors.lua').InstallDefault()      -- the editor's pointer instead of the game's cursor over the panels
    end
    Model.Init()
    Commands.Register{ id = 'shell.palette', title = 'Open command palette', keys = 'Ctrl+Shift+P', run = function() Commands.OpenPalette(Frame()) end }
    for i, n in Workspace.Presets() do
        local ws = n
        Commands.Register{ id = 'workspace.' .. ws, title = 'Workspace: ' .. ws, keys = 'Alt+' .. i, run = function() ShowWorkspace(ws) end }
    end
    Camera.RegisterCommands(Commands)
    local function ShowOrAdd(id)
        if S.main and not S.main:ShowPanel(id) then S.main:AddPanel(id) end
    end
    Commands.Register{ id = 'file.new', title = 'File: new map...', keys = 'Ctrl+N', run = function() import('/lua/editor/gui/dialogs_map.lua').NewMap() end }
    Commands.Register{ id = 'file.open', title = 'File: open map...', keys = 'Ctrl+O', run = function() import('/lua/editor/gui/dialogs_map.lua').OpenMap() end }
    Commands.Register{ id = 'file.save', title = 'File: save map', keys = 'Ctrl+S', run = function() EditorUI().DoSave() end }
    Commands.Register{ id = 'file.saveas', title = 'File: save map as...', keys = 'Ctrl+Shift+S', run = function() import('/lua/editor/maps.lua').SaveAs() end }
    Commands.Register{ id = 'file.recover', title = 'File: recover autosaved map', run = function() import('/lua/editor/gui/dialogs_map.lua').Guard(function() import('/lua/editor/maps.lua').Recover() end) end }
    Commands.Register{ id = 'terrain.generate', title = 'Terrain: generate...', run = function() import('/lua/editor/gui/dialogs_terrain.lua').Generate() end }
    Commands.Register{ id = 'terrain.playable', title = 'Terrain: playable area...', run = function() import('/lua/editor/gui/dialogs_terrain.lua').PlayableArea() end }
    Commands.Register{ id = 'terrain.flatten', title = 'Terrain: flatten...', run = function() import('/lua/editor/gui/dialogs_terrain.lua').FlattenMap() end }
    Commands.Register{ id = 'file.info', title = 'File: map info...', run = function() import('/lua/editor/gui/dialogs_map.lua').MapInfo() end }
    Commands.Register{ id = 'file.lobbyslots', title = 'File: lobby slots...', run = function() import('/lua/editor/gui/dialogs_map.lua').LobbySlots() end }
    Commands.Register{ id = 'file.play', title = 'File: play test', keys = 'F5', run = function() EditorUI().Play() end }
    Commands.Register{ id = 'file.mods', title = 'File: mods...', run = function() ShowOrAdd('mods') end }
    Commands.Register{ id = 'file.import_height', title = 'File: import heightmap...', run = function() import('/lua/editor/heightio.lua').Import() end }
    Commands.Register{ id = 'file.export_height', title = 'File: export heightmap...', run = function() import('/lua/editor/heightio.lua').Export() end }
    Commands.Register{ id = 'tool.ruler.clear', title = 'Ruler: clear', run = function() import('/lua/editor/ruler.lua').Clear() end }
    Commands.Register{ id = 'view.resetlayout', title = 'View: reset layout of this workspace', run = function() Workspace.ForgetKept(S.current) ShowWorkspace(S.current, Workspace.Fresh(S.current)) end }
    Commands.Register{ id = 'help.hotkeys', title = 'Help: hotkeys...', run = function() ShowOrAdd('hotkeys') end }
    Commands.Register{ id = 'ui.scale.up', title = 'UI scale: larger', run = function() SetScale(Skin.scale + 0.25) end }
    Commands.Register{ id = 'ui.scale.down', title = 'UI scale: smaller', run = function() SetScale(Skin.scale - 0.25) end }
    Commands.Register{ id = 'dev.perf', title = 'Performance timing: on / off (report every 5 s in the Console panel and the log; /perf starts it on)', run = function()
        local on = Perf.Toggle()
        Say('performance timing ' .. (on and 'on' or 'off'))
    end }
    Commands.Register{ id = 'workspace.save', title = 'Workspace: save current layout', run = function() Workspace.Save(S.current, CaptureLayout()) Say('saved layout ' .. S.current) end }
    Commands.Register{ id = 'workspace.load', title = 'Workspace: load saved layout', run = function()
        local layout = Workspace.Load(S.current)
        if layout then ShowWorkspace(S.current, layout) else Say('no saved layout for ' .. S.current) end
    end }
    for _, def in Panels.All() do
        local id = def.id
        if id ~= 'viewport' then
            Commands.Register{ id = 'panel.open.' .. id, title = 'Panel: show ' .. def.title, run = function()
                -- show the panel where it is, or dock it into the main window when it is closed
                if S.main and not S.main:ShowPanel(id) then S.main:AddPanel(id) end
            end }
        end
    end
    if not S.poller then
        S.poller = Bitmap(frame)
        S.poller:SetSolidColor('00000000')
        S.poller.Left:Set(0) S.poller.Top:Set(0) S.poller.Width:Set(1) S.poller.Height:Set(1)   -- all four edges set: an unset pair is a circular LazyVar the engine evaluates every frame
        S.poller:DisableHitTest()
        S.poller:SetNeedsFrameUpdate(true)
        S.poller.OnFrame = function(self, delta) Tick() end
    end
    S.started = true
    S.frameW, S.frameH = frame.Width(), frame.Height()
    Camera.Init()
    if S.editor then
        pcall(function() EditorUI().EnsureDocument() end)     -- markers and areas show from the first frame
        pcall(function() import('/lua/editor/strata.lua').Normalize() end)
    end
    Hotkeys.Load()       -- records the default bindings and applies the saved ones
    Keys.Apply{ exclusive = true }   -- the editor does not inherit the game's hotkeys; bindings come from the command registry
    -- what the previous session had open (control.lua SaveSessionUI): the workspace and the mod project
    local session = {}
    if S.editor then
        local path = import('/lua/editor/control.lua').SessionFile
        local text = ed_read_file(path)
        if text and text ~= '' then
            for key, value in string.gfind(text, '(%w+)=([^\n]*)') do session[key] = value end
            ed_write_file(path, '')
        end
        if session.project and session.project ~= '' then
            pcall(function() import('/lua/editor/bpedit.lua').Open(session.project) end)
        end
    end
    local known = false
    for _, n in Workspace.Presets() do if n == session.workspace then known = true end end
    ShowWorkspace((known and session.workspace) or name or 'Terrain')
    -- a play test of a changed mission reloaded the map: start the run now (ui.lua Play)
    if S.editor and session.autoplay == '1' then
        local ui = EditorUI()
        ui.State.backup = session.backup
        local stage = tonumber(session.stage) or 1
        ForkThread(function()
            WaitSeconds(1.5)
            if stage > 1 then pcall(function() SimCallback({ Func = 'EdMissionStartAt', Args = { stage = stage } }, false) end) end
            ui.SetMode('play')
        end)
    end
    if S.editor then
        pcall(function() import('/lua/editor/persist.lua').Restore() end)
        pcall(function() import('/lua/editor/gui/feature_start.lua').OnStart() end)      -- start screen, notices, tour, queued command
    end
    Model.Log('shell started')
end
