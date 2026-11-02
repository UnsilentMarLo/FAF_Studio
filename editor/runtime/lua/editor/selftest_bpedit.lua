-- Mod project safety (bpedit.lua): undo of add / remove, history scoped to a project, a raising change, backups, a damaged edits.lua, the gate before writing, stable uids. Through /edcmd:
--   return import('/lua/editor/selftest_bpedit.lua').Run()
-- Uses the projects "st_bpedit_a" and "st_bpedit_b" (made on the first run, kept in the instance's modproj folder); puts the open project back.

local Bp = import('/lua/editor/bpedit.lua')
local Wiz = import('/lua/editor/unitwiz.lua')
local H = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Ok(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Count(t)
    local n = 0
    for _ in t do n = n + 1 end
    return n
end

function Run()
    out, failed = {}, 0
    local savedProject = Bp.Project
    local nameA, nameB = 'st_bpedit_a', 'st_bpedit_b'
    if not Bp.Create(nameA) then Bp.Open(nameA) end
    Bp.Edits, Bp.Derived, Bp.NewUnits = {}, {}, {}
    local dirA = Bp.ROOT .. '/' .. nameA
    ed_write_file(dirA .. '/edits.lua', 'version = 1\nEdits = {}\n')
    ed_write_file(dirA .. '/edits.lua.bak', '')
    Bp.Open(nameA)
    local uidA = Bp.Uid

    -- uids
    Ok(type(uidA) == 'string' and string.find(uidA, '^ED%x%x%x%x%x%x%-%x%x%x%x%-4D57%-%x%x%x%x%-%x+$') ~= nil, 'a project has a uid in mod_info.lua: ' .. tostring(uidA))
    Bp.Open(nameA)
    Ok(Bp.Uid == uidA, 'the uid is read back, not derived: it stays the same after Open')

    -- a raising change leaves the project as it was
    local id, key = 'uel0106', 'Economy.BuildCostMass'
    local depth = H.Depth()
    local done, err = Bp.Set(id, key, nil)
    Ok(done == false and err ~= nil, 'a change that raises is refused with its message (' .. tostring(err) .. ')')
    Ok(Bp.Edits[id] == nil and H.Depth() == depth, 'and leaves no half edit and no undo entry')

    -- edit, undo, redo
    Bp.Set(id, key, 123)
    Ok(Bp.Get(id, key) == 123, 'an edit is stored')
    H.Undo()
    Ok(Bp.Edits[id] == nil, 'undo takes it back')
    H.Redo()
    Ok(Bp.Get(id, key) == 123, 'redo brings it back')

    -- a stale undo entry of another project does nothing
    Bp.Set(id, 'Defense.MaxHealth', 777)
    local okB = Bp.Create(nameB)
    if not okB then Bp.Open(nameB) end
    Bp.Edits = {}
    Ok(Bp.Project == nameB and Bp.Uid ~= uidA, 'the second project has its own uid')
    H.Undo()
    Ok(Count(Bp.Edits) == 0, 'undo of an entry from the first project does not put its edits into the second')
    H.Redo()
    Ok(Count(Bp.Edits) == 0, 'neither does redo')
    Bp.Open(nameA)
    Bp.Edits, Bp.Derived, Bp.NewUnits = {}, {}, {}

    -- add / remove / touch of a new unit are undoable
    local spec = Wiz.NewSpec('bot', 'UEF', 'zel0777')
    spec.name = 'First Name'
    local ok = Bp.AddNew(spec)
    Ok(ok and Bp.NewUnits.zel0777 ~= nil, 'AddNew')
    H.Undo()
    Ok(Bp.NewUnits.zel0777 == nil, 'undo of AddNew removes the unit')
    H.Redo()
    Ok(Bp.NewUnits.zel0777 ~= nil and Bp.NewUnits.zel0777.name == 'First Name', 'redo of AddNew brings it back with its fields')
    Bp.NewUnits.zel0777.name = 'Second Name'
    Bp.TouchNew('zel0777')
    Ok(Bp.NewUnits.zel0777.name == 'Second Name', 'TouchNew keeps the change')
    H.Undo()
    Ok(Bp.NewUnits.zel0777 and Bp.NewUnits.zel0777.name == 'First Name', 'undo of an in-place change of the spec (TouchNew)')
    H.Redo()
    Ok(Bp.NewUnits.zel0777.name == 'Second Name', 'redo of it')
    Bp.Set('zel0777', 'Defense.MaxHealth', 4321)
    Ok(Bp.RemoveNew('zel0777') and Bp.NewUnits.zel0777 == nil and Bp.Edits.zel0777 == nil, 'RemoveNew drops the unit and its edits')
    H.Undo()
    Ok(Bp.NewUnits.zel0777 ~= nil and Bp.Edits.zel0777 ~= nil and Bp.Edits.zel0777['Defense.MaxHealth'] == 4321, 'undo of RemoveNew restores the unit and its edits')

    -- Write: files, backup, version
    local before = ed_read_file(dirA .. '/mod_info.lua')
    local n, why = Bp.Write()
    Ok(n ~= nil and n > 0, 'Write writes the project (' .. tostring(n) .. ' files' .. (n and '' or ': ' .. tostring(why)) .. ')')
    local text = ed_read_file(dirA .. '/edits.lua')
    Ok(text and string.find(text, 'version = 1', 1, true) ~= nil and string.find(text, 'zel0777', 1, true) ~= nil, 'edits.lua carries its schema version and the unit')
    local after = ed_read_file(dirA .. '/mod_info.lua')
    Ok(before ~= after and string.find(after, 'uid = "' .. uidA .. '"', 1, true) ~= nil, 'a write that changed files raises the project version and keeps the uid')
    Bp.Edits.zel0777['Defense.MaxHealth'] = 4000
    Bp.Write()
    local bak = ed_read_file(dirA .. '/edits.lua.bak')
    Ok(bak and string.find(bak, '4321', 1, true) ~= nil, 'the previous edits.lua is kept as edits.lua.bak')

    -- a blueprint that would not load is not written, the old file stays
    local bpPath = dirA .. '/units/zel0777/zel0777_unit.bp'
    local goodBp = ed_read_file(bpPath)
    Ok(goodBp ~= nil, 'the unit blueprint was written')
    local oldTemplate = Bp.NewUnits.zel0777.template
    Bp.NewUnits.zel0777.template = 'nosuchtemplate'
    Bp.TouchNew('zel0777')
    n = Bp.Write()
    Ok(n ~= nil and table.getn(Bp.Blocked) == 1 and Bp.Blocked[1] == 'zel0777', 'a unit that cannot be generated is reported as blocked')
    Ok(ed_read_file(bpPath) == goodBp, 'and its old blueprint file is untouched')
    Ok(table.getn(Bp.Check()) > 0, 'the project check lists it')
    Bp.NewUnits.zel0777.template = oldTemplate
    Bp.TouchNew('zel0777')
    Bp.Write()
    Ok(table.getn(Bp.Blocked) == 0, 'once the spec is valid again the unit is written')

    -- a gate for a description that would break the script / strings text
    Bp.NewUnits.zel0777.description = 'a "quoted" \\ back\nslash line'
    Bp.NewUnits.zel0777.name = 'Name with "quotes" and \\'
    Bp.TouchNew('zel0777')
    local problems = import('/lua/editor/unitcheck.lua').PreWrite(Bp.NewUnits.zel0777, nil)
    Ok(table.getn(problems) == 0, 'quotes, backslashes and newlines in names are escaped: the generated files compile (' .. table.concat(problems, '; ') .. ')')

    -- a damaged edits.lua: opens (from the .bak), keeps the original, Write waits
    Bp.Write()
    ed_write_file(dirA .. '/edits.lua.bak', ed_read_file(dirA .. '/edits.lua'))
    local goodEdits = ed_read_file(dirA .. '/edits.lua')
    ed_write_file(dirA .. '/edits.lua', 'Edits = { broken (( \n')
    local opened, warning = Bp.Open(nameA)
    Ok(opened and warning ~= nil and Bp.Damaged == false and Bp.NewUnits.zel0777 ~= nil, 'a corrupt edits.lua opens from edits.lua.bak with a warning')
    Ok(ed_read_file(dirA .. '/edits.lua.bad') ~= nil, 'the corrupt original is kept as edits.lua.bad')
    ed_write_file(dirA .. '/edits.lua', 'Edits = { broken (( \n')
    ed_write_file(dirA .. '/edits.lua.bak', 'also (( broken')
    opened, warning = Bp.Open(nameA)
    Ok(opened and Bp.Damaged ~= false and Count(Bp.NewUnits) == 0, 'with the backup damaged as well the project opens empty and is marked damaged')
    local wn, wwhy = Bp.Write()
    Ok(wn == nil and wwhy ~= nil, 'Write refuses to replace a file it could not read')
    Ok(string.find(ed_read_file(dirA .. '/edits.lua') or '', 'broken', 1, true) ~= nil, 'and leaves it as it was')
    local mod = import('/lua/editor/modcheck.lua')
    local found = false
    for _, p in Bp.Check() do if string.find(p.text, 'could not be read', 1, true) then found = true end end
    Ok(found, 'the project check says so')
    wn = Bp.Write(true)
    Ok(wn ~= nil and Bp.Damaged == false, 'Write(true) goes on after the maker decided')

    -- put things back
    ed_write_file(dirA .. '/edits.lua', goodEdits)
    if savedProject and savedProject ~= nameA then Bp.Open(savedProject) end
    table.insert(out, 1, failed == 0 and 'ALL OK' or (failed .. ' FAIL'))
    return table.concat(out, '\n')
end
