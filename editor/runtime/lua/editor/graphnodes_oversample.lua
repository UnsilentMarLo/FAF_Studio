-- The Oversample node of the terrain graph: puts a height on a grid `factor` times finer than the run's (the map's) so that everything after it, up to the map-wide textures, can be made
-- at a multiple of the map's resolution. graphnodes.lua calls Install(Kit, Covers) once (like graphnodes_map.lua), so this file does not import graphnodes.lua at load time.
--
--   Oversample   height -> height on a (w - 1) * factor + 1 grid (first and last sample kept, Catmull-Rom smooth so the normals of the fine grid are not blocky), and the erosion masks.
--                When the height comes straight from an erosion node (Hydraulic, Droplet, Stream power) and "Run the erosion again" is on, the erosion runs again on the fine grid from its own
--                inputs with its settings scaled to the finer cell (erosion.lua OpParams, step < 1): the wear, deposit, flow and drainage masks then have the detail of the fine grid. The
--                cost of that run grows with the square of the factor and more.
--
-- Nodes after it work on the fine grid by themselves (graphrun.lua Run:Conform: inputs of other sizes are converted, E.like / E.step follow the finest input); the outputs that write into the map's
-- own grids (heights, paint, terrain types) average the fine field back down with a tent filter, which is what makes oversampled masks crisp; the map-wide textures (def.fineOk: Output: map normal map,
-- Output: map lighting) keep the fine grid and can be written at "As fine as the finest input".
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')

MAX_SAMPLES = 134217728          -- the native field cap (1 << 27): 8193 x 8193 is 67 million, 11585 a side is the limit

function Install(Kit, Covers)
    local Def, N, C, B, In, Out = Kit.Def, Kit.N, Kit.C, Kit.B, Kit.In, Kit.Out

    Covers['upsample'] = true
    Covers['downsample'] = true

    --- A field of the input grid put onto the fine grid `like` (a node's own tmp field).
    local function Fit(E, f, like, linear)
        local w = Fields.Info(f)
        local lw = Fields.Info(like)
        if w == lw then return f end
        return E:Op('upsample', { a = f, like = like, linear = linear and 1 or 0 })
    end

    Def('oversample', { label = 'Oversample', cat = 'erosion', kw = 'oversample supersample upsample resolution multiple higher fine detail 4k 8k grid factor rerun erosion masks map wide',
        desc = 'Puts the height on a grid that is `factor` times finer than the map\'s (smooth, not blocky), so what comes after it (normals, lighting, masks) can be made at a multiple of the map\'s resolution. Wired straight after an erosion node, with "Run the erosion again" on, it runs that erosion again on the fine grid from its own inputs (settings scaled to the finer cell): the wear, deposit, flow and drainage outputs then carry the fine detail. Nodes after it work on the fine grid by themselves; the outputs that write into the map (heights, paint, terrain types) average it back down, the map normal map and map lighting can be written at the fine size (texture size "As fine as the finest input"). Costs memory and time with the square of the factor: 2 = 4 times the samples, 4 = 16 times.',
        inputs = { In('a', 'height') },
        outputs = { Out('out', 'height'), Out('wear', 'mask'), Out('deposit', 'mask'), Out('flow', 'mask'), Out('accum', 'mask') },
        params = { N('factor', 'Factor (times the map\'s resolution)', 1, 8, 1, '%d', 2),
                   C('method', 'Resampling', { 'cubic', 'linear' }, { 'Smooth (cubic)', 'Linear' }, 'cubic'),
                   B('rerun', 'Run the erosion again at the higher resolution (when wired after an erosion node)', true) },
        eval = function(E, v, ins)
            local Nodes = import('/lua/editor/graphnodes.lua')
            local k = math.floor(v.factor + 0.5)
            local w, h = Fields.Info(ins.a)
            local nw, nh = (w - 1) * k + 1, (h - 1) * k + 1
            if nw * nh > MAX_SAMPLES then
                error(string.format('%d x %d samples are too many (at most %d million): use a smaller factor', nw, nh, math.floor(MAX_SAMPLES / 1000000)))
            end
            local up = E:Op('upsample', { a = ins.a, factor = k, linear = (v.method == 'linear') and 1 or 0 })
            local wantMasks = E.wanted.wear or E.wanted.deposit or E.wanted.flow or E.wanted.accum
            local wire = Graph.WireInto(E.node.id, 'a')
            local src = wire and Graph.NodeById(wire[1])
            local sdef = src and Nodes.Defs[src.type]
            local erosion = sdef and string.sub(src.type, 1, 6) == 'erode_' and not src.off and wire[2] == 'out'
            if not (erosion and v.rerun and k > 1) then
                if wantMasks then
                    error(erosion and 'turn on "Run the erosion again" (and a factor above 1) for the erosion masks' or 'the masks come from an erosion node: wire the height of Hydraulic, Droplet or Stream power erosion into this node')
                end
                return { out = up }
            end
            -- the erosion node again, on the fine grid: its inputs brought onto it, its own settings (wires applied), the environment of the fine grid
            local run = E.run
            local sins = {}
            for _, p in Nodes.Inputs(src.type) do
                local sw = Graph.WireInto(src.id, p.name)
                local val = sw and run:Value(sw[1], sw[2])
                if val ~= nil then
                    if (p.type == 'height' or p.type == 'mask') and type(val) == 'number' then
                        sins[p.name] = Fit(E, val, up, p.type == 'mask')
                    else
                        sins[p.name] = val
                    end
                end
            end
            if not sins.a then error('the erosion node before this one has no input value') end
            local sv = {}
            for _, p in sdef.params do
                local x = src.params[p.key]
                if x == nil then x = p.default end
                if p.kind == 'number' and p.wire and type(sins[p.key]) == 'number' then x = sins[p.key] end
                sv[p.key] = x
            end
            local _, _, cell = Fields.Info(up)
            local E2 = setmetatable({ like = up, cell = cell, step = E.step / k, node = src }, { __index = E })
            function E2:Seed(n)          -- the seed of the erosion node itself: the same droplets and variation as its own run
                local s = (run.seed or E.graph.seed) * 1009 + src.id * 101 + math.floor(n)
                return math.mod(s, 1000003)
            end
            local res = sdef.eval(E2, sv, sins)
            local out = {}
            for _, name in { 'out', 'wear', 'deposit', 'flow', 'accum' } do out[name] = res[name] end
            return out
        end })
end
