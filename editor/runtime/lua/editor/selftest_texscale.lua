-- Self test of the tile size maths (texscale.lua) and where it is used (texsets.lua Apply / ApplyRole, strata.lua SetTexture without a size, the size a swapped texture keeps).
-- Run in the live editor (a map with a terrain is open):
--   return import('/lua/editor/selftest_texscale.lua').Run()
-- Returns a report; the first line is PASS or FAIL. Puts the layer textures, tile sizes and the texture set back afterwards.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local TexScale = import('/lua/editor/texscale.lua')
local TexSets = import('/lua/editor/texsets.lua')
local Strata = import('/lua/editor/strata.lua')

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
    local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.001 end

    -- the formula
    check('density is about 48 texels per unit', TexScale.DENSITY > 48 and TexScale.DENSITY < 48.6, TexScale.DENSITY)
    check('512 px -> 20 (the density asks for 10.5; a tile below REPEAT_MIN repeats visibly)', near(TexScale.ForPixels(512), 20), TexScale.ForPixels(512))
    check('1024 px -> 21 (the 18 - 24 band)', near(TexScale.ForPixels(1024), 21), TexScale.ForPixels(1024))
    check('2048 px -> 42.5', near(TexScale.ForPixels(2048), 42.5), TexScale.ForPixels(2048))
    check('256 px -> 20', near(TexScale.ForPixels(256), 20), TexScale.ForPixels(256))
    check('small textures are lifted to REPEAT_MIN', near(TexScale.ForPixels(128), 20) and near(TexScale.ForPixels(32), 20))
    check('large textures clamp to 64', near(TexScale.ForPixels(4096), 64) and near(TexScale.ForPixels(8192), 64))
    check('an unknown width counts as 1024 px', near(TexScale.ForPixels(nil), 21) and near(TexScale.ForPixels(0), 21))
    local steps = true
    for _, px in { 300, 333, 700, 777, 1500, 1900, 2500 } do
        local t = TexScale.ForPixels(px)
        if math.abs(t * 2 - math.floor(t * 2 + 0.5)) > 0.0001 then steps = false end
    end
    check('results are multiples of 0.5', steps)
    check('the slider range allows 2 .. 128 (clamp range lies inside)', TexScale.MIN >= 2 and TexScale.MAX <= 128)

    -- the cache and the fallbacks
    TexScale.Forget()
    local a, b = '/env/selftest/layers/A_albedo.dds', '/env/Selftest/Layers/B_albedo.dds'
    TexScale.Remember(a, 1024)
    TexScale.Remember(b, 2048)
    check('Optimal reads the remembered width', near(TexScale.Optimal(a), 21) and near(TexScale.Optimal(b), 42.5))
    check('the cache ignores case and slashes', TexScale.Pixels('/ENV/selftest\\layers/a_albedo.dds') == 1024)
    check('a texture that cannot be read gets the fallback, else 1024 px', near(TexScale.Optimal('/env/selftest/none_albedo.dds', 7), 7) and near(TexScale.Optimal('/env/selftest/none_albedo.dds'), 21))
    check('empty paths have no width', TexScale.Pixels('') == nil and TexScale.Pixels(nil) == nil)
    check('texels per unit = width / tile', near(TexScale.TexelsPerUnit(a, 8), 128) and TexScale.TexelsPerUnit(a, 0) == nil)
    TexScale.Forget()
    check('Forget clears the cache', TexScale.Pixels(a) == nil)

    -- decorrelation: a golden ratio power, never a whole ratio
    check('Decorrelate multiplies by phi', near(TexScale.Decorrelate(10), 16.0) and near(TexScale.Decorrelate(20, 2), 52.5) and near(TexScale.Decorrelate(20, -1), 12.5))
    local ratiosOk, rangeOk = true, true
    for _, base in { 4, 5.5, 8, 10.5, 12, 14, 21, 24, 28, 32, 42.5, 64 } do
        local m = TexScale.MacroTile(base)
        local r = m / base
        if math.abs(r - math.floor(r + 0.5)) < 0.08 then ratiosOk = false end
        if m < TexScale.MACRO_MIN or m > TexScale.MACRO_MAX then rangeOk = false end
    end
    check('the macro tile is never a whole multiple of the base tile', ratiosOk)
    check('the macro tile stays in its range', rangeOk)
    check('base 21 -> macro 144, base 24 -> 101.5', near(TexScale.MacroTile(21), 144) and near(TexScale.MacroTile(24), 101.5), TexScale.MacroTile(21) .. ' ' .. TexScale.MacroTile(24))

    -- what a swapped texture keeps
    TexScale.Remember(a, 1024)
    TexScale.Remember(b, 2048)
    check('empty layers count as default', TexScale.IsDefault('', 30) and TexScale.IsDefault(Strata.CLEAR, 30) and TexScale.IsEmpty(Strata.CLEAR))
    check('4 and the Optimal size are defaults, a tuned size is not', TexScale.IsDefault(a, 4) and TexScale.IsDefault(a, 21) and not TexScale.IsDefault(a, 30))
    local s1, n1 = TexScale.Carry('', 4, 4, b)
    check('an empty layer takes Optimal of the new texture', near(s1, 42.5) and near(n1, 42.5))
    s1, n1 = TexScale.Carry(a, 21, 21, b)
    check('a default size follows the new texture', near(s1, 42.5) and near(n1, 42.5))
    s1, n1 = TexScale.Carry(a, 30, 25, b)
    check('a tuned size stays', near(s1, 30) and near(n1, 25))
    s1, n1 = TexScale.Carry(a, 30, 21, b)
    check('albedo and normal sizes are judged separately', near(s1, 30) and near(n1, 42.5))

    -- in the editor: texsets.Apply, ApplyRole and SetTexture without a size
    if not rawget(_G, 'ed_stratum_layer') or not ed_stratum_info() then
        table.insert(lines, '  skip texture set checks: no map open')
    else
        local saved, theme0, shader0 = {}, TexSets.Theme, ed_stratum_shader()
        for i = 0, 9 do saved[i] = Strata.Snapshot(i) end
        local ok, err = pcall(function()
            local grass = TexSets.TextureFor('grass', 'temperate')
            local rock = TexSets.TextureFor('rock', 'temperate')
            local base = TexSets.Themes.temperate.base[1]
            if grass and rock and base then
                TexScale.Forget()
                TexScale.Remember(base, 2048)
                TexScale.Remember(grass, 1024)
                TexScale.Remember(rock, 512)
                local n = TexSets.Apply('temperate')
                check('Apply set layers', n > 0, n)
                local _, bs = ed_stratum_layer(0)
                local _, bns = ed_stratum_layer(10)
                check('the base layer takes Optimal of its texture (42.5)', near(bs, 42.5) and near(bns, 42.5), tostring(bs) .. ' / ' .. tostring(bns))
                local _, gs = ed_stratum_layer(1)
                local _, gns = ed_stratum_layer(11)
                check('layer 1 takes Optimal of its texture (21), normal the same', near(gs, 21) and near(gns, 21), tostring(gs) .. ' / ' .. tostring(gns))
                local _, rs = ed_stratum_layer(2)
                check('layer 2 takes Optimal of a 512 px texture (20)', near(rs, 20), rs)
                local prof = Strata.Profile()
                if not prof.upper or prof.upper == 'overlay' then
                    local _, us = ed_stratum_layer(9)
                    check('the Upper layer takes a golden ratio multiple of the base tile', near(us, TexScale.MacroTile(42.5)), tostring(us))
                end
                -- ApplyRole
                TexScale.Remember(rock, 2048)
                check('ApplyRole succeeds', TexSets.ApplyRole(3, 'rock', 'temperate') == true)
                local _, as = ed_stratum_layer(3)
                check('ApplyRole uses Optimal (42.5 for 2048 px)', near(as, 42.5), as)
                -- a theme size is only the fallback for an unreadable texture: the real width is read now (nothing remembered)
                TexScale.Forget()
                TexSets.Apply('temperate')
                local _, fs = ed_stratum_layer(1)
                check('with nothing remembered the size is Optimal of the real file, or the theme size when it cannot be read', near(fs, TexScale.Optimal(grass, TexSets.Themes.temperate.size)), tostring(fs))
                -- SetTexture without sizes
                TexScale.Forget()
                TexScale.Remember(grass, 2048)
                Strata.SetTexture(1, grass, '', nil, nil)
                local _, ss = ed_stratum_layer(1)
                local _, sns = ed_stratum_layer(11)
                check('SetTexture without a size uses Optimal for albedo and normal', near(ss, 42.5) and near(sns, 42.5), tostring(ss) .. ' / ' .. tostring(sns))
            else
                table.insert(lines, '  skip texture set checks: the temperate textures are not in the game data')
            end
        end)
        if not ok then check('no error in the texture set checks', false, err) end
        for i = 0, 9 do
            local s = saved[i]
            if s and s.albedo ~= '' then
                Strata.Restore(s)
            elseif i >= 1 then
                Strata.Clear(i)
            end
        end
        TexSets.SetTheme(theme0)
        if ed_stratum_shader() ~= shader0 then ed_stratum_shader(shader0) end
    end
    TexScale.Forget()
    if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ')\n' .. table.concat(lines, '\n') end
    return 'PASS texscale\n' .. table.concat(lines, '\n')
end
