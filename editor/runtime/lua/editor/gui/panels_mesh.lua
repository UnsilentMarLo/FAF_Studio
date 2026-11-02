-- The Mesh terrain panel: the manifest terrain/terrain.lua of a mesh terrain map (meshmap.lua). Buttons load / create / save the manifest, take the
-- settings that follow from the map (size, playable area, water, ground heights, sun), and run the checks. The list shows the settings (click one to
-- edit its value with the slider) or the findings of the checks. The scenario switch sets ScenarioInfo.TerrainSystem / TerrainMesh.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Mesh = import('/lua/editor/meshmap.lua')
local Map = import('/lua/editor/map.lua')

live = {}

local function Say(text)
    pcall(function() UI.Say(text) end)
end

Panels.Register{
    id = 'meshmap', title = 'Mesh terrain',
    create = function(group, host)
        local P = { model = Mesh.Current, issues = {}, view = 'settings', sel = 1, note = '' }
        live.meshmap = P

        local function Rows()
            local rows = {}
            if P.view == 'checks' then
                for _, i in P.issues do table.insert(rows, i) end
            else
                for _, k in Mesh.Keys do table.insert(rows, k) end
            end
            return rows
        end

        P.list = W.VirtualList(group, {
            extra = true,
            rowH = 22,
            getCount = function() return table.getn(Rows()) end,
            bind = function(row, index)
                local r = Rows()[index]
                if not r then return end
                local c = Skin.color
                local label, extra, color
                if P.view == 'checks' then
                    label = r.code .. '  ' .. r.text
                    extra = r.sev
                    color = r.sev == 'E' and c.error or (r.sev == 'W' and c.warn or c.textDim)
                else
                    local v = P.model and P.model.settings[r.key]
                    label = r.key
                    extra = v == nil and '-' or ((r.dec == 'str' or type(v) ~= 'number') and tostring(v) or string.format(r.dec == 'int' and '%d' or ('%.' .. r.dec .. 'f'), v))
                    color = v == nil and c.textDim or c.text
                    if index == P.sel then color = c.accent end
                end
                local ew = math.min(row.extra.Width(), Skin.S(120))
                row.extra:SetText(extra)
                row.extra:SetColor(c.textDim)
                W.Fit(row.text, label, math.max(Skin.S(30), row.bg.Width() - ew - Skin.S(20)))
                row.text:SetColor(color or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                local w2 = row.extra.Width()
                row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                if P.view == 'checks' then return end
                P.sel = index
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })

        local function Key() return Mesh.Keys[P.sel] end

        P.slider = W.Slider(group, { label = 'Value', min = 0, max = 1, step = 0.01, fmt = '%.2f',
            tip = function()
                local k = Key()
                return 'The value of the setting ' .. (k and k.key or 'chosen in the list') .. ' of the mesh terrain map. Settings that are not set use the engine default.'
            end,
            get = function()
                local k = Key()
                local v = k and P.model and P.model.settings[k.key]
                return type(v) == 'number' and v or (k and k.min or 0)
            end,
            set = function(v)
                local k = Key()
                if k and P.model and k.dec ~= 'str' then P.model.settings[k.key] = v end
                P.list:Refresh()
            end })
        P.setBtn = W.Button(group, 'Set / unset', 0, 0, Skin.S(90), Skin.S(22), function()
            local k = Key()
            if not (k and P.model) then return end
            if P.model.settings[k.key] ~= nil then
                P.model.settings[k.key] = nil
            elseif k.dec == 'str' then
                P.model.settings[k.key] = k.key == 'water_map' and 'watermap.dds' or (k.key == 'water_map_outer' and 'watermap_outer.dds' or (k.key == 'water_beyond' and 'waterbeyond.bin' or 'waterinside.bin'))
            else
                P.model.settings[k.key] = k.min
            end
            P:Refresh()
        end)
        P.help = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        local function Need()
            if not P.model then Say('mesh terrain: load or create a manifest first') return false end
            return true
        end
        P.btnLoad = W.Button(group, 'Load', 0, 0, Skin.S(52), Skin.S(22), function()
            local m, why = Mesh.Load()
            if not m then Say('mesh terrain: ' .. tostring(why)) return end
            P.model = m
            Mesh.Current = m
            P.note = 'loaded ' .. table.getn(m.patches) .. ' patch entries'
            P:Check()
        end)
        P.btnNew = W.Button(group, 'New', 0, 0, Skin.S(46), Skin.S(22), function()
            P.model = Mesh.FromMap()
            Mesh.Current = P.model
            P.note = 'new manifest from the map (no patches yet)'
            P:Refresh()
        end)
        P.btnSync = W.Button(group, 'Sync map', 0, 0, Skin.S(72), Skin.S(22), function()
            if not Need() then return end
            Mesh.SyncFromMap(P.model)
            P.note = 'size, playable area, water, heights and sun taken from the map'
            P:Check()
        end)
        P.btnSave = W.Button(group, 'Save', 0, 0, Skin.S(52), Skin.S(22), function()
            if not Need() then return end
            local path, why = Mesh.Save(P.model)
            if path then Say('mesh terrain: manifest written') P.note = 'saved ' .. path else Say('mesh terrain: ' .. tostring(why)) end
            P:Refresh()
        end)
        P.btnCheck = W.Button(group, 'Check', 0, 0, Skin.S(56), Skin.S(22), function()
            if not Need() then return end
            P.view = 'checks'
            P:Check()
        end)
        P.btnView = W.Button(group, 'Findings', 0, 0, Skin.S(72), Skin.S(22), function()
            P.view = P.view == 'checks' and 'settings' or 'checks'
            P:Refresh()
        end)
        P.scenario = W.Button(group, 'Mesh map in scenario', 0, 0, Skin.S(160), Skin.S(22), function(self)
            if not Map.Doc then return end
            if self.on then
                local dir = Mesh.Dir()
                local folder = dir and string.gsub(dir, '^.*/', '') or nil
                Map.Doc.info.TerrainSystem = 'mesh'
                Map.Doc.info.TerrainMesh = '/maps/' .. string.lower(folder or 'map') .. '/terrain/terrain.lua'
            else
                Map.Doc.info.TerrainSystem = nil
                Map.Doc.info.TerrainMesh = nil
            end
            Say('mesh terrain: scenario fields ' .. (self.on and 'set (saved with the map)' or 'removed'))
        end, { toggle = true })

        function P:Check()
            P.issues = Mesh.Check(P.model)
            local e, w = Mesh.Count(P.issues)
            P.note = string.format('%d errors, %d warnings', e, w)
            P:Refresh()
        end

        function P:Refresh()
            P.model = Mesh.Current
            P.btnView:SetText(P.view == 'checks' and 'Settings' or 'Findings')
            P.list:Refresh()
            local k = Key()
            if k and P.view == 'settings' then
                W.Fit(P.help, k.key .. ': ' .. (k.help or ''), (P.w or 300) - Skin.S(16))
                if k.dec ~= 'str' then
                    local kmax = k.max
                    if string.find(k.key, '^playable_') then kmax = (P.model and P.model.settings.size) or kmax end
                    P.slider:SetRange(k.min, kmax, (k.dec == 'int') and 1 or math.pow(10, -math.min(k.dec, 2)), (k.dec == 'int') and '%d' or ('%.' .. k.dec .. 'f'))
                    P.slider.opts.label = k.key
                    P.slider.label:SetText(k.key)
                end
                P.slider:Refresh()
            else
                P.help:SetText('')
            end
            P.scenario:SetOn(Map.Doc and Map.Doc.info.TerrainSystem == 'mesh' or false)
            W.Fit(P.status, P.note .. (P.model and '' or '  (no manifest loaded)'), (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            local foot = Skin.S(150)
            local top = W.Flow(group, { { P.btnLoad, Skin.S(52) }, { P.btnNew, Skin.S(46) }, { P.btnSync, Skin.S(72) }, { P.btnSave, Skin.S(52) }, { P.btnCheck, Skin.S(56) }, { P.btnView, Skin.S(72) } },
                pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            local listH = math.max(Skin.S(60), h - pad - foot - top)
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            local y = math.max(h - foot + Skin.S(4), top + listH + Skin.S(6))      -- (under the list, also in a panel too short for both: the panel scrolls)
            P.slider:Place(pad, y, w - 2 * pad)
            local y2 = W.Flow(group, { { P.setBtn, Skin.S(90) }, { P.scenario, Skin.S(160) } }, pad, y + Skin.S(48), w - 2 * pad, Skin.S(22), Skin.S(8))
            W.Place(P.help, group, pad, y2 + Skin.S(6))
            W.Place(P.status, group, pad, y2 + Skin.S(24))
            P:Refresh()
        end
        return P
    end,
}

--- The model being edited (shared with the Mesh import panel).
function Model()
    return Mesh.Current
end

--- Replaces the model (the import dialog and the Mesh import panel call this); the panel shows it at its next refresh.
function SetModel(m)
    Mesh.Current = m
    if live.meshmap then live.meshmap:Refresh() end
end
