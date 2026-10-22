-- The terrain-type layer: one byte per map cell, the TypeCode of an entry of /lua/TerrainTypes.lua (footsteps and impact effects, the sound set, the
-- blocking flag, the unit style). Painted with the Terrain type tool: a hard disc of the brush radius; holding Shift paints the default type back.
-- Natives: EdTerrainType.cpp (ed_tt_*).
--
--   Types()                  the entries sorted by TypeCode: { code, name, description, blocking, style, color }
--   Active                   the TypeCode painted with
--   Visible                  show the type grid as coloured cells in the world (View panel / Terrain type panel)
--   BeginStroke() / Dab(cx, cz, brush) / EndStroke(); TakeEntry() -> undo entry of the finished stroke
--   ColorOf(code)            'RRGGBB'
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

DEFAULT = 1
Active = 1
Visible = false
Revision = 0         -- bumped on every change, so the overlay redraws

local cache = false
local stroke = false
local pending = false

--- Entries of TerrainTypes.lua by TypeCode.
function Types()
    if cache then return cache end
    local list = {}
    local ok, mod = pcall(function() return import('/lua/TerrainTypes.lua') end)
    local source = ok and mod and mod.TerrainTypes
    if source then
        for _, t in source do
            if t.TypeCode then
                table.insert(list, { code = t.TypeCode, name = t.Name or ('type ' .. t.TypeCode), description = t.Description or '', blocking = t.Blocking and true or false,
                                     style = t.Style or '', color = t.Color })
            end
        end
    end
    table.sort(list, function(a, b) return a.code < b.code end)
    cache = list
    return list
end

local function Find(code)
    for _, t in Types() do
        if t.code == code then return t end
    end
    return nil
end

function NameOf(code)
    local t = Find(code)
    return t and t.name or ('type ' .. tostring(code))
end

--- A colour that tells the types apart: the type's own colour when it has one, else one from the code.
function ColorOf(code)
    local t = Find(code)
    local c = t and t.color
    if c and string.len(c) == 8 and string.sub(c, 1, 2) ~= '00' then
        return string.sub(c, 3, 8)
    end
    local function Chan(k) return math.mod(math.floor(code * k), 200) + 40 end
    return string.format('%02X%02X%02X', Chan(97.3), Chan(57.7), Chan(143.1))
end

function Available()
    return ed_tt_info ~= nil and ed_tt_info() ~= nil
end

-- ---- what changed: the overlay (ttoverlay.lua) redraws only the cells that did -------------------------------------------------------------------
-- Revision counts the changes. A change that knows its cell rectangle reports it with Mark; the overlay asks TakeDirty for the rectangle accumulated since its last look. Code that bumps
-- Revision by itself (a panel switch, Generate, the field engine) does not know a rectangle: TakeDirty then answers 'all' and the overlay rebuilds everything.

local dirty = false          -- false | { x0, z0, x1, z1 } (cells) | 'all': the changes not yet taken
local knownRev = 0           -- the Revision `dirty` accounts for

--- Reports a change of the cells x0..x1, z0..z1 (inclusive, grid cells): bumps Revision.
function Mark(x0, z0, x1, z1)
    local unknown = (Revision ~= knownRev)           -- somebody bumped Revision without a rectangle since the last look
    Revision = Revision + 1
    knownRev = Revision
    if unknown or dirty == 'all' then
        dirty = 'all'
    elseif dirty then
        if x0 < dirty[1] then dirty[1] = x0 end
        if z0 < dirty[2] then dirty[2] = z0 end
        if x1 > dirty[3] then dirty[3] = x1 end
        if z1 > dirty[4] then dirty[4] = z1 end
    else
        dirty = { x0, z0, x1, z1 }
    end
end

--- The changes since the last call: 'all', a rectangle { x0, z0, x1, z1 } of grid cells, or nil when nothing is known to have changed.
function TakeDirty()
    local d = dirty
    if Revision ~= knownRev then d = 'all' end
    dirty = false
    knownRev = Revision
    return d
end

--- World units per grid cell (the grid spans the whole map, whatever its resolution): csx, csz.
function Cell()
    local gw, gh = ed_tt_info()
    local size = ed_terrain_info and ed_terrain_info()
    if not gw or not size then return 1, 1 end
    return (size - 1) / gw, (size - 1) / gh
end

-- ---- painting ---------------------------------------------------------------------------------------------------------------------------------------
-- A dab is one native call (ed_tt_disc: the disc, in the session's grid and the sim's copy, with the rectangle that changed). The undo data is kept in 32 x 32 cell tiles: the first time a
-- dab reaches a tile its content is read (one call per tile, once per stroke); at the end of the stroke the tiles that changed give the undo entry (before / after of those tiles only).

