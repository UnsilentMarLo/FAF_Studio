-- The FAF vault page: search the vault with every filter the FAF client's map vault has, see the previews, sign in, download a map and open it. A full window page over the editor
-- (like the start screen, which has a button for it; File > FAF vault...). The model is vault.lua; the logic is upstream's EdFafApi / EdVault bound by ed_vault_* (moho/editor/EdUpVaultLua.cpp).
--
--   Open() / Close() / IsOpen()          (the command file.vault and the start screen's button are in feature_start.lua / startscreen.lua)
--   TestHooks                 for selftests and screenshots: { noBrowser = true } keeps the sign-in from opening the browser
--
-- Top row: title, the FAF account (Sign in / Sign out), Close. Search row: the name, Search, Filters (author, uploaded from / to, widths, heights, players from / to, review score
-- from / to, ranked only, sort by and order, the query as the FAF client writes it, saved queries), the pages. "Download by name or link" works without a sign-in (the vault's
-- archives are public); the search needs one (the map API answers 401 without). The sign-in is FAF's device flow: the dialog shows the code, FAF's page opens in the browser.
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Vault = import('/lua/editor/vault.lua')

TestHooks = { noBrowser = false }

local current = false

function IsOpen()
    return current ~= false
end

function Close()
    if current then
        local state = current
        current = false
        if state.signDialog and Dialog.IsOpen() then Dialog.Close() end
        state.root.OnFrame = function() end
        if state.content then pcall(W.ScrollRelease, state.content) end
        state.root:Destroy()
    end
end

local function Say(text)
    pcall(function() import('/lua/editor/gui/shell.lua').Say(text) end)
end

local function Plural(n, one, many)
    if n == 1 then return '1 ' .. one end
    return n .. ' ' .. many
end

--- 'Size' text of a map: its width in kilometres (512 pixels are 10 km, so 51.2 per km).
local function SizeText(m)
    local function Km(px)
        local km = px / 51.2
        if km == math.floor(km) then return string.format('%d', km) end
        return string.format('%.1f', km)
    end
    local w, h = m.width or 0, m.height or 0
    if w <= 0 then return '' end
    if w == h or h <= 0 then return Km(w) .. ' km' end
    return Km(w) .. ' x ' .. Km(h) .. ' km'
end

local function MB(bytes)
    return string.format('%.1f', bytes / 1048576)
end

function Open(opts)
    opts = opts or {}
    Close()
    if not Vault.Available() then
        Say('this editor build has no FAF vault support (the ed_vault natives are missing)')
        return false
    end
    Vault.Start()
    local frame = GetFrame(0)
    local c = Skin.color
    local fw, fh = frame.Width(), frame.Height()
    local root = Group(frame)
    root.panelId = 'vault'
    root.Depth:Set(9450)               -- over the start screen (9400) and the shell, under the dialogs (9500)
    root.Left:Set(0) root.Top:Set(0) root.Width:Set(fw) root.Height:Set(fh)
    local bg = Bitmap(root)
    bg.Depth:Set(function() return root.Depth() + 1 end)
    bg:SetSolidColor(c.window)
    bg.Left:Set(0) bg.Top:Set(0) bg.Width:Set(fw) bg.Height:Set(fh)
    bg.HandleEvent = function(self, event) return true end

    local state = { root = root, q = opts.query and Vault.CopyQuery(opts.query) or Vault.LastQuery(), showFilters = opts.filters and true or false, showQuery = false,
                    cards = {}, pending = {}, seenW = fw, seenH = fh, name = '', byName = '', saveName = '', pendingSearch = false, message = '', messageBad = false }
    current = state
    local meta = Vault.Meta()

    local M = math.min(Skin.S(24), math.floor(fw / 30))
    local lh = Skin.S(28)                                   -- height of a row of controls
    local gap = Skin.S(8)

    -- ---- reading and writing the form -----------------------------------------------------------------------------------------------------
    local function ReadFields()
        local f = state.fields
        if not f then return end
        if f.name then state.q.text = f.name:GetText() end
        if f.author then state.q.author = f.author:GetText() end
        if f.from then state.q.uploadedFrom = f.from:GetText() end
        if f.to then state.q.uploadedTo = f.to:GetText() end
        if f.byName then state.byName = f.byName:GetText() end
        if f.saveName then state.saveName = f.saveName:GetText() end
    end

    local function SetMessage(text, bad)
        state.message = text or ''
        state.messageBad = bad and true or false
        if state.statusLabel then
            W.Fit(state.statusLabel, state.message, fw - 2 * M)
            state.statusLabel:SetColor(state.messageBad and c.error or c.textDim)
        end
    end

    local BuildResults, Build

    local function DoSearch(page)
        ReadFields()
        local status = Vault.Status()
        if status.state ~= 'loggedin' then
            state.pendingSearch = page
            if status.state == 'loggedout' then
                state.openSignIn()
            end
            SetMessage('Sign in to FAF to search the vault.', false)
            return
        end
        local ok, why = Vault.Search(state.q, page)
        if not ok then
            SetMessage(tostring(why), true)
        else
            state.pendingSearch = false
            SetMessage('Searching...', false)
        end
    end

    -- ---- the sign-in dialog -----------------------------------------------------------------------------------------------------------------
    function state.openSignIn()
        if Dialog.IsOpen() then return end
        if Vault.Status().state == 'loggedout' then Vault.SignIn() end
        local d = Dialog.Open('Sign in to FAF', 520, 270, function()
            state.signDialog = false
            if Vault.Status().state == 'waiting' or Vault.Status().state == 'working' then Vault.CancelSignIn() end
        end)
        state.signDialog = d
        d.lines = {}
        d:Text('FAF\'s sign-in page opens in your browser. Sign in there if asked, check that the code is the one below and approve it. This window follows.', 14, 32, { color = c.text })
        d.code = d:Label('', 14, 100, { color = c.accent, size = 32, nofit = true })
        d.left = d:Label('', 14, 150, { color = c.textDim, size = 'small' })
        d.link = d:Label('', 14, 170, { color = c.textDim, size = 'small' })
        d.msg = d:Label('', 14, 192, { color = c.error, size = 'small' })
        d:Button('Open the page again', 14, 222, 170, 28, function()
            local s = Vault.Status()
            if s.verifyUrl and s.verifyUrl ~= '' then
                local ok, why = ed_open_url(s.verifyUrl)
                if not ok then d.msg:SetText(tostring(why)) end
            end
        end)
        d:Button('Cancel', 194, 222, 100, 28, function() Dialog.Close() end)
    end

    local function UpdateSignIn()
        local d = state.signDialog
        if not d then return end
        local s = Vault.Status()
        if s.state == 'waiting' then
            d.code:SetText(s.userCode or '')
            d.left:SetText('The code runs out in ' .. tostring(s.secondsLeft or 0) .. ' s.')
            W.Fit(d.link, 'If the page did not open: ' .. tostring(s.verifyUrl or ''), d.width - Skin.S(30))
            d.msg:SetText('')
        elseif s.state == 'working' then
            d.code:SetText('...')
            d.left:SetText('Contacting FAF...')
            d.link:SetText('')
        else
            d.code:SetText('')
            d.left:SetText('')
            d.link:SetText('')
            W.Fit(d.msg, s.message or '', d.width - Skin.S(30))
        end
    end

    -- ---- the page: header, search row, filters, results -------------------------------------------------------------------------------------
    function Build()
        ReadFields()
        if state.ui then
            if state.content then pcall(W.ScrollRelease, state.content) end
            state.ui:Destroy()
        end
        state.cards, state.pending = {}, {}
        local ui = Group(root)
        ui.Depth:Set(function() return root.Depth() + 2 end)
        ui.Left:Set(0) ui.Top:Set(0) ui.Width:Set(fw) ui.Height:Set(fh)
        state.ui = ui
        local f = {}
        state.fields = f

        -- top row
        local title = W.Label(ui, 'FAF vault', M, M, { size = 24, color = c.text })
        local closeW = Skin.S(90)
        W.Button(ui, 'Close', fw - M - closeW, M, closeW, lh + Skin.S(2), function() Close() end)
        local acctW = Skin.S(110)
        state.acctButton = W.Button(ui, 'Sign in', fw - M - closeW - gap - acctW, M, acctW, lh + Skin.S(2), function()
            local s = Vault.Status()
            if s.state == 'loggedin' then
                Vault.SignOut()
                SetMessage('Signed out.', false)
            elseif s.state == 'waiting' or s.state == 'working' then
                state.openSignIn()
            else
                state.openSignIn()
            end
        end)
        local acctLabelRight = fw - M - closeW - gap - acctW - gap
        state.acctLabel = W.Label(ui, '', M + Skin.S(160), M + Skin.S(4), { color = c.textDim, maxW = function() return math.max(Skin.S(60), acctLabelRight - (M + Skin.S(160))) end })

        -- search row
        local y = M + Skin.S(48)
        W.Label(ui, 'Name', M, y + Skin.S(5), { color = c.textDim })
        local nameX = M + Skin.S(50)
        f.name = W.TextField(ui, nameX, y, Skin.S(320), lh, { text = state.q.text, tip = 'Part of the map\'s name. Enter searches.', onEnter = function() ReadFields() DoSearch(1) end })
        local sx = nameX + Skin.S(320) + gap
        W.Button(ui, 'Search', sx, y, Skin.S(90), lh, function() DoSearch(1) end)
        local filtersBtn = W.Button(ui, 'Filters', sx + Skin.S(98), y, Skin.S(90), lh, function(self)
            state.showFilters = self.on and true or false
            Build()
        end, { toggle = true })
        filtersBtn:SetOn(state.showFilters)
        local px = sx + Skin.S(98) + Skin.S(98)
        state.prevBtn = W.Button(ui, '<', px, y, Skin.S(34), lh, function()
            local r = Vault.Results()
            if r.page > 1 then DoSearch(r.page - 1) end
        end)
        state.pageLabel = W.Label(ui, '', px + Skin.S(42), y + Skin.S(5), { color = c.textDim, maxW = function() return Skin.S(150) end })
        state.nextBtn = W.Button(ui, '>', px + Skin.S(150), y, Skin.S(34), lh, function()
            local r = Vault.Results()
            if r.page < r.pages then DoSearch(r.page + 1) end
        end)
        y = y + lh + gap

        -- by name or link (no sign-in needed)
        W.Label(ui, 'Download by name or link', M, y + Skin.S(5), { color = c.textDim })
        local byX = M + Skin.S(180)
        f.byName = W.TextField(ui, byX, y, Skin.S(440), lh, { text = state.byName, tip = 'A map folder (dualgap_adaptive.v0012) or the link of its archive on content.faforever.com. Needs no sign-in.',
                                                              onEnter = function() state.downloadByName() end })
        W.Button(ui, 'Download and open', byX + Skin.S(448), y, Skin.S(160), lh, function() state.downloadByName() end)
        y = y + lh + gap

        -- saved queries
        local saved = Vault.SavedQueries()
        if table.getn(saved) > 0 then
            W.Label(ui, 'Saved', M, y + Skin.S(5), { color = c.textDim })
            local cx = M + Skin.S(50)
            for i, e in saved do
                local ew = math.min(Skin.S(180), Skin.S(24) + string.len(e.name) * Skin.S(7))
                if cx + ew + Skin.S(30) > fw - M then break end
                local entry = e
                W.Button(ui, entry.name, cx, y, ew, lh, function()
                    state.q = Vault.CopyQuery(entry.query)
                    state.showFilters = true
                    Build()
                    DoSearch(1)
                end, { tip = 'Load this query and search.' })
                W.Button(ui, 'x', cx + ew, y, Skin.S(26), lh, function()
                    Vault.DeleteQuery(entry.name)
                    Build()
                end, { tip = 'Delete this saved query.' })
                cx = cx + ew + Skin.S(26) + gap
            end
            y = y + lh + gap
        end

        -- filters
        if state.showFilters then
            local q = state.q
            local panel = Bitmap(ui)
            panel.Depth:Set(function() return ui.Depth() + 1 end)
            panel:SetSolidColor(c.panel)
            local top = y
            -- (placed after its height is known)
            local ry = y + Skin.S(8)
            local ix = M + Skin.S(10)
            W.Label(ui, 'Author', ix, ry + Skin.S(5), { color = c.textDim })
            f.author = W.TextField(ui, ix + Skin.S(56), ry, Skin.S(190), lh, { text = q.author, tip = 'The uploader\'s FAF name (part of it).' })
            local dx = ix + Skin.S(56) + Skin.S(190) + Skin.S(24)
            W.Label(ui, 'Uploaded from', dx, ry + Skin.S(5), { color = c.textDim })
            f.from = W.TextField(ui, dx + Skin.S(100), ry, Skin.S(100), lh, { text = q.uploadedFrom, tip = 'Updated after this day, YYYY-MM-DD.' })
            W.Label(ui, 'to', dx + Skin.S(210), ry + Skin.S(5), { color = c.textDim })
            f.to = W.TextField(ui, dx + Skin.S(232), ry, Skin.S(100), lh, { text = q.uploadedTo, tip = 'Updated before this day, YYYY-MM-DD.' })
            ry = ry + lh + gap

            local function SizeRow(label, list, tip)
                W.Label(ui, label, ix, ry + Skin.S(5), { color = c.textDim })
                local bx = ix + Skin.S(56)
                for k = 0, 6 do
                    local kk = k
                    local b = W.Button(ui, meta.sizes[k + 1].name, bx, ry, Skin.S(60), lh, function(self)
                        Vault.ToggleSize(list, kk)
                    end, { toggle = true, tip = tip })
                    b:SetOn(Vault.HasSize(list, k))
                    bx = bx + Skin.S(66)
                end
                ry = ry + lh + gap
            end
            SizeRow('Width', q.widths, 'Maps this wide (any when none is chosen).')
            SizeRow('Height', q.heights, 'Maps this high (any when none is chosen).')

            -- players and review score: a slider each
            local sw = math.floor((fw - 2 * M - Skin.S(20) - 3 * gap) / 4)
            local sliders = {
                W.Slider(ui, { label = 'Players from', min = 0, max = 16, step = 1, fmt = '%d', get = function() return q.minPlayers end, set = function(v) q.minPlayers = v end,
                               tip = 'Max players of the map, from (0 is any).' }),
                W.Slider(ui, { label = 'Players to', min = 0, max = 16, step = 1, fmt = '%d', get = function() return q.maxPlayers end, set = function(v) q.maxPlayers = v end,
                               tip = 'Max players of the map, up to (16 is any).' }),
                W.Slider(ui, { label = 'Review score from', min = 0, max = 5, step = 0.5, fmt = '%.1f', get = function() return q.minScore end, set = function(v) q.minScore = v end,
                               tip = 'Average review score, from.' }),
                W.Slider(ui, { label = 'Review score to', min = 0, max = 5, step = 0.5, fmt = '%.1f', get = function() return q.maxScore end, set = function(v) q.maxScore = v end,
                               tip = 'Average review score, up to.' }),
            }
            for i, s in sliders do s:Place(ix + (i - 1) * (sw + gap), ry, sw) end
            ry = ry + Skin.S(50)

            -- ranked, sort, order, query text, save
            local ranked = W.Button(ui, 'Ranked only', ix, ry, Skin.S(110), lh, function(self) q.rankedOnly = self.on and true or false end, { toggle = true, tip = 'Only maps FAF ranks.' })
            ranked:SetOn(q.rankedOnly)
            local sortLabel = function()
                for _, s in meta.sorts do
                    if s.property == q.sortProperty then return 'Sort by: ' .. s.label end
                end
                return 'Sort by: ' .. tostring(q.sortProperty)
            end
            local sortBtn
            sortBtn = W.Button(ui, sortLabel(), ix + Skin.S(118), ry, Skin.S(250), lh, function()
                local n = table.getn(meta.sorts)
                local at = 0
                for i, s in meta.sorts do
                    if s.property == q.sortProperty then at = i end
                end
                q.sortProperty = meta.sorts[math.mod(at, n) + 1].property
                sortBtn:SetText(sortLabel())
            end, { tip = 'What the results are ordered by. Click for the next one.' })
            local desc = W.Button(ui, 'Descending', ix + Skin.S(376), ry, Skin.S(110), lh, function(self) q.descending = self.on and true or false end, { toggle = true, tip = 'Highest first.' })
            desc:SetOn(q.descending)
            W.Button(ui, 'Reset filters', ix + Skin.S(494), ry, Skin.S(110), lh, function()
                local keepText = state.q.text
                state.q = Vault.NewQuery()
                state.q.text = keepText
                Build()
            end, { tip = 'Clear every filter (the name stays).' })
            local showQ = W.Button(ui, 'Show query', ix + Skin.S(612), ry, Skin.S(110), lh, function(self)
                state.showQuery = self.on and true or false
                Build()
            end, { toggle = true, tip = 'Show the query as the FAF client writes it.' })
            showQ:SetOn(state.showQuery)
            f.saveName = W.TextField(ui, ix + Skin.S(730), ry, Skin.S(150), lh, { text = state.saveName, tip = 'A name for this query.' })
            W.Button(ui, 'Save query', ix + Skin.S(888), ry, Skin.S(100), lh, function()
                ReadFields()
                local ok, why = Vault.SaveQuery(state.saveName, state.q)
                if ok then
                    state.saveName = ''
                    Build()
                    SetMessage('Query saved.', false)
                else
                    SetMessage(tostring(why), true)
                end
            end, { tip = 'Keep this query under the name (the row of saved queries).' })
            ry = ry + lh + gap
            if state.showQuery then
                local shown = ed_vault_filter(state.q)
                local line = W.Label(ui, shown ~= '' and shown or '(no filter)', ix, ry, { color = c.textDim, size = 'small', maxW = function() return fw - 2 * M - Skin.S(20) end })
                ry = ry + Skin.S(20)
            end
            W.Place(panel, ui, M, top, fw - 2 * M, ry - top)
            y = ry + gap
        end

        -- the results
        local holderTop = y
        local holderH = math.max(Skin.S(80), fh - M - Skin.S(26) - holderTop)
        local holder = Group(ui)
        holder.Depth:Set(function() return ui.Depth() + 3 end)
        holder.Left:Set(M) holder.Top:Set(holderTop) holder.Width:Set(fw - 2 * M) holder.Height:Set(holderH)
        state.holder = holder
        state.content = W.ScrollContent(holder, 'vaultresults')
        state.statusLabel = W.Label(ui, '', M, fh - M - Skin.S(18), { color = c.textDim, size = 'small', maxW = function() return fw - 2 * M end })
        SetMessage(state.message, state.messageBad)
        BuildResults()
        state.lastAcct = nil
    end

    function state.downloadByName()
        ReadFields()
        local text = state.byName
        if text == nil or string.gsub(text, '%s', '') == '' then
            SetMessage('Type a map folder (dualgap_adaptive.v0012) or the link of its archive.', true)
            return
        end
        local before = function()
            if state.signDialog and Dialog.IsOpen() then Dialog.Close() end
            Close()
            pcall(function() import('/lua/editor/gui/startscreen.lua').Close() end)
        end
        local ok, why = Vault.Download(text, true, before)
        if not ok then
            SetMessage(tostring(why), true)
        else
            SetMessage(why or 'Downloading...', false)
        end
    end

    function BuildResults()
        local content = state.content
        if not content then return end
        for _, card in state.cards do card:Destroy() end
        state.cards, state.pending = {}, {}
        W.BeginLayout(content)
        local r = Vault.Results()
        local holder = state.holder
        local rw = holder.Width()
        local cardW, cardH = Skin.S(188), Skin.S(284)
        local cgap = Skin.S(12)
        local cols = math.max(1, math.floor((rw - Skin.S(Skin.size.scrollW) + cgap) / (cardW + cgap)))
        local status = Vault.Status()
        local count = table.getn(r.maps)
        if count == 0 then
            local msg
            if r.done then
                msg = 'No map matches this search.'
            elseif status.state ~= 'loggedin' then
                msg = 'Sign in to FAF (top right) to search the vault. A map whose name you know can be downloaded above without signing in.'
            else
                msg = 'Type a name or choose filters, then Search.'
            end
            local l = W.Label(content, msg, Skin.S(4), Skin.S(8), { color = c.textDim, maxW = function() return rw - Skin.S(20) end })
            table.insert(state.cards, l)
        end
        for i, m in r.maps do
            local map = m
            local col, row = math.mod(i - 1, cols), math.floor((i - 1) / cols)
            local cx, cy = col * (cardW + cgap), row * (cardH + cgap)
            local card = Bitmap(holder)
            card.Depth:Set(function() return holder.Depth() + 4 end)
            card:SetSolidColor(c.panelAlt)
            W.Place(card, content, cx, cy, cardW, cardH)
            card.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then self:SetSolidColor(c.hover) return true
                elseif event.Type == 'MouseExit' then self:SetSolidColor(c.panelAlt) return true end
                return false
            end
            local ts = cardW - Skin.S(12)
            local thumb = Bitmap(card)
            thumb.Depth:Set(function() return card.Depth() + 5 end)
            thumb:SetSolidColor(c.panel)
            thumb:DisableHitTest()
            W.Place(thumb, content, cx + Skin.S(6), cy + Skin.S(6), ts, ts)
            if map.thumbnail and map.thumbnail ~= '' then table.insert(state.pending, { thumb = thumb, url = map.thumbnail }) end
            local name = W.Label(card, map.name, Skin.S(6), ts + Skin.S(10), { color = c.text })
            W.Fit(name, map.name, cardW - Skin.S(12))
            local by = W.Label(card, 'by ' .. tostring(map.author or ''), Skin.S(6), ts + Skin.S(28), { color = c.textDim, size = 'small' })
            W.Fit(by, 'by ' .. tostring(map.author or ''), cardW - Skin.S(12))
            local info = SizeText(map) .. '   ' .. Plural(map.players or 0, 'player', 'players') .. '   v' .. tostring(map.version or '')
            local il = W.Label(card, info, Skin.S(6), ts + Skin.S(44), { color = c.textDim, size = 'small' })
            W.Fit(il, info, cardW - Skin.S(12))
            local played = Plural(map.gamesPlayed or 0, 'game', 'games') .. (map.ranked and '   ranked' or '')
            local pl = W.Label(card, played, Skin.S(6), ts + Skin.S(60), { color = map.ranked and c.ok or c.textDim, size = 'small' })
            W.Fit(pl, played, cardW - Skin.S(12))
            W.Button(card, 'Download and open', Skin.S(6), cardH - Skin.S(30), cardW - Skin.S(12), Skin.S(24), function()
                local before = function()
                    if state.signDialog and Dialog.IsOpen() then Dialog.Close() end
                    Close()
                    pcall(function() import('/lua/editor/gui/startscreen.lua').Close() end)
                end
                local ok, why = Vault.Download(map, true, before)
                if not ok then SetMessage(tostring(why), true) else SetMessage(why or ('Downloading ' .. tostring(map.folder) .. '...'), false) end
            end, { tip = map.description and map.description ~= '' and map.description or 'Download this map into your maps folder and open it.' })
            table.insert(state.cards, card)
        end
        W.EndLayout(content)
        -- the pager
        if state.pageLabel then
            if r.pages and r.pages > 0 and r.page and r.page > 0 then
                state.pageLabel:SetText('Page ' .. r.page .. ' of ' .. r.pages)
            else
                state.pageLabel:SetText('')
            end
        end
    end

    -- ---- every frame ------------------------------------------------------------------------------------------------------------------------
    local function UpdateAccount()
        local s = Vault.Status()
        local key = s.state .. '|' .. tostring(s.user)
        if key == state.lastAcct then return end
        state.lastAcct = key
        local text, button = 'Not signed in', 'Sign in'
        if s.state == 'loggedin' then
            text = 'Signed in as ' .. tostring(s.user ~= '' and s.user or 'FAF')
            button = 'Sign out'
        elseif s.state == 'waiting' then
            text, button = 'Waiting for your approval in the browser', 'Show code'
        elseif s.state == 'working' then
            text, button = 'Signing in...', 'Show'
        end
        state.acctLabel:SetText(text)
        state.acctLabel:SetColor(s.state == 'loggedin' and c.ok or c.textDim)
        state.acctButton:SetText(button)
    end

    root:SetNeedsFrameUpdate(true)
    root.OnFrame = function(self, delta)
        if current ~= state then return end
        -- a window resize: the page is laid out for one size and is built again once it has stopped changing
        local nw, nh = frame.Width(), frame.Height()
        if nw ~= state.seenW or nh ~= state.seenH then
            state.seenW, state.seenH = nw, nh
            state.sizeAt = GetSystemTimeSeconds()
        elseif state.sizeAt and GetSystemTimeSeconds() - state.sizeAt > 0.25 and (nw ~= fw or nh ~= fh) and not state.rebuilding then
            state.rebuilding = true
            ForkThread(function()
                if current == state then
                    local q, filters, shown = state.q, state.showFilters, state.showQuery
                    ReadFields()
                    Close()
                    local page = Open{ query = state.q, filters = filters }
                end
            end)
            return
        end
        local events = Vault.Tick()
        for _, e in events do
            if e.kind == 'openpage' then
                if not TestHooks.noBrowser then
                    local ok, why = ed_open_url(e.url)
                    if not ok then SetMessage('The browser could not be started: use the link in the sign-in window.', true) end
                end
            elseif e.kind == 'login' then
                if state.signDialog and Dialog.IsOpen() then Dialog.Close() end
                SetMessage('Signed in.', false)
                BuildResults()
                if state.pendingSearch then
                    DoSearch(state.pendingSearch)
                elseif not Vault.Results().done then
                    DoSearch(1)
                end
            elseif e.kind == 'logout' then
                BuildResults()
                if e.message and e.message ~= '' then SetMessage(e.message, false) end
            elseif e.kind == 'search' then
                local s = Vault.Status()
                if s.message and s.message ~= '' and s.message ~= 'Logged in to FAF' then
                    SetMessage(s.message, true)
                else
                    SetMessage(Plural(e.count, 'map', 'maps') .. ' on this page.', false)
                end
                BuildResults()
            elseif e.kind == 'downloaded' then
                SetMessage(e.message or 'Downloaded.', false)
                if e.open then
                    local ok, why = Vault.OpenInstalled(e.folder, function()
                        if state.signDialog and Dialog.IsOpen() then Dialog.Close() end
                        Close()
                        pcall(function() import('/lua/editor/gui/startscreen.lua').Close() end)
                    end)
                    if not ok then SetMessage(tostring(why), true) end
                end
            elseif e.kind == 'failed' then
                SetMessage(e.message or 'The download failed.', true)
            end
        end
        if current ~= state then return end
        UpdateAccount()
        UpdateSignIn()
        -- the download's progress
        local d = Vault.DownloadStatus()
        if d.state == 'working' then
            local text = 'Downloading ' .. tostring(d.map) .. ': ' .. MB(d.received or 0) .. (d.total and d.total > 0 and (' of ' .. MB(d.total)) or '') .. ' MB'
            if text ~= state.lastProgress then
                state.lastProgress = text
                SetMessage(text, false)
            end
        end
        -- previews arrive a few per frame
        local budget = 6
        local keep = {}
        for _, p in state.pending do
            if budget > 0 then
                budget = budget - 1
                local vfs = Vault.Picture(p.url)
                if type(vfs) == 'string' then
                    p.thumb:SetTexture(vfs)
                elseif vfs == nil then
                    table.insert(keep, p)
                end
            else
                table.insert(keep, p)
            end
        end
        state.pending = keep
    end

    Build()
    -- a kept sign-in is resumed by Vault.Start: the page shows it in a moment
    return state
end

