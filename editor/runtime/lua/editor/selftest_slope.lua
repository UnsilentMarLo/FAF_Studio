-- Self test of the slope view (slope.lua, and the native ratings ed_slope_at / ed_overlay_slope_caps of EdOverlay.cpp). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_slope.lua').Run()
-- Run returns text that starts with PASS or FAIL. The stops and the engine fallback are checked in Lua alone; the native part (the ring and area ratings against a Lua port of
-- the engine's OCCUPY_CheckEdgeFlatness / OCCUPY_CheckAreaFlatness on a made-up terrain) needs an editor engine with the 'ring' kind and is skipped with a note otherwise.
--
-- Lua 5.0 dialect.

local Slope = import('/lua/editor/slope.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Report(title)
    return (failed == 0 and 'PASS ' or 'FAIL ') .. title .. '\n' .. table.concat(out, '\n')
end

-- ---- Lua ports of the engine's two structure checks (STIMap.cpp), over a height function in world units; returns the deviation / range ----

local function RingDeviation(height, x0, z0, x1, z1)
    local lo, hi, last = 1e30, -1e30, 0
    for x = x0 - 1, x1 + 1 do
        local a, b = height(x, z0 - 1), height(x, z1 + 1)
        last = b
        lo = math.min(lo, a, b)
        hi = math.max(hi, a, b)
    end
    for z = z0, z1 do
        local a, b = height(x0 - 1, z), height(x1 + 1, z)
        last = b
        lo = math.min(lo, a, b)
        hi = math.max(hi, a, b)
    end
    local pivot = math.ceil(last)
    return math.max(hi - pivot, pivot - lo)
end

local function AreaRange(height, x0, z0, x1, z1)
    local lo, hi = 1e30, -1e30
    for z = z0, z1 do
        for x = x0, x1 do
            local v = height(x, z)
            lo = math.min(lo, v)
            hi = math.max(hi, v)
        end
    end
    return hi - lo
end

function Logic()
    out, failed = {}, 0
    local persist = Slope.Persist
    Slope.Persist = false        -- the test moves the choices around: they are not saved
    local keep = { kind = Slope.Kind, rule = Slope.Rule, foot = Slope.Footprint, skirt = Slope.Skirt, ring = Slope.BuildLimit.ring, area = Slope.BuildLimit.area }

    -- the stops are ascending and contain the sizes the data says are the most common
    local function Ascending(list)
        for i = 2, table.getn(list) do
            if list[i] <= list[i - 1] then return false end
        end
        return true
    end
    Check(Ascending(Slope.SKIRT_STOPS) and Ascending(Slope.FOOTPRINT_STOPS) and Ascending(Slope.BUILD_LIMITS), 'the stops are ascending')
    local has = {}
    for _, v in Slope.SKIRT_STOPS do has[v] = true end
    Check(has[1] and has[2] and has[3] and has[6] and has[8] and has[10] and has[12], 'skirt stops cover 1, 2, 3, 6, 8, 10 and 12')
    Check(Slope.NearestStop(Slope.SKIRT_STOPS, 4) ~= nil and Slope.NearestStop(Slope.SKIRT_STOPS, 0) == 1 and Slope.NearestStop(Slope.SKIRT_STOPS, 99) == 15, 'nearest stop clamps')
    Check(Slope.SKIRT_HINTS[8] ~= nil and Slope.SKIRT_HINTS[1] ~= nil, 'the common sizes have a hint')

    -- the structure view: skirt and limit are remembered per kind and rule
    Slope.SetKind('build')
    Slope.SetRule('ring')
    Slope.SetWindow(8)
    Slope.SetLimit(1.2)
    Check(Slope.Window == 8 and Slope.Skirt == 8 and math.abs(Slope.Limit - 1.2) < 0.001, 'ring rule: skirt 8, limit 1.2')
    Slope.SetRule('area')
    Check(Slope.Window == 8 and math.abs(Slope.Limit - Slope.BuildLimit.area) < 0.001, 'area rule keeps the skirt and has its own limit (' .. tostring(Slope.Limit) .. ')')
    Slope.SetWindow(5)
    Check(Slope.Window == 5, 'skirt 5 is a stop')
    Slope.SetWindow(4)
    Check(Slope.Window == 3 or Slope.Window == 5, 'a value between two stops goes to a stop (' .. tostring(Slope.Window) .. ')')
    Slope.SetKind('path')
    Check(Slope.Window == Slope.Footprint and math.abs(Slope.Limit - 0.75) < 0.001, 'mobile units: their own footprint, limit 0.75')
    Slope.SetWindow(7)
    Check(Slope.Footprint == 6, 'footprint 7 goes to the last stop (' .. tostring(Slope.Footprint) .. ')')
    Slope.SetKind('build')
    Check(Slope.Window == Slope.Skirt, 'back to structures: the skirt again')

    -- the engine fallback: without 'ring' in ed_overlay_slope_caps the structure view shows the area rule, with it the ring rule
    local saved = rawget(_G, 'ed_overlay_slope_caps')
    Slope.SetKind('build')
    Slope.SetRule('ring')
    rawset(_G, 'ed_overlay_slope_caps', nil)
    Slope.ForgetProbe()
    Check(Slope.NativeKind() == 'build' and Slope.RingMissing(), 'no ed_overlay_slope_caps: ring falls back to build')
    rawset(_G, 'ed_overlay_slope_caps', function() return { 'path', 'build' } end)
    Slope.ForgetProbe()
    Check(Slope.NativeKind() == 'build' and Slope.RingMissing(), 'caps without ring: falls back to build')
    rawset(_G, 'ed_overlay_slope_caps', function() return { 'path', 'build', 'ring' } end)
    Slope.ForgetProbe()
    Check(Slope.NativeKind() == 'ring' and not Slope.RingMissing(), 'caps with ring: ring')
    Slope.SetRule('area')
    Check(Slope.NativeKind() == 'build', 'area rule is the native build kind')
    Slope.SetKind('path')
    Check(Slope.NativeKind() == 'path', 'mobile units are the native path kind')
    rawset(_G, 'ed_overlay_slope_caps', saved)
    Slope.ForgetProbe()

    -- put the user's choices back
    Slope.Footprint, Slope.Skirt, Slope.BuildLimit.ring, Slope.BuildLimit.area = keep.foot, keep.skirt, keep.ring, keep.area
    Slope.SetRule(keep.rule)
    Slope.SetKind(keep.kind)
    Slope.Persist = persist
    return Report('slope logic')
end

--- The native ratings against the ports above, on blocks of random heights (needs the editor engine).
function Native()
    out, failed = {}, 0
    if not (rawget(_G, 'ed_slope_at') and rawget(_G, 'ed_overlay_slope_caps') and rawget(_G, 'ed_terrain_set_rect') and rawget(_G, 'ed_terrain_get')) then
        return 'PASS (skipped: this engine has no ed_slope_at / ed_overlay_slope_caps)'
    end
    Slope.ForgetProbe()
    Check(Slope.HasRing(), 'the engine lists the ring kind')
    ed_terrain_set_rect(90, 90, 160, 160, 25)
    local seed = 12345
    for bz = 0, 21 do
        for bx = 0, 21 do
            seed = math.mod(seed * 75 + 74, 65537)
            local h = 25 + math.mod(seed, 300) / 128         -- 25 .. 27.3 in steps of 1/128 (whole height words)
            ed_terrain_set_rect(95 + bx * 3, 95 + bz * 3, 97 + bx * 3, 97 + bz * 3, h)
        end
    end
    local height = function(x, z) return ed_terrain_get(x, z) end
    local bad, cases, fits, blocked = 0, 0, 0, 0
    for _, n in { 1, 2, 3, 5, 6, 8, 10, 12, 15 } do
        for cz = 100, 130, 5 do
            for cx = 100, 130, 4 do
                local ring = ed_slope_at('ring', cx + 0.5, cz + 0.5, n)
                local want = RingDeviation(height, cx, cz, cx + n, cz + n)
                local area = ed_slope_at('build', cx + 0.5, cz + 0.5, n)
                local wantArea = AreaRange(height, cx, cz, cx + n, cz + n)
                cases = cases + 1
                if not ring or math.abs(ring - want) > 0.0005 then
                    bad = bad + 1
                    if bad < 6 then Check(false, string.format('ring n=%d at (%d, %d): native %s, port %.5f', n, cx, cz, tostring(ring), want)) end
                end
                if not area or math.abs(area - wantArea) > 0.0005 then
                    bad = bad + 1
                    if bad < 6 then Check(false, string.format('area n=%d at (%d, %d): native %s, port %.5f', n, cx, cz, tostring(area), wantArea)) end
                end
                if want <= 1.1 then fits = fits + 1 else blocked = blocked + 1 end
            end
        end
    end
    Check(bad == 0, string.format('%d places x 2 rules: the native ratings equal the Lua ports of the engine checks', cases))
    Check(fits > 0 and blocked > 0, string.format('the fixture gives both verdicts for limit 1.1 (%d fit, %d blocked)', fits, blocked))
    return Report('slope native ratings')
end

function Run()
    local a = Logic()
    local b = Native()
    local ok = string.sub(a, 1, 4) == 'PASS' and string.sub(b, 1, 4) == 'PASS'
    return (ok and 'PASS' or 'FAIL') .. ' slope view\n' .. a .. '\n' .. b
end
