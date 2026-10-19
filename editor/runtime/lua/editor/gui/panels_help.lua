-- The Help panel (F1): a search field and the list of topics; a click opens a topic as formatted text, Back returns to the list. The panel scrolls with the mouse wheel like
-- every panel. Content: help.lua (topics from editor/help/*.md, the shortcut cheat sheet and the tools list generated from the running editor).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Help = import('/lua/editor/help.lua')

live = {}

--- Takes over what Help.Open asked for (a topic, a search) into the showing panel.
function Apply()
    local P = live.help
    if P and P.Apply then P:Apply() end
end

Panels.Register{
    id = 'help', title = 'Help',
    create = function(group, host)
        local P = { view = 'home', topic = false, query = '', results = {}, texts = {}, w = 300, h = 300 }
        live.help = P
        local c = Skin.color

        P.back = W.Button(group, 'Back', 0, 0, Skin.S(60), Skin.S(22), function() P:Home() end)
        P.field = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function(text) P.query = text P:Search() end })
        P.hint = W.Label(group, 'Search the help', 0, 0, { color = c.textDim, size = 'small' })
        P.list = W.VirtualList(group, {
            rowH = 40,
            extra = true,
            getCount = function() return table.getn(P.results) end,
            bind = function(row, index)
                local r = P.results[index]
                local t = r.topic
                W.Fit(row.text, t.title, math.max(Skin.S(40), row.bg.Width() - Skin.S(20)))
                row.text:SetColor(c.text)
                W.Fit(row.extra, t.summary or '', math.max(Skin.S(40), row.bg.Width() - Skin.S(20)))
                row.extra:SetColor(c.textDim)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.text.Top:Set(function() return row.bg.Top() + Skin.S(4) end)
                row.extra.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
                row.extra.Top:Set(function() return row.bg.Top() + Skin.S(21) end)
            end,
            onSelect = function(index)
                local r = P.results[index]
                if r then P:Open(r.topic.id) end
            end,
            bgColor = c.panel,
        })

        function P:Clear()
            for _, l in self.texts do l:Destroy() end
            self.texts = {}
        end

        function P:Search()
            self.results = Help.Search(self.query)
            self.hint:SetText(self.query == '' and 'Search the help' or (table.getn(self.results) .. ' topics'))
            if self.view == 'topic' then self.view = 'home' end
            self:Layout()
        end

        function P:Home()
            self.view = 'home'
            self:Layout()
        end

        function P:Open(id)
            local topic = Help.Find(id)
            if not topic then return end
            self.view = 'topic'
            self.topic = topic
            self:Layout()
        end

        --- A Help.Open request: a topic, or a search.
        function P:Apply()
            local p = Help.Pending
            if not p then return end
            Help.Pending = false
            if p.query and p.query ~= '' then
                self.query = p.query
                self.field:SetText(p.query)
                self.results = Help.Search(p.query)
                self.view = 'home'
            end
            if p.topic then
                self.view = 'topic'
                self.topic = Help.Find(p.topic) or self.topic
            end
            self:Layout()
        end

        local function Text(topic, x, y, maxW, opts, lineH)
            local labels, below = W.Paragraph(group, topic, x, y, maxW, opts, lineH)
            for _, l in labels do table.insert(P.texts, l) end
            return below
        end

        function P:Layout()
            local pad = Skin.S(10)
            local w = self.w
            self:Clear()
            W.BeginLayout(group)
            local top = pad
            if self.view == 'topic' then
                W.Place(self.back, group, pad, top, Skin.S(60), Skin.S(22))
                W.Place(self.field.frame, group, pad + Skin.S(68), top, math.max(Skin.S(60), w - 2 * pad - Skin.S(68)), Skin.S(22))
                self.field.Width:Set(math.max(Skin.S(60), w - 2 * pad - Skin.S(68)) - 2)
                W.Place(self.hint, group, -20000, -20000)
                self.list:SetRect(-20000, -20000, 10, 10)
                local y = top + Skin.S(36)
                local topic = self.topic
                local title = W.Label(group, topic.title, pad, y, { size = 16 })
                table.insert(self.texts, title)
                y = y + Skin.S(30)
                local labelW = w - 2 * pad - Skin.S(10)
                for _, b in topic.blocks do
                    local kind = b[1]
                    if kind == 'h' then
                        y = y + Skin.S(10)
                        table.insert(self.texts, W.Label(group, b[2], pad, y, { color = c.accent, size = 14 }))
                        y = y + Skin.S(24)
                    elseif kind == 'p' then
                        y = Text(b[2], pad, y, labelW, { color = c.text }, Skin.S(18)) + Skin.S(8)
                    elseif kind == 'li' then
                        table.insert(self.texts, W.Label(group, '-', pad + Skin.S(4), y, { color = c.textDim }))
                        y = Text(b[2], pad + Skin.S(18), y, labelW - Skin.S(18), { color = c.text }, Skin.S(18)) + Skin.S(4)
                    elseif kind == 'step' then
                        table.insert(self.texts, W.Label(group, tostring(b[3]) .. '.', pad + Skin.S(2), y, { color = c.accent }))
                        y = Text(b[2], pad + Skin.S(22), y, labelW - Skin.S(22), { color = c.text }, Skin.S(18)) + Skin.S(4)
                    elseif kind == 'kv' then
                        local left = W.Label(group, b[2], pad + Skin.S(4), y, { color = c.text })
                        local split = math.floor(w * 0.52)
                        W.Fit(left, b[2], split - pad - Skin.S(12))
                        local right = W.Label(group, b[3], split, y, { color = c.textDim })
                        W.Fit(right, b[3], w - split - pad)
                        table.insert(self.texts, left)
                        table.insert(self.texts, right)
                        y = y + Skin.S(20)
                    end
                end
            else
                W.Place(self.back, group, -20000, -20000)
                W.Place(self.field.frame, group, pad, top, w - 2 * pad, Skin.S(22))
                self.field.Width:Set(w - 2 * pad - 2)
                W.Place(self.hint, group, pad, top + Skin.S(26))
                local y = top + Skin.S(46)
                self.list:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(80), self.h - y - pad))
            end
            W.EndLayout(group)
        end

        function P:OnResize(w, h)
            self.w, self.h = w, h
            if table.getn(self.results) == 0 and self.query == '' then self.results = Help.Search('') end
            self:Apply()
            self:Layout()
        end
        function P:Refresh() end
        return P
    end,
}
