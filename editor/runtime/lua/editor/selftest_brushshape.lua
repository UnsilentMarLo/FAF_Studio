-- Self test of the shaped brushes: the cached mask grid (brushes.lua Grid / Weight / Fill), the native shaped dab (ed_terrain_brush with a shape handle, EdBrush.h) against the
-- Lua loop, the erosion brush's native weights against Brushes.Fill, and a timing of the dab. In the live editor through /edcmd:
--   return import('/lua/editor/selftest_brushshape.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The native checks run only when the exe has ed_brush_shape_set (they are reported as skipped otherwise).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Brushes = import('/lua/editor/brushes.lua')
local T = import('/lua/editor/terrain.lua')
local EroBrush = import('/lua/editor/erosionbrush.lua')

local SHAPES = { 'ridge', 'mountain', 'plateau', 'ring', 'diamond' }

function Run()
    local failures = {}
    local lines = {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local function info(text) table.insert(lines, '  info ' .. text) end

    local savedActive, savedAngle, savedRandom = Brushes.Active, Brushes.Angle, Brushes.RandomAngle
    Brushes.RandomAngle = false

    -- ---- the cached grid is what Weight reads, and it follows the shape function ------------------------------------------------------------------
    for _, id in SHAPES do
        local g = Brushes.Grid(id)
        check(id .. ': a grid of odd size, n * n values', g ~= nil and g.n == 129 and table.getn(g.values) == 129 * 129, g and tostring(g.n))
        if g then
            check(id .. ': the grid is cached', Brushes.Grid(id) == g)
            -- on the lattice Weight reads the grid values (angle 0): u = -1 + 2 i / (n - 1)
            Brushes.Angle = 0
            local worst = 0
            for k = 1, 60 do
                local i, j = math.mod(k * 37, g.n), math.mod(k * 53, g.n)
                local u, v = i / (g.n - 1) * 2 - 1, j / (g.n - 1) * 2 - 1
                if u * u + v * v < 1 then
                    local w = Brushes.Weight(id, u * 10, v * 10, 10, 0)
                    local d = math.abs(w - g.values[j * g.n + i + 1])
                    if d > worst then worst = d end
                end
            end
            check(id .. ': Weight reads the grid on its samples', worst < 1e-4, worst)
            -- between the samples the grid follows the shape function (a kink or noise costs a few percent at 129 x 129)
            worst = 0
            for k = 1, 200 do
                local u, v = math.mod(k * 7919, 1999) / 1000 - 1, math.mod(k * 104729, 1999) / 1000 - 1
                if u * u + v * v < 0.95 then
                    local d = math.abs(Brushes.Weight(id, u * 10, v * 10, 10, 0) - Brushes.Sample(id, u, v))
                    if d > worst then worst = d end
                end
            end
            check(id .. ': the grid follows the shape function (' .. string.format('%.3f', worst) .. ' at worst)', worst < 0.08, worst)
        end
    end
    -- Fill = Weight sample by sample (also with a turn): the preview and the erosion brush use it
    do
        Brushes.Angle = 20
        local worst, count = 0, 0
        for _, id in { 'ridge', 'mountain' } do
            local x0, z0, x1, z1 = 30, 40, 60, 66
            local list = Brushes.Fill(id, 13.5, 33, 45.3, 52.7, x0, z0, x1, z1)
            local n = 0
            for z = z0, z1 do
                for x = x0, x1 do
                    n = n + 1
                    local dx, dz = x - 45.3, z - 52.7
                    local ref = (math.sqrt(dx * dx + dz * dz) >= 13.5) and 0 or Brushes.Weight(id, dx, dz, 13.5, 33)
                    local d = math.abs(list[n] - ref)
                    if d > worst then worst = d end
                end
            end
            count = count + n
            check(id .. ': Fill gives as many values as samples', n == table.getn(list), n .. ' / ' .. table.getn(list))
        end
        check('Fill = Weight at ' .. count .. ' samples', worst < 1e-6, worst)
        local scaled = Brushes.Fill('ridge', 10, 0, 50, 50, 40, 40, 60, 60, 255)
        local okInt = true
        for _, v in scaled do if v ~= math.floor(v) or v < 0 or v > 255 then okInt = false end end
        check('Fill with a scale gives whole numbers 0..255', okInt)
        check('a round / unknown shape has no grid and no weight', Brushes.Grid('round') == nil and Brushes.Weight('round', 1, 1, 10, 0) == 0)
    end

    -- ---- the native shaped dab against the Lua loop -----------------------------------------------------------------------------------------------
    local w, h = ed_terrain_info()
    local haveNative = rawget(_G, 'ed_terrain_brush') ~= nil and rawget(_G, 'ed_brush_shape_set') ~= nil and w ~= nil and w >= 160
    if not haveNative then
        info('skipped the native checks: this exe has no ed_brush_shape_set (or no terrain)')
    else
        local h1 = Brushes.NativeShape('ridge')
        check('NativeShape uploads a shape', h1 ~= nil and ed_brush_shape_info(h1) == 129, tostring(h1))
        check('NativeShape returns the same handle again', Brushes.NativeShape('ridge') == h1)
        check('NativeShape: round has none', Brushes.NativeShape('round') == nil)
        local savedBrush = { mode = T.Brush.mode, radius = T.Brush.radius, strength = T.Brush.strength, falloff = T.Brush.falloff, level = T.Brush.level }
        local function Stroke(shape, mode, native, angle)
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
            ed_terrain_raise(95, 95, 12, 6)
            ed_terrain_raise(110, 102, 9, -4)
            ed_terrain_raise(104, 118, 15, 5)
            T.ClearHistory()
            T.NativeBrush = native
            Brushes.Active = shape
            Brushes.Angle = angle
            T.Brush.mode = mode
            T.Brush.radius = 17.5
            T.Brush.strength = (mode == 'smooth') and 6 or 2.5
            T.Brush.falloff = 0.7
            T.Brush.level = nil
            T.SetNextStrokeId(1000)
            T.BeginStroke()
            local total = T.Dab(100.3, 100.6) + T.Dab(108, 104.25) + T.Dab(106.5, 112)
            T.EndStroke()
            local words = ed_terrain_read_rect(70, 70, 140, 140)
            T.NativeBrush = true
            return words, total
        end
        for _, shape in { 'ridge', 'mountain', 'plateau' } do
            for _, mode in { 'raise', 'lower', 'plateau', 'flatten', 'smooth', 'noise' } do
                local angle = (shape == 'plateau') and 0 or 37
                local lua, luaChanged = Stroke(shape, mode, false, angle)
                local nat, natChanged = Stroke(shape, mode, true, angle)
                local differ, worst = 0, 0
                for i = 1, 71 * 71 do
                    local d = math.abs(lua[i] - nat[i])
                    if d > 0 then differ = differ + 1 end
                    if d > worst then worst = d end
                end
                check('native ' .. shape .. ' ' .. mode .. ' dab = the Lua loop', worst <= 1 and differ <= 40 and luaChanged > 0 and natChanged > 0,
                      differ .. ' words differ, worst ' .. worst .. ', changed lua ' .. tostring(luaChanged) .. ' native ' .. tostring(natChanged))
            end
        end
        -- a different angle gives a different dab (the turn reaches the native), and 360 degrees is the same as 0
        local a0 = Stroke('ridge', 'raise', true, 0)
        local a90 = Stroke('ridge', 'raise', true, 90)
        local a360 = Stroke('ridge', 'raise', true, 360)
        local diff90, diff360 = 0, 0
        for i = 1, 71 * 71 do
            if a0[i] ~= a90[i] then diff90 = diff90 + 1 end
            if math.abs(a0[i] - a360[i]) > 1 then diff360 = diff360 + 1 end
        end
        check('the angle turns the native shape', diff90 > 100, diff90)
        check('angle 360 = angle 0 natively', diff360 == 0, diff360)

        -- ---- timing: a shaped dab of radius 64 natively and in Lua (printed, not checked) --------------------------------------------------------
        local function Time(shape, native)
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
            T.ClearHistory()
            T.NativeBrush = native
            Brushes.Active = shape
            Brushes.Angle = 20
            T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff = 'raise', 64, 0.01, 1
            local clock = GetSystemTimeSeconds
            local reps = native and 20 or 3
            T.BeginStroke()
            local t0 = clock()
            for i = 1, reps do T.Dab(100 + i, 100) end
            local ms = (clock() - t0) * 1000 / reps
            T.EndStroke()
            T.NativeBrush = true
            return ms
        end
        if w >= 260 then
            local nat, lua = Time('mountain', true), Time('mountain', false)
            info(string.format('raise dab, radius 64, mountain: native %.2f ms, Lua loop %.1f ms (%.0fx)', nat, lua, lua / math.max(nat, 0.001)))
            local natImg, luaImg = Time('ridge', true), Time('ridge', false)
            info(string.format('raise dab, radius 64, ridge: native %.2f ms, Lua loop %.1f ms (%.0fx)', natImg, luaImg, luaImg / math.max(natImg, 0.001)))
        end
        Brushes.Active = 'round'
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        T.ClearHistory()
        T.Brush.mode, T.Brush.radius, T.Brush.strength, T.Brush.falloff, T.Brush.level = savedBrush.mode, savedBrush.radius, savedBrush.strength, savedBrush.falloff, savedBrush.level

        -- ---- the erosion brush: the native weights (opts.shape) = the list Brushes.Fill makes ---------------------------------------------------------
        if EroBrush.IsAvailable() and rawget(_G, 'ed_erode_window') then
            local function Erode(native)
                ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
                ed_terrain_raise(100, 100, 14, 8)
                ed_terrain_raise(115, 104, 10, -5)
                T.ClearHistory()
                Brushes.Angle = 25
                local brush = { mode = 'erode', radius = 14, strength = 2, falloff = 1 }
                ed_cmd_begin('Terrain erode test')
                local started = EroBrush.Begin()
                local changed = 0
                if started then
                    for _, c in { { 100.4, 100.2 }, { 106.5, 103 } } do
                        if native then
                            changed = changed + EroBrush.Dab(c[1], c[2], brush, 'erode', false, { id = 'mountain', turn = 12 })
                        else
                            local opts = EroBrush.DabOptions(brush, 'erode', false)
                            local x0, z0, x1, z1 = ed_erode_window(c[1], c[2], brush.radius, { mode = opts.mode, margin = opts.margin })
                            opts.weights = Brushes.Fill('mountain', brush.radius, 12, c[1], c[2], x0, z0, x1, z1)
                            changed = changed + (ed_erode_dab(c[1], c[2], brush.radius, opts) or 0)
                        end
                    end
                    EroBrush.End()
                end
                ed_cmd_end()
                return ed_terrain_read_rect(80, 80, 135, 125), changed
            end
            local a, ca = Erode(true)
            local b, cb = Erode(false)
            local differ, worst = 0, 0
            for i = 1, 56 * 46 do
                local d = math.abs(a[i] - b[i])
                if d > 0 then differ = differ + 1 end
                if d > worst then worst = d end
            end
            check('erosion brush: native shape weights = the Fill list', ca > 0 and cb > 0 and worst <= 2 and differ <= 80,
                  differ .. ' words differ, worst ' .. worst .. ', changed ' .. tostring(ca) .. ' / ' .. tostring(cb))
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
            T.ClearHistory()
        end
    end

    Brushes.Active, Brushes.Angle, Brushes.RandomAngle = savedActive, savedAngle, savedRandom
    local head = 'PASS'
    if table.getn(failures) > 0 then
        head = 'FAIL (' .. table.getn(failures) .. ')'
    end
    return head .. '\n' .. table.concat(lines, '\n')
end
