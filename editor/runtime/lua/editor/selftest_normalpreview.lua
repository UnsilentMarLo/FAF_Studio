-- Self test of the normal map relief pictures (normalpreview.lua): a flat synthetic normal map gives one uniform grey, slopes are shaded by their direction to the light, the DXT5nm style layout
-- is recognised and gives the same picture, and (when the natives exist) Preview() writes a 128 x 128 picture once and finds it again.
-- Run in the live editor:
--   return import('/lua/editor/selftest_normalpreview.lua').Run()
-- Returns a report; the first line is PASS or FAIL.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local NP = import('/lua/editor/normalpreview.lua')

--- A w x h normal map: fn(x, y) -> nx, ny (z is rebuilt), stored as RGB (x, y, z) or, when `ag`, as DXT5nm (red 255, green y, blue 0, alpha x).
local function Synth(w, h, fn, ag)
    local px = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local nx, ny = fn(x, y)
            local nz = math.sqrt(math.max(0, 1 - nx * nx - ny * ny))
            local o = (y * w + x) * 4
            local ex, ey, ez = (nx + 1) * 127.5, (ny + 1) * 127.5, (nz + 1) * 127.5
            if ag then
                px[o + 1], px[o + 2], px[o + 3], px[o + 4] = 255, ey, 0, ex
            else
                px[o + 1], px[o + 2], px[o + 3], px[o + 4] = ex, ey, ez, 255
            end
        end
    end
    return px
end

local function Grey(out, w, x, y) return out[(y * w + x) * 4 + 1] end

function Run()
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end

    local w, h = 24, 8
    -- flat everywhere: one uniform mid grey
    local flat = Synth(w, h, function() return 0, 0 end)
    local out = NP.Relief(flat, w, h)
    local uniform, first = true, out[1]
    for i = 1, w * h * 4 do
        if math.mod(i, 4) ~= 0 and out[i] ~= first then uniform = false end
    end
    check('a flat normal map gives one uniform picture', uniform)
    check('flat is mid grey', math.abs(first - 128) <= 1, first)
    check('alpha is opaque', out[4] == 255)

    -- left third flat, middle third tilted toward the light (upper left: x negative, y positive), right third tilted away
    local function Fn(x, y)
        if x < 8 then return 0, 0 end
        if x < 16 then return -0.4, 0.4 end
        return 0.4, -0.4
    end
    local slope = Synth(w, h, Fn)
    out = NP.Relief(slope, w, h)
    local g0, g1, g2 = Grey(out, w, 3, 3), Grey(out, w, 11, 3), Grey(out, w, 20, 3)
    check('a slope facing the light is lighter than flat', g1 > g0 + 40, g1 .. ' vs ' .. g0)
    check('a slope facing away is darker than flat', g2 < g0 - 40, g2 .. ' vs ' .. g0)
    check('the contrast is stretched (bright and dark ends reached)', g1 >= 170 and g2 <= 40, g1 .. ' / ' .. g2)

    -- a shallow slope is made visible by the stretch
    local shallow = Synth(w, h, function(x, y) if x < 12 then return 0, 0 end return -0.05, 0.05 end)
    out = NP.Relief(shallow, w, h)
    check('a shallow slope shows', Grey(out, w, 18, 3) > Grey(out, w, 3, 3) + 30, Grey(out, w, 18, 3) .. ' vs ' .. Grey(out, w, 3, 3))

    -- layout detection and the DXT5nm style
    check('RGB normals are recognised', NP.Layout(slope, w, h) == 'rgb', NP.Layout(slope, w, h))
    local ag = Synth(w, h, Fn, true)
    check('DXT5nm style normals are recognised', NP.Layout(ag, w, h) == 'ag', NP.Layout(ag, w, h))
    local outAg = NP.Relief(ag, w, h)
    local same = true
    for _, x in { 3, 11, 20 } do
        if math.abs(Grey(outAg, w, x, 3) - Grey(NP.Relief(slope, w, h), w, x, 3)) > 6 then same = false end
    end
    check('both layouts give the same picture', same)
    check('a flat map is not mistaken for DXT5nm', NP.Layout(flat, w, h) == 'rgb')

    -- the hue of the albedo is mixed in a little
    local tintPx = {}
    for i = 0, w * h - 1 do
        tintPx[i * 4 + 1], tintPx[i * 4 + 2], tintPx[i * 4 + 3], tintPx[i * 4 + 4] = 200, 100, 50, 255
    end
    local tinted = NP.Relief(flat, w, h, { tint = tintPx })
    check('the albedo tints the picture (red above blue)', tinted[1] > tinted[3] + 10, tinted[1] .. ' / ' .. tinted[3])

    -- the cache (needs the natives of the live editor)
    if NP.Preview and rawget(_G, 'ed_dds_write') and rawget(_G, 'ed_dds_thumb') and rawget(_G, 'ed_vfs_mount') then
        local UserData = import('/lua/editor/userdata.lua')
        local src = UserData.Path('normalpreview/selftest_' .. math.floor(GetSystemTimeSeconds()) .. '.dds')
        local sw, sh = 16, 16
        local sp = Synth(sw, sh, function(x, y) if x < 8 then return 0, 0 end return -0.4, 0.4 end)
        local bytes = ed_dds_write(src, sw, sh, sp, 1)
        check('the synthetic normal map was written', bytes ~= nil)
        if bytes then
            local vfs, layout = NP.Preview(src)
            check('Preview makes a picture', vfs ~= nil and string.find(vfs, '^/ednormals/') ~= nil, tostring(vfs))
            if vfs then
                check('the layout is reported', layout == 'rgb', tostring(layout))
                check('it is found again without decoding', NP.Cached(src) == vfs, tostring(NP.Cached(src)))
                check('asking twice gives the same picture', NP.Preview(src) == vfs)
                local disk = ed_vfs_to_disk and ed_vfs_to_disk(vfs)
                local px, pw, ph = ed_dds_read(disk or vfs)
                check('the picture is ' .. NP.Size .. ' x ' .. NP.Size, px ~= nil and pw == NP.Size and ph == NP.Size, tostring(pw))
                if px and pw == NP.Size then
                    local flatSide, litSide = px[(60 * pw + 10) * 4 + 1], px[(60 * pw + 120) * 4 + 1]
                    check('flat and lit halves differ in the picture', litSide > flatSide + 40, litSide .. ' vs ' .. flatSide)
                end
            end
            check('a missing file gives nil, not an error', NP.Preview(UserData.Path('normalpreview/missing_file.dds')) == nil)
        end
    else
        table.insert(lines, '  skip file round trip (natives not available)')
    end

    if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. table.concat(lines, '\n') end
    return 'PASS normalpreview\n' .. table.concat(lines, '\n')
end
