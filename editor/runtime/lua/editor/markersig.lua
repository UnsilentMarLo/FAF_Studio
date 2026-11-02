-- A cheap fingerprint of the markers and areas of the open map, for the nets of code that keeps something derived from them (the name labels, the marker meshes): "has anything moved
-- that did not announce itself through Tools.Changed?". One walk over the markers (a sum of their positions, ~1 ms for 3000) instead of the rebuild of whatever hangs on them
-- (5-8 ms). The result is shared: a second caller within 0.4 s gets the numbers of the first.
--
--   Sums(now)   -> count, sum    `now` = GetSystemTimeSeconds(); the count of markers and a sum over their positions and the corners of the areas
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
    for _, m in doc.save.MasterChain._MASTERCHAIN_.Markers do
        local p = m.position
        if p then
            count = count + 1
            sum = sum + p[1] + 3 * p[2] + 7 * p[3]
        end
    end
    for _, a in doc.save.Areas do
        local r = a.rectangle
        if r then sum = sum + r[1] + 3 * r[2] + 7 * r[3] + 11 * r[4] end
    end
    return count, sum
end
