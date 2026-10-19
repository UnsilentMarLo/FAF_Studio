-- The Sky objects panel: the sun, moon and planet billboards of the sky dome (what the engine calls the sky decals, up to 1024 of them). Each is a square of the billboard atlas (Sky textures) at a direction
-- and distance from the dome centre, with a size and a rotation. The list, Add / Duplicate / Delete and the sliders edit environment.lua's billboards; the engine draws them at once and writes them to
-- the .scmap. "Sun direction" turns the selected billboard towards the sun of the lighting. Every change is an undo step (a drag is one).
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Env = import('/lua/editor/environment.lua')
local World = import('/lua/editor/world.lua')

live = {}
state = { sel = 1 }

local function List() return Env.Billboards() end

local function Selected()
    local list = List()
    return list[state.sel], list
end

--- A billboard lies on the dome: its position is absolute, on a sphere around the dome origin. Direction (azimuth 0..360 from +x towards +z, elevation -90..90) and distance from that origin.
local function Origin() return Env.Value('dome_ox'), Env.Value('dome_oy'), Env.Value('dome_oz') end

local function Polar(b)
    local ox, oy, oz = Origin()
    local x, y, z = b.x - ox, b.y - oy, b.z - oz
    local d = math.sqrt(x * x + y * y + z * z)
    if d < 0.0001 then return 0, 45, 1000 end
    local az = math.deg(math.atan2(z, x))
    if az < 0 then az = az + 360 end
    return az, math.deg(math.asin(y / d)), d
end

local function FromPolar(b, az, el, d)
    local a, e = math.rad(az), math.rad(el)
    local ox, oy, oz = Origin()
    b.x, b.y, b.z = ox + d * math.cos(e) * math.cos(a), oy + d * math.sin(e), oz + d * math.cos(e) * math.sin(a)
end

--- Changes the selected billboard with fn(b) and applies the whole list (one merged undo step per slider).
local function Edit(label, key, fn)
    local b, list = Selected()
    if not b then return end
    fn(b)
    Env.Apply({ billboards = Env.FlatBillboards(list) }, { label = label, merge = 'bb' .. state.sel .. key })
end