NativeDisc = true        -- false forces the Lua loop (tests compare the two)
local TILE = 32

function BeginStroke()
    local w, h = ed_tt_info()
    if not w then
        stroke = { refused = true }
        return
    end
    local csx = Cell()
    stroke = { w = w, h = h, cs = csx, tiles = {}, tilesW = math.ceil(w / TILE) }
end

--- Remembers the content of the tiles under the cell rectangle before the first change of the stroke reaches them.
local function Snapshot(s, x0, z0, x1, z1)
    local tiles = s.tiles
    for tz = math.floor(z0 / TILE), math.floor(z1 / TILE) do
        for tx = math.floor(x0 / TILE), math.floor(x1 / TILE) do
            local key = tz * s.tilesW + tx
            if not tiles[key] then
                local values, ax0, az0, ax1, az1 = ed_tt_read(tx * TILE, tz * TILE, tx * TILE + TILE - 1, tz * TILE + TILE - 1)
                if values then
                    tiles[key] = { x0 = ax0, z0 = az0, x1 = ax1, z1 = az1, before = values, changed = false }
                end
            end
        end
    end
end

--- A hard disc of terrain type at world position (cx, cz) with the brush radius. Returns the number of cells changed.
function Dab(cx, cz, brush)
    if not stroke then BeginStroke() end
    if stroke.refused then return 0 end
    local cs = stroke.cs
    local r = brush.radius / cs                     -- the grid in cells
    cx, cz = cx / cs, cz / cs
    local code = Active
    if IsKeyDown and IsKeyDown('Shift') then code = DEFAULT end
    local x0, z0 = math.max(0, math.floor(cx - r)), math.max(0, math.floor(cz - r))
    local x1, z1 = math.min(stroke.w - 1, math.ceil(cx + r)), math.min(stroke.h - 1, math.ceil(cz + r))
    if x1 < x0 or z1 < z0 then return 0 end
    Snapshot(stroke, x0, z0, x1, z1)
    local changed, bx0, bz0, bx1, bz1
    if NativeDisc and rawget(_G, 'ed_tt_disc') then
        changed, bx0, bz0, bx1, bz1 = ed_tt_disc(cx, cz, r, code)
    end
    if changed == nil then
        -- the same disc in Lua (an exe without ed_tt_disc): one read of the window, one write
        local values, ax0, az0, ax1, az1 = ed_tt_read(x0, z0, x1, z1)
        if not values then return 0 end
        local rw = ax1 - ax0 + 1
        local r2 = r * r
        changed = 0
        for z = az0, az1 do
            local dz = (z + 0.5) - cz
            local dz2 = dz * dz
            local row = (z - az0) * rw - ax0 + 1
            for x = ax0, ax1 do
                local dx = (x + 0.5) - cx
                if dx * dx + dz2 <= r2 and values[row + x] ~= code then
                    values[row + x] = code
                    changed = changed + 1
                    if changed == 1 then
                        bx0, bz0, bx1, bz1 = x, z, x, z
                    else
                        if x < bx0 then bx0 = x end
                        if x > bx1 then bx1 = x end
                        if z < bz0 then bz0 = z end
                        if z > bz1 then bz1 = z end
                    end
                end
            end
        end
        if changed > 0 then ed_tt_write(ax0, az0, ax1, az1, values) end
    end
    if changed > 0 then
        for tz = math.floor(bz0 / TILE), math.floor(bz1 / TILE) do
            for tx = math.floor(bx0 / TILE), math.floor(bx1 / TILE) do
                local t = stroke.tiles[tz * stroke.tilesW + tx]
                if t then t.changed = true end
            end
        end
        Mark(bx0, bz0, bx1, bz1)
    end
    return changed
end

function EndStroke()
    local s = stroke
    stroke = false
    pending = false
    if not s or s.refused then return end
    local parts = {}
    for _, t in s.tiles do
        if t.changed then
            local after = ed_tt_read(t.x0, t.z0, t.x1, t.z1)
            if after then
                local before = t.before
                local same = true
                for i = 1, table.getn(before) do
                    if before[i] ~= after[i] then same = false break end
                end
                if not same then table.insert(parts, { x0 = t.x0, z0 = t.z0, x1 = t.x1, z1 = t.z1, before = before, after = after }) end
            end
        end
    end
    if table.getn(parts) == 0 then return end
    local function Apply(field)
        for _, p in parts do
            ed_tt_write(p.x0, p.z0, p.x1, p.z1, p[field])
            Mark(p.x0, p.z0, p.x1, p.z1)
        end
    end
    pending = {
        label = 'paint terrain type',
        undo = function() Apply('before') end,
        redo = function() Apply('after') end,
    }
