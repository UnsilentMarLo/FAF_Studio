-- Self test of the categorized browser (gui/browser.lua): categories, counts, search, folders, picking. Run() -> report text.
-- Lua 5.0 dialect.

local Browser = import('/lua/editor/gui/browser.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')

function Run()
    local fails, checks = {}, 0
    local function check(name, ok, detail)
        checks = checks + 1
        if not ok then table.insert(fails, name .. (detail and (' (' .. tostring(detail) .. ')') or '')) end
    end
    local picked
    local entries = {}
    for i, def in { { 'UEF', 'T1', 'env/a/x' }, { 'UEF', 'T2', 'env/a/y' }, { 'Cybran', 'T2', 'env/b/x' }, { 'Cybran', 'T3', 'env/b/x' }, { 'Aeon', 'T1', 'env/b/z' } } do
        table.insert(entries, { key = 'k' .. i, name = 'Unit ' .. i, sub = def[1], tags = { faction = def[1], tech = def[2] }, folder = def[3] })
    end
    Browser.Open{ title = 'selftest', entries = entries, facets = { { 'faction', 'Faction' }, { 'tech', 'Tech' } }, memory = 'selftest', done = function(e) picked = e.key end }
    local B = Browser.last
    check('the browser opens', B ~= false and Dialog.IsOpen())
    if not B then return 'FAIL browser did not open' end
    check('all entries shown at first', table.getn(B.state.shown) == 5, table.getn(B.state.shown))
    B.state.filters.faction = 'Cybran'
    B.rebuild()
    check('a faction filter narrows the list', table.getn(B.state.shown) == 2, table.getn(B.state.shown))
    B.state.filters.tech = 'T3'
    B.rebuild()
    check('two filters narrow it further', table.getn(B.state.shown) == 1 and B.state.shown[1].key == 'k4')
    B.state.filters = {}
    B.state.query = 'unit 5'
    B.rebuild()
    check('the search finds words in the name', table.getn(B.state.shown) == 1 and B.state.shown[1].key == 'k5', table.getn(B.state.shown))
    B.state.query = 'aeon t1'
    B.rebuild()
    check('the search also matches categories', table.getn(B.state.shown) == 1 and B.state.shown[1].key == 'k5')
    B.state.query = ''
    B.state.folder = 'env/b'
    B.rebuild()
    check('a folder lists what is below it', table.getn(B.state.shown) == 3, table.getn(B.state.shown))
    local heads = 0
    for _, r in B.state.rows do if r.kind == 'head' then heads = heads + 1 end end
    check('the sidebar has a section per category and for the folders', heads == 3, heads)
    local techRows = {}
    for _, r in B.state.rows do if r.kind == 'val' and r.facet == 'tech' then techRows[r.value] = r.count end end
    check('counts follow the other filters (folder env/b: T1 1, T2 1, T3 1)', techRows.T1 == 1 and techRows.T2 == 1 and techRows.T3 == 1)
    B.state.folder = false
    B.rebuild()
    B.take(B.state.shown[2])
    check('taking an entry calls done and closes the dialog', picked == 'k2' and not Dialog.IsOpen(), tostring(picked))
    Dialog.Close()
    -- names: categories are made from the names
    local names = {}
    for i = 1, 30 do table.insert(names, 'Mass ' .. i) end
    for i = 1, 20 do table.insert(names, 'ARMY_' .. i) end
    Browser.OpenNames{ title = 'names', names = names, done = function() end }
    local N = Browser.last
    local groups = {}
    for _, r in N.state.rows do if r.kind == 'val' and r.facet == 'group' then groups[r.value] = r.count end end
    check('names get prefix groups', groups.Mass == 30 and groups.ARMY == 20)
    Dialog.Close()
    -- shader browser data
    local Shaders = import('/lua/editor/shaders.lua')
    local pbr = Shaders.Find('Terrain201B')
    check('a numbered shader is described from its name', pbr.family == 'splat' and string.find(pbr.instructions, 'Biplanar', 1, true) ~= nil and pbr.listed == true and pbr.summary ~= '', pbr.family)
    check('a known shader has notes', Shaders.Find('TTerrainXP').listed == true and Shaders.Find('TTerrainXP').instructions ~= '')
    local unknown = Shaders.Find('SomeNewShader')
    check('a shader nobody described still gets an entry', unknown.id == 'SomeNewShader' and unknown.listed == false)
    local SB = import('/lua/editor/gui/shaderbrowser.lua')
    local pool = { Shaders.Find('TTerrain'), Shaders.Find('TTerrainXP'), Shaders.Find('Terrain250') }
    check('the shader search needs every word', table.getn(SB.Filter(pool, 'half mask')) >= 1 and table.getn(SB.Filter(pool, 'half qqqzz')) == 0)
    -- map sizes
    local Maps = import('/lua/editor/maps.lua')
    local i5 = Maps.SizeForKm(5)
    local i80, n80 = Maps.SizeForKm(80)
    local i25, n25 = Maps.SizeForKm(2.5)
    check('map sizes in kilometres map to templates', i5 == 1 and i80 == 5 and n80 == 4096 and i25 == 0 and n25 == 128, tostring(i5) .. ' ' .. tostring(i80))
    check('a size the terrain does not support is refused', Maps.SizeForKm(7) == nil and Maps.SizeForKm(160) == nil and Maps.SizeForKm('x') == nil)
    if table.getn(fails) == 0 then return 'PASS browser (' .. checks .. ' checks)' end
    return 'FAIL browser: ' .. table.concat(fails, '; ')
end
