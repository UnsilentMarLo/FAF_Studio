-- Hostile values in every parameter of every mission node, and in the places around nodes (stage names, dialogue lines, bases), and hostile sidecar files.
--   return import('/lua/editor/selftest_missionfuzz.lua').Run()
--
-- The rule the compiler must keep: whatever a user types, the structure of the generated script does not change. For every node type and parameter, the script made with a hostile value
-- (quotes, newlines, backslashes, `]]`, NUL, unicode, nil, nan, inf, tables, a very long text ...) must have exactly the same CODE as the script made with an ordinary value once the
-- string literals and comments are taken out: nothing a user typed becomes code (except in a Raw Lua node and in the category expressions, whose text must then be one valid expression).
-- Every such script must still load, and no node may be silently dropped (Problems stays empty) unless it is a Raw Lua node with code that does not compile.
--
-- Lua 5.0 dialect.

local M = import('/lua/editor/mission.lua')

local out, failed = {}, 0
local function Check(ok, text)
    if not ok then failed = failed + 1 end
    if not ok or table.getn(out) < 400 then table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text) end
end

--- The script text without string literals and comments (a real scan: a comment may hold a quote, a string may hold `--`), numbers and variable names normalised: what is left is
--- the structure of the code.
function Skeleton(text)
    local out = {}
    local i, n = 1, string.len(text)
    while i <= n do
        local s = string.find(text, "['%-]", i)
        if not s then
            table.insert(out, string.sub(text, i))
            break
        end
        if s > i then table.insert(out, string.sub(text, i, s - 1)) end
        if string.sub(text, s, s) == "'" then
            local j = s + 1
            while j <= n do
                local d = string.sub(text, j, j)
                if d == '\\' then j = j + 2
                elseif d == "'" then break
                else j = j + 1 end
            end
            table.insert(out, "''")
            i = j + 1
        elseif string.sub(text, s + 1, s + 1) == '-' then
            local j = string.find(text, '\n', s, true)
            if not j then break end
            i = j       -- (the newline stays)
        else
            table.insert(out, '-')
            i = s + 1
        end
    end
    local bare = table.concat(out)
    bare = string.gsub(bare, '%d+%.?%d*[eE][%+%-]?%d+', '0')
    bare = string.gsub(bare, '%d+%.?%d*', '0')
    bare = string.gsub(bare, '%-0', '0')       -- (the sign of a number)
    bare = string.gsub(bare, 'V%.[%a_][%w_]*', 'V.x')       -- (a variable name is code by design)
    bare = string.gsub(bare, 'Base%.(%a+)_[%w_]+', 'Base.%1_x')
    return bare
end

local NAN = 0 / 0
local INF = 1 / 0

--- The hostile values; `text` ones are strings.
Hostile = {
    "x'; os.exit() --", "]]; os.exit() --[[", "line one\nline two", "line one\r\nline two", '\\', "\\'", "'", '"', 'end end end', 'a\0b', 'a\1b\27c', '\255\254',
    'ünï☃ \226\128\139', string.rep('a', 5000), '', '   ', '-- comment', '--[[ x ]]', '-- <<< EDITOR MISSION', '-- >>> EDITOR MISSION v1', '%s%d%', '$1', '[[', ']]',
    NAN, INF, -INF, 1e308, -1e308, 0, -1, 1.5e-30, 'NaN', 'inf', '0x10', '1e999',
    true, false, {}, { 1, 2 }, { x = 1 },
}

local function Label(v)
    local t = type(v)
    if t == 'string' then
        local s = string.gsub(string.sub(v, 1, 18), '%c', '?')
        return 'string "' .. s .. '"' .. (string.len(v) > 18 and ('(' .. string.len(v) .. ')') or '')
    end
    return t .. ' ' .. tostring(v)
end

local function Model(stage)
    return { mode = 'both', stages = { stage }, bases = {}, dialogues = { { name = 'INTRO', lines = { { text = 'hello', speaker = '', seconds = 5 } } } } }
end

local function Compile(flavor)
    local ok, text = pcall(M.Compile, true, { test = flavor })
    return ok, text
end

