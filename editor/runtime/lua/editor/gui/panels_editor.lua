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
            local pad, bh = Skin.S(8), Skin.S(24)
            local bw = math.max(Skin.S(70), math.floor((w - pad * 3) / 2))
            local cols = math.max(1, math.floor((w - pad) / (bw + pad)))
            local function Grid(list, y)
                for i, loopButton in list do
                    local b = loopButton   -- closures share the loop variable (nil after the loop)
                    local col, row = math.mod(i - 1, cols), math.floor((i - 1) / cols)
                    W.Place(b, group, pad + col * (bw + pad), y + row * (bh + Skin.S(4)), bw, bh)
                    local lx = math.floor((bw - b.label.Width()) / 2)
                    b.label.Left:Set(function() return b.Left() + lx end)
                end
                return y + math.ceil(table.getn(list) / cols) * (bh + Skin.S(4))
            end
            -- only the tools of the showing workspace; the others leave the screen (a Maui child shown by a refresh would reappear)
            local tools = {}
            for _, tool in UI.Tools do
                local b = P.toolButtons[tool.id]
                if UI.ToolAllowed(tool) then
                    tools[table.getn(tools) + 1] = b
                else
                    W.Place(b, group, -20000, -20000)
                    b.label.Left:Set(function() return b.Left() end)
                end
            end
            local y = Grid(tools, pad)
            y = y + Skin.S(8)
            -- a read-only workspace (Review) has nothing to undo
            local ws = UI.Workspaces[UI.State.workspace]
            local actions = { P.undo, P.redo, P.save, P.play, P.mods }
            if ws and ws.readOnly then
                for _, b in { P.undo, P.redo } do
                    W.Place(b, group, -20000, -20000)
                    local hidden = b
                    hidden.label.Left:Set(function() return hidden.Left() end)
                end
                actions = { P.save, P.play, P.mods }
            end
            Grid(actions, y)
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
                bar:SetSolidColor(string.format('ff%02x%02x%02x', g, g, g))
                W.Place(bar, group, gx + (i - 1) * bw, gy + gh - h, bw - 1 > 0 and bw - 1 or bw, h)
            end
        end
        function P:OnResize(w, h)
            local pad = Skin.S(10)
            local y = pad
            for _, s in P.sliders do
                s:Place(pad, y, w - 2 * pad)
                y = y + Skin.S(52)
            end
            W.Place(P.title, group, pad, y)
            P.gx, P.gy, P.gw, P.gh = pad, y + Skin.S(20), w - 2 * pad, Skin.S(56)
            W.Place(P.baseline, group, pad, P.gy + P.gh, w - 2 * pad, 1)
            P:Refresh()
        end
        return P
    end,
}
