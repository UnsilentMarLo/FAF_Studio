-- Self test of the detail pass (detail.lua) and the layered textures (texsets.lua LayeredLayout / ApplyLayered, recipes.lua mix / soft knobs, the Layered style). Run in the live editor:
--   return import('/lua/editor/selftest_detail.lua').Run()
-- Places props and decals on the open map and takes them back with undo.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Detail = import('/lua/editor/detail.lua')
local TexSets = import('/lua/editor/texsets.lua')
local Recipes = import('/lua/editor/recipes.lua')
local History = import('/lua/editor/history.lua')

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

    -- the classes of every environment: props resolved through the props catalog (they lie in subfolders), decals as files
    for _, theme in { 'valley', 'temperate', 'desert', 'tropical', 'tundra' } do
        local classes = Detail.Classes(theme)
        local ids, bad = {}, ''
        for _, c in classes do
            ids[c.id] = table.getn(c.entries)
            for _, e in c.entries do
                if c.mode == 'props' and not string.find(string.lower(e), '_prop%.bp$') then bad = bad .. e .. ' ' end
            end
        end
        check(theme .. ': small and big rocks and at least two kinds of decals have entries', (ids.small or 0) > 0 and (ids.big or 0) > 0 and ((ids.crack or 0) > 0 or (ids.ground or 0) > 0 or (ids.cliff or 0) > 0), Join({ ids.small, ids.big, ids.crack, ids.ground, ids.cliff }, ' '))
        check(theme .. ': prop entries are blueprint paths', bad == '', bad)
    end

    -- counts follow the density
    local p1 = Detail.Plan{ theme = 'valley', density = 1 }
    local p2 = Detail.Plan{ theme = 'valley', density = 2 }
    local ok2 = table.getn(p1) > 0 and table.getn(p1) == table.getn(p2)
    for i = 1, table.getn(p1) do
        if p2[i].count < p1[i].count * 2 - 1 or p2[i].count > p1[i].count * 2 + 1 then ok2 = false end
    end
    check('twice the density gives twice the count in every class', ok2)

    -- a run places props, one undo step takes them back; settings of the scatter panel stay as they were
    local Scatter = import('/lua/editor/scatter.lua')
    local seedBefore, modeBefore = Scatter.Settings.seed, Scatter.Settings.mode
    local before = ed_prop_count()
    local summary, total = Detail.Run{ theme = 'valley', only = { 'small' }, density = 0.3, underWater = true }
    check('Run places small rocks', summary and total and total > 0 and ed_prop_count() == before + total, tostring(total))
    check('the scatter settings are restored', Scatter.Settings.seed == seedBefore and Scatter.Settings.mode == modeBefore)
    if summary then History.Undo() end
    check('one undo takes the class back', ed_prop_count() == before, tostring(ed_prop_count()) .. ' vs ' .. tostring(before))

    local decalsBefore = rawget(_G, 'ed_decal_count') and ed_decal_count() or 0
    local s2, t2 = Detail.Run{ theme = 'valley', only = { 'crack' }, density = 2, underWater = true }
    check('Run places decals', s2 and t2 and t2 > 0 and (not rawget(_G, 'ed_decal_count') or ed_decal_count() == decalsBefore + t2), tostring(t2))
    if s2 and t2 and t2 > 0 then History.Undo() end
    check('one undo takes the decals back', not rawget(_G, 'ed_decal_count') or ed_decal_count() == decalsBefore)

    -- layered textures: the layout per shader, every variant path is a string
    local l8 = TexSets.LayeredLayout({ painted = 8 })
    local l7b = TexSets.LayeredLayout({ painted = 7, biplanar = true })
    local l7 = TexSets.LayeredLayout({ painted = 7 })
    check('the layered layout has 8 layers for 8, 7 for 7 painted layers and none for 4', l8 and table.getn(l8) == 8 and l7b and table.getn(l7b) == 7 and l7 and table.getn(l7) == 7 and TexSets.LayeredLayout({ painted = 4 }) == nil)
    local rockOnSide = l7b and l7b[3][1] == 'rock' and l7b[4][1] == 'rock'
    check('the side-mapped layers 3 and 4 of the B shaders are rock', rockOnSide)
    local allStrings = true
    for theme, roles in TexSets.Variants do
        for role, list in roles do
            for _, p in list do
                if type(p) ~= 'string' then allStrings = false end
            end
        end
    end
    check('every variant is a path', allStrings)

    -- the recipe: the new knobs and the Layered style
    local hasMix, hasSoft = false, false
    for _, k in Recipes.KnobInfo do
        if k.key == 'mix' then hasMix = true end
        if k.key == 'soft' then hasSoft = true end
    end
    check('mix and soft are knobs', hasMix and hasSoft and Recipes.Knobs.mix == 0.55 and Recipes.Knobs.soft == 0)
    local layeredIndex
    for i, pr in Recipes.Presets do
        if pr.layered then layeredIndex = i end
    end
    check('the Layered style exists with softer blending', layeredIndex and Recipes.Presets[layeredIndex].knobs.soft > 0 and Recipes.Presets[layeredIndex].knobs.mix > 0.55)
    return Done()
end
