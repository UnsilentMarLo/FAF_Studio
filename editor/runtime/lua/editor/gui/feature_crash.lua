-- Crash handling and support commands: the notice at the start after a crash (report path, save diagnostics), the offer to restore an unsaved autosave, Help > Save
-- diagnostics for a bug report, Help > Reset user settings. Logic: crash.lua, userdata.lua. Self-registering (gui/feature_*.lua are imported by the shell).
--
--   Notices(done)   shows the crash notice and the autosave offer one after the other (the start screen calls this once per process), then runs done()
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Crash = import('/lua/editor/crash.lua')
local UserData = import('/lua/editor/userdata.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

--- Writes the text to `diagnostics.txt` in the user folder and, when this engine build has CopyToClipboard (the stock FAF exe has, the editor's build may not), puts it on the clipboard
--- too. Returns the file and whether the clipboard got it.
local function Save(text)
    local file = UserData.Path('diagnostics.txt')
    ed_write_file(file, text)
    local clip = false
    if rawget(_G, 'CopyToClipboard') then clip = CopyToClipboard(text) and true or false end
    return file, clip
end

local function HasClipboard()
    return rawget(_G, 'CopyToClipboard') ~= nil
end

--- Saves the diagnostics and tells where they are (a dialog: the path is long, the status line cuts it).
function CopyDiagnostics()
    local ok, text = pcall(Crash.Diagnostics)
    if not ok then text = 'diagnostics failed: ' .. tostring(text) end
    local file, clip = Save(text)
    Say('diagnostics saved as ' .. file .. (clip and ' and copied to the clipboard' or ''))
    local c = Skin.color
    local d = Dialog.Open('Diagnostics', 560, 170)
    local y = d:Text(clip and 'The diagnostics are on the clipboard and in this file:' or 'The diagnostics are in this file; attach it to your bug report:', 14, 36, { color = c.text })
    local label = d:Label(file, 14, y + 4, { color = c.textDim, size = 'small' })
    y = d:Text('Version, settings, open map, monitors, the end of the log and the newest crash report.', 14, y + 28, { color = c.textDim, size = 'small' })
    d:Flow({ { d:Button('OK', 0, 0, 100, 28, function() Dialog.Close() end), 100 } }, y + 10, 28)
end

-- ---- autosave offer ----------------------------------------------------------------------------------------------------------------------

local function AutosaveOffer(done)
    local pending = Crash.PendingAutosave()
    local Maps = import('/lua/editor/maps.lua')
    if not pending or not Maps.AutosavePath() then
        if pending then Crash.ClearAutosave() end
        if done then done() end
        return
    end
    local c = Skin.color
    local d = Dialog.Open('Unsaved work from the last session', 520, 170, function() if done then done() end end)
    local name = (pending.map and pending.map ~= '') and ("'" .. pending.map .. "'") or 'a map'
    local y = d:Text('The editor was closed (or stopped) with unsaved changes. An autosave of ' .. name .. ' is available. Restore it now?', 14, 36, { color = c.text })
    local restore = d:Button('Restore it', 0, 0, 120, 28, function()
        d.onClose = nil
        Dialog.Close()
        Maps.Recover()
    end)
    local later = d:Button('Ask me later', 0, 0, 120, 28, function() Dialog.Close() end)
    local discard = d:Button('Discard it', 0, 0, 120, 28, function()
        Crash.ClearAutosave()
        Dialog.Close()
    end)
    d:Flow({ { restore, 120 }, { later, 120 }, { discard, 120 } }, y + 14, 28)
end

-- ---- crash notice ------------------------------------------------------------------------------------------------------------------------

local function CrashNotice(done)
    local fresh = Crash.NewReports()
    UserData.Flush()
    if table.getn(fresh) == 0 then
        if done then done() end
        return
    end
    local newest = fresh[table.getn(fresh)]
    local c = Skin.color
    local d = Dialog.Open('The editor stopped unexpectedly', 600, 230, function()
        Crash.MarkSeen(fresh)
        if done then done() end
    end)
    local y = d:Text('Last time FAF Studio ended with an error. The engine wrote a crash report:', 14, 36, { color = c.text })
    local path = Crash.ReportPath(newest)
    d:Label(path, 14, y + 4, { color = c.textDim, size = 'small' })
    y = d:Text('Please send it with a short description of what you were doing. Your work is not lost: if the editor autosaved, the next window offers to restore it.', 14, y + 28, { color = c.text })
    local save = d:Button('Save diagnostics', 0, 0, 160, 28, function() CopyDiagnostics() end)
    local keep = d:Button('Continue', 0, 0, 110, 28, function() Dialog.Close() end)
    d:Flow({ { save, 160 }, { keep, 110 } }, y + 14, 28)
end

function Notices(done)
    CrashNotice(function() AutosaveOffer(done) end)
end

-- ---- commands and menu ---------------------------------------------------------------------------------------------------------------------

Commands.Register{ id = 'help.diagnostics', title = 'Help: save diagnostics for bug report', run = function() CopyDiagnostics() end }

local function ResetSettings()
    local d = Dialog.Open('Reset user settings', 520, 190)
    local c = Skin.color
    local y = d:Text('This clears your layouts, UI size, hotkeys, recent maps and tool settings. Your maps, mod projects and backups are not affected.', 14, 36, { color = c.text })
    y = d:Text('User folder: ' .. UserData.Dir(), 14, y + 8, { color = c.textDim, size = 'small' })
    local reset = d:Button('Reset', 0, 0, 110, 28, function()
        local cleared = UserData.Reset()
        Dialog.Close()
        Say('user settings reset (' .. table.getn(cleared) .. ' files): restart the editor to start from the defaults')
    end)
    local cancel = d:Button('Cancel', 0, 0, 110, 28, function() Dialog.Close() end)
    d:Flow({ { reset, 110 }, { cancel, 110 } }, y + 14, 28)
end

Commands.Register{ id = 'help.reset_settings', title = 'Help: reset user settings...', run = function() ResetSettings() end }
Commands.Register{ id = 'help.userfolder', title = 'Help: open settings folder', run = function()
    Say('user folder: ' .. UserData.Dir() .. '   installation: ' .. tostring(Crash.Root()))
end }

Menu.Extend('menubar.Help', function()
    return {
        { command = 'help.diagnostics' },
        { command = 'help.userfolder' },
        { command = 'help.reset_settings' },
    }
end, 30)
