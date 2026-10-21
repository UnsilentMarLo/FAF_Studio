-- Mission import: shows a hand-written mission (a campaign map whose `_script.lua` was written by hand) in the mission editor WITHOUT touching the script.
-- The script is read as TEXT and never executed; strings and comments are blanked first, so a keyword, a bracket or a call inside a string or a comment is ignored.
--
--   Parse(text)                 -> outline of a `_script.lua`: { lineCount, assignments, stages, functions, objectives, triggers, helpers, imports, dialogueRefs, options, difficulty, referenced, notes }
--     stages        { { number, name, entry (function name), line } } sorted by number; a stage is a number `ScenarioInfo.MissionNumber = N` is set to (or a function named IntroMissionN / StartMissionN)
--     functions     { { name, line, endLine, stage (number or nil), how = 'sets' | 'name' | 'called' | nil, role } } named functions, in file order
--     objectives    { { call, name, var, otype, complete, title, titleExpr, description, descriptionExpr, group, line, fn, stage } }   Objectives.* calls with their literal arguments
--     triggers      { { kind, target, callback, line, fn, stage } }      ScenarioFramework.Create...Trigger(callback, ...), x:Add...Callback(...), taunt managers
--     helpers       { { name, kind = 'ai module' | 'opai' | 'platoon', count, line, stage } }       names only
--     imports       { { var, path, line, ai } }       import('...') calls
--     dialogueRefs  { { name, count, line, stage } }  ScenarioFramework.Dialogue(<table>, ...)
--     options       { { key, count, line } }          ScenarioInfo.Options.<key>;   difficulty = { uses, branches, line }
--   Stages(outline)             -> list of model stages for mission.lua Data.stages: { name, failsafe = 0, enter = {}, ready = {}, imported = true, info = { ... } } (stage 0 = the script's own setup)
--   Rows(info)                  -> display rows { text, extra, kind } of one imported stage (the Stages panel shows them instead of nodes)
--   ParseStrings(text)          -> list of dialogues { name, imported = true, lines = { { text, speaker, seconds, vid, bank, cue, faction, phase } } } of a `_strings.lua`
--   Mask(text)                  -> plain, code: the text with strings + comments blanked / with comments blanked (same length, same newlines)
--
-- Nothing here imports another module: the parser is plain Lua 5.0 text work and runs in the self test without a map.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

WHY = 'This stage was imported from the hand-written script of the map and is read-only: the editor never rewrites or compiles it. Edit the script file in a text editor.'

local KEYWORD = {}
for _, k in { 'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while' } do
    KEYWORD[k] = true
end

-- calls that make or steer platoons: names only, listed as helpers
local PLATOON_CALLS = {}
for _, k in { 'CreateArmyGroupAsPlatoon', 'CreateArmyGroupAsPlatoonVeteran', 'CreatePlatoon', 'PlatoonPatrolChain', 'PlatoonMoveChain', 'PlatoonAttackChain', 'PlatoonPatrolRoute',
              'PlatoonMoveRoute', 'PlatoonAttackRoute', 'GroupPatrolChain', 'GroupMoveChain', 'GroupAttackChain', 'GroupPatrolRoute', 'MakePlatoon', 'AssignUnitsToPlatoon',
              'ForkAIThread', 'SetPlatoonAI', 'DisbandPlatoon' } do
    PLATOON_CALLS[k] = true
end

local function Trim(s)
    s = string.gsub(s, '^%s+', '')
    s = string.gsub(s, '%s+$', '')
    return s
end

local function Blank(s) return (string.gsub(s, '[^\n]', ' ')) end

local function Unescape(s)
    s = string.gsub(s, '\\(.)', function(c)
        if c == 'n' then return '\n' end
        if c == 't' then return '\t' end
        return c
    end)
    return s
end

-- ---- masking ---------------------------------------------------------------------------------------------------------------------------------------

--- Returns two texts as long as `text`: plain (strings and comments blanked, the quotes of a string kept) and code (comments blanked, strings kept). Newlines stay, so a position
--- and its line number are the same in all three.
function Mask(text)
    local plain, code = {}, {}
    local len = string.len(text)
    local copied = 1
    local i = 1
    while i <= len do
        local s, _, ch = string.find(text, '([%-"\'%[])', i)
        if not s then break end
        local stop, kind
        if ch == '-' then
            if string.sub(text, s + 1, s + 1) == '-' then
                kind = 'comment'
                local _, opened, eq = string.find(text, '^%[(=*)%[', s + 2)
                if opened then
                    local _, closed = string.find(text, ']' .. eq .. ']', opened + 1, true)
                    stop = closed or len
                else
                    local nl = string.find(text, '\n', s + 2, true)
                    stop = nl and (nl - 1) or len
                end
            end
        elseif ch == '[' then
            local _, opened, eq = string.find(text, '^%[(=*)%[', s)
            if opened then
                kind = 'long'
                local _, closed = string.find(text, ']' .. eq .. ']', opened + 1, true)
                stop = closed or len
            end
        else
            -- a quoted string ends at its closing quote, or at the end of the line when it is not closed
            kind = 'string'
            local k = s + 1
            local seek = '[\\\n' .. ch .. ']'
            stop = len
            while true do
                local j = string.find(text, seek, k)
                if not j then break end
                local cj = string.sub(text, j, j)
                if cj == '\\' then
                    k = j + 2
                elseif cj == '\n' then
                    stop = j - 1
                    break
                else
                    stop = j
                    break
                end
            end
        end
        if kind then
            if s > copied then
                local piece = string.sub(text, copied, s - 1)
                table.insert(plain, piece)
                table.insert(code, piece)
            end
            local region = string.sub(text, s, stop)
            if kind == 'comment' then
                local b = Blank(region)
                table.insert(plain, b)
                table.insert(code, b)
            elseif kind == 'long' then
                table.insert(plain, Blank(region))
                table.insert(code, region)
            else
                if string.len(region) >= 2 and string.sub(region, -1) == ch then
                    table.insert(plain, ch .. Blank(string.sub(region, 2, -2)) .. ch)
                else
                    table.insert(plain, Blank(region))
                end
                table.insert(code, region)
            end
            copied = stop + 1
            i = stop + 1
        else
            i = s + 1
        end
    end
    if copied <= len then
        local piece = string.sub(text, copied, len)
        table.insert(plain, piece)
        table.insert(code, piece)
    end
    return table.concat(plain), table.concat(code)
end

--- A function that gives the line number (1 based) of a position in `text`.
local function LineIndex(text)
    local newlines = {}
    local at = 0
    while true do
        at = string.find(text, '\n', at + 1, true)
        if not at then break end
        table.insert(newlines, at)
    end
    return function(pos)
        local lo, hi, before = 1, table.getn(newlines), 0
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if newlines[mid] < pos then
                before = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        return before + 1
    end
end

--- Position of the bracket that closes the one at `open` (in a masked text), or nil.
local function CloseOf(plain, open, limit)
    local depth = 0
    local i = open
    local stopAt = math.min(string.len(plain), open + (limit or 30000))
    while i <= stopAt do
        local s = string.find(plain, '[%(%)%{%}%[%]]', i)
        if not s or s > stopAt then return nil end
        local c = string.sub(plain, s, s)
        if c == '(' or c == '{' or c == '[' then
            depth = depth + 1
        else
            depth = depth - 1
            if depth == 0 then return s end
        end
        i = s + 1
    end
    return nil
end

--- The comma separated items between two positions of a masked text: a list of { from, to } (empty items are dropped).
local function Items(plain, from, to)
    local items = {}
    local depth, start = 0, from
    local i = from
    local function Add(a, b)
        if b >= a and string.find(string.sub(plain, a, b), '%S') then table.insert(items, { a, b }) end
    end
    while i <= to do
        local s = string.find(plain, '[%(%)%{%}%[%],]', i)
        if not s or s > to then break end
        local c = string.sub(plain, s, s)
        if c == '(' or c == '{' or c == '[' then
            depth = depth + 1
        elseif c == ')' or c == '}' or c == ']' then
            depth = depth - 1
        elseif depth == 0 then
            Add(start, s - 1)
            start = s + 1
        end
        i = s + 1
    end
    Add(start, to)
    return items
end

--- The text of an item: its value when it is one string literal (second result true), else the expression as written (cut to 80 characters).
local function Literal(plain, code, a, b)
    local p = Trim(string.sub(plain, a, b))
    local c = Trim(string.sub(code, a, b))
    local q = string.sub(p, 1, 1)
    if (q == '"' or q == "'") and string.len(p) >= 2 and string.sub(p, -1) == q and not string.find(string.sub(p, 2, -2), '%S') then
        return Unescape(string.sub(c, 2, -2)), true
    end
    c = string.gsub(c, '%s+', ' ')
    if string.len(c) > 80 then c = string.sub(c, 1, 77) .. '...' end
    return c, false
end

-- ---- the script ------------------------------------------------------------------------------------------------------------------------------------

--- The stage number a function name points at (IntroMission2NIS, StartMission3, M2CheatEconomy, SetupFooM1Taunt, Stage4), or nil.
local function NumberInName(name)
    local _, _, n = string.find(name, 'Mission(%d+)')
    if not n then _, _, n = string.find(name, '^M(%d+)[%u_%d]') end
    if not n then _, _, n = string.find(name, '%lM(%d+)%u') end
    if not n then _, _, n = string.find(name, '^Stage(%d+)') end
    return n and tonumber(n)
end

local function IsAiPath(path)
    local lower = string.lower(path or '')
    return string.find(lower, 'ai%.lua$') ~= nil or string.find(lower, '/opai/', 1, true) ~= nil or string.find(lower, 'basemanager', 1, true) ~= nil
end

--- The name an Objectives call creates through, or nil when the callee is no objective creator.
local function ObjectiveCall(callee, last)
    if string.find(callee, '^Objectives%.[%w_]+$') or string.find(callee, '^ScenarioFramework%.Objectives%.[%w_]+$') then return last end
    if string.find(callee, '^ScenarioFramework%.[%w_]+$') and string.find(last, 'Objective', 1, true) then return last end
    return nil
end

function Parse(text)
    text = text or ''
    local plain, code = Mask(text)
    local LineOf = LineIndex(text)
    local len = string.len(plain)
    local o = {
        lineCount = LineOf(len), assignments = {}, stages = {}, functions = {}, objectives = {}, triggers = {}, helpers = {}, imports = {}, dialogueRefs = {},
        options = {}, difficulty = { uses = 0, branches = 0 }, referenced = {}, notes = {},
    }
    local frames = {}
    local refs = {}                -- function name -> { name = true }: the plain names its body mentions
    local aiAlias = {}
    local helperAt, dialogueAt, optionAt = {}, {}, {}

    local function Owner()
        local top = frames[table.getn(frames)]
        return top and top.owner
    end

    local function Target(s)
        local seg = string.sub(plain, math.max(1, s - 100), s - 1)
        local _, _, v = string.find(seg, '([%a_][%w_%.]*)%s*=%s*$')
        return v
    end

    local function Helper(name, kind, line, owner)
        local h = helperAt[name]
        if h then
            h.count = h.count + 1
        else
            h = { name = name, kind = kind, count = 1, line = line, fn = owner }
            helperAt[name] = h
            table.insert(o.helpers, h)
        end
    end

    local function Call(callee, s, paren, line, owner)
        local close = CloseOf(plain, paren)
        local items = close and Items(plain, paren + 1, close - 1) or {}
        local _, _, last = string.find(callee, '([%w_]+)$')
        last = last or callee
        local _, _, first = string.find(callee, '^([%a_][%w_]*)')
        local function Arg(n)
            local it = items[n]
            if not it then return nil, false end
            return Literal(plain, code, it[1], it[2])
        end
        local objective = ObjectiveCall(callee, last)
        if callee == 'import' then
            local path, literal = Arg(1)
            local var = Target(s)
            local ai = literal and IsAiPath(path) or false
            table.insert(o.imports, { var = var, path = literal and path or nil, line = line, ai = ai })
            if ai and var then aiAlias[var] = true end
        elseif objective then
            local ob = { call = callee, name = objective, var = Target(s), line = line, fn = owner }
            if objective == 'CreateGroup' then
                ob.group = true
                local v, lit = Arg(1)
                if lit then ob.title = v else ob.titleExpr = v end
            else
                local v, lit = Arg(1)
                if lit then ob.otype = v end
                v, lit = Arg(2)
                if lit then ob.complete = v end
                v, lit = Arg(3)
                if lit then ob.title = v elseif v then ob.titleExpr = v end
                v, lit = Arg(4)
                if lit then ob.description = v elseif v then ob.descriptionExpr = v end
            end
            table.insert(o.objectives, ob)
        elseif string.find(last, '^Create%a*Trigger$') or string.find(last, '^Add%a*Callback$') or string.find(last, '^Add%a*Taunt$') then
            local v, lit = Arg(1)
            local callback = v
            if v and not lit and string.find(v, '^function') then callback = '(inline function)' end
            if v and not lit and string.find(last, 'Taunt$') then callback = v end
            local target
            if string.find(callee, ':', 1, true) then _, _, target = string.find(callee, '^(.*):[%w_]+$') end
            table.insert(o.triggers, { kind = last, target = target, callback = callback, line = line, fn = owner })
        elseif last == 'Dialogue' and items[1] then
            local p = Trim(string.sub(plain, items[1][1], items[1][2]))
            if string.find(p, '^[%a_][%w_%.]*$') then
                local d = dialogueAt[p]
                if d then d.count = d.count + 1 else
                    d = { name = p, count = 1, line = line, fn = owner }
                    dialogueAt[p] = d
                    table.insert(o.dialogueRefs, d)
                end
            end
        end
        -- the AI / platoon helpers: names only
        if first and aiAlias[first] and callee ~= first then
            Helper(callee, 'ai module', line, owner)
        elseif string.find(callee, 'OpAI', 1, true) or string.find(callee, 'BaseManager', 1, true) then
            Helper(callee, 'opai', line, owner)
        elseif PLATOON_CALLS[last] then
            Helper(callee, 'platoon', line, owner)
        end
    end

    local pos = 1
    while pos <= len do
        local s, e = string.find(plain, '[%a_][%w_]*', pos)
        if not s then break end
        local prev = (s > 1) and string.sub(plain, s - 1, s - 1) or ''
        local word = string.sub(plain, s, e)
        if string.find(prev, '%d') or ((prev == '.' or prev == ':') and string.sub(plain, s - 2, s - 1) ~= '..') then
            -- the end of a number (1e5), or a field after an expression (f().x): not a name of ours
            pos = e + 1
        elseif KEYWORD[word] then
            pos = e + 1
            if word == 'function' then
                local _, ne, fname = string.find(plain, '^%s*([%a_][%w_%.:]*)', e + 1)
                local owner = Owner()
                if fname then
                    pos = ne + 1
                    owner = fname
                    if not refs[fname] then refs[fname] = {} end
                end
                table.insert(frames, { fn = true, name = fname, owner = owner, line = LineOf(s) })
            elseif word == 'if' or word == 'do' or word == 'repeat' then
                table.insert(frames, { fn = false, owner = Owner() })
            elseif word == 'end' or word == 'until' then
                local top = table.remove(frames)
                if top and top.fn and top.name then
                    table.insert(o.functions, { name = top.name, line = top.line, endLine = LineOf(s) })
                end
            end
        else
            local ee = e
            while true do
                local _, e2 = string.find(plain, '^[%.:][%a_][%w_]*', ee + 1)
                if not e2 then break end
                ee = e2
            end
            local name = string.sub(plain, s, ee)
            local line = LineOf(s)
            local owner = Owner()
            pos = ee + 1
            local _, paren = string.find(plain, '^%s*%(', ee + 1)
            if paren then Call(name, s, paren, line, owner) end
            if owner and refs[owner] and not string.find(name, '[%.:]') then refs[owner][name] = true end
            if name == 'ScenarioInfo.MissionNumber' then
                local _, _, n = string.find(plain, '^%s*=%s*(%d+)', ee + 1)
                if n then
                    table.insert(o.assignments, { n = tonumber(n), line = line, fn = owner })
                else
                    local _, _, m = string.find(plain, '^%s*[=~<>]=?%s*(%d+)', ee + 1)
                    m = m and tonumber(m)
                    if m and not o.referenced[m] then o.referenced[m] = line end
                end
            elseif name == 'Difficulty' or name == 'ScenarioInfo.Options.Difficulty' then
                local d = o.difficulty
                d.uses = d.uses + 1
                d.line = d.line or line
                if string.find(plain, '^%s*[=~<>]=', ee + 1) or string.find(plain, '^%s*[<>]', ee + 1) then d.branches = d.branches + 1 end
            end
            local _, _, key = string.find(name, '^ScenarioInfo%.Options%.([%w_]+)$')
            if key and key ~= 'Difficulty' then
                local op = optionAt[key]
                if op then op.count = op.count + 1 else
                    op = { key = key, count = 1, line = line }
                    optionAt[key] = op
                    table.insert(o.options, op)
                end
            end
        end
    end

    -- which stage does each function belong to: the function that sets MissionNumber, a name that carries the number, then the single stage that calls it
    table.sort(o.functions, function(a, b) return a.line < b.line end)
    local byName, names = {}, {}
    for _, f in o.functions do
        if not byName[f.name] then
            byName[f.name] = f
            table.insert(names, f.name)
        end
    end
    table.sort(names)
    local stageOf, howOf = {}, {}
    for _, a in o.assignments do
        if a.fn and byName[a.fn] and not stageOf[a.fn] then
            stageOf[a.fn] = a.n
            howOf[a.fn] = 'sets'
        end
    end
    for _, name in names do
        if not stageOf[name] then
            local n = NumberInName(name)
            if n then
                stageOf[name] = n
                howOf[name] = 'name'
            end
        end
    end
    for round = 1, 5 do
        local changed = false
        for _, name in names do
            if not stageOf[name] then
                local callers, unstaged, found, many = 0, false, nil, false
                for _, caller in names do
                    if caller ~= name and refs[caller] and refs[caller][name] then
                        callers = callers + 1
                        local cs = stageOf[caller]
                        if not cs then unstaged = true
                        elseif found and found ~= cs then many = true
                        else found = cs end
                    end
                end
                if callers > 0 and not unstaged and not many and found then
                    stageOf[name] = found
                    howOf[name] = 'called'
                    changed = true
                end
            end
        end
        if not changed then break end
    end

    -- the stages: numbers that are set somewhere, or that an IntroMissionN / StartMissionN function belongs to
    local stageAt = {}
    local function Stage(n, fname)
        if not stageAt[n] then
            stageAt[n] = { number = n, name = 'Mission ' .. n }
            table.insert(o.stages, stageAt[n])
        end
        if fname and not stageAt[n].entry then
            stageAt[n].entry = fname
            stageAt[n].line = byName[fname] and byName[fname].line
        end
    end
    for _, a in o.assignments do Stage(a.n, a.fn) end
    for _, name in names do
        if howOf[name] == 'name' and (string.find(name, '^Intro') or string.find(name, '^Start')) and string.find(name, 'Mission%d') then Stage(stageOf[name], name) end
    end
    table.sort(o.stages, function(a, b) return a.number < b.number end)
    for _, f in o.functions do
        f.stage = stageOf[f.name]
        f.how = howOf[f.name]
        if f.how == 'sets' then f.role = 'enters stage ' .. f.stage
        elseif string.find(f.name, '^Intro') then f.role = 'intro'
        elseif string.find(f.name, '^Start') then f.role = 'start'
        elseif f.how == 'called' then f.role = 'called from stage ' .. f.stage
        else f.role = 'helper' end
    end
    local function StageOfFn(rec)
        rec.stage = rec.fn and stageOf[rec.fn] or nil
    end
    for _, l in { o.objectives, o.triggers, o.helpers, o.dialogueRefs } do
        for _, rec in l do StageOfFn(rec) end
    end
    local numbered = {}
    for _, st in o.stages do numbered[st.number] = true end
    for n, line in o.referenced do
        if not numbered[n] then table.insert(o.notes, 'MissionNumber ' .. n .. ' is checked (line ' .. line .. ') but nothing sets it') end
    end
    table.sort(o.notes)
    return o
end

-- ---- the stages of the model -----------------------------------------------------------------------------------------------------------------------

--- The imported stages for mission.lua: one per mission number, and a first one (number 0) for what the script does outside any stage (OnPopulate, OnStart, the AI bases it starts ...).
function Stages(o)
    local list = {}
    local function Info(n, name)
        return { number = n, name = name, functions = {}, objectives = {}, triggers = {}, helpers = {}, dialogueRefs = {}, imports = {}, options = {}, notes = {} }
    end
    local infoOf = {}
    local setup = Info(0, 'Script setup')
    infoOf[0] = setup
    local ordered = {}
    for _, st in o.stages do
        local info = Info(st.number, st.name)
        info.entry, info.line = st.entry, st.line
        infoOf[st.number] = info
        table.insert(ordered, info)
    end
    local function Into(n) return infoOf[n or 0] or setup end
    for _, f in o.functions do table.insert(Into(f.stage).functions, f) end
    for _, ob in o.objectives do table.insert(Into(ob.stage).objectives, ob) end
    for _, t in o.triggers do table.insert(Into(t.stage).triggers, t) end
    for _, h in o.helpers do table.insert(Into(h.stage).helpers, h) end
    for _, d in o.dialogueRefs do table.insert(Into(d.stage).dialogueRefs, d) end
    for _, imp in o.imports do table.insert(setup.imports, imp) end
    setup.options = o.options
    setup.difficulty = o.difficulty
    setup.notes = o.notes
    setup.lineCount = o.lineCount
    local used = table.getn(setup.functions) + table.getn(setup.objectives) + table.getn(setup.triggers) + table.getn(setup.helpers) + table.getn(setup.dialogueRefs)
        + table.getn(setup.imports) + table.getn(setup.options) + table.getn(setup.notes) + o.difficulty.uses
    if used > 0 then table.insert(ordered, 1, setup) end
    for _, info in ordered do
        table.insert(list, { name = info.name, failsafe = 0, enter = {}, ready = {}, imported = true, info = info })
    end
    return list
end

-- ---- display rows ----------------------------------------------------------------------------------------------------------------------------------

--- The rows of one imported stage: what the script does there, with line numbers. kind: 'note' | 'function' | 'objective' | 'trigger' | 'ai' | 'detail'.
function Rows(info)
    local rows = {}
    local function Add(text, extra, kind) table.insert(rows, { text = text, extra = extra, kind = kind or 'detail' }) end
    if not info then return rows end
    Add('imported from the script: read-only (never rewritten or compiled)', '', 'note')
    if info.number and info.number > 0 then
        Add('stage ' .. info.number .. (info.entry and (' starts in ' .. info.entry) or ''), info.line and ('line ' .. info.line) or '', 'note')
    else
        Add('what the script does outside the numbered stages', info.lineCount and (info.lineCount .. ' lines') or '', 'note')
    end
    for _, f in info.functions do
        local other = (f.stage and info.number ~= f.stage) and ('  [mission ' .. f.stage .. ']') or ''
        Add('function ' .. f.name, 'line ' .. f.line .. '-' .. f.endLine .. '  ' .. tostring(f.role or '') .. other, 'function')
    end
    for _, ob in info.objectives do
        local label = ob.group and 'objective group' or ('objective' .. (ob.otype and (' (' .. ob.otype .. ')') or ''))
        local title = ob.title or ob.titleExpr or '?'
        Add(label .. ': ' .. title, 'line ' .. ob.line, 'objective')
        local detail = (ob.var and (ob.var .. ' = ') or '') .. ob.call
        local d = ob.description or ob.descriptionExpr
        if d and d ~= '' then detail = detail .. '  ' .. d end
        Add('    ' .. detail, ob.fn and ('in ' .. ob.fn) or '', 'detail')
    end
    for _, t in info.triggers do
        Add('trigger ' .. t.kind .. (t.callback and (': ' .. t.callback) or '') .. (t.target and ('  on ' .. t.target) or ''), 'line ' .. t.line, 'trigger')
    end
    for _, h in info.helpers do
        Add(h.kind .. ': ' .. h.name .. (h.count > 1 and ('  x' .. h.count) or ''), 'line ' .. h.line, 'ai')
    end
    for _, d in info.dialogueRefs do
        Add('dialogue ' .. d.name .. (d.count > 1 and ('  x' .. d.count) or ''), 'line ' .. d.line, 'detail')
    end
    for _, imp in info.imports do
        if imp.ai then Add('imports ' .. tostring(imp.var) .. ' = ' .. tostring(imp.path), 'line ' .. imp.line, 'ai') end
    end
    local diff = info.difficulty
    if diff and diff.uses > 0 then
        Add('difficulty: used ' .. diff.uses .. ' times, ' .. diff.branches .. ' comparisons', diff.line and ('line ' .. diff.line) or '', 'detail')
    end
    for _, op in info.options do
        Add('option ScenarioInfo.Options.' .. op.key .. (op.count > 1 and ('  x' .. op.count) or ''), 'line ' .. op.line, 'detail')
    end
    for _, n in info.notes do Add(n, '', 'note') end
    return rows
end

-- ---- the strings file ------------------------------------------------------------------------------------------------------------------------------

--- Dialogue tables of a `_strings.lua` (BriefingData, objective and dialogue tables with lines { text, character, vid, bank, cue, faction ... }) and, in one dialogue called
--- 'Text strings', its plain string assignments. Read as text, never executed. The `[{i Speaker}]: ` prefix of a line becomes the speaker.
function ParseStrings(text)
    local dialogues = {}
    local t = '\n' .. (text or '')
    local plain, code = Mask(t)
    local texts = { name = 'Text strings', imported = true, lines = {} }
    local pos = 1
    local guard = 0
    while guard < 20000 do
        guard = guard + 1
        local s, _, name, at = string.find(plain, '\n([%a_][%w_]*)[ \t]*=[ \t]*()', pos)
        if not s then break end
        local ch = string.sub(plain, at, at)
        pos = at
        if ch == '{' then
            local close = CloseOf(plain, at, 400000)
            if not close then break end
            pos = close + 1
            local lines = {}
            for _, entry in Items(plain, at + 1, close - 1) do
                local ob = string.find(plain, '{', entry[1], true)
                if ob and ob <= entry[2] then
                    local ce = CloseOf(plain, ob)
                    if ce and ce <= entry[2] then
                        local line = { text = '', speaker = '', seconds = 5 }
                        local hasText = false
                        for _, field in Items(plain, ob + 1, ce - 1) do
                            local _, ke, key = string.find(plain, '^%s*([%a_][%w_]*)%s*=%s*', field[1])
                            if key and ke < field[2] then
                                local v = Literal(plain, code, ke + 1, field[2])
                                if key == 'text' then line.text = v hasText = true
                                elseif key == 'character' then line.speaker = v
                                elseif key == 'delay' then line.seconds = tonumber(v) or line.seconds
                                elseif key == 'vid' or key == 'bank' or key == 'cue' or key == 'faction' then line[key] = v
                                elseif key == 'phase' then line.phase = tonumber(v) or v end
                            end
                        end
                        if hasText then
                            if line.speaker == '' then
                                local _, _, who, rest = string.find(line.text, '^%[{i ([^}]*)}%]: ?(.*)$')
                                if who then
                                    line.speaker = who
                                    line.text = rest
                                end
                            end
                            table.insert(lines, line)
                        end
                    end
                end
            end
            if table.getn(lines) > 0 then table.insert(dialogues, { name = name, imported = true, lines = lines }) end
        elseif ch == "'" or ch == '"' then
            local eol = string.find(plain, '\n', at, true) or (string.len(plain) + 1)
            local v, lit = Literal(plain, code, at, eol - 1)
            if lit then table.insert(texts.lines, { text = v, speaker = name, seconds = 0 }) end
            pos = eol
        end
    end
    if table.getn(texts.lines) > 0 then table.insert(dialogues, texts) end
    return dialogues
end
