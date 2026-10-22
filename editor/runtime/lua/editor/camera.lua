-- The editor's camera: free movement and rotation, reset only when the user asks for it.
--
-- The game's camera tidies itself up (it reorients, tilts with the zoom, snaps back when a key is released). An editor needs the opposite, so:
--   * the engine's free camera mode is switched on (cam_Free): a rotation stays where the user left it;
--   * every camera movement here is explicit: mouse gestures (drag with a button and modifiers) and held keys, both rebindable in the
--     hotkey manager (gui/hotkeys.lua), and a few one-shot actions (reset, face north, top-down, focus the selection);
--   * nothing resets the camera by itself.
-- IsKeyDown is false while the window is in the background or a text field has the keyboard (engine side), so typing never moves the camera.
-- The wheel zooms to the pointer through the engine, as before. Camera state is read and written with SaveSettings / SnapTo (instant, exact).
--
-- Gestures (data, rebound by the hotkey manager; each is a mouse button plus required modifiers):
--   pan      grab the ground and drag
--   orbit    turn and tilt around the point in the middle of the view
--   orbit2   the same on a second binding
--   zoom     drag up / down to zoom

local Dragger = import('/lua/maui/dragger.lua').Dragger

--- Default gestures. `title` is what the hotkey manager shows.
--- A heading in (-pi, pi]: turning the view past a half turn kept adding to the heading (-3.14 ... -4.71 for east reached by turning left). The real cause of props and units vanishing
--- in that case was in the engine, not here: MeshRenderer::Batch took the LOD depth from the camera's orientation quaternion, which flips its sign by a full turn (fixed in the engine,
--- mesh/MeshLodDepth.h). Keeping the heading in range is still tidier, so it stays.
local TWO_PI = 6.2831853
function NormalizeHeading(h)
    while h > 3.1415927 do h = h - TWO_PI end
    while h <= -3.1415927 do h = h + TWO_PI end
    return h
end

Gestures = {
    pan    = { title = 'Camera: pan (drag)',        button = 'Middle', ctrl = false, alt = false, shift = false },
    orbit  = { title = 'Camera: rotate (drag)',     button = 'Left',   ctrl = false, alt = true,  shift = false },
    orbit2 = { title = 'Camera: rotate, second (drag)', button = 'Right', ctrl = false, alt = false, shift = false },
    zoom   = { title = 'Camera: zoom (drag)',       button = 'Middle', ctrl = true,  alt = false, shift = false },
}
GestureOrder = { 'pan', 'orbit', 'orbit2', 'zoom' }

GestureDefaults = {}
for id, g in Gestures do
    GestureDefaults[id] = { button = g.button, ctrl = g.ctrl, alt = g.alt, shift = g.shift }
end

function ResetGestures()
    for id, d in GestureDefaults do
        local g = Gestures[id]
        g.button, g.ctrl, g.alt, g.shift = d.button, d.ctrl, d.alt, d.shift
    end
end

--- 'Alt + Left drag' etc.
function GestureText(g)
    local parts = {}
    if g.ctrl then table.insert(parts, 'Ctrl') end
    if g.alt then table.insert(parts, 'Alt') end
    if g.shift then table.insert(parts, 'Shift') end
    table.insert(parts, g.button .. ' mouse')
    return table.concat(parts, ' + ') .. ' drag'
end

local ROTATE_PER_PIXEL = 0.006
local MIN_PITCH = 0.12
local MAX_PITCH = 1.5707

local function Cam()
    return GetCamera('WorldCamera')
end

local function Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

--- The view's focus may leave the map a little (looking at the edge from outside) but not fly off: with the engine's own clamp off (cam_Free)
--- a held key at far zoom would take the camera hundreds of kilometres away, where the engine's terrain handling also tilts it.
local EDGE_MARGIN = 0.25

local function ClampToMap(x, z)
    local ok, size = pcall(function() return import('/lua/editor/map.lua').Doc.info.size end)
    if ok and size then
        local mx, mz = size[1] * EDGE_MARGIN, size[2] * EDGE_MARGIN
        return Clamp(x, -mx, size[1] + mx), Clamp(z, -mz, size[2] + mz)
    end
    return x, z
end

-- ---- one-shot actions -----------------------------------------------------------------------------------------------------------------------

--- Back to the engine's default view (only when the user asks).
function Reset()
    Cam():Reset()
end

--- Heading to north (0), pitch and zoom kept.
function North()
    local cam = Cam()
    local s = cam:SaveSettings()
    cam:SnapTo(s.Focus, { 0, s.Pitch, 0 }, s.Zoom)
