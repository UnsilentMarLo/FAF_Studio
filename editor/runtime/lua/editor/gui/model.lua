-- Sample document model for the built-in panels: panels keep state here, not in their controls, so moving a panel to another window
-- (destroy and recreate) loses nothing. A real editor replaces this with the MapDocument.

items = {}
selection = false   -- module variables set to nil do not exist (strict globals): use false for 'none'
listeners = {}

function Init()
    if table.getn(items) > 0 then return end
    local kinds = { 'Mass', 'Hydro', 'Start', 'Prop', 'Decal', 'Area' }
    for i = 1, 2500 do
        local kind = kinds[math.mod(i, 6) + 1]
        items[i] = { name = kind .. ' ' .. string.format('%04d', i), kind = kind, x = math.mod(i * 37, 512), z = math.mod(i * 91, 512), team = math.mod(i, 4) + 1 }
    end
    Log('model ready: ' .. table.getn(items) .. ' objects')
end

function OnChange(fn)
    listeners[table.getn(listeners) + 1] = fn
end

local function Notify(what)
    for _, fn in listeners do pcall(fn, what) end
end

function Select(i)
    selection = i
    Notify('selection')
end

--- A line for the Console panel. The messages live in consolelog.lua (a ring of 2000 entries, also fed by LOG, WARN and the status line); this stays for the callers that log through the model.
function Log(text)
    import('/lua/editor/consolelog.lua').Add('info', text, 'editor')
end

function Clear()
    import('/lua/editor/consolelog.lua').Clear()
end
