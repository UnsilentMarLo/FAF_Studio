-- Thumbnails of the asset browser (gui/panels_assets.lua): pictures of props, decals and textures, made lazily in the background and kept on disk.
--
--   decals, textures  the DDS is reduced natively (ed_dds_thumb: one call, any size of source; it starts from a small mip level of the file, so a 2048 x 2048 texture costs a 256 x 256 decode)
--   texprev           the same at 256 x 256 (Sizes): the large preview of the texture browser, instead of loading the whole texture
--   props             the prop stands in the lab spot (sim callback EdThumbProp) and the offscreen renderer of the icon generator takes its picture from a fixed camera
--                     (ed_icon_request, the fitting loop of icongen.lua): 96 x 96 DXT5 with alpha
--
-- The cache is a folder of the user data, `assetthumbs/v<Version>/`, mounted as /edassets. A file name is kind + a hash of (key, time stamp of the source file, Version): a changed source
-- gets a new name and the old file is left for Prune(); changing the picture recipe means raising Version, which starts a new folder (the old folders are listed by OldFolders()).
--
--   Request(kind, key, source[, owner]) -> vfs path | nil   the picture when it is in the cache; else nil and the request is queued. Requests are served in the order they were asked within
--                              the owner's latest wave (a list binds its rows top to bottom: the first visible row is made first)
--   NewWave(owner)             a list calls it before it binds its visible rows again: what the owner asked in an earlier wave and did not ask again (scrolled out of view, the list changed) is
--                              cancelled. Nothing is made for it, so a long scroll does not leave seconds of useless decoding behind
--   Warm(kind, items)          items = { { key, source }, ... }: pictures made in the background when nothing visible waits (the whole layer texture set the first time a picker opens), never cancelled
--   SetBudget(seconds)         how long the worker may work per tick (default 12 ms; the open browser raises it, nobody scrolls while a modal dialog waits for its pictures)
--   Cached(kind, key, source)  -> vfs path | nil   only what is on disk
--   Listen(id, fn) / Unlisten(id)  fn is called (at most every 0.2 s) when pictures were made, so a panel can redraw
--   Hold(seconds)              the background worker makes no picture for this long (a list that is being scrolled calls it on every wheel step: decoding a big DDS blocks the
--                              frame, and the rows that scroll by are not wanted anyway)
--   Pause(on)                  the renders wait while the unit viewer / a capture / a stroke needs the renderer
--   Stats()                    { queued, made, failed, rendered, hits, cancelled, warm, avgMs, maxMs }   (avgMs / maxMs: the time of one native picture, also in the perf report as 'thumbs: make <kind>')
--   Clear()                    forgets what is queued and failed (the files stay)
--
-- Lua 5.0 dialect. The worker is a thread: nothing in here waits inside a pcall.

local UserData = import('/lua/editor/userdata.lua')
local Perf = import('/lua/editor/perf.lua')

Version = 1
Size = 96
Sizes = { texprev = 256 }       -- kinds whose picture is not Size wide
KEEP = 0.15             -- pieces smaller than this fraction of the largest piece of the render are ignored
ABOVE = 30             -- how far above the ground a prop stands while its picture is taken

Listeners = {}
Paused = false
Trace = false            -- a list: RenderNow records the fitting steps in it

local mounted = false
local known = {}         -- cache file names known to exist
local failedNames = {}   -- cache file names that could not be made (not asked again until Clear)
local queued = {}        -- id -> true
local wanted = {}        -- queued decals / textures that a list asked for (served by rank)
local warmQ = {}         -- queued warm-up requests, first in first out
local warmHead = 1
local warmSeen = {}      -- id -> true: asked to warm in this session (not checked again)
local waves = {}         -- owner -> number of its latest wave
local rankCounter = 0
local budget = 0.012       -- seconds of work per worker tick
local MAX_WARM = 3000
local lastNotify = 0
local renders = {}       -- queued props
local running = false
local holdUntil = 0
local nameCache = {}     -- kind|key -> { name, at, version, source }: Name() reads the source's time stamp from the disk and hashes the name three times, too much for every row of every scroll step
local NAME_TTL = 5       -- seconds a cache name is trusted (a source file that changes is noticed after that)
local MAX_NATIVE_QUEUE = 200
local MAX_RENDER_QUEUE = 24
local counts = { made = 0, failed = 0, rendered = 0, hits = 0, cancelled = 0, warm = 0, ms = 0, maxMs = 0 }
local changedAt = false
local infoPath = 'ed_thumb_info.txt'

