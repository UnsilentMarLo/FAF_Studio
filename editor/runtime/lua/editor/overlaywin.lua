-- The ground window of an overlay drawn as a node grid (ed_overlay_nodes: at most 300 x 300 nodes, `step` world units apart). The window covers everything the camera sees of the map: the corners and
-- edge middles of the view are projected onto the ground (a corner that looks at the sky counts as the whole map), the box around them is clamped to the map, and the node distance grows
-- (1, 2, 4 ... units) until the box fits `maxNodes` nodes per side, so a zoomed out view still shows the whole map and a close view keeps one node per unit.
--
--   Window(view, maxNodes) -> x0, z0, nw, nh, step      (world units; nil without a terrain or a view)
--   Fit(x0, z0, x1, z1, last, maxNodes) -> the same for a given ground box (what Window does after it has found the box of the view)
--
-- The box is snapped to a multiple of max(8, step) units, so it only changes when the camera has moved a bit: callers compare the returned numbers with the last ones before they rebuild a grid.
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

--- The node grid for the ground box (x0, z0)-(x1, z1) of a map `last` units wide: 8 units of margin, clamped to the map, the node distance doubled until at most maxNodes nodes per side, snapped to
--- a multiple of max(8, step). Returns x0, z0, nw, nh, step.
function Fit(x0, z0, x1, z1, last, maxNodes)
    x0, z0 = math.max(0, x0 - 8), math.max(0, z0 - 8)
    x1, z1 = math.min(last, x1 + 8), math.min(last, z1 + 8)
    local step = 1
    while math.max(x1 - x0, z1 - z0) / step + 1 > maxNodes and step < 64 do step = step * 2 end
    local snap = math.max(8, step)
    x0, z0 = math.floor(x0 / snap) * snap, math.floor(z0 / snap) * snap
    x1, z1 = math.min(last, math.ceil(x1 / snap) * snap), math.min(last, math.ceil(z1 / snap) * snap)
    while math.max(x1 - x0, z1 - z0) / step + 1 > maxNodes and step < 64 do step = step * 2 end        -- the snap may have grown the box
    return x0, z0, math.floor((x1 - x0) / step + 0.999) + 1, math.floor((z1 - z0) / step + 0.999) + 1, step
end

function Window(view, maxNodes)
    maxNodes = maxNodes or 290
    local size = ed_terrain_info and ed_terrain_info()
    if not size or not view then return nil end
    local last = size - 1
    local w, h = view.Width(), view.Height()
    if not w or w < 1 or h < 1 then return nil end
    local x0, z0, x1, z1 = last, last, 0, 0
    local sky = false
    -- UnProject takes window coordinates, not view coordinates: a view that does not start at the window's corner (the Generate workspace's world view) looked at the wrong ground
    local l, t = view.Left(), view.Top()
    for _, p in { { 0, 0 }, { w / 2, 0 }, { w, 0 }, { 0, h / 2 }, { w / 2, h / 2 }, { w, h / 2 }, { 0, h }, { w / 2, h }, { w, h } } do
        local g = UnProject(view, Vector2(l + p[1], t + p[2]))
        if g then
            x0, x1 = math.min(x0, g[1]), math.max(x1, g[1])
            z0, z1 = math.min(z0, g[3]), math.max(z1, g[3])
        else
            sky = true
        end
    end
    if sky or x1 < x0 or z1 < z0 then
        x0, z0, x1, z1 = 0, 0, last, last
    end
    return Fit(x0, z0, x1, z1, last, maxNodes)
end