end

--- Look straight down, heading kept.
function TopDown()
    local cam = Cam()
    local s = cam:SaveSettings()
    cam:SnapTo(s.Focus, { s.Heading, MAX_PITCH, 0 }, s.Zoom)
end

--- Moves the view over a world point (and optionally to a zoom), orientation kept.
function FocusOn(x, z, zoom)
    local cam = Cam()
    local s = cam:SaveSettings()
    local y = ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
    cam:MoveTo(Vector(x, y, z), { s.Heading, s.Pitch, 0 }, zoom or s.Zoom, 0.25)
end

-- ---- bookmarks -------------------------------------------------------------------------------------------------------------------------------

Bookmarks = {}        -- 1..9 -> the camera's SaveSettings table

--- Remembers the view as bookmark n (Ctrl+Shift+n).
function SaveBookmark(n)
    Bookmarks[n] = Cam():SaveSettings()
    pcall(function() import('/lua/editor/ui.lua').Say('camera bookmark ' .. n .. ' saved') end)
end

--- Goes to bookmark n (Ctrl+n); false when it is empty.
function GoBookmark(n)
    local s = Bookmarks[n]
    if not s then
        pcall(function() import('/lua/editor/ui.lua').Say('camera bookmark ' .. n .. ' is empty (Ctrl+Shift+' .. n .. ' saves one)') end)
        return false
    end
    Cam():RestoreSettings(s)
    return true
end

-- ---- mouse gestures --------------------------------------------------------------------------------------------------------------------------

local function ButtonOf(event)
    local m = event.Modifiers
    if not m then return nil end
    if m.Middle then return 'Middle' end
    if m.Right then return 'Right' end
    if m.Left then return 'Left' end
    return nil
end

local function Matches(g, event, button)
    local m = event.Modifiers
    return g.button == button and (m.Ctrl and true or false) == g.ctrl and (m.Alt and true or false) == g.alt and (m.Shift and true or false) == g.shift
end

--- Called with (view, x, y) when a rotate gesture bound to the right button ends without having moved: a right click. The menus module sets it
--- (the viewport's context menu); a right drag still rotates.
OnClick = false

local function StartDrag(event, onMove, onRelease)
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y) onMove(x, y) end
    dragger.OnRelease = function(self, x, y)
        self:Destroy()
        if onRelease then onRelease(x, y) end
    end
    dragger.OnCancel = function(self) self:Destroy() end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
end

local function GroundAt(view, x, y)
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

local function DragPan(view, event)
    local cam = Cam()
    local lastX, lastY = event.MouseX, event.MouseY
    StartDrag(event, function(x, y)
        -- keep the ground point that was under the pointer under the pointer: both points are read with the camera as it is now
        local ax, az = GroundAt(view, lastX, lastY)
        local bx, bz = GroundAt(view, x, y)
        lastX, lastY = x, y
        if ax and bx then
            local s = cam:SaveSettings()
            local f = s.Focus
            local nx, nz = ClampToMap(f[1] + (ax - bx), f[3] + (az - bz))
            cam:SnapTo(Vector(nx, f[2], nz), { s.Heading, s.Pitch, 0 }, s.Zoom)
        end
    end)
end

local CLICK_PIXELS = 4

local function DragOrbit(view, event, clickable)
    local cam = Cam()
    local s = cam:SaveSettings()
    local heading, pitch, focus, zoom = s.Heading, s.Pitch, s.Focus, s.Zoom
    local lastX, lastY = event.MouseX, event.MouseY
    local startX, startY = event.MouseX, event.MouseY
    local moved = false
    StartDrag(event, function(x, y)
        -- a few pixels of hand tremor do not turn a click into a rotation
        if not moved and math.abs(x - startX) + math.abs(y - startY) < CLICK_PIXELS then
            return
        end
        moved = true
        heading = NormalizeHeading(heading - (x - lastX) * ROTATE_PER_PIXEL)
        pitch = Clamp(pitch + (y - lastY) * ROTATE_PER_PIXEL, MIN_PITCH, MAX_PITCH)
        lastX, lastY = x, y
        cam:SnapTo(focus, { heading, pitch, 0 }, zoom)
    end, function(x, y)
        if clickable and not moved and OnClick then
            OnClick(view, startX, startY)
        end
    end)
end

local function DragZoom(event)
    local cam = Cam()
    local lastY = event.MouseY
    StartDrag(event, function(x, y)
        local zoom = Clamp(cam:GetZoom() * math.exp((y - lastY) * 0.01), cam:GetMinZoom(), cam:GetMaxZoom())
        lastY = y
        cam:SetZoom(zoom, 0)
    end)
