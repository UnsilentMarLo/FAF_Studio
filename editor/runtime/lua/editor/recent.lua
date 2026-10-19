-- Recently opened or saved maps (File > Open recent, the start screen). The list is kept in the user folder (userdata.lua, `recent.txt`), newest first, one scenario
-- path per line; the file an older editor kept next to the exe (`editor_recent.txt`) is read when the new one does not exist yet.
--
--   Add(scenarioPath)     puts a map at the top (called by maps.lua when a map is opened or saved)
--   List([limit])         list of { path, name, folder } of the maps that still exist, newest first
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')

local LEGACY = 'editor_recent.txt'
local LIMIT = 12

local function File()
    return UserData.Path('recent.txt')
end

local function Read()
    local list = {}
    local text = ed_read_file(File())
    if not text then text = ed_read_file(LEGACY) end
    for line in string.gfind(text or '', '[^\r\n]+') do table.insert(list, line) end
    return list
end

function Add(path)
    if not path or path == '' or string.find(path, '_playtest', 1, true) or string.find(path, '_autosave', 1, true) or string.find(path, '_modreload', 1, true) then return end
    local list = { path }
    for _, p in Read() do
        if string.lower(p) ~= string.lower(path) and table.getn(list) < LIMIT then table.insert(list, p) end
    end
    ed_write_file(File(), table.concat(list, '\n') .. '\n')
end

function List(limit)
    local out = {}
    for _, p in Read() do
        if (not limit or table.getn(out) < limit) and DiskGetFileInfo(p) then
            local stem = string.gsub(string.gsub(p, '^.*/', ''), '_scenario%.lua$', '')
            local folder = string.gsub(string.gsub(p, '/[^/]*$', ''), '^.*/', '')
            table.insert(out, { path = p, name = stem, folder = folder })
        end
    end
    return out
end
