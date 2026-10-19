-- Self test of the mask generator, the stratum recipes and the props scatter (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2). Run in the live editor:
--   return import('/lua/editor/selftest_maskgen.lua').Run()
-- Returns a report; the first line is PASS or FAIL. Works on a scratch terrain (flat ground with a 45 degree ramp on the right half) and puts the map back to flat 25 afterwards.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Scatter = import('/lua/editor/scatter.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

local function R(type, values, op, invert)
    local r = MaskGen.NewRule(type)
    for k, v in (values or {}) do r.v[k] = v end
    r.op = op or 'and'
    r.invert = invert or false
    return r
end

--- The mask of `rules` at full resolution, read at the given map positions.
local function Probe(rules, points)
    return Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        local m, err = MaskGen.Evaluate(c, { rules = rules })
        if not m then return nil, err end
        local out = {}
        for i, p in points do out[i] = Fields.Get(m, p[1], p[2]) end
        local mn, mx, mean = Fields.Stats(m)
        return out, mean, mn, mx
    end)
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
    local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.02) end

    if not Fields.IsAvailable() then return 'FAIL (no field natives)' end
    local w, h = ed_terrain_info()
    if not w or w < 129 then return 'FAIL (no terrain)' end
    local startFields = ed_field_count()
    local startProps = ed_prop_count()
    local Strata = import('/lua/editor/strata.lua')
    if ed_stratum_info() then for i = 1, 8 do Strata.ClearMask(i) end end       -- a clean slate

    -- scratch terrain: 25 on the left half, a 45 degree ramp from the middle on
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    local mid = math.floor((w - 1) / 2)
    Fields.Run(function(S)
        local g = S:Op('gradient', { width = w, height = h, angle = 0, lo = 0, hi = w - 1 })                  -- value = x
        local ramp = S:Op('clamp', { a = g, lo = mid, hi = w - 1 })
        local hgt = S:Op('affine', { a = ramp, mul = 1, add = 25 - mid })
        Fields.CommitHeight(hgt, { label = 'selftest ramp', noHistory = true })
    end)
    Terrain.ClearHistory()
    History.Clear()
    check('scratch terrain', near(ed_terrain_get(10, 40), 25, 0.01) and near(ed_terrain_get(mid + 40, 40), 25 + 40, 0.5),
        tostring(ed_terrain_get(10, 40)) .. ' / ' .. tostring(ed_terrain_get(mid + 40, 40)))
    local L, Rt = { 20, 60 }, { w - 20, 60 }

    -- ---- rules ----------------------------------------------------------------------------------------------------------------------------------
    local v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }) }, { L, Rt })
    check('slope rule: steep ground only', v and v[1] == 0 and v[2] == 1, v and (v[1] .. ' / ' .. v[2]))
    v = Probe({ R('unitclass', { class = 1, blocked = 1, soft = 0 }) }, { L, Rt })
    check('unit class: a 45 degree ramp blocks a land unit', v and v[1] == 0 and v[2] == 1, v and (v[1] .. ' / ' .. v[2]))
    v = Probe({ R('unitclass', { class = 1, blocked = 0, soft = 0 }) }, { L, Rt })
    check('unit class: flat ground is passable', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('unitclass', { class = 5, blocked = 0, soft = 0 }) }, { L, Rt })
    check('unit class: structure rule', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('height', { lo = 20, hi = 30, soft = 0 }) }, { L, Rt })
    check('height band', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('aspect', { azimuth = 180, from = 0.6, soft = 0, flat = 0.05 }) }, { L, Rt })
    check('aspect: the ramp descends toward -x', v and v[1] == 0 and v[2] == 1, v and (v[1] .. ' / ' .. v[2]))
    v = Probe({ R('aspect', { azimuth = 0, from = 0.6, soft = 0, flat = 0.05 }) }, { L, Rt })
    check('aspect: and not toward +x', v and v[2] == 0)
    v = Probe({ R('flow', { range = 1000, from = 0.0, to = 0.001 }) }, { L, Rt })
    check('flow rule runs', v ~= nil)
    v = Probe({ R('position', { kind = 1, angle = 0, from = 0, to = 1 }) }, { L, Rt })
    check('position gradient grows to the right', v and v[1] < 0.3 and v[2] > 0.7)
    local mean
    v, mean = Probe({ R('const', { value = 0.5 }) }, { L })
    check('constant', v and v[1] == 0.5)

    -- combinators
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('height', { lo = 40, hi = 200, soft = 0 }, 'and') }, { { mid + 5, 60 }, { w - 20, 60 } })
    check('and: the smaller of the two', v and v[1] == 0 and v[2] == 1, v and (v[1] .. ' / ' .. v[2]))
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('height', { lo = 40, hi = 200, soft = 0 }, 'or') }, { { mid + 5, 60 }, L })
    check('or: the larger of the two', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('const', { value = 0.5 }), R('const', { value = 0.5 }, 'mul') }, { L })
    check('multiply', v and v[1] == 0.25)
    v = Probe({ R('const', { value = 1 }), R('slope', { lo = 30, hi = 90, soft = 0 }, 'sub') }, { L, Rt })
    check('difference removes the second rule', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }, 'and', true) }, { L, Rt })
    check('invert flag (not)', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('const', { value = 0.25 }), R('const', { value = 0.5 }, 'add') }, { L })
    check('add', v and v[1] == 0.75)

    -- modifiers
    local base, baseMean = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }) }, { L })
    local _, grownMean = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('grow', { distance = 12, soft = 0 }) }, { L })
    local _, shrunkMean = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('shrink', { distance = 12, soft = 0 }) }, { L })
    check('grow adds area, shrink takes it away', grownMean > baseMean + 0.02 and shrunkMean < baseMean - 0.02, baseMean .. ' ' .. grownMean .. ' ' .. shrunkMean)
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('grow', { distance = 12, soft = 0 }) }, { { mid - 8, 60 }, { mid - 20, 60 } })
    check('grow reaches 12 units', v and v[1] == 1 and v[2] == 0, v and (v[1] .. ' / ' .. v[2]))
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('blur', { radius = 6 }), R('threshold', { value = 0.5 }) }, { { mid + 30, 60 }, L })
    check('blur then threshold', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('not', {}) }, { L, Rt })
    check('not modifier', v and v[1] == 1 and v[2] == 0)
    v = Probe({ R('const', { value = 0.4 }), R('amount', { factor = 2 }) }, { L })
    check('amount', v and near(v[1], 0.8, 0.001))
    v = Probe({ R('slope', { lo = 30, hi = 90, soft = 0 }), R('close', { radius = 3 }), R('open', { radius = 3 }) }, { L, Rt })
    check('open / close keep large shapes', v and v[1] == 0 and v[2] == 1)
    local _, nm = Probe({ R('noise', { kind = 1, seed = 4, size = 30, octaves = 3, from = 0.4, to = 0.6 }) }, { L })
    check('noise mask has a spread', nm > 0.15 and nm < 0.85, nm)

    -- every type evaluates with its defaults
    local bad = {}
    for _, id in MaskGen.Order do
        local rules = { R('slope', { lo = 0, hi = 90, soft = 0 }) }
        if MaskGen.Types[id].kind == 'source' then rules[2] = R(id, {}, 'or') else rules[2] = R(id, {}) end
        local out, err = Probe(rules, { L })
        if not out then table.insert(bad, id .. ': ' .. tostring(err)) end
    end
    check('all rule types evaluate (layer rules need paint masks)', table.getn(bad) == 0, table.concat(bad, '; '))
    local pbad = {}
    for _, p in MaskGen.Presets do
        local out, err = Probe(p.make(), { L })
        if not out then table.insert(pbad, p.id .. ': ' .. tostring(err)) end
    end
    check('all presets evaluate', table.getn(pbad) == 0, table.concat(pbad, '; '))

    -- determinism and the preview
    local def = { rules = { R('noise', { seed = 7, size = 20 }), R('slope', { lo = 0, hi = 50, soft = 4 }, 'mul') } }
    local f1 = MaskGen.PreviewDef(def)
    local c1 = f1 and Fields.Checksum(f1)
    local f2 = MaskGen.PreviewDef(def)
    check('preview is deterministic', c1 ~= nil and c1 == Fields.Checksum(f2))
    check('preview replaces the previous one', ed_field_count() <= startFields + 1)
    MaskGen.ClearPreview()
    local none = MaskGen.PreviewDef({ rules = {} })
    check('no rules, no mask', none == nil)

    -- ---- outputs: paint masks ------------------------------------------------------------------------------------------------------------------
    local mw, mh = ed_stratum_info()
    local steep = { rules = { R('slope', { lo = 30, hi = 90, soft = 0 }) } }
    if mw then
        local function Layer(i, raw) return Fields.Run(function(S) return Fields.Checksum(S:Stratum(i, raw)) end) end
        local function Value(i, wx, wz) return Fields.Run(function(S) return Fields.Sample(S:Stratum(i), wx, wz) end) end
        local before = { Layer(2, true), Layer(5, true) }
        local depth = History.Version
        local n = MaskGen.ApplyToLayer(steep, { layer = 5, mode = 1, strength = 1, takeAway = false })
        check('apply to layer changes cells', n and n > 100, tostring(n))
        check('apply to layer is one history entry', History.Version == depth + 1)
        check('layer 5 is painted on the ramp only', near(Value(5, w - 20, 60), 1, 0.02) and near(Value(5, 20, 60), 0, 0.01), Value(5, w - 20, 60) .. ' / ' .. Value(5, 20, 60))
        -- layers above take away: layer 2 everywhere, but only where layer 5 leaves room
        local all = { rules = { R('const', { value = 1 }) } }
        MaskGen.ApplyToLayer(all, { layer = 2, mode = 1, strength = 1, takeAway = true })
        check('layers above take away', near(Value(2, 20, 60), 1, 0.02) and near(Value(2, w - 20, 60), 0, 0.02), Value(2, 20, 60) .. ' / ' .. Value(2, w - 20, 60))
        History.Undo()
        check('undo of the take-away write', Layer(2, true) == before[1])
        MaskGen.ApplyToLayer(all, { layer = 2, mode = 1, strength = 1, takeAway = false })
        check('without take away it covers everything', near(Value(2, w - 20, 60), 1, 0.02))
        MaskGen.ApplyToLayer(steep, { layer = 2, mode = 3, strength = 1, takeAway = false })
        check('subtract mode', near(Value(2, w - 20, 60), 0, 0.02) and near(Value(2, 20, 60), 1, 0.02), Value(2, w - 20, 60) .. ' / ' .. Value(2, 20, 60))
        History.Undo()
        History.Undo()
        History.Undo()
        check('undo restores layer 5', Layer(5, true) == before[2])
        check('undo restores layer 2', Layer(2, true) == before[1])
        History.Redo()
        check('redo brings layer 5 back', near(Value(5, w - 20, 60), 1, 0.02))
        History.Undo()

        -- the strata cascade as a rule
        MaskGen.ApplyToLayer(steep, { layer = 5, mode = 1, strength = 1 })
        v = Probe({ R('free_above', { layer = 2 }) }, { L, Rt })
        check('free of layers above', v and v[1] == 1 and near(v[2], 0, 0.02), v and (v[1] .. ' / ' .. v[2]))
        v = Probe({ R('layer', { layer = 5, visible = 0 }) }, { L, Rt })
        check('layer rule reads the paint mask', v and near(v[1], 0, 0.02) and near(v[2], 1, 0.02))
        History.Undo()

        -- ---- terrain types -------------------------------------------------------------------------------------------------------------------
        local ttw, tth = nil, nil
        if rawget(_G, 'ed_tt_info') then ttw, tth = ed_tt_info() end
        if ttw then
            local TT = import('/lua/editor/terraintype.lua')
            local function Cell(wx, wz) local vals = ed_tt_read(math.floor(wx * ttw / (w - 1)), math.floor(wz * tth / (h - 1)), math.floor(wx * ttw / (w - 1)), math.floor(wz * tth / (h - 1))) return vals[1] end
            local codeA, codeB = TT.Types()[1].code, TT.Types()[table.getn(TT.Types())].code
            local old, oldRight = Cell(20, 60), Cell(w - 20, 60)
            local cnt = MaskGen.ApplyToTypes(steep, { typeCode = codeB, threshold = 0.5 })
            check('apply to terrain type', cnt and cnt > 100 and Cell(w - 20, 60) == codeB and Cell(20, 60) == old, tostring(cnt) .. ' ' .. tostring(Cell(w - 20, 60)))
            History.Undo()
            check('undo restores the terrain types', Cell(w - 20, 60) == oldRight)
            History.Redo()
            check('redo writes them again', Cell(w - 20, 60) == codeB)
            History.Undo()
        else
            table.insert(lines, '  skip terrain type tests (no grid)')
        end

        -- ---- recipes -------------------------------------------------------------------------------------------------------------------------
        Recipes.State.preset = 1
        Recipes.State.layers = nil
        Recipes.State.types = true
        Recipes.Knobs.cliff, Recipes.Knobs.rock = 40, 20
        local roles = Recipes.Roles()
        check('recipe roles', table.getn(roles) >= 4, table.getn(roles))
        Recipes.State.layers = Recipes.AutoLayers(roles)
        local snap = {}
        for l = 1, 8 do snap[l] = Layer(l, true) end
        depth = History.Version
        local summary, cells = Recipes.Apply()
        check('recipe applies', summary ~= nil, tostring(cells))
        check('recipe is one history entry', History.Version == depth + 1)
        if summary then
            local total = 0
            for _, e in summary do total = total + e.share end
            check('recipe shares add up to the map', near(total, 1, 0.03), total)
            local rockLayer = Recipes.State.layers[4]
            check('rock lies on the ramp, not on the flat', Value(rockLayer, w - 20, 60) > 0.9 and Value(rockLayer, 20, 60) < 0.1)
        end
        History.Undo()
        local same = true
        for l = 1, 8 do if Layer(l, true) ~= snap[l] then same = false end end
        check('recipe undo restores every layer', same)
        for _, p in Recipes.Presets do
            Recipes.State.preset = _
            Recipes.State.layers = nil
            local rs = Recipes.Roles()
            Recipes.State.layers = Recipes.AutoLayers(rs)
            local ok, s = pcall(Recipes.Apply)
            check('preset ' .. p.id .. ' applies', ok and s ~= nil, tostring(s))
            History.Undo()
        end
        Recipes.State.preset = 1
        Recipes.State.layers = nil
        check('texture matching gives every role a layer', table.getn(Recipes.MatchTextures(Recipes.Roles())) == table.getn(Recipes.Roles()))
    else
        table.insert(lines, '  skip paint mask tests (no mask)')
    end

    -- ---- scatter ---------------------------------------------------------------------------------------------------------------------------------
    local R1, R2 = Scatter.Stream_(5), Scatter.Stream_(5)
    local same, spread, sum = true, true, 0
    for i = 1, 500 do
        local a, b = R1.next(), R2.next()
        if a ~= b then same = false end
        if a < 0 or a >= 1 then spread = false end
        sum = sum + a
    end
    check('random stream is repeatable and in range', same and spread)
    check('random stream is spread evenly', near(sum / 500, 0.5, 0.06), sum / 500)
    check('other seeds give other values', Scatter.Stream_(6).next() ~= Scatter.Stream_(5).next())

    local blank = '/env/common/props/markers/M_Blank_prop.bp'
    Scatter.Entries = { { bp = blank, weight = 1 } }
    Scatter.Density = { rules = {} }
    local S0 = Scatter.Settings
    local keep = {}
    for k, val in S0 do keep[k] = val end
    S0.seed, S0.count, S0.minDist, S0.fill, S0.slopeMin, S0.slopeMax, S0.margin, S0.avoidExisting, S0.underWater = 3, 200, 9, 1, 0, 90, 4, true, true
    local plan, report = Scatter.Plan()
    check('scatter plans props', plan and table.getn(plan) >= 100, plan and table.getn(plan) or tostring(report))
    local plan2 = Scatter.Plan()
    local identical = plan and plan2 and table.getn(plan) == table.getn(plan2)
    if identical then
        for i = 1, table.getn(plan) do
            if plan[i].x ~= plan2[i].x or plan[i].z ~= plan2[i].z or plan[i].heading ~= plan2[i].heading then identical = false break end
        end
    end
    check('scatter is deterministic', identical)
    local closest = 1e9
    if plan then
        for i = 1, table.getn(plan) do
            for j = i + 1, table.getn(plan) do
                local dx, dz = plan[i].x - plan[j].x, plan[i].z - plan[j].z
                closest = math.min(closest, math.sqrt(dx * dx + dz * dz))
            end
        end
    end
    check('minimum distance holds', closest >= 9 - 0.001, closest)
    S0.seed = 4
    local plan3 = Scatter.Plan()
    check('another seed, another layout', plan3 and plan and (plan3[1].x ~= plan[1].x or plan3[1].z ~= plan[1].z))
    S0.seed = 3

    -- density mask and limits
    Scatter.Density = steep
    local dens = Scatter.Plan()
    local onRamp = dens ~= nil and table.getn(dens) > 20
    if dens then for _, p in dens do if p.x < mid - 2 then onRamp = false end end end
    check('density mask keeps props on the ramp', onRamp, dens and table.getn(dens))
    Scatter.Density = { rules = {} }
    S0.slopeMax = 10
    local flat = Scatter.Plan()
    local onFlat = flat ~= nil and table.getn(flat) > 20
    if flat then for _, p in flat do if p.x > mid + 2 then onFlat = false end end end
    check('slope limit keeps props on the flat', onFlat, flat and table.getn(flat))
    S0.slopeMax = 90
    S0.heightMax = 30
    local low = Scatter.Plan()
    local onLow = low ~= nil and table.getn(low) > 20
    if low then for _, p in low do if p.x > mid + 10 then onLow = false end end end
    check('height limit', onLow)
    S0.heightMax = 600

    -- symmetry
    local oldMode = Symmetry.Mode
    Symmetry.Mode = 'mirror_x'
    local sym = Scatter.Plan()
    local closed = sym ~= nil and table.getn(sym) > 20
    if sym then
        local cx = Symmetry.Centre()
        for _, p in sym do
            local mx = 2 * cx - p.x
            local found = math.abs(mx - p.x) < 0.6       -- on the axis the image is the prop itself
            for _, q in sym do
                if math.abs(q.x - mx) < 0.02 and math.abs(q.z - p.z) < 0.02 then found = true break end
            end
            if not found then closed = false end
        end
    end
    check('symmetric scatter is closed under the mirror', closed)
    Symmetry.Mode = oldMode

    -- apply and undo
    S0.count = 120
    local placed = Scatter.Apply()
    check('scatter places props', placed and placed >= 60 and ed_prop_count() == startProps + placed, tostring(placed))
    local first = { ed_prop_get(startProps + 1) }
    check('props stand on the ground', near(first[3], ed_terrain_get(math.floor(first[2] + 0.5), math.floor(first[4] + 0.5)), 0.01))
    History.Undo()
    check('scatter undo removes them', ed_prop_count() == startProps, ed_prop_count() .. ' vs ' .. startProps)
    History.Redo()
    check('scatter redo places them again', ed_prop_count() == startProps + (placed or 0))
    History.Undo()
    -- decals
    local catalog = import('/lua/editor/decals.lua').Catalog()
    if table.getn(catalog) > 0 then
        local startDecals = ed_decal_count()
        S0.mode, S0.count, S0.minDist, S0.withNormals = 'decals', 40, 12, true
        Scatter.DecalEntries = { { bp = catalog[1].path, weight = 1 } }
        local dplan = Scatter.Plan()
        check('decal scatter plans', dplan and table.getn(dplan) >= 20, dplan and table.getn(dplan))
        local spots = Scatter.Apply()
        local added = ed_decal_count() - startDecals
        check('decal scatter places decals (and their normals)', spots and spots >= 20 and added >= spots and added <= 2 * spots, tostring(spots) .. ' / ' .. added)
        History.Undo()
        check('decal scatter undo', ed_decal_count() == startDecals, ed_decal_count() .. ' vs ' .. startDecals)
        History.Redo()
        check('decal scatter redo', ed_decal_count() == startDecals + added)
        History.Undo()
        Scatter.DecalEntries = {}
    else
        table.insert(lines, '  skip decal scatter (no decal textures)')
    end
    for k, val in keep do S0[k] = val end
    Scatter.Entries = {}

    -- ---- clean up --------------------------------------------------------------------------------------------------------------------------------
    MaskGen.ClearPreview()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    if ed_stratum_info() then for i = 1, 8 do Strata.ClearMask(i) end end
    check('no field leaks', ed_field_count() == startFields, ed_field_count() .. ' vs ' .. startFields)
    check('no prop leaks', ed_prop_count() == startProps)

    local shown = lines
    if not verbose then       -- only what failed (the command channel cuts long answers); Run(true) lists every check
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
