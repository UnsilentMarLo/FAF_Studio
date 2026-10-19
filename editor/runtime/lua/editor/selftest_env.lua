-- Self test of the environment model, the libraries and the sky / water natives (EdEnv.cpp, EdScmapEnv.cpp, environment.lua, envlib.lua). Run in the live editor:
--   return import('/lua/editor/selftest_env.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check). The environment of the open map is put back at the end.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Env = import('/lua/editor/environment.lua')
local Lib = import('/lua/editor/envlib.lua')
local World = import('/lua/editor/world.lua')
local History = import('/lua/editor/history.lua')
local Strata = import('/lua/editor/strata.lua')
local Fields = import('/lua/editor/fields.lua')
local Panels = import('/lua/editor/gui/panels.lua')

local ALL = { 'light', 'water', 'waves', 'sky', 'skyshape', 'cubes', 'imager', 'levels' }

local function SameParts(a, b)
    for k, v in a.num do
        if math.abs((b.num[k] or 1e9) - v) > 1e-4 then return false, 'number ' .. k .. ' ' .. tostring(v) .. ' / ' .. tostring(b.num[k]) end
    end
    for k, v in a.texts do
        if (b.texts[k] or '') ~= v then return false, 'text ' .. k end
    end
    for _, list in { 'billboards', 'lookups' } do
        local x, y = a[list], b[list]
        if (x == nil) ~= (y == nil) then return false, list .. ' presence' end
        if x then
            if table.getn(x) ~= table.getn(y) then return false, list .. ' length ' .. table.getn(x) .. ' / ' .. table.getn(y) end
            for i = 1, table.getn(x) do
                if x[i] ~= y[i] and not (type(x[i]) == 'number' and math.abs(x[i] - y[i]) < 1e-3) then return false, list .. ' entry ' .. i end
            end
        end
    end
    return true
end

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
    local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.001) end

    check('natives present', rawget(_G, 'ed_env_get') ~= nil and rawget(_G, 'ed_scmap_env') ~= nil)
    if not Env.Available() then return 'FAIL (no map or no environment natives)' end
    local original = Env.Capture(ALL)
    History.Clear()

    -- ---- numbers, texts, lists with undo ------------------------------------------------------------------------------------------------------
    local v0 = Env.Value('horizon_r')
    local depth = History.Version
    Env.SetNumber('horizon_r', 0.33)
    check('a sky number is set', near(Env.Value('horizon_r'), 0.33))
    check('the engine has it', near(ed_env_get().horizon_r, 0.33))
    History.Undo()
    check('undo of a number', near(Env.Value('horizon_r'), v0))
    History.Redo()
    check('redo of a number', near(Env.Value('horizon_r'), 0.33))
    History.Undo()
    Env.SetNumber('sun_r', 1.7)
    check('a lighting number goes through the world natives', near(World.Value('sun_r'), 1.7) and near(Env.Value('sun_r'), 1.7))
    History.Undo()

    local steps = History.Version
    Env.SetNumber('cirrus_mult', 2.0)
    Env.SetNumber('cirrus_mult', 2.5)
    Env.SetNumber('cirrus_mult', 3.0)
    check('a drag of one slider is one undo step', History.Version == steps + 1, History.Version - steps)
    History.Undo()
    check('...and one undo takes it all back', near(Env.Value('cirrus_mult'), original.num.cirrus_mult))

    local t0 = Env.Text('sky_cirrus')
    Env.SetText('sky_cirrus', '/textures/environment/cirrus000.dds')
    check('a texture path is set', Env.Text('sky_cirrus') == '/textures/environment/cirrus000.dds')
    History.Undo()
    check('undo of a texture path', Env.Text('sky_cirrus') == t0)
    local w0 = Env.Text('water_wave3')
    Env.SetText('water_wave3', '/textures/engine/waves001.dds')
    check('a wave map path is set', Env.Text('water_wave3') == '/textures/engine/waves001.dds')
    History.Undo()
    check('...and comes back', Env.Text('water_wave3') == w0)
    Env.Apply({ num = { w_move2_x = 0.77, w_repeat_1 = 0.02 } }, { label = 'waves' })
    check('wave motion and scale', near(Env.Value('w_move2_x'), 0.77) and near(Env.Value('w_repeat_1'), 0.02))
    History.Undo()

    local bb = { 100, 50, 300, 0.5, 40, 30, 0, 0.5, 0.5, 0.5, -200, 80, 10, 0, 12, 12, 0.5, 0, 0.5, 0.5 }
    Env.Apply({ billboards = bb }, { label = 'billboards' })
    local list = Env.Billboards()
    check('sky billboards are set', table.getn(list) == 2 and near(list[1].x, 100) and near(list[2].sx, 12) and near(list[1].rot, 0.5), table.getn(list))
    History.Undo()
    check('undo of the billboards', table.getn(Env.Billboards()) == table.getn(original.billboards) / 10)
    Env.Apply({ lookups = { '<default>', '/textures/environment/envcube_desert01a.dds' } }, { label = 'cubes' })
    check('environment cube lookups', table.getn(Env.Lookups()) == 1 and Env.Lookups()[1][2] == '/textures/environment/envcube_desert01a.dds')
    History.Undo()
    check('undo of the lookups', table.getn(Env.Lookups()) == table.getn(original.lookups) / 2)
    Env.Apply({ num = { topo_samples = 31, hypso1_r = 0.25 } }, { label = 'imager' })
    check('strategic view numbers', near(Env.Value('topo_samples'), 31) and near(Env.Value('hypso1_r'), 0.25, 0.01))
    History.Undo()
    Env.Apply({ num = { dome_w = 24, dome_radius = 700 } }, { label = 'dome' })
    check('dome shape (rebuilds the dome)', near(Env.Value('dome_w'), 24) and near(Env.Value('dome_radius'), 700, 0.5))
    History.Undo()
    check('unknown names are ignored', pcall(function() ed_env_set({ no_such_number = 5 }) ed_env_set_texts({ no_such_text = 'x' }) end))

    -- ---- capture, blend, from a map -----------------------------------------------------------------------------------------------------------
    local cap = Env.Capture(ALL)
    local same, why = SameParts(cap, original)
    check('capture after undo equals the start', same, why)
    local a = { num = { x = 0, y = 10 }, texts = { t = 'a' } }
    local b = { num = { x = 1, y = 20, z = 5 }, texts = { t = 'b' }, billboards = { 1, 2 } }
    local mid = Env.Blend(a, b, 0.5)
    check('blend numbers', near(mid.num.x, 0.5) and near(mid.num.y, 15) and near(mid.num.z, 5))
    check('blend paths and lists follow the nearer end', mid.texts.t == 'b' and Env.Blend(a, b, 0.4).texts.t == 'a' and mid.billboards ~= nil)
    local fake = { width = 100, light = { sun_r = 1.1, bloom = 0.2 }, water = { w_glow = 0.4, texts = { water_ramp = '/textures/engine/waterramp.dds' } },
                   sky = { sky_r = 0.5, dome_radius = 1000, horizon_size = 50, dome_oy = 5, dome_height = 2, texts = { sky_cirrus = '/textures/environment/cirrus000.dds' }, billboards = { 100, 200, 300, 0.1, 10, 20, 0, 0, 1, 1 } },
                   lookups = { 'a', 'b' }, skycube = '/textures/environment/defaultskycube.dds' }
    local size = (ed_terrain_info() or 257) - 1
    local parts = Env.FromMap(fake, { 'light', 'water', 'waves', 'sky', 'skyshape', 'cubes' }, { size = size })
    check('from a map: numbers and paths sorted into their groups', near(parts.num.sun_r, 1.1) and near(parts.num.w_glow, 0.4) and near(parts.num.sky_r, 0.5)
        and parts.texts.water_ramp == '/textures/engine/waterramp.dds' and parts.texts.sky_cirrus == '/textures/environment/cirrus000.dds' and parts.texts.skycube ~= nil)
    local ratio = size / 100
    local half = size / 2
    check('from a map: the sky grows with the map', near(parts.num.dome_radius, 1000 * ratio, 1) and near(parts.billboards[5], 10 * ratio, 0.01) and near(parts.billboards[4], 0.1)
        and near(parts.billboards[1], size / 2 + (100 - 50) * ratio, 0.01) and near(parts.billboards[3], size / 2 + (300 - 50) * ratio, 0.01), tostring(parts.billboards[1]))
    check('from a map: the dome stays on this map', near(parts.num.dome_oy, Env.Value('dome_oy')) and near(parts.num.dome_ox, size / 2, 1))
    check('from a map: only the asked groups', Env.FromMap(fake, { 'light' }).num.sky_r == nil and Env.FromMap(fake, { 'light' }).num.sun_r ~= nil)

    -- ---- the shipped libraries ----------------------------------------------------------------------------------------------------------------
    -- only the shipped entries: the user's own looks and themes (whatever is in the user files) must not decide the test
    local looks, themes = {}, {}
    for _, l in Lib.Looks() do if not l.user then table.insert(looks, l) end end
    for _, th in Lib.Themes() do if not th.user then table.insert(themes, th) end end
    check('shipped looks', table.getn(looks) >= 60, table.getn(looks))
    check('shipped themes', table.getn(themes) >= 40, table.getn(themes))
    local bad = {}
    local function Exists(path, who)
        if path and path ~= '' and not DiskGetFileInfo(path) then table.insert(bad, who .. ': ' .. path) end
    end
    local ids, dupes = {}, {}
    for _, l in looks do
        if ids[l.id] then table.insert(dupes, l.id) end
        ids[l.id] = true
        local t = l.t
        for _, bag in { t.water and t.water.texts, t.sky and t.sky.texts } do
            for _, p in (bag or {}) do Exists(p, l.name) end
        end
        Exists(t.skycube, l.name)
        for i = 2, table.getn(t.lookups or {}), 2 do Exists(t.lookups[i], l.name) end
    end
    check('every look has a unique id', table.getn(dupes) == 0, table.concat(dupes, ' '))
    check('every texture of every look exists', table.getn(bad) == 0, table.getn(bad) .. ': ' .. (bad[1] or '') .. ' ' .. (bad[2] or ''))
    bad = {}
    ids, dupes = {}, {}
    for _, th in themes do
        if ids[th.id] then table.insert(dupes, th.id) end
        ids[th.id] = true
        for i, ly in th.layers do
            Exists(ly.albedo, th.name)
            Exists(ly.normal, th.name)
        end
    end
    check('every theme has a unique id', table.getn(dupes) == 0, table.concat(dupes, ' '))
    check('every texture of every theme exists', table.getn(bad) == 0, table.getn(bad) .. ': ' .. (bad[1] or '') .. ' ' .. (bad[2] or ''))

    -- ---- applying looks ------------------------------------------------------------------------------------------------------------------------
    local look = looks[1]
    local before = Env.Capture(Lib.LOOK_SECTIONS)
    local ok, revert = Lib.ApplyLook(look, { preview = true })
    local tried = Env.Capture(Lib.LOOK_SECTIONS)
    local changed = not SameParts(before, tried)
    check('a look can be tried', ok == true and revert ~= nil and changed)
    local hv = History.Version
    revert()
    local back = Env.Capture(Lib.LOOK_SECTIONS)
    same, why = SameParts(before, back)
    check('reverting a try restores everything', same, why)
    check('a try leaves no undo entry', History.Version == hv)
    ok = Lib.ApplyLook(look, {})
    check('apply makes ONE undo step', ok and History.Version == hv + 1)
    History.Undo()
    same, why = SameParts(before, Env.Capture(Lib.LOOK_SECTIONS))
    check('undo of a look restores everything', same, why)
    Lib.ApplyLook(look, { blend = 0.5, sections = { 'light' } })
    local full = Env.FromMap(look.t, { 'light' }, { size = size })
    check('a half blend lies between', near(Env.Value('sun_r'), (before.num.sun_r + full.num.sun_r) / 2, 0.01))
    History.Undo()
    local snapshotBefore = Env.Capture(Lib.LOOK_SECTIONS)
    local okp, rv = Lib.ApplyLook(look, { preview = true })
    Lib.SetPreview('look', rv, function() local o2, r2 = Lib.ApplyLook(look, { preview = true }) return r2 end)
    check('a preview is registered', Lib.HasPreview('look'))
    local resume = Lib.SuspendPreviews()
    same, why = SameParts(snapshotBefore, Env.Capture(Lib.LOOK_SECTIONS))
    check('saving takes a preview off', same and resume ~= nil, why)
    resume()
    check('...and puts it back', not SameParts(snapshotBefore, Env.Capture(Lib.LOOK_SECTIONS)))
    Lib.RevertPreview('look')
    same, why = SameParts(snapshotBefore, Env.Capture(Lib.LOOK_SECTIONS))
    check('revert takes the preview off', same and not Lib.HasPreview('look'), why)

    -- ---- the map as a source: the natives and the saver -------------------------------------------------------------------------------------
    local Map = import('/lua/editor/map.lua')
    Env.Apply({ num = { horizon_r = 0.91, sky_b = 0.33, cirrus2_speed = 4.5, w_move1_x = 0.25, w_sun_refl = 3.5, bloom = 0.21, fog_end = 1234 },
                texts = { sky_cirrus = '/textures/environment/cirrus000.dds', water_wave2 = '/textures/engine/waves001.dds' }, billboards = bb }, { label = 'save test' })
    local scenario = Map.SaveAs('../mapout/_selftest_env.v0001', '_selftest_env')
    check('the map saves', scenario ~= nil, tostring(scenario))
    local disk = scenario and ed_vfs_to_disk(scenario)
    local path = disk and string.gsub(disk, '_scenario%.lua$', '.scmap')
    local t, err = nil, nil
    if path then t, err = ed_scmap_env(path) end
    check('ed_scmap_env reads the saved map', t ~= nil, tostring(err) .. ' ' .. tostring(path))
    if t then
        check('saved lighting', near(t.light.bloom, 0.21, 0.001) and near(t.light.fog_end, 1234, 0.5))
        check('saved water', near(t.water.w_move1_x, 0.25, 0.001) and near(t.water.w_sun_refl, 3.5, 0.001) and t.water.texts.water_wave2 == '/textures/engine/waves001.dds')
        check('saved sky', t.sky ~= nil and near(t.sky.horizon_r, 0.91, 0.001) and near(t.sky.sky_b, 0.33, 0.001) and near(t.sky.cirrus2_speed, 4.5, 0.001) and t.sky.texts.sky_cirrus == '/textures/environment/cirrus000.dds')
        check('saved billboards', t.sky and table.getn(t.sky.billboards) == 20 and near(t.sky.billboards[1], 100, 0.01) and near(t.sky.billboards[16], 12, 0.01))
        check('saved strata', table.getn(t.strata) == 10)
        check('saved size', t.width == size)
        local imported = Lib.ImportLook(path, '_selftest_env_look')
        check('a look is imported from a map file', imported ~= nil and near(imported.t.sky.horizon_r, 0.91, 0.001))
        if imported then
            Lib.DeleteLook(imported.id)
            check('...and deleted again', Lib.FindLook(imported.id) == nil)
        end
        local theme = Lib.ImportTheme(path, '_selftest_env_theme')
        check('a theme is imported from a map file', theme ~= nil and theme.layers[0] ~= nil)
        if theme then Lib.DeleteTheme(theme.id) end
    end
    local saved = Lib.SaveLook('_selftest_env_save', { 'light', 'sky' })
    check('the present environment is saved as a look', saved ~= nil and saved.t.light.fog_end ~= nil and saved.t.sky.horizon_r ~= nil and saved.user == true)
    local found = Lib.FindLook(saved.id)
    check('...and found again (read from the user file)', found ~= nil and near(found.t.light.fog_end, 1234, 0.5) and found.t.sky.billboards ~= nil)
    check('...and applies', found and Lib.ApplyLook(found, { preview = true }) == true)
    Lib.RevertPreviews()
    Lib.DeleteLook(saved.id)
    check('...and is deleted', Lib.FindLook(saved.id) == nil)
    History.Undo()

    -- ---- themes ------------------------------------------------------------------------------------------------------------------------------
    if ed_stratum_info() then
        local theme
        for _, th in themes do if th.name == 'Volcanic' then theme = th end end
        local function Sig()
            local s = {}
            for i = 0, 9 do
                local snap = Strata.Snapshot(i)
                if snap.albedo == '' or snap.albedo == Strata.CLEAR then
                    s[i] = 'none'            -- no texture: an empty slot and the transparent texture are the same to the eye
                else
                    s[i] = snap.albedo .. '|' .. snap.normal .. '|' .. snap.size .. '|' .. snap.nsize
                end
            end
            return s
        end
        local function SameSig(x, y) for i = 0, 9 do if x[i] ~= y[i] then return false, i end end return true end
        local sig0 = Sig()
        local snaps = {}
        for i = 0, 9 do snaps[i] = Strata.Snapshot(i) end
        local okt, rev, missing = Lib.ApplyTheme(theme, { preview = true })
        check('a theme can be tried', okt and rev ~= nil and ed_stratum_layer(1) == theme.layers[1].albedo and table.getn(missing) == 0, tostring(ed_stratum_layer(1)))
        local _, tile = ed_stratum_layer(1)
        check('...with its tile sizes', near(tile or 0, theme.layers[1].size))
        rev()
        local ok2, why2 = SameSig(sig0, Sig())
        check('reverting a try restores the layers', ok2, tostring(why2))
        hv = History.Version
        Lib.ApplyTheme(theme, {})
        check('apply is ONE undo step', History.Version == hv + 1)
        History.Undo()
        ok2, why2 = SameSig(sig0, Sig())
        check('undo restores the layers', ok2, tostring(why2))
        History.Redo()
        check('redo applies it again', ed_stratum_layer(1) == theme.layers[1].albedo)
        History.Undo()
        -- clear unused: a layer the theme does not have loses texture and paint, undo brings both back
        Strata.SetTexture(8, '/env/evergreen/layers/rockmed_albedo.dds', nil, 6, 6)
        Strata.ClearMask(8)
        Strata.FillMask(8)
        local function MaskSum() return Fields.Run(function(S) return Fields.Checksum(S:Stratum(8, true)) end) end
        local full8 = MaskSum()
        local sig1 = Sig()
        Lib.ApplyTheme(theme, { clearUnused = true })
        local mn, mx = Fields.Run(function(S) local x, y = Fields.Stats(S:Stratum(8)) return x, y end)
        check('clear unused layers removes texture and paint', ed_stratum_layer(8) == Strata.CLEAR and mx == 0, tostring(ed_stratum_layer(8)))
        History.Undo()
        ok2, why2 = SameSig(sig1, Sig())
        check('...and undo brings both back', ok2 and MaskSum() == full8, tostring(why2))
        Strata.ClearMask(8)
        for i = 0, 9 do
            local snap = snaps[i]
            if snap.albedo ~= '' then Strata.Restore(snap) else if i >= 1 then Strata.Clear(i) end end
        end
        local saveTheme = Lib.SaveTheme('_selftest_env_theme_save')
        check('the present layers are saved as a theme', saveTheme ~= nil and saveTheme.user == true)
        Lib.DeleteTheme(saveTheme.id)
    else
        table.insert(lines, '  skip theme tests (no paint masks)')
    end

    -- ---- water masks (foam, flatness, depth bias) ---------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_field_wmask') then
        local MaskGen = import('/lua/editor/maskgen.lua')
        local function Mean(kind) return Fields.Run(function(S) local _, _, m = Fields.Stats(S:Add(Fields.WaterMask(kind))) return m end) end
        local function Const(v)
            local r = MaskGen.NewRule('const')
            r.v.value = v
            return { rules = { r } }
        end
        local f0, fl0, d0 = Mean(1), Mean(2), Mean(3)
        local w, h = Fields.Run(function(S) local a, b = Fields.Info(S:Add(Fields.WaterMask(1))) return a, b end)
        check('water masks are half the map', w == math.floor((ed_terrain_info() - 1) / 2) and h == w, tostring(w) .. 'x' .. tostring(h))
        hv = History.Version
        local n = MaskGen.ApplyToWaterMask(Const(0.5), { wmask = 1, mode = 1, strength = 1 })
        check('the foam mask is written', n and n > 100 and near(Mean(1), 0.5, 0.01), tostring(n) .. ' ' .. Mean(1))
        check('...as one undo step', History.Version == hv + 1)
        History.Undo()
        check('undo restores the foam mask', near(Mean(1), f0, 0.001))
        History.Redo()
        check('redo writes it again', near(Mean(1), 0.5, 0.01))
        History.Undo()
        MaskGen.ApplyToWaterMask(Const(0.25), { wmask = 2, mode = 3, strength = 1 })
        check('subtract from the flatness mask', near(Mean(2), fl0 * 0.75, 0.01), tostring(Mean(2)))
        History.Undo()
        MaskGen.ApplyToWaterMask(Const(1), { wmask = 3, mode = 1, strength = 0.5 })
        check('strength blends with what is there', near(Mean(3), d0 + (1 - d0) * 0.5, 0.01), tostring(Mean(3)))
        History.Undo()
        check('every water mask is back', near(Mean(1), f0, 0.001) and near(Mean(2), fl0, 0.001) and near(Mean(3), d0, 0.001))
        local fn = 0
        for _, p in MaskGen.Presets do if p.id == 'shorefoam' or p.id == 'deepcalm' then fn = fn + 1 end end
        check('water mask presets', fn == 2)
    else
        table.insert(lines, '  skip water mask tests (engine build without water masks)')
    end

    -- ---- panels ---------------------------------------------------------------------------------------------------------------------------------
    for _, id in { 'sky', 'skytex', 'skyobjects', 'watermotion', 'imager', 'looks', 'themes' } do
        check('panel ' .. id .. ' is registered', Panels.Get(id) ~= nil)
    end

    -- ---- put everything back -----------------------------------------------------------------------------------------------------------------
    Lib.RevertPreviews()
    Env.Apply(original, { label = 'selftest restore' })
    History.Clear()
    same, why = SameParts(original, Env.Capture(ALL))
    check('the environment is as it was', same, why)

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
