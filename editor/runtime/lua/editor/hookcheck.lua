-- What the schook hooks (editor/runtime/schook/**) know about the game they run on. The hooks replace and wrap functions of the game's own Lua files; FAF changes those files
-- between builds. Two checks, both only log (the hooks themselves fall back to the game's behaviour outside /editor):
--
--   Check()                   once per Lua state: warns when the running game build is not the one the hooks were read against (VERIFIED)
--   Expect(tag, env, names)   true when every name is a function of `env` (a module table, _G, a class); otherwise one warning with the missing names and false
--   GameBuild()               the running game's build number, or nil
--
-- scripts/hook_baseline.py compares the *source* of the functions the hooks depend on with the fingerprints in schook/BASELINE.txt at lint time (`studio.py check`); this module is the
-- run time half: the build number and the presence of what a hook is about to call.
--
-- Lua 5.0 dialect. Used in the UI and the sim state (the hooks run in both): only LOG / WARN, pcall, rawget.

VERIFIED = 3840         -- FAF game build the hooks were read against (keep in step with scripts/hook_baseline.py update)

function GameBuild()
    local ok, build = pcall(function()
        local v = import('/lua/version.lua')
        return v and v.GetVersion and v.GetVersion()
    end)
    if ok and type(build) == 'number' then return build end
    local get = rawget(_G, 'GetVersion')
    if get then
        local ok2, text = pcall(get)
        if ok2 and text then
            local s, e, tail = string.find(tostring(text), '(%d+)%s*$')
            if tail then return tonumber(tail) end
        end
    end
    return nil
end

function Check()
    if rawget(_G, 'EdHookCheckDone') then return true end
    rawset(_G, 'EdHookCheckDone', true)
    local build = GameBuild()
    if build and build ~= VERIFIED then
        WARN('EDITOR: this FAF build (' .. tostring(build) .. ') is not the one the editor\'s hooks were read against (' .. VERIFIED .. '). The hooks replace functions of the game\'s own Lua; '
            .. 'if the editor misbehaves, run `python scripts/hook_baseline.py check` to see which of them changed.')
        return false
    end
    return true
end

function Expect(tag, env, names)
    local missing = {}
    for _, name in names do
        local ok, v = pcall(function() return env[name] end)
        if not ok or type(v) ~= 'function' then table.insert(missing, name) end
    end
    if table.getn(missing) > 0 then
        WARN('EDITOR hook ' .. tostring(tag) .. ': the game no longer has ' .. table.concat(missing, ', ') .. ' (build ' .. tostring(GameBuild()) .. ', hooks read against ' .. VERIFIED
            .. '): the hook may not do its job')
        return false
    end
    return true
end
