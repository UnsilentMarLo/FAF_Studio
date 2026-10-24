-- Graph nodes of the map layout (layout.lua, the Layout workspace): the drawing becomes fields the generator can use.
--
--   Map layout: heights      the height field of the whole layout (the same one Generate terrain writes), to carry on with: erosion, texturing, props
--   Map layout: layer mask   the mask of one layer (hills, a lake, a free mask ...) as a 0..1 field: where the user drew it, softened by the layer's own soft edge
--   Map layout: bases        the start positions drawn on Base layers as a mask (a disc around each base centre) and the number of bases as a number
--
-- The nodes follow the drawing: a stroke on the canvas makes them evaluate again (liveKey). graphnodes.lua calls Install(Kit, Covers) once.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, C, B, In, Out = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.In, Kit.Out
    local Layout = import('/lua/editor/layout.lua')
    local Symmetry = import('/lua/editor/symmetry.lua')

    local function Key()
        local doc = Layout.Doc
        return string.format('%d|%s|%s', doc and doc.rev or 0, tostring(Symmetry.Mode), tostring(doc and doc.res))
    end

    Def('layout_height', { label = 'Map layout: heights', cat = 'sources', kw = 'map layout drawing canvas layers height terrain generate hills mountains water base plateau',
        desc = 'The height field the Layout workspace makes from the layers drawn on its canvas (hills, mountains, plateaus, water, valleys, flat ground, bases), at the resolution of the graph. The ground height and water level are the ones of the layout. Carry on with it like with any generator: erosion, texturing, props. The editor symmetry is applied to the noise relief when it is on.',
        outputs = { Out('out', 'height') }, liveKey = Key,
        params = { N('weather', 'Weathering (gullies)', 0, 1, 0.05, '%.2f', 0), B('sym', 'Apply the editor symmetry', true) },
        eval = function(E, v, ins)
            local H = Layout.Build(E, E.like, { weather = v.weather, symmetry = v.sym })
            return { out = H }
        end })

    Def('layout_mask', { label = 'Map layout: layer mask', cat = 'sources', kw = 'map layout drawing canvas layer mask forest lake mountains region free',
        desc = 'The mask of one layer of the layout: 1 where it is drawn, 0 where it is not, as soft as the layer\'s own soft edge (the Layer setting counts the layers of the list from 1). Use it as a region for erosion, texturing or scatter, or draw a Free mask layer for exactly that.',
        outputs = { Out('out', 'mask') }, liveKey = Key,
        params = { N('layer', 'Layer (its number in the list)', 1, 16, 1, '%d', 1), B('soft', 'Use the soft edge of the layer', true) },
        eval = function(E, v, ins)
            local i = math.floor(v.layer + 0.5)
            local L = Layout.Doc.layers[i]
            if not L then error('the layout has no layer ' .. i) end
            if v.soft then return { out = Layout.LayerMask(E, E.like, i) } end
            return { out = Layout.RawLayerMask(E, E.like, i) }
        end })

    Def('layout_bases', { label = 'Map layout: bases', cat = 'sources', kw = 'map layout bases start positions players centres discs',
        desc = 'The bases drawn on layers of the kind Base: a mask with a disc around the centre of each blob and the number of bases (players) as a number.',
        outputs = { Out('out', 'mask'), Out('count', 'number') }, liveKey = Key,
        params = { N('radius', 'Disc radius (units)', 2, 200, 1, '%d', 30), N('edge', 'Soft edge (units)', 0, 100, 1, '%d', 12) },
        eval = function(E, v, ins)
            local list = Layout.BaseCentres()
            local pts = {}
            for _, c in list do
                table.insert(pts, c.x)
                table.insert(pts, c.z)
                table.insert(pts, v.radius)
                table.insert(pts, 1)
            end
            local f
            if table.getn(list) == 0 then
                f = E:Const(0)
            else
                f = E:Op('points_mask', { like = E.like, pts = pts, feather = v.edge })
            end
            return { out = f, count = table.getn(list) }
        end })
end
