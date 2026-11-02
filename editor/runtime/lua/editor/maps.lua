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

-- The blank templates (scripts/ed_make_blank_map.py): the map sizes the game's terrain supports are powers of two, 51.2 samples to the kilometre (2.5 km = 128 ... 80 km = 4096).
Sizes = {
    { label = '5 x 5 km',   km = 5,  samples = 256,  template = '/maps/editor_blank/editor_blank_scenario.lua' },
    { label = '10 x 10 km', km = 10, samples = 512,  template = '/maps/editor_blank_512/editor_blank_512_scenario.lua' },
    { label = '20 x 20 km', km = 20, samples = 1024, template = '/maps/editor_blank_1024/editor_blank_1024_scenario.lua' },
    { label = '40 x 40 km', km = 40, samples = 2048, template = '/maps/editor_blank_2048/editor_blank_2048_scenario.lua' },
    { label = '80 x 80 km', km = 80, samples = 4096, template = '/maps/editor_blank_4096/editor_blank_4096_scenario.lua' },
}

--- The template for a map of `km` x `km` (a fraction is fine: 2.5): index into Sizes (or 0 for 2.5 km, which has a template of its own), and its edge in samples. nil and a message
--- when the size is not one the terrain supports.
function SizeForKm(km)
    km = tonumber(km)
    if not km or km <= 0 then return nil, 'type a size in kilometres, for example 2.5 or 10' end
    local samples = math.floor(km * 51.2 + 0.5)
    local n = 128
    while n < samples do n = n * 2 end
    if n ~= samples or samples > 4096 then
        return nil, 'the terrain supports 2.5, 5, 10, 20, 40 and 80 km (128 to 4096 samples a side)'
    end
    if samples == 128 then return 0, 128 end
    for i, s in Sizes do
        if s.samples == samples then return i, samples end
    end
    return nil, 'no template for this size'
end

local PENDING = 'editor_pending_map.txt'
local TEMPLATE_NAMES = { ['Editor blank world'] = true }

-- ---- any size: the terrain of the next power of two, the playable area cut to the size asked for -----------------------------------------------------------------------------
--
-- The terrain can only be 128 ... 4096 samples a side (powers of two), but the PLAYABLE AREA (AREA_1, playable.lua) is any rectangle in it: that is how maps of 7.5 x 12 km or
-- 15 x 15 km are made. A custom map is a blank template of the smallest terrain that holds the size, with the playable area in the middle of it and the start position in the
-- middle of the area.

SAMPLES_PER_KM = 51.2
MIN_KM, MAX_KM = 1, 80

local function TemplateOf(samples)
    if samples == 128 then return '/maps/editor_blank_128/editor_blank_128_scenario.lua' end
    for _, s in Sizes do
        if s.samples == samples then return s.template end
    end
end

--- The plan for a map of width x height kilometres: { terrain (samples a side), template, w, h (units of the playable area), rect = { x0, z0, x1, z1 } | false (the whole terrain),
--- used (share of the terrain that is playable), whole = true when the size needs no playable area }; nil and a message for a size the terrain cannot hold.
function CustomPlan(widthKm, heightKm)
    local wk, hk = tonumber(widthKm), tonumber(heightKm)
    if not wk or not hk then return nil, 'type the width and the height in kilometres, for example 7.5' end
    if wk < MIN_KM or hk < MIN_KM then return nil, 'the smallest map is ' .. MIN_KM .. ' km a side' end
    if wk > MAX_KM or hk > MAX_KM then return nil, 'the terrain holds at most ' .. MAX_KM .. ' km a side' end
    local w, h = math.floor(wk * SAMPLES_PER_KM + 0.5), math.floor(hk * SAMPLES_PER_KM + 0.5)
    local terrain = 128
    while terrain < math.max(w, h) do terrain = terrain * 2 end
    local plan = { terrain = terrain, template = TemplateOf(terrain), w = w, h = h, used = (w * h) / (terrain * terrain) }
    if w == terrain and h == terrain then
        plan.whole, plan.rect = true, false
    else
        local x0, z0 = math.floor((terrain - w) / 2), math.floor((terrain - h) / 2)
        plan.rect = { x0, z0, x0 + w, z0 + h }
    end
    return plan
end

--- A new map of width x height km (fractions allowed) with the name. Returns true, or nil and a message.
function NewCustom(widthKm, heightKm, name)
    local plan, why = CustomPlan(widthKm, heightKm)
    if not plan then return nil, why end
    if not TemplateReady(plan.template) then
        return nil, 'the blank map for ' .. plan.terrain .. ' samples is not installed: run  python scripts/studio.py generate'
    end
    local text = 'name=' .. (name or 'My map') .. '\n'
    if plan.rect then text = text .. 'playable=' .. plan.rect[1] .. ',' .. plan.rect[2] .. ',' .. plan.rect[3] .. ',' .. plan.rect[4] .. '\n' end
    ed_write_file(PENDING, text)
    import('/lua/editor/control.lua').LoadMap(plan.template)
    return true
