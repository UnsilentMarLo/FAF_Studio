-- Self test of the new unit wizard (unitwiz.lua), its validators (unitcheck.lua), the skinned SCM writer (scm.lua), the preview icon (quickicon.lua) and the project integration (bpedit.lua). Through /edcmd:
--   return import('/lua/editor/selftest_unitwiz.lua').Run()
-- Uses the project "selftest_unitwiz" (its files stay in the instance's modproj folder; the units are rewritten each run), puts the open project back afterwards.

local Bp = import('/lua/editor/bpedit.lua')
local Wiz = import('/lua/editor/unitwiz.lua')
local Check = import('/lua/editor/unitcheck.lua')
local Scm = import('/lua/editor/scm.lua')
local Data = import('/lua/editor/unitwizdata.lua')
local Quick = import('/lua/editor/quickicon.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Has(list, text, sev)
    for _, p in list do
        if string.find(p.text, text, 1, true) and (not sev or p.sev == sev) then return p end
    end
    return nil
end

local function Count(list, sev)
    local n = 0
    for _, p in list do if p.sev == sev then n = n + 1 end end
    return n
end

local function Dump(list)
    local lines = {}
    for _, p in list do table.insert(lines, '      [' .. p.sev .. '] ' .. p.text) end
    return table.concat(lines, '\n')
end

-- a small OBJ: a body, a turret (named like a bone of the bot skeleton) and a barrel
local OBJ = [[
o Body
v -1 0 -2
v 1 0 -2
v 1 1 -2
v -1 1 -2
v -1 0 2
v 1 0 2
v 1 1 2
v -1 1 2
f 1 2 3 4
f 8 7 6 5
f 5 6 2 1
f 4 3 7 8
f 2 6 7 3
f 5 1 4 8
o Torso
v -0.5 1 -0.5
v 0.5 1 -0.5
v 0.5 1.6 -0.5
v -0.5 1.6 -0.5
v -0.5 1 0.5
v 0.5 1 0.5
v 0.5 1.6 0.5
v -0.5 1.6 0.5
f 9 10 11 12
f 16 15 14 13
f 13 14 10 9
f 12 11 15 16
f 10 14 15 11
f 13 9 12 16
]]

function Run()
    out, failed = {}, 0
    local savedProject, savedEdits, savedDerived, savedNew = Bp.Project, Bp.Edits, Bp.Derived, Bp.NewUnits
    local name = 'selftest_unitwiz'
    if not Bp.Create(name) then Bp.Open(name) end
    Bp.Edits, Bp.Derived, Bp.NewUnits = {}, {}, {}
    local dir = Bp.ROOT .. '/' .. name
    -- files an earlier (aborted) run left: make them the wizard's again so that they are rewritten
    for _, id in { 'zel0001', 'zel0002' } do
        for _, suffix in { '_unit.bp', '_script.lua', '_strings.lua' } do
            local path = dir .. '/units/' .. id .. '/' .. id .. suffix
            if ed_file_stamp(path) then ed_write_file(path, Wiz.MARK .. '\n') end
        end
    end

    -- ---- data and bind pose ----
    local donors = 0
    for _ in Data.Donors do donors = donors + 1 end
    Ok(donors == 35, 'the donor data has 35 units (' .. donors .. ')')
    local worst = 0
    for id, d in Data.Donors do
        local bones = {}
        for i, row in d.bones do bones[i] = { name = row[1], parent = row[2], pos = { row[15], row[16], row[17] }, rot = { row[18], row[19], row[20], row[21] } } end
        Scm.BindPose(bones)
        for i, row in d.bones do
            for k = 1, 12 do
                local e = math.abs(bones[i].rest[k] - row[2 + k])
                if e > worst then worst = e end
            end
        end
    end
    Ok(worst < 0.002, string.format('the inverse bind pose computed from position and rotation matches the shipped one (largest difference %.5f)', worst))

    -- ---- category expressions ----
    local set = { BUILTBYTIER1FACTORY = true, UEF = true, MOBILE = true, LAND = true, TECH1 = true }
    Ok(Check.EvalCategory('BUILTBYTIER1FACTORY UEF MOBILE LAND', set), 'a space is an intersection')
    Ok(not Check.EvalCategory('BUILTBYTIER1FACTORY AEON MOBILE LAND', set), 'a missing category fails the intersection')
    Ok(Check.EvalCategory('(AEON + UEF) * LAND', set) and not Check.EvalCategory('UEF - LAND', set), '+ unites, - subtracts, brackets group')

    -- ---- every template, every faction ----
    local bad = {}
    local reach = 0
    for _, t in Wiz.Templates do
        for _, faction in Wiz.Factions do
            local id = 'zq' .. string.sub(t.id, 1, 1) .. string.sub(faction, 1, 1) .. '0001'
            local spec = Wiz.NewSpec(t.id, faction, id)
            if not spec then
                table.insert(bad, t.id .. '/' .. faction .. ': no spec')
            else
                local text = Wiz.BlueprintText(spec)
                local bp, why = Check.LoadBlueprint(text)
                if not bp then table.insert(bad, t.id .. '/' .. faction .. ' blueprint: ' .. tostring(why)) end
                local fn, err = Check.Compile(Wiz.ScriptText(spec))
                if not fn then table.insert(bad, t.id .. '/' .. faction .. ' script: ' .. tostring(err)) end
                local fn2 = Check.Compile(Wiz.StringsText(spec))
                if bp then
                    local cset = {}
                    for _, c in bp.Categories do cset[c] = true end
                    if table.getn(Check.Builders(cset)) > 0 then reach = reach + 1 else table.insert(bad, t.id .. '/' .. faction .. ': nothing builds it') end
                    if t.mobile and not cset.MOBILE then table.insert(bad, t.id .. '/' .. faction .. ': not MOBILE') end
                    if t.layer == 'structure' and not cset.STRUCTURE then table.insert(bad, t.id .. '/' .. faction .. ': not STRUCTURE') end
                    if not (cset.TECH1) then table.insert(bad, t.id .. '/' .. faction .. ': no TECH1') end
                end
            end
        end
    end
    Ok(table.getn(bad) == 0, 'all 36 template / faction pairs make a blueprint and a script that compile, are TECH1 and are built by some factory or engineer of the game (' .. reach .. ' of 36 reachable)' .. (table.getn(bad) > 0 and ('\n      ' .. table.concat(bad, '\n      ')) or ''))

    -- ---- the blueprint of a bot ----
    local spec = Wiz.NewSpec('bot', 'UEF', 'zel0001')
    spec.name, spec.description = 'Test Bot', 'Selftest assault bot'
    local bp = Check.LoadBlueprint(Wiz.BlueprintText(spec))
    Ok(bp and bp.Weapon and bp.Weapon[1] and bp.Weapon[1].Label == 'MainGun' and bp.Weapon[1].TurretBoneYaw == 'Torso', 'the bot has one weapon, MainGun, aimed with the donor\'s Torso bone')
    Ok(bp and bp.Display.Mesh.LODs[1].ShaderName ~= nil and bp.Display.UniformScale == 0.0625, 'mesh LOD and uniform scale come from the template')
    Ok(bp and bp.General.UnitName == '<LOC zel0001_name>Test Bot' and bp.Description == '<LOC zel0001_desc>Selftest assault bot', 'name and description are <LOC> keys with the text as fallback')
    local has = {}
    for _, c in bp.Categories do has[c] = true end
    Ok(has.UEF and has.TECH1 and has.MOBILE and has.LAND and has.DIRECTFIRE and not has.PRODUCTSC1, 'categories: faction, tech, layer, weapon; nothing donor specific (PRODUCTSC1)')
    Ok(Wiz.CheckId('zel0001') and not Wiz.CheckId('Zel0001') and not Wiz.CheckId('uel0106') and not Wiz.CheckId('abc'), 'id rules: lower case, at least 6, not a game unit')
    Ok(string.find(Wiz.ScriptText(spec), 'MainGun = ClassWeapon(TDFMachineGunWeapon)', 1, true) ~= nil and string.find(Wiz.ScriptText(spec), 'ZEL0001 = ClassUnit(TWalkingLandUnit)', 1, true) ~= nil, 'the script derives from TWalkingLandUnit with a weapon class by label')
    spec.tech = 2
    spec.buildBy = Wiz.DefaultBuildBy(Wiz.Template('bot'), 2)
    local cats2 = Wiz.Categories(spec)
    local has2 = {}
    for _, c in cats2 do has2[c] = true end
    Ok(has2.TECH2 and not has2.TECH1 and not has2.BUILTBYTIER1FACTORY and has2.BUILTBYTIER2FACTORY, 'tech 2 changes the tech category and the factory tiers')
    spec.tech = 1
    spec.buildBy = Wiz.DefaultBuildBy(Wiz.Template('bot'), 1)

    -- ---- the skinned SCM ----
    local data, info, mesh = Wiz.Mesh(spec, nil)
    Ok(data ~= nil and info.placeholder and info.vertices > 0 and info.bones == 19, 'a placeholder mesh in the 19 bone skeleton of the donor (' .. tostring(info and info.vertices) .. ' vertices)')
    if data then
        local bones = Scm.Bones(data)
        Ok(bones and table.getn(bones) == 19 and bones[2].name == 'Torso' and bones[2].parent == 0 and bones[1].parent == -1, 'the SCM file reads back with the bone names and parents')
        local h = Scm.Header(data)
        Ok(h and h.vertexCount == info.vertices, 'the header counts the vertices')
        local m2 = Scm.Read(data)
        Ok(m2 and m2.n == info.vertices, 'the mesh reads back (Scm.Read)')
        -- the vertex bone bytes: the turret box is on the Torso bone (index 1)
        local boneOf = {}
        local vat = h.vertexAt
        for k = 0, h.vertexCount - 1 do
            local b = string.byte(data, vat + k * 68 + 65)
            boneOf[b] = (boneOf[b] or 0) + 1
        end
        Ok(boneOf[0] and boneOf[1], 'vertices are bound to the root and to the Torso bone')
        local x0, y0, z0, x1, y1, z1 = Scm.FileBounds(data)
        Ok(x0 and x1 > x0 and y1 > y0, 'FileBounds reads the box')
    end

    -- ---- OBJ import: groups become bone bindings ----
    spec.mesh.source = ''
    local data2, info2 = Wiz.Mesh(spec, OBJ)
    Ok(data2 ~= nil and not info2.placeholder and info2.vertices == 16, 'the OBJ (2 boxes) imports to 16 welded vertices, skinned to the template skeleton (' .. tostring(info2 and info2.vertices) .. ')')
    if data2 then
        local h = Scm.Header(data2)
        local counts = {}
        for k = 0, h.vertexCount - 1 do
            local b = string.byte(data2, h.vertexAt + k * 68 + 65)
            counts[b] = (counts[b] or 0) + 1
        end
        Ok(counts[0] == 8 and counts[1] == 8, 'the group named Torso is bound to bone 1, the other group to the root')
        local x0, y0, z0, x1, y1, z1 = Scm.FileBounds(data2)
        local us = 0.0625
        local length = math.max(x1 - x0, z1 - z0) * us
        Ok(math.abs(length - spec.mesh.length) < spec.mesh.length * 0.01, string.format('the mesh is scaled to the spec length (%.3f against %.3f)', length, spec.mesh.length))
    end
    spec.mesh.skeleton = 'groups'
    local data3, info3 = Wiz.Mesh(spec, OBJ)
    Ok(data3 ~= nil and info3.bones == 3, 'a skeleton from the OBJ groups: root + 2 bones (' .. tostring(info3 and info3.bones) .. ')')
    spec.mesh.skeleton = 'template'

    -- ---- writing a project with a new unit ----
    local ok, why = Bp.AddNew(spec)
    Ok(ok, 'AddNew accepts the spec ' .. tostring(why))
    Ok(not Bp.AddNew(Wiz.NewSpec('bot', 'UEF', 'zel0001')), 'the same id twice is refused')
    local n = Bp.Write()
    Ok(n ~= nil and table.getn(Bp.Report or {}) == 0, 'Write makes the unit\'s files (' .. tostring(n) .. ' files written; report: ' .. table.concat(Bp.Report or {}, '; ') .. ')')
    for _, rel in { 'units/zel0001/zel0001_unit.bp', 'units/zel0001/zel0001_script.lua', 'units/zel0001/zel0001_strings.lua', 'units/zel0001/zel0001_lod0.scm', 'units/zel0001/zel0001_albedo.dds',
                    'units/zel0001/zel0001_normalsts.dds', 'units/zel0001/zel0001_specteam.dds', 'textures/ui/common/icons/units/zel0001_icon.dds' } do
        Ok(ed_file_stamp(dir .. '/' .. rel) ~= nil, rel .. ' exists')
    end
    local alb = ed_read_file(dir .. '/units/zel0001/zel0001_albedo.dds')
    Ok(alb and string.sub(alb, 1, 4) == 'DDS ' and string.sub(alb, 85, 88) == 'DXT5', 'the placeholder albedo is a DXT5 DDS')
    local icon = ed_read_file(dir .. '/textures/ui/common/icons/units/zel0001_icon.dds')
    Ok(icon and string.len(icon) == 4224, 'the preview icon is 64 x 64 DXT5 without mip maps like the shipped ones (' .. tostring(icon and string.len(icon)) .. ' bytes)')
    local px = ed_dds_read(dir .. '/textures/ui/common/icons/units/zel0001_icon.dds')
    local opaque = 0
    if px then for i = 0, 64 * 64 - 1 do if px[i * 4 + 4] > 128 then opaque = opaque + 1 end end end
    Ok(opaque > 400 and opaque < 3800, 'the icon shows the unit (' .. opaque .. ' of 4096 pixels solid)')

    -- ---- validators on the written unit ----
    local list = Check.Check('zel0001', Bp.NewUnits.zel0001, Bp.Edits.zel0001)
    Ok(Count(list, 'E') == 0, 'no errors on the fresh unit (' .. Count(list, 'E') .. ')' .. (Count(list, 'E') > 0 and ('\n' .. Dump(list)) or ''))
    Ok(Count(list, 'W') == 0, 'no warnings on the fresh unit (' .. Count(list, 'W') .. ')' .. (Count(list, 'W') > 0 and ('\n' .. Dump(list)) or ''))

    -- persistence
    Bp.Open(name)
    Ok(Bp.NewUnits.zel0001 and Bp.NewUnits.zel0001.weapons[1].label == 'MainGun' and Bp.NewUnits.zel0001.name == 'Test Bot', 'the new unit survives closing and opening the project (edits.lua)')

    -- the unit lab sees the unit: fields and edits go into the generated blueprint
    local fields = Bp.Fields('zel0001')
    local found
    for _, f in fields do if f.key == 'Weapon:MainGun.Damage' then found = f end end
    Ok(table.getn(fields) > 10 and found ~= nil, 'the unit lab lists the new unit\'s fields (' .. table.getn(fields) .. ') including its weapon damage')
    Bp.Set('zel0001', 'Weapon:MainGun.Damage', found and (found.base + 5) or 12)
    Bp.Set('zel0001', 'Economy.BuildCostMass', 77)
    Bp.Write()
    local edited = Check.LoadBlueprint(ed_read_file(dir .. '/units/zel0001/zel0001_unit.bp'))
    Ok(edited and edited.Economy.BuildCostMass == 77 and edited.Weapon[1].Damage == (found and found.base + 5 or 12), 'unit lab edits end up in the generated blueprint')
    Ok(ed_file_stamp(Bp.FilePath(dir, 'zel0001')) == ed_file_stamp(dir .. '/units/zel0001/zel0001_unit.bp'), 'no separate merge blueprint is written for a new unit')
    Bp.Edits.zel0001 = nil

    -- ---- the validators find what is wrong ----
    local bpPath = dir .. '/units/zel0001/zel0001_unit.bp'
    local original = ed_read_file(bpPath)
    local function WithBlueprint(text, fn)
        ed_write_file(bpPath, text)
        local l = Check.Check('zel0001', Bp.NewUnits.zel0001, nil)
        fn(l)
        ed_write_file(bpPath, original)
    end
    WithBlueprint(string.gsub(original, 'TurretBoneYaw = "Torso"', 'TurretBoneYaw = "Turret_Gone"'), function(l)
        Ok(Has(l, 'Turret_Gone', 'E'), 'a weapon bone that is not in the mesh is an error')
    end)
    WithBlueprint(string.gsub(original, 'TurretBoneYaw = "Torso"', 'TurretBoneYaw = "torso"'), function(l)
        Ok(Has(l, 'case', 'W') and not Has(l, 'torso', 'E'), 'a bone name differing in case is a warning')
    end)
    WithBlueprint(string.gsub(original, 'Label = "MainGun"', 'Label = "Cannon"'), function(l)
        Ok(Has(l, 'weapon Cannon has no entry in the script', 'E') and Has(l, 'script has a weapon MainGun', 'W'), 'weapon labels against the script names, both ways (the fix writes the script again)')
        local p = Has(l, 'weapon Cannon has no entry', 'E')
        Ok(p and p.fix ~= nil, 'the label mismatch comes with a fix')
    end)
    WithBlueprint(string.gsub(original, 'SizeX = [%d%.]+', 'SizeX = 9'), function(l)
        local p = Has(l, 'SizeX 9.00 against the mesh', 'W')
        Ok(p and p.fix, 'a collision box far from the mesh bounds is a warning with a fix')
    end)
    WithBlueprint(string.gsub(original, 'SizeZ = [%d%.]+', 'SizeZ = 0.2'), function(l)
        local p = Has(l, 'SizeZ 0.20 is below 10%', 'W')
        Ok(p and p.fix, 'a collision box below 10 percent of the top speed (the engine overrides it) is a warning with a fix')
    end)
    WithBlueprint(string.gsub(original, 'LODCutoff = (%d+)', 'LODCutoff = 30', 1), function(l)
        Ok(Has(l, 'LOD 1 ends at 30', 'W'), 'a first LOD cutoff below 70 is a warning')
    end)
    WithBlueprint(string.gsub(original, '"TECH1",', '', 1), function(l)
        Ok(Has(l, 'no tech category', 'E'), 'a missing tech category is an error')
    end)
    WithBlueprint(string.gsub(original, '"BUILTBY[%u%d]+",', ''), function(l)
        Ok(Has(l, 'nothing can build the unit', 'E'), 'a unit no builder\'s BuildableCategory matches is an error')
        local p = Has(l, 'nothing can build the unit', 'E')
        Ok(p and p.fix, 'it comes with a fix')
    end)
    WithBlueprint(string.gsub(original, 'Animation = "/units/uel0106/uel0106_Adeath01.sca"', 'Animation = "/units/uel0106/nothere.sca"'), function(l)
        Ok(Has(l, 'nothere.sca', 'E'), 'an animation file the game does not have is an error')
    end)
    WithBlueprint(string.gsub(original, 'BuildTime = %d+', 'BuildTime = 0'), function(l)
        Ok(Has(l, 'BuildTime is 0', 'E'), 'build time 0 is an error')
    end)
    WithBlueprint('UnitBlueprint { Broken = ', function(l)
        Ok(Has(l, 'does not compile', 'E'), 'a blueprint that does not compile is an error')
    end)
    -- files
    local scriptPath = dir .. '/units/zel0001/zel0001_script.lua'
    local script = ed_read_file(scriptPath)
    ed_write_file(scriptPath, 'this is not lua (')
    local l = Check.Check('zel0001', Bp.NewUnits.zel0001, nil)
    Ok(Has(l, 'script does not compile', 'E'), 'a script that does not compile is an error')
    ed_write_file(scriptPath, string.gsub(script, 'local DefaultProjectileWeapon', 'local X'))
    ed_write_file(scriptPath, script)
    local iconPath = dir .. '/textures/ui/common/icons/units/zel0001_icon.dds'
    local iconData = ed_read_file(iconPath)
    ed_write_file(iconPath, '')
    -- an empty file still exists; remove it by writing it elsewhere is not possible, so check the reverse: the generated files are current
    ed_write_file(iconPath, iconData)
    l = Check.Check('zel0001', Bp.NewUnits.zel0001, nil)
    Ok(Count(l, 'E') == 0 and Count(l, 'W') == 0, 'everything put back: clean again')
    -- missing files: use another unit that was never written
    -- an id whose files do not exist yet: the ids came from the clock before, so a second run (or a restarted editor at the same clock phase) found the files of the first one
    -- and 'is missing' was not reported: the flaky failure of selftest_unitwiz. There is no way to delete a file, so the id is searched.
    local gid
    for k = 1, 9999 do
        local try = string.format('zaq%04d', k)
        if not ed_file_stamp(dir .. '/units/' .. try .. '/' .. try .. '_unit.bp') and not ed_file_stamp(dir .. '/units/' .. try .. '/' .. try .. '_lod0.scm') then gid = try break end
    end
    local ghost = Wiz.NewSpec('tank', 'Aeon', gid)
    Bp.NewUnits[gid] = ghost
    l = Check.Check(gid, ghost, nil)
    Ok(Has(l, gid .. '_unit.bp is missing', 'E') and Has(l, gid .. '_lod0.scm is missing', 'E') and Has(l, 'no icon', 'W'), 'missing blueprint, mesh and icon are reported')
    local fix = Has(l, gid .. '_unit.bp is missing', 'E')
    if fix and fix.fix then fix.fix() end
    l = Check.Check(gid, ghost, nil)
    Ok(Count(l, 'E') == 0, 'the write fix makes the missing files (errors left: ' .. Count(l, 'E') .. ')' .. (Count(l, 'E') > 0 and ('\n' .. Dump(l)) or ''))
    Bp.NewUnits[gid] = nil
    -- a unit of the game with the same id
    local clash = Wiz.NewSpec('bot', 'UEF', 'uel0106')
    Bp.NewUnits.uel0106 = clash
    l = Check.Check('uel0106', clash, nil)
    Ok(Has(l, 'already has a unit', 'E'), 'an id the game already uses is an error')
    Bp.NewUnits.uel0106 = nil

    -- ---- weapon kinds and templates without weapons ----
    local sub = Wiz.NewSpec('naval', 'Cybran', 'zrs0001')
    table.insert(sub.weapons, Wiz.NewWeapon(sub, 'torpedo', 'Torpedo01'))
    local sbp = Check.LoadBlueprint(Wiz.BlueprintText(sub))
    Ok(sbp and table.getn(sbp.Weapon) == 2 and sbp.Weapon[2].Label == 'Torpedo01' and sbp.Weapon[2].ProjectileId ~= nil, 'a torpedo is added from the weapon template of its kind')
    local scat = {}
    for _, c in sbp.Categories do scat[c] = true end
    Ok(scat.ANTINAVY and scat.NAVAL, 'the torpedo adds ANTINAVY; the naval template is NAVAL')
    local fac = Wiz.NewSpec('factory', 'Aeon', 'zab0001')
    local fbp = Check.LoadBlueprint(Wiz.BlueprintText(fac))
    Ok(fbp and fbp.Weapon == nil and fbp.Economy.BuildableCategory and fbp.Physics.SkirtSizeX, 'a factory has no weapon, a BuildableCategory and a skirt')

    -- ---- texture import: a shipped icon (DXT5) as albedo, converted with mip maps ----
    local tspec = Wiz.NewSpec('tank', 'UEF', 'zel0002')
    tspec.textures.albedo = '/textures/ui/common/icons/units/UEL0201_icon.dds'
    Bp.NewUnits.zel0002 = tspec
    local n2, report = Wiz.Write(dir, tspec, nil)
    local imported = ed_read_file(dir .. '/units/zel0002/zel0002_albedo.dds')
    Ok(imported and string.sub(imported, 1, 4) == 'DDS ' and string.len(imported) > 4224, 'a DDS source is converted to DXT5 with mip maps (' .. tostring(imported and string.len(imported)) .. ' bytes; ' .. table.concat(report, '; ') .. ')')
    tspec.textures.albedo = '/textures/nothing/here.dds'
    local n3, report3 = Wiz.Write(dir, tspec, nil)
    Ok(Has({ { text = table.concat(report3, ' '), sev = 'E' } }, 'Albedo'), 'an unreadable texture source is reported')
    Bp.NewUnits.zel0002 = nil

    -- ---- preview icon ----
    local cube = Scm.New()
    local m3 = Wiz.BuildMesh(tspec, nil)
    local r = Quick.Render(m3, {})
    Ok(r and r.w == 64 and table.getn(r.px) == 64 * 64 * 4, 'the preview icon renders 64 x 64')

    -- ---- put everything back ----
    Bp.Edits, Bp.Derived, Bp.NewUnits = savedEdits, savedDerived, savedNew
    if savedProject then Bp.Open(savedProject) else Bp.Project = false end
    Bp.Revision = Bp.Revision + 1
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end
