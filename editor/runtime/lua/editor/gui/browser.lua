-- The categorized browser: one modal dialog for choosing a unit, a texture, a name from a long list ... Instead of one long scroll list it has
--
--   a sidebar     All / Starred / Recent, then every category of the entries (faction, tech, layer, type ... or the folders of a texture path) with the number of entries
--                 that match the other filters: one click narrows the list, a second click on the same value lifts the filter. Counts follow the search, so a value that
--                 would give nothing is not offered.
--   a search box  words (all must occur in the name, id, folder or a category); Enter takes the first result, so the keyboard path is: type, Enter.
--   the results   a list with a picture on every row, or a grid of pictures (the choice is kept); a click takes the entry, the pointer over a row shows it in the preview.
--   a preview     the large picture, name, id, categories, a star (favourites come first, the sidebar's Starred / Recent views list what you used).
--   filter chips  the active filters as buttons: click one to lift it.
--
--   Open{ title, entries, facets, fav, current, none, view, memory, done }      entries: list of { key, name, sub, tags = { facet = value }, folder = 'a/b/c' (optional: a folder
--         tree is added to the sidebar), thumb = texture path (optional), color = 'ffrrggbb' (a tile without a picture), source = path shown under the name }
--         facets: { { id, label }, ... } the categories (a facet nobody has a value for is left out)
--         fav: a kind of favourites.lua ('units', 'textures' ...) switches Starred / Recent and the star on;  none: text of an extra "no choice" entry (key NONE)
--         current: the key marked in the list;  view: 'list' | 'grid' (default);  memory: key to remember the view under;  done(entry) is called with the chosen entry
--   OpenUnits{ title, current, ids, done }              unit blueprints (asset catalog: faction / tech / layer / type), `ids` restricts to a list of unit ids; done(id)
--   OpenTextures{ title, sources, match, none, thumbs, current, done }     the texpicker.lua spec; the folder tree comes from the paths; done(path)
--   OpenNames{ title, names, current, done }            any list of names: categories by prefix or initial letter are made automatically; done(name)
--
-- Lua 5.0 dialect.

local Dialog = import('/lua/editor/gui/dialog.lua')
local Grid = import('/lua/editor/gui/grid.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Fav = import('/lua/editor/favourites.lua')
local UserData = import('/lua/editor/userdata.lua')

NONE = '*none*'
last = false          -- the open browser { state, rebuild, take, entries }: for the self test

local function Lower(s) return string.lower(tostring(s or '')) end

local function Words(query)
    local words = {}
    for w in string.gfind(Lower(query), '%S+') do table.insert(words, w) end
    return words
end

local function Prepare(e)
    e.tags = e.tags or {}
    e.sub = e.sub or ''
    if not e.search then
        local parts = { Lower(e.name), Lower(e.key), Lower(e.sub), Lower(e.folder) }
        for _, v in e.tags do table.insert(parts, Lower(v)) end
        e.search = table.concat(parts, ' ')
    end
    return e
end

--- The picture of an entry: a texture path, or nil.
local function ThumbOf(e)
    if e.thumb then return e.thumb end
    if e.kind and e.key and e.search then
        local ok, tex = pcall(function() return import('/lua/editor/assetcat.lua').Thumb(e) end)
        if ok then return tex end
    end
    return nil
end

local function Segments(folder)
    local list = {}
    for s in string.gfind(folder or '', '[^/]+') do table.insert(list, s) end
    return list
end

function Open(spec)
    local c = Skin.color
    local frame = GetFrame(0)
    local sc = Skin.S(1000) / 1000
    local plain = spec.plain and true or false       -- names only: no pictures, no preview, a narrower window
    local totalW = math.min(plain and 720 or 980, math.floor(frame.Width() / sc) - 40)
    local totalH = math.min(plain and 520 or 620, math.floor(frame.Height() / sc) - 50)
    local sideW = 210
    local previewW = (totalW >= 820 and not plain) and 230 or 0
    local d = Dialog.Open(spec.title or 'Choose', totalW, totalH)
    local entries = {}
    for _, e in spec.entries or {} do table.insert(entries, Prepare(e)) end
    if spec.none then
        table.insert(entries, 1, Prepare({ key = NONE, name = '(none)', sub = spec.none, tags = {}, none = true }))
    end
    local facets = {}
    for _, f in spec.facets or {} do
        local any = false
        for _, e in entries do if e.tags[f[1]] then any = true break end end
        if any then table.insert(facets, f) end
    end
    local hasFolders = false
    for _, e in entries do if e.folder and e.folder ~= '' then hasFolders = true break end end
    -- the folders every entry shares (all of them below /env, say) are not offered: the tree starts where the paths part
    local rootDepth = 0
    if hasFolders then
        local first
        for _, e in entries do
            if e.folder and e.folder ~= '' then
                local segs = Segments(e.folder)
                if not first then
                    first = segs
                    rootDepth = table.getn(segs)
                else
                    local n = 0
                    while n < rootDepth and n < table.getn(segs) and segs[n + 1] == first[n + 1] do n = n + 1 end
                    rootDepth = n
                end
            end
        end
    end
    local memory = 'browser.view.' .. tostring(spec.memory or spec.fav or spec.title or 'any')
    local S = {
        filters = {}, folder = false, onlyFav = false, recent = false, query = '', shown = {}, rows = {}, collapsed = {},
        view = UserData.Get(memory, spec.view or 'grid'), hover = false,
    }
    if previewW == 0 then S.view = 'list' end
    if plain then S.view = 'list' end

    -- ---- filtering -------------------------------------------------------------------------------------------------------------------------
    local words = {}
    local function Pass(e, skipFacet, skipFolder)
        for _, w in words do
            if not string.find(e.search, w, 1, true) then return false end
        end
        for f, v in S.filters do
            if f ~= skipFacet and e.tags[f] ~= v then return false end
        end
        if not skipFolder and S.folder then
            local folder = e.folder or ''
            if folder ~= S.folder and string.sub(folder, 1, string.len(S.folder) + 1) ~= S.folder .. '/' then return false end
        end
        if S.onlyFav and not (spec.fav and Fav.Is(spec.fav, e.key)) then return false end
        if S.recent and not (spec.fav and Fav.RecentRank(spec.fav, e.key)) then return false end
        return true
    end

    local function Counts()
        -- per facet: value -> number of entries that pass everything except that facet's own filter
        local counts = {}
        for _, f in facets do
            local per = {}
            for _, e in entries do
                local v = e.tags[f[1]]
                if v and not e.none and Pass(e, f[1]) then per[v] = (per[v] or 0) + 1 end
            end
            counts[f[1]] = per
        end
        return counts
    end

    local function FolderCounts()
        local per = {}
        for _, e in entries do
            if e.folder and e.folder ~= '' and not e.none and Pass(e, nil, true) then
                local path = ''
                for _, seg in Segments(e.folder) do
                    path = (path == '') and seg or (path .. '/' .. seg)
                    per[path] = (per[path] or 0) + 1
                end
            end
        end
        return per
    end

    local list, grid, countLabel, chips, preview, pName, pSub, pTags, pPath, star
    local selectedKey = spec.current
    local Rebuild

    local function Shown()
        local out = {}
        for _, e in entries do
            if e.none or Pass(e) then table.insert(out, e) end
        end
        if S.recent and spec.fav then
            table.sort(out, function(a, b) return (Fav.RecentRank(spec.fav, a.key) or 9999) < (Fav.RecentRank(spec.fav, b.key) or 9999) end)
        elseif spec.fav then
            local starred, rest = {}, {}
            for _, e in out do
                if e.none or Fav.Is(spec.fav, e.key) then table.insert(starred, e) else table.insert(rest, e) end
            end
            for _, e in rest do table.insert(starred, e) end
            out = starred
        end
        return out
    end

    local function SideRows()
        local rows = {}
        local total = 0
        for _, e in entries do if not e.none and Pass(e, nil, true) and not S.folder then total = total + 1 end end
        local anyFilter = S.folder or S.onlyFav or S.recent
        for _ in S.filters do anyFilter = true end
        local allCount = 0
        for _, e in entries do if not e.none then allCount = allCount + 1 end end
        table.insert(rows, { kind = 'all', label = 'All', count = allCount, on = not anyFilter })
        if spec.fav then
            local nf, nr = 0, 0
            for _, e in entries do
                if not e.none then
                    if Fav.Is(spec.fav, e.key) then nf = nf + 1 end
                    if Fav.RecentRank(spec.fav, e.key) then nr = nr + 1 end
                end
            end
            table.insert(rows, { kind = 'fav', label = 'Starred', count = nf, on = S.onlyFav })
            table.insert(rows, { kind = 'recent', label = 'Recent', count = nr, on = S.recent })
        end
        local counts = Counts()
        for _, f in facets do
            local per = counts[f[1]]
            local values = {}
            for v in per do table.insert(values, v) end
            -- a chosen value stays listed even when the other filters leave it nothing
            local chosen = S.filters[f[1]]
            if chosen and not per[chosen] then table.insert(values, chosen) per[chosen] = 0 end
            table.sort(values)
            -- a category with one value cannot narrow anything: it is not shown (unless that value is chosen)
            if table.getn(values) > 1 or (table.getn(values) == 1 and chosen) then
                table.insert(rows, { kind = 'head', facet = f[1], label = f[2], collapsed = S.collapsed[f[1]] })
                if not S.collapsed[f[1]] then
                    for _, v in values do
                        table.insert(rows, { kind = 'val', facet = f[1], value = v, label = v, count = per[v], on = (S.filters[f[1]] == v), depth = 1 })
                    end
                end
            end
        end
        if hasFolders then
            local per = FolderCounts()
            local headAt = table.getn(rows) + 1
            table.insert(rows, { kind = 'head', facet = '*folders', label = 'Folders', collapsed = S.collapsed['*folders'] })
            if not S.collapsed['*folders'] then
                local paths = {}
                for p in per do table.insert(paths, p) end
                table.sort(paths)
                local sel = S.folder or ''
                for _, p in paths do
                    local segs = Segments(p)
                    local depth = table.getn(segs)
                    local parent = string.gsub(p, '/?[^/]*$', '')
                    -- the first level below the shared root always; deeper folders only below a folder on the path of the selected one
                    local visible = (depth == rootDepth + 1)
                    if depth > rootDepth + 1 then
                        visible = (sel == parent) or (string.sub(sel, 1, string.len(parent) + 1) == parent .. '/')
                    end
                    if visible then
                        table.insert(rows, { kind = 'folder', value = p, label = segs[depth], count = per[p], on = (S.folder == p), depth = depth - rootDepth - 1 })
                    end
                end
            end
        end
        return rows
    end

    -- ---- the views -------------------------------------------------------------------------------------------------------------------------
    local side
    local function ShowPreview(e)
        if not preview then return end
        if not e then return end
        S.hover = e
        local tex = (not e.none) and ThumbOf(e) or nil
        if tex then preview:SetTexture(tex) else preview:SetSolidColor(e.color or c.panelAlt) end
        W.Fit(pName, e.name, Skin.S(previewW - 20))
        W.Fit(pSub, e.sub or '', Skin.S(previewW - 20))
        local tags = {}
        for _, f in facets do if e.tags[f[1]] then table.insert(tags, e.tags[f[1]]) end end
        W.Fit(pTags, table.concat(tags, ', '), Skin.S(previewW - 20))
        W.Fit(pPath, e.source or (e.folder and (e.folder .. '/' .. tostring(e.name))) or '', Skin.S(previewW - 20))
        if star then star:SetText((spec.fav and Fav.Is(spec.fav, e.key)) and 'Unstar' or 'Star') end
    end

    local function Take(e)
        if not e then return end
        Dialog.Close()
        if spec.fav and not e.none then pcall(Fav.Touch, spec.fav, e.key) end
        if spec.done then spec.done(e) end
    end

    local function Bind(row, index)
        local e = S.shown[index]
        if not e then return end
        local tx = Skin.S(8)
        local tex = (not e.none) and ThumbOf(e) or nil
        if row.thumb then
            if tex then row.thumb:SetTexture(tex) else row.thumb:SetSolidColor(e.color or c.panelAlt) end
            tx = row.bg.Height() + Skin.S(6)
        end
        W.Fit(row.text, e.name, math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(90)))
        row.text:SetColor((selectedKey and e.key == selectedKey) and c.accent or c.text)
        local th = row.text.Height()
        row.text.Left:Set(function() return row.bg.Left() + tx end)
        if plain then
            local ty = math.floor((row.bg.Height() - th) / 2)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
        else
            row.text.Top:Set(function() return row.bg.Top() + Skin.S(4) end)
            if not row.sub then row.sub = W.Label(row.bg, '', 0, 0, { color = c.textDim, size = 'small' }) end
            W.Fit(row.sub, e.sub or '', math.max(Skin.S(40), row.bg.Width() - tx - Skin.S(90)))
            row.sub.Left:Set(function() return row.bg.Left() + tx end)
            row.sub.Top:Set(function() return row.bg.Top() + Skin.S(4) + th + Skin.S(1) end)
        end
        if row.extra then
            local tags = {}
            for _, f in facets do if e.tags[f[1]] then table.insert(tags, e.tags[f[1]]) end end
            row.extra:SetText(plain and '' or ((spec.fav and not e.none and Fav.Is(spec.fav, e.key) and '* ' or '') .. table.concat(tags, ' ')))
            row.extra:SetColor(c.textDim)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + (plain and math.floor((row.bg.Height() - row.extra.Height()) / 2) or Skin.S(4)) end)
        end
    end

    local function CellBind(cell, index)
        local e = S.shown[index]
        if not e then return end
        local tex = (not e.none) and ThumbOf(e) or nil
        if tex then cell.thumb:SetTexture(tex) else cell.thumb:SetSolidColor(e.color or c.panelAlt) end
        if cell.mark then cell.mark:SetText((not tex) and string.upper(string.sub(tostring(e.name), 1, 4)) or '') end
        if cell.badge then cell.badge:SetText((spec.fav and not e.none and Fav.Is(spec.fav, e.key)) and '*' or '') end
        cell.text = e.name
    end

    local function Counted()
        local n = 0
        for _, e in S.shown do if not e.none then n = n + 1 end end
        local total = 0
        for _, e in entries do if not e.none then total = total + 1 end end
        countLabel:SetText(n == total and (n .. ' entries') or (n .. ' of ' .. total))
    end

    -- the active filters as buttons that lift themselves
    local chipList = {}
    local function Chips()
        for _, b in chipList do b:Destroy() end
        chipList = {}
        local items = {}
        for f, v in S.filters do table.insert(items, { text = tostring(v), lift = function() S.filters[f] = nil end }) end
        if S.folder then table.insert(items, { text = tostring(S.folder), lift = function() S.folder = false end }) end
        if S.onlyFav then table.insert(items, { text = 'Starred', lift = function() S.onlyFav = false end }) end
        if S.recent then table.insert(items, { text = 'Recent', lift = function() S.recent = false end }) end
        local x = sideW + 8
        local limit = totalW - 14 - 120
        for _, it in items do
            local text = it.text
            if string.len(text) > 28 then text = '...' .. string.sub(text, string.len(text) - 24) end
            local probe = W.Label(d.group, text .. '  x', 0, 0, {})
            local bw = math.floor(probe.Width() / sc) + 14
            probe:Destroy()
            if x + bw > limit then break end
            local b = d:Button(text .. '  x', x, 58, bw, 20, function() it.lift() Rebuild() end, { tip = 'Lift this filter.' })
            table.insert(chipList, b)
            x = x + bw + 4
        end
    end

    Rebuild = function()
        words = Words(S.query)
        S.shown = Shown()
        S.rows = SideRows()
        if side then side:Refresh() end
        if S.view == 'grid' then
            if grid then grid:Refresh() end
        elseif list then
            list:Refresh()
        end
        Counted()
        Chips()
        if S.shown[1] then ShowPreview(S.shown[1]) end
    end

    -- ---- layout ---------------------------------------------------------------------------------------------------------------------------
    local topH = 58
    local resX = sideW + 8
    local resW = totalW - sideW - 16 - previewW - ((previewW > 0) and 8 or 0)
    local resY = topH + 26
    local resH = totalH - resY - 40

    local fieldW = math.max(120, resW - 240)
    local field = d:Field(sideW + 8, 30, fieldW, 22, {
        onChange = function(text)
            S.query = text or ''
            Rebuild()
        end,
        onEscape = function() Dialog.Close() end,
    })
    field.OnEnterPressed = function(self, text)
        local first
        for _, e in S.shown do if not e.none then first = e break end end
        Take(first or S.shown[1])
        return true
    end
    countLabel = d:Label('', sideW + 8 + fieldW + 8, 34, { color = c.textDim, size = 'small' })

    local ApplyView
    local bList = d:Button('List', sideW + 8 + resW - 112, 30, 54, 22, function() S.view = 'list' UserData.Set(memory, 'list') ApplyView() Rebuild() end,
        { tip = 'Show the results as a list with pictures.' })
    local bGrid = d:Button('Grid', sideW + 8 + resW - 54, 30, 54, 22, function() S.view = 'grid' UserData.Set(memory, 'grid') ApplyView() Rebuild() end,
        { tip = 'Show the results as a grid of pictures.' })

    -- the sidebar
    side = W.VirtualList(d.group, {
        rowH = 22, extra = true,
        getCount = function() return table.getn(S.rows) end,
        bind = function(row, index)
            local r = S.rows[index]
            if not r then return end
            local indent = Skin.S(8 + (r.depth or 0) * 12)
            local label = r.label
            if r.kind == 'head' then label = (r.collapsed and '+ ' or '- ') .. string.upper(string.sub(r.label, 1, 1)) .. string.sub(r.label, 2) end
            W.Fit(row.text, label, math.max(Skin.S(40), row.bg.Width() - indent - Skin.S(46)))
            row.text:SetColor((r.kind == 'head') and c.textDim or ((r.on and c.accent) or c.text))
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + indent end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            row.extra:SetText(r.count and tostring(r.count) or '')
            row.extra:SetColor(c.textDim)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local r = S.rows[index]
            if not r then return end
            if r.kind == 'all' then
                S.filters = {} S.folder = false S.onlyFav = false S.recent = false
            elseif r.kind == 'fav' then
                S.onlyFav = not S.onlyFav
                if S.onlyFav then S.recent = false end
            elseif r.kind == 'recent' then
                S.recent = not S.recent
                if S.recent then S.onlyFav = false end
            elseif r.kind == 'head' then
                S.collapsed[r.facet] = not S.collapsed[r.facet]
            elseif r.kind == 'val' then
                if S.filters[r.facet] == r.value then S.filters[r.facet] = nil else S.filters[r.facet] = r.value end
            elseif r.kind == 'folder' then
                if S.folder == r.value then S.folder = string.gsub(r.value, '/?[^/]*$', '') if S.folder == '' then S.folder = false end else S.folder = r.value end
            end
            Rebuild()
        end,
        bgColor = c.panelAlt,
    })
    side:SetRect(Skin.S(8), Skin.S(30), Skin.S(sideW - 8), Skin.S(totalH - 30 - 40))

    list = W.VirtualList(d.group, {
        rowH = plain and 26 or 40, thumb = not plain, extra = true,
        getCount = function() return table.getn(S.shown) end,
        bind = Bind,
        onSelect = function(index) Take(S.shown[index]) end,
        onHover = function(index) if index then ShowPreview(S.shown[index]) end end,
    })
    list:SetRect(Skin.S(resX), Skin.S(resY), Skin.S(resW), Skin.S(resH))

    grid = Grid.Create(d.group, {
        cellW = 96, cellH = 112,
        getCount = function() return table.getn(S.shown) end,
        bind = CellBind,
        onSelect = function(index) Take(S.shown[index]) end,
        onHover = function(index) if index then ShowPreview(S.shown[index]) end end,
    })
    grid:SetRect(Skin.S(resX), Skin.S(resY), Skin.S(resW), Skin.S(resH))
    -- the view that is not shown leaves the screen (Maui shows a hidden child again whenever its parent refreshes)
    ApplyView = function()
        if S.view == 'grid' then
            list:SetRect(-20000, -20000, Skin.S(resW), Skin.S(resH))
            grid:SetRect(Skin.S(resX), Skin.S(resY), Skin.S(resW), Skin.S(resH))
        else
            grid:SetRect(-20000, -20000, Skin.S(resW), Skin.S(resH))
            list:SetRect(Skin.S(resX), Skin.S(resY), Skin.S(resW), Skin.S(resH))
        end
        bList:SetOn(S.view == 'list')
        bGrid:SetOn(S.view == 'grid')
        if plain then
            bList:SetHidden(true)
            bGrid:SetHidden(true)
        end
    end
    ApplyView()

    -- the preview
    if previewW > 0 then
        local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
        local px = sideW + 8 + resW + 8
        preview = Bitmap(d.group)
        preview.Depth:Set(function() return d.group.Depth() + 20 end)
        preview:SetSolidColor(c.panelAlt)
        W.Place(preview, d.group, Skin.S(px), Skin.S(30), Skin.S(previewW), Skin.S(previewW))
        preview:DisableHitTest()
        pName = d:Label('', px, 30 + previewW + 8, { color = c.text })
        pSub = d:Label('', px, 30 + previewW + 28, { color = c.textDim, size = 'small' })
        pTags = d:Label('', px, 30 + previewW + 46, { color = c.textDim, size = 'small' })
        pPath = d:Label('', px, 30 + previewW + 64, { color = c.textDim, size = 'small' })
        if spec.fav then
            star = d:Button('Star', px, 30 + previewW + 88, 70, 22, function()
                local e = S.hover
                if e and not e.none then
                    Fav.Toggle(spec.fav, e.key)
                    Rebuild()
                    ShowPreview(e)
                end
            end, { tip = 'Mark the entry shown above as a favourite: favourites come first.' })
        end
    end
    d:Button('Cancel', totalW - 100, totalH - 34, 86, 24, function() Dialog.Close() end, { tip = 'Close without choosing.' })
    d:Label('Click an entry to take it. Enter takes the first result. Esc closes.', 14, totalH - 30, { color = c.textDim, size = 'small' })

    Rebuild()
    field:AcquireFocus()
    last = { state = S, rebuild = Rebuild, take = Take, entries = entries }
