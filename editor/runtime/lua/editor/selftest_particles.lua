-- The particle editor (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md, docs/projects/editor/WP8_PARTICLES.md): upstream's emitter logic bound as ed_fx_*, the file-preserving writer, the model's edits,
-- the preview natives, the effect templates as node graphs and the effect decorations of a map.
-- Through /edcmd in a session of any map:
--   return import('/lua/editor/selftest_particles.lua').Run()                  the checks below (the open map's document is edited and put back)
--   return import('/lua/editor/selftest_particles.lua').Audit([dir])           every emitter / beam / trail file of the game's file system (or of the disk folder `dir`: retail's effects.scd
--                                                                                extracted): read, written back, byte for byte (scripts/ed_fx_audit.py runs it)
--   return import('/lua/editor/selftest_particles.lua').Build('<disk dir>', '<stem>')      a decoration is put on the map and the map saved as a folder; open it with control.LoadMap(<path>)
--   return import('/lua/editor/selftest_particles.lua').Verify()               in the reopened session: the marker, the script and the live decoration are there
--
-- Lua 5.0 dialect.

local Fx = import('/lua/editor/fxparticle.lua')
local Deco = import('/lua/editor/fxdeco.lua')
local Map = import('/lua/editor/map.lua')

local out, failed = {}, 0

local function Check(ok, text)
    if not ok then failed = failed + 1 end
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
end

local function Report(prefix)
    local text = (failed == 0 and 'PASS' or ('FAIL (' .. failed .. ')')) .. ' ' .. (prefix or '') .. '\n' .. table.concat(out, '\n')
    return text
end

--- The first and the last index at which two texts differ, from both ends: what lies between is all an edit changed.
local function Changed(a, b)
    local la, lb = string.len(a), string.len(b)
    local p = 0
    local n = math.min(la, lb)
    while p < n and string.byte(a, p + 1) == string.byte(b, p + 1) do p = p + 1 end
    local q = 0
    while q < n - p and string.byte(a, la - q) == string.byte(b, lb - q) do q = q + 1 end
    return p, q, la - p - q, lb - p - q
end

local EMITTER = '/effects/emitters/cannon_muzzle_flash_01_emit.bp'
local BEAM = '/effects/emitters/adjacency_aeon_beam_01_emit.bp'

--- Every emitter, beam and trail file: read back, written back. `files` = list of { path | text, name }.
local function AuditFiles(read, names)
    local emitters, ok, identical, preserved, flats, flatOk, flatPreserved, unread = 0, 0, 0, 0, 0, 0, 0, 0
    local bad = {}
    for _, name in names do
        local raw = read(name)
        local kind = raw and Fx.KindOfText(raw)
        if kind == 'emitter' then
            emitters = emitters + 1
            local r = ed_fx_emitter_roundtrip(raw)
            if r.ok then ok = ok + 1 end
            if r.identical then identical = identical + 1 end
            if r.preserved then preserved = preserved + 1 elseif table.getn(bad) < 6 then table.insert(bad, name) end
        elseif kind then
            flats = flats + 1
            local r = ed_fx_flat_roundtrip(raw)
            if r.ok then flatOk = flatOk + 1 end
            if r.preserved then flatPreserved = flatPreserved + 1 elseif table.getn(bad) < 6 then table.insert(bad, name) end
        else
            unread = unread + 1
        end
    end
    return { emitters = emitters, ok = ok, identical = identical, preserved = preserved, flats = flats, flatOk = flatOk, flatPreserved = flatPreserved, other = unread, bad = bad }
end

--- The audit over the game's file system, or over the .bp files of a disk folder (`dir`, forward slashes; `names` = its file names).
function Audit(dir, names)
    local read, list
    if dir and names then
        list = names
        read = function(name) return ed_read_file(dir .. '/' .. name) end
    else
        list = {}
        for _, f in ed_fx_list_files() do table.insert(list, f.path) end
        read = function(path) return ed_game_file_read(path) end
    end
    local a = AuditFiles(read, list)
    return string.format('files %d | emitters %d: read back as the same emitter %d, plain writer byte-identical %d, written back through the file\'s own text byte-identical %d | beams and trails %d: ok %d, byte-identical %d | other %d%s',
        table.getn(list), a.emitters, a.ok, a.identical, a.preserved, a.flats, a.flatOk, a.flatPreserved, a.other,
        table.getn(a.bad) > 0 and (' | not preserved: ' .. table.concat(a.bad, ' ')) or '')
