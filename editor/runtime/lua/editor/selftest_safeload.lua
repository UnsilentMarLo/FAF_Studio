-- Protected loading (safe.lua, safeload.lua, the sidecar read of mods.lua): corrupt, old, future and oversized files must degrade, not break. Through /edcmd:
--   return import('/lua/editor/selftest_safeload.lua').Run()
-- Writes under ../mapout/_st_safeload (the instance's saved maps) and puts editor_mods.txt back.

local Load = import('/lua/editor/safeload.lua')
local Safe = import('/lua/editor/safe.lua')
local Mods = import('/lua/editor/mods.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Has(list, name)
    for _, n in list or {} do if n == name then return true end end
    return false
end

local GOOD = "version = 1\nEditorMods = {\n    'AAAA',\n}\nGraph = {\n    ['nodes'] = {},\n}\n"

function Run()
    out, failed = {}, 0
    Load.ClearProblems()
    local opts = function(extra)
        local o = { name = 'selftest', current = 1, schema = { EditorMods = 'table', Graph = 'table', Mission = 'table' }, migrate = {} }
        for k, v in extra or {} do o[k] = v end
        return o
    end

    -- a good file
    local env, info = Load.Text(GOOD, opts())
    Ok(env and env.EditorMods[1] == 'AAAA' and info.version == 1 and not info.future and table.getn(info.dropped) == 0, 'a good file loads untouched')

    -- a syntax error in one section: the other sections survive
    local broken = "version = 1\nEditorMods = {\n    'AAAA',\n}\nGraph = {\n    ['nodes' = {},\n}\nMission = { stages = {} }\n"
    env, info = Load.Text(broken, opts())
    Ok(env ~= nil and env.EditorMods and env.EditorMods[1] == 'AAAA' and env.Mission ~= nil and env.Graph == nil, 'a syntax error loses only its own section')
    Ok(info and Has(info.dropped, 'Graph') and info.bad, 'the dropped section is named')

    -- a runtime error (a call: the environment has no functions)
    env, info = Load.Text("version = 1\nEditorMods = {}\nMission = os.exit()\nGraph = {}\n", opts())
    Ok(env ~= nil and env.Graph ~= nil and env.Mission == nil and Has(info.dropped, 'Mission'), 'a section that raises is dropped, the rest stays')
    Ok(env and env.EditorMods ~= nil, 'a file cannot reach the globals (no os / import / doscript)')
    env = Load.Text("Graph = import('/lua/editor/mods.lua')\nEditorMods = {}\n", opts())
    Ok(env ~= nil and env.Graph == nil and env.EditorMods ~= nil, 'import is not available to a data file')

    -- wrong types
    env, info = Load.Text("version = 1\nGraph = 5\nMission = 'text'\nEditorMods = {}\n", opts())
    Ok(env and env.Graph == nil and env.Mission == nil and env.EditorMods ~= nil, 'a value of the wrong type is dropped')

    -- complete garbage and the size limit
    local nothing, why = Load.Text("this is not lua at all !!!\n(((", opts())
    Ok(nothing == nil and why ~= nil, 'a file that is garbage from end to end gives nil and a reason')
    nothing, why = Load.Text(GOOD, opts({ maxBytes = 10 }))
    Ok(nothing == nil and why == 'too large', 'a file over the size limit is refused')
    nothing = Load.Text(nil, opts())
    Ok(nothing == nil, 'no text is refused')
    local salvageOff = Load.Text(broken, opts({ salvage = false }))
    Ok(salvageOff == nil, 'salvage = false is all or nothing')

    -- versions: old file migrated, future file loaded as far as it is understood, bad version type
    local migrated = 0
    env, info = Load.Text("EditorMods = {}\nOld = 7\n", opts({ migrate = { [0] = function(e) e.Moved = e.Old e.Old = nil migrated = migrated + 1 end } }))
    Ok(env and env.Moved == 7 and env.Old == nil and env.version == 1 and migrated == 1 and info.migrated[1] == 0, 'a file without version is migrated from 0 to the current version')
    env, info = Load.Text("version = 3\nEditorMods = { 'x' }\nFuture = true\n", opts())
    Ok(env and info.future and info.version == 3 and env.EditorMods[1] == 'x' and env.Future == true, 'a newer version is loaded as it is and flagged')
    local steps = ''
    env, info = Load.Text("version = 1\nEditorMods = {}\n", opts({ current = 3, migrate = { [1] = function() steps = steps .. 'a' end, [2] = function() steps = steps .. 'b' end } }))
    Ok(steps == 'ab' and env.version == 3, 'migrations run in order, one per version')
    local mwhy
    env, mwhy, info = Load.Text("version = 1\nEditorMods = {}\n", opts({ current = 2, migrate = { [1] = function() error('boom') end } }))
    Ok(env == nil and mwhy and info and info.bad, 'a failing migration refuses the file (nothing half migrated)')
    env, info = Load.Text("version = 'one'\nEditorMods = {}\n", opts())
    Ok(env and info.version == 1 and info.bad, 'a version that is not a number reads as a file without version')

    -- a file on disk: the original is kept as .bad
    local dir = '../mapout/_st_safeload'
    ed_write_file(dir .. '/_st_scenario.lua', "ScenarioInfo = {}\n")
    local file = dir .. '/_st_editor.lua'
    ed_write_file(file, broken)
    ed_write_file(file .. '.bad', '')
    env, info = Load.File(file, opts())
    Ok(env ~= nil and env.EditorMods ~= nil and env.Graph == nil, 'File: a corrupt file on disk still loads what it can')
    Ok(info and type(info.bad) == 'string' and ed_read_file(file .. '.bad') == broken, 'File: the original text is kept as <file>.bad')
    local before = ed_read_file(file)
    Ok(before == broken, 'File: the corrupt file itself is not rewritten')
    ed_write_file(file .. '.bad', '')
    ed_write_file(file, GOOD)
    env, info = Load.File(file, opts())
    Ok(env ~= nil and not info.bad and ed_read_file(file .. '.bad') == '', 'File: a good file leaves no backup')
    env, why = Load.File(dir .. '/missing_editor.lua', opts())
    Ok(env == nil, 'File: a missing file gives nil')

    -- the sidecar read of mods.lua through a real mounted map folder
    local saved = ed_read_file('editor_mods.txt')
    local mounted = ed_vfs_mount(dir, '/maps/_st_safeload')
    Ok(mounted, 'the test map folder is mounted')
    local scenario = '/maps/_st_safeload/_st_scenario.lua'
    ed_write_file(file, "version = 1\nEditorMods = {\n    'NOSUCHMOD',\n    42,\n}\nMission = {{{{ broken\nGraph = { ['nodes'] = {} }\n")
    local set, call = nil, nil
    call, set = pcall(Mods.ApplySidecar, scenario)
    Ok(call, 'ApplySidecar does not raise on a corrupt sidecar (' .. tostring(set) .. ')')
    local sc, sinfo = Mods.SidecarEnv(scenario)
    Ok(sc ~= nil and type(sc.Graph) == 'table' and sc.Mission == nil, 'SidecarEnv: the readable sections are there, the broken one is not')
    Ok(sinfo and Has(sinfo.dropped, 'Mission'), 'SidecarEnv: the broken section is reported')
    local sc2 = Mods.SidecarEnv(scenario)
    Ok(sc2 == sc, 'SidecarEnv: the same table while the file is unchanged (one parse per open)')
    local again = Mods.SidecarEnv(scenario, true)
    Ok(again ~= sc and again ~= nil, 'SidecarEnv: fresh = true reads again')
    -- the loaders of the features take the broken file too
    local names = { 'terraintype', 'graph', 'layout', 'paths', 'interop', 'shaders' }
    for _, n in names do
        local good, err = pcall(function() import('/lua/editor/' .. n .. '.lua').LoadSidecar(scenario) end)
        Ok(good, n .. '.LoadSidecar survives a corrupt sidecar' .. (good and '' or (': ' .. tostring(err))))
    end
    -- a sidecar with an old (missing) version and a future one
    ed_write_file(file, "EditorMods = {}\nGraph = { ['nodes'] = {} }\n")
    sc, sinfo = Mods.SidecarEnv(scenario, true)
    Ok(sc and sinfo.version == Mods.SIDECAR_VERSION, 'an unversioned sidecar reads as the current version')
    ed_write_file(file, "version = 99\nEditorMods = {}\nGraph = { ['nodes'] = {} }\nNewThing = { 1, 2 }\n")
    sc, sinfo = Mods.SidecarEnv(scenario, true)
    Ok(sc and sinfo.future and type(sc.NewThing) == 'table', 'a sidecar of a newer editor opens, unknown sections kept')
    -- SidecarText writes the version this module reads
    local text = Mods.SidecarText()
    Ok(string.find(text, '^version = ' .. Mods.SIDECAR_VERSION) ~= nil, 'SidecarText starts with the schema version')
    local round = Load.Text(text, Mods.SidecarOptions())
    Ok(round ~= nil and round.version == Mods.SIDECAR_VERSION, 'what SidecarText writes loads without a complaint')

    if saved then ed_write_file('editor_mods.txt', saved) end
    ed_write_file(file, GOOD)

    -- Safe: logged once per site, then at the powers of ten
    Safe.Reset()
    local lines = {}
    local oldWarn = rawget(_G, 'WARN')
    rawset(_G, 'WARN', function(...) table.insert(lines, tostring(arg[1])) end)
    local r1 = Safe.Try('selftest.site', function() error('first') end)
    for i = 2, 25 do Safe.Try('selftest.site', function() error('again') end) end
    local okTry, value = Safe.Try('selftest.site', function(a, b) return a + b end, 2, 3)
    rawset(_G, 'WARN', oldWarn)
    Ok(r1 == false and okTry == true and value == 5, 'Try returns like pcall')
    Ok(table.getn(lines) == 2 and Safe.Failures('selftest.site') == 25, 'a site that fails 25 times is logged twice (the 1st and the 10th failure): ' .. table.getn(lines))
    Ok(Safe.Call('selftest.call', function() return 'x' end) == 'x' and Safe.Call('selftest.call', function() error('y') end) == nil, 'Call returns the first result or nil')
    Ok(Safe.Wrap('selftest.wrap', function(a) return a * 2 end)(4) == 8, 'Wrap passes arguments and results through')
    Safe.Reset()

    table.insert(out, 1, failed == 0 and 'ALL OK' or (failed .. ' FAIL'))
    return table.concat(out, '\n')
end
