-- Self test of the alpha generation (alphagen.lua: the roughness / height atlas from the detail of the textures and the kind of ground, the base layer's alpha for the macrotexture variants,
-- the specularity alpha). Run in the live editor:
--   return import('/lua/editor/selftest_alphagen.lua').Run()
-- Needs a map with paint layers; switches the shader and the texture set of the open map (the test puts the shader back).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local AG = import('/lua/editor/alphagen.lua')
local MT = import('/lua/editor/maptextures.lua')
local TS = import('/lua/editor/texsets.lua')
local Shaders = import('/lua/editor/shaders.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

--- The mean alpha (0..1) of a DDS texture.
local function MeanAlpha(vfs)
    local px, w, h = ed_dds_read(ed_vfs_to_disk(vfs))
    if not px then return nil end
    local sum, n = 0, w * h
    for i = 1, n do sum = sum + px[(i - 1) * 4 + 4] end
    return sum / n / 255
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

    check('the kinds of ground are ordered: wet shiny, rock dull; rock high, wet low', AG.ROLE_ROUGH.wet < AG.ROLE_ROUGH.rock and AG.ROLE_HEIGHT.rock > AG.ROLE_HEIGHT.wet and AG.ROLE_SPEC.wet > AG.ROLE_SPEC.rock)
    if not rawget(_G, 'ed_dds_fields') or not rawget(_G, 'ed_stratum_layer') or not ed_terrain_info() then
        table.insert(lines, '  (no map or no native writer: the checks on a map are skipped)')
        return Done()
    end
    local shader0 = ed_stratum_shader()
    Shaders.Set('TTerrainXP')
    TS.Apply('temperate')
    import('/lua/editor/recipes.lua').Invalidate()
    local base0 = ed_stratum_layer(0)          -- the texture set's own base texture (its alpha is a specularity)

    -- the atlas
    Shaders.Set('Terrain202B')
    TS.Apply('temperate')                      -- (the layout of the kinds of ground follows the shader)
    import('/lua/editor/recipes.lua').Invalidate()
    local entry, why = MT.GenerateAtlas({ size = 1024 })
    check('the atlas is generated from the textures', entry ~= nil, why)
    local stats = MT.State.atlasStats
    check('every textured layer reports its height and roughness', stats and stats[1] and stats[4] and stats[6])
    local function Num(text, key)
        local _, _, a, b = string.find(text, key .. ' ([%d%.]+)%+%-([%d%.]+)')
        return tonumber(a), tonumber(b)
    end
    if stats and stats[4] and stats[6] and stats[1] then
        local rockH, rockSd = Num(stats[4], 'height')
        local wetH = Num(stats[6], 'height')
        local grassH = Num(stats[1], 'height')
        local rockR = Num(stats[4], 'rough')
        local wetR = Num(stats[6], 'rough')
        check('rock stands above grass above wet ground in the heights (so the splatting lets rock win)', rockH > grassH + 0.1 and grassH > wetH + 0.03, string.format('%.2f %.2f %.2f', rockH, grassH, wetH))
        check('wet ground is shinier than rock', wetR < rockR - 0.2, string.format('%.2f %.2f', wetR, rockR))
        check('every layer has the same detail contrast (about %.2f)', rockSd > 0.08 and rockSd < 0.2, rockSd)
    end

    -- the base layer's alpha
    Shaders.Set('Terrain202')
    local base1 = ed_stratum_layer(0)
    check('a macrotexture variant (Terrain202) gives the base layer a copy of its texture', base1 ~= base0 and string.find(base1, 'edmaptex', 1, true) ~= nil, tostring(base1))
    local a = MeanAlpha(base1)
    check('with alpha 0 (the texture set\'s specularity would cover the map)', a ~= nil and a < 0.01, tostring(a))
    Shaders.Set('Terrain200')
    check('a shader without the feature (Terrain200) gets the original texture back', ed_stratum_layer(0) == base0, tostring(ed_stratum_layer(0)))
    check('FitBase does nothing twice', AG.FitBase() == nil)
    Shaders.Set('Terrain202')
    local base2 = ed_stratum_layer(0)
    check('switching back to the variant makes the copy again, once', base2 ~= base0 and AG.FitBase() == nil)

    -- the specularity alpha
    local vfs = AG.SpecAlpha(base0, 'wet')
    local vfs2 = AG.SpecAlpha(base0, 'rock')
    local aw, ar = vfs and MeanAlpha(vfs), vfs2 and MeanAlpha(vfs2)
    check('the specularity of wet ground is above that of rock', aw and ar and aw > ar + 0.3, tostring(aw) .. ' ' .. tostring(ar))

    -- the atlas settings move the heights the splatting compares
    Shaders.Set('Terrain202B')
    TS.Apply('temperate')
    import('/lua/editor/recipes.lua').Invalidate()
    local function RockMinusGrass(o)
        o.size = 1024
        MT.GenerateAtlas(o)
        local st = MT.State.atlasStats
        if not (st and st[4] and st[1]) then return nil end
        return (Num(st[4], 'height')) - (Num(st[1], 'height'))
    end
    local wide, flat = RockMinusGrass({ biasScale = 2 }), RockMinusGrass({ biasScale = 0 })
    check('the height step between the kinds of ground follows its setting', wide and flat and wide > flat + 0.2, tostring(wide) .. ' ' .. tostring(flat))
    RockMinusGrass({ spread = 2 })
    local _, sdWide = Num(MT.State.atlasStats[4], 'height')
    RockMinusGrass({ spread = 0.5 })
    local _, sdNarrow = Num(MT.State.atlasStats[4], 'height')
    check('the height contrast inside a texture follows its setting', sdWide and sdNarrow and sdWide > sdNarrow * 1.5, tostring(sdWide) .. ' ' .. tostring(sdNarrow))

    -- the specularity alpha of the layers (TTerrainXP reads it; Terrain202 does not)
    Shaders.Set('TTerrainXP')
    TS.Apply('temperate')
    import('/lua/editor/recipes.lua').Invalidate()
    local own = ed_stratum_layer(4)
    local own1 = ed_stratum_layer(6)
    local entry2, report, n = AG.ApplyLayerAlpha({ mode = 'generate', noPush = true })
    check('Generate gives the layers a copy with the specularity alpha', entry2 ~= nil and n and n >= 4, tostring(report))
    local gen = ed_stratum_layer(4)
    check('the layer now uses a new file', gen ~= own and string.find(gen, 'edmaptex', 1, true) ~= nil, tostring(gen))
    local ag = MeanAlpha(gen)
    check('the specularity alpha is a middle value (not the 0 of the macrotexture fix)', ag ~= nil and ag > 0.05 and ag < 0.95, tostring(ag))
    local e3, r3, n3 = AG.ApplyLayerAlpha({ mode = 'adjust', amount = 0.9, noPush = true })
    check('Adjust works from the original textures', e3 ~= nil and ed_stratum_layer(4) ~= gen, tostring(r3))
    AG.ApplyLayerAlpha({ mode = 'off', noPush = true })
    check('Off puts the original textures back', ed_stratum_layer(4) == own and ed_stratum_layer(6) == own1, tostring(ed_stratum_layer(4)))
    Shaders.Set('Terrain202B')
    local e4, r4 = AG.ApplyLayerAlpha({ mode = 'generate', noPush = true })
    check('a shader that ignores the alpha (Terrain202B) says so and changes nothing', e4 == nil and r4 and string.find(r4, 'does not read', 1, true) ~= nil, tostring(r4))

    Shaders.Set(shader0 or 'TTerrainXP')
    return Done()
end
