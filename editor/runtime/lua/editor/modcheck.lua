-- Validators of the open mod project (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S4): the problems that would make the project fail in the game, shown in the Validation panel next to the map checks.
--
--   Run()        checks the project now; Update() (called by the validation panel about four times a second) does it again when the project or its edits changed
--   Issues       list of { kind = 'mod', sev = 'E' | 'W' | 'I', text }, Revision (bumped when the list changes)
--
-- What is checked: mod_info.lua (there, compiles, names and uid), unit and blueprint ids (lower case, valid derived ids), the game files the edits refer to (the base unit, the emitter / projectile
-- file), generated files that were not written yet or are stale, the weapon labels of edited and derived units against the unit script (the script's weapon table is keyed by the label; scripts inside
-- game archives are not readable from Lua and are skipped), the blueprint hook (what would be written and what is on disk compile), and an icon for every derived unit.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local Bp = import('/lua/editor/bpedit.lua')
local Fx = import('/lua/editor/fxedit.lua')
local Safe = import('/lua/editor/safe.lua')

Issues = {}
Revision = 0

local lastSig = false

local function Add(list, sev, text, fix, fixLabel)
    table.insert(list, { kind = 'mod', sev = sev, text = text, fix = fix, fixLabel = fixLabel })
end

local function Exists(path) return ed_file_stamp(path) ~= nil end

--- Compiles Lua text; true | false + message.
local function Compiles(text)
    local fn, err = loadstring(text)
    if fn then return true end
    return false, tostring(err)
end

local function ScriptText(bp)
    if not bp or not bp.ScriptModule then return nil end
    local disk = ed_vfs_to_disk(bp.ScriptModule)
    if not disk or string.find(string.lower(disk), '%.scd[/\\]') or string.find(string.lower(disk), '%.nx2[/\\]') then return nil end
    return ed_read_file(disk)
end

local function CheckUnit(list, id, bpId)
    local bp = __blueprints and __blueprints[bpId]
    if not bp then return end
    local text = ScriptText(bp)
    if not text then return end
    for _, w in bp.Weapon or {} do
        if w.Label and not w.DummyWeapon and not string.find(text, w.Label, 1, true) then
            Add(list, 'W', id .. ': the weapon ' .. w.Label .. ' has no entry in the unit script ' .. tostring(bp.ScriptModule) .. ' (the script weapon names must equal the blueprint labels)')
        end
    end
end

function Run()
    local list = {}
    local project = Bp.Project
    if project then
        local dir = Bp.ROOT .. '/' .. project
        -- mod_info.lua
        local info = ed_read_file(dir .. '/mod_info.lua')
        if not info then
            Add(list, 'E', 'the project has no mod_info.lua: the engine does not list it as a mod')
        else
            local ok, err = Compiles(info)
            if not ok then
                Add(list, 'E', 'mod_info.lua does not compile: ' .. err)
            else
                local env = {}
                local fn = loadstring(info)
                setfenv(fn, env)
                Safe.Try('modcheck:fn', fn)
                if not env.name or env.name == '' then Add(list, 'E', 'mod_info.lua has no name') end
                if not env.uid or string.len(tostring(env.uid)) ~= 36 then Add(list, 'E', 'mod_info.lua has no uid of the form XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX') end
                if env.name and env.name ~= project then Add(list, 'W', 'the mod name (' .. tostring(env.name) .. ') differs from the project folder (' .. project .. ')') end
            end
        end

        -- the edits and derived units
        local seen = {}
        for _, id in Bp.Edited() do seen[id] = true end
        for id, _ in Bp.Derived do seen[id] = true end
        local ids = {}
        for id, _ in seen do table.insert(ids, id) end
        table.sort(ids)
        for _, id in ids do
            local isFx = Fx.Kind(id)
            local derived = Bp.Derived[id]
            -- id casing
            if isFx then
                if Fx.Kind(id) == 'projectile' and id ~= string.lower(id) then Add(list, 'E', id .. ': a projectile id is its lower case path') end
                if not ed_vfs_to_disk(id) and not (Fx.Kind(id) == 'projectile' and ed_vfs_to_disk(string.lower(id))) then Add(list, 'E', id .. ': the game has no such file') end
            else
                if id ~= string.lower(id) then Add(list, 'E', id .. ': unit ids are lower case (the blueprint would not merge)') end
                if derived and not string.find(id, '^[a-z][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]+$') then Add(list, 'E', id .. ': a derived unit id is lower case letters and digits, at least 6') end
                if derived and not (__blueprints and __blueprints[derived.base]) then Add(list, 'E', id .. ': its base unit ' .. tostring(derived.base) .. ' is not in the game') end
                if not derived and not (__blueprints and __blueprints[id]) then Add(list, 'E', id .. ': the game has no such unit') end
                -- weapon labels against the script
                CheckUnit(list, id, derived and derived.base or id)
                -- icon of a derived unit
                if derived then
                    local icon = dir .. '/textures/ui/common/icons/units/' .. id .. '_icon.dds'
                    if not Exists(icon) then Add(list, 'I', id .. ': no icon yet (the Icons panel makes one); the build menu shows a blank one') end
                end
            end
            -- generated files present and current
            if Bp.Edits[id] and not derived then
                local path = Bp.FilePath(dir, id)
                local text = Exists(path) and ed_read_file(path)
                if not text then
                    Add(list, 'I', id .. ': the merge blueprint is not written yet (Write)')
                elseif text ~= Bp.MergeText(id) then
                    Add(list, 'I', id .. ': the merge blueprint on disk differs from the edits (Write)')
                end
            end
        end

        -- the blueprint hook on disk
        local hookPath = dir .. '/hook/lua/system/Blueprints.lua'
        local hook = Exists(hookPath) and ed_read_file(hookPath)
        if hook then
            local ok, err = Compiles(hook)
            if not ok then Add(list, 'E', 'hook/lua/system/Blueprints.lua does not compile (it would empty the module for everyone): ' .. err) end
        elseif next(Bp.Derived) then
            Add(list, 'I', 'the blueprint hook of the derived units is not written yet (Write)')
        end

        -- what the project itself reports
        for _, p in Bp.Check() do Add(list, p.sev, p.text, p.fix, p.fixLabel) end
    end

    local changed = table.getn(list) ~= table.getn(Issues)
    if not changed then
        for i, issue in list do
            if issue.text ~= Issues[i].text or issue.sev ~= Issues[i].sev then changed = true end
        end
    end
    if changed then
        Issues = list
        Revision = Revision + 1
    else
        Issues = list           -- the same problems: the new list holds the current fix functions (a reopened project has new spec tables)
    end
    return list
end

--- Checks again when the project or its edits changed (cheap otherwise).
function Update()
    local sig = tostring(Bp.Project) .. '|' .. Bp.Revision
    if sig ~= lastSig then
        lastSig = sig
        Run()
    end
end

--- Forces the next Update to check (after a Write: the files on disk changed).
function Touch()
    lastSig = false
end
