-- The Unit wizard panel (unitwiz.lua, unitcheck.lua, unittest.lua; docs/projects/MOD_UNIT_EDITOR_DESIGN.md stage S4): makes a new unit with its own id in the open mod project from a template, edits it in
-- tabs and generates its files.
--
--   Unit      template, faction, tech, name, description, extra / removed categories, sound set, animations
--   Stats     economy, health, speed, vision, footprint
--   Weapons   the unit's weapons: label, kind (from the weapon templates), damage, range, rate of fire, projectile
--   Visuals   the OBJ (groups become bones), size, orientation, skeleton, LODs; the three textures; the preview icon
--   Build     which factories / engineers / commanders build it, and who does in the running game
--   Files     the generated files, the problems found by unitcheck.lua with their fixes
--   Test      Test in game: the project is written and enabled, the session reloads, the unit stands on the map with dummy targets; quick commands
--
-- The panel keeps no state of its own besides the open tab: every value is read from and written to the spec in bpedit.NewUnits (saved with the project's edits.lua).
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Bp = import('/lua/editor/bpedit.lua')
local Wiz = import('/lua/editor/unitwiz.lua')
local Check = import('/lua/editor/unitcheck.lua')
local Test = import('/lua/editor/unittest.lua')

live = {}

local TABS = { 'Unit', 'Stats', 'Weapons', 'Visuals', 'Build', 'Files', 'Test' }
local PREVIEW_DIR = '../icontmp'
local previewSerial = 0
local mounted = false
local resumeTicks = 0

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Pick(title, options, current, done)
    local names, byName = {}, {}
    for _, o in options do
        table.insert(names, o.label)
        byName[o.label] = o
    end
    local curLabel
    for _, o in options do if o.id == current then curLabel = o.label end end
    import('/lua/editor/gui/dialogs_mission.lua').PickName(title, names, curLabel, function(name) done(byName[name]) end)
end

local function Labeled(list, id)
    for _, o in list do if o.id == id then return o.label end end
    return tostring(id)
end

local function FactionOptions()
    local out = {}
    for _, f in Wiz.Factions do table.insert(out, { id = f, label = f }) end
    return out
end

local function TemplateOptions()
    local out = {}
    for _, t in Wiz.Templates do table.insert(out, { id = t.id, label = t.label }) end
    return out
end

local function TechOptions()
    local out = {}
    for i, n in Wiz.TechNames do table.insert(out, { id = i, label = n }) end
    return out
end

local function KindOptions(spec)
    local out = {}
    local t = Wiz.Template(spec.template)
    for _, k in t and t.kinds or {} do table.insert(out, { id = k, label = Wiz.WeaponKinds[k] or k }) end
    return out
end

local function Dir() return Bp.ROOT .. '/' .. tostring(Bp.Project) end

local MOTION = {
    { id = 'RULEUMT_Land', label = 'Land (walks / drives)' }, { id = 'RULEUMT_Amphibious', label = 'Amphibious (land and sea bed)' },
    { id = 'RULEUMT_AmphibiousFloating', label = 'Amphibious, floating' }, { id = 'RULEUMT_Hover', label = 'Hover (land and water)' },
    { id = 'RULEUMT_Water', label = 'Water (ship)' }, { id = 'RULEUMT_Air', label = 'Air' }, { id = 'RULEUMT_None', label = 'None (structure)' },
}

--- A preview of a DDS file in the panel: the picture is written to the preview folder under a fresh name (textures are cached by name).
local function Preview(px, w, h)
    previewSerial = previewSerial + 1
    local name = 'w' .. previewSerial .. '.dds'
    if not ed_dds_write(PREVIEW_DIR .. '/' .. name, w, h, px, 1) then return nil end
    if not mounted then
        ed_vfs_mount(PREVIEW_DIR, '/icontmp')
        mounted = true
    end
    return '/icontmp/' .. name
end

Panels.Register{
    id = 'unitwiz', title = 'Unit wizard', stack = { workspace = 'Mod', with = 'unitlab' },
    create = function(group, host)
        local P = { tab = 'Unit', unit = false, controls = {}, sliders = {}, y = 0, w = 320, weapon = 1, note = '', report = '', thumb = false, building = false, targetKind = false }
        live.unitwiz = P
        local pad = Skin.S(8)

        local function Spec() return P.unit and Bp.NewUnits[P.unit] end

        -- ---- controls ----
        local function Keep(c) table.insert(P.controls, c) return c end

        local function Clear()
            for _, c in P.controls do pcall(function() c:Destroy() end) end
            P.controls = {}
            for _, s in P.sliders do
                for _, k in { 'label', 'track', 'fill', 'thumb', 'minus', 'plus' } do pcall(function() s[k]:Destroy() end) end
                pcall(function() s.field.frame:Destroy() end)
                pcall(function() s.field:Destroy() end)
            end
            P.sliders = {}
            P.thumb = false
        end

        local function Wd() return math.max(Skin.S(120), P.w - 2 * pad) end

        local function Touch()
            if P.building then return end
            if P.unit then Bp.TouchNew(P.unit) end
        end

        local function Label(text, color, small)
            Keep(W.Label(group, text, pad, P.y, { color = color or Skin.color.textDim, size = small and 'small' or nil }))
            P.y = P.y + Skin.S(small and 16 or 20)
        end

        local function Note(text)
            local labels, bottom = W.Paragraph(group, text, pad, P.y, Wd(), { color = Skin.color.textDim, size = 'small' }, Skin.S(16))
            for _, l in labels do Keep(l) end
            P.y = bottom + Skin.S(4)
        end

        local function Button(text, x, w, fn, opts)
            return Keep(W.Button(group, text, x, P.y, w, Skin.S(22), fn, opts))
        end

        local function Buttons(list)
            local x = pad
            local avail = Wd()
            for _, b in list do
                local bw = math.min(Skin.S(b[2]), avail)
                if x > pad and x + bw > pad + avail then      -- a row of buttons wraps in a narrow panel (Maui does not clip)
                    x = pad
                    P.y = P.y + Skin.S(26)
                end
                local btn = Keep(W.Button(group, b[1], x, P.y, bw, Skin.S(22), b[3], b[4]))
                if b[5] then b[5](btn) end
                x = x + bw + Skin.S(4)
            end
            P.y = P.y + Skin.S(28)
        end

        local function Text(label, get, set, browse)
            Label(label, nil, true)
            local fw = browse and (Wd() - Skin.S(64)) or Wd()
            local f = W.TextField(group, pad, P.y, fw, Skin.S(22), {
                text = get() or '',
                onChange = function(text) if not P.building then set(text) end end,
            })
            Keep(f)
            Keep(f.frame)
            if browse then
                Keep(W.Button(group, 'Browse', pad + fw + Skin.S(4), P.y, Skin.S(60), Skin.S(22), function()
                    local path = browse()
                    if path then f:SetText(path) set(path) end
                end))
            end
            P.y = P.y + Skin.S(28)
            return f
        end

        local function Number(label, min, max, step, fmt, get, set)
            local s = W.Slider(group, { label = label, min = min, max = max, step = step, fmt = fmt, get = get, set = function(v) set(v) Touch() end })
            table.insert(P.sliders, s)
            s:Place(pad, P.y, Wd())
            P.y = P.y + Skin.S(48)
            return s
        end

        local function Choice(label, current, options, set)
            local lw = math.floor(Wd() * 0.38)
            Keep(W.Label(group, label, pad, P.y + Skin.S(3), { color = Skin.color.textDim, size = 'small' }))
            local btn
            btn = Keep(W.Button(group, '', pad + lw, P.y, Wd() - lw, Skin.S(22), function()
                Pick(label, options, current, function(o)
                    if o then
                        set(o.id)
                        P:Rebuild()
                    end
                end)
            end))
            btn.label:SetText(Labeled(options, current))
            W.Fit(btn.label, Labeled(options, current), Wd() - lw - Skin.S(8))
            W.Center(btn.label, btn, 0, 0, Wd() - lw, Skin.S(22))
            P.y = P.y + Skin.S(26)
        end

        local function Toggle(label, get, set)
            local b = Keep(W.Button(group, label, pad, P.y, Wd(), Skin.S(22), function(self)
                set(self.on)
                Touch()
            end, { toggle = true }))
            b:SetOn(get() and true or false)
            P.y = P.y + Skin.S(26)
        end

        -- ---- tabs ----
        local function TabUnit(spec)
            local t = Wiz.Template(spec.template)
            Choice('Template', spec.template, TemplateOptions(), function(id)
                spec.template = id
                local fresh = Wiz.NewSpec(id, spec.faction, spec.id)
                for k, v in fresh do
                    if k ~= 'id' and k ~= 'name' and k ~= 'description' and k ~= 'mesh' and k ~= 'textures' and k ~= 'tech' then spec[k] = v end
                end
                spec.mesh.length = fresh.mesh.length
                spec.mesh.bounds = nil
                spec.buildBy = Wiz.DefaultBuildBy(Wiz.Template(id), spec.tech)
                Touch()
            end)
            Choice('Faction', spec.faction, FactionOptions(), function(id)
                spec.faction = id
                local donor, donorId = Wiz.Donor(spec)
                spec.sounds = donorId
                spec.buildable = Wiz.Template(spec.template).builder and donor.buildableCategory or nil
                spec.mesh.bounds = nil
                Touch()
            end)
            Choice('Tech', spec.tech, TechOptions(), function(id)
                spec.tech = id
                spec.buildBy = Wiz.DefaultBuildBy(Wiz.Template(spec.template), id)
                Touch()
            end)
            Text('Name', function() return spec.name end, function(v) spec.name = v Touch() end)
            Text('Description', function() return spec.description end, function(v) spec.description = v Touch() end)
            Text('Add categories (comma separated)', function() return table.concat(spec.catAdd or {}, ', ') end, function(v)
                spec.catAdd = {}
                for c in string.gfind(v, '[^,%s]+') do table.insert(spec.catAdd, string.upper(c)) end
                Touch()
            end)
            Text('Remove categories (comma separated)', function() return table.concat(spec.catDel or {}, ', ') end, function(v)
                spec.catDel = {}
                for c in string.gfind(v, '[^,%s]+') do table.insert(spec.catDel, string.upper(c)) end
                Touch()
            end)
            local sets = { { id = '', label = 'none' } }
            for _, s in Wiz.SoundSets() do table.insert(sets, { id = s.id, label = s.label }) end
            Choice('Sounds', spec.sounds or '', sets, function(id) spec.sounds = id ~= '' and id or nil Touch() end)
            Choice('Animations', spec.anim or 'template', { { id = 'template', label = 'the template\'s' }, { id = 'none', label = 'none' } }, function(id) spec.anim = id Touch() end)
            do
                local donor = Wiz.Donor(spec)
                local files = {}
                if donor.animationWalk then table.insert(files, 'walk ' .. donor.animationWalk) end
                for _, a in donor.death or {} do table.insert(files, 'death ' .. a) end
                if spec.anim ~= 'none' and table.getn(files) > 0 then
                    Note('Animations used (the skeleton must keep the template\'s bone names): ' .. table.concat(files, '; '))
                elseif table.getn(files) == 0 then
                    Note('The template has no animation files.')
                end
            end
            Note('Categories now: ' .. table.concat(Wiz.Categories(spec), ' '))
        end

        local function TabStats(spec)
            local t = Wiz.Template(spec.template)
            local e, d, ph = spec.economy, spec.defense, spec.physics
            Label('Economy', nil, true)
            Number('Mass cost', 0, 20000, 1, '%d', function() return e.BuildCostMass or 0 end, function(v) e.BuildCostMass = v end)
            Number('Energy cost', 0, 200000, 5, '%d', function() return e.BuildCostEnergy or 0 end, function(v) e.BuildCostEnergy = v end)
            Number('Build time', 1, 100000, 5, '%d', function() return e.BuildTime or 1 end, function(v) e.BuildTime = v end)
            if t.builder then Number('Build rate', 0, 500, 1, '%.1f', function() return e.BuildRate or 10 end, function(v) e.BuildRate = v end) end
            if spec.template == 'economy' then
                Number('Energy produced / s', 0, 20000, 5, '%d', function() return e.ProductionPerSecondEnergy or 0 end, function(v) e.ProductionPerSecondEnergy = v end)
            end
            Label('Defence', nil, true)
            Number('Health', 1, 100000, 10, '%d', function() return d.MaxHealth or 100 end, function(v) d.MaxHealth = v end)
            Number('Regeneration / s', 0, 100, 0.5, '%.1f', function() return d.RegenRate or 0 end, function(v) d.RegenRate = v ~= 0 and v or nil end)
            if t.mobile then
                Label('Movement', nil, true)
                local donorPhysics = Wiz.Donor(spec).physics or {}
                Choice('Motion', ph.MotionType or donorPhysics.MotionType or 'RULEUMT_Land', MOTION, function(id) ph.MotionType = id end)
                if t.layer == 'air' then
                    Number('Cruise altitude', 1, 120, 1, '%d', function() return ph.Elevation or donorPhysics.Elevation or 15 end, function(v) ph.Elevation = v end)
                end
                Number('Top speed', 0, 30, 0.1, '%.1f', function() return ph.MaxSpeed or 0 end, function(v) ph.MaxSpeed = v end)
                Number('Acceleration', 0, 60, 0.1, '%.1f', function() return ph.MaxAcceleration or 0 end, function(v) ph.MaxAcceleration = v end)
                Number('Braking', 0, 60, 0.1, '%.1f', function() return ph.MaxBrake or 0 end, function(v) ph.MaxBrake = v end)
                Number('Turn rate', 0, 360, 1, '%d', function() return ph.TurnRate or 0 end, function(v) ph.TurnRate = v end)
            else
                Label('Footprint (build grid cells)', nil, true)
                spec.footprint = spec.footprint or { x = 1, z = 1 }
                Number('Footprint width', 1, 16, 1, '%d', function() return spec.footprint.x end, function(v) spec.footprint.x = v end)
                Number('Footprint depth', 1, 16, 1, '%d', function() return spec.footprint.z end, function(v) spec.footprint.z = v end)
            end
            Label('Intel', nil, true)
            spec.intel = spec.intel or {}
            Number('Vision radius', 0, 200, 1, '%d', function() return spec.intel.VisionRadius or 0 end, function(v) spec.intel.VisionRadius = v end)
        end

        local function TabWeapons(spec)
            local t = Wiz.Template(spec.template)
            if table.getn(t.kinds) == 0 then
                Note('The ' .. string.lower(t.label) .. ' template has no weapons.')
                return
            end
            local n = table.getn(spec.weapons)
            if P.weapon > n then P.weapon = n end
            if P.weapon < 1 then P.weapon = 1 end
            local opts = {}
            for i, w in spec.weapons do table.insert(opts, { id = i, label = i .. '. ' .. w.label .. ' (' .. (Wiz.WeaponKinds[w.kind] or w.kind) .. ')' }) end
            if n > 0 then Choice('Weapon', P.weapon, opts, function(i) P.weapon = i end) end
            Buttons({
                { 'Add weapon', 90, function()
                    Pick('Weapon template', KindOptions(spec), nil, function(o)
                        if not o then return end
                        local label = 'Weapon' .. (table.getn(spec.weapons) + 1)
                        if table.getn(spec.weapons) == 0 then label = 'MainGun' end
                        table.insert(spec.weapons, Wiz.NewWeapon(spec, o.id, label))
                        P.weapon = table.getn(spec.weapons)
                        Touch()
                        P:Rebuild()
                    end)
                end },
                { 'Remove', 64, function()
                    if spec.weapons[P.weapon] then
                        table.remove(spec.weapons, P.weapon)
                        Touch()
                        P:Rebuild()
                    end
                end },
            })
            local w = spec.weapons[P.weapon]
            if not w then
                Note('No weapon yet: Add weapon takes a weapon template (direct fire, cannon, artillery, anti air, missile, torpedo, bomb) of the unit\'s faction.')
                return
            end
            Text('Label (the script weapon name)', function() return w.label end, function(v) if v ~= '' then w.label = v Touch() end end)
            Choice('Kind', w.kind, KindOptions(spec), function(id)
                local fresh = Wiz.NewWeapon(spec, id, w.label)
                w.kind, w.damage, w.range, w.rof, w.damageRadius, w.minRange, w.projectile = id, fresh.damage, fresh.range, fresh.rof, fresh.damageRadius, fresh.minRange, fresh.projectile
                Touch()
            end)
            Number('Damage', 0, 100000, 1, '%d', function() return w.damage end, function(v) w.damage = v end)
            Number('Range', 1, 1000, 1, '%d', function() return w.range end, function(v) w.range = v end)
            Number('Minimum range', 0, 500, 1, '%d', function() return w.minRange or 0 end, function(v) w.minRange = v end)
            Number('Rate of fire (shots / s)', 0.05, 20, 0.05, '%.2f', function() return w.rof end, function(v) w.rof = v end)
            Number('Damage radius', 0, 50, 0.5, '%.1f', function() return w.damageRadius or 0 end, function(v) w.damageRadius = v end)
            Text('Projectile blueprint', function() return w.projectile or '' end, function(v) w.projectile = v Touch() end)
            local wb = Wiz.WeaponBones(spec)
            Note(wb and ('Aims with the bones ' .. tostring(wb.yaw) .. ' / ' .. tostring(wb.pitch) .. ', fires from ' .. tostring(wb.muzzle) .. ' (the skeleton of the template or the OBJ groups named turret / barrel / muzzle).') or 'The skeleton has no weapon bones: the weapon fires from the unit\'s centre.')
        end

        local function ObjBrowse()
            return ed_file_dialog(false, 'Choose an OBJ file', 'Wavefront OBJ (*.obj)|*.obj|All files|*.*', '')
        end
        local function TexBrowse()
            return ed_file_dialog(false, 'Choose a texture', 'Images (*.dds;*.png;*.bmp;*.jpg;*.tif)|*.dds;*.png;*.bmp;*.jpg;*.jpeg;*.tif;*.tiff|All files|*.*', '')
        end

        local function CheckMesh(spec)
            local text
            if spec.mesh.source ~= '' then
                text = ed_read_file(spec.mesh.source)
                if not text then P.report = 'cannot read ' .. spec.mesh.source P:Rebuild() return end
            end
            local mesh, info = Wiz.BuildMesh(spec, text)
            if not mesh then
                P.report = 'mesh: ' .. tostring(info)
            else
                spec.mesh.bounds = info.bounds
                spec.mesh.groups = (spec.mesh.skeleton == 'groups') and info.groups or nil
                Touch()
                local b = info.bounds
                local us = Wiz.Donor(spec).uniformScale or 0.1
                P.report = string.format('%d vertices, %d triangles, %d bones; %.2f x %.2f x %.2f world units%s', info.vertices, info.triangles, info.bones,
                    (b[4] - b[1]) * us, (b[5] - b[2]) * us, (b[6] - b[3]) * us, table.getn(info.warnings) > 0 and ('. ' .. table.concat(info.warnings, '. ')) or '')
            end
            P:Rebuild()
        end

        local function TabVisuals(spec)
            local m = spec.mesh
            Label('Mesh (OBJ: each group or object becomes a part; a group named like a bone is bound to it)', nil, true)
            Text('OBJ file', function() return m.source end, function(v) m.source = v Touch() end, ObjBrowse)
            Number('Length (world units, longest side)', 0.05, 80, 0.05, '%.2f', function() return m.length end, function(v) m.length = v m.bounds = nil end)
            Choice('Up axis', m.axis, { { id = 'y_up', label = 'Y up' }, { id = 'z_up', label = 'Z up (Blender)' } }, function(id) m.axis = id end)
            Choice('Front faces', m.yaw or 0, { { id = 0, label = '+Z (as exported)' }, { id = 1.5708, label = 'rotated 90 degrees' }, { id = 3.14159, label = 'rotated 180 degrees' }, { id = 4.71239, label = 'rotated 270 degrees' } }, function(id) m.yaw = id end)
            Choice('Skeleton', m.skeleton, { { id = 'template', label = 'the template\'s bones' }, { id = 'groups', label = 'root + one bone per OBJ group' } }, function(id) m.skeleton = id m.bounds = nil end)
            Choice('LODs', m.lods or 1, { { id = 1, label = '1' }, { id = 2, label = '2 (same mesh)' } }, function(id) m.lods = id end)
            Toggle('Mirror X', function() return m.mirrorX end, function(v) m.mirrorX = v end)
            Toggle('Flip winding (inside out)', function() return m.flipWinding end, function(v) m.flipWinding = v end)
            Toggle('Flip V (textures run down)', function() return m.flipV end, function(v) m.flipV = v end)
            Buttons({ { 'Check mesh', 90, function() CheckMesh(spec) end }, { 'Clear OBJ', 76, function() m.source = '' m.bounds = nil m.groups = nil Touch() P:Rebuild() end } })
            if P.report ~= '' then Note(P.report) end
            Label('Textures (DDS DXT1 / 3 / 5 / 32 bit, PNG, BMP, JPEG, TIFF; converted to DXT5 with mip maps)', nil, true)
            Text('Albedo', function() return spec.textures.albedo end, function(v) spec.textures.albedo = v end, TexBrowse)
            Text('Normal map', function() return spec.textures.normal end, function(v) spec.textures.normal = v end, TexBrowse)
            Text('Specular + team colour (alpha)', function() return spec.textures.spec end, function(v) spec.textures.spec = v end, TexBrowse)
            Label('Icon', nil, true)
            local holder = Keep(Bitmap(group))
            holder:SetSolidColor(Skin.color.panelAlt)
            W.Place(holder, group, pad, P.y, Skin.S(64), Skin.S(64))
            P.thumb = Keep(Bitmap(group))
            P.thumb.Depth:Set(function() return group.Depth() + 12 end)
            P.thumb:DisableHitTest()
            W.Place(P.thumb, group, pad, P.y, Skin.S(64), Skin.S(64))
            local function ShowIcon()
                local path = Dir() .. '/textures/ui/common/icons/units/' .. spec.id .. '_icon.dds'
                if ed_file_stamp(path) then
                    local px, w, h = ed_dds_read(path)
                    local vfs = px and Preview(px, w, h)
                    if vfs then P.thumb:SetTexture(vfs) P.thumb:Show() return end
                end
                P.thumb:Hide()
            end
            ShowIcon()
            Button('Preview icon', pad + Skin.S(72), Skin.S(96), function()
                local ok, why = Wiz.WriteQuickIcon(Dir(), spec, true)
                P.note = ok and 'preview icon written (the Icons panel replaces it with the engine render once the unit is in the game)' or ('icon: ' .. tostring(why))
                P:Rebuild()
            end)
            P.y = P.y + Skin.S(72)
        end

        local function TabBuild(spec)
            Label('Built by (a factory, engineer or commander with this category in its build list)', nil, true)
            local has = {}
            for _, k in spec.buildBy or {} do has[k] = true end
            for _, bk in Wiz.BuildKeys do
                local key = bk.key
                Toggle(bk.label .. '  (' .. bk.cat .. ')', function() return has[key] end, function(on)
                    local list = {}
                    for _, k in spec.buildBy or {} do if k ~= key then table.insert(list, k) end end
                    if on then table.insert(list, key) end
                    spec.buildBy = list
                    has[key] = on or nil
                end)
            end
            local set = {}
            for _, c in Wiz.Categories(spec) do set[c] = true end
            local ids = Check.Builders(set)
            local shown = {}
            for i = 1, math.min(8, table.getn(ids)) do table.insert(shown, ids[i]) end
            Note(table.getn(ids) == 0 and 'Nothing in the game builds this unit with these categories.' or (table.getn(ids) .. ' builder(s) of the game list it: ' .. table.concat(shown, ', ') .. (table.getn(ids) > 8 and ', ...' or '')))
            if Wiz.Template(spec.template).builder then
                Text('This unit builds (BuildableCategory, one per line: use | between lines)', function() return table.concat(spec.buildable or {}, ' | ') end, function(v)
                    spec.buildable = {}
                    for line in string.gfind(v .. '|', '([^|]*)|') do
                        local trimmed = string.gsub(line, '^%s+', '')
                        trimmed = string.gsub(trimmed, '%s+$', '')
                        if trimmed ~= '' then table.insert(spec.buildable, trimmed) end
                    end
                end)
            end
        end

        local function TabFiles(spec)
            local dir = Dir()
            local id = spec.id
            Buttons({
                { 'Write files', 84, function()
                    local n, why = Bp.Write()
                    P.note = n and ('written: ' .. n .. ' file(s)' .. (table.getn(Bp.Report or {}) > 0 and ('; ' .. table.concat(Bp.Report, '; ')) or '')) or tostring(why)
                    P:Rebuild()
                end },
                { 'Tweak in Unit lab', 112, function()
                    local ok, lab = pcall(function() return import('/lua/editor/gui/panels_unitlab.lua').live.unitlab end)
                    if ok and lab then
                        lab.unit = id
                        lab.sel = 1
                        lab:Refresh()
                        Say('the Unit lab now edits ' .. id .. ': its changes go into the generated blueprint')
                    else
                        Say('open the Unit lab panel first')
                    end
                end },
            })
            local rels = {
                'units/' .. id .. '/' .. id .. '_unit.bp', 'units/' .. id .. '/' .. id .. '_script.lua', 'units/' .. id .. '/' .. id .. '_strings.lua', 'units/' .. id .. '/' .. id .. '_lod0.scm',
                'units/' .. id .. '/' .. id .. '_albedo.dds', 'units/' .. id .. '/' .. id .. '_normalsts.dds', 'units/' .. id .. '/' .. id .. '_specteam.dds', 'textures/ui/common/icons/units/' .. id .. '_icon.dds',
            }
            for _, rel in rels do
                local stamp = ed_file_stamp(dir .. '/' .. rel)
                local bytes = stamp and tonumber(string.sub(stamp, 1, (string.find(stamp, ':', 1, true) or 1) - 1))
                Label((stamp and 'ok     ' or 'missing  ') .. rel .. (bytes and (' (' .. bytes .. ' bytes)') or ''), stamp and Skin.color.text or Skin.color.warn, true)
            end
            local problems = Check.Check(id, spec, Bp.Edits[id])
            local e, wn, fixable = 0, 0, 0
            for _, p in problems do
                if p.sev == 'E' then e = e + 1 elseif p.sev == 'W' then wn = wn + 1 end
                if p.fix then fixable = fixable + 1 end
            end
            Label(string.format('Checks: %d error(s), %d warning(s), %d fixable', e, wn, fixable), e > 0 and Skin.color.error or Skin.color.text)
            local shown = 0
            for _, p in problems do
                if shown < 10 and p.sev ~= 'I' then
                    shown = shown + 1
                    local color = p.sev == 'E' and Skin.color.error or Skin.color.warn
                    Keep(W.Label(group, (p.fix and '* ' or '') .. string.gsub(p.text, '^' .. id .. ': ', ''), pad, P.y, { color = color, size = 'small' }))
                    P.y = P.y + Skin.S(16)
                end
            end
            if fixable > 0 then
                Buttons({ { 'Fix ' .. fixable .. ' (*)', 90, function()
                    for _, p in Check.Check(id, spec, Bp.Edits[id]) do
                        if p.fix then pcall(p.fix) end
                    end
                    P:Rebuild()
                end } })
            end
            Note('Problems of all units also show in the Validation panel.')
        end

        local function TabTest(spec)
            local p = Test.Pending()
            Buttons({
                { 'Test in game', 96, function()
                    local ok, why = Test.Begin(spec.id, { target = P.targetKind or nil })
                    if not ok then P.note = tostring(why) P:Rebuild() end
                end },
                { 'Restart', 64, function()
                    local ok, why = Test.Restart()
                    if not ok then P.note = tostring(why) P:Rebuild() end
                end },
                { 'End test', 68, function() Test.Stop() P:Rebuild() end },
            })
            Choice('Dummy target', P.targetKind or Test.TargetFor(spec), { { id = 'uel0106', label = 'a bot (ground)' }, { id = 'ueb2101', label = 'a structure' }, { id = 'uea0101', label = 'an aircraft' }, { id = 'ues0103', label = 'a ship' } }, function(id) P.targetKind = id end)
            Note('Test in game writes the project, enables it and reloads the session (a few seconds): the unit stands on the map with two dummy targets 28 units ahead. The targets belong to an enemy army that the test adds to the map (UNIT_TEST_TARGETS; End test removes it), have no weapons and 20,000 health: the unit shoots them when they are in range, Attack sends it. Restart writes and reloads again, which reads the blueprint from disk again.')
            if p then
                Label('Testing ' .. p.unit .. (__blueprints and __blueprints[p.unit] and '' or '  (not in the game: the project is not enabled in this session)'), Skin.color.text, true)
            end
            Buttons({
                { 'Attack', 56, function() Test.Command('attack') end },
                { 'Move', 48, function() Test.Command('move') end },
                { 'Patrol', 52, function() Test.Command('patrol') end },
                { 'Stop', 44, function() Test.Command('stop') end },
                { 'Heal', 44, function() Test.Command('heal') end },
            })
            Buttons({
                { 'Build it from a factory', 140, function()
                    local ok, why = Test.Command('build')
                    if not ok then P.note = tostring(why) P:Rebuild() end
                end },
                { 'Kill', 44, function() Test.Command('kill') end },
                { 'Respawn', 64, function() Test.Respawn() end },
            })
            P.statusLabel = Keep(W.Label(group, '', pad, P.y, { color = Skin.color.text, size = 'small' }))
            P.y = P.y + Skin.S(18)
            P.statusLabel2 = Keep(W.Label(group, '', pad, P.y, { color = Skin.color.text, size = 'small' }))
            P.y = P.y + Skin.S(18)
        end

        -- ---- the frame ----
        function P:Rebuild()
            P.building = true
            Clear()
            W.BeginLayout(group)
            P.y = pad
            local spec = Spec()
            Keep(W.Label(group, Bp.Project and ('Project: ' .. Bp.Project) or 'No project: New project / Open in the Unit lab panel', pad, P.y, { color = Skin.color.textDim, size = 'small' }))
            P.y = P.y + Skin.S(18)
            Buttons({
                { 'New unit...', 84, function() P:NewDialog() end },
                { P.unit and ('Unit: ' .. P.unit) or 'Choose unit', 120, function()
                    local ids = Bp.NewIds()
                    if table.getn(ids) == 0 then Say('the project has no wizard unit yet: New unit...') return end
                    import('/lua/editor/gui/dialogs_mission.lua').PickName('Unit of the project', ids, P.unit, function(name) P.unit = name P.report = '' P:Rebuild() end)
                end },
                { 'Delete', 56, function()
                    if P.unit and Bp.RemoveNew(P.unit) then
                        Say(P.unit .. ' removed from the project (its files stay on disk)')
                        P.unit = false
                        P:Rebuild()
                    end
                end },
            })
            -- the tabs keep the width of their text and wrap into a second row when the panel is narrow
            local tabItems = {}
            for _, name in TABS do
                local tabName = name
                local probe = W.Label(group, name, 0, 0)
                local bw = probe.Width() + Skin.S(14)
                probe:Destroy()
                local b = Keep(W.Button(group, name, pad, P.y, bw, Skin.S(22), function()
                    P.tab = tabName
                    P:Rebuild()
                end))
                b:SetOn(P.tab == name)
                table.insert(tabItems, { b, bw })
            end
            P.y = W.Flow(group, tabItems, pad, P.y, Wd(), Skin.S(22), Skin.S(2)) + Skin.S(8)
            if not Bp.Project then
                Note('Create or open a mod project in the Unit lab panel first.')
            elseif not spec then
                Note('New unit... makes a unit with its own id from a template (land bot, tank, hover, naval, air, defence, economy, engineer, factory) of one of the four factions. The wizard generates the blueprint, the script, the strings, the mesh (your OBJ, or a placeholder), the textures and a preview icon; nothing is copied from a shipped unit except references (sound cues, animation files, bone names).')
            else
                if P.tab == 'Unit' then TabUnit(spec)
                elseif P.tab == 'Stats' then TabStats(spec)
                elseif P.tab == 'Weapons' then TabWeapons(spec)
                elseif P.tab == 'Visuals' then TabVisuals(spec)
                elseif P.tab == 'Build' then TabBuild(spec)
                elseif P.tab == 'Files' then TabFiles(spec)
                else TabTest(spec) end
            end
            if P.note ~= '' then Note(P.note) end
            W.EndLayout(group)
            P.building = false
        end

        function P:NewDialog()
            if not Bp.Project then Say('open or create a mod project first (Unit lab panel)') return end
            local d = Dialog.Open('New unit', 420, 240)
            local st = { template = 'bot', faction = 'UEF' }
            st.id = Bp.SuggestNewId(st.template, st.faction)
            local tBtn, fBtn
            d:Label('Template', 14, 34, { color = Skin.color.textDim, size = 'small' })
            tBtn = d:Button(Labeled(TemplateOptions(), st.template), 14, 52, 190, 24, function()
                Pick('Template', TemplateOptions(), st.template, function(o) if o then st.template = o.id tBtn:SetText(o.label) end end)
            end)
            d:Label('Faction', 216, 34, { color = Skin.color.textDim, size = 'small' })
            fBtn = d:Button(st.faction, 216, 52, 188, 24, function()
                Pick('Faction', FactionOptions(), st.faction, function(o) if o then st.faction = o.id fBtn:SetText(o.label) end end)
            end)
            d:Label('Id (lower case letters and digits, at least 6)', 14, 88, { color = Skin.color.textDim, size = 'small' })
            local idField = d:Field(14, 106, 190, 22, { text = st.id })
            d:Button('Suggest', 216, 106, 80, 22, function() idField:SetText(Bp.SuggestNewId(st.template, st.faction)) end)
            d:Label('Name', 14, 138, { color = Skin.color.textDim, size = 'small' })
            local nameField = d:Field(14, 156, 390, 22, { text = '' })
            local msg = d:Label('', 14, 214, { color = Skin.color.error, size = 'small' })
            d:Button('Create', 14, 186, 90, 24, function()
                local id = idField:GetText()
                local spec, why = Wiz.NewSpec(st.template, st.faction, id)
                if not spec then msg:SetText(tostring(why)) return end
                if nameField:GetText() ~= '' then spec.name = nameField:GetText() end
                local ok, why2 = Bp.AddNew(spec)
                if not ok then msg:SetText(tostring(why2)) return end
                Dialog.Close()
                P.unit = id
                P.tab = 'Unit'
                P.report = ''
                local n = Bp.Write()
                Say('unit ' .. id .. ' made: ' .. tostring(n) .. ' file(s) written (blueprint, script, strings, mesh, textures, icon)')
                P:Rebuild()
            end)
            d:Button('Cancel', 114, 186, 90, 24, function() Dialog.Close() end)
            d:Button('Derive from a game unit...', 214, 186, 190, 24, function() Dialog.Close() P:DeriveDialog() end)
            idField:AcquireFocus()
        end

        --- A unit derived from a unit of the game: no file is copied, the project's blueprint hook copies the base blueprint under the new id (bpedit.AddDerived); the Unit lab edits its numbers.
        function P:DeriveDialog()
            if not Bp.Project then Say('open or create a mod project first (Unit lab panel)') return end
            local Units = import('/lua/editor/units.lua')
            local d = Dialog.Open('Unit derived from a unit of the game', 420, 200)
            d:Label('Base unit (the id of a unit of the game; the Units panel\'s pick is the default)', 14, 34, { color = Skin.color.textDim, size = 'small' })
            local baseField = d:Field(14, 52, 380, 22, { text = Units.Active or '' })
            d:Label('New id (lower case letters and digits, at least 6)', 14, 82, { color = Skin.color.textDim, size = 'small' })
            local idField = d:Field(14, 100, 380, 22, { text = Bp.SuggestNewId('bot', 'UEF') })
            d:Label('Name (optional)', 14, 130, { color = Skin.color.textDim, size = 'small' })
            local nameField = d:Field(14, 148, 380, 22, { text = '' })
            local msg = d:Label('', 120, 176, { color = Skin.color.error, size = 'small' })
            d:Button('Derive', 14, 172, 90, 24, function()
                local ok, why = Bp.AddDerived(idField:GetText(), baseField:GetText(), nameField:GetText(), '')
                if not ok then msg:SetText(tostring(why)) return end
                Dialog.Close()
                Say('derived unit ' .. idField:GetText() .. ' added: edit its numbers in the Unit lab, then Write / Test')
            end)
            baseField:AcquireFocus()
        end

        --- Shows the sim's status of the test while the Test tab is open.
        function P:Refresh()
            if P.tab == 'Test' and P.statusLabel then
                local s = Test.Status()
                if s then
                    pcall(function()
                        P.statusLabel:SetText(string.format('%s  health %d / %d   orders %d   pos %.0f, %.0f', s.alive and 'alive' or 'dead', s.health or 0, s.max or 0, s.orders or 0, s.x or 0, s.z or 0))
                        local parts = {}
                        for i, t in s.targets do table.insert(parts, string.format('%d/%d', t.health, t.max)) end
                        P.statusLabel2:SetText(string.format('targets %s   damage dealt %d   built %d%s', table.concat(parts, ' '), s.damage or 0, s.built or 0, s.error and ('   ' .. s.error) or ''))
                    end)
                else
                    pcall(function() P.statusLabel:SetText(Test.Active and 'waiting for the test ...' or 'no test running') P.statusLabel2:SetText('') end)
                end
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            if not P.unit then
                local ids = Bp.NewIds()
                if table.getn(ids) > 0 then P.unit = ids[1] end
            end
            P:Rebuild()
        end

        function P:Destroy()
            Clear()
        end
        return P
    end,
}

--- Called by the shell about four times a second: continues a test that reloaded the session, and refreshes the open panel.
function Refresh()
    resumeTicks = resumeTicks + 1
    if resumeTicks == 12 then
        pcall(Test.Resume)
    end
    local P = live.unitwiz
    if P then
        if P.tab == 'Test' then pcall(function()
            if resumeTicks > 12 and math.mod(resumeTicks, 4) == 0 then Test.Refresh() end
            P:Refresh()
        end) end
    end
end
