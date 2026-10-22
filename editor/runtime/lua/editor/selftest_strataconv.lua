-- Self test of the shader layer data, the mask range of the shaders and Convert layers (shaders.lua, strata.lua Range, stratumconv.lua, recipes.lua Cap / FitLayers). Run in the live editor:
--   return import('/lua/editor/selftest_strataconv.lua').Run()
-- Returns a report; the first line is PASS or FAIL. Puts the shader, the layer textures and the paint masks back afterwards.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Shaders = import('/lua/editor/shaders.lua')
local Strata = import('/lua/editor/strata.lua')
local Conv = import('/lua/editor/stratumconv.lua')
local History = import('/lua/editor/history.lua')
local Recipes = import('/lua/editor/recipes.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Fields = import('/lua/editor/fields.lua')

local function Same(a, b)
    if not a or not b or table.getn(a) ~= table.getn(b) then return false end
    for i = 1, table.getn(a) do
        if a[i] ~= b[i] then return false end
    end
    return true
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

    -- the data (needs no terrain)
    check('TTerrainXP reads the half range', Shaders.RangeOf('TTerrainXP') == 'half' and Shaders.RangeOf('TTerrain') == 'half' and Shaders.RangeOf('TTerrainXPExt') == 'half')
    check('Terrain000 and the x0x shaders read the full range', Shaders.RangeOf('Terrain000') == 'full' and Shaders.RangeOf('Terrain200') == 'full' and Shaders.RangeOf('Terrain100B') == 'full')
    check('the x5x shaders read the half range', Shaders.RangeOf('Terrain050') == 'half' and Shaders.RangeOf('Terrain250') == 'half' and Shaders.RangeOf('Terrain151B') == 'half')
    check('layer counts', Shaders.Profile('TTerrain').painted == 4 and Shaders.Profile('TTerrainXP').painted == 8 and Shaders.Profile('Terrain200').painted == 7)
    check('layer 8 roles', Shaders.Profile('TTerrainXP').l8 == 'paint' and Shaders.Profile('Terrain200').l8 == 'rough' and Shaders.Profile('Terrain000').l8 == 'data')
    check('Terrain301 is not converted', Shaders.Profile('Terrain301').supported == false)
    local rows = Shaders.Rows('Terrain200')
    check('a layer table has ten rows (Base, 1-8, Upper)', rows and table.getn(rows) == 10 and rows[1].layer == 'Base' and rows[10].layer == 'Upper' and rows[9].layer == 'Layer 8')
    check('every listed shader has a table', (function()
        for _, s in Shaders.List() do
            if s.listed and not s.rows then return false end
        end
        return true
    end)())

    if not rawget(_G, 'ed_stratum_info') or not ed_stratum_info() or not import('/lua/editor/fields.lua').IsAvailable() then
        table.insert(lines, '  (no paint masks: the conversion checks are skipped)')
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. table.concat(lines, '\n') end
        return 'PASS strataconv (data only)\n' .. table.concat(lines, '\n')
    end

    -- save the map's state
    local shader0 = ed_stratum_shader()
    local w, h = ed_stratum_info()
    local layers0 = {}
    for i = 0, 9 do layers0[i] = Strata.Snapshot(i) end
    local masks0 = {}
    for s = 0, 7 do masks0[s] = ed_stratum_read(s, 0, 0, w - 1, h - 1) end

    local function Restore()
        ed_stratum_shader(shader0)
        for i = 0, 9 do
            if layers0[i].albedo ~= '' then Strata.Restore(layers0[i]) end
        end
        ed_stratum_shader(shader0)
        for s = 0, 7 do ed_stratum_write(s, 0, 0, w - 1, h - 1, masks0[s]) end
    end

    local ok, err = pcall(function()
        ed_stratum_shader('TTerrainXP')
        -- a known paint: layer 1 byte pattern 0 / 191 / 255 / 128 (half range), layer 8 painted (255 on the first row), the others empty
        local function Pattern(s)
            local t = {}
            for i = 1, w * h do t[i] = 0 end
            if s == 0 then
                local pat = { 0, 191, 255, 128 }
                for i = 1, w * h do t[i] = pat[math.mod(i - 1, 4) + 1] end
            elseif s == 7 then
                for i = 1, w do t[i] = 255 end
            end
            return t
        end
        for s = 0, 7 do ed_stratum_write(s, 0, 0, w - 1, h - 1, Pattern(s)) end
        for i = 1, 8 do Strata.SetTexture(i, '/env/evergreen/layers/dirt001_albedo.dds', nil, 10, 10) end

        local plan = Conv.Plan('Terrain000')
        check('plan: XP -> Terrain000 re-encodes and has layer 8 to place', plan.refused == nil and plan.fromP.range == 'half' and plan.toP.range == 'full' and table.getn(plan.extra) == 1 and plan.extra[1] == 8, plan.refused)
        check('plan: layers 2-7 are free, so layer 8 can move', plan.canMove == true and plan.default == 'move')
        local before = History.Top()
        local report, why = Conv.Run(plan, { layer8 = 'move', upper = false })
        check('the conversion runs', report ~= nil, why)
        if report then
            check('the shader changed', ed_stratum_shader() == 'Terrain000')
            check('one history entry', History.Top() ~= before and History.Top().label == 'convert layers to Terrain000')
            local m1 = ed_stratum_read(0, 0, 0, w - 1, h - 1)
            local ok1 = true
            local want = { 0, 127, 255, 1 }
            for i = 1, w * h do
                if m1[i] ~= want[math.mod(i - 1, 4) + 1] then ok1 = false end
            end
            check('layer 1 re-encoded to the full range (191 -> 127, 128 -> 1)', ok1)
            local m2 = ed_stratum_read(1, 0, 0, w - 1, h - 1)
            check('layer 8 paint moved to layer 2 (first row 255)', m2[1] == 255 and m2[w] == 255 and (w * h <= w or m2[w + 1] == 0), tostring(m2[1]))
            local m8 = ed_stratum_read(7, 0, 0, w - 1, h - 1)
            check('layer 8 mask cleared (Terrain000 does not paint it)', m8[1] == 0)
            -- the painting follows the range: a full strength dab gives 255 in both, half strength 128 (full) instead of 191 (half)
            check('Range() follows the shader', Strata.Range() == 'full')
            -- back
            local plan2 = Conv.Plan('TTerrainXP')
            local report2 = Conv.Run(plan2, {})
            check('the way back runs', report2 ~= nil)
            local m1b = ed_stratum_read(0, 0, 0, w - 1, h - 1)
            check('layer 1 is as it was after the round trip', Same(m1b, Pattern(0)))
            -- undo both
            History.Undo()
            History.Undo()
            check('undo restores the shader', ed_stratum_shader() == 'TTerrainXP')
            check('undo restores the masks', Same(ed_stratum_read(0, 0, 0, w - 1, h - 1), Pattern(0)) and Same(ed_stratum_read(7, 0, 0, w - 1, h - 1), Pattern(7)))
            History.Redo()
            History.Redo()
            History.Undo()
            History.Undo()
        end
        -- recipes follow the shader
        ed_stratum_shader('Terrain200')
        check('recipes: Terrain200 paints 7 layers', Recipes.Cap() == 7)
        local fit = Recipes.FitLayers({ 0, 1, 8 })
        check('recipes: a kind on layer 8 moves to layer 7', fit[3] == 7, tostring(fit[3]))
        ed_stratum_shader('TTerrainXP')
        check('recipes: TTerrainXP paints 8 layers', Recipes.Cap() == 8 and Recipes.FitLayers({ 0, 1, 8 })[3] == 8)

        -- every mask writer refuses a layer the shader does not paint (strata.lua WhyNotPaintable, the same cap as the recipes)
        check('TTerrainXP: every layer can be written', Strata.PaintCap() == 8 and Strata.WhyNotPaintable(8) == nil and Strata.WhyNotPaintable(1) == nil)
        ed_stratum_shader('Terrain200')
        check('Terrain200: PaintCap is the recipes Cap', Strata.PaintCap() == 7 and Recipes.Cap() == Strata.PaintCap())
        check('Terrain200: layer 8 is refused, layer 7 is not', Strata.WhyNotPaintable(8) ~= nil and Strata.WhyNotPaintable(7) == nil, tostring(Strata.WhyNotPaintable(8)))
        local all = { rules = { MaskGen.NewRule('const') } }
        local m8 = ed_stratum_read(7, 0, 0, w - 1, h - 1)
        local depth = History.Version
        local n, why = MaskGen.ApplyToLayer(all, { layer = 8, mode = 1, strength = 1, takeAway = false })
        check('mask generator refuses layer 8 on Terrain200', n == nil and why ~= nil and string.find(why, 'Layer 8', 1, true) ~= nil, tostring(why))
        check('the refusal wrote nothing and made no history entry', History.Version == depth and Same(ed_stratum_read(7, 0, 0, w - 1, h - 1), m8))
        local entry, werr = Fields.Run(function(S)
            local c = MaskGen.NewContext(S, { step = 1 })
            return MaskGen.WriteLayer(c, S:Op('const', { like = c.H, value = 1 }), 8, { mode = 1, strength = 1 }, true)
        end)
        check('WriteLayer refuses layer 8 on Terrain200', entry == nil and werr ~= nil and Same(ed_stratum_read(7, 0, 0, w - 1, h - 1), m8), tostring(werr))
        ed_stratum_shader('Terrain000')
        check('Terrain000: layer 8 only holds map-wide data, refused', Strata.WhyNotPaintable(8) ~= nil)
        ed_stratum_shader('TTerrainGlow')
        check('TTerrainGlow paints layers 1-4 only', Strata.PaintCap() == 4 and Strata.WhyNotPaintable(4) == nil and Strata.WhyNotPaintable(5) ~= nil)
        ed_stratum_shader('TTerrainXP')
    end)
    if not ok then check('no error while running', false, err) end
    Restore()
    check('the map is put back', ed_stratum_shader() == shader0)
    if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. table.concat(lines, '\n') end
    return 'PASS strataconv\n' .. table.concat(lines, '\n')
end
