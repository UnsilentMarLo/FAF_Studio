-- Editor start-up: FAF's own init, then our content mounted on top (hooks go under <editor>/schook/...).
--   <bin>/../editor            this folder (schook hooks, lua/editor/*, maps/*)
--   <bin>/../mapout/<folder>   maps the editor saved with a plain disk path (mounted at /maps/<folder>)
dofile(InitFileDir .. '/init_faf.lua')

-- A new process: the first editor session of it may show the start screen (lua/editor/gui/feature_start.lua reads and updates this file; later sessions
-- of the same process, started by opening or creating a map, do not).
do
    local f = io.open('editor_boot.txt', 'w')
    if f then
        f:write('0')
        f:close()
    end
end

-- The launcher passes the Windows display scale (FAFSTUDIO_UISCALE, e.g. 1.25) because the editor runs DPI aware (docs/projects/editor/DPI.md); gui/shell.lua uses it as the first-run
-- UI scale. Only the init state may read the environment, so it goes through a file like editor_boot.txt.
do
    local ok, value = pcall(function() return os.getenv('FAFSTUDIO_UISCALE') end)
    local f = io.open('editor_dpi.txt', 'w')
    if f then
        f:write((ok and value) or '')
        f:close()
    end
end

local function Mount(dir, mountpoint)
    -- table.insert, not path[getn(path) + 1]: after the table.insert(path, 1, ...) below getn is a stored size that plain
    -- index writes do not update, so every later mount would overwrite the same slot and only the last would survive
    table.insert(path, { dir = dir, mountpoint = mountpoint })
end

local editorDir = InitFileDir .. '/../editor'
Mount(editorDir, '/')
-- Files that must shadow FAF's own: mounts earlier in `path` win, so this one goes to the front. Currently the generated
-- /effects/primbatcher.fx (FAF's file plus the editor text techniques, editor/tools/gen_primbatcher_fx.py).
table.insert(path, 1, { dir = editorDir .. '/override', mountpoint = '/' })

local function MountMapFolders(parent)
    for _, entry in io.dir(parent .. '/*') do
        if entry ~= '.' and entry ~= '..' then
            Mount(parent .. '/' .. entry, '/maps/' .. string.lower(entry))
            LOG('EDITOR: map folder ' .. parent .. '/' .. entry)
        end
    end
end
-- Mods shipped with the editor live in <editor>/mods/<name>/mod_info.lua: the root mount above already shows them
-- as /mods/<name>. Which mods are active is decided in lua/editor/mods.lua (hooked into /lua/mods.lua): editor mods
-- always, game mods only when the map maker loaded them.
MountMapFolders(editorDir .. '/maps')
MountMapFolders(InitFileDir .. '/../mapout')
-- Mod projects the user made in the editor (modproj/<Name>/mod_info.lua): mounted as /mods/<Name>, like the mods shipped in <editor>/mods.
pcall(function()
    for _, entry in io.dir(InitFileDir .. '/../modproj/*') do
        if entry ~= '.' and entry ~= '..' then
            Mount(InitFileDir .. '/../modproj/' .. entry, '/mods/' .. entry)
            LOG('EDITOR: mod project ' .. entry)
        end
    end
end)
LOG('EDITOR: mounted ' .. editorDir)
