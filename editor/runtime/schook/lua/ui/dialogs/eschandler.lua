-- Escape in the game asks "Are you sure you'd like to quit?" with Restart Session. In an editor session (/editor) that is the editor's job (Stop, File > Exit), so
-- the Escape key keeps its other meaning only (end the command mode, clear the selection, a registered escape handler).
-- Base signature: HandleEsc(quit_game)
do
    local baseHandleEsc = HandleEsc
    function HandleEsc(quit_game)
        if HasCommandLineArg('/editor') then
            return baseHandleEsc(false)
        end
        return baseHandleEsc(quit_game)
    end
end
