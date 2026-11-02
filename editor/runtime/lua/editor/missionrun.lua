-- Run from editor: the mission debug side of a play test (docs/projects/MAP_EDITOR_DESIGN.md sections 11 and 19.24). The generated mission script exposes its state
-- (ScenarioInfo.EditorMission) and honours EditorSkip / EditorTimeScale; the sim callbacks of lua/editorsim/mission.lua write it to a file, jump to a stage, set flags, skip
-- waiting timers and scale them. This module is the UI side: it asks for a dump, parses it, and reads the engine log for the warnings the play test raised.
--
--   Poll()                     asks the sim for a dump and parses the one it wrote before; State = { tick, stage, playing, scale, flags = { NAME = bool }, objectives = { { title, active } }, vars = { NAME = text } }
--   ParseState(text)           the same parsing for a given dump text (tests)
--   Jump(stage) / SetFlag(name, value) / Skip() / SetScale(scale)       sim callbacks
--   MarkLog()                  remembers where the log is now (Play pressed); Warnings() / ParseLog(text) lists the warning lines raised since
--
-- Lua 5.0 dialect.

local UI = import('/lua/editor/ui.lua')

STATE_FILE = '../mission_state.txt'

State = { tick = 0, stage = 0, playing = false, scale = 1, flags = {}, objectives = {}, vars = {}, fresh = false, flagOrder = {}, trace = {}, units = {}, eco = {}, rel = {}, ended = false, success = false }
local logMark = 0

local M = import('/lua/editor/mission.lua')

local function Say(text)
    M.Safe('run panel', UI.Say, text)
end

local function Sim(func, args)
    local ok = M.Safe('sim callback ' .. tostring(func), SimCallback, { Func = func, Args = args or {} }, false)
    return ok
end

--- Parses a dump written by EdMissionDump.
function ParseState(text)
    local s = { tick = 0, stage = 0, playing = false, scale = 1, flags = {}, objectives = {}, vars = {}, flagOrder = {}, trace = {}, units = {}, eco = {}, rel = {}, ended = false, success = false }
    for line in string.gfind((text or '') .. '\n', '([^\n]*)\n') do
        local _, _, key, rest = string.find(line, '^(%a+) ?(.*)$')
        if key == 'tick' then s.tick = tonumber(rest) or 0
        elseif key == 'stage' then s.stage = tonumber(rest) or 0
        elseif key == 'playing' then s.playing = (rest == '1')
        elseif key == 'scale' then s.scale = tonumber(rest) or 1
        elseif key == 'flag' then
            local _, _, name, value = string.find(rest, '^(%S+) (%d)$')
            if name then s.flags[name] = (value == '1') table.insert(s.flagOrder, name) end
        elseif key == 'obj' then
            local _, _, title, active = string.find(rest, '^(.*)|(%d)$')
            if title then table.insert(s.objectives, { title = title, active = (active == '1') }) end
        elseif key == 'var' then
            local _, _, name, value = string.find(rest, '^(%S+) (.*)$')
            if name then s.vars[name] = value end
        elseif key == 'trace' then
            table.insert(s.trace, rest)
        elseif key == 'ended' then
            local _, _, e, ok = string.find(rest, '^(%d) (%d)$')
            s.ended = (e == '1') s.success = (ok == '1')
        elseif key == 'units' then
            local _, _, name, n = string.find(rest, '^(%S+) (%d+)$')
            if name then s.units[name] = tonumber(n) end
        elseif key == 'eco' then
            local _, _, name, mass, energy = string.find(rest, '^(%S+) (-?%d+) (-?%d+)$')
            if name then s.eco[name] = { mass = tonumber(mass), energy = tonumber(energy) } end
        elseif key == 'rel' then
            local _, _, a, b, kind = string.find(rest, '^(%d+) (%d+) (%a+)$')
            if a then s.rel[a .. '>' .. b] = kind end
        elseif key == 'playable' then
            local _, _, x0, y0, x1, y1 = string.find(rest, '^(-?%d+) (-?%d+) (-?%d+) (-?%d+)$')
            if x0 then s.playable = { tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1) } end
        end
    end
    table.sort(s.flagOrder)
    return s
end

--- Asks the sim for a fresh dump and reads the previous one (the sim answers on its next beat). Returns State.
function Poll()
    Sim('EdMissionDump', { path = STATE_FILE })
    local text = ed_read_file(STATE_FILE)
    if text then
        State = ParseState(text)
        State.fresh = true
    end
    return State
end

function Jump(stage)
    if not Sim('EdMissionJump', { stage = stage }) then Say('mission: jump failed') end
end

function SetFlag(name, value)
    Sim('EdMissionFlag', { name = name, value = value and true or false })
end

function Skip()
    Sim('EdMissionSkip')
end

function SetScale(scale)
    Sim('EdMissionScale', { scale = scale })
end

-- ---- the log -----------------------------------------------------------------------------------------------------------------------------------------

--- Path of the engine log (the /log argument of the editor instance), or nil.
function LogPath()
    local ok, arg = M.Safe('log path', GetCommandLineArg, '/log', 1)
    return ok and arg and arg[1] or nil
end

--- Remembers how long the log is now: Warnings() lists what came after.
function MarkLog()
    local path = LogPath()
    local text = path and ed_read_file(path)
    logMark = text and string.len(text) or 0
end

-- engine and editor debug output that is not about the mission
local NOISE = { 'SIMGATE', 'RECONDRIVE', 'ENABLEINTEL', 'GHOST', 'RECONFUNNEL', 'RECONDETECT', 'GetResource', 'LazyVar', 'Can\'t find texture', 'NUM PROPS', 'Detected a' }

local function IsNoise(line)
    if string.find(line, '^warning: %[%u+%]') then return true end       -- [TAG] diagnostics of the engine
    for _, tag in NOISE do
        if string.find(line, tag, 1, true) then return true end
    end
    return false
end

--- The warning lines of a log text (a `warning:` line that is not engine noise, with its traceback lines, at most 6 lines per warning); `WARN(...)` of a script and script errors
--- are `warning:` lines too. Returns a list of strings.
function ParseLog(text)
    local list = {}
    local keep = 0
    for line in string.gfind((text or '') .. '\n', '([^\n]*)\n') do
        if string.find(line, '^warning:') and not IsNoise(line) then
            table.insert(list, string.sub(line, 10))
            keep = 5
        elseif keep > 0 and (string.find(line, '^%s') or string.find(line, '^stack')) and not IsNoise(line) then
            table.insert(list, '    ' .. string.gsub(line, '^%s+', ''))
            keep = keep - 1
        else
            keep = 0
        end
    end
    return list
end

--- The warnings the play test raised since MarkLog().
function Warnings()
    local path = LogPath()
    local text = path and ed_read_file(path)
    if not text then return {}, 'the log cannot be read' end
    return ParseLog(string.sub(text, logMark + 1))
end
