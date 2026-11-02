-- Self test of the "Map heights" node of the terrain graph (graphrun.lua Base / EnsureBase / Refresh, terrainepoch.lua Stamp): it must follow the ground however the ground was written.
-- The bug: the node kept showing the old terrain after the Generate panel's "Apply to terrain" (and other commits) until a brush stroke happened, because the live run only looked at the
-- ground when History.Version moved. Checked here, without any brush stroke:
--   * a commit through Fields.CommitHeight, through fieldgen.Commit, a commit without a history entry, a native write that clears the undo stack (ed_terrain_set_rect), an undo:
--     the next Refresh() (what the shell's tick calls) re-reads the node, its output and its thumbnail change
--   * nothing changed = Refresh() does nothing (no evaluation per frame); the graph's own preview on the terrain does not make it evaluate again
--   * a Build does not read its own output (a second build gives the same ground), and the node still shows the ground from before the graph after it
-- Run in the live editor:   return import('/lua/editor/selftest_graphbase.lua').Run()
-- Works on the open map (flat 25 afterwards).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Gen = import('/lua/editor/fieldgen.lua')
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')

local function Sum()
    local f = Fields.Height(1)
    local s = Fields.Checksum(f)
    Fields.Free(f)
    return s
end

--- A field that is `value` over the whole map, to be committed.
local function Level(w, h, value)
    return Fields.Op('const', { width = w, height = h, value = value })
end

--- The mean of the node's current output in the live run (nil when it has none).
local function NodeMean(id)
    local e = GRun.Main and GRun.Main:Entry(id)
    local f = e and e.outs and e.outs.out
    if not f then return nil, e end
    local mn, mx, mean = Fields.Stats(f)
    return mean, e
end

--- Equal within a hair (a mean is worked out in floats).
local function Near(a, b)
    return a ~= nil and math.abs(a - b) < 0.01
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

    if not Fields.IsAvailable() then return 'FAIL (no field natives)' end
    local w, h = ed_terrain_info()
    if not w or w < 129 then return 'FAIL (no terrain)' end
    GRun.Release()
    local startFields = ed_field_count()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()

    -- Map heights -> Output: heights, add mode: a build that read its own output would add again every time
    Graph.New('graphbase')
    local tn = Graph.Add('terrain', 0, 0)
    local oh = Graph.Add('out_height', 300, 0)
    Graph.SetParam(oh.id, 'mode', 'add')
    check('the nodes connect', Graph.Connect(tn.id, 'out', oh.id, 'a') == true)

    local rep = GRun.Refresh(true)
    local m0, e0 = NodeMean(tn.id)
    check('the Map heights node shows the ground (25)', Near(m0, 25) and rep and next(rep.errors) == nil, tostring(m0))
    check('nothing changed: Refresh does nothing', GRun.Refresh() == nil)
    check('...and again', GRun.Refresh() == nil)
    local stamp0 = TerrainEpoch.Stamp()
    check('the stamp is steady while nothing is written', TerrainEpoch.Stamp() == stamp0)

    -- TerrainEpoch.Step: the 5 s net follows the clock (the `now` argument is for this test), not the number of frames
    do
        local T0 = GetSystemTimeSeconds() + 1000          -- (numbers are 32-bit floats: a small clock keeps 0.1 s exact)
        TerrainEpoch.Step(false, T0)                 -- the net fires (the clock is 1000 s ahead of the last move) and the clock of the net is T0
        local e = TerrainEpoch.Epoch
        for i = 1, 500 do TerrainEpoch.Step(false, T0 + 0.1) end
        check('Epoch.Step: 500 frames within 0.1 s do not move the epoch', TerrainEpoch.Epoch == e)
        TerrainEpoch.Step(true, T0 + 9)
        check('Epoch.Step: no net while a stroke is dragged', TerrainEpoch.Epoch == e)
        TerrainEpoch.Step(false, T0 + TerrainEpoch.NET_SECONDS + 0.5)
        check('Epoch.Step: the net moves the epoch once after the net time', TerrainEpoch.Epoch == e + 1)
        TerrainEpoch.Step(false, T0 + TerrainEpoch.NET_SECONDS + 0.6)
        check('Epoch.Step: and not again at once', TerrainEpoch.Epoch == e + 1)
        TerrainEpoch.Bump()                          -- the clock of the net is the real one again
    end

    -- ---- Fields.CommitHeight (Fields panel "Commit to heights", the generators' common path) ------------------------------------------------------------
    local depth0 = History.Depth()
    local f60 = Level(w, h, 60)
    local n = Fields.CommitHeight(f60, { label = 'selftest graphbase commit' })
    Fields.Free(f60)
    check('the commit changed the ground', n and n > 0, tostring(n))
    check('the stamp moved', TerrainEpoch.Stamp() ~= stamp0)
    rep = GRun.Refresh()
    local m1, e1 = NodeMean(tn.id)
    check('Refresh re-evaluates after a commit, without any brush stroke', rep ~= nil)
    check('the Map heights node shows the committed ground (60)', Near(m1, 60), tostring(m1))
    check('the node was recomputed (new version) and its picture is new', e1 and e0 and e1.ver ~= e0.ver and (e0.thumb == nil or e1.thumb ~= e0.thumb), tostring(e1 and e1.thumb) .. ' vs ' .. tostring(e0 and e0.thumb))
    check('the commit is one history entry', History.Depth() == depth0 + 1)
    check('then Refresh is quiet again', GRun.Refresh() == nil)

    -- ---- fieldgen.Commit (Generate > Apply to terrain) ----------------------------------------------------------------------------------------------
    local result = { terrain = Level(w, h, 45) }
    local gn = Gen.Commit(result, 'selftest graphbase generator')
    Gen.Free(result)
    check('fieldgen.Commit wrote the ground', gn and gn > 0, tostring(gn))
    rep = GRun.Refresh()
    local m2 = NodeMean(tn.id)
    check('Refresh re-evaluates after the generator, without any brush stroke', rep ~= nil and Near(m2, 45), tostring(m2))

    -- ---- a commit that records no history entry (a tool, an import, a preview) ----------------------------------------------------------------------
    local depth1 = History.Depth()
    local f52 = Level(w, h, 52)
    Fields.CommitHeight(f52, { noHistory = true, label = 'selftest graphbase quiet' })
    Fields.Free(f52)
    rep = GRun.Refresh()
    local m3 = NodeMean(tn.id)
    check('a commit without a history entry is seen too', rep ~= nil and Near(m3, 52) and History.Depth() == depth1, tostring(m3))

    -- ---- a native write outside the undo stack (it also clears the stack) ---------------------------------------------------------------------------
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 40)
    rep = GRun.Refresh()
    local m4 = NodeMean(tn.id)
    check('a native write that clears the undo stack is seen', rep ~= nil and Near(m4, 40), tostring(m4))
    Terrain.ClearHistory()
    History.Clear()

    -- ---- undo -------------------------------------------------------------------------------------------------------------------------------------
    local f70 = Level(w, h, 70)
    Fields.CommitHeight(f70, { label = 'selftest graphbase undo' })
    Fields.Free(f70)
    GRun.Refresh()
    check('before the undo the node shows 70', Near(NodeMean(tn.id), 70))
    History.Undo()
    GRun.Refresh()
    check('after an undo it shows the ground again (40)', Near(NodeMean(tn.id), 40), tostring(NodeMean(tn.id)))
    History.Redo()
    GRun.Refresh()
    check('after a redo it shows 70', Near(NodeMean(tn.id), 70), tostring(NodeMean(tn.id)))
    History.Undo()
    GRun.Refresh()

    -- ---- the graph's own preview on the terrain is not a change from outside ----------------------------------------------------------------------
    local shownN = GRun.ShowOnTerrain()
    check('the preview shows on the terrain', shownN and shownN > 0 and GRun.TerrainShown())
    check('the preview does not make the live run evaluate again (no loop on its own output)', GRun.Refresh() == nil)
    check('the node still shows the ground from before the preview (40)', Near(NodeMean(tn.id), 40), tostring(NodeMean(tn.id)))
    GRun.RevertTerrain()
    check('taking the preview off is not a change either', GRun.Refresh() == nil)
    check('...and the ground is back (40)', Near(NodeMean(tn.id), 40))

    -- ---- a build does not read its own output --------------------------------------------------------------------------------------------------------
    GRun.Refresh(true)
    local before = Sum()
    local r1, why = GRun.Build()
    check('build works', r1 ~= nil, why)
    local built1 = Sum()
    local bm = Fields.Run(function(S) local f = S:Height(1) local a, b, mean = Fields.Stats(f) return mean end)
    check('add mode: the ground was 40, the node adds the ground to itself (80)', Near(bm, 80), tostring(bm))
    local r2 = GRun.Build()
    check('a second build starts from the same ground, not from its own result', r2 ~= nil and Sum() == built1)
    GRun.Refresh()
    check('after a build the node still shows the ground from before the graph (40)', Near(NodeMean(tn.id), 40), tostring(NodeMean(tn.id)))
    History.Undo()
    check('undo of the build gives the ground back', Sum() == before)
    GRun.Refresh()
    check('and the node shows it (40)', Near(NodeMean(tn.id), 40))

    -- a generator on top of a built ground is not mistaken for the build's result
    GRun.Build()
    local f33 = Level(w, h, 33)
    Fields.CommitHeight(f33, { label = 'selftest graphbase after build' })
    Fields.Free(f33)
    rep = GRun.Refresh()
    check('a commit after a build is seen (33)', rep ~= nil and Near(NodeMean(tn.id), 33), tostring(NodeMean(tn.id)))

    -- ---- clean up ---------------------------------------------------------------------------------------------------------------------------------
    GRun.Release()
    Graph.New('untitled')
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    check('no field leaks', ed_field_count() <= startFields, ed_field_count() .. ' vs ' .. startFields)

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