end

function TakeEntry()
    local e = pending
    pending = false
    return e
end

--- Cells per code in the whole grid (for the panel; empty when there is no grid).
function Census()
    local w, h = ed_tt_info()
    if not w then return {} end
    local values = ed_tt_read(0, 0, w - 1, h - 1)
    local count = {}
    for i = 1, table.getn(values) do
        local v = values[i]
        count[v] = (count[v] or 0) + 1
    end
    return count
end


--- The type codes under a grid of nodes (the overlay's): node (i, j) lies at world (x0 + i * step, z0 + j * step) and takes the code of the grid cell that position is in (the grid spans the whole
--- map, whatever its resolution). Returns a row major list of nw * nh codes; nil without a grid.
NativeNodes = true       -- false forces the Lua loop below (tests compare the two)

function NodeCodes(x0, z0, nw, nh, step)
    local gw, gh = ed_tt_info()
    local size = ed_terrain_info()
    if not gw or not size then return nil end
    local csx, csz = (size - 1) / gw, (size - 1) / gh
    if NativeNodes and rawget(_G, 'ed_tt_nodes') then
        local native = ed_tt_nodes(x0, z0, nw, nh, step, csx, csz)           -- all nodes in one call
        if native then return native end
    end
    local out = {}
    local n = 0
    local c0 = math.max(0, math.min(gw - 1, math.floor(x0 / csx)))
    local c1 = math.max(0, math.min(gw - 1, math.floor((x0 + (nw - 1) * step) / csx)))
    for j = 0, nh - 1 do
        local cz = math.max(0, math.min(gh - 1, math.floor((z0 + j * step) / csz)))
        local row = ed_tt_read(c0, cz, c1, cz)          -- one row of cells under this row of nodes
        for i = 0, nw - 1 do
            n = n + 1
            local cx = math.max(0, math.min(gw - 1, math.floor((x0 + i * step) / csx)))
            out[n] = row and row[cx - c0 + 1] or 0
        end
    end
    return out
end

-- ---- from the texture layers ----------------------------------------------------------------------------------------------------------------
--
-- Every texture layer has a terrain type slot (Base = layer 0, painted layers 1..8). A layer's type is the default of its texture (DefaultFor, by the file
-- name) until the user assigns one (Manual). Generate() works out, for every mask cell, which layer is seen most there: the layers are blended in order, so a
-- layer's visible share is its mask value times what the layers above it leave free (the masks "subtract" from the ones below); the cell takes the type of
-- the layer with the largest share, the base layer's share being what nothing covers.

local fullRange = false          -- the shader of the map reads a mask byte as it is (strata.lua Range), set by Generate

local function Decode(m)
    if fullRange then return m / 255 end
    local e = 2 * m / 255 - 1
    if e < 0 then return 0 end
    return e
end

LayerType = {}        -- layer index (0..8) -> TypeCode, only the ones the user assigned
Manual = {}           -- layer index -> true when LayerType[layer] is the user's choice

