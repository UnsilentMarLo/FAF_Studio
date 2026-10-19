-- The variation gallery of the terrain graph: the result of the graph for six seeds side by side as small pictures (each seed is a private run at preview resolution; the live cache of the
-- canvas stays). A click on a picture makes that seed the seed of the graph. Docs: docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T5.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')

live = {}
state = { first = 1, list = {}, text = 'Press Make to see the graph for six seeds.', count = 6, size = 112 }

function Make(first)
    if first then state.first = first end
    if not Graph.Current or table.getn(Graph.Current.nodes) == 0 then
        state.text = 'the graph is empty'
        state.list = {}
    else
        local clock = rawget(_G, 'ed_field_clock') or function() return 0 end
        local t0 = clock()
        state.list = GRun.Gallery(state.first, state.count, state.size)
        local t1 = clock()
        state.text = string.format('seeds %d - %d (%.0f ms); click one to use it', state.first, state.first + state.count - 1, (t1 - t0) * 1000)
    end
    local Pn = live.gallery
    if Pn and not Pn.dead then Pn:Refresh() end
end

Panels.Register{
    id = 'graphgallery', title = 'Variations', minW = 250, minH = 160,
    create = function(group, host)
        local Pn = { cells = {} }
        live.gallery = Pn
        local c = Skin.color
        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn) end
        Pn.bMake = Btn('Make', 54, function() Make(Graph.Current.seed) end)
        Pn.bPrev = Btn('Previous', 64, function() Make(math.max(0, state.first - state.count)) end)
        Pn.bNext = Btn('Next', 54, function() Make(state.first + state.count) end)
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        local function Cell(i)
            local cell = Pn.cells[i]
            if cell then return cell end
            cell = {}
            cell.frame = Bitmap(group)
            cell.frame.Depth:Set(function() return group.Depth() + 5 end)
            cell.frame:SetSolidColor(c.line)
            cell.pic = Bitmap(cell.frame)
            cell.pic.Depth:Set(function() return cell.frame.Depth() + 1 end)
            cell.pic:DisableHitTest()
            cell.label = W.Label(cell.frame, '', 0, 0, { color = c.text, size = 'small' })
            cell.frame.HandleEvent = function(self, event)
                if event.Type == 'ButtonPress' then
                    local item = state.list[i]
                    if item then
                        Graph.SetSeed(item.seed)
                        state.text = 'seed ' .. item.seed .. ' is the seed of the graph now'
                        local ok, canvas = pcall(import, '/lua/editor/gui/panels_graph.lua')
                        if ok and canvas.live.canvas then canvas.live.canvas:Tick(true) end
                        Pn:Refresh()
                    end
                    return true
                end
                return false
            end
            Pn.cells[i] = cell
            return cell
        end

        function Pn:Refresh()
            W.Fit(self.status, state.text, (self.w or 300) - Skin.S(16))
            for i = 1, state.count do
                local cell = Cell(i)
                local item = state.list[i]
                if item and item.path then
                    cell.pic:SetTexture(item.path)
                    cell.pic:Show()
                else
                    cell.pic:SetSolidColor('ff0f1113')
                end
                cell.label:SetText(item and ('seed ' .. item.seed .. (item.seed == Graph.Current.seed and '  (current)' or '')) or '')
            end
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            y = W.Flow(group, { { self.bMake, Skin.S(54) }, { self.bPrev, Skin.S(64) }, { self.bNext, Skin.S(54) } }, pad, y, w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(6)
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(20)
            local cell = Skin.S(state.size)
            local cols = math.max(1, math.floor((w - pad) / (cell + pad)))
            self:Refresh()
            for i = 1, state.count do
                local cl = Cell(i)
                local cx = pad + math.mod(i - 1, cols) * (cell + pad)
                local cy = y + math.floor((i - 1) / cols) * (cell + Skin.S(18) + pad)
                W.Place(cl.frame, group, cx, cy, cell, cell + Skin.S(16))
                cl.pic.Left:Set(function() return cl.frame.Left() + 1 end)
                cl.pic.Top:Set(function() return cl.frame.Top() + 1 end)
                cl.pic.Width:Set(cell - 2)
                cl.pic.Height:Set(cell - 2)
                cl.label.Left:Set(function() return cl.frame.Left() + Skin.S(4) end)
                cl.label.Top:Set(function() return cl.frame.Top() + cell + 1 end)
            end
        end

        function Pn:Destroy()
            self.dead = true
        end

        return Pn
    end,
}
