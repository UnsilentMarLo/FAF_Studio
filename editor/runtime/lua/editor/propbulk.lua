-- Removing many props at once. ed_prop_remove(index) rebuilds the whole prop list of the map each call (17 ms on a 40000 prop map), so removing thousands one by one took minutes:
-- ed_prop_remove_many (native, EdPropBulk.cpp) does it in one pass. Without the native (an older engine exe) this falls back to the one by one removal.
--
--   Remove(indices)      removes the props with these (1-based) numbers, any order; the sim's entities go with them. Returns how many went.
--
-- Lua 5.0 dialect.

function Remove(indices)
    local n = table.getn(indices)
    if n == 0 then return 0 end
    local data = {}
    for _, i in indices do
        local bp, x, y, z = ed_prop_get(i)
        if bp then table.insert(data, { bp = bp, x = x, z = z }) end
    end
    local removed
    if rawget(_G, 'ed_prop_remove_many') then
        removed = ed_prop_remove_many(indices) or 0
    else
        local sorted = {}
        for _, i in indices do table.insert(sorted, i) end
        table.sort(sorted, function(a, b) return a > b end)
        removed = 0
        for _, i in sorted do if ed_prop_remove(i) then removed = removed + 1 end end
    end
    for _, d in data do
        SimCallback({ Func = 'EdRemovePropAt', Args = { bp = d.bp, x = d.x, z = d.z } }, false)
    end
    return removed
end
