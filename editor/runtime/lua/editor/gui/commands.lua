-- Command registry and the command palette. Every user action is a command with an id; menus, buttons, key bindings and the palette
-- all run commands by id. Editor mods register commands the same way.
--
--   Commands.Register{ id = 'workspace.terrain', title = 'Workspace: Terrain', keys = 'Ctrl+1', run = function() ... end }
--   Commands.Run(id)            Commands.Find(text) -> list of commands whose title contains every word of `text`
--   A command registered with `mod = 'My mod'` (api.lua Mod(name).Command does it) that raises is reported with the mod's name and turned off for the session; every command is protected.
--   Commands.OpenPalette(frame) overlay with a filter field and a list; Enter or a click runs the selected command, Esc closes

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Skin = import('/lua/editor/gui/skin.lua')
local W = import('/lua/editor/gui/widgets.lua')

registry = {}
order = {}
palette = false   -- nil would not exist as a module variable (strict globals)

function Register(def)
    if not def or not def.id or not def.run then
        error('Commands.Register: a command needs an id and a run function')
    end
    if registry[def.id] and registry[def.id].mod and registry[def.id].mod ~= def.mod then
        WARN('EDITOR commands: ' .. def.id .. ' of mod ' .. tostring(registry[def.id].mod) .. ' is replaced by ' .. tostring(def.mod or 'the editor'))
    end
    if not registry[def.id] then order[table.getn(order) + 1] = def.id end
    registry[def.id] = def
end

-- Interceptors let a module that owns the keyboard focus for a while (the terrain graph canvas) take Copy, Paste, Delete, Undo ... for itself: fn(id) returns true when it handled the
-- command. Intercept(fn) adds one.
interceptors = {}
function Intercept(fn)
    table.insert(interceptors, fn)
end

function Run(id)
    local def = registry[id]
    if not def then return false end
    local Api = import('/lua/editor/api.lua')
    if Api.IsDisabled('command', id) then
        LOG('EDITOR gui: command ' .. id .. ' is disabled (mod ' .. tostring(def.mod) .. ' failed earlier in this session)')
        return false
    end
    for _, fn in interceptors do
        local ok, used = pcall(fn, id)
        if not ok then Api.Failed('interceptor', id, nil, used) end
        if ok and used then return true end
    end
    local ok, err = pcall(def.run)
    if not ok then Api.Failed('command', id, def.mod, err) end
    return ok
end

function Find(text)
    local words = {}
    for w in string.gfind(string.lower(text or ''), '%S+') do words[table.getn(words) + 1] = w end
    local out = {}
    for _, id in order do
        local def = registry[id]
        local hay = string.lower(def.title or id)
        local all = not (def.mod and import('/lua/editor/api.lua').IsDisabled('command', id))
        for _, w in words do
            if not string.find(hay, w, 1, true) then all = false end
        end
        if all then out[table.getn(out) + 1] = def end
    end
    return out
end

function ClosePalette()
    if palette then
        palette.group:Destroy()
        palette = false
    end
end

function OpenPalette(frame)
    ClosePalette()
    local c = Skin.color
    local width, height = Skin.S(520), Skin.S(34) + Skin.S(Skin.size.rowH) * 10 + Skin.S(16)
    local fw, fh = frame.Width(), frame.Height()
    local x, y = math.floor((fw - width) / 2), Skin.S(70)
    local group = Group(frame)
    group.Depth:Set(9000)
    group.Left:Set(x) group.Top:Set(y) group.Width:Set(width) group.Height:Set(height)
    local shade = Bitmap(group)    -- swallows clicks outside the box
    shade.Depth:Set(function() return group.Depth() + 1 end)
    shade:SetSolidColor('00000000')
    shade.Left:Set(0) shade.Top:Set(0) shade.Width:Set(fw) shade.Height:Set(fh)
    shade.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then ClosePalette() return true end
        return false
    end
    local box = Bitmap(group)
    box.Depth:Set(function() return group.Depth() + 2 end)
    box:SetSolidColor(c.line)
    box.Left:Set(function() return group.Left() end) box.Top:Set(function() return group.Top() end)
    box.Width:Set(width) box.Height:Set(height)
    local inner = Bitmap(group)
    inner.Depth:Set(function() return group.Depth() + 3 end)
    inner:SetSolidColor(c.panel)
    inner.Left:Set(function() return group.Left() + 1 end) inner.Top:Set(function() return group.Top() + 1 end)
    inner.Width:Set(width - 2) inner.Height:Set(height - 2)
    local state = { matches = Find('') }
    local function RunSelected(i)
        local def = state.matches[i or 1]
        ClosePalette()
        if def then Run(def.id) end
    end
    local list
    local field = W.TextField(group, Skin.S(8), Skin.S(8), width - Skin.S(16), Skin.S(24), {
        onChange = function(text)
            state.matches = Find(text)
            list:SetSelected(1)
            list:Refresh()
        end,
        onEnter = function() RunSelected(list.selected) end,
        onEscape = function() ClosePalette() end,
    })
    list = W.VirtualList(group, {
        rowH = Skin.size.rowH,
        getCount = function() return table.getn(state.matches) end,
        bind = function(row, index)
            local def = state.matches[index]
            row.text:SetText(def.title .. (def.keys and ('    ' .. def.keys) or ''))
            row.text:SetColor(c.text)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index) RunSelected(index) end,
    })
    list:SetRect(Skin.S(8), Skin.S(40), width - Skin.S(16), Skin.S(Skin.size.rowH) * 10)
    list:SetSelected(1)
    field:AcquireFocus()
    palette = { group = group, field = field, list = list }
end