end

--- A square map of `km` km a side.
function NewKm(km, name)
    return NewCustom(km, km, name)
end


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

-- DiskFindFiles over '/maps' walks the whole file tree of the game (hundreds of maps in the archives): one answer is kept for a second, so the calls one dialog makes
-- one after the other (ListUser = List + UserMapsDir, the release and resize dialogs) share a single walk. A map saved a moment ago shows up after that second.
local scenarioFiles, scenarioFilesAt = false, -100

local function ScenarioFiles()
    local now = GetSystemTimeSeconds()
    if not scenarioFiles or now - scenarioFilesAt > 1 then
        scenarioFiles = DiskFindFiles('/maps', '*_scenario.lua') or {}
        scenarioFilesAt = now
    end
    return scenarioFiles
end

--- Every scenario file of the game data (and mounted mods / user maps).
function List()
    local list = {}
    local files = ScenarioFiles()
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
    local files = ScenarioFiles()
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

--- Is the blank map file of a template scenario installed? (The 2.5 and 80 km ones only exist after `python scripts/studio.py generate`.)
function TemplateReady(scenarioPath)
    local ok, info = pcall(DiskGetFileInfo, (string.gsub(scenarioPath, '_scenario%.lua$', '.scmap')))
    return ok and info ~= nil and info ~= false
end

function New(sizeIndex, name)
    local size = Sizes[sizeIndex] or Sizes[1]
    if not TemplateReady(size.template) then
        return nil, 'the blank map for ' .. size.label .. ' is not installed: run  python scripts/studio.py generate'
    end
    ed_write_file(PENDING, 'name=' .. (name or 'My map') .. '\n')
    import('/lua/editor/control.lua').LoadMap(size.template)
    return true
end

freshMap = false

--- True once after a session was started by File > New.
function TakeFresh()
    local f = freshMap
    freshMap = false
    return f
end

--- Called once the document exists after a (re)start of the session: takes over what New / Open left in the pending file.
function ApplyPending(doc)
    local text = ed_read_file(PENDING)
    if not text or text == '' then return end
    ed_write_file(PENDING, '')
    for key, value in string.gfind(text, '(%w+)=([^\n]*)') do
        if key == 'name' then
            freshMap = true             -- File > New: Map.Load gives the blank map its texture set (texsets.lua)
            doc.info.name = value
            saveDir, saveStem = false, false
        elseif key == 'dir' then
            saveDir = value
        elseif key == 'stem' then
            saveStem = value
        elseif key == 'playable' then
            -- a custom size: the playable area in the middle of the terrain, the start position in the middle of the area
            local _, _, x0, z0, x1, z1 = string.find(value, '^(%d+),(%d+),(%d+),(%d+)')
            if x0 then
                x0, z0, x1, z1 = tonumber(x0), tonumber(z0), tonumber(x1), tonumber(z1)
                doc.save.Areas = doc.save.Areas or {}
                doc.save.Areas.AREA_1 = { rectangle = { x0, z0, x1, z1, type = 'RECTANGLE' } }
                local markers = doc.save.MasterChain and doc.save.MasterChain._MASTERCHAIN_ and doc.save.MasterChain._MASTERCHAIN_.Markers
                local start = markers and markers.ARMY_1
                if start and start.position then
                    start.position = Map.MakeVec3(math.floor((x0 + x1) / 2), start.position[2], math.floor((z0 + z1) / 2))
                end
            end
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
    AutosaveSaved()
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
    -- (UserMapsDir has no trailing slash: without one the dialog got '...\\mapsMy_map' and opened the folder above with a file name starting with 'maps')
    local initial = base and ((string.gsub((string.gsub(base, '[/\\]+$', '')), '/', '\\')) .. '\\' .. suggestion) or suggestion
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
AutosaveQuiet = 2          -- seconds without an edit and without a mouse movement before an autosave starts
AutosaveGrace = 120        -- an autosave this many seconds overdue starts although the user keeps working (never in the middle of a stroke or drag)
AutosaveSlice = 0.004      -- seconds of serialising per frame
local lastVersion = 0
local lastTime = false

-- What the autosave waits for. The save itself is one native call (ed_map_save, 150-200 ms on a 1025 map) that cannot be sliced, so it is started when the user has stopped (no edit, no mouse
-- movement for AutosaveQuiet seconds, no brush stroke or drag), and the part that is Lua, the text of `_save.lua` (0.3 s and more on a mission map with thousands of units), is made ahead in
-- slices of AutosaveSlice seconds over many frames (a coroutine resumed by a thread). If the document changes while that runs, the text is dropped and made again later.
local seenVersion, seenAt, seenX, seenY = -1, 0, false, false
local job = false          -- { co, version, doc, calls, every (pace calls per slice), slices, started }

