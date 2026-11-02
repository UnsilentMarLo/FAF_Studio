-- Escape in the game asks "Are you sure you'd like to quit?" with Restart Session. In an editor session (/editor) that is the editor's job (Stop, File > Exit), so
-- the Escape key keeps its other meaning only (end the command mode, clear the selection, a registered escape handler).
-- The window's close button (the X) reaches the same function: the engine's WSupComFrame::OnCloseWindow calls ShowEscapeDialog(true), i.e. HandleEsc(true), while the
-- Escape key calls HandleEsc() without it. In the editor that request runs File > Exit (unsaved changes are asked about first); before, both were turned into "no quit" and the X did nothing.
-- Base signature: HandleEsc(quit_game)
-- baseline: HandleEsc
do
    local baseHandleEsc = HandleEsc
    pcall(function() import('/lua/editor/hookcheck.lua').Expect('eschandler', getfenv(1), { 'HandleEsc' }) end)
    function HandleEsc(quit_game)
        if HasCommandLineArg('/editor') then
            if quit_game then
                local ok, err = pcall(function() import('/lua/editor/gui/commands.lua').Run('file.exit') end)
                if not ok then
                    LOG('EDITOR: the close button could not run File > Exit (' .. tostring(err) .. '): quitting')
                    SafeQuit()
                end
                return
            end
            return baseHandleEsc(false)
        end
        return baseHandleEsc(quit_game)
    end
end
