-- The FAF vault client's model: the search the FAF client's map vault has (name, author, upload dates, sizes, players, review score, ranked, sort), the sign-in it needs,
-- the pages of results with their preview pictures, saved queries, and the download of a map into the vault's maps folder. Logic is upstream's (src/editor/doc/EdFafApi, EdVault,
-- EdHttp) bound by the ed_vault_* natives (moho/editor/EdUpVaultLua.cpp); the panel is gui/panels_vault.lua. Everything that waits for the network runs on a worker thread of the native
-- side and is POLLED here (Tick), so the UI never blocks.
--
--   Available()                  false in an exe without the natives
--   NewQuery() / CopyQuery(q)    the filters; { text, author, uploadedFrom, uploadedTo, widths = {k..}, heights = {k..} (0..6 into Meta().sizes), minPlayers, maxPlayers, minScore, maxScore,
--                                rankedOnly, sortProperty, descending }
--   Start()                      once, when the vault is first shown: previews mounted, the kept sign-in (DPAPI file `faf_login.bin` in the user folder) resumed. Nothing touches the network before.
--   Tick()                       call every frame while the vault is shown: reads the session, the search and the download; returns a list of events { kind = 'search' | 'login' | 'logout' | 'downloaded' | 'failed', ... }
--   Status()                     the last session state { state = 'loggedout' | 'working' | 'waiting' | 'loggedin', user, message, userCode, verifyUrl, secondsLeft, searching }
--   SignIn() / CancelSignIn() / SignOut()
--   Search(query, page) -> ok, why       (needs the sign-in: the map API answers 401 without one)      Results() -> { maps, pages, page, query, done }
--   Picture(url) -> vfs path | false | nil        a map's preview as a Bitmap texture path (nil while it loads, false when it can't be had)
--   Download(map, openAfter) -> ok, why       a vault map (a Results() entry, its folder name or its link): installed into MapsFolder(); `openAfter` opens it in the editor when done
--   DownloadStatus()             { state = 'idle' | 'working' | 'done' | 'failed', message, received, total, map }
--   OpenInstalled(folder, before)   mounts a map folder on disk and opens it (what a finished download does); `before` runs once the unsaved-changes question is answered, just before the map opens
--   MapsFolder()                 where downloads go (setting `vaultMapsFolder` of the user folder, else the FAF client's vault, else Documents\My Games\...\maps)
--   SavedQueries() / SaveQuery(name, q) / DeleteQuery(name)     the "Favorites", one line each in `vault_queries.txt`
--   Meta()                       { sizes = { {name, pixels}.. }, sorts = { {property, label}.. } }
--   Inject(maps, pages)          test runs: shows results without the network
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local UserData = import('/lua/editor/userdata.lua')

local started = false
local mountedPreviews = false
local previewDir = false
local meta = false

local state = {
    status = { state = 'loggedout', message = '' },
    results = { maps = {}, pages = 0, page = 0, query = false, done = false },
    download = { state = 'idle', message = '', received = 0, total = 0, map = '' },
    openAfter = false,          -- the folder name of a download that opens the map when it finishes
    searchAsk = false,          -- a search waiting for the sign-in (made while it was still working)
    wasLoggedIn = false,
    lastTick = -100,
}

function Available()
    return rawget(_G, 'ed_vault_start') ~= nil
end

function Meta()
    if not meta then meta = ed_vault_meta() end
    return meta
end

function NewQuery()
    return { text = '', author = '', uploadedFrom = '', uploadedTo = '', widths = {}, heights = {}, minPlayers = 0, maxPlayers = 0, minScore = 0, maxScore = 5,
             rankedOnly = false, sortProperty = 'gamesPlayed', descending = true }
end

local function CopyList(l)
    local out = {}
    for i, v in l do out[i] = v end
    return out
end

function CopyQuery(q)
    local c = {}
    for k, v in q do c[k] = v end
    c.widths = CopyList(q.widths or {})
    c.heights = CopyList(q.heights or {})
    return c
end

--- Adds or removes `k` (0..6) in a list of size indexes.
function ToggleSize(list, k)
    for i, v in list do
        if v == k then
            table.remove(list, i)
            return false
        end
    end
    table.insert(list, k)
    table.sort(list)
    return true
end

function HasSize(list, k)
    for _, v in list do
        if v == k then return true end
    end
    return false
end

-- ---- paths ------------------------------------------------------------------------------------------------------------------------------------

local function PreviewDir()
    if not previewDir then previewDir = UserData.Path('vault_previews') end
    return previewDir
end

local function TokenFile()
    return UserData.Path('faf_login.bin')
end

--- Where downloads go.
function MapsFolder()
    local custom = UserData.Get('vaultMapsFolder', false)
    if type(custom) == 'string' and custom ~= '' then return custom end
    local folder = ed_vault_maps_folder()
    return folder
end

-- ---- session ----------------------------------------------------------------------------------------------------------------------------------

--- Called when the vault is first shown.
function Start()
    if started then return true end
    if not Available() then return false end
    started = true
    -- the previews: a folder of the user folder, mounted so a Bitmap can show them (the folder must exist to be mounted: a placeholder file creates it)
    ed_write_file(PreviewDir() .. '/.keep', '')
    if not mountedPreviews then
        mountedPreviews = ed_vfs_mount(PreviewDir(), '/edvault') and true or false
    end
    ed_vault_start{ tokenFile = TokenFile(), pictureCache = PreviewDir(), resume = true }
    -- the last query, as the vault was left
    local saved = UserData.Get('vaultQuery', false)
    if type(saved) == 'string' and saved ~= '' then
        local q = ed_vault_query_parse(saved)
        if q then state.lastQuery = q end
    end
    return true
end

function LastQuery()
    return state.lastQuery and CopyQuery(state.lastQuery) or NewQuery()
end

function Status()
    return state.status
end

function SignIn()
    if not Start() then return end
    state.status.message = ''
    ed_vault_login()
end

function CancelSignIn()
    if Available() and started then ed_vault_cancel_login() end
end

function SignOut()
    if Available() and started then
        ed_vault_logout()
        state.results = { maps = {}, pages = 0, page = 0, query = false, done = false }
    end
end

-- ---- search -----------------------------------------------------------------------------------------------------------------------------------

function Search(query, page)
    if not Start() then return false, 'the editor has no vault support' end
    page = page or 1
    local ok, why = ed_vault_search(query, page)
    if not ok then return false, why end
    state.results.query = CopyQuery(query)
    state.results.page = page
    state.results.done = false
    UserData.Set('vaultQuery', ed_vault_query_text(query))
    return true
end

function Results()
    return state.results
end

--- Test runs and screenshots: results without the network.
function Inject(maps, pages, query, page)
    state.results = { maps = maps, pages = pages or 1, page = page or 1, query = query and CopyQuery(query) or NewQuery(), done = true }
end

--- A preview's texture path (what a Bitmap shows), or nil while it loads / false when it can't be had.
function Picture(url)
    if not url or url == '' or not Available() or not started then return false end
    local file = ed_vault_picture(url)
    if not file then return file end
    local dir = string.gsub(PreviewDir(), '\\', '/')
    file = string.gsub(file, '\\', '/')
    local low, lowDir = string.lower(file), string.lower(dir)
    local at = string.find(low, lowDir, 1, true)
    if at == 1 then
        local rest = string.sub(file, string.len(dir) + 1)
        if string.sub(rest, 1, 1) ~= '/' then rest = '/' .. rest end
        return '/edvault' .. rest
    end
    -- the preview folder is not under the path the native answered with (a relative user folder): find it by its last two parts
    local _, _, size, name = string.find(file, '/([^/]+)/([^/]+)$')
    if size and name then return '/edvault/' .. size .. '/' .. name end
    return false
end

-- ---- download ---------------------------------------------------------------------------------------------------------------------------------

function DownloadStatus()
    return state.download
end

local function InstalledScenario(folder)
    local low = string.lower(folder)
    local ok, files = pcall(DiskFindFiles, '/maps/' .. low, '*_scenario.lua')
    if ok and files and table.getn(files) > 0 then return files[1] end
    return nil
end

--- Mounts a map folder on disk (as the game would: /maps/<folder>) and opens its scenario in the editor. Returns ok, why.
function OpenInstalled(folder, before)
    local name = string.gsub(folder, '[/\\]+$', '')
    name = string.gsub(name, '^.*[/\\]', '')
    local stem = ed_vault_scenario(folder)
    if not stem then return false, 'no _scenario.lua in ' .. folder end
    local scenario = InstalledScenario(name)
    if scenario then
        -- already known to the game (mounted at start or by an earlier download): open it as it is
        local Maps = import('/lua/editor/maps.lua')
        import('/lua/editor/gui/dialogs_map.lua').Guard(function() if before then before() end Maps.Open(scenario) end)
        return true
    end
    local Maps = import('/lua/editor/maps.lua')
    import('/lua/editor/gui/dialogs_map.lua').Guard(function() if before then before() end Maps.OpenFolder(folder, stem) end)
    return true
end

--- A vault map to download: `map` is a Results() entry, a folder name (`dualgap_adaptive.v0012`) or a link to its archive. A map the game lists already is opened instead.
function Download(map, openAfter, before)
    if not Start() then return false, 'the editor has no vault support' end
    local text = type(map) == 'table' and map.folder or map
    local parsed, why = ed_vault_parse_name(text)
    if not parsed then return false, why end
    if openAfter then
        local here = InstalledScenario(parsed.folder)
        if here then
            local Maps = import('/lua/editor/maps.lua')
            import('/lua/editor/gui/dialogs_map.lua').Guard(function() if before then before() end Maps.Open(here) end)
            return true, 'already installed'
        end
    end
    local folder = MapsFolder()
    if not folder then return false, 'no folder to install maps into' end
    local started1, why2 = ed_vault_download(parsed.folder, folder)
    if not started1 then return false, why2 end
    state.openAfter = openAfter and parsed.folder or false
    state.download = { state = 'working', message = 'downloading ' .. parsed.folder, received = 0, total = 0, map = parsed.folder }
    return true
end

-- ---- the frame --------------------------------------------------------------------------------------------------------------------------------

--- Reads the session and the jobs; returns a list of events (see the header).
function Tick(force)
    local events = {}
    if not started then return events end
    local now = GetSystemTimeSeconds()
    if not force and now - state.lastTick < 0.1 then return events end
    state.lastTick = now

    local s = ed_vault_status()
    local before = state.status
    state.status = s
    if s.openPage and s.verifyUrl and s.verifyUrl ~= '' then
        table.insert(events, { kind = 'openpage', url = s.verifyUrl })
    end
    local loggedIn = s.state == 'loggedin'
    if loggedIn and not state.wasLoggedIn then table.insert(events, { kind = 'login', user = s.user }) end
    if not loggedIn and state.wasLoggedIn then table.insert(events, { kind = 'logout', message = s.message }) end
    state.wasLoggedIn = loggedIn

    local r = ed_vault_poll()
    if r then
        state.results.maps = r.maps
        state.results.pages = r.pages
        state.results.done = true
        table.insert(events, { kind = 'search', count = table.getn(r.maps), pages = r.pages, message = s.message })
    end

    local d = ed_vault_download_status()
    state.download = d
    if d.state == 'done' then
        local folder, map = d.folder, d.map
        ed_vault_download_reset()
        state.download = { state = 'idle', message = d.message, received = d.received, total = d.total, map = map }
        local open = state.openAfter == map
        state.openAfter = false
        table.insert(events, { kind = 'downloaded', map = map, folder = folder, message = d.message, open = open })
    elseif d.state == 'failed' then
        ed_vault_download_reset()
        state.download = { state = 'idle', message = d.message, received = 0, total = 0, map = d.map }
        state.openAfter = false
        table.insert(events, { kind = 'failed', message = d.message, map = d.map })
    end
    return events
end

-- ---- saved queries ----------------------------------------------------------------------------------------------------------------------------

local function QueriesFile()
    return UserData.Path('vault_queries.txt')
end

--- { { name, text, query }, ... } in the order they were saved.
function SavedQueries()
    local list = {}
    local text = ed_read_file(QueriesFile())
    if not text then return list end
    for line in string.gfind(text, '[^\n]+') do
        line = string.gsub(line, '\r$', '')
        local tab = string.find(line, '\t', 1, true)
        if tab and tab > 1 then
            local q = ed_vault_query_parse(string.sub(line, tab + 1))
            if q then table.insert(list, { name = string.sub(line, 1, tab - 1), text = string.sub(line, tab + 1), query = q }) end
        end
    end
    return list
end

local function WriteQueries(list)
    local out = {}
    for _, e in list do table.insert(out, e.name .. '\t' .. e.text) end
    return ed_write_file(QueriesFile(), table.concat(out, '\n') .. (table.getn(out) > 0 and '\n' or ''))
end

function SaveQuery(name, query)
    name = string.gsub(name or '', '[%c]', ' ')
    name = string.gsub(name, '^%s+', '')
    name = string.gsub(name, '%s+$', '')
    if name == '' then return false, 'name the query first' end
    local list = SavedQueries()
    local text = ed_vault_query_text(query)
    local replaced = false
    for _, e in list do
        if e.name == name then e.text = text replaced = true end
    end
    if not replaced then table.insert(list, { name = name, text = text }) end
    return WriteQueries(list)
end

function DeleteQuery(name)
    local list, kept = SavedQueries(), {}
    for _, e in list do
        if e.name ~= name then table.insert(kept, e) end
    end
    return WriteQueries(kept)
end