function Dir() return UserData.Path('assetthumbs/v' .. Version) end

local function Mount()
    if mounted then return true end
    ed_write_file(Dir() .. '/.keep', '')
    mounted = ed_vfs_mount(Dir(), '/edassets') and true or false
    return mounted
end

local function Hash(text, mod, mul)
    local h = 7
    for i = 1, string.len(text) do
        h = math.mod(h * mul + string.byte(text, i), mod)
    end
    return h
end

--- The time stamp of the file a VFS path comes from; a file inside an archive is stamped by the archive.
function SourceStamp(source)
    local disk = source and ed_vfs_to_disk and ed_vfs_to_disk(source)
    if not disk then return '0' end
    local scd = string.find(string.lower(disk), '%.scd[\\/]')
    if scd then disk = string.sub(disk, 1, scd + 3) end
    return tostring(ed_file_stamp(disk) or '0')
end

--- The cache file name of an entry (no folder).
function Name(kind, key, source)
    local text = key .. '|' .. SourceStamp(source) .. '|' .. Version
    return string.format('%s_%04x%04x%04x.dds', kind, Hash(text, 65521, 31), Hash(text, 65519, 37), Hash(text, 65497, 41))
end

local function Exists(name)
    if known[name] then return true end
    local ok = ed_file_exists(Dir() .. '/' .. name) and true or false
    if ok then known[name] = true end
    return ok
end

--- Name() remembered for NAME_TTL seconds. Returns the name and the request id.
local function NameOf(kind, key, source)
    local id = kind .. '|' .. key
    local now = GetSystemTimeSeconds()
    local c = nameCache[id]
    if c and c.version == Version and c.source == source and now - c.at < NAME_TTL then return c.name, id end
    local name = Name(kind, key, source)
    nameCache[id] = { name = name, at = now, version = Version, source = source }
    return name, id
end

function Cached(kind, key, source)
    local name = NameOf(kind, key, source)
    if Exists(name) and Mount() then
        counts.hits = counts.hits + 1
        return '/edassets/' .. name
    end
    return nil
end

-- ---- making -----------------------------------------------------------------------------------------------------------------------------------

local function Changed()
    changedAt = GetSystemTimeSeconds()
end

--- The picture of a stamp shape (brushes.lua): its mask as a 48 x 48 greyscale picture, white = 1.
local function MakeShape(req)
    local Brushes = import('/lua/editor/brushes.lua')
    local n = 48
    local px = {}
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local m = Brushes.Sample(req.key, (i + 0.5) / n * 2 - 1, (j + 0.5) / n * 2 - 1, 64)
            local v = math.floor(math.max(0, math.min(1, m)) * 255 + 0.5)
            local k = (j * n + i) * 4
            px[k + 1], px[k + 2], px[k + 3], px[k + 4] = v, v, v, 255
        end
    end
    return ed_dds_write(Dir() .. '/' .. req.name, n, n, px, 1)
end

local function MakeNative(req)
    if req.kind == 'shapes' then
        if MakeShape(req) then
            known[req.name] = true
            counts.made = counts.made + 1
        else
            failedNames[req.name] = true
            counts.failed = counts.failed + 1
        end
        return
    end
    local disk = ed_vfs_to_disk(req.source)
    local path = Dir() .. '/' .. req.name
    -- (the last argument: start from a small mip level of the file)
    local t0 = GetSystemTimeSeconds()
    local w = disk and ed_dds_thumb and ed_dds_thumb(disk, path, Sizes[req.kind] or Size, 1)
    local dt = GetSystemTimeSeconds() - t0
    counts.ms = counts.ms + dt * 1000
    if dt * 1000 > counts.maxMs then counts.maxMs = dt * 1000 end
    Perf.End('thumbs: make ' .. tostring(req.kind), Perf.Enabled and t0 or nil)
    if w then
        known[req.name] = true
        counts.made = counts.made + 1
    else
        failedNames[req.name] = true
        counts.failed = counts.failed + 1
    end
end

--- True when the owner of a request asked for something newer since (a wave it is not part of).
local function Stale(req)
    return req.owner ~= nil and req.wave < (waves[req.owner] or 0)
end