--- The ordinary values of a parameter whose scripts a hostile value may legitimately equal (in code): any valid number, both booleans, every choice, an empty and an ordinary text.
local function References(p)
    if p.kind == 'number' then return { p.default or 1, 0, 1, 2, -1, 100000 } end
    if p.kind == 'bool' then return { true, false } end
    if p.kind == 'choice' then return p.choices or {} end
    if p.kind == 'var' then return { 'UNSET', '' } end
    if p.kind == 'text' and (p.key == 'category' or p.key == 'categories') then return { p.default or 'categories.ALLUNITS', '' } end
    return { 'x', '' }
end

local function Variants(p)
    local list = {}
    for _, h in Hostile do table.insert(list, h) end
    table.insert(list, '__ABSENT__')
    return list
end

--- A node of type `t` with the defaults, parameter `key` set to `value` (nil = left out).
local function NodeWith(t, key, value)
    local n = M.NewNode(t.id)
    -- the usual values that make a node emit its main form
    for _, p in t.params do
        if n[p.key] == nil and p.kind ~= 'bool' and p.kind ~= 'number' and p.kind ~= 'choice' then n[p.key] = 'x' end
    end
    if value == '__ABSENT__' then n[key] = nil else n[key] = value end
    if t.container then
        n.children = { { type = 'set_flag', flag = 'F', value = true } }
    end
    return n
end

--- Hostile values in the parameters of every node type.
local function NodeFuzz()
    local types = 0
    for _, t in M.Catalogue do
        types = types + 1
        for _, p in t.params do
            local codeParam = (t.id == 'raw' and p.key == 'code')
            if not codeParam then
                -- the scripts of the ordinary values
                local refs = {}
                local refBad
                for _, v in References(p) do
                    M.Data = Model({ name = 'S', failsafe = 0, enter = {}, ready = { NodeWith(t, p.key, v) } })
                    local ok, text = Compile(true)
                    if ok then refs[Skeleton(text)] = true else refBad = tostring(text) end
                end
                if refBad then Check(false, t.id .. '.' .. p.key .. ': Compile raised with an ordinary value: ' .. refBad) end
                local bad = 0
                local isExpr = (p.kind == 'text' and (p.key == 'category' or p.key == 'categories'))
                for _, h in Variants(p) do
                  -- (a category that is one valid expression IS code, by design: only what is not one must stay out of the script)
                  if not (isExpr and (type(h) == 'number' or (type(h) == 'string' and h ~= '' and M.ExprOk(h)))) then
                    M.Data = Model({ name = 'S', failsafe = 0, enter = {}, ready = { NodeWith(t, p.key, h) } })
                    for _, flavor in { true, false } do
                        local ok, text = Compile(flavor)
                        local what = t.id .. '.' .. p.key .. ' = ' .. Label(h) .. (flavor and ' (test run)' or ' (saved map)')
                        if not ok then
                            Check(false, what .. ': Compile raised: ' .. tostring(text))
                            bad = bad + 1
                        elseif loadstring(text) == nil then
                            Check(false, what .. ': the script does not load')
                            bad = bad + 1
                        elseif flavor and not refs[Skeleton(text)] then
                            Check(false, what .. ': the code of the script is not the code of any ordinary value')
                            bad = bad + 1
                        elseif table.getn(M.Problems) > 0 then
                            Check(false, what .. ': a node was left out (' .. M.Problems[1].text .. ')')
                            bad = bad + 1
                        end
                    end
                  end
                end
                if bad == 0 then Check(true, t.id .. '.' .. p.key .. ' (' .. p.kind .. ') keeps the code of the script under ' .. table.getn(Hostile) .. ' hostile values') end
            end
        end
    end
    return types
end

--- A Raw Lua node with hostile code never takes the others down.
local function RawFuzz()
    for _, code in { 'this is not lua', 'end end', 'if x then', "local s = '", 'return', 'return 1 2', 'x = [[', '', 'for', '\0', string.rep('(', 500) } do
        M.Data = Model({ name = 'S', failsafe = 0, enter = {}, ready = { { type = 'raw', code = code }, { type = 'set_flag', flag = 'AFTER', value = true } } })
        local ok, text = Compile(true)
        local shown = string.gsub(string.sub(code, 1, 14), '%c', '?')
        Check(ok and loadstring(text) ~= nil, 'Raw Lua "' .. shown .. '" cannot stop the script from loading')
        if ok then Check(string.find(text, "'AFTER'", 1, true) ~= nil, 'and the node after Raw Lua "' .. shown .. '" is still in the script') end
    end
end

