-- Mod selection of the editor session.
--
--   editor mods   mod_info.lua sets `editor_mod = true`: always active (UI and sim state), not shown in the mod
--                 browser. They extend the editor by hooking its Lua files (hook/lua/editor/*.lua).
--   map mods      every other mod that is not `ui_only`: held back until the map maker loads it in the browser.
--   UI mods       `ui_only` mods that are not editor mods: never active in the editor.
--
-- The selection is a list of mod uids in `editor_mods.txt` (one per line, next to the exe). A map folder carries
-- its own copy in `<stem>_editor.lua`, written by Map.SaveAs and read again when the map is opened, so a map
-- reopens with the mods its maker loaded. Changing the selection needs a new session (mods are applied at
-- session start); ui.lua reopens the map from an autosave.
--
-- Lua 5.0 dialect. The functions here run in the UI state only; the sim state gets its mods from the session.

local SELECTION_FILE = 'editor_mods.txt'
local TRIAL_FILE = 'editor_mods_trial.txt'

local function Mods()
    return import('/lua/mods.lua')
end

--- uid -> ModInfo of every mod on disk.
function All()
    return Mods().AllMods()
end

--- ModInfo list of the editor mods (always active), sorted by name.
function EditorMods()
    local list = {}
    for _, mod in All() do
        if mod.editor_mod then
            table.insert(list, mod)
        end
    end
    table.sort(list, function(a, b) return string.lower(tostring(a.name)) < string.lower(tostring(b.name)) end)
    return list
end

--- ModInfo list of the mods the map maker can load, sorted by name.
function Browsable()
    local list = {}
    for _, mod in All() do
        if not mod.editor_mod and not mod.ui_only and mod.selectable ~= false then
            table.insert(list, mod)
        end
    end
    table.sort(list, function(a, b) return string.lower(tostring(a.name)) < string.lower(tostring(b.name)) end)
    return list
end

--- The map maker's selection (uid set), from the selection file. Unknown or no longer loadable uids are dropped.
function GetSelection()
    local set = {}
    local text = ed_read_file(SELECTION_FILE)
    if not text then
        return set
    end
    local all = All()
    for line in string.gfind(text, '[^\r\n]+') do
        local mod = all[line]
        if mod and not mod.editor_mod and not mod.ui_only then
            set[line] = true
        end
    end
    return set
end

--- Writes the selection (uid set).
function SetSelection(set)
    local lines = {}
    for uid, on in set do
        if on then
            table.insert(lines, uid)
        end
    end
    table.sort(lines)
    ed_write_file(SELECTION_FILE, table.concat(lines, '\n') .. '\n')
end

--- Adds the mods the selected ones require (recursively) to a copy of `set`.
function WithDependencies(set)
    local result = {}
    for uid, on in set do
        if on then
            result[uid] = true
            local deps = Mods().GetDependencies(uid)
            if deps and deps.requires then
                for required in deps.requires do
                    result[required] = true
                end
            end
        end
    end
    return result
end

--- The set of active mod uids of the editor session (what mods.GetSelectedMods answers in /editor).
function ActiveSet()
    local set = {}
    for uid, mod in All() do
        if mod.editor_mod then
            set[uid] = true
        end
    end
    for uid in WithDependencies(GetSelection()) do
        set[uid] = true
    end
    return set
end

--- Uids of the active mods that came in only as a dependency of a selected one.
function DependencyOnly(set)
    local extra = {}
    for uid in WithDependencies(set) do
        if not set[uid] then
            extra[uid] = true
        end
    end
    return extra
end

-- ---- failed mod loads ------------------------------------------------------------------------------------------
-- A mod can break blueprint loading or the sim start; the session then never comes up and the editor has to be
-- restarted. ApplyMods (ui.lua) writes the previous selection to the trial file before it reopens the map and
-- control.Start() clears it once a session is running. A trial file still there at the next launch means the
-- last load failed: the previous selection is restored instead of the map's own mod list.

function BeginTrial(previous)
    local lines = { 'trial' }
    for uid, on in previous do
        if on then
            table.insert(lines, uid)
        end
    end
    ed_write_file(TRIAL_FILE, table.concat(lines, '\n') .. '\n')
end

function EndTrial()
    ed_write_file(TRIAL_FILE, '')
end

--- At the first map open of a process: undo a mod load that never came up. Returns true when it did.
function RecoverAtLaunch()
    if rawget(_G, 'EdModsLaunchChecked') then
        return false
    end
    rawset(_G, 'EdModsLaunchChecked', true)
    local text = ed_read_file(TRIAL_FILE)
    if not text or text == '' then
        return false
    end
    local previous = {}
    local first = true
    for line in string.gfind(text, '[^\r\n]+') do
        if first then
            first = false
        else
            previous[line] = true
        end
    end
    SetSelection(previous)
    EndTrial()
    LOG('EDITOR: the last mod load did not start a session; the previous mod list is restored')
    return true
end

-- ---- map sidecar ---------------------------------------------------------------------------------------------

--- `<stem>_editor.lua` next to a scenario file (`/maps/x/x_scenario.lua` -> `/maps/x/x_editor.lua`).
function SidecarPath(scenarioFile)
    local path, count = string.gsub(scenarioFile, '_scenario%.lua$', '_editor.lua')
    if count == 0 then
        return nil
    end
    return path
end

local sidecarCache = false      -- path -> { stamp =, env =, info = } (see SidecarEnv below)

--- Text of the sidecar file for the current selection.
--- `pathsText` replaces the paths part (Map > Resize writes the sidecar of the resized map with the paths moved).
function SidecarText(pathsText)
    local lines = { 'version = ' .. SIDECAR_VERSION, 'EditorMods = {' }
    local uids = {}
    for uid in GetSelection() do
        table.insert(uids, uid)
    end
    table.sort(uids)
    for _, uid in uids do
        table.insert(lines, string.format('    %q,', uid))
    end
    table.insert(lines, '}')
    sidecarCache = false        -- a save changes the file: the next read looks again
    return table.concat(lines, '\n') .. '\n' .. import('/lua/editor/terraintype.lua').SidecarText() .. import('/lua/editor/mission.lua').SidecarText()
        .. import('/lua/editor/graph.lua').SidecarText()
        .. import('/lua/editor/layout.lua').SidecarText()
        .. (pathsText or import('/lua/editor/paths.lua').SidecarText())
        .. import('/lua/editor/interop.lua').SidecarText()
        .. import('/lua/editor/shaders.lua').SidecarText()
end

-- ---- reading the sidecar -------------------------------------------------------------------------------------------
-- The sidecar is one Lua file with one assignment per feature (`EditorMods`, `Mission`, `Graph` ...), read by up to eight loaders. They all go through SidecarEnv: one protected
-- read (safeload.lua: syntax and runtime errors lose only the section that has them, the original is kept as `<file>.bad`, wrong types are dropped, `version` is checked and
-- migrated), shared while the file on disk is unchanged. A broken sidecar never stops a map from opening.

SIDECAR_VERSION = 1             -- (written by SidecarText above) bumped when a section changes shape; Migrate[v](env) turns a version v file into version v + 1 (in place)
Migrate = {}                    -- (nothing changed shape yet: a file without `version` is a version 0 file and reads the same)
SidecarSchema = { EditorMods = 'table', TerrainTypeLayers = 'table', Mission = 'table', Graph = 'table', Layout = 'table', Paths = 'table', Interop = 'table', StrataAuthored = 'table' }


function SidecarOptions(extra)
    local opts = { name = 'sidecar', current = SIDECAR_VERSION, migrate = Migrate, schema = SidecarSchema }
    for k, v in extra or {} do opts[k] = v end
    return opts
end

--- The sidecar's values for the map, or nil when it has none or none can be read. `fresh` reads the file again (ApplySidecar does, at every map open); the other loaders of the
--- same open get the same table. Second result: the load info of safeload.lua (dropped sections, version, migrated).
function SidecarEnv(scenarioFile, fresh)
    local path = scenarioFile and SidecarPath(scenarioFile)
    if not path or not DiskGetFileInfo(path) then return nil end
    sidecarCache = sidecarCache or {}
    local disk = rawget(_G, 'ed_vfs_to_disk') and ed_vfs_to_disk(path)
    local stamp = disk and rawget(_G, 'ed_file_stamp') and ed_file_stamp(disk)
    local entry = sidecarCache[path]
    if entry and not fresh and stamp and entry.stamp == stamp then
        return entry.env or nil, entry.info
    end
    local env, why, info = import('/lua/editor/safeload.lua').File(path, SidecarOptions())
    if env then info = why end
    sidecarCache[path] = { stamp = stamp, env = env or false, info = info }
    return env, info
end

--- Called before a map opens: the map's own mod list becomes the selection (empty when it has none).
function ApplySidecar(scenarioFile)
    local set = {}
    local env = SidecarEnv(scenarioFile, true)
    if env then
        for _, uid in env.EditorMods or {} do
            if type(uid) == 'string' then set[uid] = true end
        end
    end
    SetSelection(set)
    return set
end
