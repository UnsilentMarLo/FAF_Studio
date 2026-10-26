-- Self test of the erosion paint (erosionpaint.lua, the Erosion paint style of recipes.lua, the variant ports of the Ground kinds node). Run in the live editor:
--   return import('/lua/editor/selftest_erosionpaint.lua').Run()
-- Works on synthetic fields over the open map's grid; paints nothing.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Recipes = import('/lua/editor/recipes.lua')
local EP = import('/lua/editor/erosionpaint.lua')
local Nodes = import('/lua/editor/graphnodes.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

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
    local function Done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end

    local erosionIndex
    for i, p in Recipes.Presets do
        if p.id == 'erosion' and p.erosion then erosionIndex = i end
    end
    check('the Erosion paint style exists and is flagged', erosionIndex ~= nil)
    local knobs = {}
    for _, k in Recipes.KnobInfo do knobs[k.key] = true end
    check('the knobs wear, sed, chan and edge exist', knobs.wear and knobs.sed and knobs.chan and knobs.edge)
    check('the Ground kinds node has the five variant outputs and Output: ground kinds the inputs', Nodes.Defs.ground_kinds and Nodes.Defs.out_kinds and table.getn(Nodes.Defs.ground_kinds.outputs) == 13 and table.getn(Nodes.Defs.out_kinds.inputs) == 13,
        Nodes.Defs.ground_kinds and (table.getn(Nodes.Defs.ground_kinds.outputs) .. ' / ' .. table.getn(Nodes.Defs.out_kinds.inputs)))

    if not Fields.IsAvailable() or not ed_terrain_info() then return Done() end
    Fields.Run(function(S)
        local H = S:Height(1)
        -- Above: the threshold with `share` of the cells above it
        local noise = S:Op('perlin', { like = H, seed = 3, scale = 50, octaves = 4 })
        for _, share in { 0.1, 0.3, 0.6 } do
            local t = EP.Above(S, noise, share)
            local _, _, m = Fields.Stats(S:Op('threshold', { a = noise, value = t }))
            check(string.format('Above finds the threshold of a %.0f percent share (got %.1f)', share * 100, m * 100), math.abs(m - share) < 0.03, tostring(m))
        end
        -- masks from the heights when none is given, and the given ones are kept
        local made = EP.Masks(S, H, nil)
        check('Masks makes wear, deposit and flow from the heights', made.wear and made.deposit and made.flow)
        local given = EP.Masks(S, H, { wear = noise })
        check('a given mask is used (the others are still made)', given.wear and given.deposit and given.flow)
        -- Override: the selections of rock, dirt and wet and the variant bands
        local sel, groups = {}, { rock = { 2, 4, 7 }, dirt = { 3, 6 }, wet = { 5, 8 }, grass = { 0, 1 } }
        local c = { S = S, H = H }
        local k = Recipes.KnobsFor({ preset = 'erosion' })
        EP.Override(S, c, sel, groups, k, { wear = noise, deposit = S:Op('perlin', { like = H, seed = 9, scale = 40, octaves = 3 }), flow = S:Op('perlin', { like = H, seed = 5, scale = 30, octaves = 2 }) })
        local keys = ''
        for _, key in { 'rock', 'rock#1', 'rock#2', 'dirt', 'dirt#1', 'wet', 'wet#1', 'grass#1' } do
            if not sel[key] then keys = keys .. key .. ' ' end
        end
        check('Override makes every selection and variant band', keys == '', 'missing ' .. keys)
        if sel.dirt then
            local lo, hi, mean = Fields.Stats(sel.dirt)
            check('the dirt selection is a share of the ground (near 22 percent of the open ground)', mean > 0.05 and mean < 0.4 and hi <= 1.001 and lo >= -0.001, string.format('%.3f', mean))
        end
        -- crisp: the edge of a band is narrow (few cells between 0.1 and 0.9)
        if sel.wet then
            local _, _, lowShare = Fields.Stats(S:Op('threshold', { a = sel.wet, value = 0.1 }))
            local _, _, highShare = Fields.Stats(S:Op('threshold', { a = sel.wet, value = 0.9 }))
            check('the edge of a band is narrow: under a third of the cells above 0.1 are not above 0.9', lowShare > 0 and (lowShare - highShare) < lowShare * 0.34, string.format('%.3f / %.3f', lowShare, highShare))
        end
    end)
    return Done()
end
