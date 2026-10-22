-- Editor control module (user Lua state). Loaded by the gamemain hook when the engine runs with /editor.
--
--   /edcmd <file>   development command channel: whenever the file changes it is run as a Lua chunk in the
--                   UI state; the printable result (or the error) is written to <file>.out
--
-- Everything here is data under editor/: the binary only provides the ed_* functions (moho/editor/EditorLua.cpp).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap

local started = false

--- Queue a map to be opened when the current session has ended, then end the session. The front-end hook
--- (schook uimain) starts the queued map instead of showing the main menu.
-- The queue lives in a file: the session end hands the engine a different Lua state, so neither module
-- locals nor FrontEndData survive it (SetFrontEndData also needs the engine's front-end state).
NextMapFile = 'editor_next_map.txt'

--- The engine keeps the overlay objects (marker icons, area lines, decals of ed_overlay_*) in static tables that outlive a session: whoever ends or starts a
--- session empties them, otherwise the markers of the previous map stay on screen.
function ClearOverlays()
    if rawget(_G, 'ed_overlay_clear') then ed_overlay_clear() end
end

--- The field engine's grids (masks, graph node results, undo copies) live in the exe, not in the Lua state: the handles of an ended session are unreachable
--- and the exe does not free them at session end (EdField.cpp keeps them in a static table), so every session start and every map load frees them all.
function FreeNativeStores()
    if rawget(_G, 'ed_field_free_all') then pcall(ed_field_free_all) end
end

--- What the user had open besides the map, so that a session restart (open another map, apply mods, Test in the unit lab) does not throw them back to the Terrain
--- workspace with the mod project closed: the shell's workspace and the open mod project, in a file the next session reads once (gui/shell.lua Start).
SessionFile = 'editor_session_ui.txt'
SessionExtra = {}        -- more keys for the next session file (ui.Play: autoplay, backup, stage)

function SaveSessionUI()
    local text = ''
    local ok, ws = pcall(function() return import('/lua/editor/gui/shell.lua').S.current end)
    if ok and ws then text = text .. 'workspace=' .. tostring(ws) .. '\n' end
    local ok2, project = pcall(function() return import('/lua/editor/bpedit.lua').Project end)
    if ok2 and project then text = text .. 'project=' .. tostring(project) .. '\n' end
    -- a play test of a changed mission needs a new session (the sim runs the script it was loaded with): the new session starts in play mode (ui.lua Play)
    for key, value in SessionExtra do text = text .. key .. '=' .. tostring(value) .. '\n' end
    SessionExtra = {}
    ed_write_file(SessionFile, text)
end

--- Everything the editor made in the engine that does not go away with the Lua modules: the overlay objects, and the world meshes (a WorldMesh keeps its own Lua table alive, so
--- the next session's module reset does not free it: the rock meshes of a map's resource markers showed up in the next map, floating at their old heights). Called when a map
--- is queued (LoadMap) and by the front-end hook (schook/lua/ui/uimain.lua) before the modules are dropped; it does nothing the second time.
function Teardown()
    for _, name in { 'markervis', 'placer' } do
        local mod = __modules and __modules['/lua/editor/' .. name .. '.lua']      -- only a module that is loaded: nothing is imported here
        if mod and mod.Shutdown then pcall(mod.Shutdown) end
    end
    ClearOverlays()
end

function LoadMap(name)
    pcall(SaveSessionUI)
    Teardown()
    FreeNativeStores()
    ed_write_file(NextMapFile, name)
    ExitGame()    -- back to the front end; the uimain hook then opens the queued map
end

local function RunCommandFile(path)
    local data = ed_read_file(path)
    if not data then
        return
    end
    local out = {}
    local chunk, err = loadstring(data, '=edcmd')
    if not chunk then
        out[1] = 'ERROR: ' .. tostring(err)
    else
        local ok, result = pcall(chunk)
        if ok then
            out[1] = 'OK: ' .. tostring(result)
        else
            out[1] = 'ERROR: ' .. tostring(result)
        end
    end
    ed_write_file(path .. '.out', table.concat(out, '\n') .. '\n')
end

function Start()
    if started then
        return
    end
    started = true
    LOG('EDITOR: control module started')
    -- a session is up: a mod load that was being tried has worked
    import('/lua/editor/mods.lua').EndTrial()
    ClearOverlays()
    FreeNativeStores()
    -- every session starts a new map document (heights, command stack, dirty state)
    ed_doc_attach()
    if not HasCommandLineArg('/noeditorui') then
        local ui = import('/lua/editor/ui.lua')
        if not HasCommandLineArg('/oldui') then
            -- docking GUI shell (editor/gui): panels, workspaces, pop-out windows. ui.lua keeps the editor logic.
            ui.Create{ shell = true }
            import('/lua/editor/gui/shell.lua').Start('Terrain', { editor = true, remember = true })
        else
            ui.Create()
        end
    end

    local arg = GetCommandLineArg('/edcmd', 1)
    local path = arg and arg[1]
    if not path then
        return
    end
    LOG('EDITOR: command channel ' .. path)

    local poller = Bitmap(GetFrame(0))
    poller:SetSolidColor('00000000')
    poller.Left:Set(0)
    poller.Top:Set(0)
    poller.Width:Set(1)
    poller.Height:Set(1)
    poller:DisableHitTest()
    poller:SetNeedsFrameUpdate(true)
    poller.elapsed = 0
    poller.OnFrame = function(self, delta)
        self.elapsed = self.elapsed + delta
        if self.elapsed < 0.25 then
            return
        end
        self.elapsed = 0
        -- the stamp of the last command run lives in a file: a command that reopens the map (Stop, Apply mods)
        -- would otherwise run again in the new session, whose Lua state does not keep globals
        local stamp = ed_file_stamp(path)
        if stamp and tostring(stamp) ~= ed_read_file(path .. '.stamp') then
            ed_write_file(path .. '.stamp', tostring(stamp))
            RunCommandFile(path)
        end
    end
end
