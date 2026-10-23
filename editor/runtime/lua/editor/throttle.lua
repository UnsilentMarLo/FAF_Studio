-- Coalesces bursts of updates (a slider being dragged) into at most one run per `ms` milliseconds, the last value winning. Pure: the clock is injected, so the timing is tested without a game
-- (selftest_overlayfield.lua).
--
--   New(ms, clock) -> t     ms: the least time between two runs (default 80); clock() -> seconds (default GetSystemTimeSeconds)
--   t:Push(value)           an update is wanted; it replaces an update that has not run yet
--   t:Due() -> bool         something is pending and `ms` have passed since the last run (or there was no run yet: the first update goes at once)
--   t:Poll() -> true, value | false     takes the pending update when it is due (the caller runs it); the window starts now
--   t:Pending() -> bool     an update waits (for its turn)
--   t:Cancel()              drops the pending update
--
-- The shared registry for UI code (a slider callback cannot poll by itself; the frame hook of overlay.lua calls Pump every frame):
--   Defer(key, fn [, ms])   fn runs at once when the last run of `key` was `ms` ago or more, otherwise it waits for Pump; a newer fn of the same key replaces it (the last one wins, and it
--                           always runs: the final state of a drag is never lost)
--   Pump()                  runs the waiting functions that are due (pcall each: one failing update must not stop the others)
--   SetClock(clock)         replaces the clock of the registry and forgets its state (tests)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

DEFAULT_MS = 80

local Methods = {}

function New(ms, clock)
    return setmetatable({ ms = ms or DEFAULT_MS, clock = clock or rawget(_G, 'GetSystemTimeSeconds') or function() return 0 end, pending = false, value = nil, last = nil }, { __index = Methods })
end

function Methods:Push(value)
    self.pending = true
    self.value = value
end

function Methods:Pending()
    return self.pending
end

function Methods:Cancel()
    self.pending = false
    self.value = nil
end

function Methods:Due()
    if not self.pending then return false end
    if self.last == nil then return true end
    local dt = (self.clock() - self.last) * 1000
    return dt < 0 or dt >= self.ms - 0.001        -- a clock that went backwards must not stall the updates; the tolerance is float rounding of seconds * 1000
end

function Methods:Poll()
    if not self:Due() then return false end
    local v = self.value
    self.pending = false
    self.value = nil
    self.last = self.clock()
    return true, v
end

-- ---- the shared registry ---------------------------------------------------------------------------------------------------------------------------

local keyed = {}
local registryClock = false

local function RunDue(t)
    local due, fn = t:Poll()
    if due and fn then
        local ok, err = pcall(fn)
        if not ok then
            local log = rawget(_G, 'LOG')
            if log then log('EDITOR throttle: an update failed: ' .. tostring(err)) end
        end
    end
end

function Defer(key, fn, ms)
    local t = keyed[key]
    if not t then
        t = New(ms, registryClock or nil)
        keyed[key] = t
    end
    t:Push(fn)
    RunDue(t)
end

function Pump()
    -- (called every frame by the overlay: no table is made when nothing waits, which is nearly always)
    local waiting
    for _, t in keyed do
        if t.pending then
            waiting = waiting or {}
            table.insert(waiting, t)
        end
    end
    if not waiting then return end
    for _, t in waiting do RunDue(t) end
end

function SetClock(clock)
    registryClock = clock or false
    keyed = {}
end
