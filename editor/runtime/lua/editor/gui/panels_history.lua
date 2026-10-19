-- The History panel: the undo stack as a list (newest on top), the applied entries normal, the undone ones dim; a click on a row goes back or forward to that state
-- (history.lua JumpTo: a number of undos or redos, each one the same code the Undo / Redo commands run). "(start)" at the bottom is the state before the first entry.
-- The stack holds the last 200 entries of terrain strokes and object edits.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local History = import('/lua/editor/history.lua')

live = {}

Panels.Register{
    id = 'history', title = 'History',
    stack = { { workspace = 'Objects', with = 'validation' }, { workspace = 'Terrain', with = 'view' }, { workspace = 'Mission', with = 'validation' }, { workspace = 'Environment', with = 'console' } },
    create = function(group, host)
        local P = { rows = {}, version = -1 }
        live.history = P
        local c = Skin.color

        function P:Rebuild()
            local entries, pos = History.Entries()
            local rows = {}
            for i = table.getn(entries), 1, -1 do
                table.insert(rows, { index = i, text = entries[i].label, applied = i <= pos })
            end
            table.insert(rows, { index = 0, text = '(start)', applied = pos >= 0 })
            P.rows, P.pos = rows, pos
        end

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local r = P.rows[index]
                if not r then return end
                W.Fit(row.text, r.text, math.max(Skin.S(30), row.bg.Width() - Skin.S(60)))
                local current = r.index == P.pos
                row.text:SetColor(current and c.accent or (r.applied and c.text or c.textDim))
                row.extra:SetText(r.index > 0 and tostring(r.index) or '')
                row.extra:SetColor(c.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local r = P.rows[index]
                if r then
                    History.JumpTo(r.index)
                    P:Refresh(true)
                end
            end,
            bgColor = c.panel,
        })
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh(force)
            if not force and P.version == History.Version then return end
            P.version = History.Version
            P:Rebuild()
            P.list:Refresh()
            local pos, redo = History.Depth()
            P.status:SetText(pos .. ' to undo, ' .. redo .. ' to redo')
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            P.list:SetRect(pad, pad, w - 2 * pad, math.max(Skin.S(44), h - 2 * pad - Skin.S(20)))
            W.Place(P.status, group, pad, h - pad - Skin.S(14))
            P:Refresh(true)
        end
        return P
    end,
}

--- Ticked by the shell: follows undo / redo / new edits.
function Refresh()
    local P = live.history
    if P and P.version ~= History.Version then pcall(P.Refresh, P) end
end
