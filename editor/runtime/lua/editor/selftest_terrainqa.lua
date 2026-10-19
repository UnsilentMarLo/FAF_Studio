-- Self test of the fixes of the second QA pass over the terrain features (docs/projects/editor/QA_TERRAIN_2026-10.md): the graph canvas hover tracking (GetMouseScreenPos is not
-- tracked over panels), node placement, and what else that pass found. Run in the live editor:
--   return import('/lua/editor/selftest_terrainqa.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')

--- The graph canvas when it is on screen and alive (live.canvas can name a canvas whose controls were destroyed by a workspace switch), else nil.
local function LiveCanvas()
    local ok, mod = pcall(import, '/lua/editor/gui/panels_graph.lua')
    local Pn = ok and mod.live and mod.live.canvas
    if not Pn or Pn.dead or not Pn.bg or not Pn.w then return nil end
    local alive, wide = pcall(function() return Pn.bg.Width() > 100 and not Pn.bg:IsHidden() end)
    if alive and wide then return Pn, mod end
    return nil
end

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

    -- ---- graph canvas: "the pointer is over the canvas" comes from enter / exit events (the keys Ctrl+C / V / D / Z / Y, Delete act on the graph only then) ----
    do
        local Pn, mod = LiveCanvas()
        if Pn then
            local saved = Pn.hover          -- the real pointer may be over the canvas right now
            Pn.hover = {}
            Pn.bg:HandleEvent({ Type = 'MouseEnter', MouseX = Pn.bg.Left() + 10, MouseY = Pn.bg.Top() + 10 })
            check('graph canvas: an enter event puts the pointer over the canvas', mod.PointerInside())
            check('graph canvas: the last pointer position is kept for Paste', Pn.pointer and Pn.pointer[1] == Pn.bg.Left() + 10)
            Pn.bg:HandleEvent({ Type = 'MouseExit' })
            check('graph canvas: an exit event takes it off', not mod.PointerInside())
            -- a node frame under the pointer: exit of the background after the enter of the frame must not turn the state off
            Pn.bg:HandleEvent({ Type = 'MouseEnter' })
            Pn.hover.frameStandIn = true
            Pn.bg:HandleEvent({ Type = 'MouseExit' })
            check('graph canvas: leaving the background onto a node keeps the pointer over the canvas', mod.PointerInside())
            Pn.hover.frameStandIn = nil
            check('graph canvas: nothing under the pointer = not over the canvas', not mod.PointerInside())
            Pn.hover = saved
        else
            table.insert(lines, '  (no graph canvas open: hover checks skipped)')
        end
    end

    -- ---- graph canvas: a loaded graph reuses node ids with other types: the views must follow ----
    do
        local Pn = LiveCanvas()
        if Pn then
            local snap = Graph.Snapshot()
            local g = Graph.Current
            Graph.Edit('qa: clear', function() g.nodes = {} g.wires = {} Graph.Sel = {} end)
            local a = Graph.Add('const', 40, 40)
            Pn:Tick(true)
            local t1 = Pn.views[a.id] and Pn.views[a.id].type
            Graph.Edit('qa: swap type', function() g.nodes[1].type = 'blur' g.nodes[1].params = {} end)
            Pn:Tick(true)
            local v = Pn.views[a.id]
            check('graph canvas: the view of a node follows a changed node type', t1 == 'const' and v and v.type == 'blur', tostring(t1) .. '/' .. tostring(v and v.type))
            check('graph canvas: the new view has the ports of the new type', v and v.ins and table.getn(v.ins) == table.getn(Nodes.Inputs('blur')))
            Graph.Undo() Graph.Undo() Graph.Undo()
            Pn:Tick(true)
        end
    end

    -- ---- graph: a new node never lands on top of another one ----
    do
        local ok, mod = pcall(import, '/lua/editor/gui/panels_graph.lua')
        if ok and mod.FreeSpot then
            local n0 = table.getn(Graph.Current.nodes)
            local a = Graph.Add('const', 100, 100)
            local b = Graph.Add('blur', 140, 130)
            local x, y = mod.FreeSpot(100, 100, 'perlin')
            local overlap = false
            for _, n in { a, b } do
                if x < n.x + 160 and x + 160 > n.x and y < n.y + 110 and y + 110 > n.y then overlap = true end
            end
            check('graph: FreeSpot returns a place clear of the existing nodes', not overlap, x .. ',' .. y)
            local x2, y2 = mod.FreeSpot(2000, 2000, 'perlin')
            check('graph: a free wanted place stays where it is', x2 == 2000 and y2 == 2000)
            -- Reveal: a node far to the right is brought into view without a zoom change
            local far = Graph.Add('const', 5000, 40)
            local v0 = Graph.Current.view or { x = 0, y = 0, zoom = 1 }
            local z0, vx0, vy0 = v0.zoom, v0.x, v0.y
            if LiveCanvas() then mod.Reveal(far) end
            local view = Graph.Current.view
            local Pn = LiveCanvas()
            if Pn then
                check('graph: Reveal brings a far node into view', view.x + (far.x + 160) * view.zoom <= Pn.cw and view.x + far.x * view.zoom >= 0, view.x)
                check('graph: Reveal keeps the zoom', view.zoom == z0)
                Pn:SetView(vx0, vy0, z0)
            end
            Graph.Undo()
            Graph.Undo()
            Graph.Undo()
            check('graph: the test nodes are gone again', table.getn(Graph.Current.nodes) == n0)
        end
    end

    -- ---- overlay window: covers the ground in the middle of the world view wherever the view lies in the window ----
    do
        local wv = import('/lua/ui/game/worldview.lua').viewLeft
        local Win = import('/lua/editor/overlaywin.lua')
        if wv and wv.Width() > 200 and wv.Height() > 100 and ed_terrain_info and ed_terrain_info() then
            local x0, z0, nw, nh, step = Win.Window(wv, 290)
            local mid = UnProject(wv, Vector2(wv.Left() + wv.Width() / 2, wv.Top() + wv.Height() / 2))
            if x0 and mid then
                local x1, z1 = x0 + (nw - 1) * step, z0 + (nh - 1) * step
                local last = ed_terrain_info() - 1
                -- the window is clamped to the map: compare the clamped middle (a camera looking past the map edge puts the middle outside)
                local mx, mz = math.max(0, math.min(last, mid[1])), math.max(0, math.min(last, mid[3]))
                check('overlay window: holds the ground under the middle of the world view', mx >= x0 - 1 and mx <= x1 + 1 and mz >= z0 - 1 and mz <= z1 + 1,
                    string.format('mid %.0f,%.0f window %d,%d..%d,%d', mid[1], mid[3], x0, z0, x1, z1))
            end
        end
    end

    -- ---- interop panel: text typed into a field counts when the next button is pressed ----
    do
        local ok, mod = pcall(import, '/lua/editor/gui/panels_interop.lua')
        local Pn = ok and mod.live and mod.live.interop
        if Pn and Pn.Flush and Pn.pending then
            local saved = Pn.pending
            local got
            Pn.pending = { a = { text = 'C:/x', fn = function(t) got = t end } }
            Pn:Flush()
            check('interop panel: Flush applies the typed text of a field (no Enter needed)', got == 'C:/x', tostring(got))
            check('interop panel: Flush empties the pending list', next(Pn.pending) == nil)
            Pn.pending = saved
        end
    end

    -- ---- scrolling panels: the shifted content group must not swallow clicks on the tab strip above its panel ----
    do
        local ok, mod = pcall(import, '/lua/editor/gui/panels_maskgen.lua')
        local Pn = ok and mod.live and mod.live.maskgen
        local okc, ctx = pcall(function() return Pn and Pn.bApplyType and Pn.bApplyType:GetParent().scroll end)
        if not okc then ctx = nil end
        if ctx then
            check('scroll content: a clear catcher bitmap holds the wheel on the panel rectangle', ctx.catcher ~= nil)
            local hit = true
            local okHit, disabled = pcall(function() return ctx.content:IsHitTestDisabled() end)
            if okHit then hit = not disabled end
            check('scroll content: the shifted content group is not hit tested', not hit)
        end
    end

    -- ---- history: a merged entry may hold terrain strokes (Apply skeleton was two Ctrl+Z) ----
    do
        local History = import('/lua/editor/history.lua')
        local T = import('/lua/editor/terrain.lua')
        if ed_terrain_info and ed_terrain_info() then
            History.Clear()
            T.ClearHistory()
            local function Sum() return ed_doc_checksum(0, 0, 4000, 4000) end
            local function Stroke(x, z)
                T.Brush.mode = 'raise' T.Brush.radius = 10 T.Brush.strength = 5
                T.BeginStroke() T.Dab(x, z) T.Dab(x + 4, z + 2) T.EndStroke()
                History.PushTerrain()
            end
            local s0 = Sum()
            local state = 0
            Stroke(60, 60)
            History.Push({ label = 'qa object', undo = function() state = state - 1 end, redo = function() state = state + 1 end })
            state = 1
            Stroke(120, 120)
            local s1 = Sum()
            History.Merge(3, 'qa merged')
            local u, r = History.Depth()
            check('history: three entries (two strokes, an object edit) merge into one', u == 1 and r == 0, tostring(u))
            History.Undo()
            check('history: one undo takes back both strokes exactly', Sum() == s0, tostring(Sum()) .. ' vs ' .. tostring(s0))
            check('history: and the object part', state == 0, tostring(state))
            History.Redo()
            check('history: redo brings both strokes back exactly', Sum() == s1)
            check('history: and the object part again', state == 1)
            History.Undo()
            History.Clear()
            T.ClearHistory()
        end
    end

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
