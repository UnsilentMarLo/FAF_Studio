-- Validators of the units the new unit wizard made (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S4). They look at the files in the project folder (the generated ones may have been edited by hand, the mesh and
-- the textures come from the user), not at the spec, and report what would fail or look wrong in the game:
--
--   files            blueprint, script, strings, LOD meshes, textures, icon are there; generated text files are current (fix: write)
--   id               lower case letters and digits, at least 6 characters, unique among the project's units and the game's (a unit of the running game with that id that is not ours is an error)
--   blueprint        compiles; economy and health are positive; weapons have a projectile that exists, damage, range and rate of fire
--   bones            every bone the blueprint names (weapon turrets, racks, muzzles, build effects ...) and the script creates manipulators on is a bone of the SCM file (case differences are warnings)
--   weapon labels    each blueprint weapon label equals a weapon name in the script's Weapons table and the other way round (fix: write regenerates the script)
--   categories       faction, tech and layer category, MOBILE / STRUCTURE, a builder category; footprint and skirt of structures
--   build menu       some factory / engineer / commander of the game has a BuildableCategory that matches the unit (category expressions are evaluated); fix: add the default builders
--   collision box    SizeX / SizeY / SizeZ against the mesh bounds times Display.UniformScale (vanilla ratios run 0.35 .. 3.7, outside is reported) and the engine's minimum (10 % of the top speed, 0.5 high); fix: write the unit
--   LODs             at least one, cutoffs ascending, first not below 70, a mesh file per LOD
--   limits           SCM version 5, at most 65,535 vertices (error), heavy above 20,000 vertices / 3 MB; textures DXT, power of two, at most 2048
--   animations       the .sca files the blueprint names are in the game; reused animations need the template's skeleton
--   icon             textures/ui/common/icons/units/<id>_icon.dds (fix: software preview icon)
--
--   Check(id, spec, edits) -> list of { sev = 'E' | 'W' | 'I', text, id, fix = function() | nil, fixLabel }
--   EvalCategory(expression, set) -> bool;  Builders(set) -> list of builder ids;  Rules -> the rule names (documentation and selftest)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local Wiz = import('/lua/editor/unitwiz.lua')
local Scm = import('/lua/editor/scm.lua')

Rules = { 'files', 'id', 'blueprint', 'bones', 'weapon labels', 'categories', 'build menu', 'extents', 'LODs', 'limits', 'animations', 'icon' }

-- ---- category expressions --------------------------------------------------------------------------------------------------------------------------

local function Tokens(expr)
    local list = {}
    local i, n = 1, string.len(expr)
    while i <= n do
        local c = string.sub(expr, i, i)
        if string.find(c, '[%s,]') then
            i = i + 1
        elseif c == '(' or c == ')' or c == '+' or c == '-' or c == '*' then
            table.insert(list, c)
            i = i + 1
        else
            local s, e = string.find(expr, '^[%w_]+', i)
            if not s then
                i = i + 1
            else
                table.insert(list, string.upper(string.sub(expr, s, e)))
                i = e + 1
            end
        end
    end
    return list
end

--- Evaluates a category expression against a set of category names (upper case keys). Words next to each other and `*` intersect, `+` unites, `-` subtracts, as in the game's expressions.
function EvalCategory(expr, set)
    local tokens = Tokens(expr)
    local pos = 1
    local Sum
    local function Atom()
        local t = tokens[pos]
        if t == '(' then
            pos = pos + 1
            local v = Sum()
            if tokens[pos] == ')' then pos = pos + 1 end
            return v
        elseif t and t ~= ')' and t ~= '+' and t ~= '-' and t ~= '*' then
            pos = pos + 1
            return t == 'ALLUNITS' or set[t] == true
        end
        return false
    end
    local function Product()
        local v = Atom()
        while tokens[pos] and tokens[pos] ~= ')' and tokens[pos] ~= '+' and tokens[pos] ~= '-' do
            if tokens[pos] == '*' then pos = pos + 1 end
            local w = Atom()
            v = v and w
        end
        return v
    end
    Sum = function()
        local v = Product()
        while tokens[pos] == '+' or tokens[pos] == '-' do
            local op = tokens[pos]
            pos = pos + 1
            local w = Product()
            if op == '+' then v = v or w else v = v and not w end
        end
        return v
    end
    return Sum() and true or false
