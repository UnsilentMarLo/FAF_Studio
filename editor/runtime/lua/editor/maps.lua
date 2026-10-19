-- The map's life cycle: new from a template, open from the maps the game knows, save and save as, map info.
--
--   Sizes                 the blank templates (editor/runtime/maps/editor_blank*, made by scripts/ed_make_blank_map.py)
--   New(sizeIndex, name)  opens a blank map of that size; `name` becomes the map's name
--   Open(scenarioPath)    opens a map ('/maps/<folder>/<stem>_scenario.lua')
--   List()                every scenario file the game data knows: { path, folder, name }, sorted by name
--   Save()                writes to where the map was saved before; asks (Save as) when it was not
--   SaveAs()              the common dialog; the map is written to <picked folder>/<stem>.v0001/ (a folder named after the stem is used as it is)
--   Info() / SetInfo(t)   name, description, author of the map's scenario file
--   UserMapsDir()         the folder the game loads user maps from (derived from a mounted user map), or false
--
-- The editor reopens a map through a restart of the session (control.LoadMap), so what must survive it (the name of a new map, where the
-- map is saved) goes through a small file next to the queue file.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')

Sizes = {
    { label = '5 x 5 km  (256)',    template = '/maps/editor_blank/editor_blank_scenario.lua' },
    { label = '10 x 10 km  (512)',  template = '/maps/editor_blank_512/editor_blank_512_scenario.lua' },
    { label = '20 x 20 km  (1024)', template = '/maps/editor_blank_1024/editor_blank_1024_scenario.lua' },
}

local PENDING = 'editor_pending_map.txt'
local TEMPLATE_NAMES = { ['Editor blank world'] = true }

saveDir = false      -- where the open map was last saved / opened from (disk folder)
saveStem = false

local function Norm(path)
    return (string.gsub(path or '', '\\', '/'))
end

local function Basename(path)
    return (string.gsub((string.gsub(Norm(path), '/+$', '')), '^.*/', ''))
end

local function Dirname(path)
    local p = Norm(path)
    local d = string.gsub(p, '/[^/]*$', '')
    if d == p then return '' end
    return d
end

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR maps: ' .. text)
end

--- Characters a folder or file stem may keep.
function Sanitize(name)
    local s = string.gsub(name or '', '[^%w_%- ]', '')
    s = string.gsub(s, '^%s+', '')
    s = string.gsub(s, '%s+$', '')
    s = string.gsub(s, '%s+', '_')
    if s == '' then s = 'my_map' end
    return s
end

