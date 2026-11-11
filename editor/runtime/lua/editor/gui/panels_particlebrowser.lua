-- The Particle browser panel (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): every effect file of the game (`/effects/**/*.bp`, 3,000 and more: emitters, beams, trails, and the files of mods and the
-- open map) in one list with the filters of upstream's browser (faction and kind from the file's name, type, a text), and the effect templates of /lua/EffectTemplates.lua. A click opens the file in the
-- Particle editor and plays it in the Particle preview (opened in a window of its own when no panel shows it); the swatch shows the file's texture. `Place on map` puts the effect on the map as an
-- effect decoration (fxdeco.lua).
--
-- The list is the game's file system (ed_fx_list_files), so a mod or map folder that holds `effects/emitters/x_emit.bp` shows up in it the next time the panel is built.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Fx = import('/lua/editor/fxparticle.lua')
local Deco = import('/lua/editor/fxdeco.lua')

live = {}

local files = false          -- every effect file: { path, name, faction, kind, type }
local templates = false

local TYPES = { 'All types', 'Emitters', 'Beams', 'Trails' }
local TYPE_COLOR = { emitter = 'fff0aa50', beam = 'ff6ea0ff', trail = 'ff78dc8c', other = 'ff909090' }

local function Say(text)
    pcall(function() UI.Say(text) end)
end

--- The effect files of the game (cached; Reload() lists them again).
function Files()
    if files then return files end
    files = {}
    local list = ed_fx_list_files and ed_fx_list_files(Fx.Roots()) or {}
    for i, f in list do
        local low = string.lower(f.name)
        local kind = 'other'
        if string.find(low, '_emit$') then kind = 'emitter'
        elseif string.find(low, '_beam$') then kind = 'beam'
        elseif string.find(low, '_trail$') then kind = 'trail' end
        files[i] = { path = f.path, name = f.name, faction = f.faction, kind = f.kind, type = kind }
    end
    return files
end

function Reload()
    files, templates = false, false
end

--- The effect templates of the game's EffectTemplates.lua that are plain lists of emitter files: { name, emitters = { paths } }, by name.
function Templates()
    if templates then return templates end
    templates = {}
    local ok, FXV = pcall(import, '/lua/editor/effectview.lua')
    if ok and FXV then
        for i, t in FXV.Templates() do templates[i] = { name = t.name, emitters = t.emitters } end
    end
    return templates
end

--- Opens an effect file in the editor and shows it in the preview (a window of its own when no panel shows the preview).
function OpenFile(path)
    local ok, why = Fx.Open(path)
    if not ok then
        Say('particles: ' .. tostring(why))
        return false
    end
    pcall(function()
        local Shell = import('/lua/editor/gui/shell.lua')
        Shell.OpenPanelWindow('particleview', 540, 640)
    end)
    return true
end

