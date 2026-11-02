-- A small panel builder for the environment panels (sky, water motion, imager, cube maps): a panel is a list of rows, every number is a slider with - / + buttons and a field.
--
--   Build{ id, title, rows, stack = { workspace = 'Environment', with = 'lighting' }, minW, minH }   registers the panel
--
-- Rows (tables, the first entry is the kind):
--   { 'single', label, min, max, step, fmt, get, set }                         a slider
--   { 'group', { label, min, max, step, fmt, get, set }, ... }                 two or three compact sliders in one row
--   { 'toggle', label, get, set }                                              an on / off button
--   { 'section', title }                                                       a heading
--   { 'note', function() -> text }                                             a dim line (refreshed with the panel)
--   { 'texture', label, name, sources, opts }                                  a texture slot of environment.lua (Text(name) / SetText): shows the file, "Change..." opens the browser
--                                                                              opts: none = text of a "no texture" entry, thumbs = false for cube maps, match = function(path)
--   { 'buttons', { text, width, fn }, ... }                                    a row of buttons
--
-- The panel follows environment.lua and world.lua changes (undo and redo included): every row re-reads its values.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Env = import('/lua/editor/environment.lua')
local World = import('/lua/editor/world.lua')
local Picker = import('/lua/editor/gui/texpicker.lua')

live = {}

local function ShortName(path)
    if not path or path == '' then return '(none)' end
    return (string.gsub(path, '^.*/', ''))
end

--- A number of environment.lua as a slider entry: { label, min, max, step, fmt, get, set }.
function Num(label, name, min, max, step, fmt)
    return { label, min, max, step or 0.01, fmt or '%.2f',
        function() return Env.Value(name) end,
        function(v) Env.SetNumber(name, v, label) end }
end

function Build(def)
    local id = def.id
    Panels.Register{
        id = id, title = def.title, minW = def.minW, minH = def.minH, stack = def.stack,
        create = function(group, host)
            local P = { rows = {}, w = 240, h = 300 }
            live[id] = P
            for _, r in def.rows do
                local kind = r[1]
                local row = { kind = kind, def = r }
                if kind == 'single' then
                    row.s = W.Slider(group, { label = r[2], min = r[3], max = r[4], step = r[5], fmt = r[6], get = r[7], set = r[8] })
                elseif kind == 'group' then
                    row.list = {}
                    for i = 2, table.getn(r) do
                        local o = r[i]
                        table.insert(row.list, W.Slider(group, { label = o[1], min = o[2], max = o[3], step = o[4], fmt = o[5], get = o[6], set = o[7], compact = true }))
                    end
                elseif kind == 'toggle' then
                    local setter = r[4]
                    row.b = W.Button(group, r[2], 0, 0, Skin.S(170), Skin.S(24), function(self) setter(self.on) end, { toggle = true })
                elseif kind == 'section' then
                    row.label = W.Label(group, r[2], 0, 0, { color = Skin.color.text })
                elseif kind == 'note' then
                    row.label = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
                elseif kind == 'texture' then
                    local name, sources, opts = r[3], r[4], r[5] or {}
                    row.label = W.Label(group, r[2], 0, 0, { color = Skin.color.textDim })
                    row.file = W.Label(group, '', 0, 0, { color = Skin.color.text, size = 'small' })
                    row.b = W.Button(group, 'Change...', 0, 0, Skin.S(80), Skin.S(22), function()
                        Picker.Open{ title = r[2], sources = sources, none = opts.none, thumbs = opts.thumbs, match = opts.match, current = Env.Text(name),
                            done = function(path)
                                if path == Picker.NONE then path = '' end
                                Env.SetText(name, path, r[2])
                            end }
                    end)
                elseif kind == 'buttons' then
                    row.bs = {}
                    for i = 2, table.getn(r) do
                        local o = r[i]
                        table.insert(row.bs, W.Button(group, o[1], 0, 0, Skin.S(o[2]), Skin.S(24), o[3]))
                    end
                end
                table.insert(P.rows, row)
            end

            function P:Refresh()
                for _, row in self.rows do
                    local kind = row.kind
                    if kind == 'single' then
                        row.s:Refresh()
                    elseif kind == 'group' then
                        for _, s in row.list do s:Refresh() end
                    elseif kind == 'toggle' then
                        row.b:SetOn(row.def[3]())
                    elseif kind == 'note' then
                        W.Fit(row.label, row.def[2](), (self.w or 300) - Skin.S(20))
                    elseif kind == 'texture' then
                        W.Fit(row.file, ShortName(Env.Text(row.def[3])), (self.w or 300) - Skin.S(130))
                    end
                end
            end

            function P:OnResize(w, h)
                if not w then return end
                self.w, self.h = w, h
                local pad = Skin.S(10)
                local y = pad
                for _, row in self.rows do
                    local kind = row.kind
                    if kind == 'single' then
                        row.s:Place(pad, y, w - 2 * pad)
                        y = y + Skin.S(52)
                    elseif kind == 'group' then
                        local n = table.getn(row.list)
                        local cw = math.floor((w - 2 * pad - (n - 1) * pad) / n)
                        for i, s in row.list do s:Place(pad + (i - 1) * (cw + pad), y, cw) end
                        y = y + Skin.S(52)
                    elseif kind == 'toggle' then
                        W.Place(row.b, group, pad, y, Skin.S(170), Skin.S(24))
                        y = y + Skin.S(32)
                    elseif kind == 'section' then
                        y = y + Skin.S(6)
                        W.Place(row.label, group, pad, y)
                        y = y + Skin.S(24)
                    elseif kind == 'note' then
                        W.Place(row.label, group, pad, y)
                        y = y + Skin.S(20)
                    elseif kind == 'texture' then
                        row.label.fitCap = math.max(Skin.S(40), w - 2 * pad - Skin.S(80) - Skin.S(8))        -- (the label stops before the Change button)
                        W.Place(row.label, group, pad, y)
                        W.Place(row.file, group, pad, y + Skin.S(18))
                        W.Place(row.b, group, w - pad - Skin.S(80), y + Skin.S(6), Skin.S(80), Skin.S(22))
                        y = y + Skin.S(44)
                    elseif kind == 'buttons' then
                        local bx = pad
                        for _, b in row.bs do
                            local bw = b.Width()
                            if bx > pad and bx + bw > w - pad then
                                bx = pad
                                y = y + Skin.S(28)
                            end
                            W.Place(b, group, bx, y, bw, Skin.S(24))
                            bx = bx + bw + Skin.S(4)
                        end
                        y = y + Skin.S(32)
                    end
                end
                self:Refresh()
            end

            local function Follow() if live[id] == P then pcall(P.Refresh, P) end end
            Env.Listen(Follow)
            World.Listen(Follow)
            return P
        end,
    }
end
