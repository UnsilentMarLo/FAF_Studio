-- Error containment helpers: a pcall that does not swallow.
--
--   Try(site, fn, ...)      pcall(fn, ...) that reports a failure (once per site, see Report) and returns ok, ... exactly like pcall
--   Wrap(site, fn)          a function that runs fn through Try and returns what fn returned (nil after a failure)
--   Call(site, fn, ...)     Try, but returns only fn's first result, or nil after a failure
--   Report(site, err)       logs "EDITOR <site>: failed: <err>" the first time a site fails, again at the 10th, 100th, 1000th ... failure (the count is in the text); the
--                           message goes through WARN, so the Console panel shows it (consolelog.lua) and the log file keeps it
--   Failures(site)          how many times a site failed;   Sites() -> list of { site, count, last }, most failures first;   Reset()
--   OnFailure(fn)           fn(site, err, count) is called for every report that is logged (the Console and the status line use it); returns nothing
--
-- A `site` is a short text that says where ("mods.apply", "panel:outliner"), never a per-call value: the rate limit counts per site.
-- The state is the global `EdSafeState`, so a module reload keeps the counts. Works in the UI and the sim state (only LOG / WARN, tostring, pcall).
--
-- Lua 5.0 dialect: no `#`, no `%`, no `...` as an expression (the `arg` table).

local S = rawget(_G, 'EdSafeState')
if not S then
    S = { sites = {}, listeners = {} }
    rawset(_G, 'EdSafeState', S)
end

local function Say(text)
    local warn = rawget(_G, 'WARN') or rawget(_G, 'LOG')
    if warn then warn(text) end
end

--- True when the count is one that is logged: 1, then every power of ten.
local function Logged(n)
    if n <= 1 then return true end
    while n > 1 and n - math.floor(n / 10) * 10 == 0 do n = n / 10 end
    return n == 1
end

function Report(site, err)
    site = tostring(site)
    local e = S.sites[site]
    if not e then
        e = { count = 0, last = '' }
        S.sites[site] = e
    end
    e.count = e.count + 1
    e.last = tostring(err)
    if Logged(e.count) then
        Say('EDITOR ' .. site .. ': failed' .. (e.count > 1 and (' (x' .. e.count .. ')') or '') .. ': ' .. e.last)
        for _, fn in S.listeners do
            pcall(fn, site, e.last, e.count)       -- best effort: a listener that fails must not report through here again
        end
    end
    return e.count
end

function Try(site, fn, ...)
    if type(fn) ~= 'function' then
        Report(site, 'not a function: ' .. type(fn))
        return false
    end
    local r = { pcall(fn, unpack(arg)) }
    if not r[1] then
        Report(site, r[2])
    end
    return unpack(r)
end

function Wrap(site, fn)
    return function(...)
        local r = { Try(site, fn, unpack(arg)) }
        if not r[1] then return nil end
        table.remove(r, 1)
        return unpack(r)
    end
end

function Call(site, fn, ...)
    local ok, result = Try(site, fn, unpack(arg))
    if ok then return result end
    return nil
end

function Failures(site)
    local e = S.sites[tostring(site)]
    return e and e.count or 0
end

function Sites()
    local list = {}
    for site, e in S.sites do
        table.insert(list, { site = site, count = e.count, last = e.last })
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.site < b.site
    end)
    return list
end

function Reset()
    S.sites = {}
end

function OnFailure(fn)
    if type(fn) == 'function' then table.insert(S.listeners, fn) end
end