--- Removes what is stale from `wanted` and takes the request with the lowest rank (the first one the latest wave asked for); nil when there is none.
local function NextWanted()
    local n = table.getn(wanted)
    local j = 0
    local best, bestAt
    for i = 1, n do
        local r = wanted[i]
        if Stale(r) then
            queued[r.id] = nil
            counts.cancelled = counts.cancelled + 1
        else
            j = j + 1
            wanted[j] = r
            if not best or r.rank < best.rank then best, bestAt = r, j end
        end
    end
    for i = j + 1, n do wanted[i] = nil end
    if best then table.remove(wanted, bestAt) end
    return best
end

--- The next warm-up request that is still to be made (those already on disk are skipped here); nil when the queue is empty or `limit` (a time) is reached.
local function NextWarm(limit)
    while warmHead <= table.getn(warmQ) do
        local r = warmQ[warmHead]
        warmQ[warmHead] = false
        warmHead = warmHead + 1
        if r and r.state == 'warm' then
            r.name = NameOf(r.kind, r.key, r.source)
            if known[r.name] or failedNames[r.name] or Exists(r.name) then
                r.state = 'done'
                queued[r.id] = nil
            else
                return r
            end
        end
        if GetSystemTimeSeconds() >= limit then return nil end
    end
    if warmHead > 1 then warmQ, warmHead = {}, 1 end
    return nil
end

local function Pending()
    for i = 1, 300 do
        WaitSeconds(0.03)
        local st, msg = ed_icon_status()
        if st ~= 'pending' then return st, msg end
    end
    return 'error', 'timeout'
end

local R = { heading = 0.6, pitch = 0.5, fov = 22, probe = 256, render = 384, probeFill = 0.8, fill = 0.92 }

local function Shot(x, y, z, zoom, size)
    local ok, why = ed_icon_request(x, y, z, R.heading, R.pitch, zoom, R.fov, size, 0)
    if not ok then return nil, why end
    local st, msg = Pending()
    if st ~= 'done' then return nil, msg end
    return true
end

local spot = false       -- { x, y, z, doc } the stand of the props, chosen per map document

--- A point of the map the camera looks at least, as candidates for the stand of a prop: a grid over the map, farthest from the camera focus first.
function Candidates()
    local w = ed_terrain_info()
    local size = (w or 257) - 1
    local fx, fz = size / 2, size / 2
    pcall(function()
        local p = GetCamera('WorldCamera'):GetFocusPosition()
        fx, fz = p[1], p[3]
    end)
    local list = {}
    for _, a in { 0.15, 0.3, 0.5, 0.7, 0.85 } do
        for _, b in { 0.15, 0.3, 0.5, 0.7, 0.85 } do
            local x, z = a * size, b * size
            table.insert(list, { x = x, z = z, d = (x - fx) * (x - fx) + (z - fz) * (z - fz) })
        end
    end
    table.sort(list, function(p, q) return p.d > q.d end)
    return list
end

--- THREAD. The stand of the props: a spot high above the map where the offscreen render of the scene is empty (the map may have 3D scenery of its own around and beyond the playable area,
--- and the offscreen pass draws all of it); the first of Candidates() that is empty from the fixed camera at three distances, else the emptiest. Kept until the map document changes.
function FindSpot()
    local Map = import('/lua/editor/map.lua')
    if spot and spot.doc == Map.Doc then return spot.x, spot.y, spot.z end
    local best, bestN = false, 1e9
    local tried = 0
    for _, c in Candidates() do
        tried = tried + 1
        if tried > 14 then break end
        local y = (ed_terrain_get(math.floor(c.x + 0.5), math.floor(c.z + 0.5)) or 0) + ABOVE
        local n = 0
        for _, zoom in { 12, 30, 70 } do
            if ed_icon_request(c.x, y + 1, c.z, R.heading, R.pitch, zoom, R.fov, 128, 0) then
                local st = Pending()
                local x0, y0, x1, y1, count = ed_icon_bounds(0.05, 0)
                if st == 'done' and count then n = n + count end
            end
        end
        if n < bestN then best, bestN = { x = c.x, y = y, z = c.z }, n end
        if n == 0 then break end
    end
    if not best then return nil end
    spot = { x = best.x, y = best.y, z = best.z, doc = Map.Doc, empty = bestN == 0 }
    return best.x, best.y, best.z
end