end

function Run()
    out, failed = {}, 0

    -- 1. the natives
    for _, name in { 'ed_fx_info', 'ed_fx_emitter_new', 'ed_fx_emitter_parse', 'ed_fx_emitter_write', 'ed_fx_emitter_roundtrip', 'ed_fx_curve_samples', 'ed_fx_flat_parse', 'ed_fx_flat_write',
                     'ed_fx_list_files', 'ed_fx_templates', 'ed_fx_graph_build', 'ed_fx_graph_emitters', 'ed_fx_script_effects', 'ed_fxv_view', 'ed_fxv_emitter', 'ed_fxv_stats', 'ed_fxv_world_set' } do
        Check(rawget(_G, name) ~= nil, name .. ' is there')
    end
    if failed > 0 then return Report('the natives are missing: this engine build has no particle editor') end
    local info = ed_fx_info()
    Check(table.getn(info.curves) == 21 and table.getn(info.flags) == 13, '21 curves, 13 flags: ' .. table.getn(info.curves) .. ', ' .. table.getn(info.flags))

    -- 2. a new emitter
    local e = ed_fx_emitter_new()
    local text = ed_fx_emitter_write(e)
    local back = ed_fx_emitter_parse(text)
    Check(back ~= nil and ed_fx_emitter_write(back) == text, 'a new emitter writes, reads and writes the same text')
    Check(string.find(text, 'EmitterBlueprint', 1, true) == 1, 'a file starts with its constructor')
    local rt = ed_fx_emitter_roundtrip(text)
    Check(rt.ok and rt.identical and rt.preserved, 'a new emitter is byte-identical through the plain writer and the file\'s own text')
    local bad, why = ed_fx_emitter_parse('BeamBlueprint { Length = 1 }')
    Check(bad == nil and why ~= nil, 'a beam is not an emitter: ' .. tostring(why))

    -- 3. every file of the game's file system
    local t0 = GetSystemTimeSeconds()
    local audit = Audit()
    table.insert(out, '  info  ' .. audit .. string.format('  (%.1f s)', GetSystemTimeSeconds() - t0))
    local count, okc, plain, kept = string.gfind(audit, 'emitters (%d+): read back as the same emitter (%d+), plain writer byte%-identical (%d+), written back through the file\'s own text byte%-identical (%d+)')()
    Check(count ~= nil and tonumber(count) > 2000, 'the game has more than 2000 emitters: ' .. tostring(count))
    Check(count ~= nil and okc == count, 'every emitter reads back as the same emitter')
    Check(count ~= nil and kept == count, 'every emitter is written back through its own text byte for byte')
    local fcount, fok, fkept = string.gfind(audit, 'beams and trails (%d+): ok (%d+), byte%-identical (%d+)')()
    Check(fcount ~= nil and fok == fcount and fkept == fcount, 'every beam and trail reads back and is written back byte for byte: ' .. tostring(fkept) .. ' of ' .. tostring(fcount))

    -- 4. an edit changes the keys it touched and nothing else of the file
    local opened, owhy = Fx.Open(EMITTER)
    Check(opened, 'opens ' .. EMITTER .. ' ' .. tostring(owhy))
    if opened then
        local original = Fx.Original
        local first = Fx.Text()
        Check(first == original and Fx.Patched, 'untouched, it is written back as the file is')
        Check(Fx.CurveIndex('SizeCurve') ~= nil and Fx.CurveIndex('EmitRateCurve') ~= nil, 'curves are found by name')
        local i = Fx.CurveIndex('LifetimeCurve')
        local y0 = Fx.Curve(i).keys[1].y
        -- one flag: one line of the file changes
        local flag = not Fx.Emitter.flags.Gravity
        Fx.SetFlag('Gravity', flag)
        local flagged = Fx.Text()
        Check(Fx.Patched and flagged ~= original, "a flag edit is written into the file's text")
        local p0, q0, dropped0, added0 = Changed(original, flagged)
        Check(dropped0 < 40 and added0 < 40, string.format('and changes that value only (replaced %d bytes, new %d)', dropped0, added0))
        -- a curve key and the flag: both keys changed, the text between them untouched
        Fx.SetKey(i, 1, nil, y0 + 0.5, nil)
        local edited = Fx.Text()
        Check(Fx.Patched and edited ~= flagged, "a curve edit is written into the file's text too")
        local p, q, dropped, added = Changed(original, edited)
        Check(string.len(edited) - added == string.len(original) - dropped, string.format("the text outside the changed span is the file's (prefix %d, suffix %d bytes of %d)", p, q, string.len(original)))
        local reread = ed_fx_emitter_parse(edited)
        Check(reread and reread.flags.Gravity == Fx.Emitter.flags.Gravity and math.abs(reread.curves.LifetimeCurve.keys[1].y - (y0 + 0.5)) < 0.0011, 'the edit reads back')
        Check(Fx.CanUndo(), 'the edit is an undo step')
        Fx.Undo() Fx.Undo()
        Check(Fx.Text() == original, 'undoing the edits writes the original bytes again')
        Fx.Redo()
        Check(Fx.Emitter.flags.Gravity == flag and math.abs(Fx.Curve(i).keys[1].y - y0) < 0.011, 'redo brings the first edit (the flag) back, one step at a time')
        Fx.Undo()

        -- curve keys
        local ci = Fx.CurveIndex('SizeCurve')
        local n0 = table.getn(Fx.Curve(ci).keys)
        local idx = Fx.AddKey(ci, Fx.Curve(ci).xRange * 0.5)
        local keys = Fx.Curve(ci).keys
        Check(table.getn(keys) == n0 + 1 and idx ~= nil, 'a key is added (' .. n0 .. ' -> ' .. table.getn(keys) .. ')')
        local sorted = true
        for n = 2, table.getn(keys) do if keys[n].x < keys[n - 1].x then sorted = false end end
        Check(sorted, 'the keys stay in time order')
        local moved = Fx.SetKey(ci, idx, Fx.Curve(ci).xRange * 0.9, 7, 1)
        local s = ed_fx_curve_samples(Fx.Curve(ci).keys, Fx.Curve(ci).xRange, 3)
        Check(s.hi[3] - s.lo[3] >= 0 and s.mid[1] ~= nil, 'the curve samples (mid, low and high edge)')
        Check(Fx.RemoveKey(ci, moved) and table.getn(Fx.Curve(ci).keys) == n0, 'a key is removed again')
        Fx.SetKeys(ci, { { x = 0, y = 2, z = 0 }, { x = 1, y = 4, z = 2 } })
        local spread = ed_fx_curve_samples(Fx.Curve(ci).keys, Fx.Curve(ci).xRange, 2)
        Check(math.abs(spread.mid[1] - 2) < 1e-4 and math.abs(spread.lo[2] - 3) < 1e-4 and math.abs(spread.hi[2] - 5) < 1e-4, 'a key\'s spread is half either way: ' .. spread.lo[2] .. ' .. ' .. spread.hi[2])
        for _ = 1, 4 do Fx.Undo() end
        Check(Fx.Text() == original, 'undo goes back to the original through the key edits too')
    end

    -- 4b. the curve plot's edits (needs the Particle editor panel to be built; skipped otherwise)
    local PanelModule = import('/lua/editor/gui/panels_particles.lua')
    local P = PanelModule.live.particles
    if P and P.plotSet and not P.dead and Fx.Open(EMITTER) then
        local idx = Fx.CurveIndex('SizeCurve')
        P.curve = idx
        local R = Fx.Curve(idx).xRange
        Fx.SetKeys(idx, { { x = 0, y = 1, z = 0.2 }, { x = 50, y = 2, z = 0.5 }, { x = 100, y = 3, z = 0 } })
        P.plotSet({ { 0, 1 }, { 50 / R, 2.5 }, { 100 / R, 3 } })
        local k = Fx.Curve(idx).keys
        Check(table.getn(k) == 3 and math.abs(k[2].y - 2.5) < 1e-4 and math.abs(k[2].z - 0.5) < 1e-4, 'dragging a key keeps its spread')
        P.plotSet({ { 0, 1 }, { 20 / R, 1.4 }, { 50 / R, 2.5 }, { 100 / R, 3 } })
        k = Fx.Curve(idx).keys
        Check(table.getn(k) == 4 and math.abs(k[2].x - 20) < 0.01 and k[2].z == 0 and math.abs(k[3].z - 0.5) < 1e-4 and math.abs(k[1].z - 0.2) < 1e-4, 'a key added by a click has no spread and the others keep theirs')
        P.plotSet({ { 0, 1 }, { 50 / R, 2.5 }, { 100 / R, 3 } })
        k = Fx.Curve(idx).keys
        Check(table.getn(k) == 3 and math.abs(k[2].z - 0.5) < 1e-4 and math.abs(k[1].z - 0.2) < 1e-4, 'a deleted key takes its own spread with it')
        Fx.Open(EMITTER)
    else
        table.insert(out, '  skip  the Particle editor panel is not built: the plot checks need it')
    end

    -- 5. a beam
    local beam, bwhy = Fx.Open(BEAM)
    Check(beam, 'opens a beam ' .. tostring(bwhy))
    if beam then
        local original = Fx.Original
        Check(Fx.Kind == 'beam' and Fx.Text() == original, 'an untouched beam is written back as the file is (its # comments included)')
        Fx.SetFlat('Thickness', 'number', 0.3)
        local edited = Fx.Text()
        Check(Fx.Patched and string.find(edited, 'Thickness = 0.3', 1, true) ~= nil and (string.find(original, '#', 1, true) == nil or string.find(edited, '#', 1, true) ~= nil), 'a beam edit changes Thickness and keeps the comments')
        Fx.Undo()
    end

    -- 6. the preview natives
    Fx.Open(EMITTER)
    local view = ed_fxv_view({ pictureWidth = 1024, pictureHeight = 640 })
    Check(view ~= nil and view.texture == '/ed_dyn/fxview', 'the preview offers its picture as ' .. tostring(view and view.texture))
    ed_fxv_emitter(Fx.Emitter, true)
    ed_fxv_touch()
    local st = ed_fxv_stats()
    Check(st.open and st.texture, 'the preview view is open')

    -- 7. effect templates as node graphs
    local source = ed_game_file_read('/lua/EffectTemplates.lua') or ''
    local tpl = ed_fx_templates(source)
    Check(table.getn(tpl) > 100 and tpl[1].paths ~= nil, "the effect templates of the game's EffectTemplates.lua are read: " .. table.getn(tpl))
    local pair = {}
    for _, path in { EMITTER, '/effects/emitters/cannon_muzzle_smoke_01_emit.bp' } do
        local txt = ed_game_file_read(path)
        local em = txt and ed_fx_emitter_parse(txt)
        if em then table.insert(pair, { name = string.gsub(path, '^.*/', ''), emitter = em }) end
    end
    local graph = ed_fx_graph_build('Muzzle', pair)
    Check(graph and table.getn(graph.nodes) > 40 and table.getn(graph.links) > 40, 'two emitters become a graph: ' .. tostring(graph and table.getn(graph.nodes)) .. ' nodes, ' .. tostring(graph and table.getn(graph.links)) .. ' links')
    local made, gwhy = ed_fx_graph_emitters(graph)
    Check(made ~= nil and table.getn(made) == table.getn(pair), 'the graph makes the emitters again ' .. tostring(gwhy))
    if made then
        local same = true
        for i, m in made do
            if ed_fx_emitter_write(m.emitter) ~= ed_fx_emitter_write(pair[i].emitter) then same = false end
        end
        Check(same, 'and they are the emitters it was made from')
    end

    -- 8. a file written into a folder is found and loads as the game loads it
    local dir = '../mapout/_fxtest'
    Fx.New('emitter')
    Fx.SetName('wp8_test_emit.bp')
    Fx.SetNumber('lifetime', 33)
    local ci = Fx.CurveIndex('EmitRateCurve')
    Fx.SetKeys(ci, { { x = 0, y = 12, z = 3 }, { x = 5, y = 4, z = 0 } })
    local path, swhy = Fx.Save(dir)
    Check(path ~= nil, 'Save writes the new file ' .. tostring(path or swhy))
    if path then
        ed_vfs_mount(dir, '/mods/wp8fxtest')
        local vfs = '/mods/wp8fxtest/effects/emitters/wp8_test_emit.bp'
        local text2 = ed_game_file_read(vfs)
        Check(text2 ~= nil and text2 == Fx.Text(), 'the game\'s file system reads it from the mounted folder')
        -- the loader of the game (Blueprints.lua) runs the file with a global EmitterBlueprint(bp)
        local captured
        local env = { EmitterBlueprint = function(bp) captured = bp end }
        setmetatable(env, { __index = _G })
        local ran = pcall(doscript, vfs, env)
        Check(ran and captured ~= nil and captured.Lifetime == 33 and captured.EmitRateCurve.Keys[1].y == 12 and captured.EmitRateCurve.Keys[1].z == 3 and captured.EmitRateCurve.XRange ~= nil,
              'run as the game runs a blueprint file it gives Lifetime 33 and the emit rate keys' .. (captured and '' or ' (no blueprint)'))
        local found = false
        for _, f in ed_fx_list_files({ '/mods/wp8fxtest/effects' }) do
            if f.name == 'wp8_test_emit' then found = true end
        end
        Check(found, 'the browser\'s list finds it under the mod folder')
    end
    Fx.Close()

    -- 9. effect decorations in the map's script
    local script = "local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')\n\nfunction OnPopulate()\n    ScenarioUtils.InitializeArmies()\nend\n\nfunction OnStart(self)\nend\n"
    Check(ed_fx_script_effects(script, false) == script, 'a script without decorations stays as it is')
    local on = ed_fx_script_effects(script, true)
    Check(string.find(on, 'function MapEditorEffects()', 1, true) ~= nil and string.find(on, 'ScenarioUtils.InitializeArmies()\n    MapEditorEffects()', 1, true) ~= nil, 'with decorations the script has MapEditorEffects and calls it after InitializeArmies')
    Check(ed_fx_script_effects(on, true) == on, 'asking twice changes nothing')
    Check(ed_fx_script_effects(on, false) == script, 'taking the decorations out gives the script back byte for byte')
    if Map.Doc then
        local before = Deco.Count()
        Map.AddMarker('FX_TEST_DECO', 'Effect', 60, 25, 60, { effect = EMITTER, scale = 2, height = 1.5 })
        Check(Deco.Count() == before + 1, 'an Effect marker counts as a decoration')
        Check(string.find(Deco.PatchScript(script), 'MapEditorEffects()', 1, true) ~= nil, 'the map\'s script gets the function when a marker is there')
        Deco.Sync(true)
        local w = ed_fxv_stats()
        Check(w.decorations == before + 1, 'the decoration plays in the map view: ' .. tostring(w.decorations))
        Map.RemoveMarker('FX_TEST_DECO')
        Check(Deco.Count() == before, 'removing the marker removes the decoration')
        if before == 0 then Check(Deco.PatchScript(script) == script, 'with no decoration the script is not touched') end
        Deco.Sync(true)
    else
        table.insert(out, '  skip  no map open: the decoration checks need one')
    end
    return Report()
