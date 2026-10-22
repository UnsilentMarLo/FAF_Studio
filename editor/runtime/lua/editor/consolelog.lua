-- The data behind the Console panel (gui/panels_console.lua): every message the editor prints, kept in a ring of the last 2000 entries, plus the pure logic of the panel
-- (filter, text formats, the command line). No UI work happens here: LOG can be called thousands of times (overlay rebuilds, self tests), so an entry costs one small table and a
-- version counter; the panel looks at Version() from the shell's tick (about 4 times a second) and redraws only when it changed.
--
--   Add(level, text, source [, at])   records a message; level 'info' | 'warn' | 'error' | 'status'. Several lines become several entries, an immediate repeat (same level,
--                                     text and source as the newest entry) only raises its count (shown as "x3"), a text over 4000 characters is cut with "...". Returns the entry.
--   Install()                         wraps the global LOG, WARN, SPEW, _ALERT (and print, when this state has one) once, so their text is recorded too; the old function runs
--                                     with all its arguments and returns what it returned. Safe to call again (a restarted session, a reloaded module): nothing is wrapped twice.
--   Installed()                       true once the wrappers are in
--   Capture(level, source, args)      what a wrapper does: joins the `arg` table of a variadic call with spaces (tostring of every value) and Adds it; a LOG line that reads like
--                                     a failure ("... failed: ...", "could not", "attempt to ...", a traceback) is an 'error', WARN is 'warn'
--   Count() / Get(i) / Version() / Clear()      the ring (index 1 is the oldest); Version changes on every Add, repeat and Clear
--   Filter(levels, needle)            the entries to show: `levels` = { error = true, ... } (a level set to false is hidden, a missing one is shown), `needle` a plain,
--                                     case-insensitive substring of the text ('' = all). Returns a new array of the entries (not copies).
--   RowText(e) / Line(e) / Lines(list) / TimeText(seconds)      "[mm:ss.t] text (x3)" for a list row, the same with a level tag for the detail and the clipboard, many lines joined
--   BreakWords(text, n)               inserts spaces into words longer than n characters, so that a wrapping text control can break a long path
--   ParseCommand(text) -> kind, code  'ui' | 'sim' and the Lua source; `sim <code>` is for the sim, `=expr` becomes `return expr`;  nil for an empty line
--   Execute(text, hooks)              runs a command line: echoes it, runs it (UI state: loadstring + pcall, a bare expression such as 1 + 2 prints its value; sim: the engine
--                                     console command SimLua through ConExecute) and records the results and errors. hooks = { loadstring =, conExecute = } for tests.
--   Remember(text) / HistoryStep(dir, current)    the last 50 commands; Up (dir -1) and Down (dir 1) walk through them, Down past the newest returns the unfinished text
--
-- The state lives in the global `EdConsoleState`, not in this module: the shell restarts its session (and gui/dev.lua drops cached modules) without losing the messages, and the
-- wrappers keep working for a module that was loaded again.
--
-- Lua 5.0 dialect: no `#`, no `%`, no `...` as an expression (variadic functions read the `arg` table).

MAX = 2000          -- entries kept
MAX_TEXT = 4000     -- characters of one entry
MAX_LINES = 80      -- entries one Add of a many-line text makes
MAX_HISTORY = 50    -- commands kept

local LEVELS = { error = true, warn = true, status = true, info = true }
local TAGS = { error = 'ERROR', warn = 'WARN ', status = 'STATUS', info = 'INFO ' }

local function Now()
    local clock = rawget(_G, 'GetSystemTimeSeconds')
    return clock and clock() or 0
end

local function NewState()
    return { first = 1, last = 0, entries = {}, version = 0, history = {}, pos = 0, draft = '', wrapped = {}, t0 = Now(), max = MAX }
end

local S = rawget(_G, 'EdConsoleState')
if not S then
    S = NewState()
    rawset(_G, 'EdConsoleState', S)
end

--- Swaps the state (the self test works on a state of its own); returns the previous one. `nil` makes a fresh state.
function UseState(state)
    local old = S
    S = state or NewState()
    return old
end

function State() return S end

function Count() return S.last - S.first + 1 end
function Version() return S.version end
function Get(i) return S.entries[S.first + i - 1] end

function Clear()
    S.entries = {}
    S.first, S.last = 1, 0
    S.version = S.version + 1
end

-- ---- recording ------------------------------------------------------------------------------------------------------------------------------------------------

