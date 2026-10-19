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

function BeginStroke()
    local w, h = ed_tt_info()
    if not w then
        stroke = { refused = true }
        return
    end
    stroke = { w = w, h = h, orig = {}, minX = nil }
end

--- A hard disc of terrain type at (cx, cz). Returns the number of cells changed.
function Dab(cx, cz, brush)
    if not stroke then BeginStroke() end
    if stroke.refused then return 0 end
    local r = brush.radius
    local code = Active
    if IsKeyDown and IsKeyDown('Shift') then code = DEFAULT end
    local x0, z0 = math.max(0, math.floor(cx - r)), math.max(0, math.floor(cz - r))
    local x1, z1 = math.min(stroke.w - 1, math.ceil(cx + r)), math.min(stroke.h - 1, math.ceil(cz + r))
    if x1 < x0 or z1 < z0 then return 0 end
    local values, ax0, az0, ax1, az1 = ed_tt_read(x0, z0, x1, z1)
    if not values then return 0 end
    local rw = ax1 - ax0 + 1
    local changed = 0
    for z = az0, az1 do
        for x = ax0, ax1 do
            local dx, dz = (x + 0.5) - cx, (z + 0.5) - cz
            if dx * dx + dz * dz <= r * r then
                local i = (z - az0) * rw + (x - ax0) + 1
                if values[i] ~= code then
                    local key = z * stroke.w + x
                    if stroke.orig[key] == nil then stroke.orig[key] = values[i] end
                    values[i] = code
                    changed = changed + 1
                    if not stroke.minX then
                        stroke.minX, stroke.minZ, stroke.maxX, stroke.maxZ = x, z, x, z
                    else
                        if x < stroke.minX then stroke.minX = x end
                        if x > stroke.maxX then stroke.maxX = x end
                        if z < stroke.minZ then stroke.minZ = z end
                        if z > stroke.maxZ then stroke.maxZ = z end
                    end
                end
            end
        end
    end
    if changed > 0 then
        ed_tt_write(ax0, az0, ax1, az1, values)
        Revision = Revision + 1
    end
    return changed
end

function EndStroke()
    local s = stroke
    stroke = false
    pending = false
    if not s or not s.minX then return end
    local after, x0, z0, x1, z1 = ed_tt_read(s.minX, s.minZ, s.maxX, s.maxZ)
    if not after then return end
    local rw = x1 - x0 + 1
    local before = {}
    for z = z0, z1 do
        for x = x0, x1 do
            local i = (z - z0) * rw + (x - x0) + 1
            local o = s.orig[z * s.w + x]
            before[i] = (o == nil) and after[i] or o
        end
    end
    pending = {
        label = 'paint terrain type',
        undo = function() ed_tt_write(x0, z0, x1, z1, before) Revision = Revision + 1 end,
        redo = function() ed_tt_write(x0, z0, x1, z1, after) Revision = Revision + 1 end,
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
function NodeCodes(x0, z0, nw, nh, step)
    local gw, gh = ed_tt_info()
    local size = ed_terrain_info()
    if not gw or not size then return nil end
    local csx, csz = (size - 1) / gw, (size - 1) / gh
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

local function Decode(m)
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
