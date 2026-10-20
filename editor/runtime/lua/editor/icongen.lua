-- The unit icon generator (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stage S5).
--
-- A unit icon is the unit as the unit viewer shows it, rendered offscreen by the engine's own renderer (native ed_icon_request, EdIcon.cpp: terrain, sky, water, effects and UI off, the
-- scene drawn once on black and once on white, matted into an RGBA picture), fitted to the picture by its alpha box, reduced to 64 x 64, toned and given the light edge of the shipped icons,
-- and written as a DXT5 DDS (ed_dds_write) into the mod project: modproj/<Name>/textures/ui/common/icons/units/<id>_icon.dds. Compare() measures a render against the icon the game ships.
--
--   Recipe                    the fixed camera / tone / glow recipe (heading, pitch, fov, fill, tone, glow ...); every field can be overridden per call
--   Capture(id, recipe)       RUNS IN A THREAD (it waits for frames, so no pcall around it): stands the unit in the lab spot in the recipe's team colour, fits the camera, renders;
--                             returns { px, w, h, zoom, box, alpha0 } | nil, reason
--   Run(fn)                   forks a thread
--   Shipped(id)               the icon of the game data: { px, w, h, mips, fourcc, bytes } | nil, reason
--   Compare(a, b)             silhouette overlap and colour differences of two { px, w, h } pictures;  DiffImage(a, b) the silhouette difference as a picture
--   Evaluate(ids, recipe)     THREAD: mean Compare over many units;  ToneFit(ids, recipe)  THREAD: brightness / tint per faction
--   Write(project, id, r, mips)   writes the DDS into the project folder; returns the path
--
-- Pixels are flat tables r, g, b, a, r, g, b, a ... (0..255, not premultiplied), row major, top row first. Lua 5.0 dialect.

local View = import('/lua/editor/unitview.lua')
local Bp = import('/lua/editor/bpedit.lua')