Panels.Register{
    id = 'particlebrowser', title = 'Particle browser',
    stack = { workspace = 'Mod', with = 'effects' },
    minW = 240,
    create = function(group, host)
        local P = { mode = 'files', faction = 0, kind = 0, type = 0, shown = {}, sel = false, w = 300, h = 400 }
        live.particlebrowser = P
        local info = Fx.Info()

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end
        local function Rebuild()
            local filter = string.lower(P.filter and P.filter:GetText() or '')
            P.shown = {}
            if P.mode == 'files' then
                for i, f in Files() do
                    if (P.faction == 0 or f.faction == P.faction) and (P.kind == 0 or f.kind == P.kind) and (P.type == 0 or f.type == string.sub(string.lower(TYPES[P.type + 1]), 1, -2))
                       and (filter == '' or string.find(string.lower(f.name), filter, 1, true)) then
                        table.insert(P.shown, f)
                    end
                end
            elseif P.mode == 'items' and P.templateOf then
                -- the emitter files of the template that was picked
                for _, path in P.templateOf.emitters do
                    local name = string.gsub(string.gsub(path, '^.*/', ''), '%.bp$', '')
                    if filter == '' or string.find(string.lower(name), filter, 1, true) then
                        table.insert(P.shown, { name = name, path = path, type = 'emitter', faction = 0, kind = 0 })
                    end
                end
            else
                for _, t in Templates() do
                    if filter == '' or string.find(string.lower(t.name), filter, 1, true) then
                        table.insert(P.shown, { name = t.name, template = t })
                    end
                end
            end
            if P.list then P.list:Refresh() end
        end

        P.bFiles = Btn('Files', 52, function() P.mode = 'files' Rebuild() P:Refresh() P:OnResize(P.w, P.h) end)
        P.bTemplates = Btn('Templates', 74, function() P.mode = 'templates' P.templateOf = false Rebuild() P:Refresh() P:OnResize(P.w, P.h) end)
        P.bBack = Btn('Back to templates', 120, function() P.mode = 'templates' P.templateOf = false Rebuild() P:Refresh() P:OnResize(P.w, P.h) end)
        P.filter = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function() Rebuild() end })
        P.filterLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })
        P.bFaction = Btn('', 100, function() P.faction = math.mod(P.faction + 1, table.getn(info.factions)) Rebuild() P:Refresh() end)
        P.bKind = Btn('', 100, function() P.kind = math.mod(P.kind + 1, table.getn(info.kinds)) Rebuild() P:Refresh() end)
        P.bType = Btn('', 90, function() P.type = math.mod(P.type + 1, table.getn(TYPES)) Rebuild() P:Refresh() end)

        P.list = W.VirtualList(group, {
            extra = true, rowH = 20,
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index)
                local c = Skin.color
                local e = P.shown[index]
                if not e then return end
                W.Fit(row.text, e.name, math.max(Skin.S(30), row.bg.Width() - Skin.S(110)))
                local selected = P.sel == (e.path or e.name)
                row.text:SetColor(selected and c.accent or c.text)
                if e.template then
                    row.extra:SetText(table.getn(e.template.emitters) .. ' emitters')
                    row.extra:SetColor(c.textDim)
                elseif P.mode == 'items' then
                    row.extra:SetText('')
                else
                    row.extra:SetText(info.factions[e.faction + 1] and e.faction > 0 and string.gsub(info.factions[e.faction + 1], '^%s*', '') or '')
                    row.extra:SetColor(TYPE_COLOR[e.type] or c.textDim)
                end
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
                if e.template then
                    -- a template: its emitter files are listed (and the first opens); the Effects panel plays the whole template on the map
                    P.sel = e.name
                    P.templateOf = e.template
                    P.mode = 'items'
                    Rebuild()
                    P:OnResize(P.w, P.h)
                    local first = e.template.emitters[1]
                    if first then OpenFile(first) end
                else
                    P.sel = e.path
                    P.templateOf = false
                    OpenFile(e.path)
                end
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })

        P.swatch = Bitmap(group)
        P.swatch.Depth:Set(function() return group.Depth() + 5 end)
        P.swatch:SetSolidColor(Skin.color.panelAlt)
        P.swatchLabel = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.bPlace = Btn('Place on map', 96, function()
            local path = Fx.Source ~= '' and Fx.Source or nil
            if not path then Say('particles: open an effect file first') return end
            local name, why = Deco.PlaceAtView(path)
            Say(name and ('particles: effect decoration ' .. name .. ' placed in the middle of the view (Markers tool: move it, Properties: scale and height)') or ('particles: ' .. tostring(why)))
        end, { tip = 'Put the open effect on the map as a decoration: an Effect marker in the middle of the view. The map plays it for the whole game.' })
        P.bEdit = Btn('Open editor', 84, function()
            pcall(function() import('/lua/editor/gui/shell.lua').OpenPanelWindow('particles', 340, 700) end)
        end, { tip = 'Show the Particle editor panel.' })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        local swatched = false
        function P:Refresh()
            P.bFiles:SetOn(P.mode == 'files')
            P.bTemplates:SetOn(P.mode == 'templates' or P.mode == 'items')
            P.bFaction:SetText(info.factions[P.faction + 1] or '')
            P.bKind:SetText(info.kinds[P.kind + 1] or '')
            P.bType:SetText(TYPES[P.type + 1])
            P.list:Refresh()
            -- the texture of the open file
            local tex
            if Fx.Emitter then tex = Fx.Emitter.texture
            elseif Fx.Flat then
                local f = Fx.FlatField('TextureName') or Fx.FlatField('RepeatTexture')
                tex = f and f.text
            end
            if tex and tex ~= '' and tex ~= swatched then
                swatched = tex
                local ok = pcall(function() P.swatch:SetTexture(tex) end)
                if not ok then P.swatch:SetSolidColor(Skin.color.panelAlt) end
            elseif not tex or tex == '' then
                swatched = false
                P.swatch:SetSolidColor(Skin.color.panelAlt)
            end
            P.swatchLabel:SetText(tex and string.gsub(tex, '^.*/', '') or '')
            local text = table.getn(P.shown) .. (P.mode == 'files' and ' effect files' or (P.mode == 'items' and ' emitters' or ' templates'))
            if P.templateOf then text = text .. '   template ' .. P.templateOf.name end
            W.Fit(P.status, text, (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            W.Flow(group, { { P.bFiles, Skin.S(52) }, { P.bTemplates, Skin.S(74) }, { P.bBack, Skin.S(120) } }, pad, pad, w - 2 * pad, Skin.S(22), Skin.S(4))
            local y = pad + Skin.S(28)
            W.Place(P.filterLabel, group, pad, y + Skin.S(3))
            W.Place(P.filter.frame, group, pad + Skin.S(34), y, math.max(Skin.S(40), w - 2 * pad - Skin.S(34)), Skin.S(22))
            P.filter.Width:Set(math.max(Skin.S(40), w - 2 * pad - Skin.S(34)) - 2)
            y = y + Skin.S(28)
            local files = P.mode == 'files'
            for _, b in { P.bFaction, P.bKind, P.bType } do
                if files then b:Show() else b:Hide() end
            end
            if P.mode == 'items' then P.bBack:Show() else P.bBack:Hide() end
            if files then
                W.Flow(group, { { P.bFaction, Skin.S(100) }, { P.bKind, Skin.S(100) }, { P.bType, Skin.S(90) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4))
                y = y + Skin.S(28)
            end
            -- the list takes what is left above the footer (at least 6 rows: a short panel scrolls instead of overlapping)
            local foot = Skin.S(150)
            local listH = math.max(Skin.S(130), h - y - foot - pad)
            P.list:SetRect(pad, y, w - 2 * pad, listH)
            local fy = y + listH + Skin.S(6)
            W.Place(P.swatch, group, pad, fy, Skin.S(96), Skin.S(96))
            W.Place(P.swatchLabel, group, pad + Skin.S(104), fy)
            W.Flow(group, { { P.bPlace, Skin.S(96) } }, pad + Skin.S(104), fy + Skin.S(22), w - 2 * pad - Skin.S(104), Skin.S(22), Skin.S(4))
            W.Flow(group, { { P.bEdit, Skin.S(84) } }, pad + Skin.S(104), fy + Skin.S(50), w - 2 * pad - Skin.S(104), Skin.S(22), Skin.S(4))
            W.Place(P.status, group, pad, fy + Skin.S(104))
            Rebuild()
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: the swatch and the status follow the open file.
function Refresh()
    local P = live.particlebrowser
    if P and not P.dead and P.Refresh then pcall(P.Refresh, P) end
end
