-- A cheap fingerprint of the markers and areas of the open map, for the nets of code that keeps something derived from them (the name labels, the marker meshes): "has anything moved
-- that did not announce itself through Tools.Changed?". One walk over the markers (a hash of their positions, ~1 ms for 3000) instead of the rebuild of whatever hangs on them
-- (5-8 ms). The result is shared: a second caller within 0.4 s gets the numbers of the first.
--
--   Sums(now)   -> count, hash   `now` = GetSystemTimeSeconds(); the count of markers and a hash over their positions and the corners of the areas
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

local at, doc, count, sum = -100, false, 0, 0
MAX_AGE = 0.4

function Sums(now)
    if doc == Map.Doc and now - at < MAX_AGE then return count, sum end
    doc, at = Map.Doc, now
    count, sum = 0, 0
    if not doc then return 0, 0 end
    -- (a hash, not a plain sum: Lua numbers are 32-bit floats, and a sum of 3000 positions is ~14 million, where a marker that moved a few units can vanish in the rounding. Every
    -- product stays below 2^24, so the arithmetic is exact. Moves of a quarter unit and more change it.)
    local floor, mod = math.floor, math.mod
    local acc = 0
    for _, m in doc.save.MasterChain._MASTERCHAIN_.Markers do
        local p = m.position
        if p then
            count = count + 1
            acc = mod(acc * 3 + mod(floor(p[1] * 4), 65521) + 7 * mod(floor(p[2] * 4), 65521) + 13 * mod(floor(p[3] * 4), 65521), 65521)
        end
    end
    for _, a in doc.save.Areas do
        local r = a.rectangle
        if r then acc = mod(acc * 3 + mod(floor(r[1] * 4), 65521) + 7 * mod(floor(r[2] * 4), 65521) + 13 * mod(floor(r[3] * 4), 65521) + 17 * mod(floor(r[4] * 4), 65521), 65521) end
    end
    sum = acc
    return count, sum
end
