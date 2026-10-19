-- Self test of the asset browser (assetcat.lua, assetthumbs.lua, gui/grid.lua, gui/panels_assets.lua), the stamp brushes (stamp.lua, brushes.lua, terrain.lua hooks, gui/panels_stamps.lua) and the
-- tooltip rules (tooltips: every interactive widget has a text). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_assets.lua').Run()        synchronous checks (part of editor_inst.py selftests)
--   return import('/lua/editor/selftest_assets.lua').RunLive()    starts the checks that need frames (props rendered offscreen, drag and drop); read LIVERESULT after about 60 s
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Cat = import('/lua/editor/assetcat.lua')
local Thumbs = import('/lua/editor/assetthumbs.lua')
local Fav = import('/lua/editor/favourites.lua')
local Props = import('/lua/editor/props.lua')
local Decals = import('/lua/editor/decals.lua')
local Units = import('/lua/editor/units.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Stamp = import('/lua/editor/stamp.lua')
local Brushes = import('/lua/editor/brushes.lua')
local Strata = import('/lua/editor/strata.lua')
local H = import('/lua/editor/history.lua')
local UserData = import('/lua/editor/userdata.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end

local function Undo()
    H.Undo()
end

local function Height(x, z) return ed_terrain_get(x, z) or 0 end

-- ---- catalog --------------------------------------------------------------------------------------------------------------------------------

local function Catalog()
    local units = Cat.Entries('units')
    Check(table.getn(units) > 100, 'the catalog lists units (' .. table.getn(units) .. ')')
    Check(table.getn(Cat.Entries('props')) > 100 and table.getn(Cat.Entries('decals')) > 100, 'it lists props and decals')
    Check(table.getn(Cat.Entries('markers')) > 5 and table.getn(Cat.Entries('textures')) > 20 and table.getn(Cat.Entries('effects')) > 10, 'it lists markers, terrain textures and effects')
    local all = Cat.Entries('all')
    Check(table.getn(all) >= table.getn(units) + table.getn(Cat.Entries('props')), 'All is every kind together (' .. table.getn(all) .. ')')

    local e = Cat.Find('units', { query = 'del0204' })[1]
    Check(e and e.key == 'del0204' and e.tags.faction == 'UEF' and e.tags.layer == 'land' and e.tags.tech == 'T2', 'del0204 is UEF / land / T2')
    local uef = Cat.Find('units', { filters = { faction = 'UEF' } })
    local aeon = Cat.Find('units', { filters = { faction = 'Aeon' } })
    Check(table.getn(uef) > 20 and table.getn(aeon) > 20 and table.getn(uef) + table.getn(aeon) < table.getn(units), 'a faction filter keeps a part of the units')
    local t3air = Cat.Find('units', { filters = { tech = 'T3', layer = 'air' } })
    local ok = table.getn(t3air) > 0
    for _, u in t3air do if u.tags.tech ~= 'T3' or u.tags.layer ~= 'air' then ok = false end end
    Check(ok, 'two filters combine (T3 air: ' .. table.getn(t3air) .. ')')
    Check(table.getn(Cat.Find('units', { query = 'uef land t2' })) > 0, 'every word of a query must match (name, id or tag)')
    Check(table.getn(Cat.Find('units', { query = 'zzzzqqq' })) == 0, 'a query nothing matches finds nothing')
    local values = Cat.Values('units', 'faction')
    Check(table.getn(values) >= 4, 'the values of a facet are listed (' .. table.concat(values, ', ') .. ')')
    Check(table.getn(Cat.Facets('units')) == 4 and table.getn(Cat.Facets('props')) == 2, 'each kind has its facets')

    -- favourites and recent
    local key = 'del0204'
    local before = Fav.Is('units', key)
    Fav.Reset()
    Fav.ClearRecent()
    Fav.Toggle('units', key)
    local starred = Cat.Find('units', { onlyFav = true })
    Check(table.getn(starred) == 1 and starred[1].key == key, 'Starred only shows the favourite')
    Check(Cat.Find('units', {})[1].key == key, 'a favourite comes first')
    Fav.Toggle('units', key)
    Check(table.getn(Cat.Find('units', { onlyFav = true })) == 0, 'the star can be taken away')
    Fav.Touch('units', 'uel0201')
    Fav.Touch('props', Cat.Entries('props')[1].key)
    Fav.Touch('units', 'del0204')
    local recent = Cat.Find('all', { recent = true })
    Check(table.getn(recent) == 3 and recent[1].key == 'del0204' and recent[2].kind == 'props', 'Recent lists what was used, newest first')
    Check(table.getn(Fav.Recent('units')) == 2, 'the recent list is per kind too')
    Fav.ClearRecent()
    Fav.Reset()
    if before then Fav.Toggle('units', key) end
end

-- ---- thumbnail cache ----------------------------------------------------------------------------------------------------------------------

local function Cache()
    Thumbs.Reset()
    local d = Cat.Entries('decals')[1]
    local n1 = Thumbs.Name('decals', d.key, d.source)
    Check(n1 == Thumbs.Name('decals', d.key, d.source), 'a cache name is stable')
    Check(n1 ~= Thumbs.Name('decals', d.key .. 'x', d.source), 'and differs per key')
    Check(string.find(n1, '^decals_%x%x%x%x%x%x%x%x%x%x%x%x%.dds$') ~= nil, 'and has the form kind_hash.dds (' .. n1 .. ')')
    local v = Thumbs.Version
    Thumbs.Version = v + 1
    local n2 = Thumbs.Name('decals', d.key, d.source)
    Thumbs.Version = v
    Check(n1 ~= n2, 'a new Version is a new name (and a new folder)')
    Check(string.find(Thumbs.Dir(), 'assetthumbs/v' .. v, 1, true) ~= nil, 'the cache folder carries the version')

    -- invalidation by file stamp: a source file that changes gets a new name
    local dir = Thumbs.Dir()
    local srcName = 'stamptest_' .. math.floor(GetSystemTimeSeconds()) .. '.dds'
    local px = {}
    for i = 1, 8 * 8 * 4 do px[i] = 128 end
    ed_write_file(dir .. '/.keep', '')
    ed_vfs_mount(dir, '/edassets')
    ed_dds_write(dir .. '/' .. srcName, 8, 8, px, 1)
    local a = Thumbs.Name('decals', 'k', '/edassets/' .. srcName)
    local px2 = {}
    for i = 1, 16 * 16 * 4 do px2[i] = 40 end
    ed_dds_write(dir .. '/' .. srcName, 16, 16, px2, 1)
    local b = Thumbs.Name('decals', 'k', '/edassets/' .. srcName)
    Check(a ~= b, 'a changed source file changes the cache name (time stamp)')

    -- decal and texture pictures are made natively
    local path, why = Thumbs.Make('decals', d.key, d.source)
    Check(path ~= nil, 'a decal picture is made natively ' .. tostring(why))
    if path then
        local disk = ed_vfs_to_disk(path)
        local pix, w, h = ed_dds_read(disk)
        Check(w == Thumbs.Size and h == Thumbs.Size and pix ~= nil, 'it is ' .. Thumbs.Size .. ' x ' .. Thumbs.Size)
        Check(Thumbs.Cached('decals', d.key, d.source) == path, 'and is found in the cache afterwards')
    end
    local t = Cat.Entries('textures')[1]
    Check(Thumbs.Make('textures', t.key, t.source) ~= nil, 'a terrain texture picture is made')
    Check(Thumbs.Make('shapes', 'cone', nil) ~= nil, 'a stamp shape picture is made')
    local s = Thumbs.Stats()
    Check(type(s.made) == 'number' and type(s.hits) == 'number' and s.queued == 0, 'the statistics are there (made ' .. s.made .. ', hits ' .. s.hits .. ')')
end

-- ---- placing -------------------------------------------------------------------------------------------------------------------------------

local function Placing()
    Symmetry.SetMode('off')
    local props0, decals0 = ed_prop_count(), ed_decal_count()
    local p = Cat.Find('props', { query = 'rock' })[1] or Cat.Entries('props')[1]
    local d0 = H.Depth and H.Depth() or 0
    local n = Cat.DropAt(p, 40, 40)
    Check(n == 1 and ed_prop_count() == props0 + 1, 'a prop dropped at a point is placed there')
    Check(Props.Active == p.key, 'the browser entry became the active prop')
    Undo()
    Check(ed_prop_count() == props0, 'one undo takes it away again')
    Symmetry.SetMode('mirror_x')
    n = Cat.DropAt(p, 40, 40)
    Check(n == 2 and ed_prop_count() == props0 + 2, 'with mirror symmetry it comes with its image')
    Undo()
    Check(ed_prop_count() == props0, 'both go with one undo')
    Symmetry.SetMode('off')

    local dec = Cat.Entries('decals')[1]
    n = Cat.DropAt(dec, 60, 60)
    Check(n >= 1 and ed_decal_count() > decals0, 'a decal dropped is placed')
    Undo()
    Check(ed_decal_count() == decals0, 'and undone')

    local armies = Map.Doc and Map.Doc.save.Armies or {}
    local army = false
    for name, _ in armies do army = name break end
    if army then
        Units.ArmyName = army
        local count = 0
        for _ in Units.All() do count = count + 1 end
        local u = Cat.Find('units', { query = 'uel0201' })[1]
        n = Cat.DropAt(u, 80, 80)
        local after = 0
        for _ in Units.All() do after = after + 1 end
        Check(n == 1 and after == count + 1, 'a unit dropped is placed for the active army')
        Undo()
        local back = 0
        for _ in Units.All() do back = back + 1 end
        Check(back == count, 'and undone')
    else
        Check(true, '(no army in this map: unit drop not checked)')
    end

    -- picking sets the tool's active entry
    local m = Cat.Entries('markers')[1]
    Cat.Pick(m)
    Check(import('/lua/editor/tools.lua').MarkerType == m.key, 'picking a marker entry selects the marker type')
    Check(Cat.Droppable(m) and not Cat.Droppable(Cat.Entries('textures')[1]), 'markers can be dragged, textures cannot')

    -- a texture goes to the active layer, undoably
    local tex
    for _, e in Cat.Entries('textures') do if e.tags.type == 'albedo' then tex = e break end end
    Strata.Active = 1
    local before = Strata.Snapshot(1)
    Cat.Activate(tex)
    local after = Strata.Snapshot(1)
    Check(after.albedo == tex.key, 'a double click gives the texture to the active layer')
    Undo()
    Check(Strata.Snapshot(1).albedo ~= tex.key, 'and one undo takes it off the layer again')
end

-- ---- the grid widget -------------------------------------------------------------------------------------------------------------------

local function GridWidget()
    local Group = import('/lua/maui/group.lua').Group
    local Grid = import('/lua/editor/gui/grid.lua')
    local root = Group(GetFrame(0))
    root.Left:Set(0) root.Top:Set(0) root.Width:Set(600) root.Height:Set(400)
    root.Depth:Set(100)
    local bound, selected = {}, nil
    local g = Grid.Create(root, {
        cellW = 80, cellH = 100,
        getCount = function() return 57 end,
        bind = function(cell, index) bound[index] = true cell.text = 'item ' .. index end,
        onSelect = function(index) selected = index end,
    })
    g:SetRect(0, 0, 400, 300)
    local cells = g:Cells()
    -- (57 items need more rows than fit, so the scrollbar takes 8 units from the width: 4 columns of 80)
    Check(g.cols == 4 and table.getn(cells) == 12, 'a 400 x 300 grid of 80 x 100 cells with a scrollbar shows 4 columns and 3 rows (' .. g.cols .. ' x ' .. table.getn(cells) .. ')')
    Check(bound[1] and bound[12] and not bound[13], 'only the visible cells are bound')
    g:ScrollTo(57)
    Check(g.offset >= 11 and bound[57], 'scrolling to the last item shows it')
    g:SetSelected(3)
    Check(g.selected == 3, 'an item can be selected')
    g:SetCellSize(40, 60, false)
    Check(g.cols >= 9, 'smaller cells give more columns (' .. g.cols .. ')')
    g:SetCellSize(100, 26, true)
    Check(g.cols == 1, 'list mode is one column')
    g:Destroy()
    root:Destroy()
end

-- ---- brushes: image masks -------------------------------------------------------------------------------------------------------------

local function Masks()
    Check(Near(Brushes.Sample('round', 0, 0), 1) and Brushes.Sample('round', 1.2, 0) == 0, 'the round shape is a disc')
    Check(Brushes.Sample('cone', 0, 0) > 0.95 and Brushes.Sample('cone', 0.9, 0) < 0.2, 'the cone is high in the middle')
    -- a picture imported into the user's library: a DDS with a bright left half
    local dir = UserData.Path('brushes')
    ed_write_file(dir .. '/.keep', '')
    local px = {}
    for y = 0, 31 do
        for x = 0, 31 do
            local v = (x < 16) and 255 or 0
            local k = (y * 32 + x) * 4
            px[k + 1], px[k + 2], px[k + 3], px[k + 4] = v, v, v, 255
        end
    end
    local tmp = UserData.Path('assetthumbs/stamptest_src.dds')
    ed_write_file(UserData.Path('assetthumbs') .. '/.keep', '')
    ed_dds_write(tmp, 32, 32, px, 1)
    local n = Brushes.Import({ tmp })
    Check(n == 1, 'a picture file is imported into the stamp library')
    local id
    for _, e in Brushes.List() do
        if e.kind == 'image' and string.find(e.id, 'stamptest_src', 1, true) then id = e.id end
    end
    Check(id ~= nil, 'it shows in the shape list')
    if id then
        Check(Brushes.Sample(id, -0.5, 0, 64) > 0.9 and Brushes.Sample(id, 0.5, 0, 64) < 0.1, 'a DDS picture is read as a mask (bright left half)')
    end
    return id
end

-- ---- stamps --------------------------------------------------------------------------------------------------------------------------------

local function StampBasics()
    local img = { kind = 'mx' }
    local sx, sz = Stamp.ToSource(img, 3, 4)
    Check(sx == -3 and sz == 4, 'ToSource: a mirror in x flips x')
    local sx2, sz2 = Stamp.ToSource({ kind = 'dg' }, 3, 4)
    Check(sx2 == 4 and sz2 == 3, 'a diagonal mirror swaps x and z')
    local rx, rz = Stamp.ToSource({ kind = 'rot', angle = math.pi }, 3, 4)
    Check(Near(rx, -3, 0.001) and Near(rz, -4, 0.001), 'a half turn negates both')
    -- the images of Symmetry.Points: the source offset of the image of a point is the offset of the point
    for _, mode in { 'mirror_x', 'mirror_z', 'mirror_xz', 'rot2', 'rot4', 'diag', 'diag_both' } do
        Symmetry.SetMode(mode)
        local cx, cz = Symmetry.Centre()
        local px, pz = cx + 20, cz + 7
        local ox, oz = 3, 5                      -- an offset from the point
        local good = true
        for _, p in Symmetry.Points(px, pz) do
            -- the sample at the point + offset maps to the image + the image's offset; ToSource must bring the image's offset back
            local q = Symmetry.Points(px + ox, pz + oz)
            for _, qi in q do
                if qi.kind == p.kind and qi.angle == p.angle then
                    local sx3, sz3 = Stamp.ToSource(p, qi.x - p.x, qi.z - p.z)
                    if not (Near(sx3, ox, 0.01) and Near(sz3, oz, 0.01)) then good = false end
                end
            end
        end
        Check(good, 'symmetry ' .. mode .. ': the picture of every image is the mirrored / turned picture')
    end
    Symmetry.SetMode('off')
    Stamp.S.spacing = 100
    Terrain.Brush.radius = 10
    Check(Near(Stamp.Spacing(), 20, 0.01), 'spacing 100 percent is the width of the stamp (20 units for radius 10)')
    Stamp.S.spacing = 50
    Check(Near(Stamp.Spacing(), 10, 0.01), 'spacing 50 percent is half of it')
    Stamp.S.randomRotation = true
    Stamp.S.scaleJitter = 40
    local turns, scales = {}, {}
    for i = 1, 20 do
        Stamp.BeginDab(50, 50)
        local t, s = Stamp.LastDab()
        turns[math.floor(t / 20)] = true
        scales[math.floor(s * 20)] = true
    end
    local nt, ns = 0, 0
    for _ in turns do nt = nt + 1 end
    for _ in scales do ns = ns + 1 end
    Check(nt >= 4 and ns >= 3, 'random rotation and size jitter vary per dab (' .. nt .. ' turn bins, ' .. ns .. ' size bins)')
    Stamp.S.randomRotation = false
    Stamp.S.scaleJitter = 0
    local x0, z0 = Stamp.BeginDab(50, 50)
    Stamp.S.posJitter = 100
    local moved = false
    for i = 1, 5 do
        local jx, jz = Stamp.BeginDab(50, 50)
        if math.abs(jx - 50) > 0.01 or math.abs(jz - 50) > 0.01 then moved = true end
        if (jx - 50) * (jx - 50) + (jz - 50) * (jz - 50) > 10.01 * 10.01 then moved = false break end
    end
    Stamp.S.posJitter = 0
    Check(x0 == 50 and z0 == 50 and moved, 'position jitter moves a dab inside the radius, none keeps it')
end

local function Stroke(mode, points)
    Terrain.Brush.mode = mode
    Terrain.BeginStroke()
    for _, p in points do Terrain.Dab(p[1], p[2]) end
    Terrain.EndStroke()
end

local function HeightStamps()
    Symmetry.SetMode('off')
    -- a known ground: other tests (shuffled order) leave the terrain low, and a subtract stamp is clamped at the sea floor
    local levelDepth = Terrain.UndoDepth()
    Terrain.SetRect(0, 0, 255, 255, 40)
    local depth0 = Terrain.UndoDepth()
    Terrain.Brush.radius = 10
    Stamp.S.shape = 'cone'
    Stamp.S.mode = 'add'
    Stamp.S.height = 10
    Stamp.S.strength = 100
    Stamp.S.falloff = 0
    Stamp.S.rotation = 0
    Stamp.S.randomRotation = false
    Stamp.S.scaleJitter = 0
    Stamp.S.posJitter = 0
    Stamp.S.baseMode = 'dab'
    local sum0, n0 = Terrain.Checksum(0, 0, 255, 255)
    local c0 = Height(100, 100)
    Stroke('stamp', { { 100, 100 } })
    local c1 = Height(100, 100)
    Check(Near(c1 - c0, 10, 0.2), 'add: the stamp\'s peak adds Height units at the centre (' .. string.format('%.2f', c1 - c0) .. ')')
    Check(c1 - Height(100, 100 + 6) > 3, 'the shape has a slope (cone: 10 at the middle, ' .. string.format('%.1f', Height(100, 100 + 6) - c0) .. ' at 6 units)')
    Check(Terrain.UndoDepth() == depth0 + 1, 'one dab is one undo step')
    Terrain.Undo()
    local sum1 = Terrain.Checksum(0, 0, 255, 255)
    Check(sum1 == sum0, 'undo restores the terrain exactly')

    -- a stroke of several dabs is one undo step
    Stamp.S.spacing = 100
    local g130, g150 = Height(130, 90), Height(150, 90)      -- the ground there before: other tests (shuffled order) leave different heights
    Stroke('stamp', { { 90, 90 }, { 110, 90 }, { 130, 90 }, { 150, 90 } })
    Check(Terrain.UndoDepth() == depth0 + 1, 'a stroke of four dabs is one undo step')
    Check(Height(130, 90) > g130 + 5 and Height(150, 90) > g150 + 5, 'every dab stamped')
    Terrain.Undo()
    Check(Terrain.Checksum(0, 0, 255, 255) == sum0, 'undo of the stroke restores everything')

    -- subtract
    Stamp.S.mode = 'subtract'
    Stroke('stamp', { { 100, 100 } })
    Check(Near(Height(100, 100) - c0, -10, 0.2), 'subtract cuts the stamp out (' .. string.format('%.2f', Height(100, 100) - c0) .. ')')
    Terrain.Undo()

    -- max / min: only where the stamp is beyond the ground
    Stamp.S.mode = 'max'
    Stroke('stamp', { { 100, 100 } })
    Check(Near(Height(100, 100) - c0, 10, 0.2), 'max: the ground rises to base + stamp where it is lower (' .. string.format('%.2f', Height(100, 100) - c0) .. ')')
    Stroke('stamp', { { 100, 100 } })       -- a second max stamp with the base now at the new top: rises again (base measured under each dab)
    Terrain.Undo() Terrain.Undo()
    Stamp.S.mode = 'min'
    Stroke('stamp', { { 100, 100 } })
    Check(Near(Height(100, 100) - c0, -10, 0.2), 'min: the ground sinks to base - stamp (' .. string.format('%.2f', Height(100, 100) - c0) .. ')')
    Terrain.Undo()

    -- replace on sloped ground: the stamp sets the ground to base + stamp inside it
    Stamp.S.mode = 'replace'
    local nearBefore = Height(100 + 8, 100)
    Stroke('stamp', { { 100, 100 } })
    local c2 = Height(100, 100)
    Check(Near(c2 - c0, 10, 0.2), 'replace: the peak is base + Height (' .. string.format('%.2f', c2 - c0) .. ')')
    Terrain.Undo()

    -- strength scales the stamp
    Stamp.S.mode = 'add'
    Stamp.S.strength = 50
    Stroke('stamp', { { 100, 100 } })
    Check(Near(Height(100, 100) - c0, 5, 0.2), 'strength 50 percent adds half (' .. string.format('%.2f', Height(100, 100) - c0) .. ')')
    Terrain.Undo()
    Stamp.S.strength = 100

    -- rotation turns an unsymmetric picture: a ridge along x becomes a ridge along z
    Stamp.S.shape = 'ridge'
    Stamp.S.rotation = 0
    Stroke('stamp', { { 100, 100 } })
    local alongX0 = Height(100 + 6, 100) - c0
    local alongZ0 = Height(100, 100 + 6) - c0
    Terrain.Undo()
    Stamp.S.rotation = 90
    Stroke('stamp', { { 100, 100 } })
    local alongX1 = Height(100 + 6, 100) - c0
    local alongZ1 = Height(100, 100 + 6) - c0
    Terrain.Undo()
    Stamp.S.rotation = 0
    Check(alongX0 > 1 and alongZ0 < 0.5 and alongZ1 > 1 and alongX1 < 0.5, 'rotation 90 turns a ridge from along x to along z (x: ' .. string.format('%.1f -> %.1f', alongX0, alongX1) .. ', z: ' .. string.format('%.1f -> %.1f', alongZ0, alongZ1) .. ')')

    -- symmetry: mirror_x stamps the mirrored picture at the mirrored place
    Symmetry.SetMode('mirror_x')
    Stamp.S.shape = 'ridge'
    Stamp.S.rotation = 35
    local cx = Symmetry.Centre()
    local mirror0 = Height(2 * cx - 60, 100)
    Stroke('stamp', { { 60, 100 } })
    local good, samples = true, 0
    for _, o in { { 3, 2 }, { -4, 5 }, { 6, -3 }, { 0, 7 }, { -5, -5 } } do
        local a = Height(60 + o[1], 100 + o[2])
        local b = Height(2 * cx - (60 + o[1]), 100 + o[2])
        samples = samples + 1
        if math.abs(a - b) > 0.2 then good = false end
    end
    Check(good, 'mirror symmetry: the image is the mirrored stamp (' .. samples .. ' samples agree)')
    Check(Height(2 * cx - 60, 100) > mirror0 + 1, 'the image was stamped')
    Terrain.Undo()
    Check(Terrain.Checksum(0, 0, 255, 255) == sum0, 'one undo takes both away')
    Symmetry.SetMode('off')
    Stamp.S.rotation = 0
    Stamp.S.shape = 'mountain'
    while Terrain.UndoDepth() > levelDepth do Terrain.Undo() end
end

local function TextureStamp()
    local tex
    for _, e in Cat.Entries('textures') do if e.tags.type == 'albedo' then tex = e break end end
    Strata.Active = 1
    local before = Strata.Snapshot(1)
    Strata.SetTexture(1, tex.key, '', 4, 4)
    local w, h = Strata.MaskInfo()
    local v0 = ed_stratum_read(0, 15, 15, 35, 35)
    local sum0 = 0
    for _, v in v0 or {} do sum0 = sum0 + v end
    Stamp.S.shape = 'cone'
    Stamp.S.rotation = 0
    Stamp.S.falloff = 0
    Terrain.Brush.radius = 8
    local depth0 = H.Depth and H.Depth() or 0
    Terrain.Brush.mode = 'stamp_paint'
    Terrain.BeginStroke()
    Terrain.Dab(50, 50)
    Terrain.Dab(54, 50)
    Terrain.EndStroke()
    local entry = Strata.TakeEntry()
    local v1 = ed_stratum_read(0, 15, 15, 35, 35)
    local sum1 = 0
    for _, v in v1 or {} do sum1 = sum1 + v end
    Check(entry ~= nil and sum1 > sum0, 'the texture stamp paints the layer mask through the picture')
    if entry then
        entry.undo()
        local v2 = ed_stratum_read(0, 15, 15, 35, 35)
        local sum2 = 0
        for _, v in v2 or {} do sum2 = sum2 + v end
        Check(sum2 == sum0, 'and its undo entry restores the mask')
    end
    if before.albedo == '' then Strata.Clear(1) else Strata.SetTexture(1, before.albedo, before.normal, before.size, before.nsize) end
end

local function Tools()
    local UI = import('/lua/editor/ui.lua')
    local have = {}
    for _, t in UI.Tools do have[t.id] = t end
    Check(have.stamp and have.stamp.kind == 'brush' and have.stamp_paint and have.stamp_paint.kind == 'brush', 'the stamp tools are brush tools')
    local Panels = import('/lua/editor/gui/panels.lua')
    Check(Panels.Get('assets') ~= nil and Panels.Get('stamps') ~= nil, 'the Assets and Stamps panels are registered')
    local Commands = import('/lua/editor/gui/commands.lua')
    Check(Commands.registry['assets.open'] ~= nil, 'the asset browser has a command')
end

-- ---- tooltips -----------------------------------------------------------------------------------------------------------------------------

local function Tooltips()
    local T = import('/lua/editor/tooltips.lua')
    local W = import('/lua/editor/gui/widgets.lua')
    Check(T.Norm('Strength %') == 'strength %' and T.Norm('Sun r') == 'sun r', 'Norm: lower case')
    Check(T.Norm('Colours: Rainbow') == 'colours' and T.Norm('Import...') == 'import' and T.Norm('Rotate 90 (4)') == 'rotate #', 'Norm: no ":" part, no "...", no "(...)", digits as #')
    Check(T.ForWidget('erosion', 'Preview') ~= T.ForWidget('fields', 'Preview'), 'a label can mean different things in different panels')
    Check(T.ForWidget('nosuchpanel', 'Cancel') == T.ForWidget(nil, 'cancel') and T.ForWidget(nil, 'cancel') ~= nil, 'a label that means the same everywhere has a generic text')
    Check(T.ForWidget('nosuchpanel', 'Qqqq zzz') == nil, 'an unknown label has none')
    -- hotkeys come from the command registry
    local Commands = import('/lua/editor/gui/commands.lua')
    local keys = Commands.registry['edit.undo'] and Commands.registry['edit.undo'].keys
    Check(keys and T.Hotkey('edit.undo') == string.gsub(keys, '%-', '+'), 'Hotkey: the key of a command (' .. tostring(T.Hotkey('edit.undo')) .. ')')
    Check(string.find(T.WithHotkey('Takes it back.', 'edit.undo') or '', '@Shortcut: ', 1, true) ~= nil and T.WithHotkey('x', 'no.such.command') == 'x', 'WithHotkey adds a shortcut line, none for a command without a key')
    local saved = Commands.registry['edit.undo'].keys
    Commands.registry['edit.undo'].keys = 'Ctrl+Alt+U'
    Check(string.find(T.WithHotkey('x', 'edit.undo'), 'Ctrl+Alt+U', 1, true) ~= nil, 'a rebound key shows at once')
    Commands.registry['edit.undo'].keys = saved
    -- a button / slider / field finds its text through the panel it is in
    local Group = import('/lua/maui/group.lua').Group
    local root = Group(GetFrame(0))
    root.Left:Set(0) root.Top:Set(0) root.Width:Set(300) root.Height:Set(200) root.Depth:Set(100)
    root.panelId = 'erosion'
    local b = W.Button(root, 'Preview', 0, 0, 60, 22, function() end)
    Check(b:TipText() == T.ForWidget('erosion', 'Preview'), 'a button takes the text of its panel and label')
    local b2 = W.Button(root, 'Preview', 0, 30, 60, 22, function() end, { tip = 'my own' })
    Check(b2:TipText() == 'my own', 'a tip option wins')
    local b3 = W.Button(root, 'Preview', 0, 60, 60, 22, function() end, { tip = 'Takes it back.', cmd = 'edit.undo' })
    Check(keys == nil or string.find(b3:TipText(), 'Shortcut', 1, true) ~= nil, 'a cmd option adds the key binding')
    local sl = W.Slider(root, { label = 'Iterations', min = 1, max = 10, step = 1, fmt = '%d', get = function() return 3 end, set = function() end })
    Check(sl:TipText() == T.ForWidget('erosion', 'Iterations'), 'a slider takes its text from the label')
    local f = W.TextField(root, 0, 100, 100, 22, {})
    Check(f:TipText() ~= nil, 'a text field has a generic text')
    local f2 = W.TextField(root, 0, 130, 100, 22, { tip = 'Hello' })
    Check(f2:TipText() == 'Hello', 'and takes a tip option')
    root:Destroy()
    -- the check itself
    local TC = import('/lua/editor/tipcheck.lua')
    local missing = TC.Tools()
    Check(table.getn(missing) == 0, 'every tool has a text' .. (table.getn(missing) > 0 and (': ' .. table.concat(missing, ', ')) or ''))
    missing = TC.Panels()
    Check(table.getn(missing) == 0, 'every panel tab has a text' .. (table.getn(missing) > 0 and (': ' .. table.concat(missing, ', ')) or ''))
    missing = TC.Workspaces()
    Check(table.getn(missing) == 0, 'every workspace button has a text')
    local n, mm = TC.Menus()
    Check(n > 100 and table.getn(mm) == 0, 'every menu item has a text (' .. n .. ' checked' .. (table.getn(mm) > 0 and (', missing: ' .. mm[1]) or '') .. ')')
    n, mm = TC.Shell()
    Check(n > 10 and table.getn(mm) == 0, 'the top bar, play bar, start screen and tour have texts (' .. n .. ' checked' .. (table.getn(mm) > 0 and (', missing: ' .. mm[1]) or '') .. ')')
    n, mm = TC.Dialogs()
    Check(n > 50 and table.getn(mm) == 0, 'the dialogs of the menus have texts (' .. n .. ' checked' .. (table.getn(mm) > 0 and (', missing: ' .. mm[1]) or '') .. ')')
    -- a widget without any text is found by the check
    local W2 = import('/lua/editor/gui/widgets.lua')
    local list = {}
    W2.tracking = list
    local root2 = Group(GetFrame(0))
    root2.Left:Set(0) root2.Top:Set(0) root2.Width:Set(100) root2.Height:Set(50) root2.Depth:Set(100)
    root2.panelId = 'nosuchpanel'
    W2.Button(root2, 'Qqqq zzz', 0, 0, 60, 22, function() end)
    W2.tracking = false
    local found = 0
    for _, e in list do
        if e.button and e.button:TipText() == nil then found = found + 1 end
    end
    Check(found == 1, 'a button without a text is seen as one')
    root2:Destroy()
end

function Run()
    out, failed = {}, 0
    if not Map.Doc then Map.Load() end
    Fav.Reset()
    Catalog()
    Cache()
    Placing()
    GridWidget()
    Masks()
    StampBasics()
    HeightStamps()
    TextureStamp()
    Tools()
    Tooltips()
    table.insert(out, 1, failed == 0 and 'PASS' or ('FAIL: ' .. failed))
    return table.concat(out, '\n')
end

--- Checks that need frames: a prop is rendered offscreen into the cache, and the browser panel exists and draws it.
function RunLive()
    LIVERESULT = 'running'
    ForkThread(function()
        local res, bad = {}, 0
        local function Check2(ok, text)
            table.insert(res, (ok and '  ok   ' or '  FAIL ') .. text)
            if not ok then bad = bad + 1 end
        end
        local p = Cat.Find('props', { query = 'fieldstone01' })[1] or Cat.Entries('props')[1]
        local before = Thumbs.Stats().rendered
        Thumbs.Reset()
        local first = Thumbs.Request('props', p.key, p.source)
        Check2(first == nil, 'a prop picture is not there at first and is queued')
        for i = 1, 60 do
            WaitSeconds(0.5)
            if Thumbs.Cached('props', p.key, p.source) then break end
        end
        local path = Thumbs.Cached('props', p.key, p.source)
        Check2(path ~= nil, 'the picture was rendered in the background')
        if path then
            local px, w, h = ed_dds_read(ed_vfs_to_disk(path))
            local opaque = 0
            for i = 0, w * h - 1 do if px[i * 4 + 4] > 128 then opaque = opaque + 1 end end
            Check2(w == Thumbs.Size and opaque > 400 and opaque < w * h * 0.9, 'it shows the prop on a transparent ground (' .. opaque .. ' opaque pixels)')
        end
        local again = Thumbs.Request('props', p.key, p.source)
        Check2(again == path, 'the next request is served from the cache')
        -- the sim has nothing left of the render stand
        SimCallback({ Func = 'EdDumpAround', Args = { path = 'ed_thumb_check.txt', x = 128, z = 128, radius = 400 } }, false)
        WaitSeconds(1)
        local text = ed_read_file('ed_thumb_check.txt') or ''
        Check2(not string.find(text, string.lower(string.gsub(p.key, '^.*/', ''))), 'the prop that stood in for the render is gone')
        -- the panel
        local Shell = import('/lua/editor/gui/shell.lua')
        Shell.ShowWorkspace('Objects')
        pcall(function() Shell.FocusPanel('assets') end)
        WaitSeconds(1)
        local M = import('/lua/editor/gui/panels_assets.lua')
        Check2(M.live.assets ~= nil, 'the Assets panel can be opened')
        if M.live.assets then
            M.State.kind = 'units'
            M.State.filters = {}
            M.live.assets:Rebuild()
            Check2(table.getn(M.live.assets.shown) > 100, 'the panel lists the units')
            M.State.filters = { faction = 'UEF' }
            M.live.assets:Rebuild()
            Check2(table.getn(M.live.assets.shown) > 0 and M.live.assets.shown[1].tags.faction == 'UEF', 'a facet filter narrows the list')
            M.State.filters = {}
            M.State.kind = 'all'
            M.live.assets:Rebuild()
        end
        -- a tooltip appears after its delay, with several paragraphs and a dim shortcut line, and goes away
        local TT = import('/lua/editor/gui/tooltip.lua')
        TT.Hover(GetFrame(0), 'First paragraph of the tooltip that is long enough to wrap at the width of the box and so uses more than one line.\nSecond paragraph.\n@Shortcut: Ctrl+Z', { MouseX = 400, MouseY = 300 })
        Check2(TT.State() == 'waiting', 'a tooltip waits for its delay')
        WaitSeconds(TT.DELAY + 0.6)
        Check2(TT.State() == 'shown', 'and then shows')
        TT.Hide()
        Check2(TT.State() == 'idle', 'Hide takes it away')
        LIVERESULT = (bad == 0 and 'PASS' or ('FAIL: ' .. bad)) .. '\n' .. table.concat(res, '\n')
    end)
    return 'started'
end
