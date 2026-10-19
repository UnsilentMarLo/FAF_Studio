-- The hotkey manager: every editor command and camera mouse gesture with its current binding, rebinding by pressing the new key (or mouse
-- gesture), conflict handling, clearing, reset to the defaults, and persistence in config/editor_hotkeys.lua.
--
--   Hotkeys.Load()       called once at shell start, after the commands are registered and before Keys.Apply: records the defaults and
--                        applies the saved bindings
--   Hotkeys.Save()       writes the bindings that differ from the defaults
--   Hotkeys.Bind(id, slot, keys)   slot 1 = `keys`, slot 2 = `keys2` ('' clears); steals the key from a conflicting command
--   Hotkeys.ResetAll()   back to the defaults
--
-- A command has two binding slots (`keys`, `keys2`). Camera gestures (camera.lua Gestures) are a mouse button plus modifiers.
-- Keys are spelled like the engine does ('Ctrl-Shift-P', 'PageUp'); '+' is accepted as the separator too and is normalised for comparison.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Keys = import('/lua/editor/gui/keys.lua')
local Camera = import('/lua/editor/camera.lua')
local Menu = import('/lua/editor/gui/menu.lua')

local UserData = import('/lua/editor/userdata.lua')

local LEGACY = 'config/editor_hotkeys.lua'      -- where an older editor kept the bindings (next to the exe); read when the user folder has none

captured = false     -- the defaults have been recorded
live = {}
capture = false      -- the open capture overlay { group, ... }

-- ---- canonical key text ----------------------------------------------------------------------------------------------------------------------

--- 'Ctrl+z' / 'Shift-Ctrl-Z' -> 'Ctrl-Shift-Z' (modifiers in a fixed order), '' for none.
function Canonical(keys)
    if not keys or keys == '' then return '' end
    local key, mods = Camera.ParseKeys(keys)
    local out = ''
    if mods.Ctrl then out = out .. 'Ctrl-' end
    if mods.Alt then out = out .. 'Alt-' end
    if mods.Shift then out = out .. 'Shift-' end
    return out .. key
end

-- ---- defaults and persistence ------------------------------------------------------------------------------------------------------------------

local function CaptureDefaults()
    if captured then return end
    captured = true
    for _, id in Commands.order do
        local def = Commands.registry[id]
        def.defKeys, def.defKeys2 = def.keys or '', def.keys2 or ''
    end
end

local function Q(s) return string.format('%q', s) end

function Save()
    local lines = { 'return {', '  format = ' .. UserData.FORMAT .. ',', '  commands = {' }
    for _, id in Commands.order do
        local def = Commands.registry[id]
        if (def.keys or '') ~= (def.defKeys or '') or (def.keys2 or '') ~= (def.defKeys2 or '') then
            table.insert(lines, string.format('    [%s] = { keys = %s, keys2 = %s },', Q(id), Q(def.keys or ''), Q(def.keys2 or '')))
        end
    end
    table.insert(lines, '  },')
    table.insert(lines, '  gestures = {')
    for _, id in Camera.GestureOrder do
        local g = Camera.Gestures[id]
        local d = Camera.GestureDefaults[id]
        if g.button ~= d.button or g.ctrl ~= d.ctrl or g.alt ~= d.alt or g.shift ~= d.shift then
            table.insert(lines, string.format('    [%s] = { button = %s, ctrl = %s, alt = %s, shift = %s },', Q(id), Q(g.button),
                tostring(g.ctrl), tostring(g.alt), tostring(g.shift)))
        end
    end
    table.insert(lines, '  },')
    table.insert(lines, '}')
    return ed_write_file(UserData.Path('hotkeys.lua'), table.concat(lines, '\n') .. '\n')
end

function Load()
    CaptureDefaults()
    local text = ed_read_file(UserData.Path('hotkeys.lua'))
    if text == nil then text = ed_read_file(LEGACY) end
    if not text or text == '' then return false end
    local okLoad, chunk = pcall(loadstring, text, '=hotkeys')     -- (loadstring raises on a syntax error)
    if not okLoad or not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' then return false end
    for id, b in (data.commands or {}) do
        local def = Commands.registry[id]
        if def then
            def.keys, def.keys2 = b.keys or '', b.keys2 or ''
        end
    end
    for id, b in (data.gestures or {}) do
        local g = Camera.Gestures[id]
        if g then
            g.button, g.ctrl, g.alt, g.shift = b.button or g.button, b.ctrl and true or false, b.alt and true or false, b.shift and true or false
        end
    end
    return true
