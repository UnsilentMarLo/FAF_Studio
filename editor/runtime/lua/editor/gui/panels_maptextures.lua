-- The Map textures panel: the pictures that cover the whole map and that the terrain shader reads instead of the usual per-tile ones: the normal map, the lighting (baked shadow) texture,
-- the specular texture, the macrotexture and the roughness / height atlas of the PBR shaders. Which of them the map's shader uses, and in which layer slot, is maptextures.lua (docs: its header, effects/terrain.fx).
--
--   picture            click to import another picture for it
--   Generate           make the normal map / lighting texture from the terrain (the same generators as the graph's Height to normal map and Lighting texture nodes); one undo step
--   Import...          a DDS (taken as it is) or another picture (PNG, TGA, JPEG, BMP, TIFF; stretched and written as a DDS)
--   Export...          the texture as stored: .dds (a copy) or .png (and <name>_alpha.png)
--   Clear              the shader gets its neutral texture again (the engine's own normals, no baked shadow, no macrotexture / specular)
--   Shader / Size      the terrain shader of the map (the shader browser) and the size of generated pictures
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local MT = import('/lua/editor/maptextures.lua')

live = {}

--- Module level (the controls come and go).
state = { size = 'auto', strength = 1, soft = 1, reach = 400, ao = 0, status = '', macroContrast = 0.25, macroOpacity = 0.35, macroScale = 180, macroCavity = 0.3, specStrength = 0.8 }

SIZES = { 'auto', 256, 512, 1024, 2048, 4096, 8192 }

FILTER = 'Pictures (*.dds;*.png;*.tga;*.jpg;*.bmp;*.tif)|*.dds;*.png;*.tga;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff|All files|*.*'

local function Say(text)
    state.status = text
    pcall(function() UI.Say(text) end)
end

local function Lower(kind)
    return string.lower(MT.Kinds[kind].label)
end

local function Again()
    local P = live.maptextures
    if P then pcall(P.Refresh, P, true) end
end

-- ---- actions (module level: used by the buttons and the picture) ------------------------------------------------------------------------------------

function Generate(kind)
    local opts = { size = state.size, strength = state.strength, soft = state.soft, reach = state.reach, ao = state.ao }
    if kind == 'macro' then
        opts.contrast, opts.opacity, opts.scale, opts.cavity = state.macroContrast, state.macroOpacity, state.macroScale, state.macroCavity
    elseif kind == 'specular' then
        opts.strength = state.specStrength
    end
    local entry, err = MT.Generate(kind, opts)
    if entry then
        Say(MT.Kinds[kind].label .. ' made from the terrain and given to the shader (one undo step)')
    else
        Say('not made: ' .. tostring(err))
    end
    Again()
end

function Import(kind)
    local cur = MT.Current(kind)
    if not cur.slot then Say(cur.why) return end
    local path = ed_file_dialog(false, 'Import ' .. Lower(kind), FILTER, '')
    if not path then return end
    local entry, err = MT.Import(kind, path)
    if entry then
        Say(MT.Kinds[kind].label .. ' imported from ' .. string.gsub(path, '^.*[/\\]', '') .. ' (one undo step)')
    else
        Say('not imported: ' .. tostring(err))
    end
    Again()
end

function Export(kind)
    local cur = MT.Current(kind)
    if not cur.slot then Say(cur.why) return end
    if cur.empty then Say('this map has no ' .. Lower(kind) .. ' yet: Generate or Import one first') return end
    local path = ed_file_dialog(true, 'Export ' .. Lower(kind), 'DDS texture (*.dds)|*.dds|PNG picture (*.png)|*.png', 'map_' .. kind)
    if not path then return end
    if not string.find(string.lower(path), '%.%a+$') then path = path .. '.dds' end
    local ok, err = MT.Export(kind, path)
    if ok then Say(MT.Kinds[kind].label .. ' written to ' .. path) else Say('not exported: ' .. tostring(err)) end
end

function Clear(kind)
    local entry, err = MT.Clear(kind)
    if entry then Say(MT.Kinds[kind].label .. ' taken off: the shader uses its neutral texture (one undo step)') else Say('not cleared: ' .. tostring(err)) end
    Again()
end

-- ---- the panel ------------------------------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'maptextures', title = 'Map textures', minW = 250, minH = 240, stack = { workspace = 'Terrain', with = 'layers' },
    create = function(group, host)
        local P = { cards = {}, w = 260 }
        live.maptextures = P
        local c = Skin.color

        P.shader = W.Button(group, 'Shader: ...', 0, 0, Skin.S(210), Skin.S(24), function()
            import('/lua/editor/gui/shaderbrowser.lua').Open(function(id)
                Say('terrain shader: ' .. id)
                Again()
            end)
        end)
        P.size = W.Button(group, 'Size: auto', 0, 0, Skin.S(120), Skin.S(24), function()
            local at = 1
            for i, v in SIZES do if v == state.size then at = i end end
            state.size = SIZES[math.mod(at, table.getn(SIZES)) + 1]
            Again()
        end)
        P.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.note = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        local function Picture(tip, onClick)
            local b = Bitmap(group)
            b:SetSolidColor(c.panelAlt)
            b.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hover(self, tip, event) end)
                    return true
                elseif event.Type == 'MouseExit' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Leave(self) end)
                    return true
                elseif event.Type == 'ButtonPress' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hide() end)
                    onClick()
                    return true
                end
                return false
            end
            return b
        end

        for _, kind in MT.Order do
            local k = kind
            local info = MT.Kinds[k]
            local card = { kind = k, sliders = {}, buttons = {} }
            card.title = W.Label(group, info.label, 0, 0, { color = c.text })
            card.state = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
            card.pic = Picture(function()
                local cur = MT.Current(k)
                local text = info.desc .. '\nUsed by: ' .. info.usedBy .. '.'
                if cur.slot then text = text .. '\nStored in the ' .. cur.slot.where .. ' (' .. cur.slot.layout .. ').' end
                return text .. '\nClick to import a picture.'
            end, function() Import(k) end)
            card.line1 = W.Label(group, '', 0, 0, { color = c.text, size = 'small' })
            card.line2 = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
            card.line3 = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
            card.used = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
            if k == 'normal' then
                table.insert(card.sliders, W.Slider(group, { label = 'Slope strength', min = 0.2, max = 4, step = 0.1, fmt = '%.1f',
                    get = function() return state.strength end, set = function(v) state.strength = v end }))
            elseif k == 'light' then
                table.insert(card.sliders, W.Slider(group, { label = 'Shadow softness (degrees)', min = 0, max = 6, step = 0.25, fmt = '%.2f',
                    get = function() return state.soft end, set = function(v) state.soft = v end }))
                table.insert(card.sliders, W.Slider(group, { label = 'Longest shadow (units)', min = 50, max = 1500, step = 10, fmt = '%d',
                    get = function() return state.reach end, set = function(v) state.reach = v end }))
                table.insert(card.sliders, W.Slider(group, { label = 'Ambient occlusion', min = 0, max = 1, step = 0.05, fmt = '%.2f',
                    get = function() return state.ao end, set = function(v) state.ao = v end }))
            end
            if k == 'macro' then
                table.insert(card.sliders, W.Slider(group, { label = 'Macro patch size (units)', min = 40, max = 600, step = 10, fmt = '%d',
                    get = function() return state.macroScale end, set = function(v) state.macroScale = v end }))
                table.insert(card.sliders, W.Slider(group, { label = 'Macro lighter and darker patches', min = 0, max = 0.6, step = 0.05, fmt = '%.2f',
                    get = function() return state.macroContrast end, set = function(v) state.macroContrast = v end }))
                table.insert(card.sliders, W.Slider(group, { label = 'Macro darker cavities', min = 0, max = 1, step = 0.05, fmt = '%.2f',
                    get = function() return state.macroCavity end, set = function(v) state.macroCavity = v end }))
                table.insert(card.sliders, W.Slider(group, { label = 'Macro coverage', min = 0.05, max = 0.9, step = 0.05, fmt = '%.2f',
                    get = function() return state.macroOpacity end, set = function(v) state.macroOpacity = v end }))
            elseif k == 'specular' then
                table.insert(card.sliders, W.Slider(group, { label = 'Specular shine of wet ground and snow', min = 0, max = 1, step = 0.05, fmt = '%.2f',
                    get = function() return state.specStrength end, set = function(v) state.specStrength = v end }))
            end
            if info.generate then
                card.generate = W.Button(group, 'Generate', 0, 0, Skin.S(78), Skin.S(24), function() Generate(k) end)
                table.insert(card.buttons, { card.generate, Skin.S(78) })
            end
            card.import = W.Button(group, 'Import...', 0, 0, Skin.S(76), Skin.S(24), function() Import(k) end)
            card.export = W.Button(group, 'Export...', 0, 0, Skin.S(76), Skin.S(24), function() Export(k) end)
            card.clear = W.Button(group, 'Clear', 0, 0, Skin.S(58), Skin.S(24), function() Clear(k) end)
            table.insert(card.buttons, { card.import, Skin.S(76) })
            table.insert(card.buttons, { card.export, Skin.S(76) })
            table.insert(card.buttons, { card.clear, Skin.S(58) })
            table.insert(P.cards, card)
        end

        --- Re-reads the shader, the slots and the files; `force` redraws pictures and texts even when nothing changed.
        function P:Refresh(force)
            local id = MT.ShaderId()
            local class = MT.ShaderClass(id)
            local shaderKey = id .. '|' .. tostring(state.size)
            if force or shaderKey ~= P.shaderKey then
                P.shaderKey = shaderKey
                P.shader:SetText('Shader: ' .. (id ~= '' and id or '?'))
                P.size:SetText('Size: ' .. tostring(state.size))
                W.Fit(P.note, 'Pictures that cover the whole map. Click one to import another.', P.w - 2 * Skin.S(10))
                -- what the shader is (shaders.lua, read only) and which of the pictures it reads
                local okS, entry = pcall(function() return import('/lua/editor/shaders.lua').Find(id) end)
                local reads = {}
                for _, kind in MT.Order do
                    if MT.Slot(kind, id) then table.insert(reads, string.lower(MT.Kinds[kind].label)) end
                end
                local reading = table.getn(reads) > 0 and ('reads: ' .. table.concat(reads, ', ')) or 'reads none of these'
                W.Fit(P.info, (okS and entry and entry.summary and (entry.summary .. ' ') or '') .. '(' .. reading .. ')', P.w - 2 * Skin.S(10))
            end
            local statusText = state.status or ''
            if force or statusText ~= P.statusShown then
                P.statusShown = statusText
                W.Fit(P.status, statusText, P.w - 2 * Skin.S(10))
            end
            local textW = math.max(Skin.S(40), P.w - (P.picW or Skin.S(100)) - 3 * Skin.S(10))
            for _, card in P.cards do
                local cur = MT.Current(card.kind)
                local stale = (not cur.empty) and MT.StaleReason(card.kind)
                local key = tostring(cur.path) .. '|' .. tostring(cur.size) .. '|' .. id .. '|' .. tostring(textW) .. '|' .. tostring(stale)
                if force or key ~= card.key then
                    card.key = key
                    W.Fit(card.used, 'Used by: ' .. MT.Kinds[card.kind].usedBy, textW)
                    if not cur.slot then
                        W.Fit(card.state, 'Not used by ' .. (id ~= '' and id or 'this shader'), P.w - 2 * Skin.S(10))
                        card.state:SetColor(c.textDim)
                        card.pic:SetSolidColor(c.panelAlt)
                        W.Fit(card.line1, 'No picture', textW)
                        W.Fit(card.line2, '', textW)
                        W.Fit(card.line3, '', textW)
                    else
                        local where = cur.slot.where
                        if cur.empty then
                            W.Fit(card.state, 'None yet (' .. id .. ' reads it from the ' .. where .. ')', P.w - 2 * Skin.S(10))
                            card.state:SetColor(c.warn)
                            card.pic:SetSolidColor(c.panelAlt)
                            W.Fit(card.line1, 'No picture', textW)
                            W.Fit(card.line2, '', textW)
                            W.Fit(card.line3, cur.slot.layout, textW)
                        else
                            if stale then
                                W.Fit(card.state, stale == 'resized' and 'Out of date: the map was resized. Generate again.' or 'Out of date: the terrain or the sun changed. Generate again.', P.w - 2 * Skin.S(10))
                                card.state:SetColor(c.warn)
                            else
                                W.Fit(card.state, 'In use (' .. where .. ')', P.w - 2 * Skin.S(10))
                                card.state:SetColor(c.ok)
                            end
                            local vfs, why = MT.Preview(card.kind, 96)
                            if vfs then card.pic:SetTexture(vfs) else card.pic:SetSolidColor(c.panelAlt) end
                            W.Fit(card.line1, cur.file .. (cur.managed and '' or '  (not made here)'), textW)
                            W.Fit(card.line2, 'tile ' .. string.format('%g', cur.size or 0) .. ' units', textW)
                            W.Fit(card.line3, cur.slot.layout, textW)
                        end
                    end
                end
                for _, s in card.sliders do s:Refresh() end
            end
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(10)
            local y = pad
            y = W.Flow(group, { { P.shader, Skin.S(210) }, { P.size, Skin.S(120) } }, pad, y, w - 2 * pad, Skin.S(24), Skin.S(4)) + Skin.S(6)
            W.Place(P.info, group, pad, y)
            y = y + Skin.S(18)
            W.Place(P.note, group, pad, y)
            y = y + Skin.S(18)
            W.Place(P.status, group, pad, y)
            y = y + Skin.S(22)
            local ps = math.max(Skin.S(76), math.min(Skin.S(112), math.floor((w - 3 * pad) / 2)))
            P.picW = ps
            for _, card in P.cards do
                W.Place(card.title, group, pad, y)
                y = y + Skin.S(20)
                W.Place(card.state, group, pad, y)
                y = y + Skin.S(20)
                W.Place(card.pic, group, pad, y, ps, ps)
                local tx = pad + ps + pad
                W.Place(card.line1, group, tx, y)
                W.Place(card.line2, group, tx, y + Skin.S(18))
                W.Place(card.line3, group, tx, y + Skin.S(36))
                W.Place(card.used, group, tx, y + Skin.S(54))
                y = y + ps + Skin.S(8)
                for _, s in card.sliders do
                    s:Place(pad, y, w - 2 * pad)
                    y = y + Skin.S(50)
                end
                y = W.Flow(group, card.buttons, pad, y, w - 2 * pad, Skin.S(24), Skin.S(4)) + Skin.S(18)
            end
            P:Refresh(true)
        end

        return P
    end,
}

function Refresh()
    for id, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end
