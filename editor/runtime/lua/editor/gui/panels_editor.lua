-- The editor's own panels, built on the existing editor modules (ui.lua tool state and actions, terrain.lua brush). They replace the
-- fixed tool panel of the old UI: the tools, brush and actions now live in panels that can be docked, tabbed and torn off.
--
--   'tools'    tool buttons (every entry of ui.lua's Tools list, so editor mods that add tools show up), Undo / Redo / Save / Play / Mods
--   'brush'    radius, strength and falloff (bar, - / + and an editable value each) and the brush's weight profile
--
-- Panels refresh through Refresh(), called a few times per second by the shell (UI state is owned by ui.lua; panels hold no state).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Terrain = import('/lua/editor/terrain.lua')

live = {}      -- panel id -> instance, for Refresh

function Refresh()
    for _, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end

local function Section(group, text, y)
    W.Label(group, text, Skin.S(8), y, { color = Skin.color.textDim, size = 'small' })
    return y + Skin.S(18)
end

-- the tool buttons by what they do, in this order; a tool of no group (added by a mod) goes to "Other"
local TOOL_GROUPS = {
    { 'Select', { 'select', 'area_select', 'unit_select', 'prop_select', 'decal_select' } },
    { 'Terrain shape', { 'raise', 'lower', 'flatten', 'smooth', 'plateau', 'noise', 'ramp', 'stamp' } },
    { 'Erosion', { 'erode', 'rain', 'deposit' } },
    { 'Texture', { 'paint', 'erase', 'stamp_paint', 'ttype' } },
    { 'Place objects', { 'unit', 'prop_place', 'decal_place', 'prop', 'prop_erase', 'decal', 'decal_erase', 'marker', 'area', 'army', 'chain', 'paths' } },
    { 'Measure and view', { 'ruler', 'camera' } },
}

Panels.Register{
    id = 'tools', title = 'Tools',
    create = function(group, host)
        local P = { buttons = {}, toolButtons = {} }
        live.tools = P
        local function Make(text, onClick, tip)
            local b = W.Button(group, text, 0, 0, Skin.S(80), Skin.S(24), onClick, { toggle = false, tip = tip })
            P.buttons[table.getn(P.buttons) + 1] = b
            return b
        end
        for _, tool in UI.Tools do
            local id = tool.id
            local Tips = import('/lua/editor/tooltips.lua')
            local b = Make(tool.label, function() UI.SelectTool(id) P:Refresh() end, function() return Tips.ForTool(id) end)
            P.toolButtons[id] = b
        end
        P.heads = {}
        for _, g in TOOL_GROUPS do P.heads[g[1]] = W.Label(group, g[1], 0, 0, { color = Skin.color.textDim, size = 'small' }) end
        P.heads.Other = W.Label(group, 'Other', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.heads.Actions = W.Label(group, 'Map', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.undo = Make('Undo', function() UI.DoUndo() end, 'Undo the last step (Ctrl+Z). A brush stroke is one step.')
        P.redo = Make('Redo', function() UI.DoRedo() end, 'Redo what you undid (Ctrl+Y).')
        P.save = Make('Save map', function() UI.DoSave() end, 'Save the map (Ctrl+S). The first save asks where.')
        P.play = Make('Play test', function() UI.Play() end, 'Run the map in the game (F5). Stop brings you back to the editor.')
        P.mods = Make('Mods', function() UI.ToggleModDialog() end, 'Choose the game mods that are loaded for this map.')
        function P:Refresh()
            for id, b in P.toolButtons do b:SetOn(id == UI.State.tool) end
        end
        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad, bh, gap = Skin.S(8), Skin.S(24), Skin.S(4)
            local bw = math.max(Skin.S(70), math.floor((w - pad * 3) / 2))
            local cols = math.max(1, math.floor((w - pad) / (bw + pad)))
            local function Park(b)
                W.Place(b, group, -20000, -20000)
                b.label.Left:Set(function() return b.Left() end)
            end
            --- A group of buttons: its header, then the buttons in rows of `cols`; a button whose text does not fit one column takes the whole row.
            local function Block(head, list, y)
                if table.getn(list) == 0 then
                    W.Place(head, group, -20000, -20000)
                    return y
                end
                W.Place(head, group, pad, y)
                y = y + Skin.S(16)
                local col, rowY = 0, y
                for _, loopButton in list do
                    local b = loopButton   -- closures share the loop variable (nil after the loop)
                    local span = (b.label.Width() + Skin.S(16) > bw) and cols or 1
                    if col + span > cols then col = 0 rowY = rowY + bh + gap end
                    local bwSpan = span * bw + (span - 1) * pad
                    if cols == 1 then bwSpan = math.max(bwSpan, w - 2 * pad) end           -- one column: the button takes the panel's width
                    if b.label.Width() + Skin.S(8) > bwSpan then W.Fit(b.label, b.label:GetText(), bwSpan - Skin.S(8)) end
                    W.Place(b, group, pad + col * (bw + pad), rowY, bwSpan, bh)
                    W.Center(b.label, b, 0, 0, bwSpan, bh)
                    col = col + span
                end
                return rowY + bh + gap + Skin.S(6)
            end
            -- only the tools of the showing workspace, by group; the others leave the screen (a Maui child shown by a refresh would reappear)
            local grouped = {}
            for _, g in TOOL_GROUPS do for _, id in g[2] do grouped[id] = true end end
            local y = pad
            for _, g in TOOL_GROUPS do
                local list = {}
                for _, id in g[2] do
                    local tool
                    for _, t in UI.Tools do if t.id == id then tool = t end end
                    if tool and UI.ToolAllowed(tool) and P.toolButtons[id] then table.insert(list, P.toolButtons[id]) end
                end
                y = Block(P.heads[g[1]], list, y)
            end
            local other = {}
            for _, tool in UI.Tools do
                if not grouped[tool.id] and UI.ToolAllowed(tool) then table.insert(other, P.toolButtons[tool.id]) end
            end
            y = Block(P.heads.Other, other, y)
            for _, tool in UI.Tools do
                if not UI.ToolAllowed(tool) then Park(P.toolButtons[tool.id]) end
            end
            -- a read-only workspace (Review) has nothing to undo
            local ws = UI.Workspaces[UI.State.workspace]
            local actions = { P.undo, P.redo, P.save, P.play, P.mods }
            if ws and ws.readOnly then
                for _, b in { P.undo, P.redo } do Park(b) end
                actions = { P.save, P.play, P.mods }
            end
            Block(P.heads.Actions, actions, y)
            P:Refresh()
        end
        return P
    end,
}

Panels.Register{
    id = 'brush', title = 'Brush',
    create = function(group, host)
        local P = { bars = {} }
        live.brush = P
        local B = Terrain.Brush
        P.sliders = {
            W.Slider(group, { label = 'Radius', min = 1, max = 64, step = 1, fmt = '%d',
                get = function() return B.radius end, set = function(v) UI.SetRadius(v) end }),
            W.Slider(group, { label = 'Strength % (Shift inverts)', min = -100, max = 100, step = 1, fmt = '%d',
                get = function() return UI.GetStrengthPercent() end, set = function(v) UI.SetStrengthPercent(v) end }),
            W.Slider(group, { label = 'Falloff % (0 flat, 100 full)', min = 0, max = 100, step = 1, fmt = '%d',
                get = function() return B.falloff * 100 end, set = function(v) B.falloff = v / 100 end }),
        }
        -- the noise brush's own settings (shown while the Noise tool is active)
        P.noise = {
            W.Slider(group, { label = 'Noise scale (units)', min = 2, max = 64, step = 1, fmt = '%d',
                tip = 'The size of the bumps the noise brush makes, in map units. Small values give fine, close bumps; large values give broad hills.',
                get = function() return B.noiseScale end, set = function(v) B.noiseScale = v end }),
            W.Slider(group, { label = 'Octaves', min = 1, max = 4, step = 1, fmt = '%d',
                tip = 'How many layers of noise are added. Each further layer has half the bump size and adds finer detail.',
                get = function() return B.noiseOctaves end, set = function(v) B.noiseOctaves = v end }),
            W.Slider(group, { label = 'Roughness', min = 0.3, max = 0.7, step = 0.05, fmt = '%.2f',
                tip = 'How strong the finer layers are. Low values stay smooth; high values add rough detail on top of the big bumps.',
                get = function() return B.noiseRoughness end, set = function(v) B.noiseRoughness = v end }),
        }
        P.title = W.Label(group, 'Profile', 0, 0, { color = Skin.color.textDim })
        for i = 1, 48 do
            local bar = Bitmap(group)
            bar.Depth:Set(function() return group.Depth() + 6 end)
            bar:SetSolidColor('ffffffff')
            P.bars[i] = bar
        end
        P.baseline = Bitmap(group)
        P.baseline.Depth:Set(function() return group.Depth() + 6 end)
        P.baseline:SetSolidColor(Skin.color.line)

        function P:Refresh()
            for _, s in P.sliders do s:Refresh() end
            local noiseOn = (B.mode == 'noise')
            if noiseOn ~= P.noiseShown and P.w then
                P:OnResize(P.w, P.h)          -- the noise sliders come and go with the tool (OnResize calls Refresh again)
                return
            end
            if noiseOn then for _, s in P.noise do s:Refresh() end end
            -- the brush's weight from the centre (left) to the rim (right), in the brightness the world preview uses
            local mode = UI.State.tool
            local ref = (mode == 'flatten' or mode == 'smooth') and 1.0 or 6.0
            local scale = 0.25 + 0.75 * math.min(1, B.strength / ref)
            local n = table.getn(P.bars)
            local gx, gy, gw, gh = P.gx or 0, P.gy or 0, P.gw or 100, P.gh or 40
            local bw = math.max(1, math.floor(gw / n))
            for i, bar in P.bars do
                local d = (i - 0.5) / n * B.radius
                local w = Terrain.BrushWeight(d, B.radius, d, 0)
                local h = math.max(1, math.floor(gh * w))
                local g = math.floor(255 * math.min(1, w * scale + 0.15))
                -- (a bar that did not change is left alone: placing one rebuilds four layout closures, and this runs four times a second)
                local col = string.format('ff%02x%02x%02x', g, g, g)
                if bar.shownCol ~= col then
                    bar.shownCol = col
                    bar:SetSolidColor(col)
                end
                local bx, by, bwid = gx + (i - 1) * bw, gy + gh - h, (bw - 1 > 0 and bw - 1 or bw)
                if bar.shownX ~= bx or bar.shownY ~= by or bar.shownW ~= bwid or bar.shownH ~= h then
                    bar.shownX, bar.shownY, bar.shownW, bar.shownH = bx, by, bwid, h
                    W.Place(bar, group, bx, by, bwid, h)
                end
            end
        end
        function P:OnResize(w, h)
            local pad = Skin.S(10)
            local y = pad
            P.w, P.h = w, h
            for _, s in P.sliders do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(52)
            end
            P.noiseShown = (B.mode == 'noise')
            for _, s in P.noise do
                if P.noiseShown then
                    s:Place(pad, y, w - 2 * pad)
                    y = y + Skin.S(52)
                else
                    s:Place(-20000, -20000, Skin.S(100))
                end
            end
            W.Place(P.title, group, pad, y)
            P.gx, P.gy, P.gw, P.gh = pad, y + Skin.S(20), w - 2 * pad, Skin.S(56)
            W.Place(P.baseline, group, pad, P.gy + P.gh, w - 2 * pad, 1)
            P:Refresh()
        end
        return P
    end,
}