end

--- Called by the world click hook for every button press while editing. Returns true when a camera gesture took the press.
function OnPress(view, event)
    local button = ButtonOf(event)
    if not button then return false end
    if Matches(Gestures.pan, event, button) then DragPan(view, event) return true end
    if Matches(Gestures.orbit, event, button) or Matches(Gestures.orbit2, event, button) then DragOrbit(view, event, button == 'Right') return true end
    if Matches(Gestures.zoom, event, button) then DragZoom(event) return true end
    return false
end

-- ---- held keys -------------------------------------------------------------------------------------------------------------------------------

-- Held-key commands are polled every frame (smooth, no key repeat delay); they are commands like any other (rebindable, listed in the
-- hotkey manager) flagged `hold = '<what>'` and kept out of the engine key map.
local codeOfName = false

local function CodeOf(name)
    if not codeOfName then
        codeOfName = {}
        for code, key in import('/lua/keymap/keymapper.lua').GetKeyCodeLookup() do
            codeOfName[key] = code
        end
    end
    return codeOfName[name]
end

--- Splits 'Ctrl-Alt-W' (or 'Ctrl+Alt+W') into the key name and modifier flags.
function ParseKeys(keys)
    local mods = { Ctrl = false, Alt = false, Shift = false }
    local names = { ctrl = 'Ctrl', control = 'Ctrl', alt = 'Alt', shift = 'Shift' }
    local key = string.gsub(keys, '%+', '-')
    while true do
        local _, _, head, rest = string.find(key, '^(%a+)%-(.+)$')
        local mod = head and names[string.lower(head)]
        if mod then
            mods[mod] = true
            key = rest
        else
            break
        end
    end
    if string.len(key) == 1 then key = string.upper(key) end    -- the engine spells letter keys in capitals
    return key, mods
end

local function Down(keys)
    if not keys or keys == '' then return false end
    local name, mods = ParseKeys(keys)
    local code = CodeOf(name)
    if not code or not IsKeyDown(code) then return false end
    -- Shift is the speed modifier of movement, a binding may still ask for Ctrl or Alt (virtual key codes 17 and 18)
    return (IsKeyDown(17) and true or false) == mods.Ctrl and (IsKeyDown(18) and true or false) == mods.Alt
end

local lastTime = false

--- Per frame: moves the camera for the held movement keys. `commands` is the command registry (gui/commands.lua).
function Update(commands)
    local now = GetSystemTimeSeconds()
    local dt = lastTime and math.min(0.1, now - lastTime) or 0
    lastTime = now
    if dt <= 0 then return end

    local move = { right = 0, up = 0, turn = 0, tilt = 0, zoom = 0 }
    local any = false
    for _, id in commands.order do
        local def = commands.registry[id]
        if def.hold and (Down(def.keys) or Down(def.keys2)) then
            any = true
            local h = def.hold
            if h == 'pan.right' then move.right = move.right + 1 elseif h == 'pan.left' then move.right = move.right - 1
            elseif h == 'pan.up' then move.up = move.up + 1 elseif h == 'pan.down' then move.up = move.up - 1
            elseif h == 'turn.left' then move.turn = move.turn + 1 elseif h == 'turn.right' then move.turn = move.turn - 1
            elseif h == 'tilt.up' then move.tilt = move.tilt - 1 elseif h == 'tilt.down' then move.tilt = move.tilt + 1
            elseif h == 'zoom.in' then move.zoom = move.zoom - 1 elseif h == 'zoom.out' then move.zoom = move.zoom + 1 end
        end
    end
    if not any then return end

    local cam = Cam()
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    local s = cam:SaveSettings()
    local focus, heading, pitch, zoom = s.Focus, s.Heading, s.Pitch, s.Zoom
    local fast = IsKeyDown(16) and 3 or 1

    if (move.right ~= 0 or move.up ~= 0) and view then
        -- screen directions on the ground, from the camera as it is
        local l, t = view.Left(), view.Top()
        local cx, cz = l + view.Width() / 2, t + view.Height() / 2
        local c0x, c0z = GroundAt(view, cx, cz)
        local rx, rz = GroundAt(view, cx + 100, cz)
        local ux, uz = GroundAt(view, cx, cz - 100)
        if c0x and rx and ux then
            local rl = math.max(0.0001, math.sqrt((rx - c0x) * (rx - c0x) + (rz - c0z) * (rz - c0z)))
            local ul = math.max(0.0001, math.sqrt((ux - c0x) * (ux - c0x) + (uz - c0z) * (uz - c0z)))
            local speed = zoom * 0.9 * dt * fast
            local nx, nz = ClampToMap(focus[1] + ((rx - c0x) / rl * move.right + (ux - c0x) / ul * move.up) * speed,
                                      focus[3] + ((rz - c0z) / rl * move.right + (uz - c0z) / ul * move.up) * speed)
            focus = Vector(nx, focus[2], nz)
        end
    end
    heading = NormalizeHeading(heading + move.turn * 1.6 * dt * fast)
    pitch = Clamp(pitch + move.tilt * 1.2 * dt * fast, MIN_PITCH, MAX_PITCH)
    cam:SnapTo(focus, { heading, pitch, 0 }, zoom)
    if move.zoom ~= 0 then
        cam:SetZoom(Clamp(zoom * math.exp(move.zoom * 1.4 * dt * fast), cam:GetMinZoom(), cam:GetMaxZoom()), 0)
    end
