-- Self test of the Stratum recipes and the role detection (recipes.lua, roledetect.lua, texsets.lua RoleLayer). Run in the live editor:
--   return import('/lua/editor/selftest_recipes.lua').Run()
-- Returns a report; the first line is PASS or FAIL. The first half needs no map (names, colours from synthetic pixels, the plan for a base of sand / snow / grass, the rules); the second half
-- (needs a terrain with paint masks) makes a scratch terrain, gives the layers FAKE textures through roledetect.Fake (no file is touched), applies the recipe and measures the masks. It leaves the
-- map flat 25 with clean masks, like selftest_maskgen.lua.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Detect = import('/lua/editor/roledetect.lua')

--- A 16 x 16 reduction of one colour with a little texture (a repeating pattern of +-5 steps).
local function Solid(r, g, b)
    local px = {}
    for i = 0, 255 do
        local j = (math.mod(i * 37, 11) - 5)
        px[i * 4 + 1] = math.max(0, math.min(255, r + j))
        px[i * 4 + 2] = math.max(0, math.min(255, g + j))
        px[i * 4 + 3] = math.max(0, math.min(255, b + j))
        px[i * 4 + 4] = 255
    end
    return px
end

--- Fake albedo paths { [layer] = role } -> { [layer] = '/fake/<role>_albedo.dds' }
local function FakeLayers(assign)
    local a = {}
    for layer, role in assign do a[layer] = '/fake/' .. role .. '_albedo.dds' end
    return a
end

local function Count(t)
    local n = 0
    for _ in t do n = n + 1 end
    return n
end