end

-- ---- binding ----------------------------------------------------------------------------------------------------------------------------------

local function Apply()
    -- the engine key map is rebuilt from the registry; held keys are polled by camera.lua and need nothing
    Keys.Apply{ exclusive = true }
    Save()
end

--- Who has `keys` (other than `exceptId`)? Returns the command definition and its slot.
function Holder(keys, exceptId)
    local canon = Canonical(keys)
    if canon == '' then return nil end
    for _, id in Commands.order do
        if id ~= exceptId then
            local def = Commands.registry[id]
            if Canonical(def.keys) == canon then return def, 1 end
            if Canonical(def.keys2) == canon then return def, 2 end
        end
    end
    return nil
end

--- Binds `keys` to slot 1 or 2 of command `id`. A command that already holds the key loses it. Returns a message for the status line.
function Bind(id, slot, keys)
    local def = Commands.registry[id]
    if not def then return 'unknown command' end
    keys = Canonical(keys)
    local message = ''
    local other, otherSlot = Holder(keys, id)
    if other then
        if otherSlot == 1 then other.keys = '' else other.keys2 = '' end
        message = 'moved from ' .. tostring(other.title or other.id)
    end
    if slot == 2 then def.keys2 = keys else def.keys = keys end
    Apply()
    return message
end

function Clear(id, slot)
    local def = Commands.registry[id]
    if not def then return end
    if slot == 2 then def.keys2 = '' else def.keys = '' end
    Apply()
end

function ResetCommand(id)
    local def = Commands.registry[id]
    if not def then return end
    def.keys, def.keys2 = def.defKeys or '', def.defKeys2 or ''
    Apply()
end

function ResetAll()
    for _, id in Commands.order do
        local def = Commands.registry[id]
        def.keys, def.keys2 = def.defKeys or '', def.defKeys2 or ''
    end
    Camera.ResetGestures()
    Apply()
end

-- ---- capture overlay ---------------------------------------------------------------------------------------------------------------------------

function CloseCapture()
    if capture then
        pcall(function() capture.shade:AbandonKeyboardFocus() end)
        capture.shade:Destroy()
        capture.box:Destroy()
        capture.line:Destroy()
        capture = false
    end
end

local codeLookup = false

local function KeyName(code)
    if not codeLookup then codeLookup = import('/lua/keymap/keymapper.lua').GetKeyCodeLookup() end
    return codeLookup[code]
end

--- Opens a modal prompt that takes the next key combination ('key') or the next mouse press with its modifiers ('mouse').
--- `done(keysOrGesture)` is called with the key text, or a table { button, ctrl, alt, shift }. Esc cancels.
function OpenCapture(frame, kind, prompt, done)
    CloseCapture()
    local c = Skin.color
    local fw, fh = frame.Width(), frame.Height()
    local shade = Bitmap(frame)
    shade.Depth:Set(9500)
    shade:SetSolidColor('a0000000')
    shade.Left:Set(0) shade.Top:Set(0) shade.Width:Set(fw) shade.Height:Set(fh)
    local bw, bh = Skin.S(420), Skin.S(90)
    local box = Bitmap(frame)
    box.Depth:Set(9501)
    box:SetSolidColor(c.panel)
    box.Left:Set(math.floor((fw - bw) / 2)) box.Top:Set(math.floor(fh / 3))
    box.Width:Set(bw) box.Height:Set(bh)
    box:DisableHitTest()
    local line = W.Label(box, prompt, Skin.S(14), Skin.S(14), { color = c.text })
    line.Depth:Set(9502)
    capture = { shade = shade, box = box, line = line }
    local function Finish(result)
        CloseCapture()
        done(result)
    end
    shade.HandleEvent = function(self, event)
        if kind == 'key' and event.Type == 'KeyDown' then
            local name = KeyName(event.RawKeyCode)
            if not name then return true end
            if name == 'Esc' then CloseCapture() return true end
            if name == 'Shift' or name == 'Ctrl' or name == 'Alt' then return true end     -- wait for the key itself
            local m = event.Modifiers or {}
            local text = ''
            if m.Ctrl then text = text .. 'Ctrl-' end
            if m.Alt then text = text .. 'Alt-' end
            if m.Shift then text = text .. 'Shift-' end
            Finish(text .. name)
            return true
        elseif kind == 'mouse' and event.Type == 'ButtonPress' then
            local m = event.Modifiers or {}
            local button = (m.Middle and 'Middle') or (m.Right and 'Right') or (m.Left and 'Left') or nil
            if button then
                Finish({ button = button, ctrl = m.Ctrl and true or false, alt = m.Alt and true or false, shift = m.Shift and true or false })
            end
            return true
        elseif event.Type == 'KeyDown' and KeyName(event.RawKeyCode) == 'Esc' then
            CloseCapture()
            return true
        end
        return true
    end
    shade:AcquireKeyboardFocus(false)
