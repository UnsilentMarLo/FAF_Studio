-- UI -> sim helpers (SimCallback wrappers; the callbacks live in schook/lua/simcallbacks.lua).

--- Re-snaps units and props inside a world rectangle onto the terrain. Call after terrain edits.
function Resnap(x0, z0, x1, z1)
    SimCallback({ Func = 'EdResnap', Args = { x0 = x0, z0 = z0, x1 = x1, z1 = z1, noDirty = NoDirtyForTest } }, false)
end

--- Test control only: when true, terrain edits do not tell the pathfinder (shows what stale caches do).
NoDirtyForTest = false
