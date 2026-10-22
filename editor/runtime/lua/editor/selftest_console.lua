-- Self test of consolelog.lua (the data and logic of the Console panel): capture of LOG with all arguments (a fake LOG in a fake environment), the wrapper keeping its
-- return values and being installed once, the repeat counter, the ring cap, the text cut, many-line texts, the level / text filter, the formats, the command line
-- (results, errors, history) and the sim path, single-line entries, W.Fit / W.FitCached with tiny widths on a fake label, and Fields.CleanError / ErrorTrace / Try. Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_console.lua').Run()
-- It works on a state of its own and puts the live console back afterwards.
--
-- Lua 5.0 dialect.

local Console = import('/lua/editor/consolelog.lua')

function Run()
    local out, failed = {}, 0
    local function Check(ok, text)
        table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
        if not ok then failed = failed + 1 end
    end

    local live = Console.UseState(nil)
    local ok, err = pcall(function()
        -- capture: a fake LOG that keeps what it was called with and returns two values
        local seen = {}
        local env = {}
        rawset(env, 'LOG', function(a, b, c) seen.args = { a, b, c } seen.n = (seen.n or 0) + 1 return 'r1', 'r2' end)
        rawset(env, 'WARN', function(a) seen.warn = a end)
        Check(Console.Install(env), 'Install wraps the functions it finds')
        local wrapped = rawget(env, 'LOG')
        Check(Console.Install(env) and rawget(env, 'LOG') == wrapped, 'a second Install wraps nothing twice')
        local r1, r2 = env.LOG('hello', 42, nil)
        Check(r1 == 'r1' and r2 == 'r2', 'the wrapper keeps the return values')
        Check(seen.n == 1 and seen.args[1] == 'hello' and seen.args[2] == 42 and seen.args[3] == nil, 'the old LOG runs once with all its arguments')
        Check(Console.Count() == 1 and Console.Get(1).text == 'hello 42 nil' and Console.Get(1).level == 'info', 'the text is recorded: arguments joined by spaces, non-strings through tostring')
        env.LOG({}, 'x')
        Check(string.find(Console.Get(2).text, '^table: ') ~= nil, 'a table argument is recorded through tostring')
        env.WARN('careful')
        Check(seen.warn == 'careful' and Console.Get(3).level == 'warn' and Console.Get(3).source == 'WARN', 'WARN is recorded as a warning and still runs')
        env.LOG('EDITOR gui: command x failed: boom')
        Check(Console.Get(4).level == 'error', 'a LOG line that reads like a failure is an error')
        env.LOG('EDITOR perf: all fine')
        Check(Console.Get(5).level == 'info', 'an ordinary LOG line stays info')
        Console.Clear()
        Check(Console.Count() == 0, 'Clear empties the list')

        -- repeats
        local v0 = Console.Version()
        Console.Add('info', 'same', 'editor')
        Console.Add('info', 'same', 'editor')
        local e = Console.Add('info', 'same', 'editor')
        Check(Console.Count() == 1 and e.count == 3, 'an immediate repeat raises the counter instead of adding a line')
        Check(Console.RowText(e) == Console.TimeText(e.at) .. ' same (x3)', 'the row shows the counter as x3')
        Console.Add('warn', 'same', 'editor')
        Console.Add('info', 'same', 'editor')
        Check(Console.Count() == 3, 'a different level, or a repeat that is not immediate, is a new line')
        Check(Console.Version() > v0, 'the version changes on every Add')

        -- ring
        Console.Clear()
        Console.State().max = 50
        for i = 1, 120 do Console.Add('info', 'line ' .. i, 'editor') end
        Check(Console.Count() == 50 and Console.Get(1).text == 'line 71' and Console.Get(50).text == 'line 120', 'the ring keeps the newest entries (cap 50 here, 2000 live)')
        Console.State().max = Console.MAX
        Check(Console.MAX == 2000, 'the cap is 2000 entries')

        -- cut and many lines
        Console.Clear()
        local long = Console.Add('info', string.rep('a', 5000), 'editor')
        Check(string.len(long.text) == Console.MAX_TEXT and string.sub(long.text, -3) == '...', 'a text over 4000 characters is cut with an ellipsis')
        Console.Clear()
        Console.Add('error', 'first\r\nsecond\n\nthird\tx', 'editor')
        Check(Console.Count() == 3 and Console.Get(2).text == 'second' and Console.Get(3).text == 'third    x', 'a many-line text becomes one entry per line, tabs become spaces')
        Check(Console.Get(1).level == 'error', 'every line keeps the level')
        local before = Console.Count()
        Check(Console.Add('info', '', 'editor') == nil and Console.Count() == before, 'an empty text adds nothing')

        -- filter
        Console.Clear()
        Console.Add('error', 'Disk FULL', 'editor')
        Console.Add('warn', 'disk almost full', 'editor')
        Console.Add('status', 'saved the map', 'status')
        Console.Add('info', 'the DISK is fine', 'editor')
        Check(table.getn(Console.Filter({}, '')) == 4, 'no filter shows everything')
        Check(table.getn(Console.Filter({ info = false, status = false }, '')) == 2, 'a level set to false is hidden')
        Check(table.getn(Console.Filter({ error = true, warn = true, status = true, info = true }, 'disk')) == 3, 'the text filter ignores case')
        local only = Console.Filter({ info = false }, 'FULL')
        Check(table.getn(only) == 2 and only[1].level == 'error' and only[2].level == 'warn', 'level and text filters combine, the order is kept')
        Check(table.getn(Console.Filter({}, 'no such text')) == 0, 'no match, no rows')
        Check(table.getn(Console.Filter({}, '.*')) == 0, 'the text is a plain substring, not a pattern')

        -- formats
        Check(Console.TimeText(0) == '[00:00.0]' and Console.TimeText(75.34) == '[01:15.3]' and Console.TimeText(59.96) == '[01:00.0]', 'time text is [mm:ss.t]')
        local line = Console.Line(Console.Get(2))
        Check(string.find(line, '^%[%d%d:%d%d%.%d%] WARN  disk almost full$') ~= nil, 'a full line has time, level tag and text: ' .. line)
        local two = Console.Lines({ Console.Get(1), Console.Get(2) })
        Check(string.find(two, '\n', 1, true) ~= nil and string.find(two, 'Disk FULL', 1, true) ~= nil, 'Lines joins the entries with newlines')
        Check(Console.BreakWords('ab ' .. string.rep('x', 25), 10) == 'ab xxxxxxxxxx xxxxxxxxxx xxxxx', 'BreakWords splits only the words that are too long')

        -- the command line
        local k, code = Console.ParseCommand('  = 1 + 2 ')
        Check(k == 'ui' and code == 'return 1 + 2', '= expr becomes return expr')
        k, code = Console.ParseCommand('sim LOG("x")')
        Check(k == 'sim' and code == 'LOG("x")', 'the prefix sim selects the sim')
        k, code = Console.ParseCommand('sim =Random()')
        Check(k == 'sim' and code == 'return Random()', 'sim accepts = expr too')
        Check(Console.ParseCommand('   ') == nil and Console.ParseCommand('sim ') == nil and Console.ParseCommand(nil) == nil, 'an empty line is no command')
        Check(Console.ParseCommand('simple = 1') == 'ui', 'a word that only starts with sim is still Lua for the UI')

        Console.Clear()
        Check(Console.Execute('= 1 + 2'), 'an expression runs')
        Check(Console.Get(1).text == '> = 1 + 2' and Console.Get(1).source == 'command' and Console.Get(2).text == '3' and Console.Get(2).level == 'info', 'the command is echoed and its value recorded')
        Console.Execute('2 * 21')
        Check(Console.Get(Console.Count()).text == '42', 'a bare expression prints its value')
        local n = Console.Count()
        Check(Console.Execute('local unused = 5') and Console.Count() == n + 1, 'a statement runs and prints nothing but its echo')
        n = Console.Count()
        Console.Execute('return 1, "two", nil')
        Check(Console.Count() == n + 3 and Console.Get(n + 2).text == '1' and Console.Get(n + 3).text == 'two', 'every returned value gets a line')
        n = Console.Count()
        Check(not Console.Execute('error("kaboom")'), 'a runtime error is reported as failed')
        Check(Console.Count() == n + 2 and Console.Get(n + 2).level == 'error' and string.find(Console.Get(n + 2).text, 'kaboom', 1, true) ~= nil, 'and recorded as an error line')
        n = Console.Count()
        Check(not Console.Execute('x = = 1'), 'a syntax error is reported as failed')
        Check(Console.Get(Console.Count()).level == 'error' and Console.Count() == n + 2, 'and recorded as an error line')
        Console.Execute('= {b = 2, a = "s"}')
        Check(Console.Get(Console.Count()).text == '{ a = "s", b = 2 }', 'a table result is shown one level deep with sorted keys')

        -- the sim goes through the engine console command
        local sent = false
        Check(Console.Execute('sim LOG("hi")', { conExecute = function(cmd) sent = cmd end }) and sent == 'SimLua LOG("hi")', 'sim <code> sends SimLua <code> to the console')
        Check(Console.Get(Console.Count()).level == 'status', 'and says so')
        Check(not Console.Execute('sim x', { conExecute = function(cmd) error('no console') end }) and Console.Get(Console.Count()).level == 'error', 'a failing console call is an error line')
        n = Console.Count()
        Check(not Console.Execute('sim') and Console.Count() == n + 1 and Console.Get(n + 1).level == 'error', 'sim without code is reported')

        -- history
        Console.UseState(nil)
        for i = 1, 60 do Console.Remember('cmd ' .. i) end
        Console.Remember('cmd 60')
        Check(table.getn(Console.State().history) == 50 and Console.State().history[1] == 'cmd 11', 'the history keeps the last 50 commands, a repeat is not added twice')
        Check(Console.HistoryStep(-1, 'draft') == 'cmd 60' and Console.HistoryStep(-1, 'x') == 'cmd 59', 'Up walks back')
        Check(Console.HistoryStep(1, 'x') == 'cmd 60', 'Down walks forward')
        Check(Console.HistoryStep(1, 'x') == 'draft', 'Down past the newest returns the unfinished text')
        Check(Console.HistoryStep(1, 'x') == nil, 'and then there is nothing further')
        Console.UseState(nil)
        Check(Console.HistoryStep(-1, '') == nil, 'an empty history gives nothing')

        -- one line per entry: a text control draws the lines of a many-line text on top of each other (a long error message with its traceback was one unreadable row)
        Console.UseState(nil)
        local tb = 'not built: map normal map: boom\nstack traceback:\n\tgraphrun.lua:767: in function `BuildMapTextures`\r\n\t[C]: in function `pcall`\vx\fy'
        Console.Add('status', tb, 'status')
        local flat = true
        for i = 1, Console.Count() do
            local e = Console.Get(i)
            if string.find(e.text, '%c') or string.find(Console.RowText(e), '%c') then flat = false end
        end
        Check(Console.Count() == 4 and flat, 'a message with a traceback becomes single-line entries without any control character')
        Check(Console.Get(4).text == '    [C]: in function `pcall` x y', 'a vertical tab and a form feed become spaces too: ' .. tostring(Console.Get(4).text))
        Console.Add('info', 'a\1b\2c', 'editor')
        Check(Console.Get(Console.Count()).text == 'a b c', 'other control characters become spaces')

        -- Fit never leaves overprinting: one line, nothing wider than the room, nothing at all when not even "..." fits
        local okW, W = pcall(import, '/lua/editor/gui/widgets.lua')
        if okW and W and W.Fit then
            local label = { text = '' }
            label.SetText = function(self, t) self.text = t end
            label.GetText = function(self) return self.text end
            label.Width = function() return string.len(label.text) * 10 end
            label.Height = function() return 14 end
            local long = 'stack traceback:\n\t...dist\\fafstudio\\bin\\..\\editor\\lua\\editor\\graphrun.lua:767: in function BuildMapTextures'
            W.Fit(label, long, 100000)
            Check(not string.find(label.text, '%c') and label.text == string.gsub(long, '%c+', ' '), 'Fit makes the text one line')
            W.Fit(label, long, 200)
            Check(string.len(label.text) * 10 <= 200 and string.sub(label.text, -3) == '...' and not string.find(label.text, '%c'), 'Fit cuts to the room with an ellipsis: ' .. label.text)
            W.Fit(label, long, 30)
            Check(label.text == '...', 'room for the ellipsis only: ' .. label.text)
            W.Fit(label, long, 29)
            Check(label.text == '', 'no room for even the ellipsis: nothing is drawn')
            W.Fit(label, long, 0)
            Check(label.text == '', 'zero room: nothing is drawn')
            W.Fit(label, long, -40)
            Check(label.text == '', 'negative room: nothing is drawn')
            W.Fit(label, 'ok', 100)
            Check(label.text == 'ok', 'a text that fits is left alone')
            W.Fit(label, nil, 100)
            Check(label.text == '', 'a nil text is empty')
            -- a row binds many times: the same label is reused, the text is the same one line every time, and a narrow row shows less, not more
            local e = Console.Add('error', tb, 'editor')
            for _, room in { 400, 60, 25, 400 } do
                W.FitCached(label, Console.RowText(e), room)
                Check(not string.find(label.text, '%c') and string.len(label.text) * 10 <= room, 'a row bound at ' .. room .. ' pixels is one line that fits: ' .. label.text)
            end
        else
            table.insert(out, '  skip the Fit checks (no widget kit in this state)')
        end

        -- an error message as the user reads it
        local Fields = import('/lua/editor/fields.lua')
        local raw = 'x\\y\\graphrun.lua(835): ...graphrun.lua(767): map normal map: boom\nstack traceback:\n\tgraphrun.lua:767: in function f\nstack traceback:\n\tfields.lua:122: in function g'
        Check(Fields.CleanError(raw) == 'map normal map: boom', 'CleanError drops the tracebacks and every position prefix: ' .. Fields.CleanError(raw))
        Check(Fields.CleanError('gui.lua:12: attempt to call a nil value') == 'attempt to call a nil value' and Fields.CleanError('[string "x"]:3: bad') == 'bad', 'both prefix forms of the interpreter go')
        Check(Fields.CleanError('plain message') == 'plain message' and Fields.CleanError('see: here') == 'see: here', 'a message without a position is kept')
        Check(Fields.ErrorTrace(raw) == 'stack traceback:\n\tgraphrun.lua:767: in function f' and Fields.ErrorTrace('plain') == nil, 'ErrorTrace gives the first (deepest) traceback once')
        local okT, a1 = Fields.Try(function(S) error('inner failure', 0) end)
        Check(okT == false and Fields.CleanError(a1) == 'inner failure', 'Fields.Try returns the failure instead of raising it')
        local okT2, a2 = Fields.Try(function(S) return 7 end)
        Check(okT2 == true and a2 == 7, 'and the results of a run that works')
    end)
    if not ok then Check(false, 'error: ' .. tostring(err)) end
    Console.UseState(live)

    table.insert(out, 1, failed == 0 and 'PASS console' or ('FAIL console: ' .. failed .. ' checks'))
    return table.concat(out, '\n')
end