--- Every scenario file of the game data (and mounted mods / user maps).
function List()
    local list = {}
    local files = DiskFindFiles('/maps', '*_scenario.lua') or {}
    for _, f in files do
        local folder = Basename(Dirname(f))
        local stem = string.gsub(Basename(f), '_scenario%.lua$', '')
        table.insert(list, { path = f, folder = folder, name = stem })
    end
    table.sort(list, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return list
end

--- The maps in the user's maps folder (where Save writes them), sorted by name: the start screen's "My maps".
function ListUser()
    local base = UserMapsDir()
    local list = {}
    if not base then return list end
    base = string.lower(Norm(base))
    for _, m in List() do
        local disk = ed_vfs_to_disk(m.path)
        if disk and string.find(string.lower(Norm(disk)), base, 1, true) == 1 then table.insert(list, m) end
    end
    return list
end

function UserMapsDir()
    local files = DiskFindFiles('/maps', '*_scenario.lua') or {}
    for _, f in files do
        local disk = ed_vfs_to_disk(f)
        if disk then
            local d = string.lower(Norm(disk))
            local i = string.find(d, '/my games/', 1, true)
            if i and string.find(d, '/maps/', i, true) then
                local cut = string.find(d, '/maps/', i, true)
                return string.sub(Norm(disk), 1, cut + 4)
            end
        end
    end
    return false
end

-- ---- open / new ---------------------------------------------------------------------------------------------------------------------

function Open(scenarioPath)
    -- a path the game does not know would leave the session restart in a dead front end ("Map scenario file does not exist")
    local okInfo, info = pcall(DiskGetFileInfo, scenarioPath)
    if okInfo and not info then
        Say('map not found: ' .. tostring(scenarioPath))
        return
    end
    -- a scenario whose .scmap is missing makes the engine's map loader abort, which is a fatal assertion (SessionLoader.cpp:320) and then a crash
    -- in the session launch (one of the 414 maps: setons_mini_clutch_aix): refuse it here
    do
        local env = setmetatable({}, { __index = function(t, k) return rawget(_G, k) or function(x) return x end end })
        local okDo = pcall(doscript, scenarioPath, env)
        local mapFile = okDo and env.ScenarioInfo and env.ScenarioInfo.map
        if mapFile then
            local okMap, fileInfo = pcall(DiskGetFileInfo, mapFile)
            if okMap and not fileInfo then
                Say('cannot open: the map file ' .. tostring(mapFile) .. ' is missing')
                return
            end
        end
    end
    pcall(function() import('/lua/editor/recent.lua').Add(scenarioPath) end)
    -- remember where the map lives so Save writes back to it
    local disk = ed_vfs_to_disk(scenarioPath)
    local pending = ''
    if disk then
        local stem = string.gsub(Basename(disk), '_scenario%.lua$', '')
        pending = 'dir=' .. Dirname(disk) .. '\nstem=' .. stem .. '\n'
    end
    ed_write_file(PENDING, pending)
    import('/lua/editor/control.lua').LoadMap(scenarioPath)
end

function New(sizeIndex, name)
    local size = Sizes[sizeIndex] or Sizes[1]
    ed_write_file(PENDING, 'name=' .. (name or 'My map') .. '\n')
    import('/lua/editor/control.lua').LoadMap(size.template)
end

--- Called once the document exists after a (re)start of the session: takes over what New / Open left in the pending file.
function ApplyPending(doc)
    local text = ed_read_file(PENDING)
    if not text or text == '' then return end
    ed_write_file(PENDING, '')
    for key, value in string.gfind(text, '(%w+)=([^\n]*)') do
        if key == 'name' then
            doc.info.name = value
            saveDir, saveStem = false, false
        elseif key == 'dir' then
            saveDir = value
        elseif key == 'stem' then
            saveStem = value
        elseif key == 'resize' then
            doc.resizePayload = value        -- resize.lua applies the heights, masks, props and decals of a resized map (Map.Load calls it)
        end
    end
end

-- ---- save ---------------------------------------------------------------------------------------------------------------------------

local backedUp = {}        -- folders already backed up in this editor session

--- Copies the files of a map folder that is about to be overwritten to <maps folder>/../editor_backups/<folder>/<n>/ (once per folder per session: the first save
--- is the one that replaces what the map was opened with). Never overwrites an older backup. The backups sit outside the maps folder because the game and the
--- Open dialog list every *_scenario.lua below it.
function Backup(dir, stem)
    if backedUp[dir] then return false end
    backedUp[dir] = true
    local files = { '.scmap', '_scenario.lua', '_save.lua', '_script.lua', '_editor.lua' }
    local any = false
    for _, ext in files do
        if ed_file_exists(dir .. '/' .. stem .. ext) then any = true end
    end
    if not any then return false end
    local root = Dirname(Dirname(dir)) .. '/editor_backups/' .. Basename(dir)
    local n = 1
    while ed_file_exists(root .. '/' .. string.format('%04d', n) .. '/' .. stem .. '.scmap') or
          ed_file_exists(root .. '/' .. string.format('%04d', n) .. '/' .. stem .. '_scenario.lua') do
        n = n + 1
    end
    local target = root .. '/' .. string.format('%04d', n)
    for _, ext in files do
        local data = ed_read_file(dir .. '/' .. stem .. ext)
        if data then ed_write_file(target .. '/' .. stem .. ext, data) end
    end
    Say('backup of the previous files: ' .. target)
    return target
end

local cleanVersion = 0      -- History.Version when the map was last saved (or opened)

--- True when the map changed since it was opened or last saved (every edit, undo and redo bumps History.Version).
function Dirty()
    return import('/lua/editor/history.lua').Version ~= cleanVersion
end

function MarkClean()
    cleanVersion = import('/lua/editor/history.lua').Version
    pcall(function() import('/lua/editor/crash.lua').ClearAutosave() end)
end

local function Do(dir, stem)
    Backup(dir, stem)
    local scenario, why = Map.SaveAs(dir, stem, { preview = true })
    if scenario then
        saveDir, saveStem = dir, stem
        MarkClean()
        pcall(function() import('/lua/editor/recent.lua').Add(scenario) end)
        import('/lua/editor/ui.lua').State.savedAs = scenario
        Say('saved ' .. scenario)
        return scenario
    end
    Say('save failed: ' .. tostring(why))
    return nil, why
end

--- Saves to a given folder (a disk path of the form <maps>/<stem>.v0001) without asking; the map is saved there from now on. Used by Map > Resize.
function SaveTo(dir, stem)
    backedUp[dir] = true          -- a folder just made by the editor has nothing to back up
    return Do(dir, stem)
end

--- Opens the map folder `dir` (disk path; its scenario <stem>_scenario.lua is mounted at /maps/<folder>) and tells the new session about it: `extra` is more lines of the
--- pending file ('key=value' lines). Save writes back to that folder.
function OpenFolder(dir, stem, extra)
    dir = Norm(dir)
    local mount = '/maps/' .. string.lower(Basename(dir))
    ed_vfs_mount(dir, mount)
    ed_write_file(PENDING, 'dir=' .. dir .. '\nstem=' .. stem .. '\n' .. (extra or ''))
    import('/lua/editor/control.lua').LoadMap(mount .. '/' .. stem .. '_scenario.lua')
end

function SaveAs()
    if not Map.Doc then Map.Load() end
    if not Map.Doc then Say('no map to save') return nil end
    local suggestion = Sanitize(Map.Doc.info.name or 'my_map')
    local base = UserMapsDir()
    local initial = base and (string.gsub(base, '/', '\\') .. suggestion) or suggestion
    local path = ed_file_dialog(true, 'Save map as', 'Supreme Commander map (*.scmap)|*.scmap|All files|*.*', initial)
    if not path then return nil end
    local stem = Sanitize(string.gsub(Basename(path), '%.[^%.]*$', ''))
    stem = string.gsub(stem, '_scenario$', '')
    local dir = Dirname(path)
    local last = Basename(dir)
    local escaped = string.gsub(string.lower(stem), '(%W)', '%%%1')
    if not string.find(string.lower(last), '^' .. escaped .. '%.v%d+$') then
        dir = dir .. '/' .. stem .. '.v0001'
    end
    if TEMPLATE_NAMES[Map.Doc.info.name or ''] or not Map.Doc.info.name then
        Map.Doc.info.name = string.gsub(stem, '_', ' ')
    end
    return Do(dir, stem)
end

--- Saves to where the map came from or was saved to last; asks when it is new.
function Save()
    if saveDir and saveStem then
        return Do(saveDir, saveStem)
    end
    return SaveAs()
end

-- ---- autosave and recovery --------------------------------------------------------------------------------------------------------

local AUTOSAVE_DIR = '../mapout/_autosave.v0001'
local AUTOSAVE_STEM = '_autosave'
AutosaveSeconds = 300
local lastVersion = 0
local lastTime = false

--- Writes the open map to the autosave folder when it changed since the last autosave and AutosaveSeconds have passed. Called from the shell's tick.
function AutosaveTick()
    local History = import('/lua/editor/history.lua')
    local now = GetSystemTimeSeconds()
    if not lastTime then lastTime = now return end
    if now - lastTime < AutosaveSeconds or History.Version == lastVersion then return end
    lastTime = now
    lastVersion = History.Version
    if not Map.Doc then return end
    local scenario, why = Map.SaveAs(AUTOSAVE_DIR, AUTOSAVE_STEM)
    if scenario then
        LOG('EDITOR maps: autosaved to ' .. AUTOSAVE_DIR)
        -- remembered in the user folder: if the editor is closed or dies before this is saved, the next start offers it (crash.lua)
        pcall(function() import('/lua/editor/crash.lua').NoteAutosave(Map.Doc.info and Map.Doc.info.name) end)
    else
        LOG('EDITOR maps: autosave failed: ' .. tostring(why))
    end
end

--- The autosave as a scenario path when there is one.
function AutosavePath()
    if ed_file_exists(AUTOSAVE_DIR .. '/' .. AUTOSAVE_STEM .. '_scenario.lua') then
        return '/maps/_autosave.v0001/' .. AUTOSAVE_STEM .. '_scenario.lua'
    end
    return false
end

--- Opens the autosave (File > Recover autosave).
function Recover()
    local path = AutosavePath()
    if not path then
        Say('there is no autosave')
        return false
    end
    ed_write_file(PENDING, '')
    pcall(function() import('/lua/editor/crash.lua').ClearAutosave() end)
    import('/lua/editor/control.lua').LoadMap(path)
    return true
end

-- ---- info ---------------------------------------------------------------------------------------------------------------------------

function Info()
    if not Map.Doc then Map.Load() end
    local info = Map.Doc and Map.Doc.info or {}
    return { name = info.name or '', description = info.description or '', author = info.author or '', size = info.size, type = info.type or 'skirmish',
             version = tonumber(info.map_version) or 1, norush = tonumber(info.norushradius) or 0, starts = info.starts ~= false }
end

function SetInfo(t)
    if not Map.Doc then return false end
    for _, key in { 'name', 'description', 'author', 'type' } do
        if t[key] ~= nil then Map.Doc.info[key] = t[key] end
    end
    -- scenario fields with their file names: map version, no-rush radius, "starts" (the lobby places the armies on the start positions)
    if t.version ~= nil then Map.Doc.info.map_version = math.max(1, math.floor(tonumber(t.version) or 1)) end
    if t.norush ~= nil then Map.Doc.info.norushradius = math.max(0, tonumber(t.norush) or 0) end
    if t.starts ~= nil then Map.Doc.info.starts = t.starts and true or false end
    return true
end