local function Has(list, value)
    for _, v in list do
        if v == value then return true end
    end
    return false
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

    local fake0, over0, layers0, types0, preset0 = Detect.Fake, Detect.Overrides, Recipes.State.layers, Recipes.State.types, Recipes.State.preset
    local knobs0 = {}
    for k, v in Recipes.Knobs do knobs0[k] = v end
    local shader0
    if rawget(_G, 'ed_stratum_shader') and rawget(_G, 'ed_stratum_info') and ed_stratum_info() then
        shader0 = ed_stratum_shader()
        if shader0 ~= 'TTerrainXP' then ed_stratum_shader('TTerrainXP') end          -- eight painted layers; the cap checks switch it and put it back
    end
    Detect.Overrides = {}                   -- the user's own choices stay out of the test (and nothing is written to the settings)
    Recipes.State.layers = nil
    Recipes.State.types = false
    Recipes.SelectPreset(1)
    Recipes.Invalidate()

    -- ---- names ---------------------------------------------------------------------------------------------------------------------------------
    local names = {
        { 'grass000_albedo.dds', 'grass' }, { 'EvGrass005a_albedo.dds', 'grass' }, { 'TrBush_moss_albedo.dds', 'grass' }, { 'Sw_Sphagnum_01_albedo.dds', 'grass' },
        { 'SandLight_albedo.dds', 'sand' }, { 'Des_SandMed02_albedo.dds', 'sand' }, { 'DrySand001_albedo.dds', 'sand' }, { 'beach_albedo.dds', 'sand' }, { 'dune01_albedo.dds', 'sand' },
        { 'Sandwet_albedo.dds', 'wet' }, { 'Tund_melt001_albedo.dds', 'wet' }, { 'LAV_Lava01_albedo.dds', 'wet' },
        { 'Dirt001_albedo.dds', 'dirt' }, { 'Eg_Gravel003_albedo.dds', 'dirt' }, { 'Sw_Mudder_01_albedo.dds', 'dirt' }, { 'Tr_ground001_albedo.dds', 'dirt' },
        { 'RockMed_albedo.dds', 'rock' }, { 'Cliff_albedo.dds', 'rock' }, { 'Tund_Rock02_albedo.DDS', 'rock' }, { 'granite_albedo.dds', 'rock' },
        { 'RockLight_albedo.dds', 'highrock' }, { 'Tund_iceRock_albedo.dds', 'highrock' }, { 'peak_albedo.dds', 'highrock' },
        { 'RockDark_albedo.dds', 'darkrock' }, { 'obsidian_albedo.dds', 'darkrock' }, { 'ash_albedo.dds', 'darkrock' },
        { 'snow001_albedo.dds', 'snow' }, { 'Tund_Ice004_albedo.DDS', 'snow' }, { 'frost_albedo.dds', 'snow' },
        { 'SandRock_albedo.dds', 'rock' },
    }
    local bad = {}
    for _, n in names do
        local role = Detect.ClassifyName('/env/test/layers/' .. n[1])
        if role ~= n[2] then table.insert(bad, n[1] .. '=' .. tostring(role)) end
    end
    check('names: ' .. table.getn(names) .. ' file names give the right kind of ground', table.getn(bad) == 0, table.concat(bad, ', '))
    local r1, c1 = Detect.ClassifyName('/env/x/layers/macrotexture000_albedo.dds')
    check('names: a name with no known word says nothing', r1 == nil and c1 == 0)
    local _, cSure = Detect.ClassifyName('/x/sand_albedo.dds')
    local _, cMixed = Detect.ClassifyName('/x/GrassSand_albedo.dds')
    check('names: grass and sand in one name lower the confidence', cMixed < cSure, cMixed .. ' vs ' .. cSure)
    check('names: "sandwet" is wet, not sand', Detect.ClassifyName('/x/Sandwet_albedo.dds') == 'wet')
    check('names: camel case words (RockLight) are split', Detect.ClassifyName('/x/RockLight_albedo.dds') == 'highrock' and Detect.ClassifyName('/x/RockMed_albedo.dds') == 'rock')

    -- ---- colours (synthetic pixels through the pure classifier) -----------------------------------------------------------------------------
    local colours = {
        { 'olive grass', 95, 105, 55, 'grass' }, { 'bright grass', 70, 120, 40, 'grass' }, { 'dark moss', 40, 70, 30, 'grass' },
        { 'light sand', 200, 185, 145, 'sand' }, { 'medium sand', 185, 160, 115, 'sand' }, { 'pale sand', 225, 210, 170, 'sand' },
        { 'brown dirt', 110, 85, 60, 'dirt' }, { 'dark soil', 80, 60, 42, 'dirt' },
        { 'grey rock', 120, 118, 115, 'rock' }, { 'dark rock', 60, 58, 56, 'darkrock' }, { 'black rock', 30, 30, 32, 'darkrock' }, { 'pale rock', 190, 190, 195, 'highrock' },
        { 'snow', 240, 242, 248, 'snow' }, { 'blue ice', 170, 200, 225, 'snow' },
        { 'dark water', 40, 60, 90, 'wet' },
    }
    local badc = {}
    for _, c in colours do
        local f = Detect.Features(Solid(c[2], c[3], c[4]), 16, 16)
        local role, conf = Detect.ClassifyColour(f)
        if role ~= c[5] then table.insert(badc, c[1] .. '=' .. tostring(role)) end
    end
    check('colours: ' .. table.getn(colours) .. ' synthetic textures give the right kind of ground', table.getn(badc) == 0, table.concat(badc, ', '))
    local fs = Detect.Features(Solid(200, 185, 145), 16, 16)
    local fg = Detect.Features(Solid(95, 105, 55), 16, 16)
    check('colours: sand is yellow-tan (hue below 60, no green dominance), grass is green dominant', fs.hue < 60 and fs.gdom < 0.02 and fg.gdom > 0.02 and fg.hue > 60, fs.hue .. ' ' .. fg.gdom)
    check('colours: no pixels, no answer', Detect.Features({}, 0, 0) == nil and Detect.ClassifyColour(nil) == nil)

    -- ---- the decision ----------------------------------------------------------------------------------------------------------------------
    local role, conf, src = Detect.Decide(nil, 0, {}, false, false, 'sand', 0.9)
    check('decide: no name, the colour decides', role == 'sand' and src == 'colour' and conf < 0.9)
    role = Detect.Decide('grass', 0.57, { grass = 1, sand = 1 }, false, false, 'sand', 0.9)
    check('decide: a name with grass AND sand: the colour settles it (sand)', role == 'sand')
    role = Detect.Decide('sand', 0.57, { grass = 1, sand = 1 }, false, false, 'grass', 0.9)
    check('decide: ... and the other way (grass)', role == 'grass')
    role, conf = Detect.Decide('grass', 0.95, { grass = 1 }, false, false, 'sand', 0.95)
    check('decide: a clear name beats a tan colour, with less confidence', role == 'grass' and conf < 0.7, tostring(conf))
    role = Detect.Decide('grass', 0.7, { grass = 0.6 }, false, false, 'sand', 0.9)
    check('decide: a weak name against a sure colour: the colour wins (grass vs sand)', role == 'sand')
    role = Detect.Decide('rock', 0.95, { rock = 1 }, true, false, 'darkrock', 0.9)
    check('decide: a rock by name is refined by the colour (dark rock)', role == 'darkrock')
    role = Detect.Decide('rock', 0.95, { rock = 1 }, true, false, 'highrock', 0.9)
    check('decide: ... (high rock)', role == 'highrock')
    role = Detect.Decide('rock', 0.95, { rock = 1 }, true, false, 'sand', 0.9)
    check('decide: a rock name is not turned into sand by the colour', role == 'rock')
    -- through Classify with fake pixels
    Detect.Fake = { albedo = {}, pixels = {
        ['/fake/mystery_albedo.dds'] = { Solid(200, 185, 145), 16, 16 },
        ['/fake/mystery2_albedo.dds'] = { Solid(70, 120, 40), 16, 16 },
        ['/fake/RockX_albedo.dds'] = { Solid(55, 55, 58), 16, 16 },
    } }
    local cm = Detect.Classify('/fake/mystery_albedo.dds')
    check('classify: an unnamed tan texture is sand (colour)', cm.role == 'sand' and cm.source == 'colour' and cm.conf > 0.3)
    cm = Detect.Classify('/fake/mystery2_albedo.dds')
    check('classify: an unnamed green texture is grass', cm.role == 'grass')
    cm = Detect.Classify('/fake/RockX_albedo.dds')
    check('classify: a rock by name, dark by colour: dark rock', cm.role == 'darkrock')

    -- ---- the plan: any layer can hold any kind ---------------------------------------------------------------------------------------------------
    local all = { 'grass', 'dirt', 'wet', 'sand', 'rock', 'darkrock', 'highrock', 'snow' }
    local function PlanOf(assign)
        Detect.Fake = { albedo = FakeLayers(assign), pixels = {} }
        return Recipes.Plan()
    end
    local function RuleCount(roles, id)
        for _, r in roles do
            if r.id == id then return table.getn(r.rules), r end
        end
    end
    local plan = PlanOf({ [0] = 'sand', [1] = 'grass', [3] = 'snow' })
    check('plan: base = sand, grass on layer 1, snow on layer 3', plan.base == 'sand' and plan.byRole.grass[1] == 1 and plan.byRole.snow[1] == 3)
    check('plan: kinds with no texture are missing, not painted', Has(plan.missing, 'rock') and Has(plan.missing, 'dirt') and not Has(plan.missing, 'sand'))
    local roles = Recipes.Roles(Recipes.Context(plan))
    local nSand, rSand = RuleCount(roles, 'sand')
    local nGrass, rGrass = RuleCount(roles, 'grass')
    check('base sand: the sand (beach) rule is dropped, sand is the base', rSand.base and nSand == 0)
    check('base sand: grass takes the open ground (it has rules)', not rGrass.base and nGrass >= 3)
    local nSnow, rSnow = RuleCount(roles, 'snow')
    check('base sand: snow still has its rules', not rSnow.base and nSnow >= 3)

    plan = PlanOf({ [0] = 'snow', [1] = 'grass', [2] = 'rock' })
    roles = Recipes.Roles(Recipes.Context(plan))
    nSnow, rSnow = RuleCount(roles, 'snow')
    nGrass, rGrass = RuleCount(roles, 'grass')
    local hasHeight = false
    for _, rule in rGrass.rules do
        if rule.type == 'height' then hasHeight = true end
    end
    check('base snow: no snow rule, snow is the base', rSnow.base and nSnow == 0)
    check('base snow: grass stays below the snow line (height rule)', hasHeight)

    plan = PlanOf({ [0] = 'grass', [1] = 'sand', [2] = 'rock' })
    roles = Recipes.Roles(Recipes.Context(plan))
    nGrass, rGrass = RuleCount(roles, 'grass')
    nSand, rSand = RuleCount(roles, 'sand')
    check('base grass: grass is what is left (no rules)', rGrass.base and nGrass == 0)
    check('base grass: sand keeps its beach rule', not rSand.base and nSand >= 2)

    plan = PlanOf({ [3] = 'rock', [5] = 'grass' })
    check('empty base: no kind assumed for it', plan.base == nil and plan.has.grass and plan.has.rock)
    roles = Recipes.Roles(Recipes.Context(plan))
    nGrass, rGrass = RuleCount(roles, 'grass')
    check('empty base: grass has its own rules', not rGrass.base and nGrass >= 3)

    local assign8 = { [0] = 'grass' }
    for i = 2, 8 do assign8[i - 1] = all[i] end
    plan = PlanOf(assign8)
    check('plan: eight kinds on eight layers use all of them', Count(plan.has) == 8 and table.getn(plan.missing) == 0)
    local reversed = { [0] = 'grass' }
    for i = 2, 8 do reversed[8 - i + 1] = all[i] end
    local plan2 = PlanOf(reversed)
    local same = true
    for id, _ in plan.has do
        if not plan2.has[id] then same = false end
    end
    check('plan: the kinds present do not depend on the layer order', same and Count(plan2.has) == 8 and plan2.base == 'grass')

    plan = PlanOf({ [0] = 'grass', [1] = 'grass', [2] = 'rock', [4] = 'grass' })
    check('plan: three grass layers: the lowest is the base, the others are variants', table.getn(plan.byRole.grass) == 3 and plan.byRole.grass[1] == 0)

    Detect.Fake = { albedo = { [0] = '/fake/grass_albedo.dds', [1] = '/fake/zzz_albedo.dds' }, pixels = {} }
    plan = Recipes.Plan()
    check('plan: a texture nothing is known about is left alone', Has(plan.unknown, 1) and not plan.has.dirt)
    Detect.Overrides = { ['/fake/zzz_albedo.dds'] = 'dirt' }
    plan = Recipes.Plan()
    check('plan: the user\'s choice for a texture is used', plan.has.dirt and plan.byRole.dirt[1] == 1)
    Detect.Overrides = { ['/fake/grass_albedo.dds'] = 'none' }
    plan = Recipes.Plan()
    check('plan: "Not used" leaves a layer out', not plan.has.grass and Has(plan.unknown, 0))
    Detect.Overrides = {}

    -- the rules only use rule types and settings the mask generator has
    local okRules = true
    local worst
    for _, p in Recipes.Presets do
        local idx
        for i, q in Recipes.Presets do if q == p then idx = i end end
        Recipes.SelectPreset(idx)
        for _, base in { 'none', 'grass', 'sand', 'snow', 'rock' } do
            local cx = { base = (base ~= 'none') and base or nil, has = { grass = true, sand = true, snow = true } }
            for _, role in Recipes.Roles(cx) do
                for _, rule in role.rules do
                    local t = MaskGen.Types[rule.type]
                    if not t then okRules = false worst = rule.type end
                    if t then
                        local keys = {}
                        for _, prm in t.params do keys[prm.key] = true end
                        for k, v in rule.v do
                            if not keys[k] or type(v) ~= 'number' or v ~= v then okRules = false worst = rule.type .. '.' .. k end
                        end
                    end
                end
            end
        end
    end
    check('rules: every rule of every style and base is a valid maskgen rule with numbers', okRules, worst)
    Recipes.SelectPreset(1)

    -- layout helpers
    local TS = import('/lua/editor/texsets.lua')
    check('texsets: grass is layer 1, snow layer 8', TS.RoleLayer('grass') == 1 and TS.RoleLayer('snow') == 8 and TS.RoleLayer('nothing') == nil)
    local pct = Recipes.Percentiles({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, nil)
    check('percentiles: the median of 1..10 is about 5, the ends are the extremes', pct and near(pct[51], 5, 0.1) and pct[1] == 1 and pct[101] == 10)
    local pctLand = Recipes.Percentiles({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, 6)
    check('percentiles: only the values above the minimum count', pctLand and pctLand[1] == 6 and pctLand[101] == 10)

    -- ---- on a map ----------------------------------------------------------------------------------------------------------------------------
    local w, h = nil, nil
    if rawget(_G, 'ed_terrain_info') then w, h = ed_terrain_info() end
    if Fields.IsAvailable() and w and w >= 129 and rawget(_G, 'ed_stratum_info') and ed_stratum_info() and rawget(_G, 'ed_field_count') then
        local Terrain = import('/lua/editor/terrain.lua')
        local Strata = import('/lua/editor/strata.lua')
        local startFields = ed_field_count()
        for i = 1, 8 do Strata.ClearMask(i) end
        -- hills with steep flanks, peaks and basins
        Fields.Run(function(S)
            local like = S:Height(1)
            local n1 = S:Op('perlin', { like = like, seed = 7, scale = 80, octaves = 5 })
            local n2 = S:Op('ridged', { like = like, seed = 11, scale = 120, octaves = 4 })
            local hgt = S:Op('add', { a = S:Op('affine', { a = n1, mul = 90, add = -15 }), b = S:Op('affine', { a = n2, mul = 40, add = 0 }) })
            Fields.CommitHeight(hgt, { label = 'selftest recipe terrain', noHistory = true })
        end)
        Terrain.ClearHistory()
        History.Clear()
        Recipes.Invalidate()

        local function Seen(assign)
            local cov = Recipes.Coverage()
            local seen, total = {}, 0
            if not cov then return nil end
            for layer, role in assign do
                seen[role] = (seen[role] or 0) + (cov.seen[layer] or 0)
                total = total + (cov.seen[layer] or 0)
            end
            return seen, total, cov
        end
        local function Run1(assign, label)
            Detect.Fake = { albedo = FakeLayers(assign), pixels = {} }
            local depth = History.Version
            local summary, cells = Recipes.Apply()
            check(label .. ': the recipe applies', summary ~= nil, tostring(cells))
            if not summary then return nil end
            check(label .. ': one undo step', History.Version == depth + 1, History.Version - depth)
            return summary
        end

        -- all eight kinds on nine layers (a second grass layer makes the ninth)
        local A = { [0] = 'grass' }
        for i = 2, 8 do A[i - 1] = all[i] end
        A[8] = 'grass'
        local summary = Run1(A, 'eight kinds')
        if summary then
            local sum = 0
            for _, e in summary do sum = sum + e.share end
            check('eight kinds: the shares add up to the whole map', near(sum, 1, 0.03), sum)
            local seenA, totalA, cov = Seen(A)
            check('eight kinds: what the layers show adds up to the whole map', near(totalA, 1, 0.03), totalA)
            local used = 0
            local empty = {}
            for layer = 1, 7 do
                if cov.mask[layer] and cov.mask[layer] > 0.001 then used = used + 1 else table.insert(empty, A[layer] or layer) end
            end
            check('eight kinds: at least six of the seven kind layers are painted on a varied terrain', used >= 6, 'unpainted: ' .. table.concat(empty, ', '))
            check('eight kinds: the second grass layer holds patches inside the grass', cov.mask[8] ~= nil and cov.mask[8] > 0.001, tostring(cov.mask[8]))
            -- no cell with two layers at full opacity
            local worstFull = Fields.Run(function(S)
                local sum1
                for layer = 1, 8 do
                    local full = S:Op('threshold', { a = S:Stratum(layer), value = 0.99 })
                    sum1 = sum1 and S:Op('add', { a = sum1, b = full }) or full
                end
                local _, mx = Fields.Stats(sum1)
                return mx
            end)
            check('mask sanity: no cell has two layers at full opacity', worstFull <= 1.001, worstFull)
            History.Undo()

            -- another order of the same kinds: the same visible shares
            local B = { [0] = 'grass' }
            for i = 2, 8 do B[8 - i + 1] = all[i] end
            B[8] = 'grass'
            Run1(B, 'reversed layers')
            local seenB = Seen(B)
            local sameShare = true
            local worstRole
            for role, v in seenA do
                if not seenB or not near(v, seenB[role], 0.03) then sameShare = false worstRole = role end
            end
            check('layer order does not change what is seen of each kind', sameShare, tostring(worstRole))
            History.Undo()
        end

        -- the base layer is any kind
        local Bs = { [0] = 'sand', [1] = 'grass', [2] = 'rock', [3] = 'snow', [4] = 'dirt', [5] = 'wet', [6] = 'darkrock', [7] = 'highrock' }
        local sumS = Run1(Bs, 'base sand')
        if sumS then
            local seenS, totalS = Seen(Bs)
            check('base sand: shares add up', near(totalS, 1, 0.03), totalS)
            check('base sand: grass covers the open ground, not the sand', seenS.grass > 0.02 and seenS.sand >= 0, tostring(seenS.grass))
            History.Undo()
        end
        local Bn = { [0] = 'snow', [1] = 'grass', [2] = 'rock', [3] = 'sand', [4] = 'dirt', [5] = 'wet', [6] = 'darkrock', [7] = 'highrock' }
        local sumN = Run1(Bn, 'base snow')
        if sumN then
            local _, totalN = Seen(Bn)
            check('base snow: shares add up', near(totalN, 1, 0.03), totalN)
            History.Undo()
        end

        -- kinds with no texture are skipped: their layers are not touched
        local M = { [0] = 'grass', [1] = 'rock', [2] = 'sand' }
        local sumM = Run1(M, 'three kinds')
        if sumM then
            local cov = Recipes.Coverage()
            check('three kinds: the other layers keep empty masks', cov.mask[3] == nil and cov.mask[4] == nil)
            check('three kinds: only the three kinds are reported', table.getn(sumM) == 3, table.getn(sumM))
            History.Undo()
        end

        -- a shader that paints 4 layers: the roles on layers 5-8 are not used
        ed_stratum_shader('TTerrainGlow')
        if Recipes.Cap() == 4 then
            local C = { [0] = 'grass' }
            for i = 2, 8 do C[i - 1] = all[i] end
            Detect.Fake = { albedo = FakeLayers(C), pixels = {} }
            local planC = Recipes.Plan()
            check('4-layer shader: the kinds on layers 5-8 are beyond the shader', table.getn(planC.beyond) == 3 and not planC.has.snow and planC.has.rock)
            local auto = Recipes.AutoLayers(Recipes.Roles())
            local kept = 0
            for _, l in auto do if l >= 1 then kept = kept + 1 end end
            check('4-layer shader: the texture set layout keeps four kinds (grass, rock, sand, dirt first)', kept == 4 and auto[1] == 1 and auto[5] == 2 and auto[4] == 3 and auto[2] == 4, table.concat(auto, ','))
            local sumC = Run1(C, '4-layer shader')
            if sumC then
                local cov = Recipes.Coverage()
                check('4-layer shader: layers 5-8 are not painted', cov.mask[5] == nil and cov.mask[6] == nil)
                History.Undo()
            end
        else
            table.insert(lines, '  skip the 4-layer shader checks (TTerrainGlow does not cap at 4 here)')
        end
        ed_stratum_shader('TTerrainXP')
        -- the numbered shaders paint 7: the kinds on layer 8 are beyond
        ed_stratum_shader('Terrain200')
        if Recipes.Cap() == 7 then
            Detect.Fake = { albedo = FakeLayers(A), pixels = {} }
            local planD = Recipes.Plan()
            check('7-layer shader: a texture on layer 8 is beyond the shader', Has(planD.beyond, 8))
        end
        ed_stratum_shader('TTerrainXP')

        -- clean up
        MaskGen.ClearPreview()
        ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
        Terrain.ClearHistory()
        History.Clear()
        for i = 1, 8 do Strata.ClearMask(i) end
        Recipes.Invalidate()
        check('no field leaks', ed_field_count() == startFields, ed_field_count() .. ' vs ' .. startFields)
    else
        table.insert(lines, '  skip the map checks (no terrain with paint masks)')
    end

    if shader0 and ed_stratum_shader() ~= shader0 then ed_stratum_shader(shader0) end
    Detect.Fake, Detect.Overrides = fake0, over0
    Recipes.State.layers, Recipes.State.types, Recipes.State.preset = layers0, types0, preset0
    for k, v in knobs0 do Recipes.Knobs[k] = v end
    Recipes.Invalidate()

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
    return 'PASS recipes\n' .. table.concat(shown, '\n')
end
