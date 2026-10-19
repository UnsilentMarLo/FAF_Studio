-- Map document / command stack self test, run in the live editor through the /edcmd channel
-- (scripts/ed_run_selftest.py runs it):
--   return import('/lua/editor/selftest_cmd.lua').Run()     brush strokes, undo / redo exact by checksum, dirty
--                                                           tracking, branch truncation; asks the sim for its checksum
--   return import('/lua/editor/selftest_cmd.lua').Check2()  (a few seconds later) the sim's own field equals the
--                                                           document: the commit path reached the sim thread
-- Both return a string that starts with PASS or FAIL.

local T = import('/lua/editor/terrain.lua')

local failures = {}

local function Check(name, ok)
    if not ok then
        table.insert(failures, name)
    end
end

local function Sum()
    return ed_doc_checksum(0, 0, 4000, 4000)    -- clamped to the map
end

local function Stroke(mode, radius, strength, points)
    T.Brush.mode = mode
    T.Brush.radius = radius
    T.Brush.strength = strength
    T.BeginStroke()
    for _, p in points do
        T.Dab(p[1], p[2])
    end
    T.EndStroke()
end

local function Report()
    if table.getn(failures) == 0 then
        return nil
    end
    return 'FAIL ' .. table.concat(failures, '; ')
end

function Run()
    failures = {}
    local w, h = ed_doc_attach()
    Check('attach', w ~= nil and w > 100)
    T.ClearHistory()
    ed_doc_mark_clean()

    local s0 = Sum()
    local u, r, dirty = ed_cmd_depth()
    Check('fresh depth', u == 0 and r == 0 and dirty == false)

    Stroke('raise', 14, 6, { { 60, 60 }, { 66, 62 }, { 72, 64 }, { 78, 66 }, { 84, 68 } })
    local s1 = Sum()
    Stroke('lower', 10, 4, { { 120, 120 }, { 124, 124 }, { 128, 128 } })
    local s2 = Sum()
    Stroke('flatten', 16, 0.8, { { 60, 60 }, { 70, 64 } })
    local s3 = Sum()
    Check('strokes changed the heights', s0 ~= s1 and s1 ~= s2 and s2 ~= s3)

    u, r, dirty = ed_cmd_depth()
    Check('3 strokes = 3 undo steps (got ' .. tostring(u) .. ')', u == 3 and r == 0)
    Check('dirty after edits', dirty == true)
    local undoLabel = ed_cmd_labels()
    Check('label', undoLabel == 'Terrain flatten')

    -- undo to the bottom: every step verified, exact checksums on the way
    local ok, x0, z0, x1, z1, label, verified = ed_cmd_undo()
    Check('undo 1', ok and verified and Sum() == s2)
    ok, x0, z0, x1, z1, label, verified = ed_cmd_undo()
    Check('undo 2', ok and verified and Sum() == s1)
    ok, x0, z0, x1, z1, label, verified = ed_cmd_undo()
    Check('undo 3', ok and verified and Sum() == s0)
    ok = ed_cmd_undo()
    Check('undo past the bottom does nothing', ok == false)
    _, _, dirty = ed_cmd_depth()
    Check('clean at the bottom', dirty == false)

    -- redo to the top
    ok, x0, z0, x1, z1, label, verified = ed_cmd_redo()
    Check('redo 1', ok and verified and Sum() == s1)
    ok = ed_cmd_redo()
    ok = ed_cmd_redo()
    Check('redo to the top', Sum() == s3)
    ok = ed_cmd_redo()
    Check('redo past the top does nothing', ok == false)

    -- dirty tracking around a save point
    ed_doc_mark_clean()
    _, _, dirty = ed_cmd_depth()
    Check('clean after mark', dirty == false)
    ed_cmd_undo()
    _, _, dirty = ed_cmd_depth()
    Check('dirty after undo past the save point', dirty == true)
    ed_cmd_redo()
    _, _, dirty = ed_cmd_depth()
    Check('clean after redo to the save point', dirty == false)

    -- a new edit after undo ends the redo branch
    ed_cmd_undo()
    local s2again = Sum()
    Check('back at stroke 2', s2again == s2)
    Stroke('noise', 12, 3, { { 200, 200 }, { 205, 205 } })
    local s4 = Sum()
    u, r = ed_cmd_depth()
    Check('redo branch dropped', u == 3 and r == 0)
    Check('noise changed the heights', s4 ~= s2)
    _, _, dirty = ed_cmd_depth()
    Check('dirty: the saved state is gone with the branch', dirty == true)

    -- SetRect is one undoable step too
    local before = Sum()
    -- a height the rect does not have yet: a test that ran before (shuffled order) may have left it flat at exactly 30, and a SetRect that changes nothing records no step
    T.SetRect(20, 20, 40, 40, 30)
    if Sum() == before then
        T.SetRect(20, 20, 40, 40, 61)
    end
    Check('set rect changed', Sum() ~= before)
    ed_cmd_undo()
    Check('set rect undone', Sum() == before)
    ed_cmd_redo()

    -- the sim must see the final state: ask it for its own checksum
    local final = Sum()
    SimCallback({ Func = 'EdSimChecksum', Args = { path = 'ed_cmd_sim_sum.txt', x0 = 0, z0 = 0, x1 = 4000, z1 = 4000 } }, false)
    ed_write_file('ed_cmd_doc_sum.txt', final)

    return Report() or ('PASS stack: 4 strokes + set rect, exact by checksum; doc ' .. final .. ' (now check the sim)')
end

function Check2()
    local sim = ed_read_file('ed_cmd_sim_sum.txt')
    local doc = ed_read_file('ed_cmd_doc_sum.txt')
    if not sim or not doc then
        return 'FAIL no sim checksum yet'
    end
    if sim ~= doc then
        return 'FAIL sim field ' .. sim .. ' differs from the document ' .. doc
    end
    return 'PASS sim field equals the document (' .. sim .. ')'
end
