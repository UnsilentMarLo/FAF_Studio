-- Mission run panels (mission maps): "Run" shows a play test of the mission (stage, objectives, flags, groups, the warnings the script raised) and lets you jump to a stage,
-- set flags, skip waiting timers and speed them up (missionrun.lua + the callbacks of lua/editorsim/mission.lua); "Strings" edits the dialogue tables of the mission
-- (text, speaker, duration per line) that the Play a dialogue node and the objective reminders use.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local M = import('/lua/editor/mission.lua')
local R = import('/lua/editor/missionrun.lua')

live = {}

-- why Jump / Skip / Timers do nothing for a mission imported from a hand-written script (missionimport.lua)
local JUMP_WHY = 'this stage is imported from the hand-written script: it has no editor nodes and the script starts its own stages. Select a stage made in the editor to jump to it.'
local TIMER_WHY = 'the imported script runs its own waits and timers; only the waits of stages made in the editor can be skipped or sped up.'

--- Is the stage selected in the Stages panel an imported one?
local function SelectedImported()
    local stages = live.stages
    local s = M.Data.stages[stages and stages.stage or 1]
    return s and s.imported or false
end

--- Does the mission consist only of imported stages (nothing the run panel can steer)?
local function OnlyImported()
    return M.IsImported() and M.EditorStageCount() == 0
end

--- Adds a 'why' to the tooltip of a button while `blocked()` is true.
local function WhyTip(b, blocked, why)
    local base = b.TipText
    b.TipText = function(self)
        local t = base(self)
        if blocked() then t = (t and (t .. '  ') or '') .. 'Not available: ' .. why end
        return t
    end
    return b
end

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

local SCALES = { 1, 4, 16 }

