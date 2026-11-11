-- Self test of the FAF vault client (vault.lua, gui/panels_vault.lua, the ed_vault_* natives of moho/editor/EdUpVaultLua.cpp). Run in the live editor:
--   return import('/lua/editor/selftest_vault.lua').Run()            offline: the filters and links, the answer parser, the names, the saved queries, the page with fixture results
--   return import('/lua/editor/selftest_vault.lua').RunNetwork()      with the network and a FRESH process: a made-up sealed token is refused by FAF and the file emptied, the sign-in
--                                                                      shows its code (the browser is NOT opened, the code is not approved), a small map is downloaded and installed
--
-- It never signs in with an account. Upstream's own GoogleTests (VaultTests, FafApiTests) cover the library; this covers the binding and the Lua on top of it.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Vault = import('/lua/editor/vault.lua')
local UserData = import('/lua/editor/userdata.lua')

local function Join(t, sep)
    local out = {}
    for i = 1, table.getn(t) do out[i] = tostring(t[i]) end
    return table.concat(out, sep)
end

local function Has(text, part)
    return text ~= nil and string.find(text, part, 1, true) ~= nil
end

local function Reporter()
    local failures, lines = {}, {}
    local R = {}
    function R.check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end
    function R.done()
        if table.getn(failures) > 0 then return 'FAIL (' .. table.getn(failures) .. ': ' .. Join(failures, ', ') .. ')\n' .. Join(lines, '\n') end
        return 'PASS (' .. table.getn(lines) .. ' checks)\n' .. Join(lines, '\n')
    end
    return R
end

