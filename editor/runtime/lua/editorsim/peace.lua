-- Editing is quiet: while a map is edited nothing fires, however close the armies stand. Sim state, Lua 5.0 dialect.
--
-- The editing world is a normal sim with every army an enemy of every other (ScenarioUtilities.InitializeArmies, then BeginSessionTeams), so any weapon in range of a unit of
-- another army shot at it (CAiAttackerImpl: a target must satisfy army:IsEnemy; CFireWeaponTask: a unit on hold fire never fires). Two measures, both undone by Restore (a test run):
--   1. every pair of armies becomes Neutral, in both directions (SetAllianceOneWay); what each relation was is remembered and put back exactly by Restore, so a test run has the
--      scenario's own diplomacy (free for all, the teams of the lobby, a mission's Alliances table), not a recomputed one.
--   2. every unit gets hold fire (Unit:SetFireState(1); the engine clears the weapon target of a hold fire unit): the units of the map's INITIAL groups, of EdSpawnUnit, and any unit
--      a sweep finds later (a mission script's OnPopulate, a unit another feature made). The fire state the unit had (structures, experimentals and commanders are made with 2,
--      ground fire) is kept in unit.EdFireState and put back by Restore / Release.
-- The unit lab (editorsim/unittest.lua) is the one place where units are meant to fight while editing: its units carry unit.EdLab and Hold skips them, and Fight makes the two
-- armies of a lab enemies until Unfight. The unit viewer's own units (unit.EdViewUnit) are protected and skipped too.
-- Not done on purpose: SetCanTakeDamage / SetDoNotTarget on map units (the lab measures damage, the editor's kill and destroy tools must keep working) and disabling weapons
-- (scripts switch weapons themselves). Nothing fires, so nothing takes damage.
--
-- All natives go through one table (Api) so that selftest_peace.lua can run the logic with fakes: UseApi(fake) / UseApi(nil).

local fakeApi = nil
local quiet = false        -- the armies are neutral and the units are held
local saved = nil          -- [a][b] -> 'Ally' | 'Enemy' | 'Neutral' as it was when the quiet began
local fights = {}          -- lab armies made enemies on purpose: fights[a][b] = true
local sweepGen = 0

local function Api()
    if fakeApi then return fakeApi end
    return {
        armies = function()
            local list = {}
            for index, _ in ArmyBrains do table.insert(list, index) end
            return list
        end,
        relation = function(a, b)
            if IsAlly(a, b) then return 'Ally' end
            if IsEnemy(a, b) then return 'Enemy' end
            return 'Neutral'
        end,
        set = function(a, b, state) SetAllianceOneWay(a, b, state) end,
        units = function() return GetUnitsInRect(Rect(0, 0, 100000, 100000)) end,
        fork = function(fn) return ForkThread(fn) end,
        wait = function(ticks) WaitTicks(ticks) end,
    }
end

--- Tests: a table with armies(), relation(a, b), set(a, b, state), units() and optionally fork(fn) / wait(ticks) replaces the engine; nil gives it back.
function UseApi(api)
    fakeApi = api
end

--- Tests: forgets everything (a fresh session).
function Reset()
    quiet = false
    saved = nil
    fights = {}
    sweepGen = sweepGen + 1
end

--- True while the editing quiet is on.
function IsQuiet()
    return quiet
end

--- Hold fire for one unit; the fire state it had is kept. False when the unit was skipped (dead, held already, a viewer or lab unit).
function Hold(unit)
    if not unit or unit.Dead or unit.EdHeld or unit.EdViewUnit or unit.EdLab then
        return false
    end
    unit.EdHeld = true
    local ok, state = pcall(function() return unit:GetFireState() end)
    unit.EdFireState = (ok and state) or 0
    pcall(function() unit:SetFireState(1) end)
    return true
end

--- Puts the fire state back that Hold took (0 return fire, 2 ground fire for a structure ...).
function Release(unit)
    if unit and unit.EdHeld then
        local state = unit.EdFireState or 0
        unit.EdHeld = nil
        unit.EdFireState = nil
        if not unit.Dead then
            pcall(function() unit:SetFireState(state) end)
        end
    end
end

local function HoldAll(api)
    local units = api.units()
    if units then
        for _, unit in units do
            Hold(unit)
        end
    end
end

--- A unit another feature made while the quiet is on gets hold fire within a second.
local function StartSweep(api)
    if not api.fork or not api.wait then return end
    sweepGen = sweepGen + 1
    local mine = sweepGen
    api.fork(function()
        while quiet and sweepGen == mine do
            api.wait(10)
            if quiet and sweepGen == mine then
                HoldAll(api)
            end
        end
    end)
end

--- One sweep now (the thread of StartSweep does this every second).
function SweepOnce()
    if quiet then
        HoldAll(Api())
    end
end

--- Starts the quiet: remembers the diplomacy, makes every pair of armies Neutral, holds fire everywhere. False when it is on already.
function Enter()
    if quiet then return false end
    local api = Api()
    local list = api.armies()
    saved = {}
    for _, a in list do
        saved[a] = {}
        for _, b in list do
            if a ~= b then
                local state = api.relation(a, b)
                saved[a][b] = state
                if state ~= 'Neutral' then
                    api.set(a, b, 'Neutral')
                end
            end
        end
    end
    fights = {}
    quiet = true
    HoldAll(api)
    StartSweep(api)
    return true
end

--- Ends the quiet (a test run): the diplomacy as it was, the fire states as they were. False when it was not on.
function Restore()
    if not quiet then return false end
    quiet = false
    sweepGen = sweepGen + 1
    local api = Api()
    for a, row in saved do
        for b, state in row do
            if api.relation(a, b) ~= state then
                api.set(a, b, state)
            end
        end
    end
    saved = nil
    fights = {}
    local units = api.units()
    if units then
        for _, unit in units do
            Release(unit)
        end
    end
    return true
end

--- The unit lab: the two armies shoot at each other until Unfight (only while the quiet is on; a test run has the scenario's diplomacy anyway).
function Fight(a, b)
    if not quiet or not a or not b or a == b then return false end
    local api = Api()
    api.set(a, b, 'Enemy')
    api.set(b, a, 'Enemy')
    fights[a] = fights[a] or {}
    fights[a][b] = true
    return true
end

function Unfight(a, b)
    if not quiet or not a or not b or a == b then return false end
    if not (fights[a] and fights[a][b]) then return false end
    local api = Api()
    api.set(a, b, 'Neutral')
    api.set(b, a, 'Neutral')
    fights[a][b] = nil
    return true
end

-- Loader contract of schook/lua/simcallbacks.lua (every file of /lua/editorsim defines Register): this module has no callbacks of its own.
function Register(Callbacks)
end
