-- The Console panel: everything the editor prints (LOG, WARN, SPEW, print), the status line messages and the results of the command line, newest at the bottom.
-- The data and all the logic (ring, filter, commands) are in consolelog.lua; this file is only the view.
--
--   - one row per entry, coloured by level (errors red, warnings yellow, status messages in the accent colour, the rest normal), always ONE line cut to the width (a tooltip has the
--     full text); the entry you select is shown in full, wrapped, in the box under the list
--   - toolbar: Errors / Warnings / Status / Info switch a level on or off, a filter field (case-insensitive part of the text), Clear, Copy (the shown lines) and Scroll lock
--   - command line at the bottom: Enter runs the text as Lua in the UI state ("= expr" or a bare expression prints its value); "sim <code>" runs it in the sim (the SimLua console
--     command); Up and Down walk through the last 50 commands
--
-- The shell ticks Refresh() about four times a second: the panel redraws only when consolelog.lua's version changed, so a flood of LOG lines costs one redraw per tick.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Console = import('/lua/editor/consolelog.lua')

live = {}

-- what the user chose survives closing and reopening the panel (the controls are recreated, this is not)
local view = { levels = { error = true, warn = true, status = true, info = true }, text = '', lock = false }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function LevelColor(level)
    local c = Skin.color
    if level == 'error' then return c.error end
    if level == 'warn' then return c.warn end
    if level == 'status' then return c.accent end
    return c.text
end

--- Puts the shown lines on the clipboard; an engine without CopyToClipboard gets them in console.txt in the user folder instead.
local function Copy(rows)
    local n = table.getn(rows)
    if n == 0 then
        Say('nothing to copy: no console lines are shown')
        return
    end
    local text = Console.Lines(rows)
    local clip = rawget(_G, 'CopyToClipboard')
    if clip then
        local ok, res = pcall(clip, text)
        if ok and res ~= false then
            Say('copied ' .. n .. ' console lines to the clipboard')
            return
        end
    end
    local file = import('/lua/editor/userdata.lua').Path('console.txt')
    ed_write_file(file, text)
    Say('this build has no clipboard: ' .. n .. ' console lines saved as ' .. file)
end

local TIP_FILTER = 'Type part of a message to show only the lines that contain it. Capitals do not matter.'
local TIP_COMMAND = 'Type Lua and press Enter to run it in the UI state, like the UI_Lua console command. A bare expression or = expression prints its value (for example = table.getn(x)). '
    .. 'Start with sim to run it in the sim instead (the SimLua console command; what it prints goes to the game log). Up and Down bring back earlier commands.'