-- the JSON:API shape of the map API (upstream's FafApiTests uses the same): maps in data, their latest versions and authors in included
local ANSWER = [[{
  "data": [
    {"type": "map", "id": "101", "attributes": {"displayName": "Dual Gap Adaptive", "gamesPlayed": 54321},
     "relationships": {"latestVersion": {"data": {"type": "mapVersion", "id": "9001"}}, "author": {"data": {"type": "player", "id": "77"}}}},
    {"type": "map", "id": "102", "attributes": {"displayName": "Small Duel", "gamesPlayed": 12},
     "relationships": {"latestVersion": {"data": {"type": "mapVersion", "id": "9002"}}, "author": {"data": {"type": "player", "id": "78"}}}},
    {"type": "map", "id": "103", "attributes": {"displayName": "No Version", "gamesPlayed": 3},
     "relationships": {"latestVersion": {"data": null}}}
  ],
  "included": [
    {"type": "mapVersion", "id": "9001", "attributes": {"folderName": "dualgap_adaptive.v0012", "version": 12, "maxPlayers": 12, "width": 1024, "height": 1024, "ranked": true,
      "description": "Two {gaps}", "thumbnailUrlLarge": ""}},
    {"type": "mapVersion", "id": "9002", "attributes": {"folderName": "small_duel.v0003", "version": 3, "maxPlayers": 2, "width": 256, "height": 256, "ranked": false, "description": ""}},
    {"type": "player", "id": "77", "attributes": {"login": "CookieNoob"}},
    {"type": "player", "id": "78", "attributes": {"login": "Gator"}}
  ],
  "meta": {"page": {"number": 1, "totalRecords": 3, "totalPages": 4}}
}]]

function Run()
    local R = Reporter()
    local check = R.check
    if not rawget(_G, 'ed_vault_start') then return 'skipped (an exe without the ed_vault natives)' end

    -- ---- the natives are all there ------------------------------------------------------------------------------------------------------
    local names = { 'ed_vault_start', 'ed_vault_status', 'ed_vault_login', 'ed_vault_cancel_login', 'ed_vault_logout', 'ed_vault_search', 'ed_vault_poll', 'ed_vault_picture',
                    'ed_vault_download', 'ed_vault_download_status', 'ed_vault_download_reset', 'ed_open_url', 'ed_vault_meta', 'ed_vault_filter', 'ed_vault_url',
                    'ed_vault_query_text', 'ed_vault_query_parse', 'ed_vault_parse_search', 'ed_vault_parse_name', 'ed_vault_maps_folder', 'ed_vault_scenario', 'ed_vault_seal_test' }
    local missing = {}
    for _, n in names do
        if not rawget(_G, n) then table.insert(missing, n) end
    end
    check('natives present', table.getn(missing) == 0, Join(missing, ','))

    -- ---- the FAF client's filters and the link --------------------------------------------------------------------------------------------
    local meta = Vault.Meta()
    check('7 sizes, 1 km first, 80 km last', table.getn(meta.sizes) == 7 and meta.sizes[1].name == '1 km' and meta.sizes[7].name == '80 km' and meta.sizes[4].pixels == 512)
    check('12 sort keys, times played first', table.getn(meta.sorts) == 12 and meta.sorts[1].property == 'gamesPlayed')
    check('an empty query hides the hidden versions only', ed_vault_filter(Vault.NewQuery()) == 'latestVersion.hidden==false', ed_vault_filter(Vault.NewQuery()))
    local q = Vault.NewQuery()
    q.text, q.author, q.uploadedFrom, q.uploadedTo = 'Dual', 'Gator', '2024-01-01', '2025-06-30'
    q.widths, q.heights = { 3, 4 }, { 4 }
    q.minPlayers, q.maxPlayers, q.minScore, q.maxScore, q.rankedOnly = 4, 8, 3.5, 4.5, true
    q.sortProperty, q.descending = 'latestVersion.createTime', false
    local expect = 'displayName=="*Dual*";author.login=="*Gator*";latestVersion.updateTime=gt="2024-01-01T00:00:00Z";latestVersion.updateTime=lt="2025-06-30T00:00:00Z";'
        .. 'latestVersion.width=in=("512","1024");latestVersion.height=in=("1024");latestVersion.maxPlayers=ge=4;latestVersion.maxPlayers=le=8;'
        .. 'reviewsSummary.averageScore=ge=3.5;reviewsSummary.averageScore=le=4.5;latestVersion.ranked=="true";latestVersion.hidden==false'
    check('every filter as the FAF client writes it', ed_vault_filter(q) == expect, ed_vault_filter(q))
    local url = ed_vault_url(q, 2)
    check('the link: api, filter, include, sort, page', Has(url, 'https://api.faforever.com/data/map?filter=') and Has(url, '&include=latestVersion,author') and Has(url, '&sort=latestVersion.createTime&')
        and Has(url, 'page%5Bnumber%5D=2'), url)
    check('descending sorts with a minus', Has(ed_vault_url(Vault.NewQuery(), 1), '&sort=-gamesPlayed'))
    local any = Vault.NewQuery()
    any.maxPlayers, any.uploadedFrom = 16, '2024-1-1'
    check('"any" ends and a bad date add nothing', ed_vault_filter(any) == 'latestVersion.hidden==false', ed_vault_filter(any))
    local text = ed_vault_query_text(q)
    local back = ed_vault_query_parse(text)
    check('a saved query reads back', back ~= nil and back.text == 'Dual' and back.author == 'Gator' and back.minPlayers == 4 and back.maxPlayers == 8 and back.minScore == 3.5
        and back.rankedOnly == true and back.descending == false and back.sortProperty == 'latestVersion.createTime' and table.getn(back.widths) == 2 and back.widths[1] == 3 and back.widths[2] == 4
        and table.getn(back.heights) == 1 and back.heights[1] == 4, text)
    check('the same filter after the round trip', back ~= nil and ed_vault_filter(back) == expect)
    check('text that is no saved query is refused', ed_vault_query_parse('hello') == nil)

    -- ---- the answer ---------------------------------------------------------------------------------------------------------------------
    local r, why = ed_vault_parse_search(ANSWER)
    check('answer: the map without a version is dropped', r ~= nil and table.getn(r.maps) == 2, why)
    if r and r.maps[1] then
        local m = r.maps[1]
        check('answer: fields', m.name == 'Dual Gap Adaptive' and m.folder == 'dualgap_adaptive.v0012' and m.version == '12' and m.players == 12 and m.width == 1024 and m.ranked == true
            and m.author == 'CookieNoob' and m.gamesPlayed == 54321 and m.description == 'Two {gaps}', m.name)
        check('answer: 4 pages', r.pages == 4, tostring(r.pages))
    end
    local bad, badWhy = ed_vault_parse_search('{"errors": [{"detail": "Invalid filter"}]}')
    check('answer: the API\'s error text', bad == nil and badWhy == 'Invalid filter', tostring(badWhy))
    check('answer: not JSON', ed_vault_parse_search('<html>') == nil)

    -- ---- names and links ----------------------------------------------------------------------------------------------------------------
    local n1 = ed_vault_parse_name('dualgap_adaptive.v0012')
    check('name: a folder', n1 ~= nil and n1.folder == 'dualgap_adaptive.v0012' and n1.url == 'https://content.faforever.com/maps/dualgap_adaptive.v0012.zip', n1 and n1.url)
    local n2 = ed_vault_parse_name('https://content.faforever.com/maps/dualgap_adaptive.v0012.zip')
    check('name: a link', n2 ~= nil and n2.folder == 'dualgap_adaptive.v0012')
    check('name: a path out of the folder is refused', ed_vault_parse_name('..\\evil') == nil and ed_vault_parse_name('C:\\x.v0001') == nil and ed_vault_parse_name('') == nil)
    local n3 = ed_vault_parse_name('https://example.com/maps/x.v0001.zip')
    check('name: a link on another host downloads from the vault, never from that host', n3 ~= nil and n3.url == 'https://content.faforever.com/maps/x.v0001.zip', n3 and n3.url)

    -- ---- links open web pages only --------------------------------------------------------------------------------------------------------
    local bads = { 'file:///C:/Windows/System32/calc.exe', 'ftp://example.com/x', 'javascript:alert(1)', 'C:\\Windows\\notepad.exe', 'https://example.com/"; calc', '' }
    local refused = 0
    for _, u in bads do
        local ok = ed_open_url(u)
        if not ok then refused = refused + 1 end
    end
    check('ed_open_url refuses everything but http(s) links', refused == table.getn(bads), refused .. ' of ' .. table.getn(bads))

    -- ---- the session without the network --------------------------------------------------------------------------------------------------
    local s = ed_vault_status()
    check('status: logged out before anything', s.state == 'loggedout' or s.state == 'loggedin' or s.state == 'working', tostring(s.state))
    if s.state == 'loggedout' then
        local ok, w = ed_vault_search(Vault.NewQuery(), 1)
        check('a search needs the sign-in', ok == nil and Has(w, 'sign in'), tostring(w))
    end
    local folder = ed_vault_maps_folder()
    check('the maps folder is named', type(folder) == 'string' and Has(string.lower(folder), 'maps'), tostring(folder))
    check('a sealed file is written', ed_vault_seal_test(UserData.Path('selftest_vault/seal.bin'), 'made-up') == true)
    check('no scenario in a folder without one', ed_vault_scenario(UserData.Path('selftest_vault')) == nil)

    -- ---- saved queries ------------------------------------------------------------------------------------------------------------------------
    local file = UserData.Path('vault_queries.txt')
    local keep = ed_read_file(file)
    ed_write_file(file, '')
    check('saving needs a name', Vault.SaveQuery('   ', q) == false)
    check('save a query', Vault.SaveQuery('big and ranked', q) == true)
    local list = Vault.SavedQueries()
    check('saved queries list', table.getn(list) == 1 and list[1].name == 'big and ranked' and ed_vault_filter(list[1].query) == expect)
    check('saving under a name again replaces it', Vault.SaveQuery('big and ranked', Vault.NewQuery()) == true and table.getn(Vault.SavedQueries()) == 1 and Vault.SavedQueries()[1].query.text == '')
    Vault.DeleteQuery('big and ranked')
    check('delete a saved query', table.getn(Vault.SavedQueries()) == 0)
    ed_write_file(file, keep or '')

    -- ---- the page with fixture results (no network: the fixture has no pictures) ---------------------------------------------------------------
    local Page = import('/lua/editor/gui/panels_vault.lua')
    Page.TestHooks.noBrowser = true
    Vault.Inject(r and r.maps or {}, r and r.pages or 1, q, 1)
    local state = Page.Open{ filters = true }
    check('the page opens', state ~= nil and state ~= false and Page.IsOpen())
    if Page.IsOpen() then
        local rr = Vault.Results()
        check('the page shows the fixture results', table.getn(rr.maps) == 2 and rr.page == 1 and rr.pages == 4)
        Page.Close()
    end
    check('the page closes', not Page.IsOpen())
    Vault.Inject({}, 0)
    return R.done()
end

local netResult = false

--- The network part runs in a thread (it waits for the answers): this returns at once, NetworkResult() has the report when it is done.
function RunNetwork()
    if not rawget(_G, 'ed_vault_start') then return 'skipped (an exe without the ed_vault natives)' end
    netResult = false
    ForkThread(function()
        -- (no pcall: a wait inside one cannot yield; an error here shows in the log and the result stays 'pending')
        netResult = Network()
    end)
    return 'running: poll NetworkResult() of selftest_vault.lua'
end

function NetworkResult()
    return netResult or 'pending'
end

--- Needs a process in which the vault was not started yet (the session is one per process); never signs in.
function Network()
    local R = Reporter()
    local check = R.check
    local dir = UserData.Path('selftest_vault_net')
    local tokenFile = dir .. '/faf_login.bin'
    check('a made-up token is sealed', ed_vault_seal_test(tokenFile, 'made-up-refresh-token-for-the-test') == true)
    local function WaitFor(pred, seconds)
        local t0 = GetSystemTimeSeconds()
        while GetSystemTimeSeconds() - t0 < seconds do
            if pred() then return true end
            WaitSeconds(0.2)
        end
        return pred()
    end
    check('start', ed_vault_start{ tokenFile = tokenFile, pictureCache = dir .. '/previews', resume = true } == true)
    -- the session read the sealed file (it only tries to log in with a token it could decrypt), FAF refuses the made-up one, the file is emptied
    local sawWorking = ed_vault_status().state == 'working'
    local settled = WaitFor(function()
        local st = ed_vault_status().state
        if st == 'working' then sawWorking = true end
        return sawWorking and st ~= 'working'
    end, 30)
    local s = ed_vault_status()
    check('the sealed token was read and tried (the session went to "working")', sawWorking)
    check('FAF refuses the made-up token: logged out with a message', settled and s.state == 'loggedout' and s.message ~= '', s.state .. ' / ' .. tostring(s.message))
    local f = ed_read_file(tokenFile)
    check('the refused token was removed from the file', f == nil or f == '', f and string.len(f))
    -- the device-code step, as far as the code is shown (the page is not opened here and the code is not approved)
    ed_vault_login()
    local sawOpen = false
    local waiting = WaitFor(function()
        local st = ed_vault_status()
        if st.openPage then sawOpen = true end       -- (the flag is handed out once: the first status call after the code arrived has it)
        return st.state == 'waiting'
    end, 30)
    s = ed_vault_status()
    check('sign-in: the code is shown', waiting and type(s.userCode) == 'string' and string.len(s.userCode) >= 4, s.state .. ' / ' .. tostring(s.message))
    check('sign-in: the page is the FAF page', Has(s.verifyUrl, 'faforever.com'), tostring(s.verifyUrl))
    check('sign-in: the page is to be opened once', sawOpen and s.openPage == false)
    check('sign-in: the code has a time left', (s.secondsLeft or 0) > 0, tostring(s.secondsLeft))
    ed_vault_cancel_login()
    WaitFor(function() return ed_vault_status().state == 'loggedout' end, 15)
    check('sign-in: cancelled', ed_vault_status().state == 'loggedout')
    local ok, why = ed_vault_search(Vault.NewQuery(), 1)
    check('search refused without a sign-in', ok == nil and Has(why, 'sign in'))
    -- download by name, no sign-in: a small map into a folder of its own
    local name = 'a_new_beginning.v0001'
    local info, e = ed_vault_download(name, dir .. '/maps')
    check('download starts', info ~= nil and info.folder == name, tostring(e))
    WaitFor(function()
        local d = ed_vault_download_status()
        return d.state == 'done' or d.state == 'failed'
    end, 120)
    local d = ed_vault_download_status()
    check('download finished', d.state == 'done', d.state .. ' / ' .. tostring(d.message))
    if d.state == 'done' then
        check('download installed a map folder with a scenario', ed_vault_scenario(d.folder) == 'a_new_beginning' or ed_vault_scenario(d.folder) ~= nil, d.folder)
        check('the archive was received whole', d.received > 100000 and d.received == d.total, d.received .. ' / ' .. d.total)
    end
    ed_vault_download_reset()
    return R.done()
end
