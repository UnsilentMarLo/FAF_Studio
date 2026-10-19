-- Everything the editor remembers between runs lives in one per-user folder: layouts of the workspaces, UI scale, the last tool and brush settings,
-- hotkeys, recent maps, the first-run flag. The folder comes from the command line (`/eduser <dir>`, the launcher passes
-- %APPDATA%/FAFStudio); without it (development instances, tests) it is `userdata` next to the exe, so every test instance keeps its own and
-- never touches a real user's settings.
--
--   Dir() / Path(rel)            the folder and a file in it (forward slashes)
--   ReadTable(rel) -> table, status       status 'ok' | 'missing' | 'bad' | 'newer'   (an unreadable file is kept as <rel>.bad)
--   WriteTable(rel, tbl) -> bool           writes `return { format = N, ... }`; a file of a newer editor version is never overwritten
--   Get(key, default) / Set(key, value)    the small values in settings.lua (loaded once, written by Flush(), which the shell ticks)
--   Reset() -> list of the files cleared   the "reset user settings" command: every known file is emptied (Lua has no delete)
--   Known() -> list of the file names the editor writes
--
-- Every file starts with `format`: when a later version changes a layout, Upgrade() turns old tables into the current one. A file whose format
-- is newer than this editor knows is read as far as it fits and left alone on disk.
--
-- Lua 5.0 dialect.

FORMAT = 1                  -- the table format of every file written now

local LuaSer = import('/lua/editor/luaser.lua')

local dir = false
local settings = false      -- the loaded settings.lua
local dirty = false
local readonly = {}         -- file -> true when it came from a newer editor: not written back

local function Normalize(p)
    p = string.gsub(p, '\\', '/')
    return (string.gsub(p, '/+$', ''))
end

--- The user folder (no trailing slash).
function Dir()
    if dir then return dir end
    local arg = rawget(_G, 'GetCommandLineArg') and GetCommandLineArg('/eduser', 1)
    dir = Normalize((arg and arg[1]) or 'userdata')
    return dir
end

--- Tests point the folder somewhere else (and back with nil).
function SetDirForTest(path)
    dir = path and Normalize(path) or false
    settings, dirty, readonly = false, false, {}
end

function Path(rel)
    return Dir() .. '/' .. rel
end

--- Turns a table written by an older editor into the current format. Version 1 is the first; a change adds a step here (`if tbl.format < 2 then ... end`).
local function Upgrade(name, tbl)
    local f = tbl.format or 1
    -- (no older formats exist yet)
    tbl.format = FORMAT
    return tbl
end

--- The table in file `rel` of the user folder. Returns nil, 'missing' | 'bad'; a table whose format is newer than FORMAT comes back with status 'newer'.
function ReadTable(rel)
    local text = ed_read_file(Path(rel))
    if not text or string.find(text, '^%s*$') then return nil, 'missing' end
    -- (in this engine loadstring raises on a syntax error instead of returning nil)
    local okLoad, chunk = pcall(loadstring, text, '=' .. rel)
    local ok, tbl
    if okLoad and chunk then ok, tbl = pcall(chunk) end
    if not okLoad or not chunk or not ok or type(tbl) ~= 'table' then
        ed_write_file(Path(rel) .. '.bad', text)           -- keep what the user had; the editor starts from defaults
        ed_write_file(Path(rel), '')
        LOG('EDITOR userdata: ' .. rel .. ' could not be read, kept as ' .. rel .. '.bad')
        return nil, 'bad'
    end
    local format = tbl.format or 1
    if format > FORMAT then
        readonly[rel] = true
        return tbl, 'newer'
    end
    if format < FORMAT then tbl = Upgrade(rel, tbl) end
    return tbl, 'ok'
end

function WriteTable(rel, tbl)
    if readonly[rel] then return false end
    tbl.format = FORMAT
    local text = '-- FAF Studio user data; edit with care, "Reset user settings" in the Help menu starts over.\nreturn ' .. LuaSer.Dump(tbl, 0) .. '\n'
    return ed_write_file(Path(rel), text)
end

-- ---- settings.lua -----------------------------------------------------------------------------------------------------------------------

local function Load()
    if settings then return settings end
    local tbl = ReadTable('settings.lua')
    settings = tbl or { format = FORMAT }
    return settings
end

function Get(key, default)
    local v = Load()[key]
    if v == nil then return default end
    return v
end

function Set(key, value)
    local s = Load()
    if s[key] == value then return end
    s[key] = value
    dirty = true
end

--- Writes settings.lua when something changed (the shell calls this a few times a second).
function Flush()
    if dirty and settings then
        dirty = false
        WriteTable('settings.lua', settings)
    end
end

-- ---- reset ------------------------------------------------------------------------------------------------------------------------------

--- Files the editor writes into the user folder (layouts, saved layouts, hotkeys, recent maps, settings).
function Known()
    local list = { 'settings.lua', 'hotkeys.lua', 'recent.txt', 'crash.lua' }
    local ok, Workspace = pcall(import, '/lua/editor/gui/workspace.lua')
    if ok and Workspace then
        for _, name in Workspace.Presets() do
            table.insert(list, 'layouts/' .. name .. '.lua')
            table.insert(list, 'saved/' .. name .. '.lua')
        end
    end
    return list
end

--- Empties every known file (the editor has no delete): the next start begins with defaults. Returns the files that had content.
function Reset()
    local cleared = {}
    for _, rel in Known() do
        local text = ed_read_file(Path(rel))
        if text and text ~= '' then
            ed_write_file(Path(rel), '')
            table.insert(cleared, rel)
        end
    end
    settings, dirty, readonly = false, false, {}
    return cleared
end