end

-- ---- units ------------------------------------------------------------------------------------------------------------------------------------

function OpenUnits(spec)
    local Cat = import('/lua/editor/assetcat.lua')
    local want
    if spec.ids then
        want = {}
        for _, id in spec.ids do want[id] = true end
    end
    local list = {}
    for _, e in Cat.Entries('units') do
        if not want or want[e.key] then table.insert(list, e) end
    end
    Open{ title = spec.title or 'Unit type', entries = list, facets = Cat.Facets('units'), fav = 'units', current = spec.current, memory = 'units', view = 'list',
          done = function(e) if spec.done then spec.done(e.key) end end }
end

-- ---- textures ---------------------------------------------------------------------------------------------------------------------------------

local function TextureKind(lower)
    if string.find(lower, 'normal', 1, true) then return 'normal map' end
    if string.find(lower, '_albedo', 1, true) or string.find(lower, '_alb', 1, true) or string.find(lower, '_diff', 1, true) then return 'albedo' end
    if string.find(lower, 'mask', 1, true) then return 'mask' end
    if string.find(lower, 'spec', 1, true) then return 'specular' end
    if string.find(lower, 'cube', 1, true) then return 'cube map' end
    return 'other'
end

function OpenTextures(spec)
    local seen, entries = {}, {}
    for _, s in spec.sources or {} do
        for _, path in (DiskFindFiles(s[1], s[2]) or {}) do
            local key = string.lower(path)
            if not seen[key] and (not spec.match or spec.match(path)) then
                seen[key] = true
                local name = string.gsub(path, '^.*/', '')
                local folder = string.gsub(string.gsub(path, '/[^/]*$', ''), '^/', '')
                table.insert(entries, { key = path, name = name, sub = folder, folder = folder, source = path, thumb = (spec.thumbs ~= false) and path or nil,
                                        tags = { type = TextureKind(key) } })
            end
        end
    end
    table.sort(entries, function(a, b) return string.lower(a.key) < string.lower(b.key) end)
    Open{ title = spec.title or 'Texture', entries = entries, facets = { { 'type', 'Kind' } }, fav = 'textures', none = spec.none, current = spec.current, memory = 'textures',
          done = function(e) if spec.done then spec.done(e.key) end end }
