-- Self test of the Oversample node (graphnodes_oversample.lua), the grid handling of the graph evaluator (graphrun.lua Run:Conform) and the big texture writer (ed_dds_fields, maptextures.lua
-- WriteMapChannels / TextureSize). Run in the live editor:
--   return import('/lua/editor/selftest_oversample.lua').Run()
-- Works on the open map; changes no terrain and paints nothing (the graph is evaluated in a private run, no output node is built).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local GraphRun = import('/lua/editor/graphrun.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
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
    local function Done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end

    -- the node and the sizes
    local def = Nodes.Defs.oversample
    check('the Oversample node exists with the height and the four erosion masks as outputs', def ~= nil and table.getn(def.outputs) == 5 and def.outputs[1].name == 'out' and def.outputs[2].name == 'wear')
    check('the map textures may keep the fine grid, the heights and the paint may not', Nodes.Defs.out_normalmap.fineOk and Nodes.Defs.out_maplight.fineOk and not Nodes.Defs.out_height.fineOk and not Nodes.Defs.out_roughness.fineOk)
    check('the texture size "grid" follows the finest field and is capped at the writer\'s maximum', MT.TextureSize('grid', 1024, 4096) == (rawget(_G, 'ed_dds_fields') and 4096 or 2048) and MT.TextureSize('grid', 1024, 100000) == MT.MaxTextureSize() and MT.TextureSize('auto', 4096) == 1024)
    check('the erosion settings scale to a finer grid (more iterations, less rain per step)', (function()
        local Erosion = import('/lua/editor/erosion.lua')
        local base = Erosion.OpParams('hydraulic', { iterations = 60, rain = 0.004, erosion = 0.08, deposition = 0.05, smooth_passes = 1 }, 1, 1)
        local fine = Erosion.OpParams('hydraulic', { iterations = 60, rain = 0.004, erosion = 0.08, deposition = 0.05, smooth_passes = 1 }, 0.5, 1)
        return fine.iterations == 120 and fine.rain < base.rain and fine.erosion < base.erosion
    end)())

    if not Fields.IsAvailable() or not ed_terrain_info() then return Done() end
    local mw = ed_terrain_info()

    -- the native ops
    Fields.Run(function(S)
        local H = S:Height(4)
        local n = S:Op('perlin', { like = H, seed = 5, scale = 60, octaves = 4 })
        local w, h, cell = Fields.Info(n)
        local up = S:Op('upsample', { a = n, factor = 2 })
        local uw, uh, ucell = Fields.Info(up)
        check('upsample gives (w - 1) * factor + 1 samples over the same world extent', uw == (w - 1) * 2 + 1 and uh == (h - 1) * 2 + 1 and math.abs(ucell * 2 - cell) < 1e-5, uw .. 'x' .. uh .. ' cell ' .. ucell)
        check('upsample keeps the samples that lie on the old grid', math.abs(Fields.Get(up, 6, 8) - Fields.Get(n, 3, 4)) < 1e-4 and math.abs(Fields.Get(up, 2 * (w - 1), 2 * (h - 1)) - Fields.Get(n, w - 1, h - 1)) < 1e-4)
        local down = S:Op('downsample', { a = up, like = n })
        local lo, hi, mean = Fields.Stats(S:Op('sub', { a = down, b = n }))
        check('downsample (tent filter) of the upsampled field is close to the original', lo > -0.02 and hi < 0.02 and math.abs(mean) < 0.001, string.format('%.4f %.4f %.5f', lo, hi, mean))
        local lin = S:Op('upsample', { a = n, factor = 2, linear = 1 })
        local llo, lhi = Fields.Stats(lin)
        local nlo, nhi = Fields.Stats(n)
        check('linear upsampling does not overshoot the range', llo >= nlo - 1e-5 and lhi <= nhi + 1e-5)
        local ok = pcall(function() S:Op('add', { a = n, b = up }) end)
        check('the other ops still refuse two sizes (the evaluator converts the inputs)', not ok)
        -- the writer: a 64 x 64 texture from four fields, read back
        if rawget(_G, 'ed_dds_fields') then
            local one = S:Op('const', { like = n, value = 1 })
            local half = S:Op('const', { like = n, value = 0.5 })
            local zero = S:Op('const', { like = n, value = 0 })
            local path = MT.STAGE .. '/selftest_oversample.dds'
            local bytes, err = ed_dds_fields(path, 64, mw - 1, one, half, zero, one)
            check('ed_dds_fields writes a DXT5 file with mip maps', bytes and bytes > 64 * 64 and bytes < 64 * 64 * 2, tostring(err or bytes))
            if bytes then
                local px, pw, ph, mips, fourcc = ed_dds_read(path)
                check('it reads back as 64 x 64 DXT5 with 7 levels and the channels in order', pw == 64 and ph == 64 and fourcc == 'DXT5' and mips == 7 and px and math.abs(px[1] - 255) <= 8 and math.abs(px[2] - 128) <= 8 and px[3] <= 8 and px[4] >= 247, tostring(pw) .. ' ' .. tostring(fourcc) .. ' ' .. tostring(mips))
                if rawget(_G, 'ed_file_delete') then pcall(ed_file_delete, path) end
            end
        end
    end)

    -- the graph: erosion -> oversample 2 -> normals, the masks, a height output; evaluated in a private run at a coarse step
    local before = Graph.Current
    Graph.New('selftest oversample')
    local function A(t, p) return Graph.Add(t, 0, 0, p) end
    local gen = A('simplex', { scale = 70, octaves = 4, seed = 2 })
    local rng = A('range', { lo = 28, hi = 60 })
    local ero = A('erode_hydraulic', { iterations = 20 })
    local ovs = A('oversample', { factor = 2, rerun = true })
    local nrm = A('normal_map', {})
    local outN = A('out_normalmap', { size = 'grid', assign = false })
    local outH = A('out_height', {})
    local mix = A('add', {})
    Graph.Connect(gen.id, 'out', rng.id, 'a')
    Graph.Connect(rng.id, 'out', ero.id, 'a')
    Graph.Connect(ero.id, 'out', ovs.id, 'a')
    Graph.Connect(ovs.id, 'out', nrm.id, 'a')
    Graph.Connect(nrm.id, 'rgba', outN.id, 'normal')
    Graph.Connect(ovs.id, 'out', outH.id, 'a')
    Graph.Connect(ovs.id, 'wear', mix.id, 'a')
    Graph.Connect(rng.id, 'out', mix.id, 'b')            -- the base grid meets the fine grid: the evaluator brings them together
    local run = GraphRun.NewRun{ step = 4 }
    local okRun, report = pcall(run.Evaluate, run)
    check('the graph evaluates', okRun, tostring(report))
    if okRun then
        local errs = ''
        for id, msg in report.errors do errs = errs .. id .. ': ' .. tostring(msg) .. '; ' end
        check('without an error in any node', errs == '', errs)
        local bw = Fields.Info(run.like)
        local fw = (bw - 1) * 2 + 1
        local function Width(id, port) local f = run:Value(id, port) return f and (Fields.Info(f)) end
        check('the oversample node gives the fine grid for the height and the wear mask (erosion run again)', Width(ovs.id, 'out') == fw and Width(ovs.id, 'wear') == fw, tostring(Width(ovs.id, 'out')) .. ' / ' .. tostring(Width(ovs.id, 'wear')))
        local col = run:Value(nrm.id, 'rgba')
        check('the normal map after it is made on the fine grid', col and (Fields.Info(col.r)) == fw)
        local view = run:Value(outN.id, 'view')
        check('Output: map normal map keeps the fine grid', view and (Fields.Info(view.r)) == fw)
        check('Output: heights gets the run\'s grid again (averaged)', Width(outH.id, 'view') == bw, tostring(Width(outH.id, 'view')))
        check('a node that mixes the base grid with the fine grid works at the fine grid', Width(mix.id, 'out') == fw, tostring(Width(mix.id, 'out')))
        local rerun = run:Value(ovs.id, 'out')
        local plainUp = Fields.Op('upsample', { a = run:Value(ero.id, 'out'), like = rerun })
        local diff = Fields.Op('sub', { a = rerun, b = plainUp })
        local lo, hi = Fields.Stats(diff)
        check('the erosion run again at the fine grid is not just the upsampled coarse result', math.max(math.abs(lo), math.abs(hi)) > 0.01, string.format('%.5f %.5f', lo, hi))
        Fields.Free(plainUp)
        Fields.Free(diff)
        -- without the rerun the masks are refused with a reason, the height is the plain smooth upsampling
        Graph.SetParam(ovs.id, 'rerun', false)
        local ok2, report2 = pcall(run.Evaluate, run)
        local msg = ok2 and report2.errors[ovs.id] or nil
        check('with "Run the erosion again" off the wear output has no value and says why', msg ~= nil and string.find(msg, 'Run the erosion again', 1, true) ~= nil, tostring(msg))
    end
    run:Free()
    if before then Graph.Replace(Graph.Plain(before), 'selftest') end
    return Done()
end