Recipe = {
    heading = 3.7, pitch = 0.55, fov = 22,     -- camera (radians / degrees; the engine camera's convention): from the front left above, like the shipped icons. Measured, see the design doc S5
    probe = 256, render = 640, out = 64,       -- render sizes in pixels, icon size
    probeFill = 0.8,                           -- the box of the unit fills this much of the probe so that the final render has room around it
    fill = 0.9,                                -- the box of the part of the unit that is framed fills this much of the icon
    half = true, halfMin = -0.45,               -- frame the front half of the unit (the shipped icons are cut there); halfMin: -1 all .. 0 the front half .. 1 nothing
    -- brightness / tint per faction (ToneFit: the mean of each colour channel of the render matched to the shipped icons of 70 vanilla units)
    tone = {
        UEF = { 2.145, 2.134, 2.108 }, Cybran = { 2.063, 1.855, 1.712 }, Seraphim = { 1.093, 1.115, 1.112 }, Aeon = { 1.144, 1.228, 1.45 },
        default = { 1.477, 1.485, 1.554 },
    },
    teamColor = { 255, 255, 255 },
    teamColors = { UEF = { 150, 158, 172 } },  -- per faction, before `teamColor`: the UEF icons show a grey, not a white, team colour             -- the army colour while the unit is rendered (the shipped icons show the units in light, nearly neutral colours); false keeps the army's own
    -- the map lighting while the unit is rendered, per faction (nil = the map's own): the Aeon units reflect so much of the sun (big glossy highlights) that the shipped icons, which are matte, need a weak sun and more ambient light;
    -- for the other factions that would flatten the surface detail
    lights = { Aeon = { sun_r = 0.25, sun_g = 0.25, sun_b = 0.25, ambient_r = 0.6, ambient_g = 0.6, ambient_b = 0.6, fill_r = 0.7, fill_g = 0.7, fill_b = 0.7 } },
    lut = true, lutFaction = false,            -- lutFaction: { UEF = 'default' } uses the pooled curves for a faction                                -- tone by the measured colour curves per faction (icontone.lua, LutFit); false: the gains below
    glow = 0, glowSoft = 3.5, glowPeak = 0.65,                  -- light edge: solid width and fade width in icon pixels (glow = 0 off)
    toneScale = 0.92, knee = 215, contrast = 0.4,              -- the tone gains times toneScale, then a soft shoulder from `knee` up (highlights roll off to 255 instead of clipping)
}

-- Per kind of unit overrides of the recipe (filled by the tuning of docs/projects/MOD_UNIT_EDITOR_DESIGN.md section 9: Sweep in icontune.lua). Order of precedence: Recipe, then the unit's
-- category here, then the recipe passed to Capture (`noCategory = true` leaves the category out, the tuning needs that).
Recipe.categories = {
    land = { halfMin = -0.7 },                    -- measured alone: IoU 0.613 -> 0.634 (16 units)
    air = { heading = 3.4, fill = 0.8 },          -- 0.489 -> 0.535 (heading) -> 0.558 (fill 0.8)
    naval = { pitch = 0.8 },                      -- 0.471 -> 0.610, tint error 77 -> 30
    structure = { heading = 4.0, halfMin = -1, pitch = 0.8 },  -- 0.572 -> 0.611 (heading 4.0, whole structure framed, pitch 0.8), tint error 29 -> 14
}

Busy = false

--- 'structure' | 'air' | 'naval' | 'land' from the categories of the unit's blueprint.
function Category(id)
    local bp = __blueprints and __blueprints[id]
    local set = {}
    for _, c in bp and bp.Categories or {} do set[c] = true end
    if set.STRUCTURE then return 'structure' end
    if set.AIR then return 'air' end
    if set.NAVAL then return 'naval' end
    return 'land'
end

local function Merge(r, id)
    local out = {}
    for k, v in Recipe do out[k] = v end
    local cat = id and not (r and r.noCategory) and Recipe.categories and Recipe.categories[Category(id)]
    for k, v in cat or {} do out[k] = v end
    for k, v in r or {} do out[k] = v end
    return out
end

--- Forks a thread: the capture functions wait for frames, so they run inside one.
function Run(fn)
    return ForkThread(fn)
end

local function Pending()
    for i = 1, 300 do
        WaitSeconds(0.03)
        local st, msg = ed_icon_status()
        if st ~= 'pending' then return st, msg end
    end
    return 'error', 'timeout'
end

local function Shot(x, y, z, r, zoom, size)
    local ok, why = ed_icon_request(x, y, z, r.heading, r.pitch, zoom, r.fov, size, r.keepMask or 0)
    if not ok then return nil, why end
    local st, msg = Pending()
    if st ~= 'done' then return nil, msg end
    return true
end

local function Ground(x, z)
    if View.Id and x == View.X and z == View.Z then return View.Y0 end          -- the stage's own floor (a ship stands at the water's surface)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

--- The faction name of a unit blueprint ('UEF', 'Aeon', 'Cybran', 'Seraphim'), 'default' when it has none.
function Faction(id)
    local bp = __blueprints and __blueprints[id]
    return bp and bp.General and bp.General.FactionName or 'default'
end

local function TeamColor(color)
    if color then
        SimCallback({ Func = 'EdArmyColor', Args = { army = 'ARMY_1', r = color[1], g = color[2], b = color[3] } }, false)
    else
        local index = 1
        pcall(function()
            local a = import('/lua/editor/armysetup.lua').Get('ARMY_1')
            if a and a.color then index = a.color end
        end)
        SimCallback({ Func = 'EdArmyColor', Args = { army = 'ARMY_1', index = index } }, false)
    end
end

local function CaptureInner(id, r)
    local bp = __blueprints and __blueprints[id]
    if not bp then return nil, 'no such unit' end
    if r.teamColor then
        View.Remove()
        TeamColor(r.teamColor)
        WaitSeconds(0.3)
        -- a mesh the renderer still holds after its unit was taken down (a unit created and destroyed between two frames, which happens while the window is not the active one) would be
        -- fitted instead of the unit: the lab spot must be empty
        local lx, lz = View.LabSpot()
        if Shot(lx, Ground(lx, lz) + 1, lz, { heading = r.heading, pitch = 1.2, fov = 30 }, 40, r.probe) then
            local x0, y0, x1, y1, n = ed_icon_bounds(0.05, 0)
            if n and n > 150 then return nil, 'the lab spot is not empty (a unit left a ghost mesh: reopen the map)' end
        end
    end
    if View.Id ~= id then
        local ok, why = View.Spawn(id)
        if not ok then return nil, why end
        WaitSeconds(0.4)
    end
    local sx, sy, sz = bp.SizeX or 1, bp.SizeY or 1, bp.SizeZ or 1
    local radius = math.max(0.5, 0.5 * math.sqrt(sx * sx + sy * sy + sz * sz))
    local fx, fz = View.X, View.Z
    local fy = Ground(fx, fz) + sy * 0.5
    local zoom = radius * 5
    local rx, rz = -math.cos(r.heading), math.sin(r.heading)         -- the screen's right axis on the ground
    local size = r.probe
    local tries = 0
    for i = 1, 6 do
        local ok, why = Shot(fx, fy, fz, r, zoom, size)
        if not ok then return nil, why end
        local x0, y0, x1, y1, n = ed_icon_bounds(0.05)
        if not x0 then return nil, y0 end
        if n < 8 then
            tries = tries + 1
            if tries > 3 then return nil, 'the unit does not show in the render' end
            zoom = zoom * 1.8
            WaitSeconds(0.3)
        else
            local w, h = x1 - x0 + 1, y1 - y0 + 1
            local cx, cy = (x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2
            local touch = x0 <= 0 or y0 <= 0 or x1 >= size - 1 or y1 >= size - 1
            local sc = size / 512
            local kx = 672 * sc / zoom                              -- pixels per world unit at the focus (measured: docs/projects/MOD_UNIT_EDITOR_DESIGN.md, S5)
            local ky = 540 * math.cos(r.pitch) * sc / zoom
            local ex, ey = cx - size / 2, cy - size / 2
            fx = fx + rx * ex / kx
            fz = fz + rz * ex / kx
            fy = fy - ey / ky
            local ratio = math.max(w, h) / (r.probeFill * size)
            if touch then ratio = math.max(ratio, 1.4) end
            zoom = zoom * ratio
        end
    end
    local ok, why = Shot(fx, fy, fz, r, zoom, r.render)
    if not ok then return nil, why end
    -- a render in which the unit touches the edge is framed too close (its parts are cut off): back off until the whole box is inside, and say so in the log
    for again = 1, 4 do
        local bx0, by0, bx1, by1, bn = ed_icon_bounds(0.05)
        if not bx0 or bn < 8 then break end
        local rs = r.render
        if bx0 > 0 and by0 > 0 and bx1 < rs - 1 and by1 < rs - 1 then break end
        LOG('EDITOR: icon of ' .. tostring(id) .. ' was framed too close (zoom ' .. string.format('%.2f', zoom) .. ', box ' .. bx0 .. ',' .. by0 .. ' - ' .. bx1 .. ',' .. by1 .. ' in ' .. rs .. '): backing off')
        zoom = zoom * 1.5
        ok, why = Shot(fx, fy, fz, r, zoom, r.render)
        if not ok then return nil, why end
    end
    local fdx, fdy = math.sin(r.heading) * 672, -math.cos(r.heading) * 540 * math.sin(r.pitch)      -- where the unit's front (+z) points on the screen
    local x0, y0, x1, y1, n
    if r.half then x0, y0, x1, y1, n = ed_icon_bounds(0.05, 0.1, fdx, fdy, r.halfMin) else x0, y0, x1, y1, n = ed_icon_bounds(0.05) end
    if not x0 or n < 8 then return nil, 'the final render is empty' end
    local w, h = x1 - x0 + 1, y1 - y0 + 1
    local cx, cy = (x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2
    local side = math.max(w, h) / r.fill
    local px, pw, ph = ed_icon_result(r.out, cx, cy, side)
    if not px then return nil, pw end
    local alpha0 = {}
    for i = 0, pw * ph - 1 do alpha0[i] = px[i * 4 + 4] end
    local lut = r.lut and LutOf(id, r.lutFaction)
    if lut then
        ApplyLut(px, pw, ph, lut)
    else
        local tone = r.tone and (r.tone[Faction(id)] or r.tone.default)
        if tone then Tone(px, pw, ph, tone, 0, r.toneScale, r.knee, r.contrast) end
    end
    if (r.glow or 0) > 0 or (r.glowSoft or 0) > 0 then Glow(px, pw, ph, r.glow, r.glowSoft, r.glowPeak) end
    return { px = px, w = pw, h = ph, zoom = zoom, box = { x0, y0, x1, y1 }, focus = { fx, fy, fz }, recipe = r, alpha0 = alpha0 }
end

--- Stands the unit in the lab spot (in the recipe's neutral team colour), fits the camera to it and renders the icon. Must run in a thread. Returns { px, w, h, zoom, box } or nil, reason.
function Capture(id, recipe)
    if Busy then return nil, 'another icon render is running' end        -- two captures at once would fight over the lab spot
    Busy = true
    local r = Merge(recipe, id)
    if r.teamColors and r.teamColors[Faction(id)] then r.teamColor = r.teamColors[Faction(id)] end
    local lightBase
    if r.lights and r.lights[Faction(id)] then r.light = r.lights[Faction(id)] end
    if r.light then
        local now = ed_world_get() or {}
        lightBase = {}
        for k, _ in r.light do lightBase[k] = now[k] end
        ed_world_set(r.light, false)
    end
    View.IconLens(true)
    local res, why = CaptureInner(id, r)          -- (no pcall: the capture waits for frames, and nothing can yield inside one)
    View.IconLens(false)
    if lightBase then ed_world_set(lightBase, false) end
    if r.teamColor then TeamColor(false) end
    Busy = false
    return res, why
end

-- ---- colour curves ---------------------------------------------------------------------------------------------------------------------------------
-- icontone.lua holds one curve per faction and colour channel: 33 knots (inputs 0, 8, ... 256) that map the colour of the render to the colour of the shipped icons (LutFit: histogram matching over the
-- interior pixels of many units, so that contrast, the white team colour areas and the dark shadows come out like the shipped ones).

local lutFile = false

local function LoadLuts()
    if lutFile == false then
        local ok, mod = pcall(import, '/lua/editor/icontone.lua')
        lutFile = ok and mod and mod.Luts or {}
    end
    return lutFile
end

--- The curves of a unit: faction and category ('UEF/air') when the fit had enough units of that kind, else the faction's, else the pooled ones; nil when there are none.
function LutOf(id, map)
    local luts = LoadLuts()
    local f = Faction(id)
    if map and map[f] then f = map[f] end
    return luts[f .. '/' .. Category(id)] or luts[f] or luts.default
end

--- Applies { r = knots, g = knots, b = knots } to the colours.
function ApplyLut(px, w, h, lut)
    local chans = { lut.r, lut.g, lut.b }
    for i = 0, w * h - 1 do
        local k = i * 4
        for c = 1, 3 do
            local v = px[k + c]
            local x = v / 8
            local j = math.floor(x)
            if j > 31 then j = 31 end
            local t = x - j
            local knots = chans[c]
            px[k + c] = knots[j + 1] + (knots[j + 2] - knots[j + 1]) * t
        end
    end
end

local function Interior(alpha, w, h, radius)
    -- pixels that are solid and have no transparent pixel within `radius`
    local out = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local ok = alpha(y * w + x) >= 250
            if ok then
                for dy = -radius, radius do
                    local yy = y + dy
                    if yy < 0 or yy >= h then ok = false break end
                    for dx = -radius, radius do
                        local xx = x + dx
                        if xx < 0 or xx >= w or alpha(yy * w + xx) < 128 then ok = false break end
                    end
                    if not ok then break end
                end
            end
            out[y * w + x] = ok
        end
    end
    return out
end

--- Fits the colour curves (RUNS IN A THREAD): renders the units with no tone, per faction and channel matches the histogram of the colours of the interior pixels to the one of the shipped icons,
--- writes the curves as Lua into `path` (icontone.lua). Returns the number of units used per faction.
function LutFit(ids, recipe, path)
    local rec = {}
    for k, v in recipe or {} do rec[k] = v end
    rec.lut, rec.tone, rec.glow = false, false, 0
    local hist = {}
    local function Hist(f)
        if not hist[f] then
            hist[f] = { n = 0, units = 0, gen = { {}, {}, {} }, ship = { {}, {}, {} } }
            for c = 1, 3 do for v = 0, 255 do hist[f].gen[c][v] = 0 hist[f].ship[c][v] = 0 end end
        end
        return hist[f]
    end
    for _, id in ids do
        if __blueprints[id] then
            local r = Capture(id, rec)
            local s = Shipped(id)
            if r and s and s.w == r.w then
                local ig = Interior(function(i) return r.alpha0[i] end, r.w, r.h, 3)
                local is = Interior(function(i) return s.px[i * 4 + 4] end, s.w, s.h, 3)
                local f = Faction(id)
                local hf, ha, hc = Hist(f), Hist('default'), Hist(f .. '/' .. Category(id))
                hf.units, ha.units, hc.units = hf.units + 1, ha.units + 1, hc.units + 1
                for i = 0, r.w * r.h - 1 do
                    local k = i * 4
                    if ig[i] then
                        for c = 1, 3 do
                            local v = math.floor(math.max(0, math.min(255, r.px[k + c])))
                            hf.gen[c][v] = hf.gen[c][v] + 1 ha.gen[c][v] = ha.gen[c][v] + 1 hc.gen[c][v] = hc.gen[c][v] + 1
                        end
                    end
                    if is[i] then
                        for c = 1, 3 do
                            local v = math.floor(math.max(0, math.min(255, s.px[k + c])))
                            hf.ship[c][v] = hf.ship[c][v] + 1 ha.ship[c][v] = ha.ship[c][v] + 1 hc.ship[c][v] = hc.ship[c][v] + 1
                        end
                    end
                end
            end
        end
    end
    local lines = { '-- Colour curves of the unit icon generator (icongen.lua, LutFit): per faction (and faction / category) and channel 33 knots (inputs 0, 8 .. 256) mapping the render to the shipped icons.', 'Luts = {' }
    local counts = {}
    local names = {}
    -- a faction / category bucket ('UEF/air') needs `minUnits` units (default 3), else the faction's curves serve
    for f, h in hist do
        if not string.find(f, '/', 1, true) or h.units >= (rec.minUnits or 3) then table.insert(names, f) end
    end
    table.sort(names)
    for _, f in names do
        local h = hist[f]
        counts[f] = h.units
        table.insert(lines, "    ['" .. f .. "'] = {")
        for c, cname in { 'r', 'g', 'b' } do
            -- cumulative distributions
            local cg, cs, tg, ts = {}, {}, 0, 0
            for v = 0, 255 do tg = tg + h.gen[c][v] cg[v] = tg ts = ts + h.ship[c][v] cs[v] = ts end
            local knots = {}
            for k = 0, 32 do
                local v = math.min(255, k * 8)
                local q = tg > 0 and cg[v] / tg or 0
                local u = 0
                while u < 255 and cs[u] / math.max(ts, 1) < q do u = u + 1 end
                table.insert(knots, string.format('%d', u))
            end
            -- monotone
            for k = 2, 33 do if tonumber(knots[k]) < tonumber(knots[k - 1]) then knots[k] = knots[k - 1] end end
            table.insert(lines, '        ' .. cname .. ' = { ' .. table.concat(knots, ', ') .. ' },')
        end
        table.insert(lines, '    },')
    end
    table.insert(lines, '}')
    ed_write_file(path, table.concat(lines, string.char(10)) .. string.char(10))
    lutFile = false
    return counts
end

--- Brightness and tint of the unit: colour = colour * gain + bias (0..255); `gain` is one number or { r, g, b }. Alpha untouched. (The renderer's light in the lab map is dimmer and greyer than
--- the shipped icons; ToneFit measures the difference per faction.)
function Tone(px, w, h, gain, bias, scale, knee, contrast)
    local gr, gg, gb = gain, gain, gain
    if type(gain) == 'table' then gr, gg, gb = gain[1], gain[2], gain[3] end
    bias = bias or 0
    scale = scale or 1
    gr, gg, gb = gr * scale, gg * scale, gb * scale
    local function Shoulder(v)
        if v < 0 then return 0 end
        if not knee or v <= knee then return v > 255 and 255 or v end
        return knee + (255 - knee) * (1 - math.exp(-(v - knee) / (255 - knee)))
    end
    -- an S curve on the result: the shipped icons have more contrast (their team colour areas are almost white, their shadows dark)
    local function Curve(v)
        if not contrast or contrast == 0 then return v end
        local x = v / 255
        return 255 * (x + contrast * (x * x * (3 - 2 * x) - x))
    end
    for i = 0, w * h - 1 do
        local k = i * 4
        px[k + 1] = Curve(Shoulder(px[k + 1] * gr + bias))
        px[k + 2] = Curve(Shoulder(px[k + 2] * gg + bias))
        px[k + 3] = Curve(Shoulder(px[k + 3] * gb + bias))
    end
end

--- The light edge of the shipped icons: a white halo around the silhouette (solid for `solid` pixels, then fading out over `soft` pixels), the unit composited over it. Pixels with no
--- coverage get white colour (as the shipped files have; it keeps the block compression clean).
function Glow(px, w, h, solid, soft, peak)
    solid = solid or 3
    soft = soft or 3
    peak = peak or 1
    local reach = math.ceil(solid + soft)
    local ua = {}
    for i = 0, w * h - 1 do ua[i] = px[i * 4 + 4] / 255 end
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local i = y * w + x
            local u = ua[i]
            local d = 99
            if u >= 0.5 then
                d = 0
            else
                for dy = -reach, reach do
                    local yy = y + dy
                    if yy >= 0 and yy < h then
                        for dx = -reach, reach do
                            local xx = x + dx
                            if xx >= 0 and xx < w and ua[yy * w + xx] >= 0.5 then
                                local dist = math.sqrt(dx * dx + dy * dy)
                                if dist < d then d = dist end
                            end
                        end
                    end
                end
            end
            local ha = 0
            if d <= solid then ha = peak elseif d < solid + soft then ha = peak * (1 - (d - solid) / soft) end
            local oa = u + ha * (1 - u)
            local k = i * 4
            if oa > 0 then
                local m = 255 * ha * (1 - u)
                px[k + 1] = (px[k + 1] * u + m) / oa
                px[k + 2] = (px[k + 2] * u + m) / oa
                px[k + 3] = (px[k + 3] * u + m) / oa
                px[k + 4] = oa * 255
            else
                px[k + 1], px[k + 2], px[k + 3], px[k + 4] = 255, 255, 255, 0
            end
        end
    end
end

local function IconPath(id) return '/textures/ui/common/icons/units/' .. string.upper(id) .. '_icon.dds' end

--- The icon of the game data.
function Shipped(id)
    local disk = ed_vfs_to_disk(IconPath(id)) or ed_vfs_to_disk(string.lower(IconPath(id)))
    if not disk then return nil, 'the game has no icon for ' .. id end
    local px, w, h, mips, fourcc, bytes = ed_dds_read(disk)
    if not px then return nil, w end
    return { px = px, w = w, h = h, mips = mips, fourcc = fourcc, bytes = bytes }
end

--- Silhouette overlap (alpha >= 128: intersection over union), box areas, `color` (mean colour difference where both are solid, pixel for pixel: dominated by the details), `alpha` (mean
--- alpha difference), `tint` (difference of the mean colours of the solid pixels of each picture: brightness and tint, independent of the details) and `coarse` (difference of the 8 x 8 block
--- means of premultiplied colour and alpha: tolerant of small shifts). Colour values are 0..255 per channel.
function Compare(a, b)
    if a.w ~= b.w or a.h ~= b.h then return nil, 'different sizes' end
    local inter, union, areaA, areaB, colorSum, colorN, alphaSum = 0, 0, 0, 0, 0, 0, 0
    local mA, mB = { 0, 0, 0 }, { 0, 0, 0 }
    local n = a.w * a.h
    for i = 0, n - 1 do
        local k = i * 4
        local aa, ba = a.px[k + 4], b.px[k + 4]
        local ina, inb = aa >= 128, ba >= 128
        if ina then
            areaA = areaA + 1
            for c = 1, 3 do mA[c] = mA[c] + a.px[k + c] end
        end
        if inb then
            areaB = areaB + 1
            for c = 1, 3 do mB[c] = mB[c] + b.px[k + c] end
        end
        if ina and inb then
            inter = inter + 1
            colorSum = colorSum + (math.abs(a.px[k + 1] - b.px[k + 1]) + math.abs(a.px[k + 2] - b.px[k + 2]) + math.abs(a.px[k + 3] - b.px[k + 3])) / 3
            colorN = colorN + 1
        end
        if ina or inb then union = union + 1 end
        alphaSum = alphaSum + math.abs(aa - ba)
    end
    local tint = 255
    if areaA > 0 and areaB > 0 then
        tint = 0
        for c = 1, 3 do tint = tint + math.abs(mA[c] / areaA - mB[c] / areaB) / 3 end
    end
    local block, coarse, cells = 8, 0, 0
    for by = 0, a.h / block - 1 do
        for bx = 0, a.w / block - 1 do
            local sa, sb = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
            for y = 0, block - 1 do
                for x = 0, block - 1 do
                    local k = ((by * block + y) * a.w + bx * block + x) * 4
                    local wa, wb = a.px[k + 4] / 255, b.px[k + 4] / 255
                    for c = 1, 3 do
                        sa[c] = sa[c] + a.px[k + c] * wa
                        sb[c] = sb[c] + b.px[k + c] * wb
                    end
                    sa[4], sb[4] = sa[4] + a.px[k + 4], sb[4] + b.px[k + 4]
                end
            end
            local d = 0
            for c = 1, 4 do d = d + math.abs(sa[c] - sb[c]) / (block * block) end
            coarse = coarse + d / 4
            cells = cells + 1
        end
    end
    return {
        iou = union > 0 and inter / union or 0,
        areaA = areaA, areaB = areaB,
        color = colorN > 0 and colorSum / colorN or 255,
        alpha = alphaSum / n,
        tint = tint,
        coarse = cells > 0 and coarse / cells or 255,
    }
end

--- Difference picture: grey = both transparent, green = in both, red = only the render, blue = only the shipped icon.
function DiffImage(a, b)
    local px = {}
    for i = 0, a.w * a.h - 1 do
        local k = i * 4
        local ina, inb = a.px[k + 4] >= 128, b.px[k + 4] >= 128
        local r, g, bl, al = 40, 40, 40, 255
        if ina and inb then r, g, bl = 60, 190, 90
        elseif ina then r, g, bl = 220, 70, 60
        elseif inb then r, g, bl = 70, 110, 230 end
        px[k + 1], px[k + 2], px[k + 3], px[k + 4] = r, g, bl, al
    end
    return { px = px, w = a.w, h = a.h }
end

--- Writes the icon into the mod project and returns its path.
function Write(project, id, r, mips)
    local path = Bp.ROOT .. '/' .. project .. '/textures/ui/common/icons/units/' .. string.lower(id) .. '_icon.dds'
    local bytes, why = ed_dds_write(path, r.w, r.h, r.px, mips or 1)
    if not bytes then return nil, why end
    return path, bytes
end

--- Mean Compare of the recipe over a list of unit ids (RUNS IN A THREAD). Returns { iou, color, alpha, tint, coarse, n, per = { id = Compare result } }.
function Evaluate(ids, recipe)
    local sum = { iou = 0, color = 0, alpha = 0, tint = 0, coarse = 0 }
    local n, per, failed = 0, {}, {}
    for _, id in ids do
        if __blueprints[id] then
            local r, why = Capture(id, recipe)
            local s = Shipped(id)
            if r and s then
                local c = Compare(r, s)
                if c then
                    for k, _ in sum do sum[k] = sum[k] + c[k] end
                    n = n + 1
                    per[id] = c
                end
            elseif not r then
                failed[id] = why
            end
        end
    end
    local e = { n = n, per = per, failed = failed }
    for k, v in sum do e[k] = n > 0 and v / n or 255 end
    return e
end

--- Brightness / tint fit (RUNS IN A THREAD): renders the units without tone and, per faction, matches the mean of each colour channel over the pixels that are solid in the render and in the
--- shipped icon (and not the white of its edge halo). Returns { UEF = { gr, gg, gb }, ... default = ... }, { faction = pixel count }.
function ToneFit(ids, recipe)
    local rec = {}
    for k, v in recipe or {} do rec[k] = v end
    rec.tone = false
    local sums = {}
    for _, id in ids do
        if __blueprints[id] then
            local r = Capture(id, rec)
            local s = Shipped(id)
            if r and s and s.w == r.w then
                local f = Faction(id)
                local t = sums[f] or { n = 0, x = { 0, 0, 0 }, y = { 0, 0, 0 } }
                sums[f] = t
                for i = 0, r.w * r.h - 1 do
                    local k = i * 4
                    if r.alpha0[i] >= 250 and s.px[k + 4] >= 250 and (s.px[k + 1] + s.px[k + 2] + s.px[k + 3]) < 705 then
                        t.n = t.n + 1
                        for c = 1, 3 do
                            t.x[c] = t.x[c] + r.px[k + c]
                            t.y[c] = t.y[c] + s.px[k + c]
                        end
                    end
                end
            end
        end
    end
    local tone, counts, all = {}, {}, { n = 0, x = { 0, 0, 0 }, y = { 0, 0, 0 } }
    for f, t in sums do
        counts[f] = t.n
        if t.n > 200 then tone[f] = { t.y[1] / t.x[1], t.y[2] / t.x[2], t.y[3] / t.x[3] } end
        all.n = all.n + t.n
        for c = 1, 3 do all.x[c], all.y[c] = all.x[c] + t.x[c], all.y[c] + t.y[c] end
    end
    if all.n < 200 then return nil, 'too few pixels' end
    tone.default = { all.y[1] / all.x[1], all.y[2] / all.x[2], all.y[3] / all.x[3] }
    return tone, counts
end

-- ---- batch mode ------------------------------------------------------------------------------------------------------------------------------------

--- The units of a mod project that need an icon: the ones its edits, derived units and wizard units name. -> list of ids, sorted.
function ProjectUnits()
    local seen, list = {}, {}
    local function Add(id)
        if not seen[id] then
            seen[id] = true
            table.insert(list, id)
        end
    end
    for _, id in Bp.Edited() do
        if string.sub(id, 1, 1) ~= '/' then Add(id) end
    end
    for id, _ in Bp.Derived do Add(id) end
    for _, id in Bp.NewIds and Bp.NewIds() or {} do Add(id) end
    table.sort(list)
    return list
end

--- RUNS IN A THREAD. Renders and writes the icon of every unit of `ids` (default: ProjectUnits()) into the open project with the recipe of its category; a derived unit that is not in the running game yet is
--- rendered as its base unit (same mesh), a wizard unit that is not in the game (the project has not been tested yet) is skipped with a reason. opts: mips (default 1), recipe, progress(id, i, n).
--- -> { done = list of ids, failed = { id = reason }, skipped = { id = reason }, files = { id = path } }
function Batch(ids, opts)
    opts = opts or {}
    local project = Bp.Project
    local result = { done = {}, failed = {}, skipped = {}, files = {} }
    if not project then
        result.failed['*'] = 'no project open'
        return result
    end
    ids = ids or ProjectUnits()
    local n = table.getn(ids)
    for i, id in ids do
        if opts.progress then opts.progress(id, i, n) end
        local source = id
        if not (__blueprints and __blueprints[id]) then
            if Bp.Derived[id] then
                source = Bp.Derived[id].base
            else
                result.skipped[id] = 'not in the running game: Test the project (Unit wizard, Test) so that the session knows the unit'
            end
        end
        if not result.skipped[id] then
            local r, why = Capture(source, opts.recipe)
            if r then
                local path, bytes = Write(project, id, r, opts.mips or 1)
                if path then
                    table.insert(result.done, id)
                    result.files[id] = path
                else
                    result.failed[id] = tostring(bytes)
                end
            else
                result.failed[id] = tostring(why)
            end
        end
    end
    return result
end