end

local builders = false

--- Every unit of the game that builds something: list of { id, exprs }. Cached for the session.
local function BuilderList()
    if builders then return builders end
    builders = {}
    for id, bp in __blueprints or {} do
        if type(id) == 'string' and string.sub(id, 1, 1) ~= '/' and bp.BlueprintId == id and bp.Economy and bp.Economy.BuildableCategory then
            local bc = bp.Economy.BuildableCategory
            local exprs = {}
            if type(bc) == 'string' then exprs = { bc } else for _, e in bc do table.insert(exprs, e) end end
            -- a builder that builds everything (the cheat engineer zxa0001) is no proof that the unit is in anyone's build menu
            local real = {}
            for _, e in exprs do
                if string.upper(e) ~= 'ALLUNITS' then table.insert(real, e) end
            end
            if table.getn(real) > 0 then table.insert(builders, { id = id, exprs = real }) end
        end
    end
    table.sort(builders, function(a, b) return a.id < b.id end)
    return builders
end

function ResetCache() builders = false end

--- Ids of the game's builders whose BuildableCategory matches a unit with these categories (a set of upper case names).
function Builders(set)
    local out = {}
    for _, b in BuilderList() do
        for _, e in b.exprs do
            if EvalCategory(e, set) then
                table.insert(out, b.id)
                break
            end
        end
    end
    return out
end

-- ---- reading the project's files ----------------------------------------------------------------------------------------------------------------

--- Compiles Lua text. The engine's loadstring may raise instead of returning nil + message, so it runs in a pcall. -> function | nil, message
function Compile(text)
    local ok, fn, err = pcall(loadstring, text)
    if not ok then return nil, tostring(fn) end
    return fn, err
end

--- The table of a blueprint file's text: UnitBlueprint { ... } with Sound { ... } read as plain tables. -> table | nil, error
function LoadBlueprint(text)
    local fn, err = Compile(text)
    if not fn then return nil, tostring(err) end
    local result
    local env = { UnitBlueprint = function(t) result = t end, Sound = function(t) return t end }
    setfenv(fn, env)
    local ok, why = pcall(fn)
    if not ok then return nil, tostring(why) end
    if not result then return nil, 'the file does not contain a UnitBlueprint { ... }' end
    return result
end

local BONE_KEYS = { TurretBoneYaw = true, TurretBonePitch = true, TurretBoneMuzzle = true, TurretBoneDualPitch = true, TurretBoneDualMuzzle = true, RackBone = true, AimBone = true, Bone = true }
local BONE_LISTS = { MuzzleBones = true, BuildEffectBones = true, Bones = true }

--- Walks a blueprint and collects { path, name } of every bone it names.
local function BoneRefs(node, path, out)
    for k, v in node do
        local p = path .. (type(k) == 'number' and ('[' .. k .. ']') or ('.' .. tostring(k)))
        if type(v) == 'string' and BONE_KEYS[k] then
            table.insert(out, { path = p, name = v })
        elseif type(v) == 'table' then
            if BONE_LISTS[k] then
                for _, b in v do
                    if type(b) == 'string' then table.insert(out, { path = p, name = b }) end
                end
            else
                BoneRefs(v, p, out)
            end
        end
    end
    return out
end

local SCRIPT_BONE_CALLS = { 'CreateRotator', 'CreateSlider', 'CreateAimController', 'CreateBuilderArmController', 'CreateStorageManip', 'CreateThrustController', 'ShowBone', 'HideBone', 'GetPosition', 'CreateAttachedEmitter', 'CreateEmitterAtBone', 'AttachBoneTo', 'CreateAnimator' }

