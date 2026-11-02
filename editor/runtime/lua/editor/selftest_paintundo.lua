-- Self test of the paint undo (maskdelta.lua, strata.lua strokes and whole-mask edits, history.lua byte limit). Run in the live editor on a map with paint masks:
--   return import('/lua/editor/selftest_paintundo.lua').Run()
-- Real brush strokes (Terrain.BeginStroke / Dab / EndStroke, the calls ui.lua's stroke pump makes) on a paint layer; every undo and redo is compared with the checksum of the whole mask
-- (ed_field_checksum of the raw mask, FNV-1a of every cell: exact). Puts the masks back afterwards.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Strata = import('/lua/editor/strata.lua')
local Terrain = import('/lua/editor/terrain.lua')
local H = import('/lua/editor/history.lua')
local MD = import('/lua/editor/maskdelta.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

--- FNV checksum of the raw bytes of paint layer i (1..8).
local function Sum(i)
    local f = ed_field_stratum(i - 1, true)
    local c = ed_field_checksum(f)
    ed_field_free(f)
    return c
end

local function Line(x0, z0, x1, z1, n)
    local t = {}
    for i = 0, n do t[i + 1] = { x0 + (x1 - x0) * i / n, z0 + (z1 - z0) * i / n } end
    return t
end

--- A brush stroke along `pts`, pushed to the history like ui.lua does. Returns the entry.
local function Stroke(radius, pts)
    Terrain.Brush.mode = 'paint'
    Terrain.Brush.radius = radius
    Terrain.BeginStroke()
    for _, p in pts do Terrain.Dab(p[1], p[2]) end
    Terrain.EndStroke()
    local entry = Strata.TakeEntry()
    if entry then H.Push(entry) end
    return entry
end

--- Lua heap in KB after a full collection.
local function Heap()
    collectgarbage(0)
    return gcinfo()
end

function Run()
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    local function Done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end

    -- ---- the packing (needs no map) ----
    local vals = {}
    for i = 1, 2500 do vals[i] = math.mod(i * 7 + math.floor(i / 5), 256) end
    for _, n in { 1, 31, 1000, 1024, 2500 } do
        local s = MD.Pack(vals, n)
        local back = MD.Unpack(s, n)
        local same = (string.len(s) == n)
        for i = 1, n do if back[i] ~= vals[i] then same = false break end end
        check('Pack / Unpack round trip, ' .. n .. ' cells', same)
    end
    local uni = {}
    for i = 1, 1024 do uni[i] = 0 end
    local d = MD.New(0)
    MD.Add(d, 0, 0, 32, 32, uni, vals)
    check('a tile of one value is kept as that number', type(d.tiles[1][5]) == 'number' and d.tiles[1][5] == 0 and type(d.tiles[1][6]) == 'string')
    check('the bytes of a delta count the strings', d.bytes > 1024 and d.bytes < 1024 + 400, tostring(d.bytes))
    local back = MD.Unpack(d.tiles[1][5], 1024)
    check('a number unpacks to a full tile', back[1] == 0 and back[1024] == 0 and table.getn(back) == 1024)

    -- ---- the history limits (fake entries; no map needed) ----
    local savedEntries, savedBytes = H.MaxEntries, H.MaxBytes
    H.Clear()
    H.MaxEntries, H.MaxBytes = 200, 1000
    local log = {}
    local function Fake(name, bytes)
        return { label = name, bytes = bytes, undo = function() table.insert(log, 'u' .. name) end, redo = function() table.insert(log, 'r' .. name) end }
    end
    for i = 1, 5 do H.Push(Fake('e' .. i, 300)) end
    local n, total = H.Stats()
    check('the oldest entries go when the bytes pass the limit', n == 3 and total == 900, n .. ' entries, ' .. total .. ' bytes')
    local entries = H.Entries()
    check('and the newest stay in order', entries[1].label == 'e3' and entries[3].label == 'e5')
    H.Push(Fake('big', 5000))
    n, total = H.Stats()
    check('one entry over the limit is kept alone (the newest is never dropped)', n == 1 and total == 5000, n .. ' entries, ' .. total .. ' bytes')
    H.Undo()
    H.Push(Fake('after undo', 200))
    n, total = H.Stats()
    check('a new edit after an undo frees the redo branch and its bytes', n == 1 and total == 200, n .. ' entries, ' .. total .. ' bytes')
    H.Clear()
    n, total = H.Stats()
    check('Clear frees everything', n == 0 and total == 0)
    H.MaxBytes = 100000
    H.Push(Fake('a', 100))
    H.Push(Fake('b', 200))
    H.Merge(2, 'ab')
    n, total = H.Stats()
    check('Merge keeps the sum of its parts', n == 1 and total == 300, n .. ' entries, ' .. total .. ' bytes')
    H.Push(Fake('c', 50))
    H.JumpTo(0)
    H.Push(Fake('d', 10))
    n, total = H.Stats()
    check('dropping a merged entry (redo branch) frees its parts once', n == 1 and total == 10, n .. ' entries, ' .. total .. ' bytes')
    H.Clear()
    H.MaxEntries, H.MaxBytes = 3, 1000000
    for i = 1, 5 do H.Push(Fake('n' .. i, 1)) end
    n, total = H.Stats()
    check('the entry count limit still holds', n == 3 and total == 3, n .. ' entries, ' .. total .. ' bytes')
    H.Clear()
    H.MaxEntries, H.MaxBytes = savedEntries, savedBytes

    -- ---- strokes on a real mask ----
    if not rawget(_G, 'ed_stratum_info') or not ed_stratum_info() or not rawget(_G, 'ed_field_stratum') then
        return 'skipped the stroke checks (no map with paint masks)\n' .. Done()
    end
    local w, h, cell = Strata.MaskInfo()
    local size = ed_terrain_info()
    local layer
    for i = 1, 4 do
        local albedo = ed_stratum_layer(i)
        if albedo and albedo ~= '' and albedo ~= Strata.CLEAR then layer = i break end
    end
    if not layer then return 'skipped the stroke checks (no paint layer has a texture)\n' .. Done() end

    -- keep what is there: raw copies of the three layers the test touches
    local keep = {}
    for k = 1, 3 do keep[k] = ed_field_stratum(k - 1, true) end
    local active, brush = Strata.Active, {}
    for k, v in Strata.Brush do brush[k] = v end
    local tbrush = {}
    for k, v in Terrain.Brush do tbrush[k] = v end
    H.Clear()
    Strata.Active = layer
    Strata.ClearMask(layer)
    Strata.Brush.blend = 'max'
    Strata.Brush.strength = 70
    Strata.Brush.target = 100
    Strata.Brush.scatter = 0
    Strata.Brush.minSlope, Strata.Brush.maxSlope, Strata.Brush.minHeight, Strata.Brush.maxHeight = 0, 90, 0, 512

    local m = size / 8
    local c0 = Sum(layer)
    local heap0 = Heap()
    local entryA = Stroke(size / 30, Line(m, m, size - m, size - 2 * m, 40))
    check('a stroke makes an undo entry', entryA ~= nil and entryA.bytes and entryA.bytes > 0)
    local cA = Sum(layer)
    check('and changes the mask', cA ~= c0)
    local heapA = Heap()
    local bboxBytes = 2 * w * h * 16
    check('the entry is far smaller than two tables of the whole mask', entryA.bytes < bboxBytes / 4, entryA.bytes .. ' vs ' .. bboxBytes)
    check('and the Lua heap holds about its bytes after the stroke', heapA - heap0 < entryA.bytes / 1024 * 2 + 1000, (heapA - heap0) .. ' KB for ' .. math.floor(entryA.bytes / 1024) .. ' KB')

    Strata.Brush.blend = 'add'
    Strata.Brush.strength = 30
    local entryB = Stroke(size / 20, Line(size - m, m, m, size - m, 50))
    local cB = Sum(layer)
    check('a second stroke (build up) changes it again', entryB ~= nil and cB ~= cA)
    Strata.Brush.blend = 'max'
    Strata.Brush.strength = -60
    local entryC = Stroke(size / 40, Line(size * 0.3, size * 0.3, size * 0.5, size * 0.45, 25))
    local cC = Sum(layer)
    check('an erasing stroke too', entryC ~= nil and cC ~= cB)

    local exact = true
    local what = ''
    for round = 1, 2 do
        H.Undo()
        if Sum(layer) ~= cB then exact = false what = what .. ' undo1/' .. round end
        H.Undo()
        if Sum(layer) ~= cA then exact = false what = what .. ' undo2/' .. round end
        H.Undo()
        if Sum(layer) ~= c0 then exact = false what = what .. ' undo3/' .. round end
        H.Redo()
        if Sum(layer) ~= cA then exact = false what = what .. ' redo1/' .. round end
        H.Redo()
        if Sum(layer) ~= cB then exact = false what = what .. ' redo2/' .. round end
        H.Redo()
        if Sum(layer) ~= cC then exact = false what = what .. ' redo3/' .. round end
    end
    check('undo and redo of three strokes, twice, give the exact mask each time (checksums)', exact, what)

    -- the stroke after an undo cuts the redo branch and frees its bytes
    H.Undo()
    H.Undo()
    local _, bytesBefore = H.Stats()
    local entryD = Stroke(size / 30, Line(m, size / 2, size - m, size / 2, 30))
    local nAfter, bytesAfter = H.Stats()
    check('a stroke after two undos drops the two undone entries', nAfter == 2 and bytesAfter < bytesBefore + entryD.bytes, nAfter .. ' entries, ' .. bytesAfter .. ' bytes')
    H.Undo()
    H.Undo()
    check('and undo goes back to the start exactly', Sum(layer) == c0)
    H.Clear()

    -- the same strokes as the version that kept tables of the bounding box made (checksums taken from it), on the map they were taken on
    local info = rawget(_G, 'SessionGetScenarioInfo') and SessionGetScenarioInfo()
    if w == 512 and size == 1025 and ed_stratum_shader() == 'TTerrain' and info and string.find(string.lower(tostring(info.file)), '20x20winter_fire8v8', 1, true) then
        Strata.ClearMask(layer)
        Strata.Brush.blend = 'max' Strata.Brush.strength = 70
        Stroke(30, Line(100, 100, 700, 500, 40))
        local s1 = Sum(layer)
        Strata.Brush.blend = 'add' Strata.Brush.strength = 30
        Stroke(45, Line(200, 600, 800, 300, 50))
        local s2 = Sum(layer)
        Strata.Brush.blend = 'max' Strata.Brush.strength = -60
        Stroke(25, Line(300, 300, 500, 450, 25))
        local s3 = Sum(layer)
        check('paint output equals the version with table undo (fixed strokes, 3 checksums)',
            layer ~= 1 or (s1 == '7c11283839437624' and s2 == 'ac6e3fcfb21d74ae' and s3 == '29f33b1b19955931'), s1 .. ' ' .. s2 .. ' ' .. s3)
        H.Clear()
    else
        table.insert(lines, '  --   fixed-stroke checksums skipped (they belong to the 20x20 map with a 512 mask and TTerrain)')
    end

    -- ---- whole-mask edits ----
    Strata.Brush.target = 100
    Strata.Brush.strength = 70
    Strata.Brush.blend = 'max'
    Strata.ClearMask(layer)
    Stroke(size / 25, Line(m, m, size - m, size - m, 30))
    local p0 = Sum(layer)
    local fill = Strata.FillMask(layer)
    local pf = Sum(layer)
    check('Fill changes the mask and its entry is small (the filled side is a number per tile)', fill ~= nil and pf ~= p0 and fill.bytes < w * h / 2 + 200000, tostring(fill and fill.bytes))
    fill.undo()
    check('undo of Fill is exact', Sum(layer) == p0)
    fill.redo()
    check('redo of Fill is exact', Sum(layer) == pf)
    fill.undo()
    local clear = Strata.ClearMask(layer)
    local pc = Sum(layer)
    check('Clear changes the mask', clear ~= nil and pc ~= p0)
    clear.undo()
    check('undo of Clear is exact', Sum(layer) == p0)
    clear.redo()
    check('redo of Clear is exact', Sum(layer) == pc)
    clear.undo()
    local auto = (w * h <= 600000) and Strata.AutoPaint(layer, false) or nil       -- (a native height read per cell: slow on a big mask)
    local pa = Sum(layer)
    check('Auto paint makes an entry', auto ~= nil or w * h > 600000)
    if auto then
        auto.undo()
        check('undo of Auto paint is exact', Sum(layer) == p0)
        auto.redo()
        check('redo of Auto paint is exact', Sum(layer) == pa)
        auto.undo()
    end
    local other = (layer == 1) and 2 or 1
    local oc0 = Sum(other)
    local mv = Strata.Move(layer, (layer < 8) and 1 or -1)
    if mv then
        local j = (layer < 8) and layer + 1 or layer - 1
        check('Move swaps the two masks', Sum(j) == p0 and Sum(layer) == oc0)
        mv.undo()
        check('and undo swaps them back, exactly', Sum(layer) == p0 and Sum(j) == (j == other and oc0 or Sum(j)))
        Strata.Active = layer
    end
    -- Remove texture: the texture and the paint go, both come back
    local albedo0 = ed_stratum_layer(layer)
    local rem = Strata.RemoveTexture(layer)
    if rem then
        check('Remove texture clears the mask', Sum(layer) ~= p0)
        rem.undo()
        check('its undo brings back the paint exactly and the texture', Sum(layer) == p0 and ed_stratum_layer(layer) == albedo0)
        rem.redo()
        rem.undo()
        check('and again after a redo', Sum(layer) == p0 and ed_stratum_layer(layer) == albedo0)
    end

    -- ---- the limit on a real stroke: the oldest strokes go ----
    H.Clear()
    Strata.ClearMask(layer)
    local one = Stroke(size / 25, Line(m, m, size - m, m, 20))
    local limit = one.bytes * 2.5
    H.MaxBytes = limit
    local first = Sum(layer)
    for i = 1, 5 do
        Stroke(size / 25, Line(m, m + i * size / 12, size - m, m + i * size / 12, 20))
    end
    local nKept, bytesKept = H.Stats()
    check('strokes beyond the byte limit push the oldest out', nKept >= 1 and nKept < 6 and bytesKept <= limit + one.bytes, nKept .. ' entries, ' .. bytesKept .. ' bytes of ' .. limit)
    local steps = H.JumpTo(0)
    check('undo reaches back as far as the kept entries only', steps == nKept, steps .. ' steps for ' .. nKept)
    H.MaxBytes = savedBytes

    -- ---- put it all back ----
    H.Clear()
    for k = 1, 3 do
        local old = ed_field_commit_mask(keep[k], k - 1, { raw = true })
        if old then ed_field_free(old) end
        ed_field_free(keep[k])
    end
    for k, v in brush do Strata.Brush[k] = v end
    for k, v in tbrush do Terrain.Brush[k] = v end
    Strata.Active = active
    return Done()
end
