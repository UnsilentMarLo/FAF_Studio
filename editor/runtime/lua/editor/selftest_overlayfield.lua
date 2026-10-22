-- Self test of the field overlay's Lua parts: the throttle (throttle.lua: coalescing with an injected clock), the alpha level mapping of the Lua fallback (overlaywin.lua Level, the same rule
-- as the engine's EdOverlayField.h MapValue) and, when the engine has ed_overlay_field, a smoke test of the native call. Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_overlayfield.lua').Run()
-- Returns text that starts with PASS or FAIL. The pure parts need no map.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Throttle = import('/lua/editor/throttle.lua')
local Win = import('/lua/editor/overlaywin.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

function Run()
    out, failed = {}, 0

    -- ---- the throttle ------------------------------------------------------------------------------------------------------------------------
    local now = 100                       -- seconds
    local clock = function() return now end
    local t = Throttle.New(80, clock)
    Check(not t:Due() and not t:Pending(), 'nothing pending: not due')
    Check(not t:Poll(), 'a poll with nothing pending returns false')
    t:Push('a')
    Check(t:Pending() and t:Due(), 'the first update is due at once (no earlier run)')
    local ok, v = t:Poll()
    Check(ok and v == 'a', 'the first poll gives the update')
    Check(not t:Pending() and not t:Poll(), 'and it is gone')
    t:Push('b')
    Check(t:Pending() and not t:Due(), 'a second update right after waits')
    now = 100.079
    Check(not t:Due(), '79 ms later it still waits')
    t:Push('c')
    t:Push('d')
    now = 100.080
    Check(t:Due(), '80 ms after the run it is due')
    ok, v = t:Poll()
    Check(ok and v == 'd', 'the last value wins (b, c, d -> d), got ' .. tostring(v))
    now = 100.100
    t:Push('e')
    Check(not t:Due(), 'the window restarts at the poll (20 ms later is too soon)')
    now = 100.159
    Check(not t:Due(), '79 ms after the poll')
    now = 100.161
    ok, v = t:Poll()
    Check(ok and v == 'e', 'and 81 ms after it the update goes')
    -- many pushes in one second: at most 13 runs at 80 ms
    local runs = 0
    local t2 = Throttle.New(80, clock)
    now = 200
    for i = 1, 200 do
        t2:Push(i)
        if t2:Poll() then runs = runs + 1 end
        now = now + 0.005                 -- a push every 5 ms for one second
    end
    Check(runs >= 11 and runs <= 13, 'a drag of 200 updates in a second runs about 12 times (' .. runs .. ')')
    now = now + 1
    t2:Push('final')
    ok, v = t2:Poll()
    Check(ok and v == 'final', 'the last update of a drag is never lost')
    -- a clock that goes backwards does not stall it
    local t3 = Throttle.New(80, clock)
    now = 500
    t3:Push(1)
    t3:Poll()
    now = 100
    t3:Push(2)
    Check(t3:Due(), 'a clock that went backwards counts as due')
    t3:Cancel()
    Check(not t3:Pending(), 'Cancel drops the pending update')

    -- ---- the shared registry ---------------------------------------------------------------------------------------------------------------
    now = 1000
    Throttle.SetClock(clock)
    local log = {}
    Throttle.Defer('k', function() table.insert(log, 'one') end)
    Check(table.getn(log) == 1, 'Defer runs the first call at once')
    Throttle.Defer('k', function() table.insert(log, 'two') end)
    Throttle.Defer('k', function() table.insert(log, 'three') end)
    Check(table.getn(log) == 1, 'calls inside the window wait')
    Throttle.Pump()
    Check(table.getn(log) == 1, 'a pump inside the window runs nothing')
    now = 1000.081
    Throttle.Pump()
    Check(table.getn(log) == 2 and log[2] == 'three', 'a pump after the window runs the last call only (' .. table.concat(log, ',') .. ')')
    Throttle.Pump()
    Check(table.getn(log) == 2, 'and nothing twice')
    Throttle.Defer('other', function() table.insert(log, 'x') end)
    Check(table.getn(log) == 3, 'another key has a window of its own')
    now = 1001
    Throttle.Defer('k', function() error('boom') end)
    Throttle.Defer('k', function() table.insert(log, 'after') end)
    now = 1001.2
    Throttle.Pump()
    Check(log[table.getn(log)] == 'after', 'a failing update does not break the next one')
    Throttle.SetClock(nil)

    -- ---- alpha levels (the same numbers as EdOverlayFieldTest.cpp) ---------------------------------------------------------------------------
    Check(Win.Level(0) == 0 and Win.Level(0.02) == 0, 'zero and the cutoff draw nothing')
    Check(Win.Level(0.03) == 8, '0.03 -> 8 (' .. Win.Level(0.03) .. ')')
    Check(Win.Level(1) == 255 and Win.Level(7) == 255 and Win.Level(-3) == 0, '1 -> 255, clamped both ways')
    Check(Win.Level(1, { scale = 0.5 }) == 128, 'scale 0.5: 1 -> 128 (' .. Win.Level(1, { scale = 0.5 }) .. ')')
    Check(Win.Level(0.5, { scale = 2, bias = -1 }) == 0 and Win.Level(0.75, { scale = 2, bias = -1 }) == 128 and Win.Level(1, { scale = 2, bias = -1 }) == 255, 'bias stretches 0.5..1 to 0..1')
    Check(Win.Level(0, { invert = true }) == 255 and Win.Level(1, { invert = true }) == 0 and Win.Level(0.25, { invert = true }) == 191, 'invert: 0 -> 255, 1 -> 0, 0.25 -> 191')
    Check(Win.Level(0.01, { cutoff = 0 }) == 3 and Win.Level(0, { cutoff = 0 }) == 0, 'cutoff 0 lets the faint values through')
    local nan = 0 / 0
    Check(Win.Level(nan) == 0, 'NaN draws nothing')

    -- ---- the native call ---------------------------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_overlay_field') and rawget(_G, 'ed_field_new') and rawget(_G, 'ed_overlay_count') then
        local f = ed_field_new(16, 16, 1)
        local c0 = ed_overlay_count()
        Check(ed_overlay_field('selftest:field', f, 'FF0000', 100) == true, 'ed_overlay_field takes a field handle')
        Check(ed_overlay_count() == c0 + 1, 'and counts as an overlay object')
        Check(ed_overlay_field('selftest:field', f, 'FF0000', 100) == true and ed_overlay_count() == c0 + 1, 'the same call again changes nothing')
        Check(ed_overlay_field('selftest:field', f, 'FF0000', 100, { scale = 0.5, bias = 0.1, invert = true, reduce = 'max', px = 12 }) == true, 'options are accepted')
        local bad, why = ed_overlay_field('selftest:bad', 987654, 'FF0000')
        Check(bad == nil and why ~= nil and ed_overlay_count() == c0 + 1, 'an unknown handle is refused and leaves nothing behind')
        ed_field_free(f)
        Check(ed_overlay_field('selftest:field', f, 'FF0000', 100) == nil, 'a freed handle is refused')
        ed_overlay_remove('selftest:field')
        Check(ed_overlay_count() == c0, 'ed_overlay_remove takes it off')
        if rawget(_G, 'ed_overlay_perf') then
            local n = 0
            n = table.getn({ ed_overlay_perf() })
            Check(n >= 25, 'ed_overlay_perf reports the field numbers (' .. n .. ' values)')
        end
    else
        table.insert(out, '  skip the native call (this engine has no ed_overlay_field)')
    end

    local head = failed == 0 and 'PASS' or ('FAIL (' .. failed .. ')')
    return head .. '\n' .. table.concat(out, '\n')
end