--- Bone names a script uses in manipulator and bone calls: list of names (strings of two characters or more without a path or space).
local function ScriptBones(text)
    local names = {}
    for line in string.gfind(text, '[^\n]+') do
        if not string.find(line, '^%s*%-%-') then
            for _, fn in SCRIPT_BONE_CALLS do
                local s, e = string.find(line, fn .. '%s*%(')
                if s then
                    local rest = string.sub(line, e + 1)
                    local count = 0
                    for q in string.gfind(rest, "['\"]([%w_]+)['\"]") do
                        count = count + 1
                        if string.len(q) >= 2 and count <= 2 and q ~= 'x' and q ~= 'y' and q ~= 'z' then table.insert(names, q) end
                    end
                end
            end
        end
    end
    return names
end

--- Weapon names of the script's Weapons table: list of names.
local function ScriptWeapons(text)
    local names = {}
    for line in string.gfind(text, '[^\n]+') do
        local s, e, name = string.find(line, '^%s*([%w_]+)%s*=%s*ClassWeapon')
        if s then table.insert(names, name) end
    end
    return names
end

local function Exists(path) return ed_file_stamp(path) ~= nil end

local scmCache = {}

--- What the checks need to know about an SCM file: { header, headerWhy, bones, bonesWhy, bounds, size }. Read once per file stamp (a mesh can be several megabytes and the checks run on every edit).
local function ScmInfo(path)
    local stamp = ed_file_stamp(path)
    if not stamp then return nil end
    local c = scmCache[path]
    if c and c.stamp == stamp then return c end
    local data = ed_read_file(path)
    if not data then return nil end
    c = { stamp = stamp, size = string.len(data) }
    c.header, c.headerWhy = Scm.Header(data)
    c.bones, c.bonesWhy = Scm.Bones(data)
    local x0, y0, z0, x1, y1, z1 = Scm.FileBounds(data)
    if x0 then c.bounds = { x0, y0, z0, x1, y1, z1 } end
    scmCache[path] = c
    return c
end

-- ---- the gate before Write -------------------------------------------------------------------------------------------------------------------------

--- What bpedit.Write asks before it writes a new unit's generated text files: do they compile, does the blueprint have the parts the game reads while it loads blueprints? Looks at what the
--- wizard WOULD write (no files). -> list of problem texts (empty = write). A unit that fails here would have stopped the game's blueprint loading or the unit script's import, so its files are
--- not written (the old ones stay).
function PreWrite(spec, edits)
    local list = {}
    local function Add(text) table.insert(list, text) end
    if type(spec) ~= 'table' or not Wiz.ValidId(spec.id) then
        Add('the unit id is not valid (lower case letters and digits, a letter first, at least 6 characters)')
        return list
    end
    local ok, text = pcall(Wiz.BlueprintText, spec, edits)
    if not ok then
        Add('the blueprint could not be generated: ' .. tostring(text))
    else
        local bp, why = LoadBlueprint(text)
        if not bp then
            Add('the blueprint does not compile: ' .. tostring(why))
        else
            if type(bp.Categories) ~= 'table' or table.getn(bp.Categories) == 0 then Add('the blueprint has no Categories') end
            if type(bp.Economy) ~= 'table' then Add('the blueprint has no Economy table') end
        end
    end
    ok, text = pcall(Wiz.ScriptText, spec)
    if not ok then
        Add('the script could not be generated: ' .. tostring(text))
    else
        local fn, err = Compile(text)
        if not fn then Add('the script does not compile: ' .. tostring(err)) end
    end
    ok, text = pcall(Wiz.StringsText, spec)
    if not ok then
        Add('the strings could not be generated: ' .. tostring(text))
    else
        local fn, err = Compile(text)
        if not fn then Add('the strings file does not compile: ' .. tostring(err)) end
    end
    return list
end

-- ---- the checks --------------------------------------------------------------------------------------------------------------------------------------

