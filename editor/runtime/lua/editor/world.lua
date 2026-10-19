-- The map's lighting, fog and water settings (engine side: moho/editor/EdWorld.cpp, ed_world_get / ed_world_set).
--
--   Value(name)               -> number, one of the names listed in EdWorld.cpp (light_mult, sun_x, ambient_r, fog_start, water_elev, w_color_r ...)
--   Change(fields, opts)      applies { name = number, ... } and records an undo entry. opts: label, refresh (rebuild the water map: after the
--                             water elevations or the water switch changed), merge (a key: changes with the same key within 1.5 s are one entry,
--                             so a slider drag is a single undo step)
--   SunAngles() / SetSunAngles(azimuth, elevation)   the sun direction as degrees (the engine stores a vector)
--   Listen(fn)                fn() is called after every change, undo and redo (panels re-read their sliders)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local History = import('/lua/editor/history.lua')

local cache = false
local listeners = {}
local merge = false        -- { key, entry, time }

function Listen(fn)
    table.insert(listeners, fn)
end

local function Notify()
    cache = false
    for _, fn in listeners do pcall(fn) end
end

--- All values (a copy: nothing outside changes the engine's numbers behind this module's back, so it is read once per change).
function Get()
    if not cache then
        cache = ed_world_get() or {}
    end
    return cache
end

function Value(name)
    return Get()[name] or 0
end

local function Copy(t)
    local c = {}
    for k, v in t do c[k] = v end
    return c
end

--- Applies the numbers in `fields`. Returns false when there is no map.
function Change(fields, opts)
    opts = opts or {}
    local before = Copy(Get())
    if not ed_world_set(fields, opts.refresh and true or false) then return false end
    cache = false
    local after = Copy(Get())
    local now = GetSystemTimeSeconds()
    local label = opts.label or 'lighting'
    if opts.merge and merge and merge.key == opts.merge and now - merge.time < 1.5 and History.Top() == merge.entry then
        local entry = merge.entry
        entry.redo = function() ed_world_set(after, opts.refresh and true or false) Notify() end
        merge.time = now
    else
        local entry = {
            label = label,
            undo = function() ed_world_set(before, true) Notify() end,
            redo = function() ed_world_set(after, true) Notify() end,
        }
        History.Push(entry)
        merge = opts.merge and { key = opts.merge, entry = entry, time = now } or false
    end
    Notify()
    return true
end

-- ---- the sun direction as angles -------------------------------------------------------------------------------------------------------------

--- Azimuth (0..360, from +x towards +z) and elevation (-90..90, up is positive) of the sun direction vector.
function SunAngles()
    local x, y, z = Value('sun_x'), Value('sun_y'), Value('sun_z')
    local len = math.sqrt(x * x + y * y + z * z)
    if len < 0.0001 then return 0, 45 end
    local az = math.deg(math.atan2(z, x))
    if az < 0 then az = az + 360 end
    return az, math.deg(math.asin(y / len))
end

function SetSunAngles(az, el, key)
    local a, e = math.rad(az), math.rad(el)
    local c = math.cos(e)
    Change({ sun_x = c * math.cos(a), sun_y = math.sin(e), sun_z = c * math.sin(a) }, { label = 'sun direction', merge = key or 'sun' })
end

--- Drops the cache and tells the listeners: for code that wrote the engine numbers directly (environment.lua applies whole presets in one go).
function Invalidate()
    Notify()
end
