-- The Stages panel (mission maps): the stages of the mission and the nodes of the selected stage (mission.lua). A stage runs its enter nodes, then its ready nodes; the
-- objectives of a stage must all be done before the next stage starts (or its failsafe timer runs out). Trigger nodes (timer, group destroyed, unit killed, units in an area,
-- objective decided) and the difficulty / cutscene nodes hold child nodes, shown indented below them: select a container and use "Add inside". Click a node to select it,
-- Edit... changes its parameters.
-- The mission is compiled into the map script when the map is saved (the region between the `EDITOR MISSION` marker lines).
-- A hand-written mission script is shown as imported stages (missionimport.lua): the rows of such a stage are an outline of the script (functions, objectives, triggers, AI helpers with line numbers),
-- the node buttons are dimmed and say why, and nothing of it is compiled or rewritten.
--
-- The Bases panel lists the BaseManager tables of the mission (mbase.lua): define a base from an area, edit its groups, engineers and attacks.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local M = import('/lua/editor/mission.lua')
local B = import('/lua/editor/mbase.lua')
local I = import('/lua/editor/missionimport.lua')

live = {}

-- a stage imported from the map's hand-written script: shown as an outline, never edited or compiled (missionimport.lua)
local function ImportedStage(index)
    local s = M.Data.stages[index]
    return s and s.imported and s or nil
end

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Dialogs() return import('/lua/editor/gui/dialogs_mission.lua') end

local function Row(row, label, extra, selected, color)
    local c = Skin.color
    W.Fit(row.text, label, math.max(Skin.S(30), row.bg.Width() - Skin.S(90)))
    row.text:SetColor(selected and c.accent or (color or c.text))
    row.extra:SetText(extra or '')
    row.extra:SetColor(c.textDim)
    local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
    row.text.Top:Set(function() return row.bg.Top() + ty end)
    local w2 = row.extra.Width()
    row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
    row.extra.Top:Set(function() return row.bg.Top() + ty end)
end