--- Stage names, failsafe, dialogue tables and bases.
local function ModelFuzz()
    local baseStage = { name = 'S', failsafe = 0, enter = {}, ready = { { type = 'dialogue_table', name = 'INTRO' } } }
    M.Data = Model(baseStage)
    local ok, text = Compile(true)
    local ref = ok and Skeleton(text)
    local bad = 0
    for _, h in Hostile do
        for _, field in { 'name', 'failsafe' } do
            local stage = { name = 'S', failsafe = 0, enter = {}, ready = { { type = 'dialogue_table', name = 'INTRO' } } }
            stage[field] = h
            M.Data = Model(stage)
            local ok2, t2 = Compile(true)
            local same = ok2 and loadstring(t2) ~= nil and (field == 'failsafe' or Skeleton(t2) == ref)
            if not same then Check(false, 'stage ' .. field .. ' = ' .. Label(h) .. ' changes or breaks the script') bad = bad + 1 end
        end
        for _, field in { 'text', 'speaker', 'seconds', 'bank', 'cue', 'vid', 'faction' } do
            local d = { name = 'INTRO', lines = { { text = 'hello', speaker = '', seconds = 5 } } }
            d.lines[1][field] = h
            M.Data = { mode = 'both', stages = { baseStage }, bases = {}, dialogues = { d } }
            local ok2, t2 = Compile(true)
            -- (a bank / cue / vid / faction that is set adds a field to the line: that is the one legitimate change)
            local dx = { name = 'INTRO', lines = { { text = 'hello', speaker = '', seconds = 5 } } }
            dx.lines[1][field] = 'x'
            M.Data = { mode = 'both', stages = { baseStage }, bases = {}, dialogues = { dx } }
            local okx, tx = Compile(true)
            if not (ok2 and loadstring(t2) ~= nil and (Skeleton(t2) == ref or (okx and Skeleton(t2) == Skeleton(tx)))) then Check(false, 'dialogue line ' .. field .. ' = ' .. Label(h) .. ' changes or breaks the script') bad = bad + 1 end
        end
        local d = { name = h, lines = {} }
        M.Data = { mode = 'both', stages = { baseStage }, bases = {}, dialogues = { d } }
        local ok3, t3 = Compile(true)
        if not (ok3 and loadstring(t3) ~= nil) then Check(false, 'dialogue name = ' .. Label(h) .. ' breaks the script') bad = bad + 1 end
    end
    Check(bad == 0, 'stage names / failsafe and dialogue tables keep the script\'s code under ' .. table.getn(Hostile) .. ' hostile values')
    -- bases: every text field, and a hostile name (the base is then left out, the rest stays)
    local function Base(over)
        local b = { name = 'Alpha', army = 'Enemy', marker = 'Alpha_Marker', radius = 30, groups = { { name = 'DEF1', priority = 100 } }, engineers = { 2, 2, 2 }, assist = { 0, 0, 0 },
                    start = 'with its units', switchOn = { 'AirScouting' }, switchOff = {}, noBuild = { 'Defenses' },
                    opai = { { name = 'Attack1', ptype = 'BasicLandAttack', master = 'default', children = { 'LightTanks' }, chains = { 'PATROL' }, priority = 100, lock = 'None' } } }
        for k, v in over do b[k] = v end
        return b
    end
    local node = { type = 'base_start', base = 'Alpha' }
    M.Data = { mode = 'campaign', stages = { { name = 'S', failsafe = 0, enter = {}, ready = { node } } }, bases = { Base({}) }, dialogues = {} }
    local okb, tb = Compile(true)
    local baseRef = okb and Skeleton(tb)
    local badBase = 0
    for _, h in Hostile do
        for _, field in { 'army', 'marker', 'start' } do
            M.Data = { mode = 'campaign', stages = { { name = 'S', failsafe = 0, enter = {}, ready = { node } } }, bases = { Base({ [field] = h }) }, dialogues = {} }
            local ok2, t2 = Compile(true)
            if not (ok2 and loadstring(t2) ~= nil) then Check(false, 'base ' .. field .. ' = ' .. Label(h) .. ' breaks the script') badBase = badBase + 1
            elseif field ~= 'start' and Skeleton(t2) ~= baseRef then Check(false, 'base ' .. field .. ' = ' .. Label(h) .. ' changes the code of the script') badBase = badBase + 1 end
        end
        M.Data = { mode = 'campaign', stages = { { name = 'S', failsafe = 0, enter = {}, ready = { node } } }, bases = { Base({ name = h }), Base({ name = 'Beta' }) }, dialogues = {} }
        local ok4, t4 = Compile(true)
        if not (ok4 and loadstring(t4) ~= nil and string.find(t4, 'Base.Start_Beta', 1, true)) then Check(false, 'base name = ' .. Label(h) .. ' takes the script or the other bases down') badBase = badBase + 1 end
    end
    Check(badBase == 0, 'base fields keep the script\'s code and a bad base name only costs that base, under ' .. table.getn(Hostile) .. ' hostile values')
