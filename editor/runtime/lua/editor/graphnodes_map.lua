-- Graph nodes for the map-wide textures of the terrain shaders (maptextures.lua): Height to normal map, Environment lighting, Lighting texture, and the two outputs that give the results
-- to the shader: Output: map normal map and Output: map lighting. graphnodes.lua calls Install(Kit, Covers) once (like graphnodes_t7.lua), so this file does not import graphnodes.lua.
--
--   Height to normal map    heights -> rgba (R = x, G = z, B = y, 0..1; flat ground is blue) and the three parts as masks. The engine's own formula (native op normal_map).
--   Environment lighting    the map's sun and ambient light as numbers (azimuth, altitude, multiplier, sun / ambient / shadow fill colours).
--   Lighting texture        heights (+ mask) -> baked sun shadow (1 = sun, 0 = shadow; soft by sampling the sun disc), shaded relief and ambient occlusion.
--   Output: map normal map  Build writes it as the map-wide normal texture the shader reads (an undo step), thumbnail in the node.
--   Output: map lighting    Build writes shadow, ambient occlusion and water depth as the map-wide lighting texture.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, C, B, In, Out = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.In, Kit.Out
    local MT = import('/lua/editor/maptextures.lua')
    local World = import('/lua/editor/world.lua')

    Covers['normal_map'] = true

    local SIZE_IDS = { 'auto', '256', '512', '1024', '2048' }
    local SIZE_LABELS = { 'Map size (at most 1024)', '256', '512', '1024', '2048 (slow, big)' }

    local function EnvOf(E)
        return { Op = function(name, p) return E:Op(name, p) end, Add = function(f) return E:Add(f) end }
    end

    --- The numbers of the map's lighting that the nodes depend on (part of the cache key of a node: a change of the sun re-runs them).
    local function LightKey()
        local key = ''
        for _, name in { 'sun_x', 'sun_y', 'sun_z', 'light_mult', 'ambient_r', 'ambient_g', 'ambient_b', 'sun_r', 'sun_g', 'sun_b', 'fill_r', 'fill_g', 'fill_b' } do
            key = key .. string.format('%.4f,', World.Value(name))
        end
        return key
    end

    -- ---- Height to normal map -----------------------------------------------------------------------------------------------------------------------

    Def('normal_map', { label = 'Height to normal map', cat = 'color', kw = 'normal map height gradient slope bump relief convert lighting map wide normals',
        desc = 'Turns heights into a normal map the way the engine does, one normal per map square. rgba is the picture (R = x, G = z, B = y: flat ground is blue); x, y and z are the three parts as masks (0.5 = no lean). Wire rgba into Output: map normal map to give the whole map this normal map.',
        inputs = { In('a', 'height') },
        outputs = { Out('rgba', 'color'), Out('x', 'mask'), Out('y', 'mask'), Out('z', 'mask') },
        params = { N('strength', 'Slope strength', 0.1, 8, 0.1, '%.1f', 1, { wire = true }), N('span', 'Sample distance (units)', 0.5, 16, 0.5, '%.1f', 1),
                   B('squares', 'Place on the map squares', true) },
        eval = function(E, v, ins)
            local x, y, z = MT.NormalFields(EnvOf(E), ins.a, { strength = v.strength, span = v.span, squares = v.squares })
            local one = E:Const(1)
            return { rgba = { r = x, g = z, b = y, a = one }, x = x, y = y, z = z }
        end })

    -- ---- Environment lighting -------------------------------------------------------------------------------------------------------------------------

    Def('env_lighting', { label = 'Environment lighting', cat = 'numbers', kw = 'environment lighting sun light direction azimuth altitude ambient colour color multiplier shadow fill map input',
        desc = 'The map\'s sun and ambient light (Lighting panel of the Environment workspace) as numbers: sun direction in degrees (azimuth 0 = +x, 90 = +z; altitude above the horizon), the brightness multiplier and the sun, ambient and shadow fill colours (0..1 per channel). Wire azimuth and altitude into Lighting texture.',
        outputs = { Out('azimuth', 'number'), Out('altitude', 'number'), Out('multiplier', 'number'),
                    Out('sun_r', 'number'), Out('sun_g', 'number'), Out('sun_b', 'number'),
                    Out('ambient_r', 'number'), Out('ambient_g', 'number'), Out('ambient_b', 'number'),
                    Out('fill_r', 'number'), Out('fill_g', 'number'), Out('fill_b', 'number') },
        liveKey = LightKey,
        eval = function(E, v, ins)
            local az, alt = World.SunAngles()
            return { azimuth = az, altitude = alt, multiplier = World.Value('light_mult'),
                     sun_r = World.Value('sun_r'), sun_g = World.Value('sun_g'), sun_b = World.Value('sun_b'),
                     ambient_r = World.Value('ambient_r'), ambient_g = World.Value('ambient_g'), ambient_b = World.Value('ambient_b'),
                     fill_r = World.Value('fill_r'), fill_g = World.Value('fill_g'), fill_b = World.Value('fill_b') }
        end })

    -- ---- Lighting texture -----------------------------------------------------------------------------------------------------------------------------

    Def('lighting_tex', { label = 'Lighting texture', cat = 'analysis', kw = 'lighting texture baked shadow light sun soft ambient occlusion ao shade penumbra map wide terrain info',
        desc = 'Bakes the sun onto the ground. shadow: 1 where the sun shines, 0 in cast shadow, with soft edges (the sun is sampled as a disc); this is what the shader multiplies into its sun light, so the surface angle is not in it. light: shaded relief (angle to the sun times shadow, plus ambient) for looking at or for masks. ao: how open the ground is (1 = open), from the cavity analysis. An optional mask limits where shadows and occlusion apply.',
        inputs = { In('a', 'height'), In('mask', 'mask', true) },
        outputs = { Out('shadow', 'mask'), Out('light', 'mask'), Out('ao', 'mask') },
        liveKey = LightKey,
        params = { B('useMap', 'Use the map\'s sun direction', true),
                   N('azimuth', 'Towards the sun (degrees, 0 = +x, 90 = +z)', 0, 360, 5, '%d', 315, { wire = true }), N('altitude', 'Sun height (degrees)', 1, 89, 1, '%d', 40, { wire = true }),
                   N('soft', 'Softness (size of the sun, degrees)', 0, 8, 0.25, '%.2f', 1, { wire = true }),
                   C('quality', 'Shadow quality', { '1', '5', '9' }, { 'Draft (hard edges)', 'Normal', 'Fine' }, '5'),
                   N('reach', 'Longest shadow (units)', 20, 1500, 10, '%d', 400),
                   N('ambient', 'Ambient light (light output)', 0, 1, 0.02, '%.2f', 0.25),
                   N('ao', 'Ambient occlusion strength', 0, 1, 0.05, '%.2f', 0.5), N('aoRadius', 'Occlusion radius (units)', 2, 300, 1, '%d', 40) },
        eval = function(E, v, ins)
            local az, alt = v.azimuth, v.altitude
            if v.useMap then
                local mapAz, mapAlt = World.SunAngles()
                if type(ins.azimuth) ~= 'number' then az = mapAz end
                if type(ins.altitude) ~= 'number' then alt = mapAlt end
            end
            local env = EnvOf(E)
            local wantAo = E.wanted.ao and v.ao > 0
            local lit, light, ao = MT.Lighting(env, ins.a, { azimuth = az, altitude = alt, soft = v.soft, quality = tonumber(v.quality) or 5, reach = v.reach,
                                                             light = E.wanted.light, ambient = v.ambient, ao = wantAo and v.ao or 0, aoRadius = v.aoRadius })
            if ins.mask then
                local one = E:Const(1)
                lit = E:Op('blend', { a = one, b = lit, mask = ins.mask, mode = 'normal', opacity = 1 })
                if ao then ao = E:Op('blend', { a = one, b = ao, mask = ins.mask, mode = 'normal', opacity = 1 }) end
            end
            if not ao and E.wanted.ao then ao = E:Const(1) end
            return { shadow = lit, light = light, ao = ao }
        end })

    -- ---- the outputs -------------------------------------------------------------------------------------------------------------------------------------

    Def('out_normalmap', { label = 'Output: map normal map', cat = 'outputs', kw = 'output map wide normal map shader terrain write dds bump texture',
        desc = 'Build gives the whole map this normal map: it is written as a DDS and put where the shader reads the map-wide normal map (layer 8 normal map; Terrain000 and later shaders). The ground is lit by it instead of by normals computed from the heights, so make it again after changing the heights. One undo step with the rest of the build. With Use it on the map off, only the file is written.',
        inputs = { In('normal', 'color') }, outputs = { Out('view', 'color', true) }, output = 'mapnormal', mapTexture = 'normal',
        params = { C('size', 'Texture size (pixels)', SIZE_IDS, SIZE_LABELS, 'auto'), B('assign', 'Use it on the map', true) },
        eval = function(E, v, ins) return { view = ins.normal } end })

    -- ---- the textures made from the paint, for the shaders that need them ------------------------------------------------------------------------

    Def('out_macro', { label = 'Output: macrotexture', cat = 'outputs', kw = 'output macrotexture macro upper layer colour variation tiling repetition overlay shader write dds texture',
        desc = 'Build makes a macrotexture from the paint of the map and gives it to the Upper layer: the colour the ground has, a little lighter and darker in broad patches (and darker in cavities), laid over the whole map to break up the repetition of the layer textures. Put it after the Output: texture layer nodes. TTerrain, TTerrainXP, TTerrainXPExt and Terrain000 / 050 read it.',
        outputs = { Out('view', 'mask', true) }, output = 'mapmacro', mapTexture = 'macro',
        params = { C('size', 'Texture size (pixels)', SIZE_IDS, SIZE_LABELS, 'auto'), N('scale', 'Patch size (units)', 40, 600, 10, '%d', 180),
                   N('contrast', 'Lighter and darker patches', 0, 0.6, 0.05, '%.2f', 0.25), N('cavity', 'Darker cavities', 0, 1, 0.05, '%.2f', 0.3), N('opacity', 'How much it covers the ground', 0.05, 0.9, 0.05, '%.2f', 0.35) },
        eval = function(E, v, ins) return { view = E:Const(0) } end })

    Def('out_specular', { label = 'Output: specular texture', cat = 'outputs', kw = 'output specular shine highlight upper layer terrain001 terrain051 wet snow shader write dds texture',
        desc = 'Build makes the specular picture of the map from the paint: wet ground, snow and the waterline shine, rock and sand do not. Terrain001 and Terrain051 read it from the Upper layer.',
        outputs = { Out('view', 'mask', true) }, output = 'mapspecular', mapTexture = 'specular',
        params = { C('size', 'Texture size (pixels)', SIZE_IDS, SIZE_LABELS, 'auto'), N('strength', 'How much wet ground and snow shine', 0, 1, 0.05, '%.2f', 0.8), N('sharpness', 'Sharpness of the highlights', 0, 1.5, 0.05, '%.2f', 1) },
        eval = function(E, v, ins) return { view = E:Const(0) } end })

    Def('out_atlas', { label = 'Output: roughness / height atlas', cat = 'outputs', kw = 'output atlas roughness height pbr upper layer splat terrain1xx terrain2xx shader write dds texture',
        desc = 'Build makes the roughness / height atlas of the Upper layer from the layer textures and the kind of ground of each (rock stands above grass above wet ground, so the 2xx splatting lets the right layer win). The Terrain1xx and Terrain2xx shaders read it.',
        outputs = { Out('view', 'mask', true) }, output = 'mapatlas', mapTexture = 'atlas',
        params = { C('size', 'Texture size (pixels)', { '512', '1024' }, { '512', '1024' }, '1024') },
        eval = function(E, v, ins) return { view = E:Const(0) } end })

    Def('out_roughness', { label = 'Output: roughness mask', cat = 'outputs', kw = 'output roughness multiplier layer 8 mask pbr terrain1xx terrain2xx shiny rough wet shader write',
        desc = 'Build writes the roughness multiplier of layer 8 for the Terrain1xx and Terrain2xx shaders (128 = neutral, lower = shinier, higher = rougher). Without a wire it is made from the paint: dry rock and sand rougher, wet ground, ice and snow shinier. With a mask: rougher where it is above one half, shinier below.',
        inputs = { In('a', 'mask', true) }, outputs = { Out('view', 'mask', true) }, output = 'roughness',
        params = { N('amount', 'How much the roughness varies', 0, 1, 0.05, '%.2f', 0.6) },
        eval = function(E, v, ins) return { view = ins.a or E:Const(0.5) } end })

    Def('out_maplight', { label = 'Output: map lighting', cat = 'outputs', kw = 'output map wide lighting shadow baked ambient occlusion shader terrain write dds texture info',
        desc = 'Build gives the whole map this baked lighting: shadow (1 = sun, 0 = shadow), optional ambient occlusion and the water depth are written as a DDS and put where the shader reads it (layer 8 albedo; Terrain000 and later shaders). Wire the shadow of Lighting texture here, not its light output: the shader applies the surface angle itself. One undo step with the rest of the build. With Use it on the map off, only the file is written.',
        inputs = { In('shadow', 'mask'), In('ao', 'mask', true) }, outputs = { Out('view', 'mask', true), Out('occlusion', 'mask', true) }, output = 'maplight', mapTexture = 'light',
        params = { C('size', 'Texture size (pixels)', SIZE_IDS, SIZE_LABELS, 'auto'), B('assign', 'Use it on the map', true) },
        eval = function(E, v, ins) return { view = ins.shadow, occlusion = ins.ao } end })
end