Panels.Register{
    id = 'stages', title = 'Stages',
    create = function(group, host)
        local P = { stage = 1, node = 1, addTo = 'ready', rev = -1 }
        live.stages = P

        local function Nodes() return M.Flatten(P.stage) end

        --- Selects the node at `path` of the current stage (after an add / indent / outdent).
        local function Select(section, path)
            local key = M.PathKey(path)
            for i, r in Nodes() do
                if r.section == section and M.PathKey(r.path) == key then P.node = i end
            end
        end

        P.stageList = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(M.Data.stages) end,
            bind = function(row, index)
                local s = M.Data.stages[index]
                local n = table.getn(s.enter or {}) + table.getn(s.ready or {})
                Row(row, index .. '  ' .. tostring(s.name), s.imported and 'imported' or (n .. ' nodes'), index == P.stage, s.imported and Skin.color.textDim or nil)
            end,
            onSelect = function(index) P.stage = index P.node = 1 P:Refresh() end,
            bgColor = Skin.color.panel,
        })
        P.nodeList = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function()
                if ImportedStage(P.stage) then return table.getn(P.impRows or {}) end
                return table.getn(Nodes())
            end,
            bind = function(row, index)
                if ImportedStage(P.stage) then
                    -- the outline of the script: functions, objectives, triggers, AI helpers (read-only rows)
                    local ir = (P.impRows or {})[index]
                    if not ir then return end
                    local c = Skin.color
                    local color = (ir.kind == 'objective' and c.ok) or (ir.kind == 'trigger' and (c.warn or c.accent)) or ((ir.kind == 'note' or ir.kind == 'detail') and c.textDim) or nil
                    Row(row, ir.text, ir.extra, index == P.node, color)
                    return
                end
                local r = Nodes()[index]
                if not r then return end
                local t = M.NodeType(r.node.type)
                local indent = string.rep('    ', r.depth) .. (r.depth > 0 and '- ' or '')
                local color = nil
                if t and t.family == 'objective' then color = Skin.color.ok elseif t and t.family == 'trigger' then color = Skin.color.warn or Skin.color.accent end
                Row(row, indent .. Dialogs().NodeSummary(r.node), r.section == 'enter' and 'enter' or 'ready', index == P.node, color)
            end,
            onSelect = function(index) P.node = index P:Refresh() end,
            bgColor = Skin.color.panel,
        })

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end

        -- buttons that cannot work on a stage imported from the script: dimmed, the tooltip and the click say why
        P.lockable = {}
        local function Lockable(b)
            local base = b.TipText
            b.TipText = function(self)
                local t = base(self)
                if ImportedStage(P.stage) then t = (t and (t .. '  ') or '') .. 'Not available here: ' .. I.WHY end
                return t
            end
            table.insert(P.lockable, b)
            return b
        end
        --- True (and says why) when the selected stage is imported.
        local function Locked()
            if ImportedStage(P.stage) then Say('mission: ' .. I.WHY) return true end
            return false
        end

        P.sAdd = Btn('Add stage', 70, function() M.AddStage() P.stage = table.getn(M.Data.stages) P.node = 1 P:Refresh() end)
        P.sDel = Lockable(Btn('Remove', 60, function()
            if Locked() then return end
            if M.RemoveStage(P.stage) then P.stage = math.max(1, P.stage - 1) end
            P.node = 1
            P:Refresh()
        end))
        P.sUp = Lockable(Btn('Up', 34, function()
            if Locked() then return end
            local ok, why = M.MoveStage(P.stage, -1)
            if ok then P.stage = P.stage - 1 elseif why and why ~= 'out of range' then Say('mission: ' .. why) end
            P:Refresh()
        end))
        P.sDown = Lockable(Btn('Down', 44, function()
            if Locked() then return end
            local ok, why = M.MoveStage(P.stage, 1)
            if ok then P.stage = P.stage + 1 elseif why and why ~= 'out of range' then Say('mission: ' .. why) end
            P:Refresh()
        end))
        P.sPlay = Lockable(Btn('Play here', 70, function()
            if Locked() then return end
            if M.Data.stages[P.stage] then UI.PlayFromStage(P.stage) end
        end))
        P.name = W.TextField(group, 0, 0, Skin.S(200), Skin.S(22), { onChange = function(text)
            if P.settingName then return end
            if Locked() then return end
            if M.Data.stages[P.stage] then M.SetStage(P.stage, 'name', text, true) P.stageList:Refresh() end
        end })
        P.mode = Btn('Mode: campaign', 120, function(self)
            local at = 1
            for i, m in M.MODES do if m == M.Data.mode then at = i end end
            M.SetMode(M.MODES[math.mod(at, table.getn(M.MODES)) + 1])
            self:SetText('Mode: ' .. M.Data.mode)
        end)
        P.failsafe = W.Slider(group, { label = 'Failsafe: start the next stage after this many seconds (0 = off)', min = 0, max = 1800, step = 10, fmt = '%d', compact = true,
            get = function() local s = M.Data.stages[P.stage] return s and tonumber(s.failsafe) or 0 end,
            set = function(v)
                if Locked() then return end
                if M.Data.stages[P.stage] then M.SetStage(P.stage, 'failsafe', v, true) end
            end })

        P.nAdd = Lockable(Btn('Add node', 64, function()
            if not M.Data.stages[P.stage] then Say('mission: add a stage first') return end
            if Locked() then return end
            Dialogs().AddNode(P.stage, P.addTo, function(path) Select(P.addTo, path) P:Refresh() end)
        end))
        P.nWhere = Btn('to: ready', 70, function(self)
            P.addTo = (P.addTo == 'ready') and 'enter' or 'ready'
            self:SetText('to: ' .. P.addTo)
        end)
        P.nInside = Lockable(Btn('Add inside', 74, function()
            if Locked() then return end
            local r = Nodes()[P.node]
            local t = r and M.NodeType(r.node.type)
            if not t or not t.container then Say('mission: select a trigger (or an if / cutscene node) first') return end
            Dialogs().AddNode(P.stage, r.section, function(path) Select(r.section, path) P:Refresh() end, r.path)
        end))
        P.nEdit = Lockable(Btn('Edit...', 52, function()
            if Locked() then return end
            local r = Nodes()[P.node]
            if r then Dialogs().EditNode(P.stage, r.section, r.path, function() P:Refresh() end) end
        end))
        P.nDel = Lockable(Btn('Remove', 60, function()
            if Locked() then return end
            local r = Nodes()[P.node]
            if r then M.RemoveNode(P.stage, r.section, r.path) P.node = math.max(1, P.node - 1) P:Refresh() end
        end))
        P.nUp = Lockable(Btn('Up', 34, function()
            local r = Nodes()[P.node]
            if r and M.MoveNode(P.stage, r.section, r.path, -1) then
                local p = {}
                for _, v in r.path do table.insert(p, v) end
                p[table.getn(p)] = p[table.getn(p)] - 1
                Select(r.section, p)
            end
            P:Refresh()
        end))
        P.nDown = Lockable(Btn('Down', 44, function()
            local r = Nodes()[P.node]
            if r and M.MoveNode(P.stage, r.section, r.path, 1) then
                local p = {}
                for _, v in r.path do table.insert(p, v) end
                p[table.getn(p)] = p[table.getn(p)] + 1
                Select(r.section, p)
            end
            P:Refresh()
        end))
        P.nIn = Lockable(Btn('In', 30, function()
            local r = Nodes()[P.node]
            if not r then return end
            local ok, path = M.IndentNode(P.stage, r.section, r.path)
            if ok then Select(r.section, path) else Say('mission: ' .. tostring(path or 'the node above holds no children')) end
            P:Refresh()
        end))
        P.nOut = Lockable(Btn('Out', 34, function()
            local r = Nodes()[P.node]
            if not r then return end
            local ok, path = M.OutdentNode(P.stage, r.section, r.path)
            if ok then Select(r.section, path) else Say('mission: ' .. tostring(path or 'not inside a container')) end
            P:Refresh()
        end))
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.rev = M.Revision
            local n = table.getn(M.Data.stages)
            if P.stage > n then P.stage = n end
            if P.stage < 1 then P.stage = 1 end
            local s = M.Data.stages[P.stage]
            P.impRows = (s and s.imported) and I.Rows(s.info) or {}
            local count = (s and s.imported) and table.getn(P.impRows) or table.getn(Nodes())
            if P.node > count then P.node = count end
            if P.node < 1 then P.node = 1 end
            P.stageList:Refresh()
            P.nodeList:Refresh()
            for _, b in P.lockable do
                b.label:SetColor((s and s.imported) and Skin.color.textDim or Skin.color.text)
            end
            P.settingName = true
            P.name:SetText(s and tostring(s.name) or '')
            P.settingName = false
            P.mode:SetText('Mode: ' .. tostring(M.Data.mode))
            P.failsafe:Refresh()
            local problems = M.Check()
            local e, w = 0, 0
            for _, p in problems do if p.sev == 'E' then e = e + 1 elseif p.sev == 'W' then w = w + 1 end end
            local first = problems[1]
            local text = string.format('%d stages, %d errors, %d warnings%s', n, e, w, first and (': ' .. first.text) or '')
            if s and s.imported and s.info then
                text = string.format('imported, read-only: %d functions, %d objectives, %d triggers  -  %s', table.getn(s.info.functions or {}), table.getn(s.info.objectives or {}),
                    table.getn(s.info.triggers or {}), I.WHY)
            end
            W.Fit(P.status, text, (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local r1 = W.Flow(group, { { P.sAdd, Skin.S(70) }, { P.sDel, Skin.S(60) }, { P.sUp, Skin.S(34) }, { P.sDown, Skin.S(44) }, { P.sPlay, Skin.S(70) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            local listH = Skin.S(22) * 3 + Skin.S(4)
            P.stageList:SetRect(pad, r1 + Skin.S(4), w - 2 * pad, listH)
            local y = r1 + Skin.S(4) + listH + Skin.S(6)
            -- name field and mode button share the row; in a narrow panel the field gives way (the mode button keeps its width)
            local modeW = Skin.S(120)
            local nameW = math.max(Skin.S(60), math.min(Skin.S(200), w - 2 * pad - modeW - Skin.S(8)))
            W.Place(P.name.frame, group, pad, y, nameW, Skin.S(22))
            P.name.Width:Set(nameW - 2)
            W.Place(P.mode, group, pad + nameW + Skin.S(8), y, modeW, Skin.S(22))
            y = y + Skin.S(26)
            P.failsafe:Place(pad, y, w - 2 * pad)
            y = y + Skin.S(50)
            local r2 = W.Flow(group, { { P.nAdd, Skin.S(64) }, { P.nWhere, Skin.S(70) }, { P.nInside, Skin.S(74) }, { P.nEdit, Skin.S(52) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
            y = r2 + Skin.S(4)
            local r3 = W.Flow(group, { { P.nDel, Skin.S(60) }, { P.nUp, Skin.S(34) }, { P.nDown, Skin.S(44) }, { P.nIn, Skin.S(30) }, { P.nOut, Skin.S(34) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
            local top = r3 + Skin.S(4)
            P.nodeList:SetRect(pad, top, w - 2 * pad, math.max(Skin.S(44), h - top - pad - Skin.S(20)))
            W.Place(P.status, group, pad, h - pad - Skin.S(14))
            P:Refresh()
        end
        return P
    end,
}

Panels.Register{
    id = 'bases', title = 'Bases',
    stack = { workspace = 'Mission', with = 'armies' },
    create = function(group, host)
        local P = { sel = 1, rev = -1 }
        live.bases = P

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(B.Bases() or {}) end,
            bind = function(row, index)
                local b = B.Bases()[index]
                if not b then return end
                Row(row, tostring(b.name) .. '  (' .. tostring(b.army) .. ')', table.getn(b.groups or {}) .. ' groups, ' .. table.getn(b.opai or {}) .. ' attacks', index == P.sel)
            end,
            onSelect = function(index) P.sel = index P:Refresh() end,
            bgColor = Skin.color.panel,
        })
        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end
        P.define = Btn('Define from area...', 130, function() Dialogs().DefineBase(function() P.sel = table.getn(B.Bases()) P:Refresh() end) end)
        P.new = Btn('New empty...', 90, function() Dialogs().NewBase(function() P.sel = table.getn(B.Bases()) P:Refresh() end) end)
        P.edit = Btn('Edit...', 52, function()
            if B.Bases()[P.sel] then Dialogs().BaseEdit(P.sel, function() P:Refresh() end) end
        end)
        P.del = Btn('Remove', 60, function()
            if B.Bases()[P.sel] and B.RemoveBase(P.sel) then P.sel = math.max(1, P.sel - 1) end
            P:Refresh()
        end)
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.rev = M.Revision
            local n = table.getn(B.Bases() or {})
            if P.sel > n then P.sel = n end
            if P.sel < 1 then P.sel = 1 end
            P.list:Refresh()
            local b = B.Bases()[P.sel]
            W.Fit(P.status, b and string.format('%s: marker %s, radius %d, engineers %s', tostring(b.name), tostring(b.marker), tonumber(b.radius) or 0,
                table.concat({ tostring(b.engineers and b.engineers[1]), tostring(b.engineers and b.engineers[2]), tostring(b.engineers and b.engineers[3]) }, '/'))
                or 'drag an area around a base, then Define from area; a "Start a base" node in a stage starts it', (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local r4 = W.Flow(group, { { P.define, Skin.S(130) }, { P.new, Skin.S(90) }, { P.edit, Skin.S(52) }, { P.del, Skin.S(60) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            local top = r4 + Skin.S(4)
            P.list:SetRect(pad, top, w - 2 * pad, math.max(Skin.S(44), h - top - pad - Skin.S(20)))
            W.Place(P.status, group, pad, h - pad - Skin.S(14))
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: redraws when the mission changed (undo, redo, another panel).
function Refresh()
    for _, P in { live.stages, live.bases } do
        if P and P.rev ~= M.Revision then pcall(P.Refresh, P) end
    end
end
