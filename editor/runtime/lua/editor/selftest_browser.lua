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
    -- layout: no control may reach outside its dialog (Maui does not clip), no text outside its view, no huge gaps between blocks
    local Skin = import('/lua/editor/gui/skin.lua')
    local TextView = import('/lua/editor/gui/textview.lua')
    local function Outside(d, controls, what)
        local gl, gt = d.group.Left(), d.group.Top()
        local gr, gb = gl + d.width, gt + d.height
        for _, ctl in controls do
            local ok, l, t, r, b = pcall(function() return ctl.Left(), ctl.Top(), ctl.Right(), ctl.Bottom() end)
            if ok and (l < gl or t < gt or r > gr + 1 or b > gb + 1) then
                return what .. ' control at ' .. l .. ',' .. t .. ' .. ' .. r .. ',' .. b .. ' outside ' .. gl .. ',' .. gt .. ' .. ' .. gr .. ',' .. gb
            end
        end
        return nil
    end
    local function OutsideView(d, v)
        local vl, vt = d.group.Left() + Skin.S(v.x), d.group.Top() + Skin.S(v.y)
        local vr, vb = vl + Skin.S(v.w), vt + Skin.S(v.h)
        for _, ctl in v.labels do
            local l, t, r, b = ctl.Left(), ctl.Top(), ctl.Right(), ctl.Bottom()
            if l < vl or t < vt or r > vr or b > vb then
                return 'a text line at ' .. l .. ',' .. t .. ' .. ' .. r .. ',' .. b .. ' outside its view ' .. vl .. ',' .. vt .. ' .. ' .. vr .. ',' .. vb
            end
        end
        return nil
    end
    local function Gaps(v)
        -- the space between two blocks is a small fixed padding, never a block of reserved height
        local prev
        for _, item in v.items do
            if not item.spacer then
                if prev and item.y - (prev.y + prev.h) > Skin.S(24) then return 'gap of ' .. (item.y - (prev.y + prev.h)) .. ' px between two blocks' end
                prev = item
            end
        end
        return nil
    end
    local function ScanView(d, v, what)
        local bad = OutsideView(d, v) or Gaps(v)
        local top = v.off
        v:ScrollTo(v.maxOff)
        bad = bad or OutsideView(d, v)
        v:ScrollTo(math.floor(v.maxOff / 2))
        bad = bad or OutsideView(d, v)
        v:ScrollTo(top)
        return bad and (what .. ': ' .. bad) or nil
    end
    -- a long text: several paragraphs, a word wider than the view, a table row
    do
        local d = Dialog.Open('layout', 420, 320)
        local v = TextView.New(d, 14, 36, 392, 200)
        v:Heading('A heading', { before = 0 })
        for i = 1, 3 do
            local words = {}
            for k = 1, 70 do table.insert(words, 'word' .. k) end
            v:Text(table.concat(words, ' '))
        end
        v:Bullet('A bullet with a long text that wraps over several lines of the view and keeps its indent: ' .. string.rep('lorem ipsum ', 12))
        v:Text(string.rep('x', 120))
        v:Row({ { 'Layer 8', 56 }, { string.rep('albedo ', 14), 150 }, { string.rep('normal ', 10), 120 } })
        v:Show()
        check('a long text is taller than the view and scrolls', v.contentH > 200 and v.maxOff > 0, v.contentH)
        check('a long text stays inside its view', ScanView(d, v, 'long text') == nil, ScanView(d, v, 'long text'))
        check('a long text stays inside the dialog', Outside(d, v:Controls(), 'long text') == nil, Outside(d, v:Controls(), 'long text'))
        v:Clear()
        v:Text('one short line')
        v:Show()
        check('a short text needs no scrolling', v.maxOff == 0 and not v.barShown)
        v:Destroy()
        Dialog.Close()
    end
    -- the shader browser: every shader, both tabs
    do
        local B = SB.Open(function() end)
        local bad
        for i, sh in B.all do
            B.sel = i
            for _, tab in { 'layers', 'notes' } do
                B.tab = tab
                B.show()
                bad = bad or Outside(B.dialog, B.controls(), sh.id .. ' (' .. tab .. ')') or ScanView(B.dialog, B.view, sh.id .. ' (' .. tab .. ')')
            end
        end
        check('every shader fits in the shader browser (' .. table.getn(B.all) .. ' shaders, Layers and Notes)', bad == nil, bad)
        -- the warning of a refused conversion wraps inside the dialog
        B.sel = false
        for i, sh in B.all do
            if sh.id == 'Terrain301' then B.sel = i end
        end
        if B.sel then
            B.show()
            check('the Terrain301 conversion warning stays inside the dialog', Outside(B.dialog, B.controls(), 'Terrain301') == nil)
        end
        Dialog.Close()
    end
    -- the convert dialog: the options view of every shader and a long result report
    do
        local CD = import('/lua/editor/gui/convertdialog.lua')
        local bad
        for _, sh in Shaders.List() do
            if sh.profile and sh.profile.supported then
                local st = CD.Open(sh.id)
                bad = bad or Outside(st.dialog, st.controls(), 'convert to ' .. sh.id) or ScanView(st.dialog, st.view, 'convert to ' .. sh.id)
                if not st.plan.refused then
                    local long = string.rep('This line of the report is long and has to wrap inside the dialog without leaving it. ', 4)
                    st.ShowReport({ lines = { { kind = 'done', text = 'Shader: A -> B.' }, { kind = 'done', text = long }, { kind = 'warn', text = long },
                        { kind = 'warn', text = long }, { kind = 'warn', text = long }, { kind = 'warn', text = long }, { kind = 'warn', text = long } }, status = 'x' })
                    bad = bad or Outside(st.dialog, st.controls(), 'result of ' .. sh.id) or ScanView(st.dialog, st.view, 'result of ' .. sh.id)
                    st.ShowReport(nil, long)
                    bad = bad or Outside(st.dialog, st.controls(), 'failure of ' .. sh.id)
                end
                Dialog.Close()
            end
        end
        check('the convert dialog fits for every shader (options, result, failure)', bad == nil, bad)
    end
    -- map sizes
    local Maps = import('/lua/editor/maps.lua')
    local i5 = Maps.SizeForKm(5)
    local i80, n80 = Maps.SizeForKm(80)
    local i25, n25 = Maps.SizeForKm(2.5)
    check('map sizes in kilometres map to templates', i5 == 1 and i80 == 5 and n80 == 4096 and i25 == 0 and n25 == 128, tostring(i5) .. ' ' .. tostring(i80))
    check('a size the terrain does not support is refused', Maps.SizeForKm(7) == nil and Maps.SizeForKm(160) == nil and Maps.SizeForKm('x') == nil)
    -- any size: the terrain of the next power of two, the playable area in the middle of it
    local pl = Maps.CustomPlan(7.5, 12)
    check('7.5 x 12 km: terrain 1024, a playable area of 384 x 614 units in the middle', pl and pl.terrain == 1024 and pl.w == 384 and pl.h == 614 and pl.rect and pl.rect[1] == 320 and pl.rect[2] == 205
        and pl.rect[3] == 704 and pl.rect[4] == 819 and not pl.whole and pl.template == Maps.Sizes[3].template)
    local p10, p80, p25 = Maps.CustomPlan(10, 10), Maps.CustomPlan(80, 80), Maps.CustomPlan(2.5, 2.5)
    check('a size that is a terrain needs no playable area', p10 and p10.whole and p10.rect == false and p10.terrain == 512 and p80 and p80.whole and p25 and p25.whole and p25.terrain == 128)
    check('too small, too big or not a number is refused', Maps.CustomPlan(0.5, 5) == nil and Maps.CustomPlan(5, 81) == nil and Maps.CustomPlan('x', 5) == nil)
    if table.getn(fails) == 0 then return 'PASS browser (' .. checks .. ' checks)' end
    return 'FAIL browser: ' .. table.concat(fails, '; ')
end
