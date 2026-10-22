-- The terrain type grid as coloured cells in the world (View panel / Terrain type panel "Show on map"). Called by overlay.lua once per frame.
--
-- The cells draw as one node layer per type present in the part of the grid the camera sees (ed_overlay_nodes, one colour per layer). What makes this cheap:
--   * the layers are built at a reduced resolution: at most MAX_NODES nodes per side, fewer when many types are present (the engine projects every node of every layer each frame);
--   * the codes under the nodes come from one native call (terraintype.lua NodeCodes), not one per row;
--   * the node codes and the layer tables are kept. A change of the grid (a brush dab) only re-reads the nodes under the changed cells (terraintype.lua TakeDirty) and sends the layers
--     that really changed to the engine; nothing is rebuilt for a dab;
--   * rebuilds are at most one per UPDATE_GAP seconds, so a stroke that dabs many times a frame redraws a few times a second.
--
--   Draw(view)    once per frame
--   Forget()      the engine's overlay was cleared (a new session): drop what was kept
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local TT = import('/lua/editor/terraintype.lua')
local Win = import('/lua/editor/overlaywin.lua')

local MAX_NODES = 160          -- nodes per side of the window
local FEW_TYPES = 6            -- with more types than this the window is coarser (each type is a layer the engine draws every frame)
local MANY_TYPES = 12
local UPDATE_GAP = 0.1         -- seconds between two rebuilds
local ALPHA = 120

Stats = { full = 0, partial = 0, nodes = 0 }       -- counters for the self test and perf.lua

local state = false            -- { x0, z0, nw, nh, step, cap, rev, codes, grids = { code -> table }, count = { code -> nodes }, ids = { id -> true }, built = clock }

local function Clock()
    local now = rawget(_G, 'GetSystemTimeSeconds')
    return now and now() or 0
end

local function IdOf(code)
    return 'tt:' .. code
end

--- A layer table of n zeros.
local function NewGrid(n)
    local g = {}
    for i = 1, n do g[i] = 0 end
    return g
end

--- Takes the layers off the screen and forgets them.
function Hide()
    if state then
        for id, _ in state.ids do ed_overlay_remove(id) end
    end
    state = false
end

function Forget()
    state = false
end

local function Upload(s, code)
    local id = IdOf(code)
    if (s.count[code] or 0) > 0 then
        ed_overlay_nodes(id, s.x0, s.z0, s.nw, s.nh, s.grids[code], TT.ColorOf(code), ALPHA, s.step)
        s.ids[id] = true
    else
        if s.ids[id] then ed_overlay_remove(id) end
        s.ids[id] = nil
        s.grids[code] = nil
        s.count[code] = nil
    end
end

local function TypeCount(s)
    local n = 0
    for _, _ in s.count do n = n + 1 end
    return n
end

--- Which node cap to use: it drops when many types are present and comes back only when there are clearly fewer (so the window does not flip between two sizes).
local function CapFor(types, current)
    if types > MANY_TYPES then return 80 end
    if types > FEW_TYPES then
        if current == 80 and types > MANY_TYPES - 3 then return 80 end
        return 112
    end
    if current ~= MAX_NODES and types > FEW_TYPES - 2 then return current end
    return MAX_NODES
end

--- A full build for the window (x0, z0, nw, nh, step): the codes under all nodes, one layer per type above the default.
local function Build(x0, z0, nw, nh, step, cap, now)
    local codes = TT.NodeCodes(x0, z0, nw, nh, step)
    if not codes then return false end
    local n = nw * nh
    local s = { x0 = x0, z0 = z0, nw = nw, nh = nh, step = step, cap = cap, codes = codes, grids = {}, count = {}, ids = state and state.ids or {}, built = now }
    local default = TT.DEFAULT
    local grids, count = s.grids, s.count
    for i = 1, n do
        local v = codes[i]
        if v > default then
            local g = grids[v]
            if not g then
                g = NewGrid(n)
                grids[v] = g
                count[v] = 0
            end
            g[i] = 255
            count[v] = count[v] + 1
        end
    end
    -- layers of the old build that are gone leave the screen, the others are replaced by the upload below
    for id, _ in s.ids do
        local keep = false
        for code, _ in grids do
            if IdOf(code) == id then keep = true break end
        end
        if not keep then
            ed_overlay_remove(id)
            s.ids[id] = nil
        end
    end
    for code, _ in grids do Upload(s, code) end
    state = s
    Stats.full = Stats.full + 1
    Stats.nodes = Stats.nodes + n
    return true
