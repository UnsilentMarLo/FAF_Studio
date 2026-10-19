-- The Environment workspace's panels: Lighting (sun, bloom), Ambient and fog, Water, Water look. Every number is a slider with - / + buttons and
-- a field (compact: bar and field only, when several share a row). Values come from world.lua (engine: EdWorld.cpp); a change is one undo
-- entry per drag.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local World = import('/lua/editor/world.lua')

live = {}

--- Builds a panel from a list of rows:
---   { 'single', label, min, max, step, fmt, get, set }
---   { 'group', { label, min, max, step, fmt, get, set }, { ... }, ... }      two or three compact sliders in one row
---   { 'toggle', label, get, set }
local function Build(id, title, rows)
    Panels.Register{
        id = id, title = title,
        create = function(group, host)
            local P = { rows = {} }
            live[id] = P
            for _, r in rows do
                local kind = r[1]
                if kind == 'single' then
                    local s = W.Slider(group, { label = r[2], min = r[3], max = r[4], step = r[5], fmt = r[6], get = r[7], set = r[8] })
                    table.insert(P.rows, { kind = 'single', s = s })
                elseif kind == 'group' then
                    local list = {}
                    for i = 2, table.getn(r) do
                        local o = r[i]
                        table.insert(list, W.Slider(group, { label = o[1], min = o[2], max = o[3], step = o[4], fmt = o[5], get = o[6], set = o[7], compact = true }))
                    end
                    table.insert(P.rows, { kind = 'group', list = list })
                elseif kind == 'toggle' then
                    local setter = r[4]
                    local b = W.Button(group, r[2], 0, 0, Skin.S(150), Skin.S(24), function(self)
                        setter(self.on)
                    end, { toggle = true })
                    table.insert(P.rows, { kind = 'toggle', b = b, get = r[3] })
                end
            end

            function P:Refresh()
                for _, r in P.rows do
                    if r.kind == 'single' then
                        r.s:Refresh()
                    elseif r.kind == 'group' then
                        for _, s in r.list do s:Refresh() end
                    else
                        r.b:SetOn(r.get())
                    end
                end
            end

            function P:OnResize(w, h)
                local pad = Skin.S(10)
                local y = pad
                for _, r in P.rows do
                    if r.kind == 'single' then
                        r.s:Place(pad, y, w - 2 * pad)
                        y = y + Skin.S(52)
                    elseif r.kind == 'group' then
                        local n = table.getn(r.list)
                        local cw = math.floor((w - 2 * pad - (n - 1) * pad) / n)
                        for i, s in r.list do
                            s:Place(pad + (i - 1) * (cw + pad), y, cw)
                        end
                        y = y + Skin.S(52)
                    else
                        W.Place(r.b, group, pad, y, Skin.S(150), Skin.S(24))
                        y = y + Skin.S(32)
                    end
                end
                P:Refresh()
            end

            World.Listen(function() if live[id] == P then pcall(P.Refresh, P) end end)
            return P
        end,
    }
end

--- A slider entry for one engine number: { label, min, max, step, fmt, get, set }.
local function Num(label, name, min, max, step, fmt, refresh)
    return { label, min, max, step or 0.01, fmt or '%.2f',
        function() return World.Value(name) end,
        function(v)
            local f = {}
            f[name] = v
            World.Change(f, { label = label, merge = name, refresh = refresh })
        end }
end

local function Single(e)
    return { 'single', e[1], e[2], e[3], e[4], e[5], e[6], e[7] }
end

local function Group(a, b, c)
    return { 'group', a, b, c }
end

-- ---- Lighting -------------------------------------------------------------------------------------------------------------------------------

Build('lighting', 'Lighting', {
    { 'single', 'Sun azimuth (degrees)', 0, 360, 1, '%d',
        function() local az = World.SunAngles() return az end,
        function(v) local _, el = World.SunAngles() World.SetSunAngles(v, el, 'sun_az') end },
    { 'single', 'Sun elevation (degrees)', -90, 90, 1, '%d',
        function() local _, el = World.SunAngles() return el end,
        function(v) local az = World.SunAngles() World.SetSunAngles(az, v, 'sun_el') end },
    Single(Num('Lighting multiplier', 'light_mult', 0, 4, 0.05)),
    Single(Num('Bloom', 'bloom', 0, 1, 0.01)),
    Group(Num('Sun R', 'sun_r', 0, 2), Num('Sun G', 'sun_g', 0, 2), Num('Sun B', 'sun_b', 0, 2)),
})

-- ---- Ambient and fog ------------------------------------------------------------------------------------------------------------------------

Build('ambient', 'Ambient and fog', {
    Group(Num('Ambient R', 'ambient_r', 0, 2), Num('Ambient G', 'ambient_g', 0, 2), Num('Ambient B', 'ambient_b', 0, 2)),
    Group(Num('Shadow fill R', 'fill_r', 0, 2), Num('Shadow fill G', 'fill_g', 0, 2), Num('Shadow fill B', 'fill_b', 0, 2)),
    Group(Num('Fog R', 'fog_r', 0, 1), Num('Fog G', 'fog_g', 0, 1), Num('Fog B', 'fog_b', 0, 1)),
    Group(Num('Fog start', 'fog_start', 0, 4000, 10, '%d'), Num('Fog end', 'fog_end', 0, 8000, 10, '%d')),
})

-- ---- Water ----------------------------------------------------------------------------------------------------------------------------------

Build('water', 'Water', {
    { 'toggle', 'Water', function() return World.Value('water_on') ~= 0 end,
        function(on) World.Change({ water_on = on and 1 or 0 }, { label = 'water', refresh = true }) end },
    Single(Num('Surface elevation', 'water_elev', 0, 512, 0.5, '%.1f', true)),
    Single(Num('Deep water elevation', 'water_deep', 0, 512, 0.5, '%.1f', true)),
    Single(Num('Abyss elevation', 'water_abyss', 0, 512, 0.5, '%.1f', true)),
})

-- ---- Water look -----------------------------------------------------------------------------------------------------------------------------

Build('waterlook', 'Water look', {
    Group(Num('Color R', 'w_color_r', 0, 2), Num('Color G', 'w_color_g', 0, 2), Num('Color B', 'w_color_b', 0, 2)),
    Group(Num('Color lerp near', 'w_lerp_0', 0, 1), Num('Color lerp far', 'w_lerp_1', 0, 1)),
    Group(Num('Refraction', 'w_refraction', 0, 1), Num('Fresnel bias', 'w_fresnel_bias', 0, 1), Num('Fresnel power', 'w_fresnel_power', 0, 8, 0.05)),
    Group(Num('Sky reflection', 'w_sky_refl', 0, 4, 0.05), Num('Unit reflection', 'w_unit_refl', 0, 4, 0.05)),
    Group(Num('Sun shininess', 'w_shininess', 0, 200, 1, '%d'), Num('Sun reflection', 'w_sun_refl', 0, 20, 0.1, '%.1f'), Num('Sun glow', 'w_glow', 0, 1)),
    Group(Num('Sun R', 'w_suncol_r', 0, 2), Num('Sun G', 'w_suncol_g', 0, 2), Num('Sun B', 'w_suncol_b', 0, 2)),
    Group(Num('Wave 1 scale', 'w_repeat_0', 0, 0.2, 0.001, '%.3f'), Num('Wave 2 scale', 'w_repeat_1', 0, 0.2, 0.001, '%.3f')),
    Group(Num('Wave 3 scale', 'w_repeat_2', 0, 0.2, 0.001, '%.3f'), Num('Wave 4 scale', 'w_repeat_3', 0, 0.2, 0.001, '%.3f')),
})
