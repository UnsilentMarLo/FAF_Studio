-- Crash handling: what the editor does about the last run having ended badly, and the diagnostics a user can send with a bug report.
--
--   Unseen(names, seen) -> the names not in `seen` (pure)
--   NewReports() -> list of crash report file names (faf_crash_*.txt next to the exe) that this user folder has not seen yet
--   MarkSeen(list)                  remembers them (settings `crashSeen`), so each report is offered once
--   ReportPath(name)                absolute path of a report
--   NoteAutosave(mapName) / ClearAutosave() / PendingAutosave() -> { map, time } | nil
--                                   an autosave exists that the user has not saved or discarded: offered at the next start (maps.lua keeps this current)
--   Diagnostics() -> text           version, paths, settings, the open map, monitors, the tail of the log and the newest crash report
--   Root() / BinDir()               the editor installation folder (the one that holds `bin` and `editor`) and its `bin`
--
-- The engine writes `faf_crash_<date>_<time>.txt` and `.dmp` into its working folder when it dies; the launcher (FAFStudio.cmd) shows a message with the report's
-- path when the program ends that way, and this module offers the same, plus the autosave, at the next start.
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')
local Version = import('/lua/editor/version.lua')

local function Norm(p) return (string.gsub(p or '', '\\', '/')) end

local root = false

--- The installation folder: the editor's own Lua files are found through the virtual file system, and `editor/lua/editor/...` sits under it.
function Root()
    if root then return root end
    local disk = ed_vfs_to_disk('/lua/editor/version.lua')
    if disk then
        disk = Norm(disk)
        local i = string.find(disk, '/editor/lua/editor/', 1, true)
        if i then
            root = string.sub(disk, 1, i - 1)
            -- the engine's paths come as <root>/bin/../editor/...: fold the '..' away
            local n = 1
            while n > 0 do root, n = string.gsub(root, '/[^/]+/%.%.', '', 1) end
            return root
        end
    end
    root = ''
    return root
end

function BinDir()
    local r = Root()
    if r == '' then return '.' end
    return r .. '/bin'
end

-- ---- crash reports -----------------------------------------------------------------------------------------------------------------------

local function Reports()
    local stamps = ed_dir_stamps(BinDir(), 'txt') or {}
    local names = {}
    for name, _ in stamps do
        if string.find(name, '^faf_crash_%d+_%d+%.txt$') then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

function ReportPath(name)
    return BinDir() .. '/' .. name
end

--- The names in `names` that are not in `seen`.
function Unseen(names, seen)
    local known = {}
    for _, n in seen do known[n] = true end
    local fresh = {}
    for _, n in names do
        if not known[n] then table.insert(fresh, n) end
    end
    return fresh
end

function NewReports()
    local seen = UserData.Get('crashSeen', false)
    if type(seen) ~= 'table' then
        -- the first start with this user folder: what is on disk already is history, not news
        UserData.Set('crashSeen', Reports())
        return {}
    end
    return Unseen(Reports(), seen)
end

function MarkSeen(list)
    local seen = UserData.Get('crashSeen', {})
    local all = {}
    for _, n in seen do table.insert(all, n) end
    for _, n in list do table.insert(all, n) end
    -- the list stays short: only the newest 60 names matter
    while table.getn(all) > 60 do table.remove(all, 1) end
    UserData.Set('crashSeen', all)
    UserData.Flush()
end

-- ---- autosave marker ---------------------------------------------------------------------------------------------------------------------

function NoteAutosave(mapName)
    UserData.Set('autosave', { map = mapName or '', time = GetSystemTimeSeconds() })
    UserData.Flush()
end

function ClearAutosave()
    if UserData.Get('autosave', false) then
        UserData.Set('autosave', false)
        UserData.Flush()
    end
end

function PendingAutosave()
    local a = UserData.Get('autosave', false)
    if type(a) == 'table' then return a end
    return nil
end

-- ---- diagnostics -------------------------------------------------------------------------------------------------------------------------

--- The last `n` lines of a text file ('' when there is none).
local function Tail(path, n)
    local text = ed_read_file(path)
    if not text then return '' end
    local lines = {}
    for line in string.gfind(text, '[^\r\n]+') do
        table.insert(lines, line)
        if table.getn(lines) > n * 2 then table.remove(lines, 1) end
    end
    while table.getn(lines) > n do table.remove(lines, 1) end
    return table.concat(lines, '\n')
end

local function Head(path, n)
    local text = ed_read_file(path)
    if not text then return '' end
    local lines = {}
    for line in string.gfind(text, '[^\r\n]+') do
        table.insert(lines, line)
        if table.getn(lines) >= n then break end
    end
    return table.concat(lines, '\n')
end

function LogPath()
    local ok, arg = pcall(function() return GetCommandLineArg('/log', 1) end)
    return ok and arg and arg[1] or nil
end

function Diagnostics()
    local out = {}
    local function Add(text) table.insert(out, text) end
    Add('== ' .. Version.Text())
    Add('time: ' .. tostring(GetSystemTimeSeconds()) .. ' s since the machine started')
    Add('installation: ' .. tostring(Root()))
    Add('user folder: ' .. tostring(UserData.Dir()))
    local ok, Skin = pcall(import, '/lua/editor/gui/skin.lua')
    if ok then Add('UI scale: ' .. tostring(Skin.scale)) end
    local okShell, shell = pcall(import, '/lua/editor/gui/shell.lua')
    if okShell and shell.S then
        Add('workspace: ' .. tostring(shell.S.current))
        local n = 0
        for _ in shell.S.popouts do n = n + 1 end
        Add('pop-out windows: ' .. n)
    end
    local okMaps, Maps = pcall(import, '/lua/editor/maps.lua')
    if okMaps then
        local okInfo, info = pcall(Maps.Info)
        if okInfo and info then
            Add(string.format('map: %s (%s), unsaved changes: %s', tostring(info.name), tostring(info.type), tostring(Maps.Dirty())))
        end
    end
    local okMods, Mods = pcall(import, '/lua/editor/mods.lua')
    if okMods then
        local okA, set = pcall(Mods.ActiveSet)
        if okA and type(set) == 'table' then
            local all = Mods.All()
            local names = {}
            for uid, _ in set do
                local m = all[uid]
                table.insert(names, (m and m.name) or uid)
            end
            table.sort(names)
            Add('mods: ' .. table.concat(names, ', '))
        end
    end
    if rawget(_G, 'ed_monitor_count') then
        local n = ed_monitor_count()
        for i = 1, n do
            local x, y, w, h, wx, wy, ww, wh, primary = ed_monitor_info(i)
            Add(string.format('monitor %d: %dx%d at %d,%d%s', i, w or 0, h or 0, x or 0, y or 0, (primary == 1 or primary == true) and ' (primary)' or ''))
        end
    end
    local pending = PendingAutosave()
    if pending then Add('unsaved autosave of: ' .. tostring(pending.map)) end
    local settings = ed_read_file(UserData.Path('settings.lua'))
    if settings and settings ~= '' then
        Add('')
        Add('-- settings.lua')
        Add(settings)
    end
    local reports = Reports()
    if table.getn(reports) > 0 then
        local newest = reports[table.getn(reports)]
        Add('')
        Add('-- newest crash report: ' .. newest)
        Add(Head(ReportPath(newest), 40))
    end
    local log = LogPath()
    if log then
        Add('')
        Add('-- log tail (' .. log .. ')')
        Add(Tail(log, 120))
    end
    return table.concat(out, '\n')
end