end

--- Step 1 of the reload check: an Effect marker on the open map, saved as a folder; returns the scenario path.
function Build(diskDir, stem)
    local doc, why = Map.Load()
    if not doc then return 'FAIL load: ' .. tostring(why) end
    Map.AddMarker('FX_DECO_1', 'Effect', 80, 25, 70, { effect = EMITTER .. ';/effects/emitters/cannon_muzzle_smoke_01_emit.bp', scale = 1.5, height = 2 })
    local scenario, why2 = Map.SaveAs(diskDir, stem, {})
    if not scenario then return 'FAIL save: ' .. tostring(why2) end
    local save = ed_read_file(diskDir .. '/' .. stem .. '_save.lua')
    local script = ed_read_file(diskDir .. '/' .. stem .. '_script.lua')
    local entries = save and ed_savefile_entries(save)
    local found = false
    for _, m in (entries and entries.markers) or {} do
        if m.name == 'FX_DECO_1' then found = true end
    end
    return scenario .. '  saved: marker in _save.lua ' .. tostring(found) .. ', MapEditorEffects in _script.lua ' .. tostring(script ~= nil and string.find(script, 'function MapEditorEffects()', 1, true) ~= nil)
end

--- Step 2, in the session of the saved folder.
function Verify()
    out, failed = {}, 0
    local list = Deco.Effects()
    Check(table.getn(list) == 1 and list[1].name == 'FX_DECO_1', 'the saved map holds the decoration: ' .. table.getn(list))
    local d = list[1]
    if d then
        Check(string.find(d.effect, 'cannon_muzzle_flash_01_emit.bp', 1, true) ~= nil and string.find(d.effect, ';', 1, true) ~= nil, 'its effect (two emitter files) is as saved')
        Check(d.scale == 1.5 and d.height == 2, 'its scale and height are as saved: ' .. d.scale .. ', ' .. d.height)
    end
    local script = ed_game_file_read(Map.Doc.scriptPath or '') or ''
    Check(string.find(script, 'function MapEditorEffects()', 1, true) ~= nil and string.find(script, 'MapEditorEffects() -- the map editor', 1, true) ~= nil, 'the script of the saved map has the function and its call')
    Deco.Sync(true)
    local st = ed_fxv_stats()
    Check(st.decorations == 1, 'the decoration plays again: ' .. tostring(st.decorations))
    return Report()
end
