-- Self test of the Play setup (lua/editor/playsetup.lua): the built-in profiles, normalising, what needs a new session, the mods of the AIs, saved profiles that survive a
-- restart (the file is read again), the launch file the session start reads, and the game's real lists. Through /edcmd:
--   return import('/lua/editor/selftest_playsetup.lua').Run()      a string that starts with PASS or FAIL
--
-- Everything that writes uses a folder of its own (UserData.SetDirForTest), the launch file is emptied at the end. Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')
local PS = import('/lua/editor/playsetup.lua')

local failures = {}

local function Check(name, ok)
    if not ok then table.insert(failures, name) end
end

local function Roles(setup)
    local t = {}
    for _, s in setup.slots do table.insert(t, s.role) end
    return table.concat(t, ',')
end

local function Teams(setup)
    local t = {}
    for _, s in setup.slots do table.insert(t, tostring(s.team)) end
    return table.concat(t, ',')
end

local FAKE = {
    ai = { { key = 'rush', name = 'AI: Rush', mod = '' }, { key = 'adaptive', name = 'AI: Adaptive', mod = '' }, { key = 'm28', name = 'M28AI: M28', mod = 'UID-M28' } },
    factions = { { key = 'uef', name = 'UEF' }, { key = 'aeon', name = 'Aeon' }, { key = 'cybran', name = 'Cybran' }, { key = 'seraphim', name = 'Seraphim' } },
    mods = { { uid = 'UID-M28', name = 'M28AI', ai = { { key = 'm28', name = 'M28' } } }, { uid = 'UID-OTHER', name = 'Other', ai = {} } },
}

