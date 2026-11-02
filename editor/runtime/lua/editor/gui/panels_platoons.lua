-- The Platoons panel: the save file's platoon templates, order queues and the platoon builders of the armies (platoons.lua). Three views:
--   Platoons   the templates (list) and the unit types of the chosen one (rows: unit, min, max, squad, formation) with a plan field; "From group" makes a template from the units of an army
--              group; "Assign" puts the template on a group
--   Orders     the order queues (list) and the orders of the chosen one (Move / Patrol / Attack / Stop with a marker or a chain); "Assign" puts the queue on a group
--   Builders   the platoon builders of one army (campaign AI); "Edit" opens the whole builder
-- Every edit is one undo step. The map's validation lists missing chains, groups and templates.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local PL = import('/lua/editor/platoons.lua')
local M = import('/lua/editor/mission.lua')
local Map = import('/lua/editor/map.lua')

live = {}

local function Say(text)
    M.Safe('status line', UI.Say, text)
end

local function Dialogs() return import('/lua/editor/gui/dialogs_mission.lua') end

local function Row(row, label, extra, color)
    local c = Skin.color
    local room = row.bg.Width()
    row.extra:SetText(extra or '')
    row.extra:SetColor(c.textDim)
    if row.extra.Width() > room / 2 then W.Fit(row.extra, extra or '', math.floor(room / 2)) end          -- the right text never takes more than half the row
    W.Fit(row.text, label, math.max(Skin.S(30), room - row.extra.Width() - Skin.S(20)))          -- the left one gets what the right one leaves
    row.text:SetColor(color or c.text)
    local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
    row.text.Top:Set(function() return row.bg.Top() + ty end)
    local w2 = row.extra.Width()
    row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
    row.extra.Top:Set(function() return row.bg.Top() + ty end)
end

local function Cycle(list, current)
    for i, v in list do
        if v == current then return list[math.mod(i, table.getn(list)) + 1] end
    end
    return list[1]
end

local function ShortName(bp)
    return bp or ''
end

--- Army, then group: done(army, group).
local function PickGroup(title, done)
    local Army = import('/lua/editor/armysetup.lua')
    Dialogs().PickName(title .. ': army', Army.Names(), nil, function(army)
        local groups = PL.GroupNames(army)
        if table.getn(groups) == 0 then Say('platoons: ' .. army .. ' has no groups yet (Unit tool, group)') return end
        Dialogs().PickName(title .. ': group of ' .. army, groups, nil, function(group) done(army, group) end)
    end)
end

