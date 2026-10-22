-- The textures of the open map's own folder, for the texture browser (gui/browser.lua) and the asset catalog (assetcat.lua).
--
-- A map is mounted at /maps/<folder> (maps.lua OpenFolder, map.lua SaveAs: ed_vfs_mount), and the game reads its files through that path: /maps/<folder>/env/layers/rock.dds. That folder is NOT
-- below /env, so DiskFindFiles('/env', ...) - what the texture pickers listed - never sees a map's own textures. This module lists them:
--
--   the map folder        every .dds below /maps/<folder> (env/layers, env/decals, textures ...), found through the VFS mount
--   the staging folder    the textures the editor made or converted for this map (maptextures.lua: maptex_*.dds in /edmaptex) that wait there until the map is saved; saving copies the ones a layer
--                         uses into <map folder>/env/layers and points the layer there (maptextures.PrepareSave, which does the same for any texture of another map folder)
--
--   FolderFrom(saveDir, scenarioPath) -> '/maps/<folder>' | nil     (pure) the VFS folder of a map: where it was saved / opened from, else the folder of its scenario file; a blank template is no map folder
--   Folder() -> '/maps/<folder>' | nil                            the folder of the open map
--   GlobMatch(glob, name) -> bool                               a DiskFindFiles pattern ('*_albedo.dds') against a file name (case blind)
--   Files(opts) -> list of { path, lower, name, rel, staged, mapWide }      opts: folder (a VFS folder, false = none; default Folder()), staged (false = leave the staging folder out), find (default
--                         DiskFindFiles: the tests give a fake). The map folder's files first, then the staged ones; a staged file whose name is in the map folder already is left out
--   Signature(opts) -> string                                   changes when a file appeared or went (the browser asks now and then)
--   LABEL                                                       'This map': the name of the category
--
-- Lua 5.0 dialect.

LABEL = 'This map'
STAGE_MOUNT = '/edmaptex'          -- maptextures.MOUNT
STAGE_LABEL = 'generated'

local function Lower(s) return string.lower(tostring(s or '')) end

local function Basename(path)
    return (string.gsub(string.gsub(tostring(path or ''), '\\', '/'), '^.*/', ''))
end

function FolderFrom(saveDir, scenarioPath)
    if saveDir and saveDir ~= '' then
        local dir = string.gsub(tostring(saveDir), '\\', '/')
        dir = string.gsub(dir, '/+$', '')
        local last = Lower(string.gsub(dir, '^.*/', ''))
        if last ~= '' then return '/maps/' .. last end
    end
    if scenarioPath and scenarioPath ~= '' then
        local dir = Lower(string.gsub(tostring(scenarioPath), '/[^/]*$', ''))
        if string.find(dir, '^/maps/[^/]+$') and not string.find(dir, '^/maps/editor_blank') then return dir end
    end
    return nil
end

function Folder()
    local saveDir, scenario = false, false
    pcall(function() saveDir = import('/lua/editor/maps.lua').saveDir end)
    pcall(function()
        local doc = import('/lua/editor/map.lua').Doc
        scenario = doc and doc.scenarioPath or false
    end)
    return FolderFrom(saveDir, scenario)
end

function GlobMatch(glob, name)
    local pattern = string.gsub(Lower(glob), '([%^%$%(%)%%%.%[%]%+%-])', '%%%1')
    pattern = string.gsub(pattern, '%*', '.*')
    pattern = string.gsub(pattern, '%?', '.')
    return string.find(Lower(name), '^' .. pattern .. '$') ~= nil
end

--- True for the map-wide pictures the editor makes (maptextures.lua names them maptex_<kind>_<n>.dds).
function IsMapWide(name)
    return string.find(Lower(name), '^maptex_%a+_%d+%.dds$') ~= nil
end

function Files(opts)
    opts = opts or {}
    local find = opts.find or DiskFindFiles
    local folder = opts.folder
    if folder == nil then folder = Folder() end
    local out, seen, names = {}, {}, {}
    local function Add(path, staged)
        local lower = Lower(path)
        if seen[lower] or not string.find(lower, '%.dds$') then return end
        local name = Basename(path)
        if staged and names[Lower(name)] then return end
        seen[lower] = true
        names[Lower(name)] = true
        local rel = ''
        if folder and string.sub(lower, 1, string.len(folder) + 1) == Lower(folder) .. '/' then
            rel = string.gsub(string.sub(path, string.len(folder) + 2), '/?[^/]*$', '')
        end
        table.insert(out, { path = path, lower = lower, name = name, rel = rel, staged = staged and true or false, mapWide = IsMapWide(name) })
    end
    local function Search(dir, pattern, staged)
        local ok, list = pcall(find, dir, pattern)
        if ok and type(list) == 'table' then
            local sorted = {}
            for _, f in list do table.insert(sorted, f) end
            table.sort(sorted, function(a, b) return Lower(a) < Lower(b) end)
            for _, f in sorted do Add(f, staged) end
        end
    end
    if folder then Search(folder, '*.dds', false) end
    if opts.staged ~= false then Search(STAGE_MOUNT, 'maptex_*.dds', true) end
    return out
end

function Signature(opts)
    local files = Files(opts)
    local total = 0
    for _, f in files do total = total + string.len(f.path) end
    return table.getn(files) .. ':' .. total
end
