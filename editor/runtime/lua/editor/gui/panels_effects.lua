-- The Effects panel (effectview.lua): the effect templates of the game (filter field, a click plays the template at the lab spot), the projectile blueprints (a click fires one from the unit of the Unit
-- viewer) and the Fields tab: the numbers of the emitter blueprints of the template that was played (or of the projectile that was fired), edited with a slider and written as merge blueprints into the
-- open mod project (bpedit.lua / fxedit.lua; the changes show after "Test" in the Unit lab reloads the session with the project). The height slider lifts the effect above the ground.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local FX = import('/lua/editor/effectview.lua')
local Bp = import('/lua/editor/bpedit.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

--- Shows or hides a button, label or slider (a slider is several controls).
local function ShowControl(c, shown)
    local parts = c.track and { c.label, c.track, c.fill, c.thumb, c.minus, c.plus, c.field and c.field.frame } or { c }
    for _, part in parts do
        if part then
            if shown then part:Show() else part:Hide() end
        end
    end
end

local function ShortName(path)
    return (string.gsub(path, '^.*/', ''))
end

Panels.Register{
    id = 'effects', title = 'Effects',
    create = function(group, host)
        local P = { mode = 'effects', shown = {}, height = 1, speed = 15, targets = {}, target = false, fields = {}, sel = 1, rev = -1 }
        live.effects = P

        local function Rebuild()
            local filter = string.lower(P.filter and P.filter:GetText() or '')
            P.shown = {}
            if P.mode == 'effects' then
                for _, t in FX.Templates() do
                    if filter == '' or string.find(string.lower(t.name), filter, 1, true) then table.insert(P.shown, { name = t.name, count = table.getn(t.emitters) }) end
                end
            elseif P.mode == 'projectiles' then
                for _, id in FX.Projectiles() do
                    if filter == '' or string.find(string.lower(id), filter, 1, true) then table.insert(P.shown, { name = id, count = 0 }) end
                end
            end
            if P.list then P.list:Refresh() end
        end

        --- The things the Fields tab can edit: the emitters of the template that was played, or the projectile that was fired.
        local function Retarget()
            P.targets = FX.Targets()
            local keep = false
            for _, t in P.targets do if t == P.target then keep = true end end
            if not keep then P.target = P.targets[1] or false P.sel = 1 end
            P.fields = P.target and Bp.Fields(P.target) or {}
            if P.sel > table.getn(P.fields) then P.sel = table.getn(P.fields) end
            if P.sel < 1 then P.sel = 1 end
        end

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end
        P.bEffects = Btn('Effects', 64, function() P.mode = 'effects' Rebuild() P:Refresh() P:OnResize(P.w or 300, P.h or 300) end)
        P.bProj = Btn('Projectiles', 84, function() P.mode = 'projectiles' Rebuild() P:Refresh() P:OnResize(P.w or 300, P.h or 300) end)
        P.bFields = Btn('Fields', 56, function() P.mode = 'fields' Retarget() P:Refresh() P:OnResize(P.w or 300, P.h or 300) end)
        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function() Rebuild() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })

        P.list = W.VirtualList(group, {
            extra = true, rowH = 20,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local c = Skin.color
                local e = P.shown[index]
                if not e then return end
                W.Fit(row.text, e.name, math.max(Skin.S(30), row.bg.Width() - Skin.S(60)))
                row.text:SetColor(FX.Last == e.name and c.accent or c.text)
                row.extra:SetText(e.count > 0 and (e.count .. ' emitters') or '')
                row.extra:SetColor(c.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local e = P.shown[index]
                if not e then return end
                if P.mode == 'effects' then
                    FX.Play(e.name, P.height)
                else
                    local ok, why = FX.Fire(e.name, P.speed)
                    if not ok then Say('effects: ' .. tostring(why)) end
                    FX.Last, FX.LastKind = e.name, 'projectile'
                end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.heightSlider = W.Slider(group, { label = 'Height above the ground', min = 0, max = 30, step = 0.5, fmt = '%.1f', get = function() return P.height end, set = function(v) P.height = v end })
        P.speedSlider = W.Slider(group, { label = 'Projectile speed', min = 1, max = 80, step = 1, fmt = '%d', get = function() return P.speed end, set = function(v) P.speed = v end })

        -- the Fields tab: targets (emitters / the projectile), their numbers, the value
        P.tlist = W.VirtualList(group, {
            rowH = 20,
            getCount = function() return table.getn(P.targets) end,
            bind = function(row, index)
                local c = Skin.color
                local t = P.targets[index]
                if not t then return end
                local edited = Bp.Edits[t] ~= nil
                W.Fit(row.text, ShortName(t), math.max(Skin.S(30), row.bg.Width() - Skin.S(20)))
                row.text:SetColor(t == P.target and c.accent or (edited and c.warn or c.text))
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local t = P.targets[index]
                if t then P.target, P.sel = t, 1 Retarget() P:Refresh() end
            end,
            bgColor = Skin.color.panel,
        })
        P.flist = W.VirtualList(group, {
            extra = true, rowH = 20,
            getCount = function() return table.getn(P.fields) end,
            bind = function(row, index)
                local c = Skin.color
                local f = P.fields[index]
                if not f then return end
                local value = Bp.Get(P.target, f.key)
                local edited = value ~= f.base
                local fmt = (f.dec == 0) and '%d' or '%.2f'
                W.Fit(row.text, f.label, math.max(Skin.S(30), row.bg.Width() - Skin.S(150)))
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
        P.valueSlider = W.Slider(group, { label = 'Value', min = 0, max = 100, step = 1, fmt = '%d',
            get = function()
                local f = P.fields[P.sel]
                return f and Bp.Get(P.target, f.key) or 0
            end,
            set = function(v)
                local f = P.fields[P.sel]
                if f and P.target then Bp.Set(P.target, f.key, v, true) P.flist:Refresh() P.tlist:Refresh() end
            end })
        P.bRevert = Btn('Revert', 54, function()
            local f = P.fields[P.sel]
            if f and P.target then Bp.Revert(P.target, f.key) P:Refresh() end
        end)
        P.bWrite = Btn('Write project', 90, function()
            local n, why = Bp.Write()
            Say(n and ('mod project: ' .. n .. ' file(s) written (Test in the Unit lab loads them)') or ('mod project: ' .. tostring(why)))
        end)
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.rev = Bp.Revision
            P.bEffects:SetOn(P.mode == 'effects')
            P.bProj:SetOn(P.mode == 'projectiles')
            P.bFields:SetOn(P.mode == 'fields')
            if P.mode == 'fields' then
                Retarget()
                P.tlist:Refresh()
                P.flist:Refresh()
                local f = P.fields[P.sel]
                if f then
                    local fmt = (f.dec == 0) and '%d' or '%.2f'
                    P.valueSlider:SetRange(f.min, math.max(f.max, Bp.Get(P.target, f.key) or 0), f.step, fmt)
                    P.valueSlider.label:SetText(f.label .. '  (game: ' .. string.format(fmt, f.base) .. ')')
                    P.valueSlider:Refresh()
                end
                local what = P.target and ShortName(P.target) or 'nothing played yet'
                W.Fit(P.status, (Bp.Project and ('Project: ' .. Bp.Project) or 'No project (Unit lab)') .. '   ' .. what .. '   ' .. table.getn(P.fields) .. ' fields', (P.w or 300) - Skin.S(16))
            else
                P.list:Refresh()
                P.heightSlider:Refresh() P.speedSlider:Refresh()
                W.Fit(P.status, P.mode == 'effects' and (table.getn(P.shown) .. ' templates, a click plays one at the lab spot') or (table.getn(P.shown) .. ' projectiles, a click fires one from the shown unit'), (P.w or 300) - Skin.S(16))
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            W.Flow(group, { { P.bEffects, Skin.S(64) }, { P.bProj, Skin.S(84) }, { P.bFields, Skin.S(56) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            -- the filter shares the row with the mode buttons when it has room (at least 40 px of field), else it takes a row of its own
            local fx, fy, top = pad + Skin.S(216), pad, pad + Skin.S(28)
            if w - fx - Skin.S(34) - pad < Skin.S(40) then
                fx, fy, top = pad, pad + Skin.S(28), pad + Skin.S(56)
            end
            W.Place(P.filterLabel, group, fx, fy + Skin.S(3))
            W.Place(P.filter.frame, group, fx + Skin.S(34), fy, math.max(Skin.S(40), w - fx - Skin.S(34) - pad), Skin.S(22))
            P.filter.Width:Set(math.max(Skin.S(40), w - fx - Skin.S(34) - pad) - 2)
            local fields = P.mode == 'fields'
            for _, l in { P.list.root } do if fields then l:Hide() else l:Show() end end
            for _, l in { P.tlist.root, P.flist.root } do if fields then l:Show() else l:Hide() end end
            for _, c in { P.valueSlider, P.bRevert, P.bWrite } do ShowControl(c, fields) end
            for _, c in { P.heightSlider, P.speedSlider } do ShowControl(c, not fields) end
            if fields then
                local tl = Skin.S(86)
                P.tlist:SetRect(pad, top, w - 2 * pad, tl)
                local foot = Skin.S(92)
                P.flist:SetRect(pad, top + tl + Skin.S(4), w - 2 * pad, math.max(Skin.S(50), h - top - tl - Skin.S(4) - foot - pad))
                local y = h - foot + Skin.S(4)
                P.valueSlider:Place(pad, y, w - 2 * pad)
                W.Place(P.bRevert, group, pad, y + Skin.S(50), Skin.S(54), Skin.S(22))
                W.Place(P.bWrite, group, pad + Skin.S(60), y + Skin.S(50), Skin.S(90), Skin.S(22))
                W.Place(P.status, group, pad, y + Skin.S(76))
            else
                local foot = Skin.S(130)
                P.list:SetRect(pad, top, w - 2 * pad, math.max(Skin.S(50), h - top - foot - pad))
                local y = h - foot + Skin.S(4)
                P.heightSlider:Place(pad, y, w - 2 * pad)
                P.speedSlider:Place(pad, y + Skin.S(50), w - 2 * pad)
                W.Place(P.status, group, pad, y + Skin.S(100))
                Rebuild()
            end
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: a Fields tab follows edits made elsewhere.
function Refresh()
    local P = live.effects
    if P and P.mode == 'fields' and P.rev ~= Bp.Revision then pcall(P.Refresh, P) end
end
