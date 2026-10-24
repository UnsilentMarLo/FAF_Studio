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

--- Text of the sidecar file for the current selection.
--- `pathsText` replaces the paths part (Map > Resize writes the sidecar of the resized map with the paths moved).
function SidecarText(pathsText)
    local lines = { 'version = 1', 'EditorMods = {' }
    local uids = {}
    for uid in GetSelection() do
        table.insert(uids, uid)
    end
    table.sort(uids)
    for _, uid in uids do
        table.insert(lines, string.format('    %q,', uid))
    end
    table.insert(lines, '}')
    return table.concat(lines, '\n') .. '\n' .. import('/lua/editor/terraintype.lua').SidecarText() .. import('/lua/editor/mission.lua').SidecarText()
        .. import('/lua/editor/graph.lua').SidecarText()
        .. import('/lua/editor/layout.lua').SidecarText()
        .. (pathsText or import('/lua/editor/paths.lua').SidecarText())
        .. import('/lua/editor/interop.lua').SidecarText()
        .. import('/lua/editor/shaders.lua').SidecarText()
end

--- Called before a map opens: the map's own mod list becomes the selection (empty when it has none).
function ApplySidecar(scenarioFile)
    local set = {}
    local path = scenarioFile and SidecarPath(scenarioFile)
    if path and DiskGetFileInfo(path) then
        local env = {}
        doscript(path, env)
        for _, uid in env.EditorMods or {} do
            set[uid] = true
        end
    end
    SetSelection(set)
    return set
end
