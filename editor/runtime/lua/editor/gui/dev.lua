-- Development helper (run through /edcmd): drop the cached GUI modules so edits to editor/runtime/lua/editor/gui/*.lua are picked up
-- without restarting the engine.
--   import('/lua/editor/gui/dev.lua').Reload()

--- Stops the running shell (if any), drops the GUI modules and starts the shell again: the one-line edit-test loop.
function Restart(workspace)
    local ok, shell = pcall(import, '/lua/editor/gui/shell.lua')
    local editor = ok and shell.IsEditor and shell.IsEditor() or false   -- keep the editor integration across the restart
    if ok and shell.Stop then pcall(shell.Stop) end
    local dropped = Reload()
    import('/lua/editor/gui/shell.lua').Start(workspace or 'Terrain', { editor = editor })
    return 'restarted, ' .. dropped .. ' modules reloaded'
end

function Reload()
    local dropped = 0
    for name, _ in __modules do
        if string.find(name, '/lua/editor/gui/', 1, true) and not string.find(name, 'dev.lua', 1, true) then
            __modules[name] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end
