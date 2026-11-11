-- The material editor (WP10 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP10_MATERIAL.md): upstream's colour texture graph bound as ed_tex_*, the document model
-- (material.lua: edits, undo, pictures, files) and the bake that writes DDS files the engine loads as a stratum layer's textures.
-- Through /edcmd in a session with a map open:
--   return import('/lua/editor/selftest_material.lua').Run()
-- The open map's stratum layer 7 and its mask are changed and put back.
--
-- Lua 5.0 dialect.

local M = import('/lua/editor/material.lua')
local Strata = import('/lua/editor/strata.lua')
local History = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Check(ok, text)
    if not ok then failed = failed + 1 end
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
end

local function Report()
    return (failed == 0 and 'PASS' or ('FAIL (' .. failed .. ')')) .. ' selftest_material\n' .. table.concat(out, '\n')
end

local function Now()
    return GetSystemTimeSeconds()
end

--- Waits (busy, the worker thread runs on its own) for the bake job; the poll table or nil on a timeout.
local function WaitBake(job, seconds)
    local stop = Now() + seconds
    while Now() < stop do
        local r = ed_tex_bake_poll(job)
        if r and r.done then return r end
    end
    return nil
end

local function FindNode(snap, typeName)
    for _, n in snap.nodes do
        if n.type == typeName then return n end
    end
    return nil
end

