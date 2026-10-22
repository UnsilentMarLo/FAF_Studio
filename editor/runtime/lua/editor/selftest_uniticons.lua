-- Unit icons of mod units (units.lua IconPath / MeshFile / SourceFolders, assetcat.lua Thumb): the lookup with fake file natives. Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_uniticons.lua').Run()
-- Checks: the game's icon is found by the unit's id; a mod unit's icon is found in the mod's own folder (from bp.Source: textures/ui/common/icons/units/ or icons/units/, any letter case), in
-- another mod's folder, and not at all when there is none; a miss is cached only briefly (IconRefresh forgets it); the mesh file of a mod unit is found from its mesh blueprint; the thumbnail
-- ladder of the unit browser (icon, picture from the mesh, the game's placeholder). The file natives and the blueprints are replaced for the run and put back afterwards.

local Units = import('/lua/editor/units.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

function Run()
    out, failed = {}, 0
    local files = {
        ['/textures/ui/common/icons/units/uel0001_icon.dds'] = true,
        ['/mods/mymod/textures/ui/common/icons/units/zmod0001_icon.dds'] = true,
        ['/mods/mymod/icons/units/zmod0003_icon.dds'] = true,
        ['/mods/elsewhere/textures/ui/common/icons/units/zmod0004_icon.dds'] = true,
        ['/textures/ui/common/icons/units/default_icon.dds'] = true,
        ['/mods/mymod/units/zmod0002/zmod0002_lod0.scm'] = true,
    }
    local oldInfo, oldFind, oldBp = rawget(_G, 'DiskGetFileInfo'), rawget(_G, 'DiskFindFiles'), rawget(_G, '__blueprints')
    local fakeBp = {
        uel0001 = { BlueprintId = 'uel0001', Source = '/units/uel0001/uel0001_unit.bp', Display = {} },
        zmod0001 = { BlueprintId = 'zmod0001', Source = '/mods/MyMod/units/zmod0001/zmod0001_unit.bp', Display = {} },
        zmod0002 = { BlueprintId = 'zmod0002', Source = '/mods/MyMod/units/zmod0002/zmod0002_unit.bp', Display = { MeshBlueprint = '/mods/MyMod/units/zmod0002/zmod0002_mesh' } },
        zmod0003 = { BlueprintId = 'zmod0003', Source = '/mods/MyMod/units/zmod0003/zmod0003_unit.bp', Display = {} },
        zmod0004 = { BlueprintId = 'zmod0004', Source = '/mods/MyMod/units/zmod0004/zmod0004_unit.bp', Display = {} },
        zmod0005 = { BlueprintId = 'zmod0005', Display = {} },
    }
    fakeBp['/mods/MyMod/units/zmod0002/zmod0002_mesh'] = { LODs = { { MeshName = '/mods/MyMod/units/zmod0002/zmod0002_lod0.scm' } } }

    local ok, err = pcall(function()
        rawset(_G, 'DiskGetFileInfo', function(p) if files[string.lower(p)] then return { SizeBytes = 1 } end return false end)
        rawset(_G, 'DiskFindFiles', function(dir, pattern)
            local list = {}
            -- (any mod folder: the icon of the other mod)
            if string.find(string.lower(dir), '/mods/', 1, true) then table.insert(list, '/mods/elsewhere/textures/ui/common/icons/units/zmod0004_icon.dds') end
            return list
        end)
        rawset(_G, '__blueprints', fakeBp)
        Units.IconRefresh()

        Ok(Units.IconPath('uel0001') == '/textures/ui/common/icons/units/UEL0001_icon.dds', 'a game unit: the icon of the game folder by its id')
        Ok(Units.IconPath('zmod0001') == '/mods/MyMod/textures/ui/common/icons/units/ZMOD0001_icon.dds', 'a mod unit: the icon in the mod\'s own textures folder (any letter case)')
        Ok(Units.IconPath('zmod0003') == '/mods/MyMod/icons/units/ZMOD0003_icon.dds', 'a mod unit: the icon in the mod\'s icons/units folder')
        Ok(Units.IconPath('zmod0004') == '/mods/elsewhere/textures/ui/common/icons/units/zmod0004_icon.dds', 'a mod unit: the icon another mod ships')
        Ok(Units.IconPath('zmod0002') == nil and Units.IconPath('zmod0005') == nil and Units.IconPath('') == nil, 'no icon: nil')
        local dir, root = Units.SourceFolders(fakeBp.zmod0001)
        Ok(dir == '/mods/MyMod/units/zmod0001' and root == '/mods/MyMod', 'the folders of a blueprint source')
        local d2, r2 = Units.SourceFolders(fakeBp.uel0001)
        Ok(d2 == '/units/uel0001' and r2 == nil, 'a game unit has no mod root')
        Ok(Units.MeshFile('zmod0002') == '/mods/MyMod/units/zmod0002/zmod0002_lod0.scm' and Units.MeshFile('zmod0001') == nil, 'the mesh file of a mod unit comes from its mesh blueprint')
        Ok(Units.GenericIconPath('zmod0005') == '/textures/ui/common/icons/units/default_icon.dds', 'the placeholder of the game is the last resort')

        files['/mods/mymod/textures/ui/common/icons/units/zmod0002_icon.dds'] = true
        Ok(Units.IconPath('zmod0002') == nil, 'a miss is remembered for a few seconds')
        Units.IconRefresh()
        Ok(Units.IconPath('zmod0002') == '/mods/MyMod/textures/ui/common/icons/units/ZMOD0002_icon.dds', 'IconRefresh finds an icon written meanwhile')
        files['/mods/mymod/textures/ui/common/icons/units/zmod0002_icon.dds'] = nil

        local Cat = import('/lua/editor/assetcat.lua')
        Ok(Cat.Thumb({ kind = 'units', key = 'zmod0001' }) == '/mods/MyMod/textures/ui/common/icons/units/ZMOD0001_icon.dds', 'the unit browser shows the mod\'s own icon')
        Units.IconRefresh()
        Ok(Cat.Thumb({ kind = 'units', key = 'zmod0005' }) == '/textures/ui/common/icons/units/default_icon.dds', 'a unit without icon and mesh shows the game\'s placeholder')
    end)
    if not ok then Ok(false, 'the run stopped with an error: ' .. tostring(err)) end

    rawset(_G, 'DiskGetFileInfo', oldInfo)
    rawset(_G, 'DiskFindFiles', oldFind)
    rawset(_G, '__blueprints', oldBp)
    Units.IconRefresh()
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end