local function AddLine(level, text, source, at)
    if string.len(text) > MAX_TEXT then text = string.sub(text, 1, MAX_TEXT - 3) .. '...' end
    local newest = S.entries[S.last]
    if newest and newest.level == level and newest.text == text and newest.source == source then
        newest.count = newest.count + 1
        newest.row = nil
        S.version = S.version + 1
        return newest
    end
    local e = { level = level, text = text, source = source, at = at or (Now() - S.t0), count = 1, seq = S.last + 1 }
    S.last = S.last + 1
    S.entries[S.last] = e
    while S.last - S.first + 1 > S.max do
        S.entries[S.first] = nil
        S.first = S.first + 1
    end
    S.version = S.version + 1
    return e
end

function Add(level, text, source, at)
    if not LEVELS[level] then level = 'info' end
    text = tostring(text)
    source = source or 'editor'
    if string.find(text, '[\r\n\t]') then
        text = string.gsub(text, '\t', '    ')
        local first, n = nil, 0
        for line in string.gfind(text, '[^\n]+') do
            line = string.gsub(line, '\r', '')
            if line ~= '' then
                n = n + 1
                if n > MAX_LINES then
                    AddLine(level, '(more lines cut)', source, at)
                    break
                end
                local e = AddLine(level, line, source, at)
                first = first or e
            end
        end
        return first
    end
    if text == '' then return nil end
    return AddLine(level, text, source, at)
end

--- True for a LOG line that reads like a failure (the editor logs pcall failures as "EDITOR <where>: <what> failed: <error>").
function ErrorLike(text)
    local t = string.lower(text)
    return string.find(t, 'failed:', 1, true) or string.find(t, ' failed ', 1, true) or string.find(t, 'could not', 1, true) or string.find(t, 'stack traceback', 1, true)
        or string.find(t, 'attempt to ', 1, true) or string.find(t, 'error:', 1, true) or string.find(t, '^%s*error') or string.find(t, 'not written', 1, true)
end

--- The text of a variadic call: every value through tostring, joined by spaces (arg.n counts a nil in the middle).
function JoinArgs(args)
    local n = args.n or table.getn(args)
    local parts = {}
    for i = 1, n do parts[i] = tostring(args[i]) end
    return table.concat(parts, ' ')
end

local function Record(level, source, args)
    local text = JoinArgs(args)
    if level == 'info' and source == 'LOG' and ErrorLike(text) then level = 'error' end
    Add(level, text, source)
end

function Capture(level, source, args)
    if S.busy then return false end
    S.busy = true
    local ok = pcall(Record, level, source, args)
    S.busy = false
    return ok
end

-- ---- the wrappers of the global print functions ----------------------------------------------------------------------------------------------------------------

local function Wrap(name, level, old, st)
    return function(...)
        if st.capture then st.capture(level, name, arg) end
        return old(unpack(arg))
    end
end

local TARGETS = { { 'LOG', 'info' }, { 'WARN', 'warn' }, { 'SPEW', 'info' }, { '_ALERT', 'info' }, { 'print', 'info' } }

--- Wraps the global print functions once. `env` (default _G) is where they live: the self test passes a table of its own.
function Install(env)
    env = env or _G
    S.capture = Capture
    local done = false
    for _, t in TARGETS do
        local name = t[1]
        local cur = rawget(env, name)
        if type(cur) == 'function' and S.wrapped[name] ~= cur then
            local wrapper = Wrap(name, t[2], cur, S)
            S.wrapped[name] = wrapper
            rawset(env, name, wrapper)
        end
        if S.wrapped[name] then done = true end
    end
    return done
end

function Installed()
    return S.wrapped.LOG ~= nil and S.wrapped.LOG == rawget(_G, 'LOG')
end

-- ---- reading --------------------------------------------------------------------------------------------------------------------------------------------------

function TimeText(seconds)
    local t = math.floor((seconds or 0) * 10 + 0.5) / 10
    local m = math.floor(t / 60)
    return string.format('[%02d:%04.1f]', m, t - m * 60)
end

function RowText(e)
    if not e.row then
        e.row = TimeText(e.at) .. ' ' .. e.text .. (e.count > 1 and (' (x' .. e.count .. ')') or '')
    end
    return e.row
end

function Line(e)
    return TimeText(e.at) .. ' ' .. (TAGS[e.level] or 'INFO ') .. ' ' .. e.text .. (e.count > 1 and (' (x' .. e.count .. ')') or '')
end

function Lines(list)
    local out = {}
    for i = 1, table.getn(list) do out[i] = Line(list[i]) end
    return table.concat(out, '\n')
end

