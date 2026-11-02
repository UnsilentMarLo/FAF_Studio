-- Frame cost budgets of the overlay on a stress document (docs/projects/editor/PERFORMANCE.md, "Frame cost budgets"). Through /edcmd in an /editor session with a map open:
--   return import('/lua/editor/selftest_perfbudget.lua').Run()
-- Returns text that starts with PASS or FAIL. The document is given 3000 markers, 40 areas and 150 units (perfstress.lua) and restored afterwards (nothing is saved).
--
-- What is gated (the numbers are the budgets; the measured values on the development machine, a 1920x1080 window, are in the docs):
--   * the overlay's Lua time per second at 60 frames per second on the stress document, with the camera at rest (the nets, the marker walks, the label candidates all run in it)
--   * the Lua garbage per frame and the heap growth over the run (a leak, or a per-frame table)
--   * the terrain reads per frame with the brush ring at rest (the ring is laid again only when something changed: it was ~200 reads in every frame)
--   * the worst single frame of the run
-- A budget is a regression gate, not a goal: it has headroom for a slower machine (about 4x the measured value) and is far below what the code cost before.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')

-- budgets
BUDGET_MS_PER_SECOND = 24          -- Lua ms per second in Overlay.Update at 60 frames per second (measured about 5 to 9; before the frame cost work 30 to 120)
BUDGET_KB_PER_FRAME = 6            -- garbage per frame (measured 1 to 2; before 5 to 47)
BUDGET_HEAP_GROWTH_KB = 1024       -- the heap after a full collection may not grow more than this over the run (a leak)
BUDGET_WORST_FRAME_MS = 20         -- the slowest frame (the nets: a candidate rebuild, a height sync slice; measured 3 to 9)
BUDGET_READS_PER_FRAME = 8         -- terrain reads per frame with the brush ring at rest (before ~190)

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

function Run()
    out, failed = {}, 0
    if not Map.Doc then return 'FAIL: no map is open' end
    if not import('/lua/ui/game/worldview.lua').viewLeft then return 'FAIL perfbudget: there is no world view (the editor window is not ready, or this is not an editor session)' end
    local PS = import('/lua/editor/perfstress.lua')
    local UI = import('/lua/editor/ui.lua')
    local Overlay = import('/lua/editor/overlay.lua')
    local Perf = import('/lua/editor/perf.lua')
    local Sig = import('/lua/editor/markersig.lua')
    local Units = import('/lua/editor/units.lua')

    local perfWasOn = Perf.Enabled
    if perfWasOn then Perf.Set(false) end          -- (the marks cost time of their own)
    local tool0 = UI.ActiveTool() and UI.ActiveTool().id
    local lastPos0 = Overlay.lastBrushPos

    local made = PS.Build({ markers = 3000, areas = 40, units = 150 })
    table.insert(out, '  stress: ' .. made)
    Check(string.find(made, '3000 markers') ~= nil, 'the stress document was made')
    PS.Frames(40)                                  -- warm up: the first frames create the objects (one-off cost)
    local warm = PS.Paced(2.2, 60)                 -- ... and one pass of every net

    -- ---- the idle overlay on the stress document ----------------------------------------------------------------------------------------------
    local r = PS.Paced(3.2, 60)
    table.insert(out, string.format('  idle: %.2f ms/s, worst %.2f ms, %.2f KB/frame, heap %+d KB over %d frames', r.perSecond, r.worst, r.kb, r.growth, r.frames))
    Check(r.frames > 100, 'the run made frames (' .. r.frames .. ')')
    Check(r.perSecond <= BUDGET_MS_PER_SECOND, string.format('Lua time per second %.2f ms <= %d', r.perSecond, BUDGET_MS_PER_SECOND))
    Check(r.kb <= BUDGET_KB_PER_FRAME, string.format('garbage per frame %.2f KB <= %d', r.kb, BUDGET_KB_PER_FRAME))
    Check(r.growth <= BUDGET_HEAP_GROWTH_KB, string.format('heap growth %d KB <= %d', r.growth, BUDGET_HEAP_GROWTH_KB))
    Check(r.worst <= BUDGET_WORST_FRAME_MS, string.format('worst frame %.2f ms <= %d', r.worst, BUDGET_WORST_FRAME_MS))

    -- ---- the brush ring at rest ------------------------------------------------------------------------------------------------------------------
    UI.SelectTool('raise')
    if UI.ActiveTool() and UI.ActiveTool().id == 'raise' then
        local sx, sz = ed_terrain_info()
        local cx, cz = ((sx or 257) - 1) / 2, ((sz or 257) - 1) / 2
        Overlay.lastBrushPos = { cx, ed_terrain_get(math.floor(cx), math.floor(cz)) or 0, cz }
        PS.Frames(5)                               -- the ring is laid
        local reads = 0
        local real = _G.ed_terrain_get
        _G.ed_terrain_get = function(x, z)
            reads = reads + 1
            return real(x, z)
        end
        local ok, err = pcall(PS.Frames, 30)
        _G.ed_terrain_get = real
        Check(ok, 'frames with the brush tool ran' .. (ok and '' or ': ' .. tostring(err)))
        local per = reads / 30
        table.insert(out, string.format('  brush at rest: %.2f terrain reads per frame', per))
        Check(per <= BUDGET_READS_PER_FRAME, string.format('terrain reads per frame with the brush ring at rest %.2f <= %d', per, BUDGET_READS_PER_FRAME))
    else
        table.insert(out, '  (the Raise tool is not offered in this workspace: the ring check is skipped)')
    end

    -- ---- the pieces ------------------------------------------------------------------------------------------------------------------------------------
    local n0, s0 = Sig.Sums(GetSystemTimeSeconds() + 1000)
    local m = Map.GetMarker('PS_5')
    local x0 = m and m.position[1]
    if m then m.position[1] = x0 + 3 end
    local n1, s1 = Sig.Sums(GetSystemTimeSeconds() + 2000)
    Check(n0 == n1 and s0 ~= s1, 'the marker fingerprint sees a marker that moved')
    if m then m.position[1] = x0 end
    local a = Units.CachedAll()
    local b = Units.CachedAll()
    Check(a == b, 'Units.CachedAll returns the same list while nothing changed')
    Check((Units.CACHE_NET_SECONDS or 0) >= 5, 'the units cache net is 5 s or more')

    PS.Remove()
    Overlay.lastBrushPos = lastPos0
    if tool0 and UI.ActiveTool() and UI.ActiveTool().id ~= tool0 then UI.SelectTool(tool0) end
    PS.Frames(3)
    if perfWasOn then Perf.Set(true) end
    table.insert(out, 1, (failed == 0) and 'PASS perfbudget' or ('FAIL perfbudget: ' .. failed .. ' check(s) failed'))
    return table.concat(out, '\n')
end
