-- The Mesh import panel: imports an OBJ as terrain patches (dialogs_meshimport.lua) and edits what the manifest says about them: which material each
-- patch uses and which texture file each material slot names. "Check mesh" runs the checks that read the vertices (V3, V4, V10, V15; meshscan.lua).
-- The model is the one of the Mesh terrain panel (Mesh.Current); "Save" writes terrain/terrain.lua.
--
--   views: Patches (list of patch entries; Material < > changes the material, Sky toggles drawing last, Remove drops the entry)
--          Materials (list; Add / Remove; Slots opens the fields of the selected material)
--          Fields (texture slots and flags of one material; type a value and press Set)
--          Findings (result of Check mesh)
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Mesh = import('/lua/editor/meshmap.lua')
local PM = import('/lua/editor/gui/panels_mesh.lua')

live = {}

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

Panels.Register{
    id = 'meshimport', title = 'Mesh import',
    stack = { workspace = 'Environment', with = 'meshmap' },
    create = function(group, host)
        local P = { view = 'patches', sel = 1, mat = 1, field = 1, issues = {}, note = '' }
        live.meshimport = P

        local function Model() return Mesh.Current end

        local function PatchRows()
            local rows = {}
            local m = Model()
            if m then
                for i, p in m.patches do
                    if not p.comment then table.insert(rows, { index = i, p = p }) end
                end
            end
            return rows
        end

        local function FieldRows()
            local rows = {}
            for _, k in Mesh.MaterialSlotKeys do table.insert(rows, { key = k, flag = false }) end
            for _, k in Mesh.MaterialFlagKeys do table.insert(rows, { key = k, flag = true }) end
            return rows
        end

        local function Rows()
            local m = Model()
            if P.view == 'checks' then return P.issues end
            if not m then return {} end
            if P.view == 'patches' then return PatchRows() end
            if P.view == 'materials' then return m.materials end
            return FieldRows()
        end

        local function SelPatch()
            local rows = PatchRows()
            return rows[P.sel] and rows[P.sel].p, rows[P.sel] and rows[P.sel].index
        end

        P.list = W.VirtualList(group, {
            extra = true,
            rowH = 22,
            getCount = function() return table.getn(Rows()) end,
            bind = function(row, index)
                local r = Rows()[index]
                if not r then return end
                local c = Skin.color
                local m = Model()
                local label, extra, color = '', '', c.text
                if P.view == 'checks' then
                    label, extra = r.code .. '  ' .. r.text, r.sev
                    color = r.sev == 'E' and c.error or (r.sev == 'W' and c.warn or c.textDim)
                elseif P.view == 'patches' then
                    local p = r.p
                    local mat = m.materials[p.material or 0]
                    label = p.mesh .. ((p.sky and p.sky ~= 0) and '  (sky)' or '')
                    extra = string.format('%s  %d v', mat and (Mesh.MaterialLabel(mat) .. ' [' .. p.material .. ']') or ('material ' .. tostring(p.material) .. '?'), p.vertices or 0)
                    if not mat then color = c.error end
                    if index == P.sel then color = c.accent end
                elseif P.view == 'materials' then
                    label = index .. '  ' .. Mesh.MaterialLabel(r)
                    local slots = 0
                    for _, k in Mesh.MaterialSlotKeys do if Mesh.MaterialGet(r, k) then slots = slots + 1 end end
                    extra = slots .. ' textures'
                    if index == P.mat then color = c.accent end
                else
                    local mat = m.materials[P.mat]
                    local v = mat and Mesh.MaterialGet(mat, r.key)
                    label = r.key
                    extra = v == nil and '-' or tostring(v)
                    color = v == nil and c.textDim or c.text
                    if index == P.field then color = c.accent end
                end
                local ew = math.min(row.extra.Width(), Skin.S(260))
                W.Fit(row.extra, extra, Skin.S(260))
                row.extra:SetColor(c.textDim)
                W.Fit(row.text, label, math.max(Skin.S(30), row.bg.Width() - row.extra.Width() - Skin.S(24)))
                row.text:SetColor(color)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                if P.view == 'patches' then P.sel = index
                elseif P.view == 'materials' then P.mat = index
                elseif P.view == 'fields' then P.field = index
                else return end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })

        local function Need()
            if not Model() then Say('mesh import: load or create a manifest in the Mesh terrain panel first') return false end
            return true
        end
        local function View(name)
            P.view = name
            P:Refresh()
        end

        -- top row
        P.btnImport = W.Button(group, 'Import OBJ...', 0, 0, Skin.S(96), Skin.S(22), function()
            import('/lua/editor/gui/dialogs_meshimport.lua').Open()
        end)
        P.btnPatches = W.Button(group, 'Patches', 0, 0, Skin.S(62), Skin.S(22), function() View('patches') end)
        P.btnMaterials = W.Button(group, 'Materials', 0, 0, Skin.S(72), Skin.S(22), function() View('materials') end)
        P.btnCheck = W.Button(group, 'Check mesh', 0, 0, Skin.S(86), Skin.S(22), function()
            if not Need() then return end
            P.note = 'reading the patches ...'
            local list = Mesh.Check(Model(), nil, { deep = true })
            P.issues = list
            local e, w = Mesh.Count(list)
            P.note = string.format('%d errors, %d warnings', e, w)
            View('checks')
        end)
        P.btnSave = W.Button(group, 'Save', 0, 0, Skin.S(52), Skin.S(22), function()
            if not Need() then return end
            local path, why = Mesh.Save(Model())
            P.note = path and ('saved ' .. path) or tostring(why)
            P:Refresh()
        end)

        -- bottom controls (which are visible depends on the view)
        P.btnMatPrev = W.Button(group, 'Material <', 0, 0, Skin.S(78), Skin.S(22), function() P:StepMaterial(-1) end)
        P.btnMatNext = W.Button(group, 'Material >', 0, 0, Skin.S(78), Skin.S(22), function() P:StepMaterial(1) end)
        P.btnSky = W.Button(group, 'Sky', 0, 0, Skin.S(44), Skin.S(22), function(self)
            local p = SelPatch()
            if p then p.sky = self.on and 1 or nil end
            P:Refresh()
        end, { toggle = true })
        P.btnRemove = W.Button(group, 'Remove', 0, 0, Skin.S(62), Skin.S(22), function()
            local m = Model()
            if not m then return end
            if P.view == 'patches' then
                local _, index = SelPatch()
                if index then
                    table.remove(m.patches, index)
                    P.note = 'entry removed (the .scm file stays on disk)'
                end
            elseif P.view == 'materials' then
                local used = false
                for _, p in m.patches do if p.material == P.mat then used = true end end
                if used then
                    P.note = 'material is used by a patch: change those patches first'
                elseif m.materials[P.mat] then
                    table.remove(m.materials, P.mat)
                    for _, p in m.patches do
                        if p.material and p.material > P.mat then p.material = p.material - 1 end
                    end
                    P.mat = math.max(1, math.min(P.mat, table.getn(m.materials)))
                end
            end
            P:Refresh()
        end)
        P.btnAddMat = W.Button(group, 'Add material', 0, 0, Skin.S(90), Skin.S(22), function()
            if not Need() then return end
            local name = P.nameField:GetText()
            if name == '' then name = 'material' .. (table.getn(Model().materials) + 1) end
            table.insert(Model().materials, { { 'name', name } })
            P.mat = table.getn(Model().materials)
            P:Refresh()
        end)
        P.btnSlots = W.Button(group, 'Textures...', 0, 0, Skin.S(80), Skin.S(22), function()
            if Model() and Model().materials[P.mat] then View('fields') end
        end)
        P.btnBack = W.Button(group, 'Back', 0, 0, Skin.S(50), Skin.S(22), function() View('materials') end)
        P.nameField = W.TextField(group, 0, 0, Skin.S(160), Skin.S(22), {
            onEnter = function(text) P:ApplyField(text) end,
        })
        P.btnSet = W.Button(group, 'Set', 0, 0, Skin.S(44), Skin.S(22), function() P:ApplyField(P.nameField:GetText()) end)
        P.info = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:StepMaterial(delta)
            local m = Model()
            local p = SelPatch()
            if not (m and p) then return end
            local n = table.getn(m.materials)
            if n == 0 then P.note = 'no materials: add one in the Materials view' P:Refresh() return end
            local v = (p.material or 1) + delta
            if v < 1 then v = n elseif v > n then v = 1 end
            p.material = v
            P:Refresh()
        end

        --- The text field means: a new material's name (Materials view) or the value of the selected field (Fields view).
        function P:ApplyField(text)
            local m = Model()
            if not m then return end
            if P.view == 'fields' then
                local mat = m.materials[P.mat]
                local f = FieldRows()[P.field]
                if not (mat and f) then return end
                if f.flag then
                    local v = tonumber(text)
                    Mesh.MaterialSet(mat, f.key, v and v ~= 0 and v or nil)
                else
                    Mesh.MaterialSet(mat, f.key, text ~= '' and text or nil)
                end
                P:Refresh()
            elseif P.view == 'materials' then
                local mat = m.materials[P.mat]
                if mat and text ~= '' then
                    Mesh.MaterialSet(mat, 'name', text)
                    P:Refresh()
                end
            end
        end

        function P:Refresh()
            local m = Model()
            local v = P.view
            local nPatch, nMat = table.getn(PatchRows()), m and table.getn(m.materials) or 0
            P.sel = math.max(1, math.min(P.sel, math.max(1, nPatch)))
            P.mat = math.max(1, math.min(P.mat, math.max(1, nMat)))
            P.list:Refresh()
            local function Show(control, on)
                control:SetHidden(not on)
            end
            Show(P.btnMatPrev, v == 'patches') Show(P.btnMatNext, v == 'patches') Show(P.btnSky, v == 'patches')
            Show(P.btnRemove, v == 'patches' or v == 'materials')
            Show(P.btnAddMat, v == 'materials') Show(P.btnSlots, v == 'materials')
            Show(P.btnBack, v == 'fields')
            Show(P.nameField, v == 'materials' or v == 'fields') Show(P.nameField.frame, v == 'materials' or v == 'fields')
            Show(P.btnSet, v == 'materials' or v == 'fields')
            local text = ''
            if not m then
                text = 'No manifest loaded: use Load or New in the Mesh terrain panel.'
            elseif v == 'patches' then
                local p = SelPatch()
                P.btnSky:SetOn(p and p.sky and p.sky ~= 0 or false)
                text = p and string.format('%s: %d vertices, %d triangles', p.mesh, p.vertices or 0, p.triangles or 0) or 'No patches yet: import an OBJ.'
            elseif v == 'materials' then
                local mat = m.materials[P.mat]
                text = mat and "Name field + Set renames the selected material; 'Add material' uses the name field." or 'No materials.'
            elseif v == 'fields' then
                local mat = m.materials[P.mat]
                local f = FieldRows()[P.field]
                text = mat and f and (Mesh.MaterialLabel(mat) .. ' / ' .. f.key .. (f.flag and ': type 0 or 1 (alpha_test: 0..255) and press Set' or ': a path relative to terrain/, e.g. textures/rock_d.dds; empty clears')) or ''
                local cur = mat and f and Mesh.MaterialGet(mat, f.key)
                if cur ~= nil and P.lastField ~= P.field .. ':' .. P.mat then P.nameField:SetText(tostring(cur)) end
                if cur == nil and P.lastField ~= P.field .. ':' .. P.mat then P.nameField:SetText('') end
                P.lastField = P.field .. ':' .. P.mat
            elseif v == 'checks' then
                text = 'Findings of Check mesh (V1..V20 that need the vertices are included).'
            end
            P.info:SetText(text)
            W.Fit(P.status, P.note, (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local rowH, gap, iw = Skin.S(22), Skin.S(4), w - 2 * pad
            local top = W.Flow(group, { { P.btnImport, Skin.S(96) }, { P.btnPatches, Skin.S(62) }, { P.btnMaterials, Skin.S(72) }, { P.btnCheck, Skin.S(86) }, { P.btnSave, Skin.S(52) } },
                pad, pad, iw, rowH, gap) + Skin.S(4)
            -- the three button sets of the lower block (slot mode / material mode / back) share its first row; each wraps by itself
            local sets = {
                { { P.btnMatPrev, Skin.S(78) }, { P.btnMatNext, Skin.S(78) }, { P.btnSky, Skin.S(44) }, { P.btnRemove, Skin.S(62) } },
                { { P.btnAddMat, Skin.S(90) }, { P.btnSlots, Skin.S(80) } },
                { { P.btnBack, Skin.S(50) } },
            }
            local lower = 0
            for _, set in sets do lower = math.max(lower, W.Flow(group, set, 0, 0, iw, rowH, gap, true)) end
            local foot = Skin.S(104) + (lower - rowH)
            local listH = math.max(Skin.S(60), h - pad - foot - top)
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            local y = math.max(h - foot + Skin.S(4), top + listH + Skin.S(6))      -- (under the list, also in a panel too short for both: the panel scrolls)
            for _, set in sets do W.Flow(group, set, pad, y, iw, rowH, gap) end
            y = y + lower - rowH
            local fw = math.max(Skin.S(80), w - 2 * pad - Skin.S(52))
            W.Place(P.nameField.frame, group, pad, y + Skin.S(28), fw, Skin.S(22))
            P.nameField.Width:Set(fw - 2)
            W.Place(P.btnSet, group, pad + fw + Skin.S(4), y + Skin.S(28), Skin.S(44), Skin.S(22))
            W.Place(P.info, group, pad, y + Skin.S(56))
            W.Place(P.status, group, pad, y + Skin.S(76))
            P:Refresh()
        end
        return P
    end,
}
