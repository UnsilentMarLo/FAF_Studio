-- Mod project: effect / projectile field edits (fxedit.lua, bpedit.lua), project validators (modcheck.lua), unit viewer presets (unitview.lua). Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_modproj.lua').Run()
-- Uses the project "selftest_modproj" (made on the first run; its files stay in the instance's modproj folder), puts the edits and the open project back afterwards.

local Bp = import('/lua/editor/bpedit.lua')
local Fx = import('/lua/editor/fxedit.lua')
local Check = import('/lua/editor/modcheck.lua')
local View = import('/lua/editor/unitview.lua')
local World = import('/lua/editor/world.lua')
local H = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Find(list, key)
    for _, f in list do if f.key == key then return f end end
    return nil
end

local function IssueWith(text)
    for _, i in Check.Issues do
        if string.find(i.text, text, 1, true) then return i end
    end
    return nil
end

function Run()
    out, failed = {}, 0
    local savedProject, savedEdits, savedDerived = Bp.Project, Bp.Edits, Bp.Derived
    local name = 'selftest_modproj'
    local ok = Bp.Create(name)
    if not ok then Bp.Open(name) end
    Bp.Edits, Bp.Derived = {}, {}

    -- emitter fields
    local emitter = '/effects/emitters/dust_small_emit.bp'
    Ok(Fx.Kind(emitter) == 'emitter' and Fx.Kind('/projectiles/a/a_proj.bp') == 'projectile' and Fx.Kind('/units/uel0106/uel0106_unit.bp') == nil and Fx.Kind('uel0106') == nil, 'ids are told apart by their path')
    local fields = Bp.Fields(emitter)
    Ok(table.getn(fields) > 20, 'the emitter has editable numbers (' .. table.getn(fields) .. ')')
    local life = Find(fields, 'Lifetime')
    Ok(life ~= nil and life.base == 2, 'Lifetime is there with the game value 2')
    local curve = Find(fields, 'EmitRateCurve.Keys.1.y')
    Ok(curve ~= nil, 'curve keys are fields (EmitRateCurve.Keys.1.y)')
    Bp.Set(emitter, 'Lifetime', 3.5)
    Bp.Set(emitter, 'EmitRateCurve.Keys.1.y', 1.25)
    Ok(Bp.Get(emitter, 'Lifetime') == 3.5, 'the edit is read back')
    local text = Bp.MergeText(emitter)
    local captured
    local fn = loadstring(text or '')
    Ok(fn ~= nil, 'the emitter merge blueprint compiles')
    if fn then
        setfenv(fn, { EmitterBlueprint = function(bp) captured = bp end })
        pcall(fn)
    end
    Ok(captured and captured.Merge == true and captured.Source == emitter and captured.Lifetime == 3.5, 'it names the game file (Source) and carries the delta')
    Ok(captured and captured.EmitRateCurve and captured.EmitRateCurve.Keys and captured.EmitRateCurve.Keys[1] and captured.EmitRateCurve.Keys[1].y == 1.25 and captured.EmitRateCurve.Keys[1].x == nil, 'a curve key is merged by index, only the changed field')
    Bp.Revert(emitter, 'Lifetime')
    Ok(Bp.Get(emitter, 'Lifetime') == 2, 'revert goes back to the game value')

    -- projectile fields
    local proj
    for k, v in __blueprints do
        if type(k) == 'string' and string.find(k, '^/projectiles/') and v.Physics and v.Physics.MaxSpeed and v.Physics.MaxSpeed > 0 then proj = k break end
    end
    Ok(proj ~= nil and Find(Bp.Fields(proj), 'Physics.MaxSpeed') ~= nil, 'a projectile has Physics.MaxSpeed as a field')
    Bp.Set(proj, 'Physics.MaxSpeed', 77)
    local ptext = Bp.MergeText(proj) or ''
    Ok(string.find(ptext, 'ProjectileBlueprint', 1, true) ~= nil and string.find(ptext, "Source = '" .. proj .. "'", 1, true) ~= nil and string.find(ptext, 'MaxSpeed = 77', 1, true) ~= nil, 'the projectile merge blueprint names the file and the field')
    local n = Bp.Write()
    Ok(n ~= nil and n >= 2, 'Write puts the merge blueprints into the project (' .. tostring(n) .. ' files)')
    local onDisk = ed_read_file(Bp.FilePath(Bp.ROOT .. '/' .. name, string.lower(proj)))
    Ok(onDisk == ptext, 'the projectile file on disk is the merge text')

    -- validators
    Check.Run()
    Ok(IssueWith('differs from the edits') == nil and IssueWith('not written yet') == nil, 'written files are current')
    Bp.Set(emitter, 'Lifetime', 4)
    Check.Run()
    Ok(IssueWith(emitter) ~= nil and IssueWith('differs') ~= nil, 'a changed edit makes the file stale')
    Bp.Edits['/effects/emitters/does_not_exist_emit.bp'] = { Lifetime = 1 }
    Check.Run()
    Ok(IssueWith('does_not_exist_emit') ~= nil, 'an emitter the game does not have is an error')
    Bp.Edits['/effects/emitters/does_not_exist_emit.bp'] = nil
    Bp.Edits['UEL0106'] = { ['Economy.BuildCostMass'] = 5 }
    Check.Run()
    Ok(IssueWith('lower case') ~= nil, 'an upper case unit id is an error')
    Bp.Edits['UEL0106'] = nil
    Bp.Derived['ZML'] = { base = 'uel0106', name = '', description = '' }
    Check.Run()
    Ok(IssueWith('derived unit id') ~= nil, 'an invalid derived unit id is an error')
    Bp.Derived['ZML'] = nil
    Bp.Derived['zml0002'] = { base = 'uel0106', name = '', description = '' }
    Check.Run()
    Ok(IssueWith('zml0002: no icon yet') ~= nil, 'a derived unit without an icon is reported')
    Bp.Derived['zml0002'] = nil
    Bp.Edits['uel0106'] = { ['Weapon:NoSuchWeapon.Damage'] = 5 }
    Check.Run()
    Ok(IssueWith('NoSuchWeapon') ~= nil, 'a weapon label the unit does not have is reported')
    Bp.Edits['uel0106'] = nil
    Check.Run()
    local errors = 0
    for _, i in Check.Issues do if i.sev == 'E' then errors = errors + 1 end end
    Ok(errors == 0, 'no errors left in the clean project (' .. errors .. ')')

    -- unit viewer: LODs, presets (the stage, camera and 3D drawing are in selftest_viewer.lua)
    local lods = View.LODs('uel0106')
    Ok(table.getn(lods) >= 1 and lods[1].cutoff > 0 and lods[1].from == 0, 'the unit blueprint names its LODs (' .. table.getn(lods) .. ')')
    if table.getn(lods) >= 2 then Ok(lods[2].from == lods[1].cutoff, 'LOD 2 starts where LOD 1 ends') end
    local depth = H.Depth()
    local before = World.Value('light_mult') * 1000 + World.Value('sun_y') * 100
    Ok(View.SetLight('Overcast') and World.Value('sun_y') == 1, 'a lighting preset changes the sun')
    Ok(View.SetLight('Map') and math.abs(World.Value('light_mult') * 1000 + World.Value('sun_y') * 100 - before) < 0.01, 'the map preset puts the map lighting back')
    for i = 1, 2 do pcall(H.Undo) end
    Ok(View.SetColor('Red') and View.ColorName == 'Red' and View.SetColor('Army') and View.ColorName == 'Army', 'team colour presets are accepted')

    -- put everything back
    Bp.Edits, Bp.Derived = savedEdits, savedDerived
    if savedProject then Bp.Open(savedProject) else Bp.Project = false end
    Bp.Revision = Bp.Revision + 1
    Check.Run()
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end