end

-- ---- the panel ---------------------------------------------------------------------------------------------------------------------------------

local function Entries(filter)
    local list = {}
    local f = string.lower(filter or '')
    local function Wanted(text)
        return f == '' or string.find(string.lower(text), f, 1, true) ~= nil
    end
    for _, id in Camera.GestureOrder do
        local g = Camera.Gestures[id]
        if Wanted(g.title .. ' ' .. Camera.GestureText(g)) then table.insert(list, { kind = 'gesture', id = id }) end
    end
    for _, id in Commands.order do
        local def = Commands.registry[id]
        local keys = (def.keys or '') .. ' ' .. (def.keys2 or '')
        if Wanted((def.title or id) .. ' ' .. keys) then table.insert(list, { kind = 'command', id = id }) end
    end
    return list
end

local function BindingText(entry)
    if entry.kind == 'gesture' then
        return Camera.GestureText(Camera.Gestures[entry.id])
    end
    local def = Commands.registry[entry.id]
    local a, b = Canonical(def.keys), Canonical(def.keys2)
    if a == '' and b == '' then return '-' end
    if a == '' then return b end
    if b == '' then return a end
    return a .. ',  ' .. b
end

Panels.Register{
    id = 'hotkeys', title = 'Hotkeys',
    create = function(group, host)
        local P = { filter = '', shown = {}, selected = false, w = 300, h = 200 }
        live.hotkeys = P

        local function Rebuild()
            P.shown = Entries(P.filter)
            P.list:Refresh()
        end

        local function Say(text)
            P.status:SetText(text or '')
        end

        local function Selected()
            return P.selected and P.shown[P.selected]
        end

        P.field = W.TextField(group, Skin.S(8), Skin.S(8), 100, Skin.S(22), {
            onChange = function(text) P.filter = text Rebuild() end,
        })
        P.list = W.VirtualList(group, {
            extra = true,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local entry = P.shown[index]
                local title
                if entry.kind == 'gesture' then
                    title = Camera.Gestures[entry.id].title
                else
                    local def = Commands.registry[entry.id]
                    title = def.title or def.id
                end
                local binding = BindingText(entry)
                row.extra:SetText(binding)
                local rowW = row.bg.Width()
                local keysW = row.extra.Width()
                W.Fit(row.text, title, math.max(Skin.S(40), rowW - keysW - Skin.S(30)))
                row.text:SetColor(Skin.color.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                row.extra:SetColor(binding == '-' and Skin.color.textDim or Skin.color.accent)
                row.extra.Left:Set(function() return row.bg.Right() - keysW - Skin.S(10) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                P.selected = index
                Say('')
                P:Refresh()
            end,
            onContext = function(index, x, y)
                P.selected = index
                P.list:SetSelected(index)
                Menu.Context('context.list', { list = 'hotkeys', index = index }, x, y)
            end,
            bgColor = Skin.color.panel,
        })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        local function Frame() return GetFrame(0) end
        local function BindSlot(slot)
            local entry = Selected()
            if not entry then Say('select a row first') return end
            if entry.kind == 'gesture' then
                OpenCapture(Frame(), 'mouse', Camera.Gestures[entry.id].title .. ': press a mouse button with the modifiers (Esc cancels)', function(g)
                    if g.button == 'Left' and not g.ctrl and not g.alt then
                        Say('the plain and Shift left button belong to the tools')
                        return
                    end
                    local target = Camera.Gestures[entry.id]
                    for oid, other in Camera.Gestures do
                        if oid ~= entry.id and other.button == g.button and other.ctrl == g.ctrl and other.alt == g.alt and other.shift == g.shift then
                            Say('already used by: ' .. other.title)
                            return
                        end
                    end
                    target.button, target.ctrl, target.alt, target.shift = g.button, g.ctrl, g.alt, g.shift
                    Save()
                    Say('bound')
                    P:Refresh()
                end)
            else
                local def = Commands.registry[entry.id]
                OpenCapture(Frame(), 'key', (def.title or def.id) .. ': press the new key combination (Esc cancels)', function(keys)
                    local message = Bind(entry.id, slot, keys)
                    Say(message ~= '' and ('bound, ' .. message) or 'bound')
                    P:Refresh()
                end)
            end
        end
        P.bind1 = W.Button(group, 'Bind', 0, 0, Skin.S(50), Skin.S(24), function() BindSlot(1) end)
        P.bind2 = W.Button(group, 'Bind 2nd', 0, 0, Skin.S(70), Skin.S(24), function() BindSlot(2) end)
        local function ClearSelected()
            local entry = Selected()
            if entry and entry.kind == 'command' then
                Clear(entry.id, 1) Clear(entry.id, 2)
                Say('cleared')
                P:Refresh()
            end
        end
        local function DefaultSelected()
            local entry = Selected()
            if not entry then return end
            if entry.kind == 'gesture' then
                local g, d = Camera.Gestures[entry.id], Camera.GestureDefaults[entry.id]
                g.button, g.ctrl, g.alt, g.shift = d.button, d.ctrl, d.alt, d.shift
                Save()
            else
                ResetCommand(entry.id)
            end
            Say('reset')
            P:Refresh()
        end
        P.clear = W.Button(group, 'Clear', 0, 0, Skin.S(50), Skin.S(24), ClearSelected)
        P.default = W.Button(group, 'Default', 0, 0, Skin.S(58), Skin.S(24), DefaultSelected)

        --- The right-click menu of the selected row.
        function P:ContextItems()
            local entry = Selected()
            if not entry then return nil end
            local isCommand = entry.kind == 'command'
            return {
                { title = isCommand and 'Bind key...' or 'Bind mouse gesture...', run = function() BindSlot(1) end },
                { title = 'Bind second key...', enabled = isCommand, run = function() BindSlot(2) end },
                { title = 'Clear', enabled = isCommand, run = ClearSelected },
                { title = 'Reset to default', run = DefaultSelected },
            }
        end
        P.all = W.Button(group, 'Reset all', 0, 0, Skin.S(70), Skin.S(24), function()
            ResetAll()
            Say('all bindings reset')
            P:Refresh()
        end)

        function P:Refresh()
            P.list:Refresh()
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            W.Place(P.field.frame, group, pad, pad, math.max(Skin.S(60), w - 2 * pad), Skin.S(22))
            P.field.Width:Set(math.max(Skin.S(60), w - 2 * pad) - 2)
            local btns = {}
            for _, b in { P.bind1, P.bind2, P.clear, P.default, P.all } do table.insert(btns, { b, b.Width() }) end
            local rowsH = W.Flow(group, btns, 0, 0, w - 2 * pad, Skin.S(24), Skin.S(6), true)      -- the buttons wrap in a narrow panel
            local bottom = h - pad - rowsH
            local rowAbove = bottom - Skin.S(28)
            local listTop = pad + Skin.S(28)
            P.list:SetRect(pad, listTop, w - 2 * pad, math.max(Skin.S(40), rowAbove - listTop - Skin.S(4)))
            W.Place(P.status, group, pad, rowAbove + Skin.S(6))
            W.Flow(group, btns, pad, bottom, w - 2 * pad, Skin.S(24), Skin.S(6))
            Rebuild()
        end
        function P:Destroy()
            CloseCapture()
        end
        return P
    end,
}

Menu.Extend('context.list', function(ctx)
    if ctx.list == 'hotkeys' and live.hotkeys then return live.hotkeys:ContextItems() end
    return nil
end, 10)
