-- Editing is quiet (editorsim/peace.lua): the logic that makes every army neutral and holds fire, run with fake natives (no sim needed). Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_peace.lua').Run()
-- Checks: entering makes every pair neutral in both directions and holds every unit; a second Enter changes nothing; units made later are held by a sweep; viewer and lab units are
-- skipped; a lab fight lasts until Unfight; Restore gives back the diplomacy exactly (also an asymmetric relation and a mission's Alliances) and the fire states (ground fire of a
-- structure stays 2); Restore without Enter does nothing; a second quiet after a test run remembers the diplomacy again.

local Peace = import('/lua/editorsim/peace.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Unit(state)
    local u = { Dead = false, state = state or 0 }
    u.GetFireState = function(self) return self.state end
    u.SetFireState = function(self, n) self.state = n end
    return u
end

function Run()
    out, failed = {}, 0

    -- a world of three armies: 1 and 2 are a team, 3 is the enemy of both; 3 -> 1 is one-sided neutral (a mission's Alliances table)
    local rel = {
        [1] = { [2] = 'Ally', [3] = 'Enemy' },
        [2] = { [1] = 'Ally', [3] = 'Enemy' },
        [3] = { [1] = 'Neutral', [2] = 'Enemy' },
    }
    local expected = { [1] = { [2] = 'Ally', [3] = 'Enemy' }, [2] = { [1] = 'Ally', [3] = 'Enemy' }, [3] = { [1] = 'Neutral', [2] = 'Enemy' } }
    local calls = 0
    local units = {}
    local forked = 0
    local fake = {
        armies = function() return { 1, 2, 3 } end,
        relation = function(a, b) return rel[a][b] end,
        set = function(a, b, state) calls = calls + 1 rel[a][b] = state end,
        units = function() return units end,
        fork = function(fn) forked = forked + 1 end,
        wait = function(n) end,
    }
    Peace.Reset()
    Peace.UseApi(fake)

    local rifle, tower, cdr = Unit(0), Unit(2), Unit(2)
    local viewer, lab = Unit(0), Unit(0)
    viewer.EdViewUnit = true
    lab.EdLab = true
    units = { rifle, tower, viewer, lab }

    Ok(not Peace.IsQuiet(), 'not quiet before Enter')
    Ok(Peace.Restore() == false, 'Restore without Enter does nothing')
    Ok(calls == 0, 'Restore without Enter touches no alliance')

    Ok(Peace.Enter() == true, 'Enter starts the quiet')
    local allNeutral = true
    for a = 1, 3 do
        for b = 1, 3 do
            if a ~= b and rel[a][b] ~= 'Neutral' then allNeutral = false end
        end
    end
    Ok(allNeutral, 'every pair of armies is neutral, in both directions')
    Ok(calls == 5, 'only the relations that were not neutral are written (' .. calls .. ' of 5)')
    Ok(rifle.state == 1 and tower.state == 1, 'every unit of the world holds fire')
    Ok(rifle.EdFireState == 0 and tower.EdFireState == 2, 'the fire states they had are kept (return fire, ground fire)')
    Ok(viewer.state == 0 and not viewer.EdHeld, 'a unit viewer unit is left alone')
    Ok(lab.state == 0 and not lab.EdHeld, 'a unit lab unit is left alone')
    Ok(forked == 1, 'a sweep thread is started for units made later')

    local before = calls
    Ok(Peace.Enter() == false and calls == before and forked == 1, 'a second Enter changes nothing')

    -- a unit another feature makes later is held by the sweep
    table.insert(units, cdr)
    Ok(cdr.state == 2, 'a new unit shoots until the sweep sees it')
    Peace.SweepOnce()
    Ok(cdr.state == 1 and cdr.EdFireState == 2, 'the sweep holds a new unit and keeps its fire state')
    Ok(Peace.Hold(cdr) == false, 'a unit already held is not held twice (its fire state is not overwritten)')

    -- the unit lab: two armies fight for a while
    Ok(Peace.Fight(1, 3) == true and rel[1][3] == 'Enemy' and rel[3][1] == 'Enemy', 'Fight makes two armies enemies in both directions')
    Ok(rel[1][2] == 'Neutral' and rel[2][3] == 'Neutral', 'the other pairs stay neutral')
    Ok(Peace.Fight(2, 2) == false, 'an army does not fight itself')
    Ok(Peace.Unfight(1, 3) == true and rel[1][3] == 'Neutral' and rel[3][1] == 'Neutral', 'Unfight makes them neutral again')
    Ok(Peace.Unfight(1, 3) == false, 'Unfight of a pair that does not fight does nothing')

    -- a lab fight still going when the test run starts: Restore wins
    Peace.Fight(2, 3)
    local dead = Unit(0)
    table.insert(units, dead)
    Peace.SweepOnce()
    dead.Dead = true

    -- a test run
    Ok(Peace.Restore() == true, 'Restore ends the quiet')
    local same = true
    for a = 1, 3 do
        for b = 1, 3 do
            if a ~= b and rel[a][b] ~= expected[a][b] then same = false end
        end
    end
    Ok(same, 'the diplomacy is exactly the scenario\'s (team, enemies, the one-sided neutral)')
    Ok(rifle.state == 0 and tower.state == 2 and cdr.state == 2, 'the fire states are back (return fire 0, ground fire 2)')
    Ok(not rifle.EdHeld and rifle.EdFireState == nil and not tower.EdHeld, 'no editor marks are left on the units')
    Ok(dead.state == 1, 'a dead unit is not touched again')
    Ok(not Peace.IsQuiet() and Peace.Restore() == false, 'a second Restore does nothing')
    Ok(Peace.Fight(1, 3) == false, 'no lab fight outside the quiet')

    -- the sweep does nothing once the quiet has ended
    local late = Unit(0)
    table.insert(units, late)
    Peace.SweepOnce()
    Ok(late.state == 0, 'a sweep outside the quiet holds nothing')

    -- back to edit without reopening the map: quiet again, with the diplomacy as it is now
    rel[1][2] = 'Enemy' rel[2][1] = 'Enemy'
    Ok(Peace.Enter() == true, 'Enter again after a test run')
    Ok(rel[1][2] == 'Neutral' and late.state == 1, 'neutral and held again')
    Peace.Restore()
    Ok(rel[1][2] == 'Enemy' and rel[2][1] == 'Enemy' and late.state == 0, 'and the second Restore gives back what was there at the second Enter')

    Peace.UseApi(nil)
    Peace.Reset()
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end
