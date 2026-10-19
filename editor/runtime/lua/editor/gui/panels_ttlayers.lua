-- The "Type from textures" panel: every texture layer (Base, 1..8) with its texture and the terrain type slot assigned to it (the default of the texture until you
-- pick one; a click on a row opens the type list), and the Generate button that fills the terrain type grid from the layers (terraintype.lua Generate): each cell gets
-- the type of the layer seen most there, the masks of the layers above taking away from the ones below.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Strata = import('/lua/editor/strata.lua')
local TT = import('/lua/editor/terraintype.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

Panels.Register{
    id = 'ttlayers', title = 'Auto type',
    create = function(group, host)
        local P = { rows = {}, onlyUnset = false }
        live.ttlayers = P

        local function Reload()
            P.rows = {}
            local layers = Strata.Layers()
            for i = 1, 9 do                         -- Base (0) and the painted layers 1..8; the Upper layer is a transparency layer: no type
                local l = layers[i]
                if l then table.insert(P.rows, l) end
            end
        end
        Reload()

        P.list = W.VirtualList(group, {
            extra = true,
            thumb = true,
            rowH = 24,
            getCount = function() return table.getn(P.rows) end,
            bind = function(row, index)
                local l = P.rows[index]
                local has = (l.albedo ~= '' and l.albedo ~= Strata.CLEAR)
                if has then row.thumb:SetTexture(l.albedo) else row.thumb:SetSolidColor(Skin.color.panelAlt) end
                local code = TT.TypeOfLayer(l.index)
                row.extra:SetText((TT.Manual[l.index] and '* ' or '') .. TT.NameOf(code))
                local tx = row.bg.Height() + Skin.S(4)
                local ew = math.min(row.extra.Width(), Skin.S(110))
                W.Fit(row.text, l.name, math.max(Skin.S(30), row.bg.Width() - tx - ew - Skin.S(20)))
                row.text:SetColor(has and Skin.color.text or Skin.color.textDim)
                row.extra:SetColor(has and Skin.color.accent or Skin.color.textDim)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + tx end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local l = P.rows[index]
                if not l then return end
                import('/lua/editor/gui/dialogs_terrain.lua').PickType('Terrain type of ' .. l.name, TT.TypeOfLayer(l.index), function(code)
                    if code == false then
                        TT.ResetLayerTypes(l.index)          -- "default of the texture"
                    else
                        TT.SetLayerType(l.index, code)
                    end
                    P:Refresh()
                end)
            end,
            bgColor = Skin.color.panel,
        })

        P.defaults = W.Button(group, 'Defaults', 0, 0, Skin.S(80), Skin.S(24), function()
            TT.ResetLayerTypes()
            P:Refresh()
        end)
        P.unset = W.Button(group, 'Only unset cells', 0, 0, Skin.S(120), Skin.S(24), function(self) P.onlyUnset = self.on end, { toggle = true })
        P.generate = W.Button(group, 'Generate from textures', 0, 0, Skin.S(200), Skin.S(26), function()
            local entry, changed = TT.Generate({ onlyUnset = P.onlyUnset })
            if entry then
                UI.PushEdit(entry)
                Say('terrain types generated: ' .. tostring(changed) .. ' cells changed')
            else
                Say('terrain types: nothing to change')
            end
            TT.Visible = true
            TT.Revision = TT.Revision + 1
        end)
        P.note = W.Label(group, '* = assigned by you; the others follow the texture. Click a row to change.', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            Reload()
            P.list:Refresh()
        end

        function P:OnResize(w, h)
            local pad = Skin.S(8)
            local foot = Skin.S(96)
            P.list:SetRect(pad, pad, w - 2 * pad, math.max(Skin.S(60), h - 2 * pad - foot))
            local y = h - foot + Skin.S(4)
            W.Place(P.defaults, group, pad, y, Skin.S(80), Skin.S(24))
            W.Place(P.unset, group, pad + Skin.S(88), y, Skin.S(120), Skin.S(24))
            W.Place(P.generate, group, pad, y + Skin.S(30), w - 2 * pad, Skin.S(26))
            W.Place(P.note, group, pad, y + Skin.S(60))
            P:Refresh()
        end
        return P
    end,
}

--- Called by the layers panel when textures change, so the shown defaults follow.
function Refresh()
    if live.ttlayers then pcall(live.ttlayers.Refresh, live.ttlayers) end
end