end

--- Switches the engine's free camera mode on (rotation persists, nothing reorients).
function Init()
    ConExecute('cam_Free true')
end

--- The middle of everything selected (markers, areas, units, props, decals): x, z, count (nil without a selection).
function SelectionCenter()
    local Tools = import('/lua/editor/tools.lua')
    local x, z, n = 0, 0, 0
    local mx, mz = Tools.SelectionCenter()
    if mx then
        local count = Tools.SelectionCount()
        x, z, n = mx * count, mz * count, count
    end
    local Units = import('/lua/editor/units.lua')
    if table.getn(Units.Selection) > 0 then
        for _, sel in Units.Selection do
            local u = Units.Lookup(sel.army, sel.name)
            if u then x, z, n = x + u.x, z + u.z, n + 1 end
        end
    end
    for _, list in { import('/lua/editor/props.lua').Selection, import('/lua/editor/decals.lua').Selection } do
        for _, p in list do x, z, n = x + p.x, z + p.z, n + 1 end
    end
    if n == 0 then return nil end
    return x / n, z / n, n
end

--- Moves the view over the current selection, orientation and zoom kept. Returns false when nothing is selected.
function FocusSelection()
    local x, z = SelectionCenter()
    if not x then return false end
    FocusOn(x, z)
    return true
end

-- ---- diagnostics ------------------------------------------------------------------------------------------------------------------------------

--- The numbers mesh LOD and culling are decided from, as text lines (nothing when this engine build has no ed_lod_info). The engine measures a mesh's LOD against `lodRow`: a plane that
--- gives the depth of a point along the view direction, scaled by the field of view and the LOD scale; `depth` of a unit is that plane applied to its position. `entityId` is optional
--- (a unit of the unit viewer or the first selected unit when playing); without it only the camera is reported.
function Diagnostics(entityId)
    local lines = {}
    if not rawget(_G, 'ed_lod_info') then return lines end
    if not entityId then
        local okV, UnitView = pcall(import, '/lua/editor/unitview.lua')
        if okV and UnitView.EntityId then entityId = UnitView.EntityId end
    end
    if not entityId and rawget(_G, 'GetSelectedUnits') then
        local ok, sel = pcall(GetSelectedUnits)
        if ok and sel and sel[1] then
            local okId, id = pcall(function() return sel[1]:GetEntityId() end)
            if okId then entityId = id end
        end
    end
    local ok, i = pcall(ed_lod_info, entityId)
    if not ok or type(i) ~= 'table' then
        table.insert(lines, 'camera: no information (' .. tostring(i) .. ')')
        return lines
    end
    local function F(v, digits) return string.format('%.' .. (digits or 3) .. 'f', v or 0) end
    table.insert(lines, 'camera: heading ' .. F(i.heading) .. ' rad (' .. F(math.mod(i.heading * 57.29578, 360), 1) .. ' deg), pitch ' .. F(i.pitch) .. ', zoom ' .. F(i.zoom, 1)
        .. ', eye distance ' .. F(i.eyeDistance, 1) .. ', fov ' .. F(i.fov) .. ' rad')
    table.insert(lines, 'camera: eye ' .. F(i.eyeX, 1) .. ', ' .. F(i.eyeY, 1) .. ', ' .. F(i.eyeZ, 1) .. ', viewport ' .. F(i.viewportX, 0) .. ',' .. F(i.viewportY, 0) .. ' '
        .. F(i.viewportW, 0) .. 'x' .. F(i.viewportH, 0))
    table.insert(lines, 'LOD: scale ' .. F(i.lodScale) .. ', lodRow ' .. F(i.lodRowA, 5) .. ', ' .. F(i.lodRowB, 5) .. ', ' .. F(i.lodRowC, 5) .. ', ' .. F(i.lodRowD, 3)
        .. ', dissolve range ' .. F(i.dissolveRange, 1))
    if i.depth then
        local cut = {}
        for n = 1, (i.lodCount or 0) do table.insert(cut, F(i['cutoff' .. n], 0)) end
        table.insert(lines, 'unit ' .. tostring(entityId) .. ': at ' .. F(i.x, 1) .. ', ' .. F(i.y, 1) .. ', ' .. F(i.z, 1) .. ', LOD depth ' .. F(i.depth, 1) .. ' (straight distance '
            .. F(i.distance, 1) .. '), selected LOD ' .. tostring(i.lod) .. ' of ' .. tostring(i.lodCount) .. ', cutoffs ' .. table.concat(cut, ' / ') .. ', dissolve ' .. F(i.dissolve, 2)
            .. ', hidden ' .. tostring(i.hidden))
    end
    return lines
