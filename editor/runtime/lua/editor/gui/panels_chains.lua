-- The Chains panel: the save file's chains (ordered marker lists that patrol and move orders of a mission use). Top list: the chains; bottom list: the markers of the chosen chain
-- in order. "From selection" makes a chain of the markers selected in the world (selection order), Add selected appends them, the buttons reorder / remove; Select puts the
-- chain's markers into the selection. The chain is drawn in the world (orange, the chosen one brighter). "Draw chain" picks the Draw chain tool: each click in the world places
-- a marker at the end of the chosen chain (a new chain when none is chosen); "Finish chain" lets the next click start a new one. See chains.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Tools = import('/lua/editor/tools.lua')
local Chains = import('/lua/editor/chains.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

local function Row(row, label, extra, color)
    local c = Skin.color
    W.Fit(row.text, label, math.max(Skin.S(30), row.bg.Width() - Skin.S(70)))
    row.text:SetColor(color or c.text)
    row.extra:SetText(extra or '')
    row.extra:SetColor(c.textDim)
    local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
    row.text.Top:Set(function() return row.bg.Top() + ty end)
    local w2 = row.extra.Width()
    row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
    row.extra.Top:Set(function() return row.bg.Top() + ty end)
end

local function Dialogs() return import('/lua/editor/gui/dialogs_mission.lua') end

Panels.Register{
    id = 'chains', title = 'Chains',
    stack = { { workspace = 'Objects', with = 'markers' }, { workspace = 'Mission', with = 'markers' } },
    create = function(group, host)
        local P = { names = {}, mi = 1, rev = -1, seenTools = -1 }
        live.chains = P
        local c = Skin.color

        local function Current() return Chains.Current end
        local function CurrentMarkers() return Current() and Chains.Markers(Current()) or {} end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(P.names) end,
            bind = function(row, index)
                local name = P.names[index]
                if not name then return end
                Row(row, name, table.getn(Chains.Markers(name) or {}) .. ' markers', name == Current() and c.accent or nil)
            end,
            onSelect = function(index)
                Chains.Current = P.names[index]
                P.mi = 1
                Chains.Revision = Chains.Revision + 1
                P:Refresh(true)
            end,
            bgColor = c.panel,
        })
        P.markers = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(CurrentMarkers()) end,
            bind = function(row, index)
                local m = CurrentMarkers()[index]
                if not m then return end
                Row(row, index .. '   ' .. m, '', index == P.mi and c.accent or nil)
            end,
            onSelect = function(index)
                P.mi = index
                local m = CurrentMarkers()[index]
                if m then Tools.Select('marker', m) end
                P:Refresh(true)
            end,
            bgColor = c.panel,
        })

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end
        P.bNew = Btn('From selection...', 112, function()
            Dialogs().NameDialog('New chain', 'Name, e.g. Patrol_North (letters, digits, _)', function(name)
                local ok, why = Chains.FromSelection(name)
                if not ok then Say('chains: ' .. tostring(why)) end
                P:Refresh(true)
            end)
        end)
        P.bEmpty = Btn('Empty...', 62, function()
            Dialogs().NameDialog('New chain', 'Name (letters, digits, _)', function(name)
                local ok, why = Chains.Create(name, {})
                if not ok then Say('chains: ' .. tostring(why)) end
                P:Refresh(true)
            end)
        end)
        P.bRename = Btn('Rename...', 70, function()
            if not Current() then return end
            local old = Current()
            Dialogs().NameDialog('Rename chain ' .. old, 'New name', function(name)
                local ok, why = Chains.Rename(old, name)
                if not ok then Say('chains: ' .. tostring(why)) elseif why and why > 0 then Say('chains: ' .. why .. ' mission reference(s) renamed') end
                P:Refresh(true)
            end)
        end)
        P.bDel = Btn('Delete', 54, function()
            if Current() then Chains.Delete(Current()) end
            P:Refresh(true)
        end)
        P.bAdd = Btn('Add selected', 90, function()
            if not Current() then Say('chains: choose or create a chain first') return end
            local n = 0
            for _, it in Tools.Items do
                if it.kind == 'marker' then
                    if Chains.AddMarker(Current(), it.name) then n = n + 1 end
                end
            end
            if n == 0 then Say('chains: select markers in the world first') end
            P:Refresh(true)
        end)
        P.bRemove = Btn('Remove', 60, function()
            if Current() and Chains.RemoveMarker(Current(), P.mi) then P.mi = math.max(1, P.mi - 1) end
            P:Refresh(true)
        end)
        P.bUp = Btn('Up', 34, function() if Current() and Chains.MoveMarker(Current(), P.mi, -1) then P.mi = P.mi - 1 end P:Refresh(true) end)
        P.bDown = Btn('Down', 44, function() if Current() and Chains.MoveMarker(Current(), P.mi, 1) then P.mi = P.mi + 1 end P:Refresh(true) end)
        P.bSelect = Btn('Select markers', 100, function() if Current() then Chains.SelectMarkers(Current()) end end)
        P.bDraw = Btn('Draw chain', 80, function() UI.SelectTool('chain') P:Refresh(true) end)
        P.bFinish = Btn('Finish chain', 86, function() Chains.Finish() P:Refresh(true) end)
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        local function SetStatus(text)
            if P.w then W.Fit(P.status, text, math.max(Skin.S(40), P.w - Skin.S(16))) else P.status:SetText(text) end       -- (text does not clip)
        end

        function P:Refresh(force)
            if not force and P.rev == Chains.Revision and P.seenTools == Tools.Changed and P.seenTool == UI.State.tool then return end
            P.rev, P.seenTools, P.seenTool = Chains.Revision, Tools.Changed, UI.State.tool
            P.names = Chains.Names()
            if Current() and not Chains.Markers(Current()) then Chains.Current = false end
            local n = table.getn(CurrentMarkers())
            if P.mi > n then P.mi = n end
            if P.mi < 1 then P.mi = 1 end
            P.list:Refresh()
            P.markers:Refresh()
            local bad = table.getn(Chains.Problems())
            if UI.State.tool == 'chain' then
                -- the hint of the Draw chain tool
                SetStatus(Current() and ('drawing ' .. Current() .. ': click adds, Ctrl+click = new chain') or 'Draw chain: click to place the first marker')
            elseif Current() then
                SetStatus(string.format('%s: %d markers, %.0f long%s', Current(), n, Chains.Length(Current()), bad > 0 and ('   (' .. bad .. ' problems in all chains)') or ''))
            else
                SetStatus(table.getn(P.names) == 0 and 'select markers in the world, then From selection' or (table.getn(P.names) .. ' chains'))
            end
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local top = W.Flow(group, { { P.bNew, Skin.S(112) }, { P.bEmpty, Skin.S(62) }, { P.bRename, Skin.S(70) }, { P.bDel, Skin.S(54) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            local listH = math.max(Skin.S(44), math.floor((h - Skin.S(110) - (top - pad - Skin.S(22))) * 0.4))
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            local y = top + listH + Skin.S(6)
            y = W.Flow(group, { { P.bAdd, Skin.S(90) }, { P.bRemove, Skin.S(60) }, { P.bUp, Skin.S(34) }, { P.bDown, Skin.S(44) }, { P.bSelect, Skin.S(100) },
                                { P.bDraw, Skin.S(80) }, { P.bFinish, Skin.S(86) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
            y = y + Skin.S(4)
            P.markers:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(44), h - y - pad - Skin.S(20)))
            W.Place(P.status, group, pad, h - pad - Skin.S(14))
            P:Refresh(true)
        end
        return P
    end,
}

--- Ticked by the shell: follows undo / redo and selection changes.
function Refresh()
    local P = live.chains
    if P then pcall(P.Refresh, P) end
end
