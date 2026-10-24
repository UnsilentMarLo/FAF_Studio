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
local TexConv = import('/lua/editor/texconv.lua')

local function Same(a, b)
    if not a or not b or table.getn(a) ~= table.getn(b) then return false end
    for i = 1, table.getn(a) do
        if a[i] ~= b[i] then return false end
    end
    return true
end

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

    -- what the numbered shaders read besides the layers (docs/projects/editor/LAYER_CONVERSION.md)
    check('the 001 / 051 and x1x / x2x shaders read the base alpha as macrotexture opacity', Shaders.Profile('Terrain001').baseAlpha == 'opacity' and Shaders.Profile('Terrain051').baseAlpha == 'opacity'
        and Shaders.Profile('Terrain251').baseAlpha == 'opacity' and Shaders.Profile('Terrain102B').baseAlpha == 'opacity' and Shaders.Profile('Terrain250').baseAlpha == nil and Shaders.Profile('Terrain100').baseAlpha == nil)
    check('the B shaders are biplanar and always read layer 8 (normal map and water depth)', Shaders.Profile('Terrain200B').biplanar == true and Shaders.Profile('Terrain100B').need.normal == true
        and Shaders.Profile('Terrain100B').need.light == true and Shaders.Profile('Terrain200').biplanar == nil and Shaders.Profile('Terrain200').need == nil)
    check('Terrain001 always reads the alpha of layer 8 (baked shadow)', Shaders.Profile('Terrain001').need.light == true and Shaders.Profile('Terrain001').need.normal == nil)
    check('the splat settings default to softness 0.2, contrast 0.6, a 30 degree rotation', math.abs(Shaders.SPLAT_LIGHT.spec_b * Shaders.SPLAT_LIGHT.spec_b + Shaders.SPLAT_LIGHT.spec_a * Shaders.SPLAT_LIGHT.spec_a - 1) < 0.001
        and Shaders.SPLAT_LIGHT.spec_r > 0 and math.abs(math.deg(math.atan2(Shaders.SPLAT_LIGHT.spec_a, Shaders.SPLAT_LIGHT.spec_b)) - 30) < 0.1)
    check('the layer table of a B shader says layers 3 and 4 are mapped from the side only', string.find(Shaders.Rows('Terrain200B')[4].albedo, 'only from the side', 1, true) ~= nil and string.find(Shaders.Rows('Terrain200B')[3].albedo, 'only from the side', 1, true) == nil)

    -- the channel tables for the texture natives (texconv.lua)
    do
        local r = TexConv.ROUGH_MAX - TexConv.ROUGH_MIN
        local spec, matte = TexConv.RoughChan('spec'), TexConv.RoughChan('matte')
        check('roughness from a specularity alpha: 1 gives the glossiest, 0 the dullest', math.abs(spec.scale * 1 + spec.bias - TexConv.ROUGH_MIN) < 0.0001 and math.abs(spec.bias - TexConv.ROUGH_MAX) < 0.0001)
        check('roughness from a TTerrain alpha (1 - specularity) is the other way round', math.abs(matte.scale * 0 + matte.bias - TexConv.ROUGH_MIN) < 0.0001 and math.abs(matte.scale * 1 + matte.bias - TexConv.ROUGH_MAX) < 0.0001)
        check('no alpha kind: the neutral roughness', TexConv.RoughChan(nil).from == 'const' and TexConv.RoughChan(nil).value == TexConv.ROUGH_NEUTRAL)
        local back = TexConv.SpecFromRoughChan('spec', '/x/atlas.dds', 6)
        check('specularity from the roughness of an atlas tile is the inverse (rough MIN -> 1, MAX -> 0), tiles 5-8 read B', math.abs(back.scale * TexConv.ROUGH_MIN + back.bias - 1) < 0.0001
            and math.abs(back.scale * TexConv.ROUGH_MAX + back.bias) < 0.0001 and back.atlas.ch == 'b' and TexConv.SpecFromRoughChan('spec', 'x', 4).atlas.ch == 'r')
        local backM = TexConv.SpecFromRoughChan('matte', 'x', 1)
        check('... and for TTerrain it is 1 - specularity', math.abs(backM.scale * TexConv.ROUGH_MIN + backM.bias) < 0.0001 and math.abs(backM.scale * TexConv.ROUGH_MAX + backM.bias - 1) < 0.0001)
        local paths = { [0] = '/a/base.dds', [1] = '/a/one.dds', [3] = Strata.CLEAR }
        local spec8 = TexConv.AtlasSpec(paths, 'spec', 512)
        check('an atlas table has 8 tiles: a layer with a texture reads it, one without gets constants', spec8.size == 512 and spec8.tiles[1].src == '/a/base.dds' and spec8.tiles[2].src == '/a/one.dds'
            and spec8.tiles[3].src == nil and spec8.tiles[3].rough.from == 'const' and spec8.tiles[4].src == nil and spec8.tiles[8] ~= nil and spec8.tiles[1].height.center == true)
        check('the glossiness range is sane', r > 0.3 and TexConv.ROUGH_MIN > 0.2 and TexConv.ROUGH_MAX < 1)
    end

    -- the arrangement of the layers for the biplanar shaders (Arrange is pure: a made up plan)
    do
        local function Layers(spec)
            local l = {}
            for i = 1, 8 do l[i] = { painted = spec[i] ~= nil, slope = spec[i] } end
            return l
        end
        local function PlanOf(spec, extra)
            return { toP = { painted = 7, biplanar = true }, fromP = { biplanar = false }, extra = extra or {}, canMove = true, layers = Layers(spec) }
        end
        local p1 = Conv.Arrange(PlanOf({ [1] = 5, [2] = 8, [5] = 40, [6] = 31 }), 'drop')
        check('the two steepest painted layers go to slots 3 and 4, the steepest first', p1[3] == 5 and p1[4] == 6, p1[3] .. ' ' .. p1[4])
        check('every layer is still there once', (function()
            local seen = 0
            local mark = {}
            for j = 1, 8 do if not mark[p1[j]] then mark[p1[j]] = true seen = seen + 1 end end
            return seen == 8
        end)())
        local p2 = Conv.Arrange(PlanOf({ [1] = 5, [2] = 8 }), 'drop')
        check('without steep ground the painted layers leave slots 3 and 4 for layers without paint', p2[1] == 1 and p2[2] == 2 and p2[3] ~= 1 and p2[3] ~= 2 and p2[4] ~= 1 and p2[4] ~= 2 and p2[3] ~= nil, p2[3] .. ' ' .. p2[4])
        local p3 = Conv.Arrange(PlanOf({ [3] = 35 }), 'drop')
        check('a cliff layer that is in slot 3 stays; slot 4 holds no painted layer', p3[3] == 3 and p3[4] ~= 3)
        local p4 = Conv.Arrange(PlanOf({ [1] = 6, [2] = 6, [3] = 6, [4] = 6, [5] = 6, [6] = 6, [7] = 6 }), 'drop')
        check('when every slot has paint and nothing is steep nothing can move', p4[3] == 3 and p4[4] == 4)
        local plain = { toP = { painted = 7 }, fromP = {}, extra = {}, canMove = true, layers = Layers({ [1] = 5, [5] = 40 }) }
        local p5 = Conv.Arrange(plain, 'drop')
        check('a shader that is not biplanar keeps the order', p5[1] == 1 and p5[3] == 3 and p5[5] == 5 and p5[8] == 8)
        local movePlan = { toP = { painted = 7 }, fromP = {}, extra = { 8 }, canMove = true, layers = Layers({ [1] = 5, [4] = 5, [8] = 5 }) }
        local p6 = Conv.Arrange(movePlan, 'move')
        check('Move: the layers with paint come first (1, 4, 8), the others follow in order', p6[1] == 1 and p6[2] == 4 and p6[3] == 8 and p6[4] == 2 and p6[5] == 3 and p6[8] == 7, Join(p6, ','))
    end

    if not rawget(_G, 'ed_stratum_info') or not ed_stratum_info() or not import('/lua/editor/fields.lua').IsAvailable() then
        table.insert(lines, '  (no paint masks: the conversion checks are skipped)')
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. Join(lines, '\n') end
        return 'PASS strataconv (data only)\n' .. Join(lines, '\n')
    end

    -- save the map's state
    local shader0 = ed_stratum_shader()
    local maskState0 = Shaders.MaskState()
    local spec0 = Shaders.SpecColor()
    local w, h = ed_stratum_info()
    local layers0 = {}
    for i = 0, 9 do layers0[i] = Strata.Snapshot(i) end
    local masks0 = {}
    for s = 0, 7 do masks0[s] = ed_stratum_read(s, 0, 0, w - 1, h - 1) end

    local function Restore()
        Shaders.SetSpecColor(spec0)
        Shaders.SetMaskState(maskState0)
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

        -- a plain shader switch leaves the masks in the old range: shaders.lua tracks it (the Layers panel warns, Convert starts from the authored shader)
        Shaders.SetMaskState(false)
        check('no mismatch when the masks were made for the shader', Shaders.Mismatch() == nil and Shaders.SidecarText() == '')
        local okSet = Shaders.Set('Terrain000')
        local mis = Shaders.Mismatch()
        check('a plain switch XP -> Terrain000 leaves a range mismatch', okSet and mis ~= nil and mis.range == 'half' and mis.now == 'full' and mis.shader == 'TTerrainXP' and mis.current == 'Terrain000')
        check('the mismatch is saved with the map', string.find(Shaders.SidecarText(), 'StrataAuthored', 1, true) ~= nil)
        local okExt = Shaders.Set('TTerrainXPExt')
        if okExt then check('a switch to a shader of the same range as the masks clears it', Shaders.Mismatch() == nil) end
        Shaders.Set('Terrain000')
        check('switching again brings it back', Shaders.Mismatch() ~= nil)
        local planM = Conv.Plan('Terrain000')
        check('convert plan after a plain switch starts from the authored shader', planM.refused == nil and planM.from == (okExt and 'TTerrainXPExt' or 'TTerrainXP') and planM.cur == 'Terrain000' and planM.fromP.range == 'half' and planM.toP.range == 'full', tostring(planM.refused) .. ' from=' .. tostring(planM.from) .. ' cur=' .. tostring(planM.cur) .. ' fromRange=' .. tostring(planM.fromP and planM.fromP.range) .. ' toRange=' .. tostring(planM.toP and planM.toP.range))
        local repM = Conv.Run(planM, { layer8 = 'move', upper = false })
        check('the conversion runs and the masks match the shader afterwards', repM ~= nil and Shaders.Mismatch() == nil and Shaders.SidecarText() == '')
        History.Undo()
        check('undo restores the mismatch', ed_stratum_shader() == 'Terrain000' and Shaders.Mismatch() ~= nil)
        History.Redo()
        check('redo clears it again', Shaders.Mismatch() == nil)
        History.Undo()
        Shaders.SetMaskState(false)
        ed_stratum_shader('TTerrainXP')

        -- the splat settings: a Terrain2xx shader with a zero SpecularColor draws every second layer as one texel (terrain.fx rotated_pos = (0, 0)) and switches layers hard
        if spec0 then
            Shaders.SetSpecColor({ spec_r = 0, spec_g = 0, spec_b = 0, spec_a = 0 })
            local b0, a0 = Shaders.SplatLighting('fix')
            local now = Shaders.SpecColor()
            check('SplatLighting fix replaces an all zero SpecularColor', b0 ~= nil and now.spec_b == a0.spec_b and math.abs(now.spec_b - 0.866) < 0.001 and now.spec_r > 0.05)
            check('... and leaves a usable one alone', Shaders.SplatLighting('fix') == nil)
            local b1 = Shaders.SplatLighting('enter')
            check('enter sets the defaults and remembers nothing it cannot give back', b1 == nil or b1.spec_r ~= nil)
            Shaders.SetSpecColor({ spec_r = 0.5, spec_g = 0.1, spec_b = 0.2, spec_a = 0.3 })
            Shaders.SplatLighting('enter')
            local e = Shaders.SpecColor()
            check('enter: all four lanes are the defaults', math.abs(e.spec_r - Shaders.SPLAT_LIGHT.spec_r) < 0.0001 and math.abs(e.spec_g - Shaders.SPLAT_LIGHT.spec_g) < 0.0001 and math.abs(e.spec_a - Shaders.SPLAT_LIGHT.spec_a) < 0.0001)
            Shaders.SplatLighting('leave')
            local l = Shaders.SpecColor()
            check('leave brings the old colour back', math.abs(l.spec_r - 0.5) < 0.0001 and math.abs(l.spec_g - 0.1) < 0.0001 and math.abs(l.spec_b - 0.2) < 0.0001 and math.abs(l.spec_a - 0.3) < 0.0001)
            Shaders.SetSpecColor({ spec_r = 0, spec_g = 0, spec_b = 0, spec_a = 0 })
        end

        -- the plans: which texture work each pair needs
        for i = 1, 8 do Strata.SetTexture(i, '/env/evergreen/layers/dirt001_albedo.dds', nil, 10, 10) end
        Shaders.SetMaskState(false)
        ed_stratum_shader('TTerrainXP')
        local p250 = Conv.Plan('Terrain250')
        check('plan: XP -> Terrain250 makes an atlas and sets the splat lighting, no alpha work', p250.tex ~= nil and p250.tex.atlas == true and p250.tex.alpha == nil and p250.tex.baseClear == false and p250.tex.lighting == 'enter' and p250.upperAction == 'atlas', tostring(p250.refused))
        local p251 = Conv.Plan('Terrain251')
        check('plan: XP -> Terrain251 clears the alpha of the base layer (it is a macrotexture opacity there)', p251.tex.baseClear == true and p251.tex.atlas == true)
        local p200b = Conv.Plan('Terrain200B')
        check('plan: XP -> Terrain200B needs the map normal map and the water depth in layer 8', p200b.tex.normal == 'generate' and p200b.tex.light == 'generate', tostring(p200b.tex.normal) .. ' ' .. tostring(p200b.tex.light))
        local p001 = Conv.Plan('Terrain001')
        check('plan: XP -> Terrain001 needs a neutral light texture (layer 8 alpha is the shadow) and clears the base alpha', p001.tex.light == 'neutral' and p001.tex.normal == nil and p001.tex.baseClear == true and p001.tex.lighting == nil)
        local p000 = Conv.Plan('Terrain000')
        check('plan: XP -> Terrain000 needs no texture work', p000.tex.any == false and p000.tex.lighting == nil)
        local pgl = Conv.Plan('TTerrain')
        check('plan: XP -> TTerrain inverts the alpha (specularity <-> 1 - specularity)', pgl.tex.alpha == 'invert')
        check('every plan lists its lines, and the warnings of a conversion without textures are a list', table.getn(p250.lines) > 2 and p250.warningsNoTex ~= nil and table.getn(p251.warningsNoTex) > 0)
        local p301 = Conv.Plan('Terrain301')
        check('plan: Terrain301 is refused', p301.refused ~= nil)

        -- converting for real (needs the natives of this build)
        if TexConv.Available() then
            local layers1 = {}
            for i = 0, 9 do layers1[i] = Strata.Snapshot(i) end
            local plan = Conv.Plan('Terrain200B')
            local rep, why = Conv.Run(plan, { layer8 = 'drop', upper = true, textures = true })
            check('XP -> Terrain200B with textures runs', rep ~= nil, why)
            if rep then
                local up = ed_stratum_layer(9)
                check('the Upper layer is a new atlas file (maptex_atlas_n.dds)', string.find(string.lower(up or ''), 'maptex_atlas_%d+%.dds') ~= nil, tostring(up))
                local n18 = ed_stratum_layer(18)
                local a8 = ed_stratum_layer(8)
                check('layer 8 holds the map normal map and the water depth', string.find(string.lower(n18 or ''), 'maptex_normal_%d+%.dds') ~= nil and string.find(string.lower(a8 or ''), 'maptex_light_%d+%.dds') ~= nil, tostring(n18) .. ' ' .. tostring(a8))
                local sc = Shaders.SpecColor()
                check('the splat lighting is set', sc.spec_b > 0.8 and sc.spec_r > 0.05)
                check('the report lists the files it made', rep.files >= 3 and table.getn(rep.lines) > 4)
                History.Undo()
                local same = true
                for i = 0, 9 do
                    local s1 = Strata.Snapshot(i)
                    if s1.albedo ~= layers1[i].albedo or s1.normal ~= layers1[i].normal then same = false end
                end
                check('undo points every layer back at its old texture and puts the lighting back', same and ed_stratum_shader() == 'TTerrainXP' and Shaders.SpecColor().spec_b == 0)
            end
            -- the alpha of a TTerrain map: inverted into new files
            ed_stratum_shader('TTerrainXP')
            local planI = Conv.Plan('TTerrain')
            local repI, whyI = Conv.Run(planI, { layer8 = 'drop', textures = true })
            check('XP -> TTerrain with textures runs and writes alpha files', repI ~= nil and repI.files >= 1, tostring(whyI) .. ' files=' .. tostring(repI and repI.files) .. ' lines=' .. (repI and Join(repI.lines or {}, ' / ') or ''))
            if repI then History.Undo() end
        else
            table.insert(lines, '  (this build has no ed_tex_convert: the texture conversion itself is not run)')
        end
        ed_stratum_shader('TTerrainXP')
    end)
    if not ok then check('no error while running', false, err) end
    Restore()
    check('the map is put back', ed_stratum_shader() == shader0)
    if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. Join(lines, '\n') end
    return 'PASS strataconv\n' .. Join(lines, '\n')
end