end

-- ---- hostile sidecar files -------------------------------------------------------------------------------------------------------------------------------

local SIDECARS = {
    { name = 'empty file', text = '', model = false },
    { name = 'no mission in it', text = 'version = 1\nEditorMods = {\n}\n', model = false },
    { name = 'syntax error', text = 'Mission = { stages = {', model = false },
    { name = 'runtime error', text = "Mission = { stages = {} }\nMission.stages.x.y = 1\n", model = false },
    { name = 'calls a function', text = "Mission = { stages = { os.exit() } }\n", model = false },
    { name = 'code in a field', text = "Mission = { stages = { { name = (function() while true do end end)() } } }\n", model = false },
    { name = 'an infinite loop', text = "Mission = { stages = {} }\nwhile true do end\n", model = false },
    { name = 'a comment', text = "Mission = { stages = {} } -- x\n", model = false },
    { name = 'mission is a number', text = 'Mission = 5\n', model = false },
    { name = 'mission is a string', text = "Mission = 'x'\n", model = false },
    { name = 'stages are a string', text = "Mission = { stages = 'x' }\n", model = true, stages = 0 },
    { name = 'stage is a number', text = "Mission = { stages = { 5, { name = 'ok', enter = {}, ready = {} } } }\n", model = true, stages = 1 },
    { name = 'nodes of wrong shapes', text = "Mission = { stages = { { name = 'S', ready = { 1, 'x', {}, { type = 5 }, { type = 'set_flag', flag = 'F', value = true } } } } }\n", model = true, stages = 1, nodes = 1 },
    { name = 'unknown node type is kept', text = "Mission = { stages = { { name = 'S', ready = { { type = 'from_the_future', x = 1 } } } } }\n", model = true, stages = 1, nodes = 1 },
    { name = 'invalid values are repaired', text = "Mission = { stages = { { name = 'S', ready = { { type = 'obj_timer', seconds = 'soon', expire = 'maybe', otype = 5, reminderSecs = {} } } } } }\n", model = true, stages = 1, nodes = 1, repaired = true },
    { name = 'children of a node that holds none', text = "Mission = { stages = { { name = 'S', ready = { { type = 'wait', seconds = 3, children = { { type = 'wait' } } } } } } }\n", model = true, stages = 1, nodes = 1 },
    { name = 'children that are not a list', text = "Mission = { stages = { { name = 'S', ready = { { type = 'trg_timer', seconds = 3, children = 'x' } } } } }\n", model = true, stages = 1, nodes = 1 },
    { name = 'bad mode and failsafe', text = "Mission = { mode = 'chaos', stages = { { name = 'S', failsafe = 'x', ready = {} } } }\n", model = true, stages = 1 },
    { name = 'bad base names', text = "Mission = { stages = {}, bases = { { name = 'a b' }, { name = 'end' }, 5, { name = 'Good', army = 'x' } } }\n", model = true, bases = 1 },
    { name = 'bad dialogues', text = "Mission = { stages = {}, dialogues = { { name = 'A', lines = { 'x', { text = 5 } } }, 5, { name = 7 } } }\n", model = true, dialogues = 1, lines = 1 },
    { name = 'a newer format', text = "Mission = { schema = 99, stages = { { name = 'S', ready = {}, extra = true } }, future = { 1 } }\n", model = true, stages = 1, schema = 99 },
    { name = 'a table as a node type', text = "Mission = { stages = { { name = 'S', ready = { { type = {} } } } } }\n", model = true, stages = 1, nodes = 0 },
    { name = 'a file with other chunks around it', text = "version = 1\nEditorMods = {\n    'abc',\n}\nGraph = os.exit()\nMission = {\n    ['stages'] = {\n        {\n            ['name'] = 'S',\n            ['ready'] = {\n            },\n        },\n    },\n}\nLayout = nonsense(\n", model = true, stages = 1 },
}