end

-- ---- any list of names ------------------------------------------------------------------------------------------------------------------------

local function Prefix(name)
    local s = tostring(name)
    local cut = string.find(s, '[_%s%-]')
    if cut and cut > 1 then return string.sub(s, 1, cut - 1) end
    local digits = string.find(s, '%d')
    if digits and digits > 1 then return string.sub(s, 1, digits - 1) end
    return nil
end

--- Entries with automatic categories: the text before the first _ / space / digit when that makes a handful of groups, else the first letter.
function OpenNames(spec)
    local names = spec.names or {}
    local prefixes, distinct = {}, 0
    for _, n in names do
        local p = Prefix(n)
        if p then
            if not prefixes[p] then prefixes[p] = 0 distinct = distinct + 1 end
            prefixes[p] = prefixes[p] + 1
        end
    end
    local usePrefix = distinct >= 2 and distinct <= math.max(12, math.floor(table.getn(names) / 4))
    local entries = {}
    for _, n in names do
        local tags = {}
        local p = Prefix(n)
        if usePrefix then tags.group = (p and prefixes[p] > 1) and p or 'other' end
        tags.initial = string.upper(string.sub(tostring(n), 1, 1))
        table.insert(entries, { key = n, name = tostring(n), tags = tags })
    end
    local facets = {}
    if usePrefix then table.insert(facets, { 'group', 'Group' }) end
    table.insert(facets, { 'initial', 'Starts with' })
    Open{ title = spec.title, entries = entries, facets = facets, current = spec.current, memory = 'names', view = 'list', plain = true,
          done = function(e) if spec.done then spec.done(e.key) end end }
end
