-- Timing aid: accumulates the time spent in named sections (the shell's tick, the overlay's frame update ...) and prints a report every 5 seconds while it is on.
--
--   Perf.Enabled                 on / off (starts on with the /perf command line flag; the command "Performance timing: on / off" in the palette switches it)
--   Perf.Time(name, fn, a, b)    calls fn(a, b) and adds its duration to `name`; returns what fn returns. Off: a plain call.
--   Perf.Begin() / Perf.End(name, t0)    the same for code that cannot be wrapped in a function (Begin returns nil when off, End ignores a nil t0)
--   Perf.Tick()                  called once per frame by the shell: prints the report when 5 s have passed
--   Perf.Report()                prints the sections (LOG and the Console panel), largest total first, and starts over
--
-- The report lines read: name, ms per second of wall time, calls, average ms, worst ms. A section that costs more than ~2 ms per second is worth a look; one whose
-- worst value is above ~30 ms is a visible hitch.
--
-- Lua 5.0 dialect: no `#`, no `%`.

Enabled = false
do
    local has = rawget(_G, 'HasCommandLineArg')
    if has then
        local ok, on = pcall(has, '/perf')
        if ok and on then Enabled = true end
    end
end

local sections = {}      -- name -> { total, calls, max }
local started = false    -- wall clock at the start of the current report period
local frames = 0

local function Clock()
    return GetSystemTimeSeconds()
end

local function Add(name, dt)
    local s = sections[name]
    if not s then
        s = { total = 0, calls = 0, max = 0 }
        sections[name] = s
    end
    s.total = s.total + dt
    s.calls = s.calls + 1
    if dt > s.max then s.max = dt end
end

function Begin()
    if not Enabled then return nil end
    return Clock()
end

function End(name, t0)
    if t0 then Add(name, Clock() - t0) end
end

function Time(name, fn, a, b)
    if not Enabled then return fn(a, b) end
    local t0 = Clock()
    local ok, r1, r2 = pcall(fn, a, b)
    Add(name, Clock() - t0)
    if not ok then error(r1, 0) end
    return r1, r2
end

function Set(on)
    Enabled = on and true or false
    sections, started, frames = {}, false, 0
    local line = 'perf: timing ' .. (Enabled and 'on, a report every 5 s' or 'off')
    LOG('EDITOR ' .. line)
    pcall(function()
        if not import('/lua/editor/consolelog.lua').Installed() then import('/lua/editor/gui/model.lua').Log(line) end     -- LOG above already reaches the Console panel
    end)
end

function Toggle()
    Set(not Enabled)
    return Enabled
end

function Report()
    local now = Clock()
    local span = started and (now - started) or 0
    local list = {}
    for name, s in sections do table.insert(list, { name = name, s = s }) end
    table.sort(list, function(a, b) return a.s.total > b.s.total end)
    local Model
    pcall(function() Model = import('/lua/editor/gui/model.lua') end)
    -- the Console panel records LOG itself once consolelog.lua is installed: a second copy through Model.Log would show every line twice
    local captured = false
    pcall(function() captured = import('/lua/editor/consolelog.lua').Installed() end)
    local function Out(text)
        LOG('EDITOR perf: ' .. text)
        if Model and not captured then pcall(Model.Log, text) end
    end
    local fps = (span > 0) and (frames / span) or 0
    Out(string.format('--- %.1f s, %.0f frames/s ---', span, fps))
    local shown = 0
    for _, e in list do
        shown = shown + 1
        if shown > 24 then break end
        local s = e.s
        local perSec = (span > 0) and (s.total * 1000 / span) or 0
        Out(string.format('%-34s %7.2f ms/s %6d calls  avg %6.3f  max %7.2f', e.name, perSec, s.calls, s.total * 1000 / math.max(1, s.calls), s.max * 1000))
    end
    -- what the engine's overlay spent in its last frame (EdOverlay.cpp ed_overlay_perf: slope view and node grids; the native draw is not part of the Lua sections)
    local native = rawget(_G, 'ed_overlay_perf')
    if native then
        local rate, draw, rated, pending, quads, level, projected, grids, gridQuads, gridProjected, groups, leaves, finest, buildMs, buildLeaves, buildSegs, buildProjected, depth = native()
        if rated and (quads > 0 or pending > 0 or gridQuads > 0 or (buildSegs or 0) > 0) then
            Out(string.format('native slope: rate %.2f ms (%d tiles, %d waiting), draw %.2f ms (%d quads, %d blocks of %d..%d cells, %d nodes projected)', rate, rated, pending, draw, quads, leaves or 0, math.pow(2, finest or 0), math.pow(2, level), projected))
            Out(string.format('native build grid: %.2f ms (%d blocks, %d line segments, %d nodes projected), depth test %s', buildMs or 0, buildLeaves or 0, buildSegs or 0, buildProjected or 0, (depth == 1) and 'on' or 'off'))
            Out(string.format('native grids: %.2f ms (%d quads, %d nodes projected, %d windows)', grids, gridQuads, gridProjected, groups))
        end
    end
    sections = {}
    started = now
    frames = 0
end

function Tick()
    if not Enabled then return end
    frames = frames + 1
    local now = Clock()
    if not started then started = now return end
    if now - started >= 5 then Report() end
end