end

--- Re-reads the nodes under the changed cells (cx0..cx1, cz0..cz1, grid cells) and updates the layers that changed.
local function Patch(s, cx0, cz0, cx1, cz1)
    local csx, csz = TT.Cell()
    local step = s.step
    -- the nodes whose position lies in the cell rectangle, plus one node around it
    local i0 = math.max(0, math.ceil((cx0 * csx - s.x0) / step) - 1)
    local i1 = math.min(s.nw - 1, math.ceil(((cx1 + 1) * csx - s.x0) / step))
    local j0 = math.max(0, math.ceil((cz0 * csz - s.z0) / step) - 1)
    local j1 = math.min(s.nh - 1, math.ceil(((cz1 + 1) * csz - s.z0) / step))
    if i1 < i0 or j1 < j0 then return end
    local iw, jh = i1 - i0 + 1, j1 - j0 + 1
    local sub = TT.NodeCodes(s.x0 + i0 * step, s.z0 + j0 * step, iw, jh, step)
    if not sub then return end
    local codes, grids, count = s.codes, s.grids, s.count
    local default = TT.DEFAULT
    local n = s.nw * s.nh
    local touched = {}
    for j = 0, jh - 1 do
        local row = (j0 + j) * s.nw + i0 + 1
        for i = 0, iw - 1 do
            local idx = row + i
            local old, new = codes[idx], sub[j * iw + i + 1]
            if old ~= new then
                codes[idx] = new
                if old > default then
                    local g = grids[old]
                    if g then
                        g[idx] = 0
                        count[old] = count[old] - 1
                        touched[old] = true
                    end
                end
                if new > default then
                    local g = grids[new]
                    if not g then
                        g = NewGrid(n)
                        grids[new] = g
                        count[new] = 0
                    end
                    g[idx] = 255
                    count[new] = count[new] + 1
                    touched[new] = true
                end
            end
        end
    end
    for code, _ in touched do Upload(s, code) end
    Stats.partial = Stats.partial + 1
    Stats.nodes = Stats.nodes + iw * jh
end

--- Brings the layers up to date for the window (x0, z0, nw, nh, step) at time `now` (seconds; 0 = no clock, never throttled). Returns 'full', 'partial' or nil (nothing to do).
function Refresh(x0, z0, nw, nh, step, now)
    local s = state
    local cap = s and s.cap or MAX_NODES
    local same = s and s.x0 == x0 and s.z0 == z0 and s.nw == nw and s.nh == nh and s.step == step
    if same and s.rev == TT.Revision then return nil end
    if s and now > 0 and now - s.built < UPDATE_GAP then return nil end         -- (a stroke changes the grid every frame: redraw a few times a second)
    local rev = TT.Revision
    if same then
        local d = TT.TakeDirty()
        s.built = now
        s.rev = rev
        if d == 'all' then
            if Build(x0, z0, nw, nh, step, cap, now) then state.rev = rev end
            return 'full'
        elseif d then
            Patch(s, d[1], d[2], d[3], d[4])
            return 'partial'
        end
        return nil
    end
    TT.TakeDirty()
    if Build(x0, z0, nw, nh, step, cap, now) then
        state.rev = rev
        -- many types: a coarser window from now on
        local want = CapFor(TypeCount(state), cap)
        if want ~= cap then state.cap = want end
        return 'full'
    end
    return nil
end

--- Once per frame.
function Draw(view)
    if not TT.Visible then
        if state then Hide() end
        return
    end
    if not ed_tt_info() then return end
    local x0, z0, nw, nh, step = Win.Window(view, state and state.cap or MAX_NODES)
    if not x0 then return end
    Refresh(x0, z0, nw, nh, step, Clock())
end

--- What is drawn now (self test): { x0, z0, nw, nh, step, codes, grids, count } or nil.
function Current()
    return state or nil
end
