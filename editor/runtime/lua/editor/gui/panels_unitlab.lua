-- The Unit lab panel: a mod project and the stats of one unit (bpedit.lua). Pick a unit in the Units panel, press "Edit unit", pick a field in the list and change it with the slider; the base
-- value of the game stays visible beside it. "Write" generates the project's merge blueprints (only the changed fields); "Test" writes, enables the project for this map and reloads the session.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Units = import('/lua/editor/units.lua')
local Bp = import('/lua/editor/bpedit.lua')
local Mods = import('/lua/editor/mods.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

Panels.Register{
    id = 'unitlab', title = 'Unit lab',
    create = function(group, host)
        local P = { unit = false, fields = {}, sel = 1, rev = -1 }
        live.unitlab = P

        local function Reload()
            P.fields = P.unit and Bp.Fields(P.unit) or {}
            if P.sel > table.getn(P.fields) then P.sel = table.getn(P.fields) end
            if P.sel < 1 then P.sel = 1 end
        end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(P.fields) end,
            bind = function(row, index)
                local c = Skin.color
                local f = P.fields[index]
                if not f then return end
                local value = Bp.Get(P.unit, f.key)
                local edited = value ~= f.base
                local fmt = (f.dec == 0) and '%d' or ('%.' .. math.min(f.dec, 2) .. 'f')
                W.Fit(row.text, f.label, math.max(Skin.S(30), row.bg.Width() - Skin.S(170)))
                row.text:SetColor(index == P.sel and c.accent or (edited and c.warn or c.text))
                row.extra:SetText(string.format(fmt, value) .. (edited and ('   (' .. string.format(fmt, f.base) .. ')') or ''))
                row.extra:SetColor(edited and c.warn or c.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index) P.sel = index P:Refresh() end,
            bgColor = Skin.color.panel,
        })
        P.slider = W.Slider(group, { label = 'Value', min = 0, max = 100, step = 1, fmt = '%d',
            get = function()
                local f = P.fields[P.sel]
                return f and Bp.Get(P.unit, f.key) or 0
            end,
            set = function(v)
                local f = P.fields[P.sel]
                if f then Bp.Set(P.unit, f.key, v, true) P.list:Refresh() end
            end })

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end
        P.new = Btn('New project', 84, function()
            local d = Dialog.Open('New mod project', 360, 130)
            d:Label('Name (letters, digits, space, - and _)', 14, 34, { color = Skin.color.textDim, size = 'small' })
            local field = d:Field(14, 56, 330, 22, { text = '' })
            d:Button('Create', 14, 92, 90, 28, function()
                local ok, why = Bp.Create(field:GetText())
                Dialog.Close()
                Say(ok and 'mod project created' or ('mod project: ' .. tostring(why)))
                P:Refresh()
            end)
            d:Button('Cancel', 114, 92, 90, 28, function() Dialog.Close() end)
            field:AcquireFocus()
        end)
        P.open = Btn('Open', 50, function()
            import('/lua/editor/gui/dialogs_mission.lua').PickName('Open a mod project', Bp.Projects(), Bp.Project, function(name)
                local ok, why = Bp.Open(name)
                Say(ok and ('project ' .. name .. ' opened') or ('mod project: ' .. tostring(why)))
                P:Refresh()
            end)
        end)
        P.edit = Btn('Edit unit', 70, function()
            if not Units.Active then Say('pick a unit in the Units panel first') return end
            P.unit = Units.Active
            P.sel = 1
            P:Refresh()
        end)
        P.derive = Btn('Derive unit...', 96, function()
            local base = P.unit or Units.Active
            if not base then Say('pick a unit in the Units panel first') return end
            if not Bp.Project then Say('open or create a mod project first') return end
            local d = Dialog.Open('New unit derived from ' .. tostring(base), 420, 190)
            d:Label('Id (lower case letters and digits, like zml0001)', 14, 34, { color = Skin.color.textDim, size = 'small' })
            local idField = d:Field(14, 54, 380, 22, { text = '' })
            d:Label('Name (optional)', 14, 84, { color = Skin.color.textDim, size = 'small' })
            local nameField = d:Field(14, 104, 380, 22, { text = '' })
            d:Button('Create', 14, 144, 90, 28, function()
                local id = idField:GetText()
                local ok, why = Bp.AddDerived(id, base, nameField:GetText(), '')
                Dialog.Close()
                if ok then
                    P.unit = id
                    P.sel = 1
                    Say('derived unit ' .. id .. ' added: edit its stats, then Write / Test')
                else
                    Say('derived unit: ' .. tostring(why))
                end
                P:Refresh()
            end)
            d:Button('Cancel', 114, 144, 90, 28, function() Dialog.Close() end)
            idField:AcquireFocus()
        end)
        P.revert = Btn('Revert', 54, function()
            local f = P.fields[P.sel]
            if f then Bp.Revert(P.unit, f.key) P:Refresh() end
        end)
        P.revertAll = Btn('Revert unit', 76, function() if P.unit then Bp.RevertAll(P.unit) P:Refresh() end end)
        P.write = Btn('Write', 50, function()
            local n, why = Bp.Write()
            Say(n and ('mod project: ' .. n .. ' blueprint file(s) written') or ('mod project: ' .. tostring(why)))
            P:Refresh()
        end)
        P.test = Btn('Test', 44, function()
            local n, why = Bp.Write()
            if not n then Say('mod project: ' .. tostring(why)) return end
            local uid
            for u, mod in Mods.All() do
                if mod.name == Bp.Project then uid = u end
            end
            if not uid then Say('mod project: the engine does not list the project as a mod yet (restart the editor once)') return end
            local set = Mods.GetSelection()
            set[uid] = true
            UI.State.modsPending = set
            UI.ApplyMods()
        end)
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.rev = Bp.Revision
            Reload()
            P.list:Refresh()
            local f = P.fields[P.sel]
            if f then
                local fmt = (f.dec == 0) and '%d' or ('%.' .. math.min(f.dec, 2) .. 'f')
                P.slider:SetRange(f.min, math.max(f.max, Bp.Get(P.unit, f.key) or 0), f.step, fmt)
                P.slider.label:SetText(f.label .. '  (game: ' .. string.format(fmt, f.base) .. ')')
                P.slider:Refresh()
            end
            local problems = Bp.Check()
            local desc = ''
            if P.unit then
                for _, e in Units.Catalog() do if e.id == P.unit then desc = e.desc end end
            end
            W.Fit(P.status, (Bp.Project and ('Project: ' .. Bp.Project) or 'No project (New project / Open)') .. '   Unit: ' .. tostring(P.unit or 'none') .. ' ' .. desc ..
                             (table.getn(problems) > 0 and ('   ' .. problems[1].text) or ''), (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local u1 = W.Flow(group, { { P.new, Skin.S(84) }, { P.open, Skin.S(50) }, { P.edit, Skin.S(70) }, { P.write, Skin.S(50) }, { P.test, Skin.S(44) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            W.Place(P.status, group, pad, u1 + Skin.S(6))
            local top = u1 + Skin.S(24)
            local lower = W.Flow(group, { { P.revert, Skin.S(54) }, { P.revertAll, Skin.S(76) }, { P.derive, Skin.S(96) } }, 0, 0, w - 2 * pad, Skin.S(22), Skin.S(6), true)
            local foot = Skin.S(86) + (lower - Skin.S(22))
            P.list:SetRect(pad, top, w - 2 * pad, math.max(Skin.S(60), h - top - foot - pad))
            local y = h - foot
            P.slider:Place(pad, y, w - 2 * pad)
            W.Flow(group, { { P.revert, Skin.S(54) }, { P.revertAll, Skin.S(76) }, { P.derive, Skin.S(96) } }, pad, y + Skin.S(50), w - 2 * pad, Skin.S(22), Skin.S(6))
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second.
function Refresh()
    local P = live.unitlab
    if P and P.rev ~= Bp.Revision then pcall(P.Refresh, P) end
end
