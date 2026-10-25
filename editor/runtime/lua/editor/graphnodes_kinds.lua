-- Graph nodes for texturing by the shader of the map (docs/projects/editor/GRAPH_TEXTURING.md): they know what the shader paints and read the ground the way the stratum recipes do.
--
--   Terrain shader        the shader of the map as numbers (painted layers, PBR, splatting, biplanar, which map-wide pictures it reads), so a graph can adapt to it
--   Ground kinds          heights -> where each of the eight kinds of ground belongs (grass, dirt, wet, sand, rock, dark rock, high rock, snow): the stratum recipe's selections for the shader and the
--                         textures of the map (a kind on a layer the B shaders draw from the side gets steep ground only; kinds the shader has no layer for come out empty). A style and every knob
--   Surface roughness     kind masks -> a roughness mask (0.5 = neutral): rock and sand rough, wet ground and snow shiny; wire it into Output: roughness mask (PBR shaders)
--   Output: ground kinds  all eight kinds in one: Build resolves overlaps (snow over high rock over rock ...), gives every kind its layer whatever the shader (4, 7 or 8 painted layers), makes the
--                         paint masks in the shader's encoding, the terrain types and, on the PBR shaders, the roughness
--
-- graphnodes.lua calls Install(Kit, Covers) once. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, C, B, In, Out = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.In, Kit.Out
    local Fields = import('/lua/editor/fields.lua')
    local Recipes = import('/lua/editor/recipes.lua')
    local Strata = import('/lua/editor/strata.lua')

    local ROLES = Recipes.Order
    local ROLE_LABEL = {}
    for _, id in ROLES do ROLE_LABEL[id] = Recipes.RoleInfo[id].label end

    local function ShaderKey()
        local name = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or ''
        local plan = Recipes.Plan()
        local key = tostring(name) .. '|' .. plan.cap
        for _, id in ROLES do
            key = key .. '|' .. id .. ':'
            for _, l in (plan.byRole[id] or {}) do key = key .. l .. ',' end
        end
        return key
    end

    local function StyleParam()
        local ids, labels = {}, {}
        for _, p in Recipes.Presets do
            table.insert(ids, p.id)
            table.insert(labels, p.name)
        end
        return C('style', 'Style', ids, labels, ids[1])
    end

    local function KnobParams()
        local list = {}
        for _, info in Recipes.KnobInfo do
            table.insert(list, N(info.key, info.label, info.min, info.max, info.step, info.fmt, Recipes.KnobDefaults[info.key]))
        end
        return list
    end

    --- The knobs the user moved away from their default (a slider left alone takes the value of the style).
    local function Moved(v)
        local knobs = {}
        for _, info in Recipes.KnobInfo do
            local x = v[info.key]
            if x ~= nil and x ~= Recipes.KnobDefaults[info.key] then knobs[info.key] = x end
        end
        return knobs
    end

    -- ---- Terrain shader ---------------------------------------------------------------------------------------------------------------------------

    Def('terrain_shader', { label = 'Terrain shader', cat = 'sources', kw = 'terrain shader input layers pbr splat biplanar profile texture map technique',
        desc = 'The terrain shader of the map as numbers, so a graph can adapt to it: how many layers it paints (4, 7 or 8), whether it is a PBR shader (roughness multiplier in layer 8, roughness / height atlas), whether it splats by height (2xx), whether it draws layers 3 and 4 from the side only (the B shaders), and which map-wide pictures it reads (macrotexture, specular). The ground kind nodes already use the shader by themselves; use these numbers for what is yours (a threshold that must change with the shader, a switch).',
        outputs = { Out('layers', 'number'), Out('pbr', 'number'), Out('splat', 'number'), Out('biplanar', 'number'), Out('macro', 'number'), Out('specular', 'number'), Out('roughness', 'number') },
        liveKey = ShaderKey,
        eval = function(E, v, ins)
            local p = Strata.Profile() or {}
            local class = p.class or 'legacy'
            local maps = p.maps or {}
            return { layers = Recipes.Cap(), pbr = (class == 'pbr' or class == 'splat') and 1 or 0, splat = class == 'splat' and 1 or 0, biplanar = p.biplanar and 1 or 0,
                     macro = maps.macro and 1 or 0, specular = maps.specular and 1 or 0, roughness = p.l8 == 'rough' and 1 or 0 }
        end })

    -- ---- Ground kinds -----------------------------------------------------------------------------------------------------------------------------

    local kindOutputs = {}
    for _, id in ROLES do table.insert(kindOutputs, Out(id, 'mask')) end
    local kindParams = { StyleParam() }
    for _, p in KnobParams() do table.insert(kindParams, p) end

    Def('ground_kinds', { label = 'Ground kinds', cat = 'analysis', kw = 'ground kinds recipe stratum grass dirt wet sand rock dark rock high rock snow cliff beach texture layers shader terrain paint',
        desc = 'Where each of the eight kinds of ground belongs on these heights: the stratum recipe (Stratum recipes panel) as masks. It follows the map: the kinds that have a layer, the base layer (the kind of layer 0 is what the others leave), and the shader (a kind on layer 3 or 4 of a B shader gets steep ground only). Kinds the map has no layer for come out empty. Wire the eight masks into Output: ground kinds, or use them for anything (scatter forest on grass, roughness). A slider left at its default takes the value of the style.',
        inputs = { In('a', 'height') },
        outputs = kindOutputs,
        liveKey = ShaderKey,
        params = kindParams,
        eval = function(E, v, ins)
            local H = ins.a
            local w, h = Fields.Info(H)
            local hmin, hmax = Fields.Stats(H)
            local c = { S = E, H = H, w = w, h = h, cell = E.cell, step = E.step, hmin = hmin, hmax = hmax, water = E.water, cache = {} }
            local sel, plan = Recipes.Selections(E, c, { preset = v.style, knobs = Moved(v) })
            local out = {}
            for _, id in ROLES do
                out[id] = sel[id] or E:Const((plan.base == id) and 1 or 0)
            end
            return out
        end })

    -- ---- Surface roughness ------------------------------------------------------------------------------------------------------------------------

    -- roughness of every kind: 0 shiny .. 1 rough, 0.5 = what the shader does by itself
    local ROUGH = { grass = 0.55, dirt = 0.68, wet = 0.12, sand = 0.72, rock = 0.88, darkrock = 0.92, highrock = 0.82, snow = 0.2 }
    local roughInputs = {}
    for _, id in ROLES do table.insert(roughInputs, In(id, 'mask', true)) end

    Def('surface_roughness', { label = 'Surface roughness', cat = 'analysis', kw = 'surface roughness shiny wet snow rock sand pbr layer 8 multiplier material kinds',
        desc = 'A roughness mask (0.5 = neutral, lower = shinier, higher = rougher) from the kind masks: dry rock, dark rock and sand rough, wet ground and snow shiny. Wire the kinds you have, from the lowest priority to the highest they are laid over each other; wire the result into Output: roughness mask (Terrain1xx / 2xx).',
        inputs = roughInputs, outputs = { Out('out', 'mask') },
        params = { N('contrast', 'How far the kinds differ', 0, 1, 0.05, '%.2f', 0.8),
                   N('base', 'Where no kind is wired', 0, 1, 0.05, '%.2f', 0.5) },
        eval = function(E, v, ins)
            local cur = E:Const(v.base)
            for _, id in ROLES do
                local m = ins[id]
                if m then
                    local r = 0.5 + (ROUGH[id] - 0.5) * v.contrast
                    cur = E:Op('blend', { a = cur, b = E:Const(r), mask = m, mode = 'normal', opacity = 1 })
                end
            end
            return { out = cur }
        end })

    -- ---- Output: ground kinds ---------------------------------------------------------------------------------------------------------------------

    local outInputs, outOutputs = {}, {}
    for _, id in ROLES do
        table.insert(outInputs, In(id, 'mask', true))
        table.insert(outOutputs, Out('seen_' .. id, 'mask', true))      -- (the inputs passed through: the build reads them here; other names than the inputs)
    end
    Def('out_kinds', { label = 'Output: ground kinds', cat = 'outputs', kw = 'output ground kinds all grass dirt wet sand rock snow layers paint texture shader stratum recipe terrain types roughness 7 8 layers',
        desc = 'Build paints the whole ground from the kind masks (Ground kinds node, or your own): overlaps are settled the way the recipes do (snow over high rock over dark rock over rock over wet ground over sand over dirt over grass), every kind goes to the layer that holds it whatever the shader (4, 7 or 8 painted layers, the base layer is what is left, side-mapped layers get steep ground only), the masks are written in the shader\'s encoding, then the terrain types follow what shows most and the PBR shaders get their roughness multiplier. A kind with a layer but no wire is cleared from its layer. One undo step with the rest of the build.',
        inputs = outInputs, outputs = outOutputs, output = 'kinds',
        params = { B('types', 'Set the terrain types too', true), B('roughness', 'Roughness multiplier too (PBR shaders)', true), N('amount', 'How much the roughness varies', 0, 1, 0.05, '%.2f', 0.6) },
        eval = function(E, v, ins)
            local out = {}
            for _, id in ROLES do out['seen_' .. id] = ins[id] end
            return out
        end })
end
