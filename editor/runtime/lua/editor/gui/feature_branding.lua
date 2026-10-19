-- The look of the editor's main window: icon (branding/fafstudio.ico, drawn by scripts/make_editor_icon.py) and the title bar text
-- "FAF Studio  -  <map name>  *  [<workspace>]" (* = unsaved changes), set through the natives ed_app_set_icon / ed_app_set_title (EdWindow.cpp).
-- Both natives are optional: an older exe keeps the engine's own "Forged Alliance" title and icon. A self-registering feature module: its Refresh() is ticked by the shell.
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

local APP = 'FAF Studio'
local iconDone = false
local lastTitle = false

local function Native(name)
    return rawget(_G, name)
end

local function Title()
    local name = Map.Doc and Map.Doc.info and Map.Doc.info.name
    local dirty = false
    local ok, d = pcall(function() return import('/lua/editor/maps.lua').Dirty() end)
    if ok then dirty = d end
    local ws = false
    pcall(function() ws = import('/lua/editor/gui/shell.lua').S.current end)
    local text = APP
    if name and name ~= '' then text = text .. '  -  ' .. name .. (dirty and ' *' or '') end
    if ws then text = text .. '   [' .. tostring(ws) .. ']' end
    return text
end

--- Called by the shell about four times a second: puts the icon on once, and the title whenever it changed.
function Refresh()
    if not iconDone and Native('ed_app_set_icon') then
        local disk = ed_vfs_to_disk('/branding/fafstudio.ico')
        if disk then
            local ok, res = pcall(ed_app_set_icon, disk)
            if ok and res then iconDone = true end
        end
    end
    if Native('ed_app_set_title') then
        local title = Title()
        if title ~= lastTitle then
            local ok, res = pcall(ed_app_set_title, title)
            if ok and res then lastTitle = title end
        end
    end
end
