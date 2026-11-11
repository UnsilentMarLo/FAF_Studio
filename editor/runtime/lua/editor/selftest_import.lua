-- Self test of the FAFME importers and exporters (fafme.lua over the ed_* natives of moho/editor/EdUpImportLua.cpp, upstream's logic of faf_editor_logic). Run in the live editor:
--   return import('/lua/editor/selftest_import.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check).
--
--   * each format: the sample file FAFME wrote (testdata/fafme/sample.*, the samples of upstream's own tests) is read, written again and read again, and means the same both times
--   * the files: Export... writes a file, Import... of that file adds the same data back, with undo
--   * the document: markers, units, the paint set, a texture layer, a layer set, lighting, sky and water go into the open map and come out of it again; everything is put back at the end
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local F = import('/lua/editor/fafme.lua')
local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local History = import('/lua/editor/history.lua')
local Env = import('/lua/editor/environment.lua')
local UserData = import('/lua/editor/userdata.lua')

local lines, failures = {}, {}

local function check(name, ok, why)
    table.insert(lines, (ok and '  ok  ' or '  FAIL ') .. name .. ((not ok and why) and (' (' .. tostring(why) .. ')') or ''))
    if not ok then table.insert(failures, name) end
end

local function Near(a, b, eps)
    return type(a) == 'number' and type(b) == 'number' and math.abs(a - b) <= (eps or 1e-3)
end

local function Sample(name)
    local path = ed_vfs_to_disk('/lua/editor/testdata/fafme/' .. name)
    local text = path and ed_read_file(path)
    return text
end

--- Reads the sample, writes what was read, reads that again; returns the first read, the text written and the second read.
local function RoundTrip(read, write, text)
    local a, errA = read(text)
    if not a then return nil, errA end
    local out = write(a)
    local b, errB = read(out)
    return a, out, b, errB
end

local function SameNumbers(a, b)
    for k, v in a do
        if type(v) == 'number' and not Near(v, b[k], 1e-4) then return false, k end
    end
    return true
end

function Run(verbose)
    lines, failures = {}, {}
    if not rawget(_G, 'ed_fafmapmarkers_read') then return 'FAIL (the FAFME natives are missing: an engine without EdUpImportLua.cpp)' end
    local doc = Map.Doc
    check('a map is open', doc ~= false and doc ~= nil)
    if not doc then return 'FAIL (no map)\n' .. table.concat(lines, '\n') end
    History.Clear()

    -- ---- the formats on the samples of FAFME ---------------------------------------------------------------------------------------------------
    local text = Sample('sample.fafmapmarkers')
    check('the marker sample is found', text ~= nil and string.len(text) > 100)
    local m = ed_fafmapmarkers_read(text or '', { existing = { 'Mass 00' }, reserved = { 'ARMY_1' } })
    check('markers: 4 read, 1 left out, 1 link', m and table.getn(m.markers) == 4 and m.skipped == 1 and m.links == 1)
    if m then
        local first = m.markers[1]
        check('markers: the first is Mass 01 (Mass 00 is taken), a tenth of FAFME\'s units, z flipped', first.name == 'Mass 01' and first.type == 'Mass'
              and Near(first.position[1], 125) and Near(first.position[2], 17.5) and Near(first.position[3], 300))
        check('markers: a path node links to the next', m.markers[2].type == 'Land Path Node' and table.getn(m.markers[2].links) + table.getn(m.markers[3].links) == 2)
        check('markers: the camera is a Camera Info', m.markers[4].type == 'Camera Info')
        local list = {}
        for _, mk in m.markers do
            table.insert(list, { name = mk.name, type = mk.type, position = mk.position, orientation = mk.orientation, adjacentTo = table.concat(mk.links, ' ') })
        end
        local out = ed_fafmapmarkers_write(list, { width = 512, height = 512 })
        local again = ed_fafmapmarkers_read(out, {})
        check('markers: what is written reads back as the same markers', again and table.getn(again.markers) == 4 and again.links == 1
              and again.markers[1].type == 'Mass' and Near(again.markers[1].position[3], 300))
        check('markers: the written file keeps the map size', string.find(out, '"MapWidth": 512', 1, true) ~= nil)
        local chosen = ed_fafmapmarkers_write(list, { names = { 'Mass 01' } })
        local one = ed_fafmapmarkers_read(chosen, {})
        check('markers: a list of names writes only those', one and table.getn(one.markers) == 1)
    end
    local bad, why = ed_fafmapmarkers_read('{ "nothing": 1 }', {})
    check('markers: another file is refused with a reason', bad == nil and type(why) == 'string' and why ~= '')

    text = Sample('sample.scunits')
    local u = ed_scunits_read(text or '', {})
    check('units: 2 units with FAFME\'s positions', u and table.getn(u.units) == 2 and u.units[1].bp == 'ueb0101' and Near(u.units[1].x, 250) and Near(u.units[1].y, 15) and Near(u.units[1].z, 300))
    check('units: the quarter turn comes back (a heading of a quarter turn)', u and Near(math.mod(u.units[1].heading - math.pi / 2 + 3 * math.pi, 2 * math.pi) - math.pi, 0, 1e-3))
    check('units: the second one has its platoon and the centre is the mean', u and u.units[2].platoon == 'Attack' and Near(u.centre[1], 260) and Near(u.centre[3], 310))
    if u then
        local back = ed_scunits_read(ed_scunits_write(u.units), {})
        check('units: written and read again', back and table.getn(back.units) == 2 and back.units[2].platoon == 'Attack' and Near(back.units[1].x, 250) and Near(back.units[1].heading, u.units[1].heading, 1e-3))
        local off = ed_scunits_read(text, { width = 100, height = 100, fit = true })
        check('units: from a bigger map they move together onto a smaller one', off and off.moved and Near(off.units[1].x, 40) and Near(off.units[2].x, 60))
    end

    text = Sample('sample.proppaintset')
    local p = ed_proppaintset_read(text or '')
    check('paint set: 2 props with their ranges and chances', p and table.getn(p) == 2 and p[1].blueprint == '/env/evergreen/props/trees/pine06_s1_prop.bp' and Near(p[1].scaleMin, 0.8) and Near(p[1].scaleMax, 1.2)
          and p[1].chance == 70 and p[2].rotationMin == 90 and p[2].rotationMax == 180)
    if p then
        local back = ed_proppaintset_read(ed_proppaintset_write(p))
        check('paint set: written with each entry\'s own values', back and table.getn(back) == 2 and back[2].rotationMin == 90 and Near(back[1].scaleMax, 1.2) and back[1].chance == 70)
    end

    text = Sample('sample.scmsl')
    local l = ed_scmsl_read(text or '')
    check('layer: paths and sizes', l and l.albedo == '/env/evergreen/layers/eg_gravel005_albedo.dds' and Near(l.albedoSize, 4) and Near(l.normalsSize, 2))
    if l then
        local back = ed_scmsl_read(ed_scmsl_write(l))
        check('layer: written and read again', back and back.albedo == l.albedo and back.normals == l.normals and Near(back.normalsSize, 2))
    end
    local set = { shader = 'TTerrainXP', layers = {} }
    for i = 1, 10 do set.layers[i] = { albedo = '/env/x/layers/l' .. i .. '_albedo.dds', normals = '/env/x/layers/l' .. i .. '_normals.dds', albedoSize = i + 0.5, normalsSize = i * 2 } end
    local readSet = ed_scmst_read(ed_scmst_write(set))
    check('layer set: the shader and all ten layers', readSet and readSet.shader == 'TTerrainXP' and table.getn(readSet.layers) == 10 and readSet.layers[10].albedo == '/env/x/layers/l10_albedo.dds'
          and Near(readSet.layers[3].albedoSize, 3.5))
    local short = ed_scmst_read('{ "ShaderName": "TTerrainXP", "Stratum0": ' .. ed_scmsl_write(set.layers[1]) .. ' }')
    check('layer set: a set without ten layers is refused', short == nil)

    text = Sample('sample.scmlighting')
    local num = ed_scmlighting_read(text or '')
    check('lighting: multiplier, sun, fill, bloom and fog', num and Near(num.light_mult, 1.5) and Near(num.sun_x, 0.7071068) and Near(num.sun_r, 1.2) and Near(num.fill_b, 0.4) and Near(num.bloom, 0.08)
          and Near(num.fog_g, 0.6) and Near(num.fog_start, 50) and Near(num.fog_end, 1500))
    if num then
        local back = ed_scmlighting_read(ed_scmlighting_write(num))
        local same, key = SameNumbers(num, back or {})
        check('lighting: written and read again', same, key)
    end

    text = Sample('sample.scmskybox')
    local sky = ed_scmskybox_read(text or '')
    check('sky: dome, colours, one planet, cirrus', sky and Near(sky.num.dome_ox, 512) and Near(sky.num.dome_radius, 4686) and Near(sky.num.dome_height, -35.45) and Near(sky.num.dome_w, 16) and Near(sky.num.horizon_g, 0.6)
          and Near(sky.num.sky_b, 0.7) and table.getn(sky.billboards) == 10 and Near(sky.billboards[2], 2000) and Near(sky.billboards[5], 250) and Near(sky.num.cirrus2_speed, 0.02) and Near(sky.num.cirrus4_speed, 0)
          and sky.texts.sky_billboards == '/textures/environment/Decal_test_Albedo003.dds')
    if sky then
        local back = ed_scmskybox_read(ed_scmskybox_write({ num = sky.num, texts = sky.texts, billboards = sky.billboards }))
        local same, key = SameNumbers(sky.num, back and back.num or {})
        check('sky: written and read again', same and back.texts.sky_billboards == sky.texts.sky_billboards and table.getn(back.billboards) == 10, key)
    end

    text = Sample('sample.scmwtr')
    local water = ed_scmwtr_read(text or '')
    check('water: levels, colour, sun and the four wave layers', water and Near(water.num.water_on, 1) and Near(water.num.water_elev, 17.5) and Near(water.num.w_color_g, 0.7) and Near(water.num.w_lerp_1, 0.119)
          and Near(water.num.w_sundir_y, -0.9604) and Near(water.num.w_sun_refl, 5) and Near(water.num.w_repeat_3, 0.5) and Near(water.num.w_move2_z, -0.095)
          and water.texts.water_cubemap == '/textures/environment/SkyCube_Evergreen01a.dds' and water.texts.water_wave4 == '/textures/engine/waves.dds')
    if water then
        local back = ed_scmwtr_read(ed_scmwtr_write({ num = water.num, texts = water.texts }))
        local same, key = SameNumbers(water.num, back and back.num or {})
        check('water: written and read again', same and back.texts.water_wave4 == water.texts.water_wave4, key)
    end

    -- ---- the document ---------------------------------------------------------------------------------------------------------------------------
    local markers = doc.save.MasterChain._MASTERCHAIN_.Markers
    local before = 0
    for _, _ in markers do before = before + 1 end
    local ok, report = F.ImportMarkersText(Sample('sample.fafmapmarkers'))
    check('import markers: done', ok == true, report)
    local after = 0
    for _, _ in markers do after = after + 1 end
    check('import markers: 4 new markers, selected', after == before + 4 and Tools.SelectionCount() == 4, after - before)
    local linked = 0
    for name, mk in markers do
        if mk.type == 'Land Path Node' and mk.adjacentTo and mk.adjacentTo ~= '' then linked = linked + 1 end
    end
    check('import markers: the two path nodes are linked to each other', linked == 2, linked)
    local exported = F.MarkersToText({})
    local roundTrip = ed_fafmapmarkers_read(exported or '', {})
    check('export markers: every marker of the map is in the file', roundTrip and table.getn(roundTrip.markers) == after - 0 - roundTrip.skipped, roundTrip and table.getn(roundTrip.markers))
    local firstNew
    for _, it in Tools.Items do
        if markers[it.name] and markers[it.name].type == 'Mass' then firstNew = it.name end
    end
    local selectedOnly = F.MarkersToText({ firstNew })
    local one = ed_fafmapmarkers_read(selectedOnly or '', {})
    check('export markers: a named marker alone', firstNew ~= nil and one and table.getn(one.markers) == 1 and one.markers[1].type == 'Mass')
    History.Undo()
    local gone = 0
    for _, _ in markers do gone = gone + 1 end
    check('import markers: one undo removes them all', gone == before, gone)
    History.Redo()
    History.Undo()

    local tmpDir = UserData.Path('fafme_selftest')
    ed_write_file(tmpDir .. '/.keep', '')
    local file = tmpDir .. '/test.fafmapmarkers'
    F.ImportMarkersText(Sample('sample.fafmapmarkers'))
    local done = F.ExportMarkers(file)
    check('export markers to a file', done == true and ed_read_file(file) ~= nil)
    History.Undo()
    local okFile, whyFile = F.ImportMarkers(file)
    local back = 0
    for _, _ in markers do back = back + 1 end
    check('import markers from that file', okFile == true and back == before + 4, whyFile)
    History.Undo()
    local missing = F.ImportMarkers(tmpDir .. '/nothing.fafmapmarkers')
    check('import markers: a file that is not there says so', missing == nil)

    -- units: a temporary army
    local armyName = 'ARMY_FAFME_TEST'
    local hadArmies = doc.save.Armies ~= nil
    doc.save.Armies = doc.save.Armies or {}
    doc.save.Armies[armyName] = { Units = { type = 'GROUP', orders = '', platoon = '', Units = { INITIAL = { type = 'GROUP', orders = '', platoon = '', Units = {} } } } }
    local Units = import('/lua/editor/units.lua')
    local armyBefore = Units.ArmyName
    Units.ArmyName = armyName
    ok, report = F.ImportUnitsText(Sample('sample.scunits'))
    check('import units: done', ok == true, report)
    local count = 0
    for _, unit in Units.All() do if unit.army == armyName then count = count + 1 end end
    check('import units: 2 units in the army', count == 2, count)
    local text2 = F.UnitsToText(Units.All())
    local read2 = text2 and ed_scunits_read(text2, {})
    check('export units: the army\'s units are in the file', read2 and table.getn(read2.units) >= 2, read2 and table.getn(read2.units))
    History.Undo()
    count = 0
    for _, unit in Units.All() do if unit.army == armyName then count = count + 1 end end
    check('import units: one undo removes them', count == 0, count)
    doc.save.Armies[armyName] = nil
    if not hadArmies then doc.save.Armies = nil end
    Units.ArmyName = armyBefore

    -- the paint set
    local Scatter = import('/lua/editor/scatter.lua')
    local entriesBefore, modeBefore = Scatter.Entries, Scatter.Settings.mode
    ok, report = F.ImportPaintSetText(Sample('sample.proppaintset'))
    check('import paint set: done', ok == true, report)
    check('import paint set: the list has the two props with their own ranges', table.getn(Scatter.Entries) == 2 and Scatter.Entries[1].bp == '/env/evergreen/props/trees/pine06_s1_prop.bp'
          and Near(Scatter.Entries[1].weight, 0.7) and Near(Scatter.Entries[1].scaleMin, 80) and Scatter.Entries[2].rotMin == 90 and Scatter.Entries[2].rotMax == 180)
    local setText = F.PaintSetToText()
    local setBack = setText and ed_proppaintset_read(setText)
    check('export paint set: the list comes back', setBack and table.getn(setBack) == 2 and setBack[1].chance == 70 and setBack[2].rotationMax == 180 and Near(setBack[1].scaleMin, 0.8))
    History.Undo()
    check('import paint set: undo puts the old list back', Scatter.Entries == entriesBefore and Scatter.Settings.mode == modeBefore)

    -- layers
    if rawget(_G, 'ed_stratum_layer') then
        local layer0 = F.LayerToText(0)
        check('export layer: the base layer is written', layer0 ~= nil and ed_scmsl_read(layer0) ~= nil)
        local Strata = import('/lua/editor/strata.lua')
        local li = 0
        for i = 0, 9 do if Strata.Snapshot(i).albedo ~= '' then li = i break end end
        local snap = Strata.Snapshot(li)
        local layerText = ed_scmsl_write({ albedo = snap.albedo, normals = snap.normal, albedoSize = 7.5, normalsSize = 6 })
        ok, report = F.ImportLayerText(li, layerText)
        check('import layer: done', ok == true, report)
        local now = Strata.Snapshot(li)
        check('import layer: the tile sizes are set', Near(now.size, 7.5) and Near(now.nsize, 6), now.size)
        History.Undo()
        local undone = Strata.Snapshot(li)
        check('import layer: undo puts the sizes back', Near(undone.size, snap.size) and Near(undone.nsize, snap.nsize))
        ok, report = F.ImportLayerText(li, ed_scmsl_write({ albedo = '/env/nothing/layers/nothing_albedo.dds', normals = '', albedoSize = 3, normalsSize = 3 }))
        check('import layer: a texture that does not exist is refused and the layer is left alone', ok == nil and Near(Strata.Snapshot(li).size, snap.size), report)

        local shader = ed_stratum_shader()
        local setOut = F.LayersToText()
        local setIn = setOut and ed_scmst_read(setOut)
        check('export layer set: shader and ten layers', setIn and setIn.shader == shader and table.getn(setIn.layers) == 10)
        local snaps = {}
        for i = 0, 9 do snaps[i] = Strata.Snapshot(i) end
        ok, report = F.ImportLayersText(setOut)
        check('import layer set: the same set changes nothing', ok == true and ed_stratum_shader() == shader, report)
        local same = true
        for i = 0, 9 do
            local s = Strata.Snapshot(i)
            if s.albedo ~= snaps[i].albedo or not Near(s.size, snaps[i].size) then same = false end
        end
        check('import layer set: every layer is as it was', same)
        History.Undo()
        ok, report = F.ImportLayersText(ed_scmst_write({ shader = 'NoSuchShader', layers = setIn.layers }))
        check('import layer set: a shader this game does not have stops it', ok == nil and ed_stratum_shader() == shader, report)
    end

    -- lighting, sky, water
    if Env.Available() then
        local light0 = Env.Capture({ 'light' })
        local numIn = ed_scmlighting_read(Sample('sample.scmlighting'))
        ok, report = F.ImportLightingText(Sample('sample.scmlighting'))
        check('import lighting: done', ok == true, report)
        check('import lighting: the map has the values', Near(Env.Value('light_mult'), numIn.light_mult) and Near(Env.Value('fog_end'), 1500) and Near(Env.Value('bloom'), 0.08))
        local lightText = F.LightingToText()
        local lightBack = lightText and ed_scmlighting_read(lightText)
        check('export lighting: the map\'s lighting comes back', lightBack and Near(lightBack.light_mult, numIn.light_mult) and Near(lightBack.fog_start, 50))
        History.Undo()
        check('import lighting: undo puts it back', Near(Env.Value('light_mult'), light0.num.light_mult) and Near(Env.Value('fog_end'), light0.num.fog_end))

        local sky0 = Env.Capture({ 'sky', 'skyshape' })
        ok, report = F.ImportSkyText(Sample('sample.scmskybox'))
        check('import sky: done', ok == true, report)
        check('import sky: dome, colours and the planet are in the map', Near(Env.Value('dome_radius'), 4686) and Near(Env.Value('horizon_g'), 0.6) and table.getn(Env.Billboards()) == 1
              and Near(Env.Billboards()[1].y, 2000))
        local skyText = F.SkyToText()
        local skyBack = skyText and ed_scmskybox_read(skyText)
        check('export sky: the map\'s sky comes back', skyBack and Near(skyBack.num.dome_radius, 4686) and table.getn(skyBack.billboards) == 10)
        History.Undo()
        check('import sky: undo puts it back', Near(Env.Value('dome_radius'), sky0.num.dome_radius) and table.getn(Env.Billboards()) == math.floor(table.getn(sky0.billboards) / 10))

        local water0 = Env.Capture({ 'water', 'waves', 'levels' })
        ok, report = F.ImportWaterText(Sample('sample.scmwtr'))
        check('import water: done', ok == true, report)
        check('import water: the level and the colour are in the map', Near(Env.Value('water_elev'), 17.5) and Near(Env.Value('w_color_g'), 0.7) and Near(Env.Value('water_on'), 1))
        local waterText = F.WaterToText()
        local waterBack = waterText and ed_scmwtr_read(waterText)
        check('export water: the map\'s water comes back', waterBack and Near(waterBack.num.water_elev, 17.5) and waterBack.texts.water_wave4 == '/textures/engine/waves.dds')
        History.Undo()
        check('import water: undo puts it back', Near(Env.Value('water_elev'), water0.num.water_elev) and Near(Env.Value('w_color_g'), water0.num.w_color_g))
    else
        check('the environment natives are there', false)
    end

    -- the read-only workspace refuses an import
    local oldReadOnly = Tools.ReadOnly
    Tools.ReadOnly = true
    local refused = F.ImportMarkersText(Sample('sample.fafmapmarkers'))
    Tools.ReadOnly = oldReadOnly
    check('a read-only workspace refuses an import', refused == nil)

    History.Clear()
    local shown = lines
    if not verbose then
        shown = {}
        for _, line in lines do
            if string.sub(line, 1, 6) ~= '  ok  ' then table.insert(shown, line) end
        end
        table.insert(shown, '  ' .. (table.getn(lines) - table.getn(shown)) .. ' checks ok')
    end
    if table.getn(failures) > 0 then
        return 'FAIL (' .. table.getn(failures) .. ': ' .. table.concat(failures, ', ') .. ')\n' .. table.concat(shown, '\n')
    end
    return 'PASS\n' .. table.concat(shown, '\n')
end
