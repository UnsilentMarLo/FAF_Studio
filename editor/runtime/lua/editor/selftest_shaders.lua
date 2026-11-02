-- Self test of the shader awareness of the texturing tools: the layer layout per shader (texsets.lua Layout), the known texture sets (RoleOfTexture), the stratum recipes on every shader family
-- (kinds of ground on the right layers, side-mapped layers only steep, nothing on a layer the shader does not paint), the generators that make the pictures a shader needs from the paint
-- (macrotexture, specular, roughness / height atlas, roughness mask), the graph outputs for them (Output: ground kind and the others) and the layer conversion between the shader families.
-- Run in the live editor:   return import('/lua/editor/selftest_shaders.lua').Run()
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local TS = import('/lua/editor/texsets.lua')
local Recipes = import('/lua/editor/recipes.lua')
local Strata = import('/lua/editor/strata.lua')
local Shaders = import('/lua/editor/shaders.lua')
local MT = import('/lua/editor/maptextures.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
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

    -- ---- the layout of the kinds of ground per shader (no map needed) ---------------------------------------------------------------------------------------
    local L8 = TS.Layout({ painted = 8 })
    check('8 painted layers: the standard layout', L8.grass == 1 and L8.rock == 2 and L8.sand == 3 and L8.dirt == 4 and L8.wet == 5 and L8.highrock == 6 and L8.darkrock == 7 and L8.snow == 8)
    local L7 = TS.Layout({ painted = 7 })
    check('7 painted layers: no dark rock, snow on layer 7', L7.darkrock == nil and L7.snow == 7 and L7.rock == 2)
    local L4 = TS.Layout({ painted = 4 })
    check('4 painted layers: rock, sand, dirt, snow (grass is the base)', L4.rock == 1 and L4.sand == 2 and L4.dirt == 3 and L4.snow == 4 and L4.grass == nil and L4.wet == nil)
    local LB = TS.Layout({ painted = 7, biplanar = true })
    check('biplanar: rock and high rock on the side-mapped layers 3 and 4, sand and dirt out of them', LB.rock == 3 and LB.highrock == 4 and LB.sand == 2 and LB.dirt ~= 3 and LB.dirt ~= 4 and LB.snow == 7)
    local taken, dup = {}, false
    for _, p in { { painted = 8 }, { painted = 7 }, { painted = 4 }, { painted = 7, biplanar = true } } do
        local seen = {}
        for _, l in TS.Layout(p) do
            if seen[l] then dup = true end
            seen[l] = true
        end
    end
    check('no two kinds share a layer in any layout', not dup)
    check('RoleLayer(role, false) is the standard layout', TS.RoleLayer('snow', false) == 8 and TS.RoleLayer('grass', false) == 1)

    -- ---- known textures ------------------------------------------------------------------------------------------------------------------------------------
    check('RoleOfTexture: a texture of a set on its layer', TS.RoleOfTexture('/env/Evergreen/layers/RockMed_albedo.dds', 2) == 'rock' and TS.RoleOfTexture('/env/Evergreen/layers/SandRock_albedo.dds', 7) == 'darkrock')
    check('RoleOfTexture: the same texture, other case and slashes', TS.RoleOfTexture('\\env\\evergreen\\layers\\rockmed_albedo.dds', nil) == 'rock')
    check('RoleOfTexture: a texture the sets do not list', TS.RoleOfTexture('/env/Evergreen/layers/nothing_albedo.dds', 3) == nil)
    check('RoleOfTexture: the base layer holds grass', TS.RoleOfTexture('/env/Evergreen/layers/grass001_albedo.dds', 0) == 'grass')

    -- ---- on a map -----------------------------------------------------------------------------------------------------------------------------------------
    local w = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    if not w or not rawget(_G, 'ed_stratum_info') or not Fields.IsAvailable() then
        table.insert(lines, '  (no map with paint masks: the rest is skipped)')
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks, no map)\n' .. Join(lines, '\n')
    end
    local shader0 = ed_stratum_shader()
    pcall(function() import('/lua/editor/graphrun.lua').Release() end)
    pcall(function() import('/lua/editor/maskgen.lua').ClearPreview() end)
    local startFields = ed_field_count()
    local gpuWas = rawget(_G, 'ed_gpu_info') and ed_gpu_info(false).enabled
    if rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(false) end
    History.Clear()
    Recipes.Invalidate()

    -- a varied terrain
    local Gen = import('/lua/editor/fieldgen.lua')
    local savedSettings = {}
    for k, v in Gen.Settings do savedSettings[k] = v end
    Gen.Choose('mountains')
    Gen.Settings.seed = 4
    Gen.Settings.blend = 'replace'
    Gen.Settings.keepFlat = false
    Gen.Settings.keepWater = false
    local built = Gen.Build()
    check('a terrain to texture', built ~= nil)
    if built then
        Gen.Commit(built)
        Gen.Free(built)
    end
    Recipes.Invalidate()

    local function Max(layer)
        return Fields.Run(function(S)
            local _, mx = Fields.Stats(S:Stratum(layer, true))
            return mx
        end)
    end
    local function MeanOnFlat(layer, maxDeg)
        return Fields.Run(function(S)
            local m = S:Stratum(layer)
            local slope = S:Op('resample', { a = S:Op('slope', { a = S:Height(1), mode = 'degrees' }), like = m })
            local flat = S:Op('threshold', { a = S:Op('affine', { a = slope, mul = -1, add = maxDeg }), value = 0 })
            local _, _, mean = Fields.Stats(S:Op('mul', { a = m, b = flat }))
            return mean
        end)
    end

    local function ClearMasks()
        Fields.Run(function(S)
            local zero = S:Op('const', { like = S:Height(1), value = 0 })
            for l = 1, 8 do
                local entry = Fields.CommitMask(zero, l, { raw = true, noPush = true })
                if entry and entry.release then entry.release() end
            end
        end)
    end
    for _, shader in { 'TTerrain', 'TTerrainXP', 'Terrain000', 'Terrain250', 'Terrain200B', 'Terrain100B' } do
        ClearMasks()
        local ok = Shaders.Set(shader, true)
        if ok then
            local P = Strata.Profile()
            local cap = Strata.PaintCap()
            TS.Apply('temperate')
            Recipes.Invalidate()
            Recipes.State.layers = nil
            Recipes.SelectPreset(1)
            local layout = TS.Layout()
            local plan = Recipes.Plan()
            local wrong = {}
            for role, layer in layout do
                local found = false
                for _, l in (plan.byRole[role] or {}) do
                    if l == layer then found = true end
                end
                if not found then table.insert(wrong, role .. ' ' .. tostring(plan.byRole[role] and plan.byRole[role][1]) .. '/' .. layer) end
            end
            check(shader .. ': the texture set puts every kind on the layer of the layout, and the recipe finds it there', table.getn(wrong) == 0, Join(wrong, ', '))
            local summary, cells = Recipes.Apply()
            check(shader .. ': the recipe paints', summary ~= nil, tostring(cells))
            local beyond = {}
            for l = cap + 1, 8 do
                if P.l8 ~= 'rough' or l ~= 8 then
                    if Max(l) > ((Shaders.RangeOf(shader) == 'half') and 127 or 0) then table.insert(beyond, l) end
                end
            end
            check(shader .. ': nothing is painted on a layer the shader does not paint', table.getn(beyond) == 0, Join(beyond, ', '))
            if P.biplanar then
                local stretched = {}
                for _, l in { 3, 4 } do
                    local flat = MeanOnFlat(l, 8)
                    if flat > 0.02 then table.insert(stretched, l .. ': ' .. string.format('%.3f', flat)) end
                end
                check(shader .. ': the side-mapped layers 3 and 4 hold paint on steep ground only', table.getn(stretched) == 0, Join(stretched, ', '))
            end
            -- the generators the shader needs
            local class = P.class
            if MT.Slot('macro') then
                local e, err = MT.Generate('macro', { size = 128 })
                check(shader .. ': macrotexture made from the paint', e ~= nil and string.find(string.lower(ed_stratum_layer(9) or ''), 'maptex_macro_', 1, true) ~= nil, tostring(err))
            end
            if MT.Slot('specular') then
                local e, err = MT.Generate('specular', { size = 128 })
                check(shader .. ': specular texture made from the paint', e ~= nil, tostring(err))
            end
            if MT.Slot('atlas') then
                local e, err = MT.Generate('atlas', { size = 512 })
                check(shader .. ': roughness / height atlas made from the layers', e ~= nil and not MT.Current('atlas').empty, tostring(err))
                local before = Max(8)
                local e2, n = MT.GenerateRoughness({ amount = 0.7 })
                check(shader .. ': roughness mask written to layer 8', e2 ~= nil and n > 0, tostring(n))
            else
                local e, err = MT.GenerateRoughness({})
                check(shader .. ': no roughness mask where layer 8 is not one', e == nil)
            end
        end
    end

    -- ---- the graph outputs ---------------------------------------------------------------------------------------------------------------------------------
    local Graph = import('/lua/editor/graph.lua')
    local GRun = import('/lua/editor/graphrun.lua')
    local Nodes = import('/lua/editor/graphnodes.lua')
    check('the new nodes exist', Nodes.Defs.out_role and Nodes.Defs.out_macro and Nodes.Defs.out_specular and Nodes.Defs.out_atlas and Nodes.Defs.out_roughness)
    Shaders.Set('Terrain250', true)
    TS.Apply('temperate')
    Recipes.State.layers = nil
    Graph.New('shader outputs')
    local terrainNode = Graph.Add('terrain', 0, 200)
    local steep = Graph.Add('mask_preset', 0, 0)
    Graph.SetParam(steep.id, 'preset', 'cliffs')
    Graph.Connect(terrainNode.id, 'out', steep.id, 'a')
    local outRock = Graph.Add('out_role', 200, 0)
    Graph.SetParam(outRock.id, 'role', 'rock')
    Graph.Connect(steep.id, 'out', outRock.id, 'a')
    local outAtlas = Graph.Add('out_atlas', 200, 100)
    local outRough = Graph.Add('out_roughness', 200, 200)
    Graph.SetParam(outAtlas.id, 'size', '512')
    GRun.Refresh()
    local res, why = GRun.Build()
    check('a graph with ground kind, atlas and roughness outputs builds', res ~= nil, tostring(why))
    if res then
        check('Output: ground kind painted the layer of the kind', res.layers >= 1 and Max(TS.RoleLayer('rock')) > 0)
        check('the atlas output gave the Upper layer an atlas', not MT.Current('atlas').empty)
    end
    Graph.New('shader outputs 2')
    local t2 = Graph.Add('terrain', 0, 200)
    local m2 = Graph.Add('mask_preset', 0, 0)
    Graph.Connect(t2.id, 'out', m2.id, 'a')
    local outBase = Graph.Add('out_role', 200, 0)
    Graph.SetParam(outBase.id, 'role', 'grass')
    Graph.Connect(m2.id, 'out', outBase.id, 'a')
    GRun.Refresh()
    local res2, why2 = GRun.Build()
    check('a kind that is the base layer is skipped with a note, not an error', res2 ~= nil, tostring(why2))
    Graph.New('empty')
    GRun.Refresh()
    pcall(GRun.Release)

    -- ---- conversion between the families ----------------------------------------------------------------------------------------------------------------------
    local Conv = import('/lua/editor/stratumconv.lua')
    Shaders.Set('TTerrainXP', true)
    TS.Apply('temperate')
    Recipes.Invalidate()
    Recipes.State.layers = nil
    Recipes.SelectPreset(1)
    Recipes.Apply()
    for _, target in { 'TTerrain', 'Terrain000', 'Terrain050', 'Terrain001', 'Terrain100', 'Terrain150', 'Terrain200', 'Terrain250', 'Terrain200B', 'Terrain250B', 'TTerrainXPExt' } do
        ed_stratum_shader('TTerrainXP')
        Shaders.SetMaskState(false)
        local plan = Conv.Plan(target)
        if plan.refused then
            check('XP -> ' .. target .. ': not refused', false, plan.refused)
        else
            local rep, err = Conv.Run(plan, { layer8 = plan.default, textures = true, upper = true })
            check('XP -> ' .. target .. ': converts', rep ~= nil, tostring(err))
            if rep then
                check('XP -> ' .. target .. ': the shader is now ' .. target, ed_stratum_shader() == target)
                History.Undo()
                check('XP -> ' .. target .. ': undo gives TTerrainXP back', ed_stratum_shader() == 'TTerrainXP')
            end
        end
    end

    -- ---- back to how it was --------------------------------------------------------------------------------------------------------------------------------------
    ed_stratum_shader(shader0)
    Shaders.SetMaskState(false)
    for k, v in savedSettings do Gen.Settings[k] = v end
    ed_terrain_set_rect(0, 0, w - 1, w - 1, 25)         -- the scratch terrain goes, and with it the engine's own command stack (it holds fields)
    pcall(function() import('/lua/editor/terrain.lua').ClearHistory() end)
    History.Clear()
    Recipes.Invalidate()
    if gpuWas and rawget(_G, 'ed_gpu_enable') then ed_gpu_enable(true) end
    pcall(function() import('/lua/editor/graphrun.lua').Release() end)
    pcall(function() import('/lua/editor/maskgen.lua').ClearPreview() end)
    pcall(function() import('/lua/editor/graphrun.lua').DropBuildCache() end)
    for i = 1, 8 do Strata.ClearMask(i) end
    check('no field leaks', ed_field_count() <= startFields, ed_field_count() - startFields)
    if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
    return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
end
