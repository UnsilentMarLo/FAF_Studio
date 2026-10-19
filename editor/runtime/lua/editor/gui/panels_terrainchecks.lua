-- The Terrain checks panel (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6): runs the checks of terrainchecks.lua (marker validators, ground of the bases, pathing connectivity between all
-- start positions, grades of the paths, symmetry) and lists the problems with their positions: a click moves the camera there. Numbers are sliders (field + slider + minus / plus).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local TC = import('/lua/editor/terrainchecks.lua')

live = {}
local lastRev = -1

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

Panels.Register{
    id = 'terrainchecks', title = 'Terrain checks', minW = 260, minH = 200, stack = { workspace = 'Terrain', with = 'console' },
    create = function(group, host)
        local Pn = {}
        live.checks = Pn
        Pn.group = group
        local c = Skin.color
        local S = TC.Settings
        Pn.all = {}
        Pn.sliders = {}
        Pn.toggles = {}

        local function Btn(text, w, fn, opts)
            local b = W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), function(self) fn(self) end, opts)
            table.insert(Pn.all, b)
            return b
        end
        local function Tog(text, w, key)
            local b = Btn(text, w, function(self) S[key] = self.on Pn:Refresh() end, { toggle = true })
            b:SetOn(S[key] and true or false)
            Pn.toggles[b] = key
            return b
        end
        local function Sld(label, min, max, step, fmt, key)
            local s = W.Slider(group, { label = label, compact = true, min = min, max = max, step = step, fmt = fmt, get = function() return S[key] end,
                set = function(v) S[key] = v Pn:Refresh() end })
            table.insert(Pn.sliders, s)
            return s
        end

        Pn.summary = W.Label(group, '', 0, 0, { color = c.text })
        Pn.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        Pn.bRun = Btn('Run checks', 90, function()
            local ok, err = pcall(TC.Run)
            if not ok then TC.Message = 'checks failed: ' .. tostring(err) end
            Say(TC.Message)
            Pn:Refresh()
        end)
        Pn.layerButtons = { Tog('Land', 54, 'land'), Tog('Hover', 56, 'hover'), Tog('Amphibious', 90, 'amph') }
        Pn.optButtons = { Tog('Marker validators', 120, 'validators'), Tog('Symmetry', 80, 'symmetry'), Tog('Paths', 60, 'paths'), Tog('Auto after edits', 120, 'auto') }
        Pn.grid = {
            Sld('Blocking slope (rise per run)', 0.2, 1.5, 0.01, '%.2f', 'limit'),
            Sld('Unit class (1 small .. 4 experimental)', 1, 4, 1, '%d', 'class'),
            Sld('Land units wade through water up to', 0, 3, 0.1, '%.1f', 'wade'),
            Sld('Base area radius (units)', 3, 30, 1, '%d', 'startRadius'),
            Sld('Blocked share allowed in a base', 0, 0.5, 0.01, '%.2f', 'blockedShare'),
            Sld('Route longer than N x straight is reported', 1, 10, 0.1, '%.1f', 'detour'),
        }
        Pn.list = W.VirtualList(group, {
            rowH = 20, extra = true,
            getCount = function() return table.getn(TC.Issues) end,
            bind = function(row, index)
                local i = TC.Issues[index]
                if not i then return end
                local color = i.sev == 'E' and c.error or (i.sev == 'W' and c.warn or c.textDim)
                local at = (i.x ~= 0 or i.z ~= 0) and string.format('%.0f, %.0f', i.x, i.z) or ''
                row.extra:SetText(at)
                row.extra:SetColor(c.textDim)
                local ew = row.extra.Width()
                W.Fit(row.text, i.text, math.max(Skin.S(60), row.bg.Width() - ew - Skin.S(24)))
                row.text:SetColor(color)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
                row.extra.Left:Set(function() return row.bg.Right() - ew - Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                local i = TC.Issues[index]
                if i and (i.x ~= 0 or i.z ~= 0) then
                    pcall(function() import('/lua/editor/camera.lua').FocusOn(i.x, i.z) end)
                end
            end,
        })

        function Pn:Refresh()
            local maxW = (self.w or 300) - Skin.S(16)
            local e, w, i = TC.Summary()
            W.Fit(self.summary, TC.Info.lastRun and string.format('%d error(s), %d warning(s), %d note(s)', e, w, i) or 'not run yet', maxW)
            W.Fit(self.status, TC.Message, maxW)
            for b, key in self.toggles do b:SetOn(S[key] and true or false) end
            for _, s in self.sliders do s:Refresh() end
            self.list:Refresh()
        end

        function Pn:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            W.BeginLayout(group)
            local function Flow(buttons)
                local bx = pad
                for _, b in buttons do
                    local bw = b.Width()
                    if bx > pad and bx + bw > w - pad then
                        bx = pad
                        y = y + Skin.S(26)
                    end
                    W.Place(b, group, bx, y, bw, Skin.S(22))
                    bx = bx + bw + Skin.S(4)
                end
                y = y + Skin.S(26)
            end
            Flow({ self.bRun })
            W.Place(self.summary, group, pad, y)
            y = y + Skin.S(20)
            W.Place(self.status, group, pad, y)
            y = y + Skin.S(22)
            Flow(self.layerButtons)
            Flow(self.optButtons)
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(190) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            local i, rows = 0, 0
            for _, sl in self.grid do
                local col = math.mod(i, cols)
                local row = math.floor(i / cols)
                sl:Place(pad + col * (colW + pad), y + row * Skin.S(46), colW)
                rows = row + 1
                i = i + 1
            end
            y = y + rows * Skin.S(46) + Skin.S(4)
            self.list:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(60), h - y - pad))
            W.EndLayout(group)
            self:Refresh()
        end

        function Pn:Destroy()
            live.checks = nil
        end

        return Pn
    end,
}

--- Module level tick: the validators' late answer, Auto runs, and a redraw of the list when the issues changed.
function Refresh()
    TC.Tick()
    local Pn = live.checks
    if Pn and TC.Revision ~= lastRev then
        lastRev = TC.Revision
        Pn:Refresh()
    end
end