function Filter(levels, needle)
    levels = levels or {}
    needle = string.lower(needle or '')
    local out, n = {}, 0
    for i = S.first, S.last do
        local e = S.entries[i]
        if levels[e.level] ~= false then
            local keep = true
            if needle ~= '' then
                if not e.lower then e.lower = string.lower(e.text) end
                keep = string.find(e.lower, needle, 1, true) ~= nil
            end
            if keep then
                n = n + 1
                out[n] = e
            end
        end
    end
    return out
end

function BreakWords(text, n)
    n = math.max(4, n or 40)
    return (string.gsub(text, '%S+', function(word)
        if string.len(word) <= n then return word end
        local parts = {}
        local at = 1
        while at <= string.len(word) do
            table.insert(parts, string.sub(word, at, at + n - 1))
            at = at + n
        end
        return table.concat(parts, ' ')
    end))
end

-- ---- the command line -----------------------------------------------------------------------------------------------------------------------------------------

local function Trim(s)
    return (string.gsub(string.gsub(s, '^%s+', ''), '%s+$', ''))
end

function ParseCommand(text)
    text = Trim(tostring(text or ''))
    if text == '' then return nil end
    local kind = 'ui'
    if text == 'sim' then return nil end
    if string.find(text, '^sim%s') then
        kind = 'sim'
        text = Trim(string.sub(text, 4))
        if text == '' then return nil end
    end
    if string.sub(text, 1, 1) == '=' then text = 'return ' .. Trim(string.sub(text, 2)) end
    return kind, text
end

--- A value as one line: strings as they are, a table as { k = v, ... } one level deep (keys sorted, at most 12 shown).
function Describe(v)
    if type(v) ~= 'table' then return tostring(v) end
    local keys = {}
    for k, _ in v do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for i, k in keys do
        if i > 12 then
            table.insert(parts, '... ' .. (table.getn(keys) - 12) .. ' more')
            break
        end
        local x = v[k]
        table.insert(parts, tostring(k) .. ' = ' .. (type(x) == 'string' and ('"' .. x .. '"') or tostring(x)))
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

function Remember(text)
    text = Trim(tostring(text or ''))
    S.pos = 0
    S.draft = ''
    if text == '' then return end
    local h = S.history
    if h[table.getn(h)] ~= text then
        table.insert(h, text)
        while table.getn(h) > MAX_HISTORY do table.remove(h, 1) end
    end
end

function HistoryStep(dir, current)
    local h = S.history
    local n = table.getn(h)
    if n == 0 then return nil end
    if dir < 0 then
        if S.pos == 0 then
            S.draft = current or ''
            S.pos = n
        else
            S.pos = math.max(1, S.pos - 1)
        end
        return h[S.pos]
    end
    if S.pos == 0 then return nil end
    S.pos = S.pos + 1
    if S.pos > n then
        S.pos = 0
        return S.draft
    end
    return h[S.pos]
end

--- Runs a command line. Returns true when it ran without an error. The echo ("> text"), results and errors are recorded as entries (source 'command' / 'result').
function Execute(text, hooks)
    hooks = hooks or {}
    local kind, code = ParseCommand(text)
    if not kind then
        if Trim(tostring(text or '')) == 'sim' then Add('error', 'sim needs code after it, for example: sim LOG("hi")', 'command') end
        return false
    end
    Remember(text)
    Add('info', '> ' .. Trim(text), 'command')
    if kind == 'sim' then
        local con = hooks.conExecute or rawget(_G, 'ConExecute')
        if not con then
            Add('error', 'the sim cannot be reached from here (no ConExecute)', 'command')
            return false
        end
        local ok, err = pcall(con, 'SimLua ' .. code)
        if not ok then
            Add('error', tostring(err), 'command')
            return false
        end
        Add('status', 'sent to the sim; what it prints is in the game log', 'command')
        return true
    end
    local compile = hooks.loadstring or loadstring
    -- a bare expression ("1 + 2", "table.getn(x)") prints its value: try it as `return <code>` first, a statement ("x = 5") falls back to the plain chunk
    local fn, err = nil, nil
    if string.sub(code, 1, 7) ~= 'return ' then fn = compile('return ' .. code, '=console') end
    if not fn then fn, err = compile(code, '=console') end
    if not fn then
        Add('error', tostring(err), 'command')
        return false
    end
    local res = { pcall(fn) }
    if not res[1] then
        Add('error', tostring(res[2]), 'command')
        return false
    end
    for i = 2, table.getn(res) do Add('info', Describe(res[i]), 'result') end
    return true
end