Panels.Register{
    id = 'run', title = 'Run',
    stack = { workspace = 'Mission', with = 'armies' },
    create = function(group, host)
        local P = { view = 'state', rows = {}, sel = 1, scaleIndex = 1, lastMode = 'edit', ticks = 0 }
        live.run = P
        local c = Skin.color

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end

        --- The rows of the list for the current view.
        local function Build()
            local rows = {}
            local playing = UI.State.mode == 'play'
            if P.view == 'warnings' then
                local list, why = R.Warnings()
                if why then table.insert(rows, { text = why, color = c.textDim }) end
                if not why and table.getn(list) == 0 then table.insert(rows, { text = playing and 'no warnings since Play' or 'press Play to test the mission', color = c.textDim }) end
                for _, line in list do
                    table.insert(rows, { text = line, color = string.find(line, '^    ') and c.textDim or (c.warn or c.accent) })
                end
                return rows
            end
            if not playing then
                table.insert(rows, { text = 'not playing: press Play test in the tool list, then jump, set flags and skip timers here', color = c.textDim })
                return rows
            end
            local s = R.State
            local stage = M.StageByNumber(s.stage)
            table.insert(rows, { text = 'Stage ' .. s.stage .. (M.IsImported() and '' or (' of ' .. table.getn(M.Data.stages))) .. (stage and (': ' .. tostring(stage.name)) or ''), extra = 'tick ' .. s.tick, color = c.accent })
            if s.ended then
                table.insert(rows, { text = s.success and 'the operation ended: won' or 'the operation ended: lost', color = s.success and c.ok or (c.warn or c.accent) })
            end
            if M.IsImported() then
                table.insert(rows, { text = 'imported script: its objectives and groups are not listed here', color = c.textDim })
            end
            for _, o in s.objectives do
                table.insert(rows, { text = (o.active and '[open]  ' or '[done]  ') .. o.title, color = o.active and c.text or c.ok })
            end
            for _, name in s.flagOrder or {} do
                table.insert(rows, { text = 'flag ' .. name .. ' = ' .. (s.flags[name] and 'on' or 'off'), flag = name, extra = 'click to toggle' })
            end
            local names = {}
            for name, _ in s.vars do table.insert(names, name) end
            table.sort(names)
            for _, name in names do
                table.insert(rows, { text = 'group ' .. name .. ': ' .. tostring(s.vars[name]) .. ' alive', color = c.textDim })
            end
            return rows
        end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local r = P.rows[index]
                if not r then return end
                Row(row, r.text, r.extra, (index == P.sel and r.flag) and c.accent or r.color)
            end,
            onSelect = function(index)
                P.sel = index
                local r = P.rows[index]
                if r and r.flag then
                    R.SetFlag(r.flag, not R.State.flags[r.flag])
                    R.State.flags[r.flag] = not R.State.flags[r.flag]
                    P:Refresh()
                end
            end,
            bgColor = c.panel,
        })

        P.bState = Btn('State', 54, function() P.view = 'state' P:Refresh() end)
        P.bWarn = Btn('Warnings', 74, function() P.view = 'warnings' P:Refresh() end)
        P.bJump = WhyTip(Btn('Jump to stage', 96, function()
            if UI.State.mode ~= 'play' then Say('run: press Play test first') return end
            local stages = live.stages
            local n = stages and stages.stage or 1
            if not M.Data.stages[n] then Say('run: select a stage in the Stages panel') return end
            if M.Data.stages[n].imported then Say('run: ' .. JUMP_WHY) return end
            R.Jump(n)
            Say('run: jumped to stage ' .. n)
        end), SelectedImported, JUMP_WHY)
        P.bSkip = WhyTip(Btn('Skip waits', 76, function()
            if UI.State.mode ~= 'play' then Say('run: press Play test first') return end
            if OnlyImported() then Say('run: ' .. TIMER_WHY) return end
            R.Skip()
        end), OnlyImported, TIMER_WHY)
        P.bScale = WhyTip(Btn('Timers x1', 78, function(self)
            if OnlyImported() then Say('run: ' .. TIMER_WHY) return end
            P.scaleIndex = math.mod(P.scaleIndex, table.getn(SCALES)) + 1
            R.SetScale(SCALES[P.scaleIndex])
            self:SetText('Timers x' .. SCALES[P.scaleIndex])
        end), OnlyImported, TIMER_WHY)
        P.bFlag = Btn('New flag...', 80, function()
            if UI.State.mode ~= 'play' then Say('run: press Play test first') return end
            Dialogs().NameDialog('Flag', 'Flag name (e.g. ATTACK_NOW): set on', function(name)
                R.SetFlag(name, true)
                P:Refresh()
            end)
        end)
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            local mode = UI.State.mode
            if mode == 'play' and P.lastMode ~= 'play' then
                R.MarkLog()
                P.scaleIndex = 1
                P.bScale:SetText('Timers x1')
            end
            P.lastMode = mode
            if mode == 'play' then R.Poll() end
            P.rows = Build()
            if P.sel > table.getn(P.rows) then P.sel = table.getn(P.rows) end
            if P.sel < 1 then P.sel = 1 end
            P.list:Refresh()
            local s = R.State
            local text = mode == 'play' and string.format('playing, stage %d, timers x%s', s.stage, tostring(s.scale)) or 'editing'
            if OnlyImported() then text = text .. '  (imported script: jump, skip and timers are off)'
            elseif SelectedImported() then text = text .. '  (selected stage is imported: no jump)' end
            W.Fit(P.status, text, (P.w or 300) - Skin.S(16))
            for _, b in { P.bJump, P.bSkip, P.bScale } do
                b.label:SetColor(((b == P.bJump and SelectedImported()) or (b ~= P.bJump and OnlyImported())) and c.textDim or c.text)
            end
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local m1 = W.Flow(group, { { P.bState, Skin.S(54) }, { P.bWarn, Skin.S(74) }, { P.bJump, Skin.S(96) }, { P.bSkip, Skin.S(76) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            local m2 = W.Flow(group, { { P.bScale, Skin.S(78) }, { P.bFlag, Skin.S(80) } }, pad, m1 + Skin.S(4), w - 2 * pad, Skin.S(22), Skin.S(4))
            local top = m2 + Skin.S(4)
            local lh = math.max(Skin.S(14), P.status.Height())
            h = math.max(h, top + Skin.S(44) + pad + lh + Skin.S(6))          -- too little room: the panel scrolls (the dock's content group), the list never runs into the status line
            P.list:SetRect(pad, top, w - 2 * pad, h - top - pad - lh - Skin.S(6))
            W.Place(P.status, group, pad, h - pad - lh)
            P:Refresh()
        end
        return P
    end,
}

Panels.Register{
    id = 'strings', title = 'Strings',
    stack = { workspace = 'Mission', with = 'armies' },
    create = function(group, host)
        local P = { sel = 1, rev = -1 }
        live.strings = P
        local c = Skin.color

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(M.Data.dialogues or {}) end,
            bind = function(row, index)
                local d = M.Data.dialogues[index]
                if not d then return end
                Row(row, tostring(d.name), table.getn(d.lines or {}) .. (d.imported and ' lines (imported)' or ' lines'), index == P.sel and c.accent or (d.imported and c.textDim or nil))
            end,
            onSelect = function(index) P.sel = index P:Refresh() end,
            bgColor = c.panel,
        })
        P.add = Btn('Add dialogue...', 110, function()
            Dialogs().NameDialog('New dialogue', 'Name (letters, digits, _), e.g. INTRO', function(name)
                local ok, why = M.AddDialogue(name)
                if not ok then Say('strings: ' .. tostring(why)) return end
                P.sel = table.getn(M.Data.dialogues)
                P:Refresh()
            end)
        end)
        P.edit = Btn('Lines...', 60, function()
            if M.Data.dialogues[P.sel] then Dialogs().DialogueLines(P.sel, function() P:Refresh() end) end
        end)
        P.del = Btn('Remove', 60, function()
            if M.Data.dialogues[P.sel] then
                local ok, why = M.RemoveDialogue(P.sel)
                if ok then P.sel = math.max(1, P.sel - 1) elseif why then Say('strings: ' .. why) end
            end
            P:Refresh()
        end)
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            P.rev = M.Revision
            local n = table.getn(M.Data.dialogues or {})
            if P.sel > n then P.sel = n end
            if P.sel < 1 then P.sel = 1 end
            P.list:Refresh()
            W.Fit(P.status, n == 0 and 'a dialogue is a list of lines (text, speaker, seconds); a Play a dialogue node or an objective reminder plays it' or (n .. ' dialogues'), (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local m3 = W.Flow(group, { { P.add, Skin.S(110) }, { P.edit, Skin.S(60) }, { P.del, Skin.S(60) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            local top = m3 + Skin.S(4)
            local lh = math.max(Skin.S(14), P.status.Height())
            h = math.max(h, top + Skin.S(44) + pad + lh + Skin.S(6))          -- too little room: the panel scrolls (the dock's content group), the list never runs into the status line
            P.list:SetRect(pad, top, w - 2 * pad, h - top - pad - lh - Skin.S(6))
            W.Place(P.status, group, pad, h - pad - lh)
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: the run panel polls the play test, the strings panel follows undo / redo.
function Refresh()
    local run = live.run
    if run then
        run.ticks = run.ticks + 1
        -- the sim is asked once a second while playing (a dump is a file write)
        if UI.State.mode == 'play' or run.lastMode == 'play' then
            if math.mod(run.ticks, 4) == 0 or run.lastMode ~= UI.State.mode then M.Safe('Run panel refresh', run.Refresh, run) end
        end
    end
    local st = live.strings
    if st and st.rev ~= M.Revision then M.Safe('Strings panel refresh', st.Refresh, st) end
end
