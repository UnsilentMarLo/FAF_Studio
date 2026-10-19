-- Example of an editor sim callback file (loaded by the loader at the end of schook/lua/simcallbacks.lua): UI -> sim, SimCallback({ Func = 'EdPing', Args = { path = '...' } }, false).
-- A feature adds its own file here, `function Register(Callbacks)`, instead of editing simcallbacks.lua.
function Register(Callbacks)
    --- Writes 'pong <tick>' to a file: proves the sim state answers.
    Callbacks.EdPing = function(data)
        ed_write_file(data.path, 'pong ' .. tostring(GetGameTick()) .. '\n')
    end
end
