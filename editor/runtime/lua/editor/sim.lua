-- UI -> sim helpers (SimCallback wrappers; the callbacks live in schook/lua/simcallbacks.lua).
--
--   Resnap(x0, z0, x1, z1)        re-snaps units and props in a world rectangle onto the terrain now (one SimCallback)
--   ResnapLater(x0, z0, x1, z1)   the same for a brush stroke: rectangles are united and ONE callback is sent about every 0.15 s
--   FlushResnap()                 sends what ResnapLater collected now (terrain.lua does it when a stroke ends)
--
-- A brush dab used to send one EdResnap per dab and symmetry image: the sim thread then walked every unit and prop in the rectangle
-- (GetUnitsInRect, GetReclaimablesInRect, GetTerrainHeight, Warp) up to hundreds of times per second.

local RESNAP_INTERVAL = 0.15     -- seconds between the callbacks of a running stroke

local pending = nil              -- { x0, z0, x1, z1 } united rectangle not sent yet
local timerOn = false            -- a flush thread is waiting
local timerAt = 0

local function Now()
    if rawget(_G, 'GetSystemTimeSeconds') then return GetSystemTimeSeconds() end
    return 0
end

local function Send(x0, z0, x1, z1)
    -- a map without props (ed_prop_count() == 0, most of the time a fresh map) has nothing for the sim to search the rectangle for
    local noProps = nil
    if rawget(_G, 'ed_prop_count') and ed_prop_count() == 0 then noProps = true end
    SimCallback({ Func = 'EdResnap', Args = { x0 = x0, z0 = z0, x1 = x1, z1 = z1, noDirty = NoDirtyForTest, noProps = noProps } }, false)
end

local function Unite(x0, z0, x1, z1)
    if pending then
        if x0 < pending[1] then pending[1] = x0 end
        if z0 < pending[2] then pending[2] = z0 end
        if x1 > pending[3] then pending[3] = x1 end
        if z1 > pending[4] then pending[4] = z1 end
    else
        pending = { x0, z0, x1, z1 }
    end
end

--- Sends the collected rectangle (if any) now.
function FlushResnap()
    local p = pending
    pending = nil
    if p then
        Send(p[1], p[2], p[3], p[4])
    end
end

--- Re-snaps units and props inside a world rectangle onto the terrain. Call after terrain edits. A rectangle ResnapLater collected goes out in the same callback.
function Resnap(x0, z0, x1, z1)
    Unite(x0, z0, x1, z1)
    FlushResnap()
end

--- Like Resnap for the dabs of a stroke: the rectangle is collected and sent with the others after RESNAP_INTERVAL (the first dab of a quiet period
--- waits too: units under it follow the terrain a moment later). Any Resnap / FlushResnap call sends it at once.
function ResnapLater(x0, z0, x1, z1)
    Unite(x0, z0, x1, z1)
    local now = Now()
    -- a flush thread that never came back (an error in the thread) must not hold the rectangle for ever
    if timerOn and now - timerAt > 5 then timerOn = false end
    if not timerOn then
        timerOn = true
        timerAt = now
        ForkThread(function()
            WaitSeconds(RESNAP_INTERVAL)
            timerOn = false
            FlushResnap()
        end)
    end
end

--- Test control only: when true, terrain edits do not tell the pathfinder (shows what stale caches do).
NoDirtyForTest = false
