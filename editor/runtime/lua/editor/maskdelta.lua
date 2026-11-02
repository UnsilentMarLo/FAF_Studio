-- Compact undo data for paint masks: a set of tiles, each holding the bytes of the mask before and after an edit as packed strings.
--
-- A Lua table of mask cells costs 16 bytes a cell (24 for the hash part) and the stop-the-world collector of Lua 5.0 walks it; a string costs one byte a cell and is only marked. A paint
-- stroke used to keep two tables of its whole bounding box (tens of MB for a long stroke on a big mask, for every one of up to 200 history entries); it keeps the tiles it changed now,
-- and a tile whose bytes are all the same (the mask was empty, or is cleared) is kept as that one number.
--
--   TS                              tile edge in cells (32: 1024 cells a tile, the biggest run string.char(unpack(...)) takes in one call)
--   Pack(values, n)                 -> string of the n bytes values[1..n]
--   Unpack(data, n)                 -> table of n values (data: a packed string or a number = n cells of that value)
--   New(stratum)                    -> a delta of mask `stratum` (0..7)
--   Add(d, x0, z0, tw, th, before, after)       before / after: value tables (tw * th cells, row major)
--   AddPacked(d, x0, z0, tw, th, before, after) before / after: what Pack returned
--   Apply(d, undo)                  writes the 'before' (undo) or the 'after' bytes of every tile into the mask (one texture upload)
--   Entry(d, label)                 -> a history entry { label, undo, redo, bytes, delta }
--   Tiles(w, h, fn)                 calls fn(x0, z0, x1, z1) for every tile of a w x h mask
--
-- The history (history.lua) adds up `entry.bytes` and drops the oldest entries when the sum passes its limit.
--
-- Lua 5.0 dialect: no `#`, no `%`, string.byte returns one value.

TS = 32

local CHUNK = 1000        -- string.char(unpack(t, i, j)) fails above ~2000 values in this Lua ("table too big to unpack")

local OVERHEAD_TILE = 160       -- the tile table and its string headers, counted into `bytes`
local OVERHEAD_STRING = 24

function Pack(values, n)
    if n <= CHUNK then return string.char(unpack(values, 1, n)) end
    local parts, i = {}, 1
    while i <= n do
        local j = i + CHUNK - 1
        if j > n then j = n end
        parts[table.getn(parts) + 1] = string.char(unpack(values, i, j))
        i = j + 1
    end
    return table.concat(parts)
end

--- `s` (n cells) as one number when every byte is the same, else `s`.
local function Squash(s, n)
    if n < 1 then return s end
    local b = string.byte(s, 1)
    if s == string.rep(string.char(b), n) then return b end
    return s
end

function Unpack(data, n)
    local t = {}
    if type(data) == 'number' then
        for i = 1, n do t[i] = data end
        return t
    end
    local byte = string.byte
    for i = 1, n do t[i] = byte(data, i) end
    return t
end

local function Size(data)
    if type(data) == 'number' then return 0 end
    return string.len(data) + OVERHEAD_STRING
end

function New(stratum)
    return { stratum = stratum, tiles = {}, n = 0, bytes = 0 }
end

function AddPacked(d, x0, z0, tw, th, before, after)
    local n = tw * th
    local a, b = Squash(before, n), Squash(after, n)
    d.n = d.n + 1
    d.tiles[d.n] = { x0, z0, tw, th, a, b }
    d.bytes = d.bytes + OVERHEAD_TILE + Size(a) + Size(b)
end

function Add(d, x0, z0, tw, th, before, after)
    local n = tw * th
    AddPacked(d, x0, z0, tw, th, Pack(before, n), Pack(after, n))
end

--- Writes one side of the delta into the mask. The tiles do not overlap, so their order does not matter.
function Apply(d, undo)
    if not rawget(_G, 'ed_stratum_write') then return end
    local k = undo and 5 or 6
    local stratum = d.stratum
    for i = 1, d.n do
        local t = d.tiles[i]
        local tw, th = t[3], t[4]
        ed_stratum_write(stratum, t[1], t[2], t[1] + tw - 1, t[2] + th - 1, Unpack(t[k], tw * th), true)
    end
    ed_stratum_flush()
end

function Entry(d, label)
    return {
        label = label,
        bytes = d.bytes,
        delta = d,
        undo = function() Apply(d, true) end,
        redo = function() Apply(d, false) end,
    }
end

function Tiles(w, h, fn)
    for z0 = 0, h - 1, TS do
        local z1 = z0 + TS - 1
        if z1 > h - 1 then z1 = h - 1 end
        for x0 = 0, w - 1, TS do
            local x1 = x0 + TS - 1
            if x1 > w - 1 then x1 = w - 1 end
            fn(x0, z0, x1, z1)
        end
    end
end