function Run()
    out, failed = {}, 0
    local ok, err = pcall(function()
        Check(M.Available(), 'the ed_tex_* natives exist')
        local types = M.Types()
        Check(table.getn(types) >= 30, 'the palette has ' .. table.getn(types) .. ' node types (upstream has 35)')
        Check(M.TypeOf('Noise') ~= nil and M.TypeOf('Output') ~= nil and M.TypeOf('HeightToNormal') ~= nil, 'Noise, Output and HeightToNormal are in it')
        local cats = M.Categories()
        Check(table.getn(cats) >= 8, 'the palette groups into ' .. table.getn(cats) .. ' categories')

        -- ---- a graph ----------------------------------------------------------------------------------------------------------------
        local d = M.New('start')
        local s = M.Snap()
        Check(d and table.getn(s.nodes) == 4 and table.getn(s.links) == 4 and s.output ~= 0, 'a new graph is upstream\'s start graph: 4 nodes, 4 links, an Output')
        Check(M.PinLinked('Albedo') and M.PinLinked('Normal') and not M.PinLinked('Mask'), 'Albedo and Normal are linked, Mask is not')
        M.SetPreviewSize(64)
        local n1, ms = ed_tex_eval(d.id)
        Check(n1 == 4, 'the first evaluation computes the 4 nodes (' .. n1 .. ', ' .. string.format('%.1f', ms) .. ' ms)')
        local n2 = ed_tex_eval(d.id)
        Check(n2 == 0, 'the second computes none (cached by revision)')

        -- ---- edits and undo -------------------------------------------------------------------------------------------------------------
        local before = ed_tex_save(d.id)
        local cell = M.AddNode('Cells', 0, 200)
        Check(cell and table.getn(M.Snap().nodes) == 5, 'AddNode adds a node')
        Check(M.Undo() and table.getn(M.Snap().nodes) == 4 and ed_tex_save(d.id) == before, 'Undo takes it away (the graph file is the same as before)')
        Check(M.Redo() and table.getn(M.Snap().nodes) == 5, 'Redo puts it back')
        local noise = FindNode(M.Snap(), 'Noise')
        local def = M.TypeOf('Noise')
        local scalePar
        for i, p in def.params do
            if p.kind == 'float' and not scalePar then scalePar = i - 1 end
        end
        M.SetParam(noise.id, scalePar, 3, 'slider')
        M.SetParam(noise.id, scalePar, 4, 'slider')
        M.SetParam(noise.id, scalePar, 5, 'slider')
        local depth = table.getn(d.undo)
        M.Undo()
        Check(M.Node(noise.id).params[scalePar + 1].v[1] ~= 5 and depth >= 2, 'three slider edits in a row are one undo step')
        Check(table.getn(d.undo) == depth - 1, 'and one undo entry')
        local okLink, res = M.Connect(M.Node(noise.id).id, 0, cell, 0)
        Check(okLink == false or res == 'ok', 'a link between two pattern nodes is answered (' .. tostring(res) .. ')')
        local blurA = M.AddNode('Blur', 400, 0)
        local blurB = M.AddNode('Blur', 400, 100)
        local okAB, resAB = M.Connect(blurA, 0, blurB, 0)
        local okBA, resBA = M.Connect(blurB, 0, blurA, 0)
        Check(okAB and resBA == 'cycle', 'a link that would close a loop is refused (' .. tostring(resBA) .. ')')
        M.Disconnect(M.OutputNode(), 2)

        -- ---- evaluation, pictures ----------------------------------------------------------------------------------------------------
        M.Evaluate()
        local info = M.NodeInfo(noise.id)
        Check(info and info.outputs[1] and info.outputs[1].size == 64, 'the noise node has a 64 x 64 output after the evaluation')
        local pic = M.Picture(noise.id, 0, 32)
        Check(pic ~= nil, 'Picture writes a node\'s output (' .. tostring(pic) .. ')')
        local disk = pic and ed_vfs_to_disk(pic)
        local ddsInfo = disk and ed_tex_dds_info(disk)
        Check(ddsInfo and ddsInfo.width == 32 and ddsInfo.height == 32 and ddsInfo.mips == 6, 'the engine\'s own decoder reads it back: 32 x 32 with 6 mip levels')
        local pic2 = M.Picture(noise.id, 0, 32)
        Check(pic2 == pic, 'the picture is cached while the node does not change')
        M.SetParam(noise.id, scalePar, 9)
        M.Evaluate()
        local pic3 = M.Picture(noise.id, 0, 32)
        Check(pic3 ~= pic, 'and a new file when it does')
        Check(M.OutputPicture('Albedo', 64) ~= nil, 'the Output\'s Albedo as a picture')
        Check(M.OutputPicture('Mask', 64) == nil, 'an unlinked Mask has none')
        local lit = M.LitPicture(0, 64, 0.6, -0.7)
        local litInfo = lit and ed_tex_dds_info(ed_vfs_to_disk(lit))
        Check(litInfo and litInfo.width == 64, 'the lit sphere is a 64 x 64 picture')

        -- ---- files ------------------------------------------------------------------------------------------------------------------
        local text = ed_tex_save(d.id)
        local saved, why2 = M.Save('selftest_material')
        Check(saved, 'Save writes materials/selftest_material' .. M.EXT .. ' (' .. tostring(why2) .. ')')
        local listed = false
        for _, name in M.Files() do
            if name == 'selftest_material' then listed = true end
        end
        Check(listed, 'the file is in the list of saved graphs')
        local opened, why3 = M.Open('selftest_material')
        Check(opened and ed_tex_save(M.Doc.id) == text, 'Open reads it back: the same graph file (' .. tostring(why3) .. ')')
        local d2 = M.Doc
        local bad, badWhy = ed_tex_load(d2.id, '{ this is not a graph')
        Check(not bad, 'a broken file is refused (' .. tostring(badWhy) .. ')')
        local textNow = ed_tex_save(d2.id)
        Check(textNow == text, 'and the graph stays as it was (' .. string.len(textNow) .. ' / ' .. string.len(text) .. ' bytes)')
        ed_write_file(M.FOLDER .. '/selftest_material' .. M.EXT, '')

        -- ---- the Map nodes ----------------------------------------------------------------------------------------------------------
        local ds = M.New('empty')
        local height = M.AddNode('TerrainHeight', 0, 0)
        local slope = M.AddNode('TerrainSlope', 0, 100)
        local mask = M.AddNode('TerrainMask', 0, 200)
        M.SetPreviewSize(64)
        M.Evaluate()
        Check(M.Snap().usesTerrain, 'a graph with Map nodes says it uses the terrain')
        local wh = M.NodeInfo(height)
        Check(M.Doc.terrain and wh and wh.warning == '', 'the open map\'s heights reach the Map Height node (no warning: "' .. tostring(wh and wh.warning) .. '")')
        local picA = M.Picture(height, 0, 32)
        M.CaptureTerrain()
        M.Evaluate()
        local picB = M.Picture(height, 0, 32)
        Check(picA ~= nil and picB ~= nil and picA ~= picB, 'reading the map again makes new pictures of the Map nodes (a cached picture would show the old heights)')
        local ws = M.NodeInfo(slope)
        Check(ws and ws.warning == '', 'and the Map Slope node')
        local wm = M.NodeInfo(mask)
        Check(wm and wm.warning == '', 'and the Map Mask node')

        -- ---- the bake and the layer ----------------------------------------------------------------------------------------------------
        local dg = M.New('start')
        local gmap = FindNode(M.Snap(), 'GradientMap')
        local noiseN = FindNode(M.Snap(), 'Noise')
        -- a mask: the noise into the output's Mask
        Check(M.Connect(noiseN.id, 0, M.OutputNode(), 2), 'the noise is linked to the Mask')
        local adisk, ndisk = M.TMP .. '/bake_a.dds', M.TMP .. '/bake_n.dds'
        local job = ed_tex_bake_start(dg.id, { size = 128, albedo = adisk, normal = ndisk })
        local r = WaitBake(job, 30)
        Check(r and r.ok, 'a bake job at 128 finishes ok (' .. tostring(r and r.error) .. ', ' .. tostring(r and r.millis) .. ' ms)')
        Check(r and r.albedoBytes > 0 and r.normalBytes > 0 and r.hasMask, 'it wrote an albedo and a normal file and has a mask')
        local ai = ed_tex_dds_info(adisk)
        local ni = ed_tex_dds_info(ndisk)
        Check(ai and ai.width == 128 and ai.mips == 8, 'the albedo file is a 128 x 128 DDS with 8 mips (the engine decodes it)')
        Check(ni and ni.width == 128 and ni.centreA == 255, 'the normal file is a 128 x 128 DDS')
        -- BC3 of 128 x 128 with 8 mips: 16384 + 4096 + ... plus the header
        Check(ai and ai.bytes > 128 + 128 * 128 and ai.bytes < 128 + 128 * 128 * 2, 'its size is that of a BC3 file (' .. tostring(ai and ai.bytes) .. ' bytes)')
        ed_tex_bake_free(job)
        local never = ed_tex_bake_start(dg.id, { size = 4096, albedo = M.TMP .. '/bake_x.dds' })
        ed_tex_bake_cancel(never)
        ed_tex_bake_free(never)
        Check(true, 'a running job can be cancelled and freed')

        local layer = 7
        local w, h = ed_stratum_info()
        local albedoBefore, sizeBefore = ed_stratum_layer(layer)
        local normalBefore = ed_stratum_layer(layer + 10)
        local maskBefore = ed_stratum_read(layer - 1, 0, 0, w - 1, h - 1)
        M.SetPreviewSize(64)
        local applied = M.Apply({ stratum = layer, size = 256, tile = 20, mask = true })
        Check(applied, 'Apply starts a bake')
        local stop = Now() + 30
        while M.Job and Now() < stop do M.Refresh() end
        Check(not M.Job, 'and finishes it (' .. M.Status .. ')')
        local albedoAfter, sizeAfter = ed_stratum_layer(layer)
        local normalAfter = ed_stratum_layer(layer + 10)
        Check(albedoAfter and string.find(albedoAfter, '^/edmaptex/maptex_mata_%d+%.dds$') ~= nil, 'layer ' .. layer .. ' has the new albedo: ' .. tostring(albedoAfter))
        Check(normalAfter and string.find(normalAfter, '^/edmaptex/maptex_matn_%d+%.dds$') ~= nil, 'and the new normal map: ' .. tostring(normalAfter))
        Check(sizeAfter == 20, 'with the tile size asked for (' .. tostring(sizeAfter) .. ')')
        Check(import('/lua/editor/maptextures.lua').Managed(albedoAfter), 'the file counts as managed (a map save copies it into the map\'s folder)')
        local info2 = albedoAfter and ed_tex_dds_info(ed_vfs_to_disk(albedoAfter))
        Check(info2 and info2.width == 256, 'the engine reads the file the layer points to: 256 x 256')
        local maskAfter = ed_stratum_read(layer - 1, 0, 0, w - 1, h - 1)
        local differs, spread = 0, 0
        local lo, hi = 255, 0
        for i = 1, w * h do
            if maskAfter[i] ~= maskBefore[i] then differs = differs + 1 end
            if maskAfter[i] < lo then lo = maskAfter[i] end
            if maskAfter[i] > hi then hi = maskAfter[i] end
        end
        Check(differs > (w * h) / 4 and hi - lo > 100, 'the stratum\'s mask (' .. w .. ' x ' .. h .. ', the map\'s own grid) is painted from the Mask output: ' .. differs .. ' cells changed, values ' .. lo .. '..' .. hi)
        local label = History.Undo()
        Check(label and string.find(label, 'material', 1, true), 'Undo takes the material back as one step (' .. tostring(label) .. ')')
        local albedoUndone, sizeUndone = ed_stratum_layer(layer)
        local maskUndone = ed_stratum_read(layer - 1, 0, 0, w - 1, h - 1)
        local same = true
        for i = 1, w * h do
            if maskUndone[i] ~= maskBefore[i] then same = false break end
        end
        local wasEmpty = (albedoBefore or '') == ''
        Check((albedoUndone == albedoBefore or (wasEmpty and albedoUndone == Strata.CLEAR)) and (wasEmpty or sizeUndone == sizeBefore) and same, 'the layer texture, tile size and mask are what they were (' .. tostring(albedoUndone) .. ' / ' .. tostring(albedoBefore) .. ', ' .. tostring(sizeUndone) .. ' / ' .. tostring(sizeBefore) .. ', mask ' .. tostring(same) .. ')')
        History.Redo()
        Check(ed_stratum_layer(layer) == albedoAfter, 'Redo applies it again')
        History.Undo()

        -- saving the map: the baked files are copied into the map's folder and the layer points there (maptextures.PrepareSave), the engine loads them from there
        do
            local MT = import('/lua/editor/maptextures.lua')
            local dir, mount = M.TMP .. '/savetest', '/maps/selftest_material_save'
            M.New('start')
            M.SetPreviewSize(64)
            M.Apply({ stratum = layer, size = 64, tile = 10, mask = false })
            local stop3 = Now() + 30
            while M.Job and Now() < stop3 do M.Refresh() end
            local staged = ed_stratum_layer(layer)
            local restore = MT.PrepareSave(dir, mount)
            local saved, savedSize = ed_stratum_layer(layer)
            local base = string.gsub(staged or '', '^.*/', '')
            Check(saved == mount .. '/env/layers/' .. base, 'a map save points the layer into the map folder: ' .. tostring(saved))
            Check(ed_file_exists(dir .. '/env/layers/' .. base), 'and the baked file is in that folder')
            Check(savedSize == 10, 'with the tile size it had')
            local ni = ed_tex_dds_info(dir .. '/env/layers/' .. base)
            Check(ni and ni.width == 64, 'the copy is the 64 x 64 file the bake wrote')
            M.Close()
            Strata.Restore({ index = layer, albedo = albedoBefore, size = sizeBefore, normal = normalBefore, nsize = sizeBefore })
            if (albedoBefore or '') == '' then Strata.Clear(layer) end
            pcall(ed_file_delete, dir .. '/env/layers/' .. base)
        end

        -- the mask follows the map's mask grid whatever its size: at 256 x 256 the paint is made at that grid, and the old size comes back afterwards
        local w0, h0 = w, h
        local okSize = Strata.SetMaskSize(w0 * 2)
        local w2, h2 = ed_stratum_info()
        Check(okSize and w2 == w0 * 2 and h2 == h0 * 2, 'the mask grid can be changed (' .. w0 .. ' to ' .. tostring(w2) .. ')')
        if okSize then
            M.SetPreviewSize(64)
            M.New('start')
            for _, nd in M.Snap().nodes do if nd.type == 'Noise' then M.Connect(nd.id, 0, M.OutputNode(), 2) end end
            Check(M.Apply({ stratum = layer, size = 128, tile = 10, mask = true }), 'Apply at the new grid starts')
            local stop2 = Now() + 30
            while M.Job and Now() < stop2 do M.Refresh() end
            local big = ed_stratum_read(layer - 1, 0, 0, w2 - 1, h2 - 1)
            local lo2, hi2, painted = 255, 0, 0
            for i = 1, w2 * h2 do
                if big[i] < lo2 then lo2 = big[i] end
                if big[i] > hi2 then hi2 = big[i] end
                if big[i] > 0 then painted = painted + 1 end
            end
            Check(table.getn(big) == w2 * h2 and hi2 - lo2 > 100 and painted > (w2 * h2) / 2, 'the Mask output is painted over all ' .. w2 .. ' x ' .. h2 .. ' cells (values ' .. lo2 .. '..' .. hi2 .. ')')
            M.Close()
            Strata.SetMaskSize(w0)
            local w3 = ed_stratum_info()
            Check(w3 == w0, 'the mask grid is back at ' .. w0)
            -- the layer is put back by hand (the history was cleared by the size change)
            if wasEmpty then Strata.Clear(layer) else Strata.Restore({ index = layer, albedo = albedoBefore, size = sizeBefore, normal = normalBefore, nsize = sizeBefore }) end
            local clear = ed_stratum_read(layer - 1, 0, 0, w0 - 1, h0 - 1)
            local cleared = true
            for i = 1, w0 * h0 do
                if clear[i] ~= maskBefore[i] then cleared = false break end
            end
            if not cleared then
                -- put the original paint back: the cells that differ are rewritten
                ed_stratum_write(layer - 1, 0, 0, w0 - 1, h0 - 1, maskBefore)
            end
        end

        -- no Albedo linked: refused with a message, nothing changes
        local de = M.New('empty')
        local refused, reason = M.Apply({ stratum = layer, size = 64 })
        Check(not refused and M.StatusKind == 'warn', 'a graph with no Albedo is refused (' .. M.Status .. ')')
        M.Close()
    end)
    if not ok then
        failed = failed + 1
        table.insert(out, '  FAIL error: ' .. tostring(err))
    end
    pcall(function() M.Close() end)
    return Report()
end
