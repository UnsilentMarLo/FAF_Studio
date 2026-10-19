-- The editor's help content and its search. Static topics come from helpdata.lua (generated from editor/help/*.md by scripts/gen_help.py); two topics are built
-- from the running editor so they can never go out of date: the shortcut cheat sheet (the command registry and the camera gestures) and the list of tools and panels
-- (ui.lua's tool table, the panel registry and tooltips.lua).
--
--   Topics() -> list of { id, title, summary, keywords, blocks }     blocks: { 'h', text } | { 'p', text } | { 'li', text } | { 'step', text, n } | { 'kv', left, right }
--   Find(id) -> topic | nil
--   Search(query) -> list of { topic, score }, best first (every word of the query must occur in the title, keywords, summary or text); '' lists every topic
--   Shortcuts() / ToolsAndPanels() -> the generated topics
--   Pending: a topic id the help panel should open when it shows (set by Open)
--
-- Lua 5.0 dialect.

local Data = import('/lua/editor/helpdata.lua')

Pending = false      -- { topic = id | nil, query = text | nil }

local function Keys(def)
    local k1, k2 = def.keys or '', def.keys2 or ''
    if k1 ~= '' and k2 ~= '' then return k1 .. '  or  ' .. k2 end
    if k1 ~= '' then return k1 end
    return k2
end

local gestureButton = { Left = 'left button', Middle = 'middle button', Right = 'right button' }

local function GestureText(g)
    local parts = {}
    if g.ctrl then table.insert(parts, 'Ctrl') end
    if g.alt then table.insert(parts, 'Alt') end
    if g.shift then table.insert(parts, 'Shift') end
    local btn = gestureButton[g.button] or tostring(g.button)
    if table.getn(parts) > 0 then return table.concat(parts, ' + ') .. ' + ' .. btn .. ' drag' end
    return btn .. ' drag'
end

--- The shortcut cheat sheet: every command that has a key, by area, then the camera gestures. Built from the registry, so a rebinding shows here.
function Shortcuts()
    local Commands = import('/lua/editor/gui/commands.lua')
    local groups = {
        { title = 'File', prefix = 'file.' },
        { title = 'Edit', prefix = 'edit.' },
        { title = 'View', prefix = 'view.' },
        { title = 'Tools of the workspace', prefix = 'tool.' },
        { title = 'Workspaces', prefix = 'workspace.' },
        { title = 'Camera', prefix = 'camera.' },
        { title = 'Help and commands', prefix = '' },        -- everything else
    }
    local blocks = {
        { 'p', 'The keys below are the ones in use right now (Help > Hotkeys changes them). Every command can also be run from the command palette, Ctrl+Shift+P.' },
    }
    local used = {}
    for gi, group in groups do
        local rows = {}
        for _, id in Commands.order do
            local def = Commands.registry[id]
            local keys = Keys(def)
            if keys ~= '' and not used[id] then
                local match = (group.prefix == '') or (string.sub(id, 1, string.len(group.prefix)) == group.prefix)
                if match then
                    used[id] = true
                    local title = def.title or id
                    title = string.gsub(title, '^%a+: ', '')        -- "Camera: move forward" under the Camera heading
                    title = string.upper(string.sub(title, 1, 1)) .. string.sub(title, 2)
                    table.insert(rows, { 'kv', title, keys })
                end
            end
        end
        if group.title == 'Camera' then
            local Camera = import('/lua/editor/camera.lua')
            for _, gid in Camera.GestureOrder do
                local g = Camera.Gestures[gid]
                local gt = string.gsub(g.title or gid, '^Camera: ', '')
                table.insert(rows, { 'kv', string.upper(string.sub(gt, 1, 1)) .. string.sub(gt, 2), GestureText(g) })
            end
            table.insert(rows, { 'kv', 'Zoom', 'mouse wheel' })
        end
        if table.getn(rows) > 0 then
            table.insert(blocks, { 'h', group.title })
            for _, r in rows do table.insert(blocks, r) end
        end
    end
    return { id = 'shortcuts', title = 'Keyboard and mouse shortcuts', summary = 'Every key and mouse gesture, generated from the editor itself.',
             keywords = 'keys, keyboard, hotkeys, shortcuts, cheat sheet, mouse, camera, bindings', blocks = blocks }
end

--- Tools and panels with their one-line descriptions (tooltips.lua), for the tools and panels this editor has.
function ToolsAndPanels()
    local UI = import('/lua/editor/ui.lua')
    local Panels = import('/lua/editor/gui/panels.lua')
    local Tips = import('/lua/editor/tooltips.lua')
    local blocks = {
        { 'p', 'Hover a tool or a panel tab for the same text. Tools are in the Tools panel of each workspace; panels are the tabs around the viewport.' },
        { 'h', 'Tools' },
    }
    for _, tool in UI.Tools do
        local tip = Tips.ForTool(tool.id)
        table.insert(blocks, { 'li', tool.label .. ': ' .. (tip or 'no description yet.') })
    end
    table.insert(blocks, { 'h', 'Panels' })
    for _, def in Panels.All() do
        local tip = Tips.ForPanel(def.id)
        table.insert(blocks, { 'li', def.title .. ': ' .. (tip or 'no description yet.') })
    end
    table.insert(blocks, { 'h', 'Workspaces' })
    local Workspace = import('/lua/editor/gui/workspace.lua')
    for i, name in Workspace.Presets() do
        table.insert(blocks, { 'li', name .. ' (Alt+' .. i .. '): ' .. (Tips.ForWorkspace(name) or '') })
    end
    return { id = 'tools_and_panels', title = 'Tools, panels and workspaces', summary = 'What every tool, panel and workspace is for.',
             keywords = 'tools, panels, workspaces, list, what is, description, overview', blocks = blocks }
end

local cache = false

function Topics()
    local list = {}
    for _, t in Data.Topics do table.insert(list, t) end
    local ok, s = pcall(Shortcuts)
    if ok then table.insert(list, s) else LOG('EDITOR help: shortcuts topic failed: ' .. tostring(s)) end
    local ok2, tp = pcall(ToolsAndPanels)
    if ok2 then table.insert(list, tp) else LOG('EDITOR help: tools topic failed: ' .. tostring(tp)) end
    return list
end

function Find(id)
    for _, t in Topics() do
        if t.id == id then return t end
    end
    return nil
end

--- All the text of a topic, lower case.
local function Haystack(topic)
    local parts = {}
    for _, b in topic.blocks do
        table.insert(parts, b[2] or '')
        if b[1] == 'kv' then table.insert(parts, b[3] or '') end
    end
    return string.lower(table.concat(parts, ' '))
end

local function Has(text, word)
    return string.find(text, word, 1, true) ~= nil
end

function Search(query)
    local words = {}
    for w in string.gfind(string.lower(query or ''), '%S+') do table.insert(words, w) end
    local out = {}
    for _, topic in Topics() do
        local title, keywords, summary = string.lower(topic.title), string.lower(topic.keywords or ''), string.lower(topic.summary or '')
        local text = Haystack(topic)
        local score, all = 0, true
        for _, w in words do
            local s = 0
            if Has(title, w) then s = s + 8 end
            if Has(keywords, w) then s = s + 4 end
            if Has(summary, w) then s = s + 2 end
            if Has(text, w) then s = s + 1 end
            if s == 0 then all = false end
            score = score + s
        end
        if all then table.insert(out, { topic = topic, score = score }) end
    end
    if table.getn(words) > 0 then
        table.sort(out, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.topic.title < b.topic.title
        end)
    end
    return out
end

--- Asks the help panel to show a topic or a search the next time it is built; the shell's OpenPanelWindow shows the panel.
function Open(topicId, query)
    Pending = { topic = topicId, query = query }
    local ok, shell = pcall(import, '/lua/editor/gui/shell.lua')
    if ok then shell.OpenPanelWindow('help', 760, 560) end
    pcall(function() import('/lua/editor/gui/panels_help.lua').Apply() end)
end
