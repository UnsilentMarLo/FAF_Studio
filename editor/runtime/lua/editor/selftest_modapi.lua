-- The extension API (api.lua, gui/panels.lua, gui/commands.lua, ui.lua tools) and the example mod: the mod's tool and command are really there and work, and code that raises is caught, named,
-- logged and (for a mod) turned off without taking the host down. Through /edcmd:
--   return import('/lua/editor/selftest_modapi.lua').Run()
-- Digs one crater with the example mod's tool on the open map and undoes it.

local Api = import('/lua/editor/api.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Mods = import('/lua/editor/mods.lua')
local UI = import('/lua/editor/ui.lua')
local H = import('/lua/editor/history.lua')
local Safe = import('/lua/editor/safe.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function ToolById(id)
    for _, t in UI.Tools do if t.id == id then return t end end
    return nil
end

local EXAMPLE = 'ED170000-5C0A-4D57-9E1F-000000000001'
local EXAMPLE_NAME = 'Editor example: crater tool'

function Run()
    out, failed = {}, 0
    Api.Clear()
    Safe.Reset()
    local warnings = {}
    local oldWarn = rawget(_G, 'WARN')
    rawset(_G, 'WARN', function(...) table.insert(warnings, tostring(arg[1])) if oldWarn then oldWarn(unpack(arg)) end end)

    -- the version and what is offered
    Ok(type(Api.ApiVersion) == 'number' and Api.ApiVersion >= Api.MinApiVersion, 'ApiVersion ' .. tostring(Api.ApiVersion) .. ', oldest supported ' .. tostring(Api.MinApiVersion))
    Ok(Api.Has('panels') and Api.Has('commands') and Api.Has('tools') and not Api.Has('nothing') and not Api.Has('panels', 99), 'capability query')
    Ok(Api.Compatible({}) == true and Api.Compatible({ editor_api = 1 }) == true, 'a mod without editor_api reads as API 1')
    local newer, why = Api.Compatible({ editor_api = 99 })
    Ok(newer == false and string.find(why, 'needs editor API 99', 1, true) ~= nil, 'a mod that needs a newer API is refused: ' .. tostring(why))
    Ok(Api.Compatible({ editor_api = 0 }) == false, 'a mod written for an API older than the oldest supported is refused')

    -- the example mod is loaded and its parts work
    local info = Mods.All()[EXAMPLE]
    Ok(info ~= nil and info.editor_mod and info.editor_api == 1, 'the example mod is on disk and declares editor_api = 1')
    local active = Mods.ActiveSet()
    Ok(active[EXAMPLE] == true, 'the example mod is among the active mods (not turned off, its hooks compile)')
    local tool = ToolById('crater')
    Ok(tool ~= nil and tool.mod == EXAMPLE_NAME and tool.kind == 'custom' and type(tool.OnPress) == 'function', 'its hook added the Crater tool, tagged with the mod name')
    local cmd = Commands.Find('crater tool')
    local found = false
    for _, def in cmd do if def.id == 'example.crater_info' and def.mod == EXAMPLE_NAME then found = true end end
    Ok(found, 'its command is in the palette')
    Ok(Commands.Run('example.crater_info') == true, 'the command runs')
    local depth = H.Depth()
    local took = Api.RunTool(tool, 100, 100, {})
    Ok(took == true, 'the Crater tool takes the click')
    local after = H.Depth()
    if after > depth then H.Undo() end
    Ok(H.Depth() == depth, 'and a crater is at most one undo step (' .. tostring(after - depth) .. ' here)')

    -- the tool fails: caught, named, off for the session, the click goes through
    local good = tool.OnPress
    tool.OnPress = function() error('hostile tool') end
    warnings = {}
    Ok(Api.RunTool(tool, 1, 1, {}) == false, 'a tool that raises lets the click through')
    Ok(Api.IsDisabled('tool', 'crater'), 'and is turned off')
    local named = false
    for _, w in warnings do if string.find(w, EXAMPLE_NAME, 1, true) and string.find(w, 'hostile tool', 1, true) then named = true end end
    Ok(named, 'the log line names the mod and the error')
    local calls = 0
    tool.OnPress = function() calls = calls + 1 return true end
    Api.RunTool(tool, 1, 1, {})
    Ok(calls == 0, 'a disabled tool is not called again')
    Api.Reenable('tool', 'crater')
    Api.RunTool(tool, 1, 1, {})
    Ok(calls == 1, 'Reenable brings it back')
    tool.OnPress = good

    -- a command that fails
    Commands.Register{ id = 'selftest.hostile', title = 'Selftest hostile command', mod = 'Hostile mod', run = function() error('hostile command') end }
    Commands.Register{ id = 'selftest.builtin', title = 'Selftest builtin command', run = function() error('builtin fails') end }
    Ok(Commands.Run('selftest.hostile') == false and Api.IsDisabled('command', 'selftest.hostile'), 'a mod command that raises is caught and turned off')
    local listed = false
    for _, def in Commands.Find('selftest hostile') do if def.id == 'selftest.hostile' then listed = true end end
    Ok(not listed, 'a disabled command leaves the palette')
    Commands.Run('selftest.builtin')
    Ok(Commands.Run('selftest.builtin') == false and not Api.IsDisabled('command', 'selftest.builtin'), 'a command without a mod is reported but stays on')
    Ok(Safe.Failures('command:selftest.builtin') == 2, 'its failures are counted per site')
    Commands.registry['selftest.hostile'] = nil
    Commands.registry['selftest.builtin'] = nil

    -- panels
    local Group = import('/lua/maui/group.lua').Group
    local seen = {}
    Panels.OnFailure(function(id, message, mod) seen[id] = { message = message, mod = mod } end)
    local built = 0
    Panels.Register{ id = 'selftest_hostile_panel', title = 'Hostile', mod = 'Hostile mod', create = function(group, host) built = built + 1 error('hostile panel') end }
    local def = Panels.Get('selftest_hostile_panel')
    local holder = Group(GetFrame(0))
    holder.Width:Set(300) holder.Height:Set(200) holder.Left:Set(0) holder.Top:Set(0)
    local inst = def.create(holder, nil)
    Ok(type(inst) == 'table' and inst.failed == true, 'a panel whose create raises gives a stub, not an error')
    Ok(Panels.failed['selftest_hostile_panel'] ~= nil and seen.selftest_hostile_panel and seen.selftest_hostile_panel.mod == 'Hostile mod', 'the registry records the failure and tells its listeners (the dock can show it)')
    inst = def.create(holder, nil)
    Ok(built == 1 and inst.failed, 'a mod panel that failed is not built again in the session')
    holder:Destroy()
    Panels.registry['selftest_hostile_panel'] = nil
    for i, id in Panels.order do if id == 'selftest_hostile_panel' then table.remove(Panels.order, i) break end end

    local refreshes = 0
    Panels.Register{ id = 'selftest_method_panel', title = 'Methods', mod = 'Hostile mod', create = function(group, host)
        return { Refresh = function() refreshes = refreshes + 1 error('hostile refresh') end, OnResize = function(self, w, h) return w end }
    end }
    holder = Group(GetFrame(0))
    inst = Panels.Get('selftest_method_panel').create(holder, nil)
    Ok(inst.OnResize(inst, 5, 6) == 5, 'the methods of a panel keep their results')
    local noRaise = pcall(inst.Refresh, inst)
    pcall(inst.Refresh, inst)
    Ok(noRaise and refreshes == 1, 'a Refresh that raises is caught and a mod panel\'s method is off afterwards (' .. refreshes .. ' call)')
    holder:Destroy()
    Panels.registry['selftest_method_panel'] = nil
    for i, id in Panels.order do if id == 'selftest_method_panel' then table.remove(Panels.order, i) break end end

    -- the registrar
    local reg = Api.Mod('Registrar test')
    local tools = {}
    local t = reg.Tool(tools, { id = 'rt', OnPress = function() end })
    Ok(tools[1] == t and t.mod == 'Registrar test' and t.kind == 'custom', 'Mod(name).Tool tags the tool and adds it')
    local ok1, v1 = reg.Try('site', function() return 7 end)
    local ok2 = reg.Try('site', function() error('x') end)
    Ok(ok1 == true and v1 == 7 and ok2 == false and Api.IsDisabled('mod', 'Registrar test:site'), 'Mod(name).Try runs protected and names the mod')

    -- hooks that do not compile keep a mod out
    local dir = '../mapout/_st_modapi'
    ed_write_file(dir .. '/hook/lua/editor/ui.lua', 'do\n  local x = (\nend\n')
    ed_write_file(dir .. '/hook/lua/editor/good.lua', 'do\n  local x = 1\nend\n')
    ed_vfs_mount(dir, '/mods/_st_modapi')
    local problems = Mods.HookProblems({ location = '/mods/_st_modapi' })
    Ok(table.getn(problems) == 1 and string.find(problems[1], 'ui.lua', 1, true) ~= nil, 'HookProblems finds a hook with a syntax error and only that one: ' .. tostring(problems[1]))
    Ok(table.getn(Mods.HookProblems({ location = '/mods/editor_example' })) == 0, 'the example mod\'s hooks compile')
    ed_write_file(dir .. '/hook/lua/editor/ui.lua', 'do end\n')

    rawset(_G, 'WARN', oldWarn)
    Api.Clear()
    Safe.Reset()
    table.insert(out, 1, failed == 0 and 'ALL OK' or (failed .. ' FAIL'))
    return table.concat(out, '\n')
end
