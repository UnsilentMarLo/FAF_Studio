-- Self test of the texture browser's speed and map folder support: the thumbnail cache key (assetthumbs.lua Name), the request waves (cancelling what scrolled out of view, the order of the
-- rows, the warm-up), the map folder lookup and listing (texmap.lua) with a fake VFS, and the entries of the texture picker (gui/browser.lua TextureEntries / MapAccepts).
-- Through /edcmd in an /editor session:  return import('/lua/editor/selftest_texbrowser.lua').Run()
--
-- The fake VFS replaces the globals DiskFindFiles / ed_vfs_to_disk / ed_file_stamp for the length of the run (restored at the end, also after an error).
--
-- Lua 5.0 dialect.

local Texmap = import('/lua/editor/texmap.lua')
local Thumbs = import('/lua/editor/assetthumbs.lua')
local Browser = import('/lua/editor/gui/browser.lua')

local function Join(list)
    return table.concat(list, ',')
end

function Run()
    local fails, checks = {}, 0
    local function check(name, ok, detail)
        checks = checks + 1
        if not ok then table.insert(fails, name .. (detail and (' (' .. tostring(detail) .. ')') or '')) end
    end

    -- ---- the folder of a map ----------------------------------------------------------------------------------------------------------------
    check('a saved map: the folder it was saved to, lower case', Texmap.FolderFrom('C:\\maps\\My_Map.v0001', '/maps/old/old_scenario.lua') == '/maps/my_map.v0001')
    check('a trailing slash is ignored', Texmap.FolderFrom('D:/x/Foo.v0002/', nil) == '/maps/foo.v0002')
    check('an opened map without a save folder: the folder of its scenario', Texmap.FolderFrom(false, '/maps/Some_Map/some_map_scenario.lua') == '/maps/some_map')
    check('a blank template is no map folder', Texmap.FolderFrom(false, '/maps/editor_blank_128/editor_blank_128_scenario.lua') == nil)
    check('nothing known, no folder', Texmap.FolderFrom(false, false) == nil and Texmap.FolderFrom('', '') == nil)

    check('a glob matches a file name', Texmap.GlobMatch('*_albedo.dds', 'Rock_Albedo.DDS') and not Texmap.GlobMatch('*_albedo.dds', 'rock_normals.dds'))
    check('the dot of a glob is a dot', not Texmap.GlobMatch('*.dds', 'rockxdds') and Texmap.GlobMatch('*.dds', 'a.b.dds'))
    check('maptex names are the map-wide pictures', Texmap.IsMapWide('maptex_normal_3.dds') and not Texmap.IsMapWide('maptex_normal.dds') and not Texmap.IsMapWide('rock.dds'))

    -- ---- the fake VFS ---------------------------------------------------------------------------------------------------------------------------
    local tree = {
        ['/maps/test_map'] = {
            '/maps/test_map/env/layers/Rock_albedo.dds', '/maps/test_map/env/layers/rock_normals.dds', '/maps/test_map/env/decals/crack_albedo.dds',
            '/maps/test_map/textures/sky.dds', '/maps/test_map/env/layers/maptex_normal_2.dds', '/maps/test_map/readme.txt',
        },
        ['/edmaptex'] = { '/edmaptex/maptex_normal_2.dds', '/edmaptex/maptex_light_3.dds' },
        ['/env'] = { '/env/evergreen/layers/grass_albedo.dds', '/env/evergreen/layers/grass_normals.dds', '/env/evergreen/decals/leaf_albedo.dds' },
    }
    local stamps = {}
    local function FakeFind(dir, pattern)
        local out = {}
        for _, f in tree[dir] or {} do
            if Texmap.GlobMatch(pattern, (string.gsub(f, '^.*/', ''))) then table.insert(out, f) end
        end
        return out
    end
    local saved = { find = rawget(_G, 'DiskFindFiles'), disk = rawget(_G, 'ed_vfs_to_disk'), stamp = rawget(_G, 'ed_file_stamp'), folder = Texmap.Folder }
    rawset(_G, 'DiskFindFiles', FakeFind)
    rawset(_G, 'ed_vfs_to_disk', function(path) return 'D:/fake' .. path end)
    rawset(_G, 'ed_file_stamp', function(disk) return stamps[disk] or 1000 end)
    Texmap.Folder = function() return '/maps/test_map' end
    local ok, err = pcall(function()
        -- ---- listing the map folder -----------------------------------------------------------------------------------------------------------
        local files = Texmap.Files()
        local names = {}
        for _, f in files do table.insert(names, f.name) end
        check('the map folder lists its .dds files (sorted), the staged ones after them', Join(names) == 'crack_albedo.dds,maptex_normal_2.dds,Rock_albedo.dds,rock_normals.dds,sky.dds,maptex_light_3.dds', Join(names))
        local rock, light
        for _, f in files do
            if f.name == 'Rock_albedo.dds' then rock = f end
            if f.name == 'maptex_light_3.dds' then light = f end
        end
        check('a file keeps the path the game reads and knows its folder inside the map', rock and rock.path == '/maps/test_map/env/layers/Rock_albedo.dds' and rock.rel == 'env/layers' and not rock.staged, rock and rock.rel)
        check('a staged file is marked, map-wide, and has no folder', light and light.staged and light.mapWide and light.rel == '', light and light.rel)
        check('a staged file that is in the map folder already is listed once', Join(names) ~= '' and not string.find(Join(names), 'maptex_normal_2.dds,.*maptex_normal_2.dds'))
        check('files that are not .dds are left out', not string.find(Join(names), 'readme'))
        check('staged = false leaves the staging folder out', table.getn(Texmap.Files{ staged = false }) == 5)
        check('folder = false: only the staged files', table.getn(Texmap.Files{ folder = false }) == 2)
        local sig = Texmap.Signature()
        table.insert(tree['/maps/test_map'], '/maps/test_map/env/layers/new_albedo.dds')
        check('the signature changes when a file appears', Texmap.Signature() ~= sig)
        check('and is the same when nothing changed', Texmap.Signature() == Texmap.Signature())

        -- ---- the picker entries ---------------------------------------------------------------------------------------------------------------
        local spec = { sources = { { '/env', '*_albedo.dds' } }, match = function(path) return string.find(string.lower(path), '/layers/', 1, true) ~= nil end }
        local entries = Browser.TextureEntries(spec)
        local keys = {}
        for _, e in entries do table.insert(keys, e.key) end
        check('without mapMatch the map files must fit a source pattern and match()', Join(keys) == '/maps/test_map/env/layers/new_albedo.dds,/maps/test_map/env/layers/Rock_albedo.dds,/env/evergreen/layers/grass_albedo.dds', Join(keys))
        check('the map entries come first, in the category This map', entries[1].tags.source == 'This map' and entries[1].folder == 'This map/env/layers' and entries[3].tags.source == 'Game' and entries[3].folder == 'env/evergreen/layers')
        check('the chosen key is the path the game reads', entries[2].key == '/maps/test_map/env/layers/Rock_albedo.dds' and entries[2].source == entries[2].key and entries[2].name == 'Rock_albedo.dds')
        local layerSpec = {
            sources = { { '/env', '*_normals.dds' } },
            match = spec.match,
            mapMatch = function(path, lower) return not string.find(lower, '/decals/', 1, true) and string.find(lower, 'normal', 1, true) ~= nil end,
        }
        local normals = Browser.TextureEntries(layerSpec)
        local nk = {}
        for _, e in normals do table.insert(nk, e.name) end
        check('mapMatch decides which map files a picker offers', Join(nk) == 'maptex_normal_2.dds,rock_normals.dds,grass_normals.dds', Join(nk))
        check('a staged picture is tagged map-wide', normals[1].tags.type == 'map-wide' and normals[2].tags.type == 'normal map')
        check('map = false leaves the map folder out', table.getn(Browser.TextureEntries{ sources = spec.sources, match = spec.match, map = false }) == 1)
        check('thumbs = false gives entries without pictures', Browser.TextureEntries{ sources = spec.sources, match = spec.match, thumbs = false }[1].thumb == nil)

        -- ---- the cache key ------------------------------------------------------------------------------------------------------------------
        Thumbs.Reset()
        local src = '/maps/test_map/env/layers/Rock_albedo.dds'
        local n1 = Thumbs.Name('textures', src, src)
        check('a cache name is stable', n1 == Thumbs.Name('textures', src, src))
        stamps['D:/fake' .. src] = 2000
        local n2 = Thumbs.Name('textures', src, src)
        check('a changed file (new time stamp) gets a new name', n1 ~= n2)
        check('the kind is part of the name (the 256 pixel preview is another file)', Thumbs.Name('texprev', src, src) ~= n2)
        check('so is the path', Thumbs.Name('textures', src .. 'x', src) ~= n2)
        check('and the version of the recipe', (function()
            local v = Thumbs.Version
            Thumbs.Version = v + 1
            local other = Thumbs.Name('textures', src, src)
            Thumbs.Version = v
            return other ~= n2
        end)())
        check('the preview kind is bigger than a row picture', (Thumbs.Sizes.texprev or 0) > Thumbs.Size)

        -- ---- waves, order, warm-up --------------------------------------------------------------------------------------------------------
        Thumbs.Reset()
        Thumbs.Hold(1000)          -- (the worker waits: the queue stays as the requests left it)
        for _, k in { '/t/a.dds', '/t/b.dds', '/t/c.dds' } do Thumbs.Request('textures', k, k, 'test') end
        check('requests are served in the order they were asked', Join(Thumbs.Order()) == '/t/a.dds,/t/b.dds,/t/c.dds', Join(Thumbs.Order()))
        Thumbs.NewWave('test')
        for _, k in { '/t/c.dds', '/t/d.dds' } do Thumbs.Request('textures', k, k, 'test') end
        check('what the next wave does not ask for again is cancelled', Join(Thumbs.Order()) == '/t/c.dds,/t/d.dds', Join(Thumbs.Order()))
        Thumbs.Request('textures', '/t/e.dds', '/t/e.dds', 'other')
        Thumbs.NewWave('test')
        check('another owner is not cancelled by this owner\'s wave', Join(Thumbs.Order()) == '/t/e.dds', Join(Thumbs.Order()))
        Thumbs.Request('textures', '/t/c.dds', '/t/c.dds', 'test')
        Thumbs.Request('textures', '/t/e.dds', '/t/e.dds', 'other')
        check('asking again moves a request to the place of the newest ask', Join(Thumbs.Order()) == '/t/c.dds,/t/e.dds', Join(Thumbs.Order()))
        local added = Thumbs.Warm('textures', { { key = '/w/1.dds' }, { key = '/w/2.dds' }, { key = '/t/c.dds' }, { key = '/w/1.dds' } })
        check('the warm-up queues new pictures once, not ones already asked for', added == 2 and Thumbs.Stats().warmQueued == 2, added)
        check('a warm-up request is not served before the visible ones', Join(Thumbs.Order()) == '/t/c.dds,/t/e.dds')
        Thumbs.NewWave('test')
        Thumbs.Request('textures', '/w/2.dds', '/w/2.dds', 'test')
        check('a warm-up picture that comes into view becomes a wanted one', Join(Thumbs.Order()) == '/t/e.dds,/w/2.dds' or Join(Thumbs.Order()) == '/w/2.dds,/t/e.dds', Join(Thumbs.Order()))
        Thumbs.CancelWarm()
        check('CancelWarm drops the rest of the warm-up', Thumbs.Stats().warmQueued == 0)
        Thumbs.Reset()
    end)
    rawset(_G, 'DiskFindFiles', saved.find)
    rawset(_G, 'ed_vfs_to_disk', saved.disk)
    rawset(_G, 'ed_file_stamp', saved.stamp)
    Texmap.Folder = saved.folder
    Thumbs.Reset()
    if not ok then table.insert(fails, 'error: ' .. tostring(err)) end
    if table.getn(fails) == 0 then return 'PASS texbrowser (' .. checks .. ' checks)' end
    return 'FAIL texbrowser: ' .. table.concat(fails, '; ')
end
