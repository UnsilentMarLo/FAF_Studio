-- A cheap fingerprint of the markers and areas of the open map, for the nets of code that keeps something derived from them (the name labels, the marker meshes, the validation
-- signature): "has anything moved that did not announce itself through Tools.Changed?". One walk over the markers (~1 ms for 3000) instead of the rebuild of whatever hangs on them
-- (5-8 ms). The result is shared: a second caller within 0.4 s gets the numbers of the first.
--
--   Sums(now)   -> count, sumX, sumZ    `now` = GetSystemTimeSeconds(); the number of markers and the sums of their x and z, the corners of the areas included
--
-- (Lua numbers are 32-bit floats: a sum of 3000 coordinates is ~1.5 million, where the step is 1/8: a marker that moves by a quarter unit or more changes it. The heights are not part
-- of it: they follow the ground, and the code that syncs them says so itself.)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

local at, doc, count, sumX, sumZ = -100, false, 0, 0, 0
MAX_AGE = 0.4

function Sums(now)
    if doc == Map.Doc and now >= at and now - at < MAX_AGE then return count, sumX, sumZ end          -- (a clock that went back is not fresh)
    doc, at = Map.Doc, now
    count, sumX, sumZ = 0, 0, 0
    if not doc then return 0, 0, 0 end
    local n, sx, sz = 0, 0, 0
    for _, m in doc.save.MasterChain._MASTERCHAIN_.Markers do
        local p = m.position
        if p then
            n = n + 1
            sx = sx + p[1]
            sz = sz + p[3]
        end
    end
    for _, a in doc.save.Areas do
        local r = a.rectangle
        if r then
            sx = sx + r[1] + 3 * r[3]
            sz = sz + r[2] + 3 * r[4]
        end
    end
    count, sumX, sumZ = n, sx, sz
    return count, sumX, sumZ
end