--- THREAD. True when the renderer is free for a prop picture.
local function CanRender()
    if Paused or not ed_icon_request then return false end
    local View = import('/lua/editor/unitview.lua')
    if View.Id then return false end
    local ok, Gen = pcall(import, '/lua/editor/icongen.lua')
    if ok and Gen.Busy then return false end
    local Map = import('/lua/editor/map.lua')
    return Map.Doc and true or false
end

--- THREAD. Stands the prop in the lab spot, fits the camera by the alpha box of probe renders, renders and writes the picture. Returns true | nil, reason.
local function RenderProp(req)
    -- the prop stands high above the corner of the map the camera looks at least (a prop below the ground is not drawn by the offscreen pass either)
    local lx, gy, lz = FindSpot()
    if not lx then return nil, 'no free spot for the render' end
    ed_write_file(infoPath, '')
    SimCallback({ Func = 'EdThumbProp', Args = { bp = req.key, x = lx, y = gy, z = lz, path = infoPath } }, false)
    local answer
    for i = 1, 20 do
        WaitSeconds(0.1)
        answer = ed_read_file(infoPath)
        if answer and answer ~= '' then break end
    end
    local result, why
    if answer and string.sub(answer, 1, 2) == 'ok' then
        WaitSeconds(0.4)             -- the renderer has the mesh a frame or two later
        result, why = nil, 'no picture'
        local fx, fy, fz = lx, gy + 1, lz
        local zoom = 14
        local rx, rz = -math.cos(R.heading), math.sin(R.heading)
        local size = R.probe
        local tries = 0
        local sc = size / 512
        local good = true
        for i = 1, 6 do
            local ok, err = Shot(fx, fy, fz, zoom, size)
            if not ok then why = err good = false break end
            local x0, y0, x1, y1, n = ed_icon_bounds(0.05, KEEP)
            if Trace then table.insert(Trace, string.format('probe %d zoom %.2f focus %.1f,%.1f,%.1f box %s,%s,%s,%s n %s', i, zoom, fx, fy, fz, tostring(x0), tostring(y0), tostring(x1), tostring(y1), tostring(n))) end
            if not x0 then why = y0 good = false break end
            if n < 8 then
                tries = tries + 1
                if tries > 3 then why = 'the prop does not show in the render' good = false break end
                zoom = zoom * 1.8
                WaitSeconds(0.3)
            else
                local w, h = x1 - x0 + 1, y1 - y0 + 1
                local cx, cy = (x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2
                local touch = x0 <= 0 or y0 <= 0 or x1 >= size - 1 or y1 >= size - 1
                local kx = 672 * sc / zoom
                local ky = 540 * math.cos(R.pitch) * sc / zoom
                local ex, ey = cx - size / 2, cy - size / 2
                fx = fx + rx * ex / kx
                fz = fz + rz * ex / kx
                fy = fy - ey / ky
                local ratio = math.max(w, h) / (R.probeFill * size)
                if touch then ratio = math.max(ratio, 1.4) end
                zoom = zoom * ratio
            end
        end
        if good then
            local ok, err = Shot(fx, fy, fz, zoom, R.render)
            if not ok then
                why = err
            else
                local x0, y0, x1, y1, n = ed_icon_bounds(0.05, KEEP)
                if x0 and n >= 8 then
                    local w, h = x1 - x0 + 1, y1 - y0 + 1
                    local cx, cy = (x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2
                    local side = math.max(w, h) / R.fill
                    local px, pw, ph = ed_icon_result(Size, cx, cy, side, KEEP)
                    if px and ed_dds_write(Dir() .. '/' .. req.name, pw, ph, px, 1) then
                        result = true
                    else
                        why = 'could not write the picture'
                    end
                else
                    why = 'the final render is empty'
                end
            end
        end
    else
        why = answer or 'no answer from the sim'
    end
    SimCallback({ Func = 'EdThumbClear', Args = {} }, false)
    return result, why
end

local function Worker()
    while true do
        local t0 = GetSystemTimeSeconds()
        local served = 0
        -- a picture somebody looks at first, then the warm-up; the warm-up gets a smaller share of the frame (nobody waits for it)
        while t0 >= holdUntil do
            local now = GetSystemTimeSeconds()
            local req = NextWanted()
            local limit = t0 + budget
            if not req then
                limit = t0 + math.min(budget, 0.008)
                if now >= limit then break end
                req = NextWarm(limit)
                if req then counts.warm = counts.warm + 1 end
            end
            if not req then break end
            queued[req.id] = nil
            req.state = 'done'
            pcall(MakeNative, req)
            if not req.warm then served = served + 1 end
            if GetSystemTimeSeconds() >= limit then break end
        end
        if served > 0 then Changed() end
        if table.getn(wanted) == 0 and table.getn(renders) > 0 and t0 >= holdUntil then
            if CanRender() then
                local req = table.remove(renders)
                queued[req.id] = nil
                -- (no pcall: the render waits for frames)
                local ok, why = RenderProp(req)
                if ok then
                    known[req.name] = true
                    counts.rendered = counts.rendered + 1
                else
                    failedNames[req.name] = true
                    counts.failed = counts.failed + 1
                    LOG('EDITOR asset thumbnail of ' .. tostring(req.key) .. ': ' .. tostring(why))
                end
                Changed()
                WaitSeconds(0.15)
            else
                WaitSeconds(0.8)
            end
        end
        -- (at most one redraw every 0.2 s while pictures keep coming: they appear as they are made, not when the queue is empty)
        if changedAt and GetSystemTimeSeconds() - lastNotify >= 0.2 then
            changedAt = false
            lastNotify = GetSystemTimeSeconds()
            for _, fn in Listeners do pcall(fn) end
        end
        if table.getn(wanted) == 0 and warmHead > table.getn(warmQ) and table.getn(renders) == 0 and not changedAt then break end
        WaitTicks(2)
    end
    running = false
end

local function Start()
    if running then return end
    running = true
    ForkThread(Worker)
end

function Request(kind, key, source, owner)
    local name, id = NameOf(kind, key, source)
    if known[name] and Mount() then
        counts.hits = counts.hits + 1
        return '/edassets/' .. name
    end
    local isProp = (kind == 'props')
    local waiting = queued[id]
    if waiting then
        if isProp then
            -- asked again: the most recent request goes to the end (served first); a request that is last already stays
            local n = table.getn(renders)
            if renders[n] ~= waiting then
                for i = n - 1, 1, -1 do
                    if renders[i] == waiting then table.remove(renders, i) table.insert(renders, waiting) break end
                end
            end
        else
            -- asked again in the owner's latest wave: it keeps its place in the wave (the order the list binds its rows); a warm-up request becomes a wanted one
            rankCounter = rankCounter + 1
            waiting.rank = rankCounter
            waiting.owner = owner
            waiting.wave = owner and (waves[owner] or 0) or 0
            if waiting.state == 'warm' then
                waiting.state = 'wanted'
                waiting.warm = false
                table.insert(wanted, waiting)
            end
        end
        return nil
    end
    if failedNames[name] then return nil end              -- failed before
    if Exists(name) and Mount() then
        counts.hits = counts.hits + 1
        return '/edassets/' .. name
    end
    Mount()
    local req = { id = id, kind = kind, key = key, source = source, name = name, state = 'wanted' }
    queued[id] = req
    if isProp then
        table.insert(renders, req)
        -- a long scroll asks for thousands of pictures that are gone from the screen again before they are made: only the most recent requests are kept
        if table.getn(renders) > MAX_RENDER_QUEUE then
            local old = table.remove(renders, 1)
            queued[old.id] = nil
        end
    else
        rankCounter = rankCounter + 1
        req.rank = rankCounter
        req.owner = owner
        req.wave = owner and (waves[owner] or 0) or 0
        table.insert(wanted, req)
        if table.getn(wanted) > MAX_NATIVE_QUEUE then
            -- too many: the least urgent one (the latest asked) goes
            local worst, at = req, table.getn(wanted)
            for i = 1, table.getn(wanted) do
                if wanted[i].rank > worst.rank then worst, at = wanted[i], i end
            end
            table.remove(wanted, at)
            queued[worst.id] = nil
        end
    end
    Start()
    return nil
end

--- A list is about to bind its visible rows again: whatever `owner` asked in earlier waves and does not ask for in this one is cancelled (see the header).
function NewWave(owner)
    waves[owner] = (waves[owner] or 0) + 1
end

--- Makes the pictures of `items` ({ key, source }, in the order they are wanted) of kind `kind` in the background once nothing visible waits. An item that is on disk costs one file check.
function Warm(kind, items)
    local added = 0
    for _, it in items do
        local id = kind .. '|' .. it.key
        if not warmSeen[id] and not queued[id] and table.getn(warmQ) - warmHead < MAX_WARM then
            warmSeen[id] = true
            local req = { id = id, kind = kind, key = it.key, source = it.source or it.key, state = 'warm', warm = true }
            queued[id] = req
            table.insert(warmQ, req)
            added = added + 1
        end
    end
    if added > 0 then
        Mount()
        Start()
    end
    return added
end

--- Gives up the warm-up requests that are still waiting.
function CancelWarm()
    for i = warmHead, table.getn(warmQ) do
        local r = warmQ[i]
        if r and r.state == 'warm' then
            queued[r.id] = nil
            r.state = 'done'
            warmSeen[r.id] = nil
        end
    end
    warmQ, warmHead = {}, 1
end

--- How long the worker may work per tick (nil: the default 12 ms).
function SetBudget(seconds)
    budget = seconds or 0.012
end

--- The worker makes no picture for `seconds` (see the header).
function Hold(seconds)
    holdUntil = GetSystemTimeSeconds() + (seconds or 0.15)
end

--- Test helper: renders one prop now (a THREAD) and returns the trace of the fitting steps.
function RenderNow(key)
    Trace = {}
    local req = { id = 'trace|' .. key, kind = 'props', key = key, source = key, name = Name('props', key, key) }
    local ok, why = RenderProp(req)
    table.insert(Trace, 'result ' .. tostring(ok) .. ' ' .. tostring(why))
    return ok
end

--- Makes the picture of a decal / texture / shape entry now (no thread) and returns its vfs path | nil, reason. For tests and for panels that need a picture at once.
function Make(kind, key, source)
    if kind == 'props' then return nil, 'props are rendered by the worker' end
    local name = Name(kind, key, source)
    if not Exists(name) then
        MakeNative({ id = kind .. '|' .. key, kind = kind, key = key, source = source, name = name })
    end
    if Exists(name) and Mount() then return '/edassets/' .. name end
    return nil, 'could not make the picture'
end

--- Deletes the pictures of older versions of the recipe (the folders `assetthumbs/v1` ... `v<Version - 1>`). Returns the number of files deleted.
function PruneOldVersions()
    local n = 0
    for v = 1, Version - 1 do
        local dir = UserData.Path('assetthumbs/v' .. v)
        if ed_file_exists(dir .. '/.keep') then
            local mount = '/edassetsold' .. v
            if ed_vfs_mount(dir, mount) then
                for _, path in DiskFindFiles(mount, '*.dds') or {} do
                    local disk = ed_vfs_to_disk(path)
                    if disk and ed_file_delete(disk) then n = n + 1 end
                end
            end
        end
    end
    return n
end

function Listen(id, fn) Listeners[id] = fn end
function Unlisten(id) Listeners[id] = nil end

function Pause(on) Paused = on and true or false end

function Stats()
    local warm = 0
    for i = warmHead, table.getn(warmQ) do
        if warmQ[i] and warmQ[i].state == 'warm' then warm = warm + 1 end
    end
    return { queued = table.getn(wanted) + table.getn(renders) + warm, wanted = table.getn(wanted), warmQueued = warm, made = counts.made, failed = counts.failed, rendered = counts.rendered,
             hits = counts.hits, cancelled = counts.cancelled, warm = counts.warm, avgMs = (counts.made + counts.failed > 0) and (counts.ms / (counts.made + counts.failed)) or 0, maxMs = counts.maxMs }
end

function Clear()
    wanted, renders, queued = {}, {}, {}
    warmQ, warmHead, warmSeen = {}, 1, {}
    failedNames = {}
    nameCache = {}
end

--- Test helper: forget what is known in memory (the files stay).
function Reset()
    Clear()
    known = {}
    failedNames = {}
    nameCache = {}
    holdUntil = 0
    mounted = false
    waves, rankCounter, lastNotify, budget = {}, 0, 0, 0.012
    counts = { made = 0, failed = 0, rendered = 0, hits = 0, cancelled = 0, warm = 0, ms = 0, maxMs = 0 }
end

--- Deletes nothing (there is no delete native); lists the cache files that no current entry would use is the job of the owner. Returns the number of files known to exist.
function KnownCount()
    local n = 0
    for _ in known do n = n + 1 end
    return n
end