Panels.Register{
    id = 'platoons', title = 'Platoons',
    stack = { { workspace = 'Mission', with = 'armies' }, { workspace = 'Objects', with = 'chains' } },
    create = function(group, host)
        local P = { mode = 'platoons', rev = -1, army = false, names = {}, row = 1, sel = {} }
        live.platoons = P
        local c = Skin.color

        local function Kind() return (P.mode == 'orders') and 'orders' or 'platoon' end

        local function Items()
            if P.mode == 'platoons' then return PL.PlatoonNames() end
            if P.mode == 'orders' then return PL.OrderNames() end
            return P.army and PL.BuilderNames(P.army) or {}
        end

        local function Current()
            local names = Items()
            local sel = P.sel[P.mode]
            local found = false
            for _, n in names do if n == sel then found = true end end
            if not found then sel = names[1] P.sel[P.mode] = sel end
            return sel, names
        end

        local function Details()
            -- rows of the platoon / orders of the queue / nothing for builders
            local name = Current()
            if not name then return {} end
            if P.mode == 'platoons' then return PL.Rows(name) end
            if P.mode == 'orders' then return PL.Queue(name) end
            return {}
        end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(Items()) end,
            bind = function(row, index)
                local names = Items()
                local name = names[index]
                if not name then return end
                local extra = ''
                if P.mode == 'platoons' then extra = (table.getn(PL.Rows(name))) .. ' types'
                elseif P.mode == 'orders' then extra = table.getn(PL.Queue(name)) .. ' orders'
                else
                    local b = PL.Builders(P.army)[name]
                    extra = tostring(b and b.PlatoonTemplate or '')
                end
                Row(row, name, extra, name == P.sel[P.mode] and c.accent or nil)
            end,
            onSelect = function(index)
                P.sel[P.mode] = Items()[index]
                P.row = 1
                P:Refresh(true)
            end,
            bgColor = c.panel,
        })
        P.rows = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(Details()) end,
            bind = function(row, index)
                local d = Details()[index]
                if not d then return end
                if P.mode == 'platoons' then
                    Row(row, index .. '   ' .. ShortName(d.bp), d.min .. '-' .. d.max .. '  ' .. tostring(d.squad), index == P.row and c.accent or nil)
                else
                    local target = (d.chain or '') ~= '' and ('chain ' .. d.chain) or ((d.target or '') ~= '' and d.target or '')
                    Row(row, index .. '   ' .. tostring(d.type) .. '  ' .. target, '', index == P.row and c.accent or nil)
                end
            end,
            onSelect = function(index) P.row = index P:Refresh(true) end,
            bgColor = c.panel,
        })

        local function Btn(text, w, fn, opts) local b = W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) b.w = w return b end

        P.m1 = Btn('Platoons', 70, function() P.mode = 'platoons' P.row = 1 P:OnResize(P.vw, P.vh) end)
        P.m2 = Btn('Orders', 60, function() P.mode = 'orders' P.row = 1 P:OnResize(P.vw, P.vh) end)
        P.m3 = Btn('Builders', 66, function() P.mode = 'builders' P.row = 1 P:OnResize(P.vw, P.vh) end)
        P.army1 = Btn('Army...', 60, function()
            local Army = import('/lua/editor/armysetup.lua')
            Dialogs().PickName('Platoon builders of army', Army.Names(), P.army, function(a) P.army = a P:Refresh(true) end)
        end, { tip = 'The army whose platoons, orders and builders are shown. Click to choose another army.' })

        P.bNew = Btn('New...', 54, function()
            local base = (P.mode == 'platoons') and 'Platoon name (letters, digits, _), e.g. WestAttack'
                or ((P.mode == 'orders') and 'Order queue name (letters, digits, _), e.g. PatrolNorth' or 'Builder name (letters, digits, _), e.g. WestTanks')
            Dialogs().NameDialog('New', base, function(name)
                local ok, why
                if P.mode == 'platoons' then ok, why = PL.NewPlatoon(name)
                elseif P.mode == 'orders' then ok, why = PL.NewOrders(name)
                else
                    if not P.army then Say('platoons: choose an army first') return end
                    ok, why = PL.NewBuilder(P.army, name, P.sel.platoons)
                end
                if ok then P.sel[P.mode] = name else Say('platoons: ' .. tostring(why)) end
                P:Refresh(true)
            end)
        end)
        P.bGroup = Btn('From group...', 90, function()
            PickGroup('Platoon from the units of a group', function(army, grp)
                local name, why = PL.FromGroup(army, grp)
                if name then P.sel.platoons = name P.row = 1 else Say('platoons: ' .. tostring(why)) end
                P:Refresh(true)
            end)
        end)
        P.bDup = Btn('Copy', 44, function()
            local name = Current()
            if not name then return end
            local new
            if P.mode == 'platoons' then new = PL.DuplicatePlatoon(name)
            elseif P.mode == 'orders' then new = PL.DuplicateOrders(name)
            else new = PL.DuplicateBuilder(P.army, name) end
            if new then P.sel[P.mode] = new end
            P:Refresh(true)
        end)
        P.bRename = Btn('Rename...', 66, function()
            local old = Current()
            if not old then return end
            Dialogs().NameDialog('Rename ' .. old, 'New name', function(name)
                local ok, why
                if P.mode == 'platoons' then ok, why = PL.RenamePlatoon(old, name)
                elseif P.mode == 'orders' then ok, why = PL.RenameOrders(old, name)
                else ok, why = PL.RenameBuilder(P.army, old, name) end
                if ok then
                    P.sel[P.mode] = name
                    if type(why) == 'number' and why > 0 then Say('platoons: ' .. why .. ' reference(s) renamed') end
                else Say('platoons: ' .. tostring(why)) end
                P:Refresh(true)
            end)
        end)
        P.bDel = Btn('Delete', 52, function()
            local name = Current()
            if not name then return end
            if P.mode == 'builders' then PL.DeleteBuilder(P.army, name)
            else
                local used = PL.UsedBy(Kind(), name)
                PL.Delete(Kind(), name)
                if table.getn(used) > 0 then Say('platoons: ' .. name .. ' was used by ' .. table.getn(used) .. ' thing(s); units and groups lost it, builders and mission nodes keep the dead name (see Validation)') end
            end
            P:Refresh(true)
        end)
        P.bAssign = Btn('Assign to group...', 116, function()
            local name = Current()
            if not name then return end
            PickGroup('Give ' .. name .. ' to', function(army, grp)
                local ok, why
                if P.mode == 'platoons' then ok, why = PL.AssignPlatoon(army, grp, name) else ok, why = PL.AssignOrders(army, grp, name) end
                Say(ok and ('platoons: ' .. name .. ' is now on ' .. grp .. ' of ' .. army) or ('platoons: ' .. tostring(why)))
                P:Refresh(true)
            end)
        end)
        P.bEdit = Btn('Edit...', 54, function()
            local name = Current()
            if name and P.army then import('/lua/editor/gui/dialogs_platoons.lua').EditBuilder(P.army, name, function() P:Refresh(true) end) end
        end)

        -- platoon detail
        P.planLabel = W.Label(group, 'Plan', 0, 0, { color = c.textDim, size = 'small' })
        P.plan = W.TextField(group, 0, 0, Skin.S(160), Skin.S(22), {
            onEnter = function(text)
                local name = Current()
                if name then PL.SetPlan(name, text) end
                P:Refresh(true)
            end,
        })
        P.rowAdd = Btn('Add unit...', 74, function()
            local name = Current()
            if not name then return end
            import('/lua/editor/gui/browser.lua').OpenUnits{ title = 'Add a unit type to ' .. name, done = function(id)
                P.row = PL.AddRow(name, { id }) or P.row
                P:Refresh(true)
            end }
        end)
        P.rowDel = Btn('Remove', 58, function()
            local name = Current()
            if name and P.mode == 'platoons' then PL.RemoveRow(name, P.row) P.row = math.max(1, P.row - 1) end
            if name and P.mode == 'orders' then PL.RemoveOrder(name, P.row) P.row = math.max(1, P.row - 1) end
            P:Refresh(true)
        end)
        P.rowUp = Btn('Up', 34, function()
            local name = Current()
            if not name then return end
            local ok
            if P.mode == 'platoons' then ok = PL.MoveRow(name, P.row, -1) else ok = PL.MoveOrder(name, P.row, -1) end
            if ok then P.row = P.row - 1 end
            P:Refresh(true)
        end)
        P.rowDown = Btn('Down', 44, function()
            local name = Current()
            if not name then return end
            local ok
            if P.mode == 'platoons' then ok = PL.MoveRow(name, P.row, 1) else ok = PL.MoveOrder(name, P.row, 1) end
            if ok then P.row = P.row + 1 end
            P:Refresh(true)
        end)
        P.unitBtn = Btn('Unit...', 120, function()
            local name = Current()
            if not name then return end
            import('/lua/editor/gui/browser.lua').OpenUnits{ title = 'Unit type of row ' .. tostring(P.row), done = function(id) PL.SetRow(name, P.row, 'bp', id) P:Refresh(true) end }
        end)
        P.squadBtn = Btn('Squad', 90, function()
            local name = Current()
            local d = name and PL.Rows(name)[P.row]
            if d then PL.SetRow(name, P.row, 'squad', Cycle(PL.SQUADS, d.squad)) end
            P:Refresh(true)
        end)
        P.formBtn = Btn('Formation', 130, function()
            local name = Current()
            local d = name and PL.Rows(name)[P.row]
            if d then PL.SetRow(name, P.row, 'formation', Cycle(PL.FORMATIONS, d.formation)) end
            P:Refresh(true)
        end)
        local function RowSlider(label, key, max)
            return W.Slider(group, { label = label, min = 0, max = max, step = 1, fmt = '%d', compact = true,
                get = function()
                    local name = Current()
                    local d = name and PL.Rows(name)[P.row]
                    return d and d[key] or 0
                end,
                set = function(v)
                    local name = Current()
                    if name and PL.Rows(name)[P.row] then PL.SetRow(name, P.row, key, v, true) end
                    P.rows:Refresh()
                end })
        end
        P.minS = RowSlider('Min', 'min', 100)
        P.maxS = RowSlider('Max', 'max', 100)

        -- order detail
        P.typeBtn = Btn('Type', 90, function()
            local name = Current()
            local d = name and PL.Queue(name)[P.row]
            if d then PL.SetOrder(name, P.row, 'type', Cycle(PL.ORDER_TYPES, d.type)) end
            P:Refresh(true)
        end)
        P.markerBtn = Btn('Marker', 130, function()
            local name = Current()
            if not name or not PL.Queue(name)[P.row] then return end
            Dialogs().PickName('Marker', import('/lua/editor/mission.lua').MarkerNames(), nil, function(m) PL.SetOrder(name, P.row, 'target', m) P:Refresh(true) end)
        end)
        P.chainBtn = Btn('Chain', 130, function()
            local name = Current()
            if not name or not PL.Queue(name)[P.row] then return end
            Dialogs().PickName('Chain', import('/lua/editor/chains.lua').Names(), nil, function(m) PL.SetOrder(name, P.row, 'chain', m) P:Refresh(true) end)
        end)
        P.orderAdd = Btn('Add order', 70, function()
            local name = Current()
            if not name then return end
            P.row = PL.AddOrder(name, {}) or P.row
            P:Refresh(true)
        end)

        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.used = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        local all = { 'm1', 'm2', 'm3', 'army1', 'bNew', 'bGroup', 'bDup', 'bRename', 'bDel', 'bAssign', 'bEdit', 'rowAdd', 'rowDel', 'rowUp', 'rowDown', 'unitBtn', 'squadBtn', 'formBtn',
                      'typeBtn', 'markerBtn', 'chainBtn', 'orderAdd', 'planLabel', 'status', 'used' }

        function P:Refresh(force)
            if not force and P.rev == PL.Revision then return end
            P.rev = PL.Revision
            if not P.army then
                local Army = import('/lua/editor/armysetup.lua')
                local names = Army.Names()
                P.army = names[1] or false
                for _, a in names do           -- the first army that has builders
                    if table.getn(PL.BuilderNames(a)) > 0 then P.army = a break end
                end
            end
            P.m1:SetOn(P.mode == 'platoons')
            P.m2:SetOn(P.mode == 'orders')
            P.m3:SetOn(P.mode == 'builders')
            P.army1:SetText(P.army and tostring(P.army) or 'Army...')
            local name = Current()
            P.list:Refresh()
            local n = table.getn(Details())
            if P.row > n then P.row = n end
            if P.row < 1 then P.row = 1 end
            P.rows:Refresh()
            local d = name and Details()[P.row]
            if P.mode == 'platoons' then
                P.plan:SetText(name and PL.Plan(name) or '')
                P.unitBtn:SetText(d and tostring(d.bp) or 'Unit...')
                P.squadBtn:SetText(d and ('Squad: ' .. tostring(d.squad)) or 'Squad')
                P.formBtn:SetText(d and ('Form: ' .. tostring(d.formation)) or 'Formation')
                P.minS:Refresh() P.maxS:Refresh()
            elseif P.mode == 'orders' then
                P.typeBtn:SetText(d and tostring(d.type) or 'Type')
                P.markerBtn:SetText(d and ((d.target or '') ~= '' and d.target or 'Marker...') or 'Marker')
                P.chainBtn:SetText(d and ((d.chain or '') ~= '' and d.chain or 'Chain...') or 'Chain')
            end
            local problems = PL.Problems()
            local e, wn = 0, 0
            for _, p in problems do if p.sev == 'E' then e = e + 1 elseif p.sev == 'W' then wn = wn + 1 end end
            local first = problems[1]
            W.Fit(P.status, string.format('%d platoons, %d order queues, %d errors, %d warnings%s', table.getn(PL.PlatoonNames()), table.getn(PL.OrderNames()), e, wn, first and (': ' .. first.text) or ''), (P.w or 300) - Skin.S(16))
            if name and P.mode ~= 'builders' then
                local used = PL.UsedBy(Kind(), name)
                P.used:SetText(name .. ' is used by ' .. table.getn(used) .. (table.getn(used) > 0 and (': ' .. used[1].text) or ''))
            else
                P.used:SetText('')
            end
        end

        function P:OnResize(w, h)
            P.w, P.vw, P.vh = w, w, h
            local pad = Skin.S(8)
            for _, k in all do W.Place(P[k], group, -20000, -20000, Skin.S(P[k].w or 40), Skin.S(22)) end
            for _, s in { P.minS, P.maxS } do s:Place(-20000, -20000, Skin.S(100)) end
            W.Place(P.plan.frame, group, -20000, -20000, Skin.S(60), Skin.S(22))
            local x
            local modeRow = { { P.m1, Skin.S(P.m1.w) }, { P.m2, Skin.S(P.m2.w) }, { P.m3, Skin.S(P.m3.w) } }
            if P.mode == 'builders' then table.insert(modeRow, { P.army1, Skin.S(110) }) end
            local y = W.Flow(group, modeRow, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            local function Bw(list) local t = {} for _, b in list do table.insert(t, { b, Skin.S(b.w) }) end return t end
            local rowsAfter = {}      -- the button rows below the row list wrap in a narrow panel: they take their extra rows from the lists
            if P.mode == 'platoons' then rowsAfter = { Bw({ P.rowAdd, P.rowDel, P.rowUp, P.rowDown }), { { P.squadBtn, Skin.S(110) }, { P.formBtn, Skin.S(150) } } }
            elseif P.mode == 'orders' then rowsAfter = { Bw({ P.orderAdd, P.rowDel, P.rowUp, P.rowDown }) } end
            local extraRows = 0
            for _, r in rowsAfter do extraRows = extraRows + (W.Flow(group, r, 0, 0, w - 2 * pad, Skin.S(22), Skin.S(4), true) - Skin.S(22)) / Skin.S(26) end
            extraRows = math.floor(extraRows + 0.5)
            local row = { P.bNew, P.bDup, P.bRename, P.bDel }
            if P.mode == 'platoons' then table.insert(row, 2, P.bGroup) end
            -- the space left for the two lists once the buttons, the unit editor and the two status lines have theirs
            local lines, bx = 1, pad
            for _, bt in row do
                if bx + Skin.S(bt.w) > w - pad then lines = lines + 1 bx = pad end
                bx = bx + Skin.S(bt.w) + Skin.S(4)
            end
            local bottom = 0
            if P.mode == 'platoons' then bottom = Skin.S(26 * 3 + 48 + 4) elseif P.mode == 'orders' then bottom = Skin.S(26 + 28 + 4) end
            local planFx = pad + Skin.S(124) + P.planLabel.Width() + Skin.S(6)
            local planOwnRow = P.mode == 'platoons' and planFx + Skin.S(60) > w - pad          -- too narrow beside the Assign button: the plan takes its own row
            if planOwnRow then bottom = bottom + Skin.S(28) end
            local lh = math.max(Skin.S(16), P.status.Height())          -- the two status lines are as tall as their text, not as the 16 px they were given
            local free = h - y - pad - (2 * lh + Skin.S(4)) - Skin.S(4) - lines * Skin.S(26) - ((P.mode == 'builders') and Skin.S(26) or Skin.S(28)) - bottom - extraRows * Skin.S(26)
            local need = (P.mode == 'builders') and Skin.S(44) or Skin.S(44 + 30)
            if free < need then h = h + (need - free) free = need end          -- too little room: the panel scrolls instead of piling its controls up
            local listH = (P.mode == 'builders') and math.max(Skin.S(44), free) or math.max(Skin.S(44), math.floor(free * 0.4))
            local rowsH = math.max(Skin.S(30), free - listH)
            P.list:SetRect(pad, y, w - 2 * pad, listH)
            y = y + listH + Skin.S(4)
            x = pad
            for _, bt in row do
                if x + Skin.S(bt.w) > w - pad then x = pad y = y + Skin.S(26) end
                W.Place(bt, group, x, y, Skin.S(bt.w), Skin.S(22))
                x = x + Skin.S(bt.w) + Skin.S(4)
            end
            y = y + Skin.S(26)
            if P.mode == 'builders' then
                W.Place(P.bEdit, group, pad, y, Skin.S(54), Skin.S(22))
                y = y + Skin.S(26)
                P.rows:SetRect(-20000, -20000, 10, 10)
            else
                W.Place(P.bAssign, group, pad, y, Skin.S(116), Skin.S(22))
                if P.mode == 'platoons' then
                    local lx, fx, py = pad + Skin.S(124), planFx, y
                    if planOwnRow then
                        y = y + Skin.S(28)
                        lx, fx, py = pad, pad + P.planLabel.Width() + Skin.S(6), y
                    end
                    W.Place(P.planLabel, group, lx, py + Skin.S(4))
                    local pw = math.max(Skin.S(60), w - pad - fx)
                    W.Place(P.plan.frame, group, fx, py, pw, Skin.S(22))
                    P.plan.Width:Set(pw - 2)
                end
                y = y + Skin.S(28)
                P.rows:SetRect(pad, y, w - 2 * pad, rowsH)
                y = y + rowsH + Skin.S(4)
                if P.mode == 'platoons' then
                    y = W.Flow(group, rowsAfter[1], pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
                    W.Place(P.unitBtn, group, pad, y, w - 2 * pad, Skin.S(22))
                    y = y + Skin.S(26)
                    y = W.Flow(group, rowsAfter[2], pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
                    local half = math.floor((w - 3 * pad) / 2)
                    P.minS:Place(pad, y, half)
                    P.maxS:Place(pad * 2 + half, y, half)
                else
                    y = W.Flow(group, rowsAfter[1], pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
                    W.Place(P.typeBtn, group, pad, y, Skin.S(80), Skin.S(22))
                    local bw = math.max(Skin.S(50), math.floor((w - 2 * pad - Skin.S(92)) / 2))
                    W.Place(P.markerBtn, group, pad + Skin.S(84), y, bw, Skin.S(22))
                    W.Place(P.chainBtn, group, pad + Skin.S(88) + bw, y, bw, Skin.S(22))
                end
            end
            W.Place(P.used, group, pad, h - pad - 2 * lh - Skin.S(2))
            W.Place(P.status, group, pad, h - pad - lh)
            P:Refresh(true)
        end
        return P
    end,
}

--- Ticked by the shell: follows undo / redo and edits of other panels.
function Refresh()
    local P = live.platoons
    if P and P.rev ~= PL.Revision then M.Safe('Platoons panel refresh', P.Refresh, P) end
end
