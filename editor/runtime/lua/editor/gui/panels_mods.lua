-- The mod selection of the map as a docked panel (it used to be a paged dialog): a filter field, a scrolling list with a mark per
-- mod, and Apply & reload. The selection is edited in ui.lua's State.modsPending; Apply saves it, autosaves the map and reopens it
-- (mods are applied when a session starts). Editor mods (always loaded) are listed above the list.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Mods = import('/lua/editor/mods.lua')
local Commands = import('/lua/editor/gui/commands.lua')

-- Editor mods that were kept out (an incompatible editor_api, a hook that does not compile, a start that did not come up) are listed under the loaded ones; this command lets them try again
-- at the next launch.
Commands.Register{ id = 'mods.enable_editor', title = 'Mods: enable the editor mods that were turned off', run = function()
    Mods.ReenableEditorMods()
    pcall(function() import('/lua/editor/ui.lua').Say('Editor mods enabled again: restart the editor to load them') end)       -- best effort: a status line message
end }

live = {}
NoAutoRefresh = true       -- refreshed by its own events, not by the shell tick

function Refresh()
    for _, inst in live do
        if inst.Refresh then import('/lua/editor/safe.lua').Try('panel:mods.refresh', inst.Refresh, inst) end
    end
end

Panels.Register{
    id = 'mods', title = 'Mods',
    create = function(group, host)
        local P = { filter = '', shown = {}, w = 300, h = 200, header = {} }
        live.mods = P
        if not UI.State.modsPending then UI.State.modsPending = Mods.GetSelection() end

        local function Pending() return UI.State.modsPending or {} end

        local function Rebuild()
            P.shown = {}
            local f = string.lower(P.filter)
            for _, mod in Mods.Browsable() do
                if f == '' or string.find(string.lower(tostring(mod.name)), f, 1, true) then
                    table.insert(P.shown, mod)
                end
            end
            P.list:Refresh()
        end

        P.field = W.TextField(group, Skin.S(8), Skin.S(8), 100, Skin.S(22), {
            onChange = function(text) P.filter = text Rebuild() end,
        })
        P.list = W.VirtualList(group, {
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local mod = P.shown[index]
                local on = Pending()[mod.uid] == true
                local required = Mods.DependencyOnly(Pending())[mod.uid] == true
                local text = (on and '[x]  ' or (required and '[+]  ' or '[   ]  ')) .. tostring(mod.name)
                if required then text = text .. '   (required)' end
                W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(24)))
                row.text:SetColor((on or required) and Skin.color.text or Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local mod = P.shown[index]
                if mod then
                    local pending = Pending()
                    pending[mod.uid] = not pending[mod.uid] or nil
                    UI.State.modsPending = pending
                end
                P.list.selected = nil
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.apply = W.Button(group, 'Apply & reload', 0, 0, Skin.S(110), Skin.S(24), function() UI.ApplyMods() end)
        P.revert = W.Button(group, 'Revert', 0, 0, Skin.S(70), Skin.S(24), function()
            UI.State.modsPending = Mods.GetSelection()
            P:Refresh()
        end)

        function P:Refresh()
            local n = 0
            for _ in Pending() do n = n + 1 end
            W.Fit(P.status, string.format('%d of %d mods selected', n, table.getn(Mods.Browsable())), (P.w or 300) - Skin.S(16))
            P.list:Refresh()
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            for _, l in P.header do l:Destroy() end
            local always = {}
            for _, mod in Mods.ActiveEditorMods() do table.insert(always, tostring(mod.name)) end
            local text = 'Editor mods (always loaded): ' .. (table.getn(always) > 0 and table.concat(always, ', ') or 'none')
            for _, p in Mods.Problems() do text = text .. '\nNot loaded: ' .. p.name .. ' (' .. p.why .. ')' end
            if table.getn(Mods.Problems()) > 0 then text = text .. '\nCommand palette: "Mods: enable the editor mods that were turned off"' end
            local labels, below = W.Paragraph(group, text, pad, pad, math.max(Skin.S(80), w - 2 * pad), { color = Skin.color.textDim, size = 'small' })
            P.header = labels
            local fy = below + Skin.S(4)
            W.Place(P.field.frame, group, pad, fy, math.max(Skin.S(60), w - 2 * pad), Skin.S(22))
            P.field.Width:Set(math.max(Skin.S(60), w - 2 * pad) - 2)
            local listTop = fy + Skin.S(28)
            local lh = math.max(Skin.S(14), P.status.Height())
            h = math.max(h, listTop + Skin.S(Skin.size.rowH) * 3 + Skin.S(6) + lh + Skin.S(4) + Skin.S(24) + pad)          -- too little room: the panel scrolls
            local bottom = h - pad - Skin.S(24)
            local statusY = bottom - lh - Skin.S(4)          -- the count sits above the buttons, as wide as the panel
            -- the list takes what is left; it never reaches into the status line (a small panel shows fewer rows)
            local avail = statusY - listTop - Skin.S(6)
            P.list:SetRect(pad, listTop, w - 2 * pad, avail)
            W.Place(P.apply, group, pad, bottom, Skin.S(110), Skin.S(24))
            W.Place(P.revert, group, pad + Skin.S(118), bottom, Skin.S(70), Skin.S(24))
            W.Place(P.status, group, pad, statusY)
            Rebuild()
            P:Refresh()
        end
        return P
    end,
}