Panels.Register{
    id = 'console', title = 'Console',
    create = function(group, host)
        local c = Skin.color
        local P = { rows = {}, version = -1, follow = true, selSeq = false, detail = {}, buttons = {} }
        live.console = P

        P.list = W.VirtualList(group, {
            rowH = 18,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local e = P.rows[index]
                if not e then return end
                -- always one line, cut to the width (nothing at all when not even "..." fits: a text wider than its row would be drawn over the next panel); the same label is reused for every bind
                W.FitCached(row.text, Console.RowText(e), math.max(0, row.bg.Width() - Skin.S(12)))
                row.text:SetColor(LevelColor(e.level))
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                if row.ty ~= ty then
                    row.ty = ty
                    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                    row.text.Top:Set(function() return row.bg.Top() + ty end)
                end
            end,
            rowTip = function(index)
                local e = P.rows[index]
                if not e then return nil end
                local text = Console.Line(e)
                if string.len(text) > 700 then text = string.sub(text, 1, 700) .. '...' end
                return text
            end,
            onSelect = function(index)
                local e = P.rows[index]
                P.selSeq = e and e.seq or false
                P:ShowDetail()
            end,
            onScroll = function()
                -- the list follows new lines only while it sits at the bottom
                local L = P.list
                local vis = math.max(1, math.floor(L.h / L.rowH))
                P.follow = L.offset >= table.getn(P.rows) - vis
            end,
        })

        P.detailBg = Bitmap(group)
        P.detailBg:SetSolidColor(c.panelAlt)
        P.detailBg.Depth:Set(function() return group.Depth() + 5 end)

        local function Toggle(level, text)
            local b = W.Button(group, text, 0, 0, Skin.S(60), Skin.S(22), function(self)
                view.levels[level] = self.on and true or false
                P:Refresh(true)
            end, { toggle = true })
            b:SetOn(view.levels[level])
            P.buttons[level] = b
            return b
        end
        Toggle('error', 'Errors')
        Toggle('warn', 'Warnings')
        Toggle('status', 'Status')
        Toggle('info', 'Info')
        P.filter = W.TextField(group, 0, 0, Skin.S(150), Skin.S(22), {
            text = view.text, tip = TIP_FILTER,
            onChange = function(text)
                view.text = text
                P:Refresh(true)
            end,
        })
        P.clear = W.Button(group, 'Clear', 0, 0, Skin.S(54), Skin.S(22), function()
            Console.Clear()
            P.selSeq = false
            P:Refresh(true)
        end)
        P.copy = W.Button(group, 'Copy', 0, 0, Skin.S(54), Skin.S(22), function() Copy(P.rows) end)
        P.lock = W.Button(group, 'Scroll lock', 0, 0, Skin.S(88), Skin.S(22), function(self)
            view.lock = self.on and true or false
            if not view.lock then
                P.follow = true
                P:Refresh(true)
            end
        end, { toggle = true })
        P.lock:SetOn(view.lock)

        P.command = W.TextField(group, 0, 0, Skin.S(200), Skin.S(22), {
            tip = TIP_COMMAND,
            onEnter = function(text)
                P.command:SetText('')
                if string.find(text, '%S') then
                    Console.Execute(text)
                    if not view.lock then P.follow = true end
                    P:Refresh(true)
                end
            end,
        })
        P.command:SetMaxChars(2000)
        local base = P.command.OnNonTextKeyPressed
        P.command.OnNonTextKeyPressed = function(self, keycode, event)
            if keycode == 38 or keycode == 40 then
                local text = Console.HistoryStep(keycode == 38 and -1 or 1, self:GetText())
                if text then self:SetText(text) end
                return
            end
            if base then base(self, keycode, event) end
        end

        --- The selected entry in full, wrapped, in the box under the list (the rows are cut to the width).
        function P:ShowDetail()
            if not P.dw then return end
            local e
            if P.selSeq then
                for i = table.getn(P.rows), 1, -1 do
                    if P.rows[i].seq == P.selSeq then e = P.rows[i] break end
                end
            end
            local text, color
            if e then
                text, color = Console.Line(e), LevelColor(e.level)
            else
                text, color = table.getn(P.rows) .. ' of ' .. Console.Count() .. ' lines shown. Select a line to read it in full. Type Lua below and press Enter to run it (start with sim to run it in the sim).', c.textDim
            end
            local key = text .. '|' .. P.dw .. '|' .. P.dh
            if P.detailKey == key then return end
            P.detailKey = key
            for _, l in P.detail do l:Destroy() end
            P.detail = {}
            if P.dh <= 0 then return end
            local lineH = Skin.S(15)
            local maxChars = math.max(8, math.floor((P.dw - Skin.S(14)) / Skin.S(7)))
            P.detail = W.Paragraph(group, Console.BreakWords(text, maxChars), P.dx + Skin.S(6), P.dy + Skin.S(3), P.dw - Skin.S(12), { color = color, size = 'small' }, lineH, P.dy + P.dh)
        end

        --- Rebuilds the shown rows when the messages or the filter changed (`force`: always) and draws them.
        function P:Refresh(force)
            if not P.w then return end
            local v = Console.Version()
            if not force and v == P.version then return end
            P.version = v
            P.rows = Console.Filter(view.levels, view.text)
            local n = table.getn(P.rows)
            local sel = nil
            if P.selSeq then
                for i = n, 1, -1 do
                    if P.rows[i].seq == P.selSeq then sel = i break end
                end
            end
            P.list.selected = sel
            if P.follow and not view.lock then
                P.list:ScrollTo(n)
            else
                P.list:Refresh()
            end
            P:ShowDetail()
        end

        function P:OnResize(w, h)
            local pad, gap, rh = Skin.S(6), Skin.S(4), Skin.S(22)
            local inner = w - 2 * pad
            local items = {
                { P.buttons.error, Skin.S(60) }, { P.buttons.warn, Skin.S(78) }, { P.buttons.status, Skin.S(60) }, { P.buttons.info, Skin.S(50) },
                { P.filter.frame, Skin.S(150) }, { P.clear, Skin.S(54) }, { P.copy, Skin.S(54) }, { P.lock, Skin.S(88) },
            }
            local top = W.Flow(group, items, pad, pad, inner, rh, gap)
            local fw = math.min(Skin.S(150), inner)
            P.filter.Width:Set(fw - 2)
            P.filter.Height:Set(rh - 2)

            -- the command line sits at the bottom; in a panel too short for the toolbar rows, a list and the line, it goes under a list of the least height instead (the panel scrolls)
            local cy = math.max(h - pad - rh, top + gap + Skin.S(60) + gap)
            W.Place(P.command.frame, group, pad, cy, inner, rh)
            P.command.Width:Set(inner - 2)
            P.command.Height:Set(rh - 2)

            -- the box for the selected entry: up to six lines, none when the panel is too small for a list as well
            local lineH = Skin.S(15)
            local lines = math.max(2, math.min(6, math.floor(h * 0.3 / lineH)))
            local dh = lines * lineH + Skin.S(6)
            local listY = top + gap
            local listH = cy - gap - dh - gap - listY
            if listH < Skin.S(60) then
                dh = 0
                listH = cy - gap - listY
            end
            P.dx, P.dw, P.dh, P.dy = pad, inner, dh, cy - gap - dh
            if dh > 0 then
                W.Place(P.detailBg, group, P.dx, P.dy, P.dw, dh)
                P.detailBg:Show()
            else
                P.detailBg:Hide()
            end
            P.list:SetRect(pad, listY, inner, math.max(Skin.S(20), listH))
            P.w = w
            P.detailKey = false
            P:Refresh(true)
        end

        function P:Destroy()
            live.console = nil
        end
        return P
    end,
}

--- Ticked by the shell (about four times a second): draws new messages.
function Refresh()
    local P = live.console
    if P and P.w then pcall(P.Refresh, P) end
end