Panels.Register{
    id = 'skyobjects', title = 'Sky objects', minW = 240, minH = 200, stack = { workspace = 'Environment', with = 'lighting' },
    create = function(group, host)
        local P = { sliders = {}, w = 240, h = 300 }
        live.skyobjects = P
        local c = Skin.color

        local function Btn(text, w, fn) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(24), fn) end

        P.list = W.VirtualList(group, {
            rowH = 20,
            getCount = function() return table.getn(List()) end,
            bind = function(row, index)
                local b = List()[index]
                local az, el, d = Polar(b)
                local text = string.format('%d.  az %d  el %d  size %d  cell %.2f / %.2f', index, math.floor(az + 0.5), math.floor(el + 0.5), math.floor(b.sx + 0.5), b.u, b.v)
                W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(12)))
                row.text:SetColor(index == state.sel and c.accent or c.text)
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            bgColor = c.panelAlt,
            onSelect = function(index)
                state.sel = index
                P:Refresh()
            end,
        })

        P.bAdd = Btn('Add', 44, function()
            local list = List()
            local az, el = World.SunAngles()
            local b = { x = 0, y = 0, z = 0, rot = 0, sx = 40, sy = 40, u = 0, v = 0.5, du = 0.5, dv = 0.5 }
            FromPolar(b, az, math.max(10, el), math.max(100, Env.Value('dome_radius')))
            table.insert(list, b)
            state.sel = table.getn(list)
            Env.Apply({ billboards = Env.FlatBillboards(list) }, { label = 'add sky billboard' })
        end)
        P.bCopy = Btn('Duplicate', 70, function()
            local b, list = Selected()
            if not b then return end
            local n = {}
            for k, v in b do n[k] = v end
            n.x, n.z = n.x * 0.97, n.z * 1.03
            table.insert(list, n)
            state.sel = table.getn(list)
            Env.Apply({ billboards = Env.FlatBillboards(list) }, { label = 'duplicate sky billboard' })
        end)
        P.bDel = Btn('Delete', 54, function()
            local b, list = Selected()
            if not b then return end
            table.remove(list, state.sel)
            state.sel = math.max(1, math.min(state.sel, table.getn(list)))
            Env.Apply({ billboards = Env.FlatBillboards(list) }, { label = 'delete sky billboard' })
        end)
        P.bSun = Btn('Sun direction', 90, function()
            local az, el = World.SunAngles()
            Edit('billboard to the sun', 'sun', function(b)
                local _, _, d = Polar(b)
                FromPolar(b, az, el, d)
            end)
        end)

        P.info = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })
        P.atlas = Bitmap(group)
        P.atlas:SetSolidColor(c.panelAlt)
        P.atlas:DisableHitTest()
        P.atlasFrame = Bitmap(group)
        P.atlasFrame:SetSolidColor(c.panelAlt)
        P.atlasFrame.Depth:Set(function() return group.Depth() + 4 end)
        P.atlas.Depth:Set(function() return group.Depth() + 6 end)

        local function Slider(label, min, max, step, fmt, get, set)
            local s = W.Slider(group, { label = label, compact = true, min = min, max = max, step = step, fmt = fmt, get = get, set = set })
            table.insert(P.sliders, s)
            return s
        end
        local function Val(fn, default)
            return function()
                local b = Selected()
                if not b then return default end
                return fn(b)
            end
        end
        Slider('Azimuth (degrees)', 0, 360, 1, '%d', Val(function(b) local az = Polar(b) return az end, 0),
            function(v) Edit('billboard azimuth', 'az', function(b) local _, el, d = Polar(b) FromPolar(b, v, el, d) end) end)
        Slider('Elevation (degrees)', -20, 90, 1, '%d', Val(function(b) local _, el = Polar(b) return el end, 0),
            function(v) Edit('billboard elevation', 'el', function(b) local az, _, d = Polar(b) FromPolar(b, az, v, d) end) end)
        Slider('Distance from the dome centre', 50, 40000, 10, '%d', Val(function(b) local _, _, d = Polar(b) return d end, 1000),
            function(v) Edit('billboard distance', 'dist', function(b) local az, el = Polar(b) FromPolar(b, az, el, v) end) end)
        Slider('Rotation (degrees)', -180, 180, 1, '%d', Val(function(b) return math.deg(b.rot) end, 0),
            function(v) Edit('billboard rotation', 'rot', function(b) b.rot = math.rad(v) end) end)
        Slider('Width', 1, 1000, 1, '%d', Val(function(b) return b.sx end, 40), function(v) Edit('billboard width', 'sx', function(b) b.sx = v end) end)
        Slider('Height', 1, 1000, 1, '%d', Val(function(b) return b.sy end, 40), function(v) Edit('billboard height', 'sy', function(b) b.sy = v end) end)
        Slider('Atlas cell left', 0, 1, 0.05, '%.2f', Val(function(b) return b.u end, 0), function(v) Edit('billboard atlas', 'u', function(b) b.u = v end) end)
        Slider('Atlas cell top', 0, 1, 0.05, '%.2f', Val(function(b) return b.v end, 0), function(v) Edit('billboard atlas', 'v', function(b) b.v = v end) end)
        Slider('Cell width', 0.05, 1, 0.05, '%.2f', Val(function(b) return b.du end, 0.5), function(v) Edit('billboard atlas', 'du', function(b) b.du = v end) end)
        Slider('Cell height', 0.05, 1, 0.05, '%.2f', Val(function(b) return b.dv end, 0.5), function(v) Edit('billboard atlas', 'dv', function(b) b.dv = v end) end)

        function P:Refresh()
            if state.sel > table.getn(List()) then state.sel = math.max(1, table.getn(List())) end
            self.list:Refresh()
            for _, s in self.sliders do s:Refresh() end
            local atlas = Env.Text('sky_billboards')
            if atlas ~= '' and atlas ~= self.shownAtlas then
                self.shownAtlas = atlas
                self.atlas:SetTexture(atlas)
            end
            W.Fit(self.info, string.format('%d billboards (at most 1024). Atlas: %s', table.getn(List()), atlas ~= '' and (string.gsub(atlas, '^.*/', '')) or 'none (pick one in Sky textures)'), (self.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            if not w then return end
            self.w, self.h = w, h
            local pad = Skin.S(8)
            local y = pad
            self.list:SetRect(pad, y, w - 2 * pad, Skin.S(20 * 6))
            y = y + Skin.S(20 * 6) + pad
            local bx = pad
            for _, b in { self.bAdd, self.bCopy, self.bDel, self.bSun } do
                local bw = b.Width()
                if bx > pad and bx + bw > w - pad then bx = pad y = y + Skin.S(28) end
                W.Place(b, group, bx, y, bw, Skin.S(24))
                bx = bx + bw + Skin.S(4)
            end
            y = y + Skin.S(32)
            local cols = math.max(1, math.floor((w - 2 * pad + pad) / (Skin.S(200) + pad)))
            local colW = math.floor((w - 2 * pad - (cols - 1) * pad) / cols)
            for i, s in self.sliders do
                s:Place(pad + math.mod(i - 1, cols) * (colW + pad), y + math.floor((i - 1) / cols) * Skin.S(46), colW)
            end
            y = y + math.ceil(table.getn(self.sliders) / cols) * Skin.S(46) + Skin.S(4)
            local size = Skin.S(128)
            W.Place(self.atlasFrame, group, pad, y, size, size)
            W.Place(self.atlas, group, pad, y, size, size)
            W.Place(self.info, group, pad + size + pad, y)
            self.shownAtlas = nil
            self:Refresh()
        end

        local function Follow() if live.skyobjects == P then pcall(P.Refresh, P) end end
        Env.Listen(Follow)
        World.Listen(Follow)
        return P
    end,
}
