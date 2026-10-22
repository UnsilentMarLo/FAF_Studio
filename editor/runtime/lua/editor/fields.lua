-- Field engine facade (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T1). A field is a float32 grid in native memory (moho/editor/EdField.cpp, EdFieldCore.cpp), named in Lua by a
-- number. Lua never sees the samples: it builds ops, the engine runs them on a tiled thread pool (bit identical for any thread count), and only previews, stats and the commit cross back.
-- Heights are world units (the document's words / 128), masks 0..1. Sample (x, z) of a field lies at world (ox + x * cell, oz + z * cell); noise depends on the world position only, so a
-- coarse preview field (cell 4) samples the same noise as the full resolution one.
--
--   OpNames()                         the ops: generators const white perlin simplex ridged billow voronoi gradient radial;
--                                     filters blur box clamp invert abs gamma affine smoothstep threshold normalize quantize remap levels terrace warp offset rotate scale mirror crop resize
--                                     min max add sub mul blend resample; analysis slope height_band curvature water_below water_above water_depth shore distance aspect flow; erosion thermal
--   Op(name, params)                  -> f      (raises on a bad op or parameter; TryOp returns nil, message). params: numbers, strings, number lists, and the input fields
--                                     a, b, mask, dx, dz, like. A generator without `like` / width / height takes the map's size.
--   Height([step]) Stratum(layer[, raw]) New(w, h, value) Image(path[, opts]) Table(w, h, values)       sources
--   Scope()                           a list of handles to free together: s:Op(...) s:Height(...) s:Keep(f) s:Free()
--   Run(fn)                           fn(scope) with the scope freed afterwards (fn returns what it wants; s:Keep a field to take it out)
--   Pipeline(steps, scope, inputs)    steps = { { 'name', 'op', { params; a string '@other' is the field made by an earlier step or in `inputs` } }, ... } -> table name -> field
--   Stats(f) Checksum(f) Info(f) Read(f, x0, z0, x1, z1) Get(f, x, z) Sample(f, wx, wz) Free(f)
--   Preview(f, size[, opts])          -> VFS path of a thumbnail picture (for a Bitmap), lo, hi     opts: lo, hi, ramp = 'grey' | 'terrain' | 'heat'
--   CommitHeight(f[, opts])           writes the field into the map heights: ONE undo entry (history.lua), units re-snapped; -> samples changed
--   CommitMask(f, layer[, opts])      writes the field into the paint mask of texture layer 1..8 (0..1 = how much of the layer) -> samples changed; one undo entry
--   Apply{ height = f, masks = { { layer = 1, field = g }, ... }, label = '...' }     heights and masks as ONE undo entry -> samples changed, entry
--   TerrainTypes()                    the terrain-type grid as a field of TypeCodes      CommitTypes(f[, opts])  writes a field of TypeCodes into it: one undo entry (like CommitMask)
--   WaterMask(kind)                   a water mask (1 foam, 2 flatness, 3 depth bias) as a field      CommitWaterMask(f, kind[, opts])  writes a field into it: one undo entry
--   Timed(label, fn)                  runs fn and returns seconds (for the speed report)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Sim = import('/lua/editor/sim.lua')
local History = import('/lua/editor/history.lua')
local Terrain = import('/lua/editor/terrain.lua')

local function Available()
    return rawget(_G, 'ed_field_op') ~= nil
end

function IsAvailable()
    return Available()
end

function OpNames()
    return ed_field_ops()
end

function TryOp(name, params)
    return ed_field_op(name, params or {})
end

--- An op with several results: main field and a table of extras by name (the erosion solvers, the T7 variants, the colour ramp). The caller owns every handle. nil, message on failure.
function OpMulti(name, params)
    return ed_field_op_multi(name, params or {})
end

function Op(name, params)
    local f, err = ed_field_op(name, params or {})
    if not f then error(tostring(err), 2) end
    return f
end

local function Need(f, err)
    if not f then error(tostring(err), 3) end
    return f
end

function Height(step, x0, z0, x1, z1) return Need(ed_field_height(step or 1, x0, z0, x1, z1)) end
-- The engine decodes a paint mask byte the way the half-range shaders read it (saturate(2m - 1)); the full-range shaders read the byte as it is (shaders.lua RangeOf), so for those the
-- fields of a mask are made from, and written as, the raw bytes (m / 255 and e * 255).
local function FullRange()
    local ok, range = pcall(function() return import('/lua/editor/strata.lua').Range() end)
    return ok and range == 'full'
end

function Stratum(layer, raw)
    if not raw and FullRange() then
        local f = Need(ed_field_stratum(layer - 1, true))
        local g, err = ed_field_op('affine', { a = f, mul = 1 / 255, add = 0 })
        ed_field_free(f)
        return Need(g, err)
    end
    return Need(ed_field_stratum(layer - 1, raw))
end
function New(w, h, value, cell, ox, oz) return Need(ed_field_new(w, h, value or 0, cell or 1, ox or 0, oz or 0)) end
function Image(path, opts) return Need(ed_field_image(path, opts or {})) end
function Table(w, h, values, cell, ox, oz) return Need(ed_field_from_table(w, h, values, cell or 1, ox or 0, oz or 0)) end

function Free(f) ed_field_free(f) end
function Stats(f) return ed_field_stats(f) end
function Checksum(f) return ed_field_checksum(f) end
function Info(f) return ed_field_info(f) end
function Read(f, x0, z0, x1, z1) return ed_field_read(f, x0, z0, x1, z1) end
function Get(f, x, z) return ed_field_get(f, x, z) end
function Sample(f, wx, wz) return ed_field_sample(f, wx, wz) end

-- ---- scopes and pipelines -------------------------------------------------------------------------------------------------------------------------

--- A set of fields freed together.
function Scope()
    local S = { handles = {} }
    function S:Add(f)
        self.handles[f] = true
        return f
    end
    function S:Op(name, params) return self:Add(Op(name, params)) end
    function S:Height(step, x0, z0, x1, z1) return self:Add(Height(step, x0, z0, x1, z1)) end
    function S:Stratum(layer, raw) return self:Add(Stratum(layer, raw)) end
    function S:New(w, h, value, cell, ox, oz) return self:Add(New(w, h, value, cell, ox, oz)) end
    function S:Image(path, opts) return self:Add(Image(path, opts)) end
    function S:Table(w, h, values, cell, ox, oz) return self:Add(Table(w, h, values, cell, ox, oz)) end
    function S:Keep(f)
        self.handles[f] = nil
        return f
    end
    function S:Free()
        for f, _ in self.handles do ed_field_free(f) end
        self.handles = {}
    end
    return S
end

--- Runs fn(scope) and frees the scope's fields afterwards (also when fn raises).
function Run(fn)
    local S = Scope()
    local ok, a, b = pcall(fn, S)
    S:Free()
    if not ok then error(a, 2) end
    return a, b
end

--- Runs a recipe: steps { { 'name', 'op', params }, ... }. A string parameter '@x' is replaced by the field named x (an earlier step or `inputs`).
function Pipeline(steps, scope, inputs)
    local env = {}
    if inputs then for k, v in inputs do env[k] = v end end
    for _, step in steps do
        local params = {}
        for k, v in (step[3] or {}) do
            if type(v) == 'string' and string.sub(v, 1, 1) == '@' then
                local name = string.sub(v, 2)
                if not env[name] then error('pipeline step ' .. step[1] .. ': no field named ' .. name, 2) end
                params[k] = env[name]
            else
                params[k] = v
            end
        end
        env[step[1]] = scope:Op(step[2], params)
    end
    return env
end

function Timed(label, fn)
    local t0 = ed_field_clock()
    fn()
    return ed_field_clock() - t0
end

-- ---- preview pictures -----------------------------------------------------------------------------------------------------------------------------

local PREVIEW_DIR = '../fieldtmp'
local mounted = false
local serial = 0

--- Writes a thumbnail of the field (size x size at most, keeping the aspect) under a fresh name (textures are cached by name) and returns its VFS path, lo, hi.
function Preview(f, size, opts)
    opts = opts or {}
    local w, h = ed_field_info(f)
    local pw, ph = size, size
    if w > h then ph = math.max(1, math.floor(size * h / w + 0.5)) elseif h > w then pw = math.max(1, math.floor(size * w / h + 0.5)) end
    local px, lo, hi = ed_field_preview(f, pw, ph, opts)
    if not px then return nil end
    local path = PreviewPixels(px, pw, ph)
    if not path then return nil end
    return path, lo, hi
end

--- Writes ready made pixels (a list of pw * ph * 4 numbers 0..255) as a thumbnail picture under a fresh name; returns its VFS path (stage T7: the colour thumbnails of the graph).
function PreviewPixels(px, pw, ph)
    serial = serial + 1
    local name = 'f' .. serial .. '.dds'
    if not ed_dds_write(PREVIEW_DIR .. '/' .. name, pw, ph, px, 1) then return nil end
    if not mounted then
        ed_vfs_mount(PREVIEW_DIR, '/fieldtmp')
        mounted = true
    end
    return '/fieldtmp/' .. name
end

-- ---- commits --------------------------------------------------------------------------------------------------------------------------------------

--- Writes `f` into the map heights. opts: label, strength (0..1), mask (field), x0, z0, x1, z1. noHistory = true leaves the history entry to the caller (the document's own undo step exists
--- either way). Returns the number of samples that changed (0: nothing to undo).
function CommitHeight(f, opts)
    opts = opts or {}
    local depth = Terrain.UndoDepth()
    local changed, x0, z0, x1, z1 = ed_field_commit_height(f, opts)
    if not changed then return nil, x0 end
    if Terrain.UndoDepth() ~= depth then
        if not opts.noHistory then History.PushTerrain() end
        Sim.Resnap(x0, z0, x1, z1)
    end
    return changed, x0, z0, x1, z1
end

--- Writes `f` into the paint mask of texture layer 1..8. opts: raw, mode ('set' | 'max'), strength, mask, label. Returns the undo entry (or pushes it, unless opts.noPush) and the samples changed.
--- The entry holds two native copies of the mask (the bytes before and after); entry.release() frees them (the history does not call it when it drops old entries: 2 x the mask size, 0.5 MB at 512 x 512, stays until the editor closes).
function CommitMask(f, layer, opts)
    opts = opts or {}
    local stratum = layer - 1
    local src, o = f, opts
    if not opts.raw and FullRange() then
        src = Op('affine', { a = f, mul = 255, add = 0 })
        o = {}
        for k, v in opts do o[k] = v end
        o.raw = true
    end
    local before, changed = ed_field_commit_mask(src, stratum, o)
    if src ~= f then ed_field_free(src) end
    if not before then return nil, changed end
    if changed == 0 then
        ed_field_free(before)
        return nil, 0
    end
    local after = ed_field_stratum(stratum, true)
    local function Restore(raw)
        local old = ed_field_commit_mask(raw, stratum, { raw = true })
        if old then ed_field_free(old) end
    end
    local entry = {
        label = opts.label or ('field to layer ' .. layer),
        undo = function() Restore(before) end,
        redo = function() Restore(after) end,
        release = function() ed_field_free(before) ed_field_free(after) end,      -- the entry keeps two raw copies of the mask until then
    }
    if not opts.noPush then History.Push(entry) end
    return entry, changed
end

--- Heights and masks as one undo entry. `spec`: height (field), masks = { { layer, field, opts }, ... }, label, plus the options of CommitHeight.
function Apply(spec)
    local label = spec.label or 'Apply fields'
    local parts = {}
    local changed = 0
    local heightChanged = 0
    if spec.height then
        local o = {}
        for k, v in spec do o[k] = v end
        o.noHistory = true
        o.label = label
        local n = CommitHeight(spec.height, o)
        heightChanged = n or 0
        changed = changed + heightChanged
    end
    for _, m in (spec.masks or {}) do
        local o = {}
        for k, v in (m.opts or {}) do o[k] = v end
        o.noPush = true
        local entry, n = CommitMask(m.field, m.layer, o)
        if entry then
            table.insert(parts, entry)
            changed = changed + n
        end
    end
    if changed == 0 then return 0 end
    local entry = {
        label = label,
        undo = function()
            for i = table.getn(parts), 1, -1 do parts[i].undo() end
            if heightChanged > 0 then Terrain.Undo() end
        end,
        redo = function()
            if heightChanged > 0 then Terrain.Redo() end
            for i = 1, table.getn(parts) do parts[i].redo() end
        end,
        release = function() for _, part in parts do part.release() end end,
    }
    History.Push(entry)
    return changed, entry
end

-- ---- terrain types (stage T2) -----------------------------------------------------------------------------------------------------------------------

--- The terrain-type grid as a field of TypeCodes (one sample per grid cell).
function TerrainTypes() return Need(ed_field_tt()) end

--- Writes a field of TypeCodes (rounded, 0..255; another shape is read at the cell centres) into the terrain-type grid. opts: mask (cells where it is not above 0.5 keep their code), label, noPush.
--- Returns the undo entry (pushed to the history unless opts.noPush) and the number of cells changed; nil, message on failure. entry.release() frees the two native copies.
function CommitTypes(f, opts)
    opts = opts or {}
    local before, changed = ed_field_commit_tt(f, opts)
    if not before then return nil, changed end
    if changed == 0 then
        ed_field_free(before)
        return nil, 0
    end
    local after = ed_field_tt()
    local function Restore(codes)
        local old = ed_field_commit_tt(codes, {})
        if old then ed_field_free(old) end
        local ok, TT = pcall(import, '/lua/editor/terraintype.lua')
        if ok and TT then TT.Revision = TT.Revision + 1 end
    end
    local entry = {
        label = opts.label or 'field to terrain types',
        undo = function() Restore(before) end,
        redo = function() Restore(after) end,
        release = function() ed_field_free(before) ed_field_free(after) end,
    }
    local ok, TT = pcall(import, '/lua/editor/terraintype.lua')
    if ok and TT then TT.Revision = TT.Revision + 1 end
    if not opts.noPush then History.Push(entry) end
    return entry, changed
end

-- ---- water masks (foam, flatness, depth bias) ------------------------------------------------------------------------------------------------------

WATER_MASKS = { 'foam', 'flatness', 'depth bias' }

--- A water mask (kind 1 foam, 2 flatness, 3 depth bias) as a field 0..1 (one sample per mask cell, 2 world units).
function WaterMask(kind) return Need(ed_field_wmask(kind - 1)) end

--- Writes a field into a water mask: one undo entry like CommitMask / CommitTypes. opts: mask, strength, label, noPush. Returns the entry and the number of cells changed.
function CommitWaterMask(f, kind, opts)
    opts = opts or {}
    local before, changed = ed_field_commit_wmask(f, kind - 1, opts)
    if not before then return nil, changed end
    if changed == 0 then
        ed_field_free(before)
        return nil, 0
    end
    local after = ed_field_wmask(kind - 1)
    local function Restore(values)
        local old = ed_field_commit_wmask(values, kind - 1, {})
        if old then ed_field_free(old) end
    end
    local entry = {
        label = opts.label or ('field to water ' .. WATER_MASKS[kind]),
        undo = function() Restore(before) end,
        redo = function() Restore(after) end,
        release = function() ed_field_free(before) ed_field_free(after) end,
    }
    if not opts.noPush then History.Push(entry) end
    return entry, changed
end
