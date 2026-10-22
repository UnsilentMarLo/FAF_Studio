-- Self test of the terrain type brush and its overlay: the native disc (ed_tt_disc) gives the Lua loop's cells, the undo entry (tiles) restores the grid exactly, the dirty rectangle covers
-- what a dab changed, the codes under overlay nodes are the same from the native and the Lua path, and the incremental overlay (ttoverlay.lua) equals a full rebuild. Run in the live editor:
--   return import('/lua/editor/selftest_ttype.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check). The grid is put back afterwards.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local TT = import('/lua/editor/terraintype.lua')
local OV = import('/lua/editor/ttoverlay.lua')

function Run(verbose)
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local gw, gh = ed_tt_info()
    if not gw or gw < 96 or gh < 96 then
        return 'PASS\n  skip (no terrain type grid of at least 96 x 96 cells)'
    end
    local csx = TT.Cell()
    local saved = ed_tt_read(0, 0, gw - 1, gh - 1)
    local savedVisible, savedActive = TT.Visible, TT.Active
    local function Fill(v)
        local t = {}
        for i = 1, gw * gh do t[i] = v end
        ed_tt_write(0, 0, gw - 1, gh - 1, t)
    end
    local function Grid() return (ed_tt_read(0, 0, gw - 1, gh - 1)) end
    local function Same(a, b)
        for i = 1, gw * gh do
            if a[i] ~= b[i] then return false, i end
        end
        return true
    end
    -- world position of a cell
    local function W(c) return (c + 0.5) * csx end
    local function Stroke(native, pts, radius, code)
        TT.NativeDisc = native
        TT.Active = code
        TT.BeginStroke()
        for i = 1, table.getn(pts) do TT.Dab(W(pts[i][1]), W(pts[i][2]), { radius = radius }) end
        TT.EndStroke()
        TT.NativeDisc = true
        return TT.TakeEntry()
    end

    -- ---- painting: native and Lua give the same cells, undo and redo are exact ---------------------------------------------------------------------
    local pts = { { 30, 40 }, { 38, 44 }, { 46, 47 }, { 60, 60 }, { 2, 3 }, { gw - 3, gh - 3 } }
    Fill(1)
    local entryNative = Stroke(true, pts, 9.5 * csx, 77)
    local afterNative = Grid()
    Fill(1)
    local entryLua = Stroke(false, pts, 9.5 * csx, 77)
    local afterLua = Grid()
    local same, at = Same(afterNative, afterLua)
    check('the native disc paints the cells the Lua loop paints', same, tostring(at))
    check('the stroke has an undo entry', entryNative ~= nil and entryLua ~= nil)
    local painted = 0
    for i = 1, gw * gh do if afterNative[i] == 77 then painted = painted + 1 end end
    check('the strokes painted a sensible number of cells', painted > 600 and painted < 3000, tostring(painted))
    if entryNative then
        entryNative.undo()
        local g = Grid()
        local allOne = true
        for i = 1, gw * gh do if g[i] ~= 1 then allOne = false end end
        check('undo restores the grid before the stroke', allOne)
        entryNative.redo()
        check('redo restores the stroke exactly', Same(Grid(), afterNative))
        -- the entry holds the tiles the stroke changed, so it also redoes onto a cleared grid
        entryNative.undo()
        entryNative.redo()
        check('undo and redo again', Same(Grid(), afterNative))
        entryNative.undo()
    end

    -- ---- the dirty rectangle ---------------------------------------------------------------------------------------------------------------------------------
    TT.TakeDirty()
    Fill(1)
    TT.Active = 77
    TT.BeginStroke()
    TT.Dab(W(40), W(50), { radius = 6 * csx })
    TT.Dab(W(52), W(58), { radius = 6 * csx })
    TT.EndStroke()
    TT.TakeEntry()
    local d = TT.TakeDirty()
    check('the dirty rectangle covers the dabs', type(d) == 'table' and d[1] <= 35 and d[2] <= 45 and d[3] >= 57 and d[4] >= 63 and d[1] >= 30 and d[4] <= 66, d and (type(d) == 'table' and (d[1] .. ' ' .. d[2] .. ' ' .. d[3] .. ' ' .. d[4]) or d) or 'nil')
    check('nothing is pending after TakeDirty', TT.TakeDirty() == nil)
    TT.Revision = TT.Revision + 1
    check('a bump without a rectangle means everything', TT.TakeDirty() == 'all')

    -- ---- the codes under overlay nodes ------------------------------------------------------------------------------------------------------------------------
    do
        local g = {}
        for i = 1, gw * gh do g[i] = math.mod(i * 7 + math.floor(i / gw) * 3, 200) end
        ed_tt_write(0, 0, gw - 1, gh - 1, g)
        local bad = 0
        for _, w in { { 0, 0, 50, 40, 1 }, { 5, 7, 33, 29, 4 }, { -10, -10, 60, 60, 2 }, { gw - 30, gh - 30, 80, 80, 1 }, { 0, 0, 26, 21, 8 } } do
            TT.NativeNodes = true
            local a = TT.NodeCodes(w[1], w[2], w[3], w[4], w[5])
            TT.NativeNodes = false
            local b = TT.NodeCodes(w[1], w[2], w[3], w[4], w[5])
            for i = 1, w[3] * w[4] do
                if a[i] ~= b[i] then bad = bad + 1 end
            end
        end
        TT.NativeNodes = true
        check('NodeCodes: the native call gives the Lua loop\'s codes', bad == 0, tostring(bad) .. ' differ')
    end

    -- ---- the incremental overlay equals a full build ---------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_overlay_nodes') then
        TT.Visible = true
        OV.Hide()
        Fill(1)
        local win = { 0, 0, 100, 90, 2 }
        local now = 100
        local function Update() now = now + 1 return OV.Refresh(win[1], win[2], win[3], win[4], win[5], now) end
        local function Verify(label)
            local s = OV.Current()
            if not s then check(label, false, 'nothing drawn') return end
            local fresh = TT.NodeCodes(win[1], win[2], win[3], win[4], win[5])
            local bad = 0
            for i = 1, win[3] * win[4] do
                if s.codes[i] ~= fresh[i] then bad = bad + 1 end
                for code, g in s.grids do
                    if g[i] ~= ((fresh[i] == code) and 255 or 0) then bad = bad + 1 end
                end
            end
            check(label, bad == 0, tostring(bad) .. ' nodes differ')
        end
        TT.Active = 77
        TT.BeginStroke() TT.Dab(W(40), W(40), { radius = 8 * csx }) TT.EndStroke() TT.TakeEntry()
        check('first draw is a full build', Update() == 'full')
        Verify('full build matches the grid')
        TT.Active = 88
        TT.BeginStroke()
        TT.Dab(W(60), W(50), { radius = 6 * csx })
        TT.Dab(W(64), W(54), { radius = 6 * csx })
        check('a dab is a partial update', Update() == 'partial')
        Verify('partial update matches the grid')
        TT.EndStroke() TT.TakeEntry()
        TT.Active = 88
        TT.BeginStroke() TT.Dab(W(40), W(40), { radius = 14 * csx }) TT.EndStroke() TT.TakeEntry()
        Update()
        Verify('painting a type out removes its nodes')
        check('the type that was painted over has no layer left', OV.Current() and OV.Current().grids[77] == nil)
        Fill(5)
        TT.Revision = TT.Revision + 1
        check('a bump without a rectangle is a full build', Update() == 'full')
        Verify('full rebuild matches')
        check('no change, no work', Update() == nil)
        OV.Hide()
    end

    -- put everything back
    ed_tt_write(0, 0, gw - 1, gh - 1, saved)
    TT.Visible, TT.Active = savedVisible, savedActive
    TT.Revision = TT.Revision + 1

    local shown = lines
    if not verbose then
        shown = {}
        for _, l in lines do
            if string.sub(l, 1, 6) ~= '  ok  ' then table.insert(shown, l) end
        end
        table.insert(shown, '  ' .. (table.getn(lines) - table.getn(shown)) .. ' checks ok')
    end
    if table.getn(failures) > 0 then
        return 'FAIL (' .. table.getn(failures) .. ': ' .. table.concat(failures, ', ') .. ')\n' .. table.concat(shown, '\n')
    end
    return 'PASS\n' .. table.concat(shown, '\n')
end