local PATH = '../mapout/_sidecar_fuzz.lua'

local function SidecarFuzz()
    for _, c in SIDECARS do
        ed_write_file(PATH, c.text)
        local ok, model, report = pcall(M.ReadSidecar, PATH)
        if not ok then
            Check(false, 'sidecar "' .. c.name .. '": reading raised: ' .. tostring(model))
        else
            if c.model == false then
                Check(model == nil, 'sidecar "' .. c.name .. '": no mission is taken from it (and nothing raised)')
            else
                Check(model ~= nil, 'sidecar "' .. c.name .. '": the mission is read')
                if model then
                    if c.stages then Check(table.getn(model.stages) == c.stages, 'sidecar "' .. c.name .. '": ' .. c.stages .. ' stage(s) kept (got ' .. table.getn(model.stages) .. ')') end
                    if c.nodes and model.stages[1] then Check(table.getn(model.stages[1].ready) == c.nodes, 'sidecar "' .. c.name .. '": ' .. c.nodes .. ' node(s) kept (got ' .. table.getn(model.stages[1].ready) .. ')') end
                    if c.bases then Check(table.getn(model.bases) == c.bases, 'sidecar "' .. c.name .. '": ' .. c.bases .. ' base(s) kept (got ' .. table.getn(model.bases) .. ')') end
                    if c.dialogues then Check(table.getn(model.dialogues) == c.dialogues, 'sidecar "' .. c.name .. '": ' .. c.dialogues .. ' dialogue(s) kept') end
                    if c.lines then Check(table.getn(model.dialogues[1].lines) == c.lines, 'sidecar "' .. c.name .. '": ' .. c.lines .. ' dialogue line(s) kept') end
                    if c.schema then Check(model.schema == c.schema, 'sidecar "' .. c.name .. '": keeps its format number ' .. c.schema) end
                    if c.repaired then
                        local n = model.stages[1].ready[1]
                        Check(n.expire == 'complete' and n.otype == 'primary' and tonumber(n.seconds) ~= nil, 'sidecar "' .. c.name .. '": the invalid values are replaced by the defaults')
                    end
                    if c.stages == 1 or c.nodes then
                        -- whatever was kept compiles to a script that loads
                        local saved = M.Data
                        M.Data = model
                        local okc, text = Compile(true)
                        M.Data = saved
                        Check(okc and loadstring(text) ~= nil, 'sidecar "' .. c.name .. '": what was kept compiles to a loadable script')
                    end
                    if c.nodes or c.repaired or c.name == 'bad base names' or c.name == 'bad dialogues' then
                        Check(report and table.getn(report) > 0, 'sidecar "' .. c.name .. '": what was dropped or repaired is reported')
                    end
                end
            end
        end
    end
    ed_write_file(PATH, '')
end

--- Edits that raise leave the model as it was.
local function EditFuzz()
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    M.AddStage('One')
    local before = M.SidecarText()
    local ok, why = M.Edit('test: raises half way', function()
        M.Data.stages[1].name = 'CHANGED'
        error('boom in an edit')
    end)
    Check(ok == nil and string.find(tostring(why), 'boom', 1, true) ~= nil, 'an edit that raises returns nil and the reason')
    Check(M.Data.stages[1].name == 'One' and M.SidecarText() == before, 'and the model is exactly as it was')
    local nan = M.SetParam(1, 'ready', 1, 'seconds', NAN)
    Check(nan == nil, 'a nan is refused as a parameter value')
    M.AddNode(1, 'ready', 'wait')
    Check(M.SetParam(1, 'ready', 1, 'seconds', INF) == nil and M.SetParam(1, 'ready', 1, 'seconds', -INF) == nil, 'so is an infinity')
end

function Run()
    out, failed = {}, 0
    local saved = M.Data
    local ok, err = pcall(function()
        local types = NodeFuzz()
        Check(types == table.getn(M.Catalogue), 'fuzzed ' .. types .. ' node types')
        RawFuzz()
        ModelFuzz()
        SidecarFuzz()
        EditFuzz()
    end)
    if not ok then Check(false, 'the fuzz run itself raised: ' .. tostring(err)) end
    M.Data = saved
    table.insert(out, failed == 0 and 'ALL PASS' or (failed .. ' FAILED'))
    return table.concat(out, '\n')
end