-- file name pattern -> TypeCode, first match wins (lower case names; the game's layer textures follow these words)
local RULES = {
    { 'lav_lava', 230 }, { 'lavalt', 230 }, { 'lavamd', 230 }, { 'lavadk', 230 }, { 'lava0', 230 },
    { 'lavarock', 152 }, { 'lav_rock', 152 }, { 'lav_cracked', 153 }, { 'lav_gravel', 5 }, { 'lav_ribbon', 154 },
    { 'snow', 200 }, { 'ice', 201 }, { 'macroice', 201 },
    { 'sandwet', 41 }, { 'reef_sand', 41 }, { 'sand', 40 },
    { 'tarmac', 151 }, { 'concrete', 151 }, { 'road', 151 }, { 'tech_wiers', 151 }, { 'grid', 151 },
    { 'grass', 80 }, { 'hostas', 81 }, { 'jung', 82 }, { 'farm', 84 }, { 'veg', 83 },
    { 'crystal', 156 }, { 'cryst', 156 }, { 'coral', 160 },
    { 'rock', 150 }, { 'cliff', 158 }, { 'stone', 150 }, { 'ashley', 6 },
    { 'gravel', 4 }, { 'dirt', 2 }, { 'mud', 3 }, { 'soil', 2 }, { 'trans', 2 },
}

--- The default terrain type of a texture by its file name; DEFAULT (the Default type) when nothing matches.
function DefaultFor(albedo)
    local name = string.lower(string.gsub(albedo or '', '^.*/', ''))
    for _, r in RULES do
        if string.find(name, r[1], 1, true) then
            if Find(r[2]) then return r[2] end
        end
    end
    return DEFAULT
end

--- The terrain type of a layer: the user's choice or the default of its texture.
function TypeOfLayer(i)
    if Manual[i] and LayerType[i] then return LayerType[i] end
    local albedo = ed_stratum_layer(i)
    return DefaultFor(albedo)
end

function SetLayerType(i, code)
    LayerType[i] = code
    Manual[i] = true
end

--- Back to the defaults of the textures (one layer, or every layer when `i` is nil).
function ResetLayerTypes(i)
    if i then
        LayerType[i], Manual[i] = nil, nil
    else
        LayerType, Manual = {}, {}
    end
end

--- Generates the terrain type grid from the layers. opts.onlyUnset: leave cells that already have a type (not 0 / the default). Returns the undo entry
--- (nil when the map has no grid or nothing changed).
function Generate(opts)
    opts = opts or {}
    local gw, gh = ed_tt_info()
    local mw, mh = ed_stratum_info()
    if not gw or not mw then return nil end
    fullRange = (import('/lua/editor/strata.lua').Range() == 'full')
    local masks = {}
    for k = 1, 8 do
        local albedo = ed_stratum_layer(k)
        if albedo and albedo ~= '' and albedo ~= import('/lua/editor/strata.lua').CLEAR then
            masks[k] = ed_stratum_read(k - 1, 0, 0, mw - 1, mh - 1)
        end
    end
    local types = {}
    for k = 0, 8 do types[k] = TypeOfLayer(k) end
    -- the layer seen most in every mask cell
    local best = {}
    local n = mw * mh
    for idx = 1, n do
        local remaining = 1
        local bestLayer, bestShare = 0, -1
        for k = 8, 1, -1 do
            local m = masks[k]
            if m then
                local e = Decode(m[idx])
                if e > 0 then
                    local share = e * remaining
                    if share > bestShare then bestLayer, bestShare = k, share end
                    remaining = remaining * (1 - e)
                end
            end
        end
        if remaining >= bestShare then bestLayer = 0 end
        best[idx] = bestLayer
    end
    local before = ed_tt_read(0, 0, gw - 1, gh - 1)
    local after = {}
    local changed = 0
    local sx, sz = mw / gw, mh / gh
    for z = 0, gh - 1 do
        local mz = math.min(mh - 1, math.floor((z + 0.5) * sz))
        for x = 0, gw - 1 do
            local i = z * gw + x + 1
            local old = before[i]
            local new = types[best[mz * mw + math.min(mw - 1, math.floor((x + 0.5) * sx)) + 1]]
            if opts.onlyUnset and old > DEFAULT then new = old end
            after[i] = new
            if new ~= old then changed = changed + 1 end
        end
    end
    if changed == 0 then return nil end
    ed_tt_write(0, 0, gw - 1, gh - 1, after)
    Revision = Revision + 1
    return {
        label = 'generate terrain types from textures',
        undo = function() ed_tt_write(0, 0, gw - 1, gh - 1, before) Revision = Revision + 1 end,
        redo = function() ed_tt_write(0, 0, gw - 1, gh - 1, after) Revision = Revision + 1 end,
    }, changed
end

-- ---- the user's choices travel with the map (the _editor.lua file next to the scenario) --------------------------------------------------------

--- Lines for the sidecar file: the layers whose type the user assigned.
function SidecarText()
    local lines = {}
    for i = 0, 8 do
        if Manual[i] and LayerType[i] then
            table.insert(lines, string.format('    [%d] = %d,', i, LayerType[i]))
        end
    end
    if table.getn(lines) == 0 then return '' end
    return 'TerrainTypeLayers = {\n' .. table.concat(lines, '\n') .. '\n}\n'
end

function LoadSidecar(scenarioFile)
    LayerType, Manual = {}, {}
    local path = scenarioFile and import('/lua/editor/mods.lua').SidecarPath(scenarioFile)
    if not path or not DiskGetFileInfo(path) then return end
    local env = {}
    doscript(path, env)
    for i, code in env.TerrainTypeLayers or {} do
        LayerType[i] = code
        Manual[i] = true
    end
end
