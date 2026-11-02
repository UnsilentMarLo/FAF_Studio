-- Editor: the editor decides which mods are active, never the player's mod manager selection.
--   * editor mods (`editor_mod = true` in mod_info.lua) are always active, sim and UI side
--   * game (sim) mods are active only when the map maker loaded them in the editor's mod browser
--   * UI-only mods of the player are never active (they hook the same UI classes the editor builds on)
-- The selection lives in lua/editor/mods.lua; this hook only redirects the engine's question "which mods".
-- baseline: GetSelectedMods, AllMods, LoadModInfo
do
    -- GetSelectedMods() -> uidSet   (base: the mod manager's `active_mods` preference)
    local baseGetSelectedMods = GetSelectedMods

    function GetSelectedMods()
        local hasArg = rawget(_G, 'HasCommandLineArg')
        if not (hasArg and hasArg('/editor')) then
            return baseGetSelectedMods()
        end
        return import('/lua/editor/mods.lua').ActiveSet()
    end

    -- AllMods() -> table<uid, ModInfo>   (base: scans /mods for mod_info.lua)
    -- Mod projects made in this editor session are mounted at run time (ed_vfs_mount): files resolve, but the directory scan does not list them. The project index
    -- (modproj/projects.txt) names them, so they are added here (LoadModInfo is a local of the base file: this hook is part of the same chunk).
    local baseAllMods = AllMods

    function AllMods()
        local mods = baseAllMods()
        local hasArg = rawget(_G, 'HasCommandLineArg')
        local read = rawget(_G, 'ed_read_file')
        if hasArg and hasArg('/editor') and read then
            local text = read('../modproj/projects.txt')
            if text then
                for name in string.gfind(text, '[^\r\n]+') do
                    local file = '/mods/' .. name .. '/mod_info.lua'
                    if DiskGetFileInfo(file) then
                        local known = false
                        for _, m in mods do
                            if m.name == name then known = true end
                        end
                        if not known then
                            local info = LoadModInfo(file)
                            if info and info.enabled ~= false then mods[info.uid] = info end
                        end
                    end
                end
            end
        end
        return mods
    end
end
