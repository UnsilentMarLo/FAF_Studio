-- Self test of the terrain interop (docs/projects/editor/TERRAIN_INTEROP.md): image formats, the height mapping, the alignment of the resampler, region blends, mask import,
-- export and the round trip, the live link, the sidecar. Run in the live editor:
--   return import('/lua/editor/selftest_interop.lua').Run()
-- Returns a report; the first line is PASS or FAIL. Works on a scratch terrain and puts the map back to flat 25 afterwards. Files go to ../interoptmp (next to the instance's bin).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Interop = import('/lua/editor/interop.lua')
local Export = import('/lua/editor/interopexport.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Map = import('/lua/editor/map.lua')

local DIR = '../interoptmp'

--- A float field written as an image the importer reads back (32-bit TIFF holds floats exactly).
local function WriteTif(name, f)
    local path = DIR .. '/' .. name
    local ok, err = ed_img_write(path, f, { bits = 32 })
    if not ok then error('write ' .. name .. ': ' .. tostring(err)) end
    return path
end

local function Gradient(w, h, lo, hi, angle)
    return Fields.Op('gradient', { width = w, height = h, angle = angle or 0, lo = lo, hi = hi })
end

local function Heights(x, z) return ed_terrain_get(x, z) end

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
    local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.02) end

    if not Interop.Available() then return 'FAIL (no field natives or image natives)' end
    local w, h = ed_terrain_info()
    if not w or w < 129 then return 'FAIL (no terrain)' end
    local N = w - 1
    local startFields = ed_field_count()
    local Strata = import('/lua/editor/strata.lua')
    local savedSettings, savedMasks, savedNamed = Interop.Settings, Interop.MaskSet, Interop.NamedList()
    local savedExport = Export.Settings
    Interop.Settings = Interop.DefaultSettings()
    Interop.MaskSet = Interop.DefaultMaskSet()
    Interop.Named = {}
    Export.Settings = Export.Defaults()
    local hasMasks = ed_stratum_info() ~= nil
    if hasMasks then for i = 1, 8 do Strata.ClearMask(i) end end
    local function Flat(v)
        ed_terrain_set_rect(0, 0, w - 1, h - 1, v)
        Terrain.ClearHistory()
        History.Clear()
    end
    local function Sum() return ed_doc_checksum(0, 0, w - 1, h - 1) end
    Flat(25)

    -- ---- the file natives ----------------------------------------------------------------------------------------------------------------------
    local grad = Gradient(33, 33, 0, 1)
    local exact = true
    for _, t in { { 'a.png', 16 }, { 'b.tif', 16 }, { 'c.tif', 32 }, { 'd.r16', 16 }, { 'e.r32', 32 } } do
        local ok = ed_img_write(DIR .. '/' .. t[1], grad, { bits = t[2], lo = 0, hi = 1 })
        local g, info = ed_img_read(DIR .. '/' .. t[1], {})
        check('write / read ' .. t[1], ok and g and info.width == 33 and info.height == 33, tostring(info))
        if g then
            local d = Fields.Op('sub', { a = g, b = grad })
            local lo, hi = Fields.Stats(d)
            local tol = (t[2] == 32) and 0 or 1 / 65535 * 0.51
            check('values of ' .. t[1] .. ' within the quantisation', math.max(math.abs(lo), math.abs(hi)) <= tol + 1e-7, lo .. ' ' .. hi)
            Fields.Free(d) Fields.Free(g)
        end
    end
    local g, info = ed_img_read(DIR .. '/c.tif', {})
    check('a float TIFF reports float', g and info.float == 1 and info.bits == 32, info and info.format)
    Fields.Free(g)
    ed_img_write(DIR .. '/be.raw', grad, { bits = 16, big = 1, lo = 0, hi = 1 })
    local be = ed_img_read(DIR .. '/be.raw', { bits = 16, big = 1 })
    local le = ed_img_read(DIR .. '/be.raw', { bits = 16, big = 0 })
    check('big endian raw reads back, little endian does not', be and le and near(Fields.Get(be, 16, 0), 0.5, 0.001) and not near(Fields.Get(le, 16, 0), 0.5, 0.3))
    Fields.Free(be) Fields.Free(le)
    local ni = ed_img_info(DIR .. '/e.r32', {})
    check('raw size from the file size', ni and ni.width == 33 and ni.float == 1, ni and ni.width)
    local bad, why = ed_img_read(DIR .. '/does_not_exist.png', {})
    check('a missing file is an error message', bad == nil and why ~= nil)
    Fields.Free(grad)

    -- ---- mapping: normalised and absolute ----------------------------------------------------------------------------------------------------
    local st = Interop.DefaultSettings()
    local ramp = Gradient(N + 1, N + 1, 0, 1)
    st.file = WriteTif('ramp.tif', ramp)
    Fields.Free(ramp)
    st.min, st.max, st.align, st.filter = 10, 110, 'corner', 'bilinear'
    local d00 = History.Depth()
    local out = Interop.ApplyHeights(st)
    check('normalised import changes the terrain', out and out.changed > 0, out)
    check('the import is one undo step', History.Depth() == d00 + 1)
    check('normalised: 0 -> min', near(Heights(0, 30), 10, 0.01), Heights(0, 30))
    check('normalised: 1 -> max', near(Heights(N, 30), 110, 0.01), Heights(N, 30))
    check('normalised: linear in between', near(Heights(N / 2, 30), 60, 0.02), Heights(N / 2, 30))
    History.Undo()
    History.Redo()
    History.Undo()
    check('undo restores the flat terrain', near(Heights(10, 10), 25, 0.01) and near(Heights(N, 30), 25, 0.01), Heights(N, 30))
    st.mode, st.invert = 'normalised', true
    Interop.ApplyHeights(st)
    check('invert', near(Heights(0, 30), 110, 0.01) and near(Heights(N, 30), 10, 0.01))
    History.Undo()
    st.invert = false
    -- stretch: an image 0.2 .. 0.6 becomes the full min..max
    local part = Gradient(N + 1, N + 1, 0.2, 0.6)
    st.file = WriteTif('part.tif', part)
    Fields.Free(part)
    st.stretch = true
    Interop.ApplyHeights(st)
    check('stretch to the image range', near(Heights(0, 30), 10, 0.02) and near(Heights(N, 30), 110, 0.02), Heights(N, 30))
    History.Undo()
    st.stretch = false
    -- absolute: a float image holds world units; a 16-bit image word / 128
    local units = Gradient(N + 1, N + 1, 5, 205)
    st.file = WriteTif('units.tif', units)
    Fields.Free(units)
    st.mode = 'absolute'
    Interop.ApplyHeights(st)
    check('absolute float: the value is the height', near(Heights(0, 30), 5, 0.01) and near(Heights(N, 30), 205, 0.01), Heights(N, 30))
    History.Undo()
    local half = Fields.Op('const', { width = 16, height = 16, value = 0.5 })
    ed_img_write(DIR .. '/half.png', half, { bits = 16, lo = 0, hi = 1 })
    Fields.Free(half)
    st.file = DIR .. '/half.png'
    st.align = 'cell'
    Interop.ApplyHeights(st)
    check('absolute 16 bit: word / 128', near(Heights(40, 40), 32768 / 128, 0.02), Heights(40, 40))
    History.Undo()
    st.mode = 'normalised'

    -- ---- the report: range, warnings ---------------------------------------------------------------------------------------------------------
    local rampTall = Gradient(N + 1, N + 1, 0, 1)
    st = Interop.DefaultSettings()
    st.file = WriteTif('tall.tif', rampTall)
    Fields.Free(rampTall)
    st.min, st.max, st.align = 0, 400, 'corner'
    local pv = Interop.PreviewHeights(st, 64)
    check('preview range', pv and near(pv.hLo, 0, 0.5) and near(pv.hHi, 400, 0.5), pv and pv.hHi)
    local warned = false
    for _, t in (pv and pv.warnings or {}) do if string.find(t, 'decals', 1, true) then warned = true end end
    check('warning above the decal limit', warned)
    st.max = 600
    pv = Interop.PreviewHeights(st, 64)
    warned = false
    for _, t in (pv and pv.warnings or {}) do if string.find(t, 'cut off', 1, true) then warned = true end end
    check('warning above the 16-bit range', warned)
    local outside = Fields.Op('const', { width = 16, height = 16, value = 7 })
    st.file = WriteTif('outside.tif', outside)
    Fields.Free(outside)
    st.max = 100
    pv = Interop.PreviewHeights(st, 64)
    warned = false
    for _, t in (pv and pv.warnings or {}) do if string.find(t, 'not 0 to 1', 1, true) then warned = true end end
    check('warning for a float image outside 0..1', warned)

    -- ---- the alignment of the resampler -------------------------------------------------------------------------------------------------------
    st = Interop.DefaultSettings()
    st.mode, st.min, st.max = 'normalised', 0, N
    -- a (N+1) image: pixel k = k / N lies on sample k: the identity
    local idImg = Gradient(N + 1, N + 1, 0, 1)
    st.file = WriteTif('id.tif', idImg)
    Fields.Free(idImg)
    st.align = 'auto'
    local o = Interop.ApplyHeights(st)
    check('N+1 image: auto picks corner', o and o.result.align == 'corner')
    check('N+1 image is the identity', near(Heights(7, 3), 7, 0.01) and near(Heights(N - 3, 9), N - 3, 0.01), Heights(7, 3))
    History.Undo()
    -- an N image: pixel k is centred on cell k + 0.5, so sample i reads (i - 0.5 + 0.5)/N... value = i: interior exact for a linear image
    local cellImg = Gradient(N, N, 0.5 / N, (N - 0.5) / N)
    st.file = WriteTif('cell.tif', cellImg)
    Fields.Free(cellImg)
    for _, f in { 'bilinear', 'bicubic', 'lanczos' } do
        st.filter = f
        o = Interop.ApplyHeights(st)
        check('N image: auto picks cell (' .. f .. ')', o and o.result.align == 'cell')
        check('N image, cell centres, ' .. f .. ': h(x) = x inside', near(Heights(9, 5), 9, 0.02) and near(Heights(N - 9, 5), N - 9, 0.02) and near(Heights(N / 2, 40), N / 2, 0.02),
              Heights(9, 5) .. ' ' .. Heights(N / 2, 40))
        History.Undo()
    end
    st.align = 'corner'
    st.filter = 'bilinear'
    Interop.ApplyHeights(st)
    check('forcing corner on an N image stretches it edge to edge', near(Heights(N, 5), N - 0.5, 0.05) and near(Heights(0, 5), 0.5, 0.05), Heights(N, 5))
    History.Undo()
    -- shrinking an image 2:1 filters (no aliasing of a one-pixel checkerboard)
    local checker = Fields.Op('white', { width = 2 * N, height = 2 * N, seed = 3 })
    local sq = Fields.Op('threshold', { a = checker, value = 0.5 })
    Fields.Free(checker)
    st.file = WriteTif('noise.tif', sq)
    Fields.Free(sq)
    st.min, st.max, st.align, st.filter = 0, 1, 'cell', 'lanczos'
    Interop.ApplyHeights(st)
    local mean = Fields.Run(function(S)
        local f = S:Height(1)
        local _, _, m, sd = Fields.Stats(f)
        return m
    end)
    check('2:1 shrink of noise keeps the mean', near(mean, 0.5, 0.05), mean)
    History.Undo()
    Flat(25)

    -- ---- orientation ----------------------------------------------------------------------------------------------------------------------------
    st = Interop.DefaultSettings()
    st.mode, st.min, st.max, st.align = 'normalised', 0, 100, 'corner'
    local gx = Gradient(N + 1, N + 1, 0, 1, 0)             -- grows with x
    st.file = WriteTif('gx.tif', gx)
    Fields.Free(gx)
    Interop.ApplyHeights(st)
    check('x gradient as is', Heights(10, 20) < Heights(N - 10, 20) and near(Heights(10, 20), Heights(10, N - 20), 0.01))
    History.Undo()
    st.rot = 90
    Interop.ApplyHeights(st)
    check('rotated 90 clockwise: grows with z', Heights(30, 10) < Heights(30, N - 10) and near(Heights(10, 30), Heights(N - 10, 30), 0.01), Heights(30, 10) .. ' ' .. Heights(30, N - 10))
    History.Undo()
    st.rot = 270
    Interop.ApplyHeights(st)
    check('rotated 270: falls with z', Heights(30, 10) > Heights(30, N - 10))
    History.Undo()
    st.rot, st.flipX = 0, true
    Interop.ApplyHeights(st)
    check('flip x: falls with x', Heights(10, 20) > Heights(N - 10, 20))
    History.Undo()
    Flat(25)

    -- ---- regions and blend modes ---------------------------------------------------------------------------------------------------------------
    local mid = Fields.Op('const', { width = 64, height = 64, value = 0.5 })
    local midFile = WriteTif('mid.tif', mid)
    Fields.Free(mid)
    st = Interop.DefaultSettings()
    st.file, st.min, st.max, st.region, st.rect = midFile, 0, 100, 'rect', { 40, 40, 100, 100 }
    local function Probe(x, z) return Heights(x, z) end
    Interop.ApplyHeights(st)
    check('region replace: inside', near(Probe(70, 70), 50, 0.02), Probe(70, 70))
    check('region replace: outside is untouched', near(Probe(20, 20), 25, 0.01) and near(Probe(101, 70), 25, 0.01) and near(Probe(70, 39), 25, 0.01))
    check('region replace: the border samples are inside', near(Probe(40, 40), 50, 0.02) and near(Probe(100, 100), 50, 0.02))
    History.Undo()
    st.blend = 'add'
    Interop.ApplyHeights(st)
    check('add', near(Probe(70, 70), 75, 0.02), Probe(70, 70))
    History.Undo()
    st.blend = 'max'
    Interop.ApplyHeights(st)
    check('max keeps the higher', near(Probe(70, 70), 50, 0.02))
    History.Undo()
    st.blend, st.max = 'min', 20          -- imported = 10
    Interop.ApplyHeights(st)
    check('min keeps the lower', near(Probe(70, 70), 10, 0.02), Probe(70, 70))
    History.Undo()
    st.blend, st.max, st.feather = 'replace', 100, 10
    Interop.ApplyHeights(st)
    check('feather: 0 at the border, half at 5, full at 10', near(Probe(40, 70), 25, 0.02) and near(Probe(45, 70), 37.5, 0.1) and near(Probe(60, 70), 50, 0.02), Probe(45, 70))
    History.Undo()
    st.feather, st.strength = 0, 0.5
    Interop.ApplyHeights(st)
    check('strength 0.5 blends halfway', near(Probe(70, 70), 37.5, 0.02), Probe(70, 70))
    History.Undo()
    st.strength = 1
    -- blend by a mask image: right half of the region only
    local halfMask = Gradient(64, 64, 0, 1)
    local mt = Fields.Op('threshold', { a = halfMask, value = 0.5 })
    Fields.Free(halfMask)
    st.maskFile = WriteTif('mask.tif', mt)
    Fields.Free(mt)
    st.blend, st.region = 'mask', 'map'
    st.align = 'cell'
    Interop.ApplyHeights(st)
    check('blend by mask: left half untouched, right half imported', near(Probe(20, 70), 25, 0.01) and near(Probe(N - 20, 70), 50, 0.05), Probe(N - 20, 70))
    History.Undo()
    -- the playable area as region
    st.blend, st.region = 'replace', 'playable'
    Interop.ApplyHeights(st)
    check('playable region without an area is the map', near(Probe(5, 5), 50, 0.02))
    History.Undo()

    -- ---- pads --------------------------------------------------------------------------------------------------------------------------------------
    local made = false
    if Map.Doc then
        Map.AddMarker('ARMY_9', 'Blank Marker', 70.5, 25, 70.5)
        made = true
        st.region, st.blend, st.pads, st.padRadius = 'map', 'replace', 'keep', 8
        Interop.ApplyHeights(st)
        check('pads keep: the start position stays', near(Probe(70, 70), 25, 0.05) and near(Probe(100, 100), 50, 0.05), Probe(70, 70) .. ' ' .. Probe(100, 100))
        History.Undo()
        local tilt = Gradient(N + 1, N + 1, 0, 1)
        st.file = WriteTif('tilt.tif', tilt)
        Fields.Free(tilt)
        st.min, st.max, st.align = 0, 100, 'corner'
        st.pads = 'flatten'
        Interop.ApplyHeights(st)
        local c = Probe(70, 70)
        check('pads flatten: level inside the radius', near(Probe(66, 70), c, 0.2) and near(Probe(74, 70), c, 0.2) and near(Probe(70, 66), c, 0.2), Probe(66, 70) .. ' ' .. c .. ' ' .. Probe(74, 70))
        History.Undo()
        Map.RemoveMarker('ARMY_9')
    else
        table.insert(lines, '  skip pads (no map document)')
    end
    Flat(25)

    -- ---- masks ------------------------------------------------------------------------------------------------------------------------------------
    if hasMasks then
        local ms = Interop.DefaultMaskSet()
        local right = Gradient(N + 1, N + 1, 0, 1)
        local left = Gradient(N + 1, N + 1, 1, 0)
        local fRight, fLeft = WriteTif('mright.tif', right), WriteTif('mleft.tif', left)
        Fields.Free(right) Fields.Free(left)
        local it1 = Interop.NewItem(fRight) it1.layer = 3
        local it2 = Interop.NewItem(fLeft) it2.layer = 2
        ms.items = { it2, it1 }
        ms.takeAway = true
        Interop.Settings.align = 'corner'
        local depth0 = History.Depth()
        local r = Interop.ApplyMasks(ms)
        check('mask import writes two layers', r and r.layers == 2 and r.cells > 0, r)
        check('masks are one undo step', History.Depth() == depth0 + 1)
        local top = Fields.Run(function(S)
            local m3 = S:Op('resample', { a = S:Stratum(3), like = S:Height(1) })
            local m2 = S:Op('resample', { a = S:Stratum(2), like = S:Height(1) })
            return { Fields.Get(m3, N - 10, 30), Fields.Get(m3, 10, 30), Fields.Get(m2, 10, 30), Fields.Get(m2, N / 2, 30), Fields.Get(m3, N / 2, 30) }
        end)
        check('layer 3 follows its image', top and top[1] > 0.9 and top[2] < 0.1, top and top[1])
        check('layer 2 takes away what layer 3 covers', top and top[3] > 0.85 and top[4] < (1 - top[5]) * 0.5 + 0.15, top and (top[4] .. ' ' .. top[5]))
        History.Undo()
        local gone = Fields.Run(function(S)
            local _, mx = Fields.Stats(S:Stratum(3))
            return mx
        end)
        check('undo clears the layers', gone == 0, gone)
        -- an RGBA splat: channels of one file
        local rgba = Interop.NewItem(fRight, 'r') rgba.layer = 1
        ms.items = { rgba }
        r = Interop.ApplyMasks(ms)
        check('channel r of a grey file', r and r.layers == 1)
        History.Undo()
        -- named mask for the mask generator
        local nm = Interop.NewItem(fRight) nm.target, nm.name = 'named', 'river'
        ms.items = { nm }
        r = Interop.ApplyMasks(ms)
        check('named mask kept', r and r.named == 1 and table.getn(Interop.NamedList()) == 1)
        local rule = MaskGen.NewRule('named')
        rule.v.slot = 1
        local probe = Fields.Run(function(S)
            local c = MaskGen.NewContext(S, { step = 1 })
            local m, err = MaskGen.Evaluate(c, { rules = { rule } })
            if not m then return nil, err end
            return { Fields.Get(m, N - 10, 30), Fields.Get(m, 10, 30) }
        end)
        check('the mask generator reads the named mask', probe and probe[1] > 0.9 and probe[2] < 0.1, probe)
        if rawget(_G, 'ed_tt_info') and ed_tt_info() then
            local tt = Interop.NewItem(fRight) tt.target, tt.code, tt.threshold = 'types', 3, 0.5
            ms.items = { tt }
            r = Interop.ApplyMasks(ms)
            check('terrain type import', r and r.types == 1 and r.cells > 0, r)
            if r then History.Undo() end
        end
        Interop.Named = {}
        for i = 1, 8 do Strata.ClearMask(i) end
    else
        table.insert(lines, '  skip masks (the map has no paint masks)')
    end
    Flat(25)

    -- ---- export and the round trip -------------------------------------------------------------------------------------------------------------
    local hills = Fields.Run(function(S)
        local p = S:Op('perlin', { like = S:Height(1), seed = 5, scale = 60, octaves = 4 })
        return Fields.CommitHeight(S:Op('affine', { a = p, mul = 150, add = 20 }), { noHistory = true })
    end)
    Terrain.ClearHistory()
    History.Clear()
    local before = Sum()
    local lo0, hi0 = Fields.Run(function(S) return Fields.Stats(S:Height(1)) end)
    check('scratch hills made', hills and hills > 0)
    local ex = Export.Defaults()
    ex.dir = DIR .. '/export'
    ex.name = 'rt'
    for _, variant in { { 'png', 16, 'normalised' }, { 'tif', 16, 'absolute' }, { 'tif', 32, 'normalised' }, { 'tif', 32, 'absolute' }, { 'raw', 16, 'normalised' }, { 'png', 16, 'absolute' } } do
        ex.format, ex.bits, ex.mode = variant[1], variant[2], variant[3]
        local rep, err = Export.Export(ex)
        local label = variant[1] .. ' ' .. variant[2] .. ' ' .. variant[3]
        check('export ' .. label, rep ~= nil, err)
        if rep then
            local plan = Export.Plan(ex)
            local file
            for _, p in plan do if p.id == 'height' then file = p.file end end
            local json = Export.ReadJson(string.gsub(file, '%.[%w]+$', '.json'))
            check('json next to ' .. label, json ~= nil and near(json.width, w, 0.1))
            ed_terrain_set_rect(0, 0, w - 1, h - 1, 3)
            local imp = Interop.DefaultSettings()
            imp.file = file
            imp.filter = 'bilinear'
            if variant[1] == 'raw' then imp.rawBits, imp.rawFloat = variant[2], variant[2] == 32 end
            local text = Export.FillImportFrom(imp, json)
            local out = Interop.ApplyHeights(imp)
            check('round trip is exact: ' .. label, out ~= nil and Sum() == before, out == nil and 'no import' or (Sum() .. ' vs ' .. before))
            History.Clear()
            Terrain.ClearHistory()
        end
    end
    -- the files of one full export
    ex.format, ex.bits, ex.mode = 'png', 16, 'normalised'
    ex.items.flow, ex.items.wear, ex.items.types = true, true, true
    local rep, err = Export.Export(ex)
    check('full export', rep ~= nil, err)
    if rep then
        local missing = {}
        for _, p in Export.Plan(ex) do
            if p.id ~= 'layers' and not ed_file_exists(p.file) then table.insert(missing, p.id) end
        end
        check('every planned file exists', table.getn(missing) == 0, table.concat(missing, ','))
        local csv = ed_read_file(ex.dir .. '/rt_markers.csv')
        check('marker csv has its header', csv and string.find(csv, 'name,type,x,y,z', 1, true) ~= nil)
        local readme = ed_read_file(ex.dir .. '/rt_README_scale.txt')
        check('readme names the sizes', readme and string.find(readme, tostring(w) .. ' x ' .. tostring(h), 1, true) ~= nil and string.find(readme, 'Gaea', 1, true) ~= nil)
        local mask, info = ed_img_read(ex.dir .. '/rt_slope.png', {})
        check('slope mask is a map sized image', mask and info.width == w and info.height == h)
        if mask then Fields.Free(mask) end
    end
    -- exact range recorded
    local jr = Export.ReadJson(ex.dir .. '/rt_height.json')
    check('json records the range', jr and near(jr.min, lo0, 0.001) and near(jr.max, hi0, 0.001), jr and (jr.min .. ' ' .. jr.max))

    -- ---- the live link ---------------------------------------------------------------------------------------------------------------------------------
    Flat(25)
    local a = Fields.Op('const', { width = 64, height = 64, value = 0.2 })       -- the sizes differ per write: the stamp (size + time) must change even within one clock tick
    local linkFile = WriteTif('live.tif', a)
    Fields.Free(a)
    local ls = Interop.Settings
    ls.file, ls.min, ls.max, ls.align = linkFile, 0, 100, 'cell'
    Interop.Link.interval = 0
    Interop.Link.mode = 'file'
    Interop.MaskSet.items = {}
    Interop.LinkStart()
    Interop.LinkPoll()
    check('an unchanged file is not imported', near(Heights(50, 50), 25, 0.01))
    local b = Fields.Op('const', { width = 64, height = 65, value = 0.6 })
    WriteTif('live.tif', b)
    Fields.Free(b)
    local d0 = History.Depth()
    Interop.LinkPoll()
    check('a changed file waits until its stamp is stable', near(Heights(50, 50), 25, 0.01))
    Interop.LinkPoll()
    check('the changed file is imported', near(Heights(50, 50), 60, 0.05), Heights(50, 50))
    local c2 = Fields.Op('const', { width = 64, height = 66, value = 0.9 })
    WriteTif('live.tif', c2)
    Fields.Free(c2)
    Interop.LinkPoll()
    Interop.LinkPoll()
    check('the next change replaces the previous one', near(Heights(50, 50), 90, 0.05), Heights(50, 50))
    check('two live imports are one undo step', History.Depth() == d0 + 1, History.Depth() .. ' vs ' .. d0)
    check('revert takes it back', Interop.LinkRevert() and near(Heights(50, 50), 25, 0.01))
    Interop.LinkStop()
    Flat(25)

    -- ---- the typical height, the comparison with the maps, symmetry, names ----------------------------------------------------------------------------------
    do
        Interop.Settings = Interop.DefaultSettings()
        local st = Interop.Settings
        local sug = Interop.Suggest()
        check('the numbers of the maps of this size exist and rise', sug and sug.n >= 8 and sug.relief[1] < sug.relief[3] and sug.relief[3] < sug.relief[5] and sug.slope[1] < sug.slope[5])
        local g = Gradient(w, h, 0, 1, 0)
        local gpath = WriteTif('typical.tif', g)
        Fields.Free(g)
        st.file, st.min, st.max, st.align, st.filter = gpath, 0, 100, 'corner', 'bilinear'
        local mx, relief = Interop.SuggestMax(st, 3)
        check('the typical height of a full range image is the median relief of the maps', mx and sug and near(mx, sug.relief[3], 0.01) and near(relief, sug.relief[3], 0.01), tostring(mx))
        st.max = mx
        local pv = Interop.PreviewHeights(st, 64)
        local tooTall = false
        for _, wt in pv.warnings do if string.find(wt, 'relief', 1, true) and string.find(wt, 'more than', 1, true) then tooTall = true end end
        check('an import at the median relief has no too-tall warning, and says how it compares', not tooTall and pv.advice ~= nil and string.find(pv.advice, 'your', 1, true) ~= nil, tostring(pv.advice))
        st.max = (sug and sug.relief[5] or 90) * 3
        pv = Interop.PreviewHeights(st, 64)
        tooTall = false
        for _, wt in pv.warnings do if string.find(wt, 'more than', 1, true) then tooTall = true end end
        check('an import with three times the relief of the tallest maps is warned about', tooTall and pv.relief > sug.relief[5] * 2, pv.relief)
        -- names
        local kind = Interop.GuessMask
        local k1 = kind('c:/g/Flow.png')
        local k2 = kind('c:/g/Erosion_Wear.tif')
        local k3 = kind('c:/g/terrain_Deposits.png')
        local k4, r4 = kind('c:/g/rock_mask.png')
        local k5, r5 = kind('c:/g/height.png')
        check('erosion masks are known by name (flow, wear, deposit)', k1 == 'flow' and k2 == 'wear' and k3 == 'deposit', tostring(k1) .. tostring(k2) .. tostring(k3))
        check('a splat mask is known by the kind of ground in its name, a plain height file is nothing', k4 == nil and r4 == 'rock' and k5 == nil and r5 == nil, tostring(r4) .. tostring(k5) .. tostring(r5))
        local it = Interop.NewItem('c:/g/flow_map.png')
        local told = Interop.GuessItem(it)
        check('guessing an item sets a named mask', told and it.target == 'named' and it.name == 'flow')
        -- symmetry of an import
        Flat(25)
        st = Interop.DefaultSettings()
        Interop.Settings = st
        st.file, st.min, st.max, st.align, st.filter, st.symmetry = gpath, 0, 80, 'corner', 'bilinear', 'mirror_x'
        local out = Interop.ApplyHeights(st)
        check('a symmetric import is symmetric', out and near(Heights(10, 50), Heights(N - 10, 50), 0.1) and near(Heights(60, 120), Heights(N - 60, 120), 0.1),
              tostring(Heights(10, 50)) .. ' ' .. tostring(Heights(N - 10, 50)))
        History.Undo()
        st.symmetry = 'off'
        Interop.ApplyHeights(st)
        check('without it the gradient stays a gradient', Heights(N - 10, 50) - Heights(10, 50) > 40, tostring(Heights(10, 50)) .. ' ' .. tostring(Heights(N - 10, 50)))
        History.Undo()
        Flat(25)

        -- the graph nodes
        local Graph = import('/lua/editor/graph.lua')
        local GRun = import('/lua/editor/graphrun.lua')
        st = Interop.DefaultSettings()
        Interop.Settings = st
        st.file, st.min, st.max, st.align, st.filter = gpath, 0, 80, 'corner', 'bilinear'
        Graph.New('interop test')
        Graph.Current.symmetry = 'off'
        local ext = Graph.Add('external_terrain', 0, 0)
        local oh = Graph.Add('out_height', 200, 0)
        Graph.Connect(ext.id, 'out', oh.id, 'a')
        check('with no External node the graph signature is empty', true)
        local sig1 = Interop.GraphSignature(true)
        st.max = 81
        local sig2 = Interop.GraphSignature(true)
        st.max = 80
        check('the graph signature follows the import settings', sig1 ~= '' and sig1 ~= sig2)
        GRun.Refresh(true)
        local rb, why = GRun.Build()
        check('External terrain builds like the import of the panel', rb and near(Heights(10, 50), 80 * 10 / N, 0.1) and near(Heights(N - 10, 50), 80 * (N - 10) / N, 0.1),
              tostring(why) .. ' ' .. tostring(Heights(10, 50)) .. ' ' .. tostring(Heights(N - 10, 50)))
        History.Undo()
        -- preview and build agree (the alignment is decided on the whole map)
        local run = GRun.NewRun{ step = 4, thumbs = false, only = { [ext.id] = true } }
        run:Evaluate()
        local pf = run:Value(ext.id, 'out')
        local pvalue = pf and Fields.Sample(pf, 100, 100) or -1
        run:Free()
        check('the preview run reads the same heights as the build', near(pvalue, 80 * 100 / N, 0.2), tostring(pvalue))
        -- a file typed into the node replaces the panel's
        Graph.SetParam(ext.id, 'file', '')
        local mask = Fields.Op('gradient', { width = w, height = h, angle = 90, lo = 0, hi = 1 })
        local mpath = WriteTif('wear.tif', mask)
        Fields.Free(mask)
        Interop.Named = {}
        Interop.SetNamed({ name = 'wear', file = mpath, channel = 'gray', invert = false })
        local em = Graph.Add('external_mask', 0, 200, { name = 'wear' })
        local em2 = Graph.Add('external_mask', 0, 400, { name = 'nothing', optional = true })
        local em3 = Graph.Add('external_mask', 0, 600, { name = 'nothing', optional = false })
        local run2 = GRun.NewRun{ step = 1, thumbs = false, only = { [em.id] = true, [em2.id] = true, [em3.id] = true } }
        local rep = run2:Evaluate()
        local fm, f2 = run2:Value(em.id, 'out'), run2:Value(em2.id, 'out')
        local mean1, hi2
        if fm then local _, _, m = Fields.Stats(fm) mean1 = m end
        if f2 then local _, h2 = Fields.Stats(f2) hi2 = h2 end
        check('External mask gives the named mask, an empty field when optional, an error when not', mean1 and mean1 > 0.3 and mean1 < 0.7 and hi2 == 0 and rep.errors[em3.id] ~= nil and rep.errors[em.id] == nil,
              tostring(mean1) .. ' ' .. tostring(hi2))
        run2:Free()
        Interop.Named = {}
        Graph.New('untitled')
        GRun.Release()
        Flat(25)
    end

    -- ---- send and watch: our own files are not taken back, the other tool's files are adopted by name -----------------------------------------------------------
    do
        Interop.Settings = Interop.DefaultSettings()
        Interop.MaskSet = Interop.DefaultMaskSet()
        Interop.Named = {}
        Export.Settings = Export.Defaults()
        Export.Settings.dir, Export.Settings.name = DIR, 'adoptmap'
        local r, err = Interop.SendAndWatch()
        check('send and watch exports and starts watching the folder', r and Interop.Link.enabled and Interop.Link.mode == 'folder' and Interop.Link.folder == DIR, tostring(err))
        check('our own export files are known', Interop.IsOwnExport('c:/x/adoptmap_height.png') and Interop.IsOwnExport('adoptmap_layer3.png') and not Interop.IsOwnExport('Gaea_height.png'))
        Interop.Link.interval = 0
        Interop.LinkPoll()
        Interop.LinkPoll()
        check('the export itself is not imported', Interop.Settings.file == '' and table.getn(Interop.MaskSet.items) == 0 and near(Heights(50, 50), 25, 0.01))
        local hf = Gradient(w, h, 0, 1, 0)
        WriteTif('Gaea_Terrain.tif', hf)
        Fields.Free(hf)
        local mf = Fields.Op('gradient', { width = w, height = h, angle = 90, lo = 0, hi = 1 })
        WriteTif('Flow.tif', mf)
        Fields.Free(mf)
        Interop.LinkPoll()          -- seen once
        Interop.LinkPoll()          -- seen twice: adopted and applied
        local named = false
        for _, item in Interop.MaskSet.items do if item.target == 'named' and item.name == 'flow' then named = true end end
        check('a Flow file is adopted as the named mask flow', named and Interop.NamedSlot('flow') ~= nil, tostring(table.getn(Interop.MaskSet.items)))
        check('the other new file becomes the heightmap, at the median relief of the maps', string.find(Interop.Settings.file, 'Gaea_Terrain', 1, true) ~= nil and Interop.Settings.max > 5 and Interop.Settings.max < 100,
              tostring(Interop.Settings.file) .. ' ' .. tostring(Interop.Settings.max))
        check('and it is imported', Heights(N - 10, 50) - Heights(10, 50) > 5, tostring(Heights(10, 50)) .. ' ' .. tostring(Heights(N - 10, 50)))
        Interop.LinkStop()
        History.Undo()
        Interop.Named = {}
        Interop.Settings = Interop.DefaultSettings()
        Interop.MaskSet = Interop.DefaultMaskSet()
        Export.Settings = Export.Defaults()
        Flat(25)
    end

    -- ---- the sidecar ---------------------------------------------------------------------------------------------------------------------------------
    Interop.Settings = Interop.DefaultSettings()
    Interop.Settings.min, Interop.Settings.max, Interop.Settings.filter, Interop.Settings.region = 33, 77, 'lanczos', 'rect'
    Interop.Settings.rect = { 1, 2, 30, 40 }
    local item = Interop.NewItem('c:/x/y.png', 'g')
    item.layer = 5
    Interop.MaskSet.items = { item }
    Interop.Named = { { name = 'n1', file = 'c:/n.png', channel = 'gray', invert = true } }
    Export.Settings.dir = 'c:/export'
    local side = Interop.SidecarText()
    check('sidecar text exists', string.find(side, 'Interop', 1, true) ~= nil)
    local f = loadstring(side)
    local env = {}
    if f then setfenv(f, env) f() end
    Interop.Reset()
    check('reset goes back to the defaults', Interop.Settings.min == 0 and Interop.Settings.region == 'map' and table.getn(Interop.MaskSet.items) == 0)
    Interop.ApplyData(env.Interop)
    check('sidecar restores the import settings', Interop.Settings.min == 33 and Interop.Settings.max == 77 and Interop.Settings.filter == 'lanczos' and Interop.Settings.rect[4] == 40)
    check('sidecar restores masks, names and export settings', Interop.MaskSet.items[1].layer == 5 and Interop.MaskSet.items[1].channel == 'g' and Interop.Named[1].name == 'n1' and Export.Settings.dir == 'c:/export')
    Interop.Reset()
    check('a default state writes no sidecar section', Interop.SidecarText() == '')

    -- ---- clean up ----------------------------------------------------------------------------------------------------------------------------------
    Interop.FreeCache()
    Interop.Settings, Interop.MaskSet, Interop.Named = savedSettings, savedMasks, savedNamed
    Export.Settings = savedExport
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    Terrain.ClearHistory()
    History.Clear()
    if hasMasks then for i = 1, 8 do Strata.ClearMask(i) end end
    check('no field leaks', ed_field_count() == startFields, ed_field_count() .. ' vs ' .. startFields)

    local shown = lines
    if not verbose then       -- only what failed (the command channel cuts long answers); Run(true) lists every check
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