--- True while a brush stroke, an area drag or a gizmo drag is going on.
local function Busy()
    local busy = false
    pcall(function()
        local State = import('/lua/editor/ui.lua').State
        if State.dragPointer or State.strokeTarget or State.areaStart then busy = true end
        if import('/lua/editor/gizmo.lua').Dragging then busy = true end
    end)
    return busy
end

--- Notes edits and mouse movement (called at every tick): `seenAt` is when the user last did something.
local function Watch(now, version)
    if version ~= seenVersion then
        seenVersion = version
        seenAt = now
    end
    local x, y
    if rawget(_G, 'GetMouseScreenPos') then
        local pos = GetMouseScreenPos()
        if pos then x, y = pos[1] or pos.x, pos[2] or pos.y end
    end
    if x ~= seenX or y ~= seenY then
        seenX, seenY = x, y
        seenAt = now
    end
end

local function Written(scenario, why, version)
    if scenario then
        lastVersion = version
        LOG('EDITOR maps: autosaved to ' .. AUTOSAVE_DIR)
        -- remembered in the user folder: if the editor is closed or dies before this is saved, the next start offers it (crash.lua)
        pcall(function() import('/lua/editor/crash.lua').NoteAutosave(Map.Doc.info and Map.Doc.info.name) end)
    else
        LOG('EDITOR maps: autosave failed: ' .. tostring(why))
    end
end

--- The job's text is ready: write the map (the native save and the small files) unless the document changed meanwhile.
local function FinishJob(text)
    local j = job
    job = false
    local History = import('/lua/editor/history.lua')
    if not Map.Doc or Map.Doc ~= j.doc then return end
    if History.Version ~= j.version then
        LOG('EDITOR maps: autosave text dropped (the map changed while it was made); it is made again when the user stops')
        return
    end
    if Busy() then return end
    lastTime = GetSystemTimeSeconds()
    local t0 = GetSystemTimeSeconds()
    local scenario, why = Map.SaveAs(AUTOSAVE_DIR, AUTOSAVE_STEM, { saveText = text })
    LOG(string.format('EDITOR maps: autosave: text made in %d slices over %.1f s, written in %.0f ms', j.slices, t0 - j.started, (GetSystemTimeSeconds() - t0) * 1000))
    Written(scenario, why, j.version)
end

local function DriveJob()
    while job do
        if Busy() then
            WaitFrames(10)
        else
            local t0 = GetSystemTimeSeconds()
            job.calls = 0
            local ok, text = coroutine.resume(job.co)
            -- (the clock reads nil inside a coroutine in this engine: the slice length is counted in pace calls and tuned from the time one resume took)
            local dt = GetSystemTimeSeconds() - t0
            if dt <= 0.0001 then
                job.every = math.min(4096, job.every * 2)
            else
                job.every = math.max(1, math.min(4096, math.floor((job.every + job.every * AutosaveSlice / dt) / 2 + 0.5)))
            end
            if not ok then
                LOG('EDITOR maps: autosave text failed: ' .. tostring(text))
                job = false
                return
            end
            if coroutine.status(job.co) == 'dead' then
                FinishJob(text)
                return
            end
            job.slices = job.slices + 1
            WaitFrames(1)
        end
    end
end

local function StartJob(version)
    Map.PrepareSave()
    local started = GetSystemTimeSeconds()
    local function Pace()
        job.calls = job.calls + 1
        if job.calls >= job.every then
            job.calls = 0
            coroutine.yield()
        end
    end
    job = { co = coroutine.create(function() return Map.SaveText(Pace) end), version = version, doc = Map.Doc, calls = 0, every = 8, slices = 0, started = started }
    ForkThread(DriveJob)
end

--- Writes the open map to the autosave folder when it changed since the last autosave and AutosaveSeconds have passed. Called from the shell's tick (four times a second).
function AutosaveTick()
    local History = import('/lua/editor/history.lua')
    local now = GetSystemTimeSeconds()
    if not lastTime then lastTime = now return end
    Watch(now, History.Version)
    if job then return end
    if now - lastTime < AutosaveSeconds or History.Version == lastVersion then return end
    if not Map.Doc or Busy() then return end
    local overdue = now - lastTime - AutosaveSeconds
    if now - seenAt < AutosaveQuiet and overdue < AutosaveGrace then return end
    if rawget(_G, 'ForkThread') and rawget(_G, 'coroutine') and Map.SaveText then
        StartJob(History.Version)
        return
    end
    -- no threads (a test harness): the whole save at once
    lastTime = now
    local version = History.Version
    local scenario, why = Map.SaveAs(AUTOSAVE_DIR, AUTOSAVE_STEM)
    Written(scenario, why, version)
end

--- A manual save has written everything: the autosave has nothing to add until the map changes again, and a text being made for it is dropped.
function AutosaveSaved()
    job = false
    lastVersion = import('/lua/editor/history.lua').Version
    lastTime = GetSystemTimeSeconds()
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
