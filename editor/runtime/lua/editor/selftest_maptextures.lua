-- Self test of the map-wide shader textures (maptextures.lua, graphnodes_map.lua, the native op normal_map, the Map textures panel). Run in the live editor:
--   return import('/lua/editor/selftest_maptextures.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check). The shader, the layers and the graph of the open map are put back at the end.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local History = import('/lua/editor/history.lua')
local MT = import('/lua/editor/maptextures.lua')
local Panels = import('/lua/editor/gui/panels.lua')

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

    local mw = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    if not mw or mw < 129 or not Fields.IsAvailable() then return 'FAIL (needs a map of at least 129 samples and the field engine)' end
    local W = mw - 1

    -- ---- which shader reads what ---------------------------------------------------------------------------------------------------------------
    check('shader classes', MT.ShaderClass('Terrain000') == 'ext' and MT.ShaderClass('TTerrainXPExt') == 'ext' and MT.ShaderClass('TTerrainXP') == 'legacy' and MT.ShaderClass('Terrain250B') == 'splat'
        and MT.ShaderClass('Terrain150') == 'pbr' and MT.ShaderClass('Terrain301') == 'old301' and MT.ShaderClass('Terrain051') == 'spec' and MT.ShaderClass('Surprise') == 'other')
    local n0, l0, l3, m0, s1 = MT.Slot('normal', 'Terrain000'), MT.Slot('light', 'Terrain000'), MT.Slot('light', 'Terrain301'), MT.Slot('macro', 'Terrain000'), MT.Slot('specular', 'Terrain001')
    check('layer slots', n0 and n0.layer == 18 and l0 and l0.layer == 8 and l3 and l3.layer == 9 and m0 and m0.layer == 9 and s1 and s1.layer == 9)
    check('a legacy shader has no map-wide slots', MT.Slot('normal', 'TTerrainXP') == nil and MT.Slot('macro', 'Terrain001') == nil and MT.Slot('specular', 'Terrain000') == nil)
    check('the panel is registered', Panels.Get('maptextures') ~= nil)
    check('the native op is there', rawget(_G, 'ed_field_ops') ~= nil and (function() for _, n in Fields.OpNames() do if n == 'normal_map' then return true end end return false end)())

    local shader0 = ed_stratum_shader()
    local keep = {}
    for _, i in { 8, 9, 18, 19 } do
        local p, s = ed_stratum_layer(i)
        keep[i] = { p, s }
    end
    History.Clear()
    ed_stratum_shader('Terrain000')

    -- ---- the generators, directly ----------------------------------------------------------------------------------------------------------
    Fields.Run(function(S)
        local h = S:Height(1)
        local env = { Op = function(name, p) return S:Op(name, p) end, Add = function(f) return S:Add(f) end }
        local x, y, z = MT.NormalFields(env, h, {})
        local mn, mx = Fields.Stats(x)
        check('normal x is 0..1', mn >= 0 and mx <= 1, mn .. ' ' .. mx)
        local ymn = Fields.Stats(y)
        check('normal y is at least 0.5 (it points up)', ymn >= 0.5, ymn)
        local lit, light, ao = MT.Lighting(env, h, { azimuth = 315, altitude = 35, soft = 1, quality = 5, reach = 200, light = true, ambient = 0.2, ao = 0.5 })
        local a, b = Fields.Stats(lit)
        check('lit is 0..1', a >= 0 and b <= 1, a .. ' ' .. b)
        local c, d = Fields.Stats(light)
        check('light is 0..1', c >= 0 and d <= 1.0001, c .. ' ' .. d)
        local e, f = Fields.Stats(ao)
        check('ao is 0..1', e >= 0 and f <= 1.0001, e .. ' ' .. f)
        local depth = MT.WaterDepth(env, h)
        local dm, dx = Fields.Stats(depth)
        check('water depth is 0..1', dm >= 0 and dx <= 1, dm .. ' ' .. dx)
    end)

    -- ---- the normal map and the lighting texture, one undo step each ------------------------------------------------------------------------------
    local entry, err = MT.Generate('normal', { size = 128 })
    check('the normal map is made', entry ~= nil, err)
    local path, size = ed_stratum_layer(18)
    check('layer 8 normal map is a staged file, bigger than the map', path and string.find(path, '/edmaptex/maptex_normal_', 1, true) and size == W + 1, tostring(path) .. ' ' .. tostring(size))
    local cur = MT.Current('normal')
    check('the slot is active and made here', cur.active and cur.managed and not cur.empty)
    local px, tw, th = ed_dds_read(path)
    check('the file is 128 x 128', px and tw == 128 and th == 128, tostring(tw))
    if px then
        local bad = 0
        for i = 0, tw * th - 1, 17 do
            local x, z = px[i * 4 + 4] / 127.5 - 1, px[i * 4 + 2] / 127.5 - 1
            if x * x + z * z > 1.02 then bad = bad + 1 end
        end
        check('x and z are parts of a unit vector', bad == 0, bad)
    end
    check('a picture of it', MT.Preview('normal', 32) ~= nil)
    local before = ed_stratum_layer(18)
    local c1 = MT.Clear('normal')
    check('clear gives the neutral normal map', c1 ~= nil and (ed_stratum_layer(18)) == '/env/common/layers/none_normal.dds' and MT.Current('normal').empty)
    History.Undo()
    check('undo of clear', (ed_stratum_layer(18)) == before)
    History.Undo()
    check('undo of generate', (ed_stratum_layer(18)) == keep[18][1], tostring((ed_stratum_layer(18))))

    local e2, err2 = MT.Generate('light', { size = 128, soft = 1, reach = 300, ao = 0.3 })
    check('the lighting texture is made', e2 ~= nil, err2)
    local lpath, lsize = ed_stratum_layer(8)
    check('layer 8 albedo is a staged file', lpath and string.find(lpath, '/edmaptex/maptex_light_', 1, true) and lsize == W + 1, tostring(lpath))
    local lpx, lw = ed_dds_read(lpath)
    if lpx then
        local alphaOk = true
        for i = 0, lw * lw - 1, 13 do
            if lpx[i * 4 + 4] < 0 or lpx[i * 4 + 4] > 255 then alphaOk = false end
        end
        check('the shadow is in the alpha channel', alphaOk)
    end
    History.Undo()
    check('undo of the lighting texture', (ed_stratum_layer(8)) == keep[8][1])
    ed_stratum_shader('TTerrainXP')
    local none, why = MT.Generate('normal', {})
    check('a legacy shader refuses, with a reason', none == nil and why ~= nil and string.find(why, 'Terrain000', 1, true) ~= nil, tostring(why))
    ed_stratum_shader('Terrain000')

    -- ---- export ------------------------------------------------------------------------------------------------------------------------------
    local e3 = MT.Generate('normal', { size = 64 })
    local out = '../fieldtmp/maptex_export_test.dds'
    local ok, eerr = MT.Export('normal', out)
    check('export as DDS', ok and ed_file_exists(out), eerr)
    local imported, ierr = MT.Import('normal', out)
    check('import of a DDS', imported ~= nil, ierr)
    if ed_file_delete then pcall(ed_file_delete, out) end
    History.Undo()
    History.Undo()

    -- ---- the nodes -----------------------------------------------------------------------------------------------------------------------------
    for _, id in { 'normal_map', 'env_lighting', 'lighting_tex', 'out_normalmap', 'out_maplight' } do
        check('node ' .. id .. ' exists', Nodes.Defs[id] ~= nil)
    end
    check('the output nodes are outputs', Nodes.Defs.out_normalmap.output == 'mapnormal' and Nodes.Defs.out_maplight.output == 'maplight')
    local bad = {}
    for _, id in { 'normal_map', 'env_lighting', 'lighting_tex', 'out_normalmap', 'out_maplight' } do
        for _, p in Nodes.Defs[id].params do
            if p.kind == 'number' and not (p.min and p.max and p.step and p.fmt and p.default ~= nil and p.min < p.max and p.default >= p.min and p.default <= p.max) then table.insert(bad, id .. '.' .. p.key) end
        end
    end
    check('number parameters have a range, step, format and default', table.getn(bad) == 0, table.concat(bad, ' '))

    Graph.New('maptextures test')
    local src = Graph.Add('perlin', 0, 0, { scale = 120 })
    local hgt = Graph.Add('range', 0, 0, { lo = 10, hi = 70 })
    Graph.Connect(src.id, 'out', hgt.id, 'a')
    local nm = Graph.Add('normal_map', 0, 0)
    Graph.Connect(hgt.id, 'out', nm.id, 'a')
    local onm = Graph.Add('out_normalmap', 0, 0, { size = '128' })
    Graph.Connect(nm.id, 'rgba', onm.id, 'normal')
    local lt = Graph.Add('lighting_tex', 0, 0)
    Graph.Connect(hgt.id, 'out', lt.id, 'a')
    local ol = Graph.Add('out_maplight', 0, 0, { size = '128' })
    Graph.Connect(lt.id, 'shadow', ol.id, 'shadow')
    Graph.Connect(lt.id, 'ao', ol.id, 'ao')
    local env = Graph.Add('env_lighting', 0, 0)
    Graph.Connect(env.id, 'azimuth', lt.id, 'azimuth')
    Graph.Connect(env.id, 'altitude', lt.id, 'altitude')
    local rep = GRun.Refresh(true)
    local errs = {}
    for nid, msg in rep.errors do table.insert(errs, Graph.NodeById(nid).type .. ': ' .. msg) end
    check('the graph evaluates', table.getn(errs) == 0, table.concat(errs, ' | '))
    local main = GRun.GetMain()
    local e = main and main:Entry(nm.id)
    check('the normal map node has a colour and three masks', e and e.outs and e.outs.rgba and e.outs.rgba.r and e.outs.x and e.outs.y and e.outs.z)
    local lte = main and main:Entry(lt.id)
    check('the lighting node gives shadow and ao', lte and lte.outs and lte.outs.shadow and lte.outs.ao)
    local depth0 = History.Depth()
    local result, msg = GRun.Build()
    check('Build writes both textures', result ~= nil and result.maptextures == 2, tostring(msg))
    local depth1 = History.Depth()
    check('as one undo step', depth1 == depth0 + 1, depth0 .. ' -> ' .. depth1)
    check('layer 8 has both textures', string.find((ed_stratum_layer(18)) or '', 'maptex_normal_', 1, true) ~= nil and string.find((ed_stratum_layer(8)) or '', 'maptex_light_', 1, true) ~= nil)
    History.Undo()
    check('undo gives the layers back', (ed_stratum_layer(18)) == keep[18][1] and (ed_stratum_layer(8)) == keep[8][1])

    -- ---- put everything back -----------------------------------------------------------------------------------------------------------------
    for _, i in { 8, 9, 18, 19 } do
        if keep[i][1] and keep[i][1] ~= '' then ed_stratum_set_layer(i, keep[i][1], keep[i][2]) end
    end
    ed_stratum_shader(shader0)
    History.Clear()

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
    return 'PASS\n' .. table.concat(shown, '\n')
end