end

--- Command: writes the diagnostics lines to the log and the status line, and to camera_diagnostics.txt in the user folder (and the clipboard when this build has it).
function ReportDiagnostics()
    local lines = Diagnostics()
    if table.getn(lines) == 0 then
        pcall(function() import('/lua/editor/ui.lua').Say('camera diagnostics need a newer engine build (ed_lod_info)') end)
        return
    end
    local text = table.concat(lines, '\n')
    for _, line in lines do LOG('EDITOR camera: ' .. line) end
    local file
    pcall(function()
        file = import('/lua/editor/userdata.lua').Path('camera_diagnostics.txt')
        ed_write_file(file, text)
    end)
    if rawget(_G, 'CopyToClipboard') then pcall(CopyToClipboard, text) end
    pcall(function() import('/lua/editor/ui.lua').Say(lines[1] .. (file and ('   (all lines in ' .. file .. ')') or '')) end)
end

--- The camera commands: held keys (`hold`) and one-shot actions. Bindings are data (`keys`, `keys2`) and are rebound in the hotkey
--- manager; nothing here is wired to a key by the engine map except the one-shots.
function RegisterCommands(Commands)
    local function Hold(id, title, hold, keys, keys2)
        Commands.Register{ id = id, title = title, hold = hold, keys = keys, keys2 = keys2, run = function() end }
    end
    Hold('camera.pan.up', 'Camera: move forward', 'pan.up', 'W', 'UpArrow')
    Hold('camera.pan.down', 'Camera: move back', 'pan.down', 'S', 'DownArrow')
    Hold('camera.pan.left', 'Camera: move left', 'pan.left', 'A', 'LeftArrow')
    Hold('camera.pan.right', 'Camera: move right', 'pan.right', 'D', 'RightArrow')
    Hold('camera.turn.left', 'Camera: turn left', 'turn.left', 'Q')
    Hold('camera.turn.right', 'Camera: turn right', 'turn.right', 'E')
    Hold('camera.tilt.up', 'Camera: tilt up', 'tilt.up', 'PageUp')
    Hold('camera.tilt.down', 'Camera: tilt down', 'tilt.down', 'PageDown')
    Hold('camera.zoom.in', 'Camera: zoom in', 'zoom.in', 'Z')
    Hold('camera.zoom.out', 'Camera: zoom out', 'zoom.out', 'X')
    for n = 1, 9 do
        local slot = n
        Commands.Register{ id = 'camera.go' .. n, title = 'Camera: go to bookmark ' .. n, keys = 'Ctrl+' .. n, run = function() GoBookmark(slot) end }
        Commands.Register{ id = 'camera.mark' .. n, title = 'Camera: save bookmark ' .. n, keys = 'Ctrl+Shift+' .. n, run = function() SaveBookmark(slot) end }
    end
    Commands.Register{ id = 'camera.reset', title = 'Camera: reset view', keys = 'Home', run = Reset }
    Commands.Register{ id = 'camera.north', title = 'Camera: face north', keys = 'N', run = North }
    Commands.Register{ id = 'camera.topdown', title = 'Camera: look straight down', keys = 'T', run = TopDown }
    Commands.Register{ id = 'camera.focus', title = 'Camera: focus on selection', keys = 'F', run = FocusSelection }
    Commands.Register{ id = 'camera.diagnostics', title = 'Camera: save LOD diagnostics', run = ReportDiagnostics }
end