--- Problems of one new unit. `spec` as made by unitwiz.NewSpec, `edits` the unit lab's edits of it. Reads the project's files.
function Check(id, spec, edits)
    local Bp = import('/lua/editor/bpedit.lua')
    local list = {}
    local dir = Bp.ROOT .. '/' .. tostring(Bp.Project)
    local function Add(sev, text, fix, label)
        table.insert(list, { sev = sev, text = id .. ': ' .. text, id = id, fix = fix, fixLabel = label })
    end
    local function Write()
        local n, report = Wiz.Write(dir, spec, edits)
        Bp.TouchNew(id)
        pcall(function() import('/lua/editor/modcheck.lua').Touch() end)
        return n
    end

    -- id
    if not Wiz.ValidId(id) then Add('E', 'the id must be lower case letters and digits, a letter first, at least 6 characters') end
    if id ~= string.lower(id) then Add('E', 'unit ids are lower case (the blueprint would not merge)') end
    local live = __blueprints and __blueprints[id]
    if live and live.Source and Bp.Project and not string.find(string.lower(live.Source), string.lower('/mods/' .. Bp.Project .. '/'), 1, true) then
        Add('E', 'the game already has a unit with this id (' .. tostring(live.Source) .. ')')
    end
    for other, _ in Bp.NewUnits do
        if other ~= id and string.lower(other) == string.lower(id) then Add('E', 'two units of the project have the same id') end
    end
    if Bp.Derived[id] then Add('E', 'the id is also a derived unit of the project') end

    -- files
    local folder = 'units/' .. id .. '/'
    local files = {
        bp = folder .. id .. '_unit.bp', script = folder .. id .. '_script.lua', strings = folder .. id .. '_strings.lua', lod0 = folder .. id .. '_lod0.scm',
        albedo = folder .. id .. '_albedo.dds', normal = folder .. id .. '_normalsts.dds', spec = folder .. id .. '_specteam.dds',
        icon = 'textures/ui/common/icons/units/' .. id .. '_icon.dds',
    }
    local missing = false
    for key, rel in files do
        if not Exists(dir .. '/' .. rel) then
            local sev = (key == 'strings' or key == 'icon') and 'W' or 'E'
            if key == 'icon' then
                Add('W', 'no icon (' .. rel .. '): the build menu shows a blank one', function()
                    local ok, why = Wiz.WriteQuickIcon(dir, spec)
                    return ok, why
                end, 'make a preview icon')
            else
                Add(sev, 'file ' .. rel .. ' is missing', Write, 'write the unit')
                missing = true
            end
        end
    end
    local bpText = Exists(dir .. '/' .. files.bp) and ed_read_file(dir .. '/' .. files.bp)
    local scriptText = Exists(dir .. '/' .. files.script) and ed_read_file(dir .. '/' .. files.script)
    if bpText and string.find(bpText, Wiz.MARK, 1, true) and bpText ~= Wiz.BlueprintText(spec, edits) then
        Add('I', 'the blueprint on disk differs from the wizard\'s (Write)', Write, 'write the unit')
    end
    if scriptText and string.find(scriptText, Wiz.MARK, 1, true) and scriptText ~= Wiz.ScriptText(spec) then
        Add('I', 'the script on disk differs from the wizard\'s (Write)', Write, 'write the unit')
    end
    if bpText and not string.find(bpText, Wiz.MARK, 1, true) then Add('I', 'the blueprint was edited by hand: the wizard does not rewrite it') end

    -- blueprint (the file on disk, else what the wizard would write)
    local bp, why
    if bpText then bp, why = LoadBlueprint(bpText) else bp = Wiz.Blueprint(spec, edits) end
    if not bp then
        Add('E', 'the blueprint does not compile: ' .. tostring(why))
        return list
    end
    local econ = bp.Economy or {}
    if (econ.BuildCostMass or 0) <= 0 and (econ.BuildCostEnergy or 0) <= 0 then Add('W', 'the unit costs nothing (mass and energy 0)') end
    if (econ.BuildTime or 0) <= 0 then Add('E', 'Economy.BuildTime is 0: the unit can never be built') end
    if not bp.Defense or (bp.Defense.MaxHealth or 0) <= 0 then Add('E', 'Defense.MaxHealth must be above 0') end
    if bp.Defense and bp.Defense.Health ~= bp.Defense.MaxHealth then Add('W', 'Defense.Health differs from MaxHealth: the unit starts damaged') end

    -- weapons
    local labels = {}
    for i, w in bp.Weapon or {} do
        if w.Label and not w.DummyWeapon then
            if labels[w.Label] then Add('E', 'two weapons have the label ' .. w.Label) end
            labels[w.Label] = true
            if (w.Damage or 0) <= 0 and not w.NukeWeapon then Add('W', 'weapon ' .. w.Label .. ' does no damage') end
            if (w.MaxRadius or 0) <= 0 then Add('W', 'weapon ' .. w.Label .. ' has no range (MaxRadius)') end
            if (w.RateOfFire or 0) <= 0 then Add('E', 'weapon ' .. w.Label .. ' never fires (RateOfFire 0)') end
            if w.ProjectileId and not w.NoProjectile and ed_vfs_to_disk and not ed_vfs_to_disk(w.ProjectileId) then
                Add('E', 'weapon ' .. w.Label .. ': the projectile ' .. w.ProjectileId .. ' is not in the game')
            end
        elseif not w.Label then
            Add('E', 'weapon ' .. i .. ' has no Label')
        end
    end

    -- script: compiles, the class, weapon names
    if scriptText then
        local fn, err = Compile(scriptText)
        if not fn then Add('E', 'the script does not compile: ' .. tostring(err)) end
        if not string.find(scriptText, 'TypeClass%s*=') then Add('E', 'the script does not set TypeClass') end
        local scriptWeapons = ScriptWeapons(scriptText)
        local seen = {}
        for _, name in scriptWeapons do seen[name] = true end
        for label, _ in labels do
            if not seen[label] then Add('E', 'blueprint weapon ' .. label .. ' has no entry in the script (the script weapon names must equal the blueprint labels)', Write, 'write the unit') end
        end
        for name, _ in seen do
            if not labels[name] then Add('W', 'the script has a weapon ' .. name .. ' that the blueprint does not', Write, 'write the unit') end
        end
    end

    -- bones: the SCM file's, else the wizard's
    local bones, boneSource = {}, 'the template'
    local scm = ScmInfo(dir .. '/' .. files.lod0)
    local scmBounds = scm and scm.bounds
    if scm then
        if scm.bones then
            for _, b in scm.bones do bones[string.lower(b.name)] = b.name end
            boneSource = 'the mesh ' .. id .. '_lod0.scm'
        else
            Add('E', 'the mesh cannot be read: ' .. tostring(scm.bonesWhy))
        end
    else
        for _, name in Wiz.BoneNames(spec) do bones[string.lower(name)] = name end
    end
    if next(bones) then
        for _, ref in BoneRefs(bp, 'Blueprint', {}) do
            local have = bones[string.lower(ref.name)]
            if not have then
                Add('E', ref.path .. ' names the bone ' .. ref.name .. ', which is not in ' .. boneSource)
            elseif have ~= ref.name then
                Add('W', ref.path .. ' names the bone ' .. ref.name .. ', the mesh calls it ' .. have .. ' (case)')
            end
        end
        if scriptText then
            local reported = {}
            for _, name in ScriptBones(scriptText) do
                local have = bones[string.lower(name)]
                if not have and not reported[name] then
                    reported[name] = true
                    Add('W', 'the script uses the bone ' .. name .. ', which is not in ' .. boneSource)
                end
            end
        end
    end

    -- categories
    local set = {}
    local cats = bp.Categories or {}
    for _, c in cats do set[string.upper(c)] = true end
    local isMobile = set.MOBILE
    local isStructure = set.STRUCTURE
    if not (set.UEF or set.AEON or set.CYBRAN or set.SERAPHIM) then Add('W', 'no faction category (UEF, AEON, CYBRAN or SERAPHIM)') end
    if not (set.TECH1 or set.TECH2 or set.TECH3 or set.EXPERIMENTAL) then Add('E', 'no tech category (TECH1, TECH2, TECH3 or EXPERIMENTAL): the build menu cannot sort the unit') end
    if not (set.LAND or set.NAVAL or set.AIR or set.STRUCTURE) then Add('W', 'no layer category (LAND, NAVAL, AIR or STRUCTURE)') end
    if not isMobile and not isStructure then Add('W', 'neither MOBILE nor STRUCTURE') end
    if isMobile and isStructure then Add('E', 'MOBILE and STRUCTURE together') end
    if not set.SELECTABLE then Add('W', 'no SELECTABLE category: the player cannot select the unit') end
    local ph = bp.Physics or {}
    if isStructure then
        if (ph.SkirtSizeX or 0) < 1 or (ph.SkirtSizeZ or 0) < 1 then
            Add('E', 'a structure needs Physics.SkirtSizeX / SkirtSizeZ (its footprint on the build grid)')
        else
            local ox, oz = ph.SkirtOffsetX or 0, ph.SkirtOffsetZ or 0
            if math.abs(ox + (ph.SkirtSizeX - 1) / 2) > 2 or math.abs(oz + (ph.SkirtSizeZ - 1) / 2) > 2 then
                Add('W', 'Physics.SkirtOffset is far from the centre of the skirt: the footprint is not under the model')
            end
        end
        if ph.MotionType and ph.MotionType ~= 'RULEUMT_None' then Add('W', 'a structure with MotionType ' .. ph.MotionType) end
    elseif isMobile then
        if not ph.MotionType or ph.MotionType == 'RULEUMT_None' then Add('E', 'a mobile unit needs a Physics.MotionType') end
        if (ph.MaxSpeed or 0) <= 0 then Add('E', 'a mobile unit needs Physics.MaxSpeed above 0') end
    end
    if (bp.SizeX or 0) <= 0 or (bp.SizeZ or 0) <= 0 then Add('W', 'SizeX / SizeZ are 0: selection and the cursor circle have no size') end

    -- build menu
    local builderIds = Builders(set)
    if table.getn(builderIds) == 0 then
        local default = Wiz.DefaultBuildBy(Wiz.Template(spec.template), spec.tech or 1)
        Add('E', 'nothing can build the unit: no factory, engineer or commander has a BuildableCategory that matches its categories', function()
            spec.buildBy = default
            Bp.TouchNew(id)
            return Write()
        end, 'add the default builders')
    end

    -- the collision box (SizeX / SizeY / SizeZ) against the mesh: shipped units run 0.35 to 3.7 times the mesh bounds times Display.UniformScale (the big structure bases are flat: 0.1 in height)
    if scmBounds and bp.Display and bp.Display.UniformScale then
        local us = bp.Display.UniformScale
        local dims = { (scmBounds[4] - scmBounds[1]) * us, (scmBounds[5] - scmBounds[2]) * us, (scmBounds[6] - scmBounds[3]) * us }
        local box = { bp.SizeX, bp.SizeY, bp.SizeZ }
        local names = { 'SizeX', 'SizeY', 'SizeZ' }
        for i = 1, 3 do
            if box[i] and dims[i] > 0.001 and not (i == 2 and isStructure) then
                local ratio = box[i] / dims[i]
                if ratio < 0.35 or ratio > 4 then
                    Add('W', string.format('%s %.2f against the mesh %.2f (ratio %.2f; shipped units run 0.35 to 3.7): hits and selection will not match the model', names[i], box[i], dims[i], ratio), Write, 'write the unit (the box is made from the mesh)')
                end
            end
        end
        local size = math.max(dims[1], dims[3])
        if size < 0.05 then Add('W', string.format('the mesh is %.3f world units across: it will be a speck (check Display.UniformScale and the OBJ scale)', size)) end
        if size > 60 then Add('W', string.format('the mesh is %.1f world units across: larger than any shipped unit', size)) end
    end
    -- the engine raises the collision box below 10 % of the top speed and below 0.5 in height (and says so in the log): the written one should already be that large
    if isMobile then
        local speed = (bp.Air and bp.Air.MaxAirspeed) or ph.MaxSpeed or 0
        if speed > 0 then
            for _, n in { 'SizeX', 'SizeZ' } do
                if bp[n] and bp[n] < speed * 0.1 - 0.0001 then
                    Add('W', string.format('%s %.2f is below 10%% of the top speed (%.2f): the engine overrides it (beam weapons need that much to hit a moving unit)', n, bp[n], speed * 0.1), Write, 'write the unit (the box is made large enough)')
                end
            end
        end
        if bp.SizeY and bp.SizeY < 0.5 then Add('W', 'SizeY ' .. bp.SizeY .. ' is below 0.5: the engine overrides it (gunships need that much to hit)', Write, 'write the unit (the box is made large enough)') end
    end

    -- LODs
    local lods =bp.Display and bp.Display.Mesh and bp.Display.Mesh.LODs
    if not lods or table.getn(lods) == 0 then
        Add('E', 'Display.Mesh.LODs is missing: the unit has no mesh to draw')
    else
        local last = 0
        for i, lod in lods do
            local cut = lod.LODCutoff or 0
            if cut <= last then Add('E', 'LOD ' .. i .. ': LODCutoff ' .. cut .. ' is not above the previous one (' .. last .. ')') end
            if i == 1 and cut < 70 then Add('W', 'LOD 1 ends at ' .. cut .. ': below 70 the strategic icon already covers the mesh (no shipped unit is below 70)') end
            last = cut
            if not Exists(dir .. '/' .. folder .. id .. '_lod' .. (i - 1) .. '.scm') and not (lod.MeshName and lod.MeshName ~= '') then
                Add('E', 'LOD ' .. i .. ' has no mesh file ' .. id .. '_lod' .. (i - 1) .. '.scm', Write, 'write the unit')
            end
        end
    end

    -- limits
    if scm then
        local h, hwhy = scm.header, scm.headerWhy
        if not h then
            Add('E', 'mesh: ' .. tostring(hwhy))
        else
            if h.vertexCount > 20000 then Add('W', 'the mesh has ' .. h.vertexCount .. ' vertices: heavy for a unit (shipped units run up to about 15,000)') end
            if h.size > 3 * 1024 * 1024 then Add('W', string.format('the mesh file is %.1f MB', h.size / 1048576)) end
            if h.indexCount > 90000 then Add('W', 'the mesh has ' .. (h.indexCount / 3) .. ' triangles') end
        end
    end
    for _, key in { 'albedo', 'normal', 'spec' } do
        local data = Exists(dir .. '/' .. files[key]) and ed_read_file(dir .. '/' .. files[key])
        if data then
            if string.sub(data, 1, 4) ~= 'DDS ' then
                Add('E', files[key] .. ' is not a DDS file')
            else
                local function U32(p) local a, b, c, d = string.byte(data, p), string.byte(data, p + 1), string.byte(data, p + 2), string.byte(data, p + 3) return a + b * 256 + c * 65536 + d * 16777216 end
                local h, w = U32(13), U32(17)
                local fourcc = string.sub(data, 85, 88)
                if fourcc ~= 'DXT1' and fourcc ~= 'DXT3' and fourcc ~= 'DXT5' and U32(89) ~= 32 then Add('W', files[key] .. ' is neither DXT1/3/5 nor 32 bit') end
                local function Pow2(n) while n > 1 do if math.mod(n, 2) ~= 0 then return false end n = n / 2 end return true end
                if not Pow2(w) or not Pow2(h) then Add('W', files[key] .. ' is ' .. w .. ' x ' .. h .. ': not a power of two (no mip maps, blurry or slow)') end
                if w > 2048 or h > 2048 then Add('W', files[key] .. ' is ' .. w .. ' x ' .. h .. ': larger than 2048') end
                if key == 'normal' and fourcc ~= 'DXT5' then Add('W', files[key] .. ' is ' .. fourcc .. ': the shipped normal maps are DXT5') end
            end
        end
    end

    -- animations
    if bp.Display and ed_vfs_to_disk then
        local anims = {}
        for k, v in bp.Display do
            if type(v) == 'string' and string.find(k, '^Animation') and string.find(string.lower(v), '%.sca$') then table.insert(anims, v) end
        end
        for _, set2 in { bp.Display.AnimationDeath or {}, bp.Display.TransportAnimation or {} } do
            for _, a in set2 do
                if type(a) == 'table' and type(a.Animation) == 'string' then table.insert(anims, a.Animation) end
            end
        end
        for _, a in anims do
            if not ed_vfs_to_disk(a) then Add('E', 'the animation ' .. a .. ' is not in the game') end
        end
        if table.getn(anims) > 0 and spec.mesh.skeleton == 'groups' then
            Add('W', 'the unit reuses animations of the template but its skeleton is made from the OBJ groups: the animation tracks name bones the mesh does not have')
        end
    end

    return list
end