function Run()
    failures = {}
    UserData.SetDirForTest('userdata_selftest')
    UserData.Reset()
    PS.Reload()
    PS.UseLists(FAKE)

    -- ---- built-in profiles
    local solo = PS.Solo(4)
    Check('solo: 4 slots, you first', table.getn(solo.slots) == 4 and Roles(solo) == 'you,empty,empty,empty')
    Check('solo needs no new session', not PS.NeedsReload(solo))
    local one = PS.Builtin(PS.BUILTIN[2], 4)
    Check('you vs 1 AI: you and one AI', Roles(one) == 'you,ai,empty,empty' and one.slots[2].ai == 'rush')
    Check('you vs 1 AI needs a new session', PS.NeedsReload(one))
    local two = PS.Builtin(PS.BUILTIN[3], 8)
    Check('2 v 2: four armies, teams 1 2 1 2', Roles(two) == 'you,ai,ai,ai,empty,empty,empty,empty' and Teams(two) == '1,2,1,2,0,0,0,0')
    local ffa = PS.Builtin(PS.BUILTIN[4], 6)
    Check('free for all: every slot plays, no teams', Roles(ffa) == 'you,ai,ai,ai,ai,ai' and Teams(ffa) == '0,0,0,0,0,0')
    local watch = PS.Builtin(PS.BUILTIN[5], 6)
    Check('watch: four AIs, no You', Roles(watch) == 'ai,ai,ai,ai,empty,empty')
    Check('an unknown built-in name gives nil', PS.Builtin('nothing', 4) == nil)
    Check('every built-in has no problem', table.getn(PS.Problems(one)) == 0 and table.getn(PS.Problems(two)) == 0 and table.getn(PS.Problems(watch)) == 0)

    -- ---- normalising
    local messy = PS.Normalize({ fog = 'yes', victory = 'bogus', unitCap = 999, cheat = 99, mods = { 'b', 'a', 'a', 5 },
        slots = { { role = 'you', team = 99, faction = 'aeon' }, { role = 'you', ai = 'rush' }, { role = 'ai', ai = 'adaptive', team = -3 }, 'x' } }, 3)
    Check('normalise: 3 slots', table.getn(messy.slots) == 3)
    Check('normalise: one You only', Roles(messy) == 'you,empty,ai')
    Check('normalise: team clamped', messy.slots[1].team == PS.MAX_TEAM and messy.slots[3].team == 0)
    Check('normalise: fog is a boolean, victory known, cap on the list, cheat in range', messy.fog == false and messy.victory == 'sandbox' and messy.unitCap == 1000 and messy.cheat == 5.9)
    Check('normalise: mods sorted and unique', table.getn(messy.mods) == 2 and messy.mods[1] == 'a' and messy.mods[2] == 'b')
    Check('normalise: a table that is no setup gives solo', Roles(PS.Normalize('x', 2)) == 'you,empty')
    local padded = PS.Normalize(one, 6)
    Check('normalise: more slots are padded empty', Roles(padded) == 'you,ai,empty,empty,empty,empty')
    Check('normalise: fewer slots are cut', Roles(PS.Normalize(two, 2)) == 'you,ai')
    Check('normalise does not change its argument', Roles(two) == 'you,ai,ai,ai,empty,empty,empty,empty')

    -- ---- what needs a new session
    local base = PS.Solo(3)
    local function Needs(change)
        local s = PS.Solo(3)
        change(s)
        return PS.NeedsReload(s)
    end
    Check('reload: fog', Needs(function(s) s.fog = true end))
    Check('reload: victory', Needs(function(s) s.victory = 'domination' end))
    Check('reload: unit cap', Needs(function(s) s.unitCap = 500 end))
    Check('reload: pre-built', Needs(function(s) s.prebuilt = true end))
    Check('reload: a mod', Needs(function(s) s.mods = { 'UID-OTHER' } end))
    Check('reload: another faction', Needs(function(s) s.slots[1].faction = 'aeon' end))
    Check('reload: random faction', Needs(function(s) s.slots[1].faction = '' end))
    Check('reload: you in slot 2', Needs(function(s) s.slots[1].role = 'empty' s.slots[2].role = 'you' end))
    Check('reload: an AI', Needs(function(s) s.slots[3].role = 'ai' end))
    Check('no reload: a different AI type on an empty slot', not Needs(function(s) s.slots[2].ai = 'adaptive' s.slots[2].team = 3 end))
    Check('solo is stable', not PS.NeedsReload(base))

    -- ---- mods of the AIs
    local withMod = PS.Builtin(PS.BUILTIN[2], 4)
    withMod.slots[2].ai = 'm28'
    withMod.mods = { 'UID-OTHER' }
    local used = PS.UsedMods(withMod)
    Check('used mods: the setup own and the AI mod', table.getn(used) == 2 and used[1] == 'UID-M28' and used[2] == 'UID-OTHER')
    Check('used mods: a game AI brings none', table.getn(PS.UsedMods(one)) == 0)
    Check('ai names: a mod type is found', PS.AiName('m28') == 'M28AI: M28' and PS.AiName('gone') == 'gone')

    -- ---- problems
    local nobody = PS.Solo(2)
    nobody.slots[1].role = 'empty'
    Check('blocking: nobody plays', PS.Blocking(nobody) ~= nil)
    local gone = PS.Builtin(PS.BUILTIN[2], 3)
    gone.slots[2].ai = 'removed_mod_ai'
    Check('blocking: an AI the game does not have', PS.Blocking(gone) ~= nil and table.getn(PS.Problems(gone)) >= 1)
    Check('blocking: a good setup is not', PS.Blocking(one) == nil)
    local sameTeam = PS.Builtin(PS.BUILTIN[2], 3)
    sameTeam.slots[1].team = 1
    sameTeam.slots[2].team = 1
    Check('problem: all on one team', table.getn(PS.Problems(sameTeam)) == 1)
    local lonely = PS.Solo(2)
    lonely.victory = 'demoralization'
    Check('problem: victory with one army', table.getn(PS.Problems(lonely)) == 1)

    -- ---- profiles survive a restart (the file is read again)
    PS.Reload()
    local saved = PS.Builtin(PS.BUILTIN[3], 6)
    saved.fog = false
    saved.unitCap = 750
    saved.cheat = 2.3
    saved.slots[2].ai = 'adaptive'
    saved.slots[3].faction = 'cybran'
    saved.mods = { 'UID-M28' }
    local ok1 = PS.SaveProfile('  My 2v2  ', saved)
    Check('save profile', ok1)
    local refused, why = PS.SaveProfile(PS.BUILTIN[1], saved)
    Check('save profile: a built-in name is refused with a reason', refused == false and why ~= nil)
    Check('save profile: an empty name is refused', PS.SaveProfile('   ', saved) == false)
    Check('profiles list: built-ins first, then saved', PS.Profiles()[1] == PS.BUILTIN[1] and PS.Profiles()[table.getn(PS.BUILTIN) + 1] == 'My 2v2')
    PS.Reload()                         -- a new editor run reads the file
    local back = PS.GetProfile('My 2v2', 6)
    Check('profile survives the restart', back ~= nil and Roles(back) == Roles(saved) and Teams(back) == Teams(saved) and back.unitCap == 750 and back.cheat == 2.3
        and back.slots[2].ai == 'adaptive' and back.slots[3].faction == 'cybran' and back.mods[1] == 'UID-M28')
    local onFour = PS.GetProfile('My 2v2', 4)
    Check('profile on a map with other slot count', onFour ~= nil and table.getn(onFour.slots) == 4)
    Check('delete: a built-in stays', PS.DeleteProfile(PS.BUILTIN[1]) == false)
    Check('delete: a saved one goes', PS.DeleteProfile('My 2v2') == true and PS.GetProfile('My 2v2', 6) == nil)
    PS.Reload()
    Check('delete survives the restart', PS.GetProfile('My 2v2', 6) == nil)

    -- ---- the last setup
    PS.Remember(two, false)
    PS.Reload()
    local last = PS.Current()
    Check('the last setup comes back after a restart', table.getn(last.slots) == PS.SlotCount() and last.slots[1].role == 'you' and (PS.SlotCount() < 2 or last.slots[2].role == 'ai'))

    -- ---- the launch file
    local text = PS.LaunchText(withMod, '/maps/_playtest.v0001/_playtest_scenario.lua')
    local chunk = loadstring(text)
    local t = chunk and chunk()
    Check('launch text is Lua data', type(t) == 'table' and t.slots[2].ai == 'm28' and t.slots[2].role == 'ai' and t.fog == true and t.victory == 'sandbox' and t.unitCap == 1000)
    Check('launch carries the mods the AIs need', t and table.getn(t.mods) == 2)
    Check('launch write', PS.WriteLaunch(withMod, '/maps/_playtest.v0001/_playtest_scenario.lua'))
    Check('launch for another map is not used', PS.ReadLaunch('/maps/other/other_scenario.lua') == nil)
    Check('launch is emptied once read', (ed_read_file(PS.LAUNCH_FILE) or '') == '')
    PS.WriteLaunch(withMod, '/maps/_playtest.v0001/_playtest_scenario.lua')
    local got = PS.ReadLaunch('/MAPS/_playtest.v0001/_playtest_scenario.lua')
    Check('launch for the same map (case ignored) is read', got ~= nil and got.slots[2].ai == 'm28')
    Check('launch is gone after the read', PS.ReadLaunch('/maps/_playtest.v0001/_playtest_scenario.lua') == nil)
    ed_write_file(PS.LAUNCH_FILE, 'return { this is not lua')
    Check('a broken launch file gives nothing', PS.ReadLaunch('x') == nil and (ed_read_file(PS.LAUNCH_FILE) or '') == '')

    -- ---- the game's own lists (what the dialog shows)
    PS.UseLists(nil)
    local ai = PS.AiTypes()
    local haveRush, haveAdaptive = false, false
    for _, a in ai do
        if a.key == 'rush' then haveRush = true end
        if a.key == 'adaptive' then haveAdaptive = true end
    end
    Check('real lists: the game AI types (rush, adaptive) are there', haveRush and haveAdaptive)
    Check('real lists: four factions at least', table.getn(PS.Factions()) >= 4 and PS.Factions()[1].key == 'uef')
    Check('real lists: a default AI exists', PS.AiType(PS.DefaultAi()) ~= nil)
    Check('real lists: the slot count is sane', PS.SlotCount() >= 1 and PS.SlotCount() <= PS.MAX_SLOTS)

    -- clean up
    UserData.Reset()
    PS.Reload()
    ed_write_file(PS.LAUNCH_FILE, '')
    UserData.SetDirForTest(nil)
    if table.getn(failures) > 0 then
        return 'FAIL: ' .. table.getn(failures) .. ' check(s): ' .. table.concat(failures, '; ')
    end
    return 'PASS: the play setup'
end
