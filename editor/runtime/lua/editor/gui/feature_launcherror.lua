-- The notice after a map that could not be opened. schook/lua/SinglePlayerLaunch.lua catches the failure of a session start (a scenario file that is not there, a map that does not load),
-- opens the editor's blank map instead and leaves the reason in `editor_launch_error.txt` (first line the map, the rest the error). feature_start.lua OnStart calls Take() and Show() so the
-- maker sees what happened and lands on the start screen instead of a window that does not answer.
--
--   Take()            -> the text of the failed launch (and removes the file), or nil
--   Show(text, done)  opens the notice (a dialog; Console and status line get the text too); done() runs when it is closed
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')

FILE = 'editor_launch_error.txt'

function Take()
    local text = ed_read_file(FILE)
    if not text or text == '' then return nil end
    ed_write_file(FILE, '')
    return text
end

function Show(text, done)
    local map, err = text, ''
    local nl = string.find(text, '\n', 1, true)
    if nl then
        map = string.sub(text, 1, nl - 1)
        err = string.sub(text, nl + 1)
    end
    local line = 'The map ' .. map .. ' could not be opened: ' .. err
    WARN('EDITOR: ' .. line)
    pcall(function() import('/lua/editor/ui.lua').Say('The map ' .. map .. ' could not be opened (see the Console)') end)
    local ok, why = pcall(function()
        local c = Skin.color
        local d = Dialog.Open('The map could not be opened', 620, 220, function() if done then done() end end)
        d:Label('The editor opened its blank map instead. What it was asked to open:', 14, 40, { color = c.text })
        local mapLabel = d:Label(map, 14, 64, { color = c.textDim, size = 'small' })
        W.Fit(mapLabel, map, d.width - Skin.S(28))
        local labels = W.Paragraph(d.group, err, Skin.S(14), Skin.S(92), d.width - Skin.S(28), { color = c.error, size = 'small' })
        for _, l in labels do d:Raise(l) end
        d:Button('OK', 14, 176, 110, 28, function() Dialog.Close() end)
    end)
    if not ok then
        LOG('EDITOR: the notice for the failed map open could not be shown (' .. tostring(why) .. ')')
        if done then done() end
    end
end
