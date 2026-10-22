-- Map > Resize: crop, expand or scale the map to another size (docs/projects/editor/MAP_EDITOR_DESIGN.md 19.28).
--
-- The engine's terrain, paint masks and terrain-type grid cannot change their size in place, so a resize makes a COPY of the map in a new folder and reloads the session
-- on it (the original map is never touched: that is the undo, and the report says where it is):
--
--   phase 1 (Run, in the old session)   plans the change, writes the new folder (the blank template of the target size as .scmap, the scenario with the new size, the save
--                                       file with markers / areas / chains / units moved or dropped, the script, the sidecar with the paths moved) and the payload (heights,
--                                       paint masks and terrain types as raw float files made with the native field ops, props, decals, world values, texture layers),
--                                       then reloads the session on the new folder
--   phase 2 (ApplyPending, from Map.Load) writes the payload into the new session's native data and saves the folder (so the .scmap holds it)
--
--   Two ways to change the size (Options.mode):
--     'canvas'  the terrain stays as it is; the map is cut or padded around an anchor (a corner, an edge middle or the centre). Everything moves by the offset (ox, oz),
--               what falls outside the new bounds is dropped. Padding repeats the edge heights ('edge') or sits at a constant 'level'.
--     'scale'   the whole map is resampled to the new size (heights, masks and terrain types; every position is multiplied by the size ratio). Nothing is dropped.
--
--   Sizes                                       the target sizes (the templates of scripts/ed_make_blank_map.py)
--   Geometry(old, new, opts)                    -> g { old, new, mode, f, ox, oz }: the position mapping
--   MapPoint(g, x, z) / Inside(g, x, z) / MapRect(g, x0, z0, x1, z1)
--   TransformSave(save, g, opts)                -> new save table, report (markers, chains, areas, units: kept and dropped)
--   TransformPaths(list, g)                     -> new path list, report
--   Plan(opts)                                  -> { g, lines, ... } the report of what the resize would do (also drawn as bounds in the viewport: ShowBounds)
--   BuildFields(g, opts)                        -> { height = f, masks = { [i] = f }, tt = f, ... } the remapped native fields (the caller frees them)
--   Run(opts)                                   phase 1; returns true (the session is reloading) or false, reason
--   ApplyPending(doc)                           phase 2
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Map = import('/lua/editor/map.lua')
local Maps = import('/lua/editor/maps.lua')
local Ser = import('/lua/editor/luaser.lua')

Sizes = { 128, 256, 512, 1024, 2048, 4096 }

--- The dialog's settings (kept while the editor runs).
Options = { size = 512, mode = 'canvas', ax = 0.5, az = 0.5, fill = 'edge', level = 25, playable = 'keep' }

DIR = 'editor_resize'
PAYLOAD = DIR .. '/payload.lua'

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR resize: ' .. text)
end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end

local function SortedKeys(t)
    local keys = {}
    for k, _ in t do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- ---- geometry ------------------------------------------------------------------------------------------------------------------------------------

--- Folder name and scenario file of the blank template of a size.
function TemplateScenario(n)
    if n == 256 then return '/maps/editor_blank/editor_blank_scenario.lua' end
    return '/maps/editor_blank_' .. n .. '/editor_blank_' .. n .. '_scenario.lua'
end

local function TemplateScmap(n)
    return string.gsub(TemplateScenario(n), '_scenario%.lua$', '.scmap')
end

function TemplateAvailable(n)
    local ok, info = pcall(DiskGetFileInfo, TemplateScmap(n))
    return ok and info ~= nil and info ~= false
end

--- The mapping from old to new world coordinates. canvas: new = old + (ox, oz) where the offset puts the old map at the anchor (ax, az in 0..1: 0 = west / north edge, 1 = east /
--- south edge); scale: new = old * f.
function Geometry(oldN, newN, opts)
    opts = opts or {}
    local g = { old = oldN, new = newN, mode = (opts.mode == 'scale') and 'scale' or 'canvas', f = 1, ox = 0, oz = 0 }
    if g.mode == 'scale' then
        g.f = newN / oldN
    else
        g.ox = math.floor((opts.ax or 0.5) * (newN - oldN) + 0.5)
        g.oz = math.floor((opts.az or 0.5) * (newN - oldN) + 0.5)
    end
    return g
end

function MapPoint(g, x, z)
    return x * g.f + g.ox, z * g.f + g.oz
end

--- True when the new position is on the new map.
function Inside(g, x, z)
    return x >= 0 and z >= 0 and x <= g.new and z <= g.new
end

--- A rectangle moved to the new map and cut to its bounds, or nil when nothing (less than one unit in either direction) is left.
function MapRect(g, x0, z0, x1, z1)
    local ax, az = MapPoint(g, math.min(x0, x1), math.min(z0, z1))
    local bx, bz = MapPoint(g, math.max(x0, x1), math.max(z0, z1))
    ax, az = math.max(0, ax), math.max(0, az)
    bx, bz = math.min(g.new, bx), math.min(g.new, bz)
    if bx - ax < 1 or bz - az < 1 then return nil end
    return ax, az, bx, bz
end

-- ---- the save file (markers, chains, areas, units) ---------------------------------------------------------------------------------------------

local function WalkUnits(tbl, g, rep)
    for _, name in SortedKeys(tbl) do
        local u = tbl[name]
        if type(u) == 'table' then
            if u.Position and u.type and u.type ~= 'GROUP' then
                local x, z = MapPoint(g, u.Position[1], u.Position[3])
                if Inside(g, x, z) then
                    u.Position = { x, u.Position[2], z, type = 'VECTOR3' }
                    rep.units.kept = rep.units.kept + 1
                else
                    tbl[name] = nil
                    rep.units.dropped = rep.units.dropped + 1
                end
            elseif u.type == 'GROUP' and u.Units then
                WalkUnits(u.Units, g, rep)
            end
        end
    end
end

--- Moves the objects of a save file (a copy of `save`) onto the new map. opts.playable = 'keep' (move AREA_1) | 'whole' (drop AREA_1: the whole new map is playable).
--- Returns the new save table and the report { markers = {kept, dropped = {names}}, chains = {kept, dropped = {names}, trimmed = {names}}, areas = {...}, units = {kept, dropped} }.
function TransformSave(save, g, opts)
    opts = opts or {}
    local s = Copy(save)
    local rep = { markers = { kept = 0, dropped = {} }, chains = { kept = 0, dropped = {}, trimmed = {} }, areas = { kept = 0, dropped = {} },
                  units = { kept = 0, dropped = 0 }, starts = {} }
    local markers = (s.MasterChain and s.MasterChain._MASTERCHAIN_ and s.MasterChain._MASTERCHAIN_.Markers) or {}
    local gone = {}
    for _, name in SortedKeys(markers) do
        local m = markers[name]
        local p = m.position
        if p and p[1] then
            local x, z = MapPoint(g, p[1], p[3])
            if Inside(g, x, z) then
                if g.mode == 'scale' and (m.type == 'Mass' or m.type == 'Hydrocarbon') then
                    -- resources sit on the build grid (a scaled position would be off it)
                    local ok, sx, sz = pcall(function() return import('/lua/editor/grid.lua').SnapMarker(m.type, x, z) end)
                    if ok and sx then x, z = sx, sz end
                end
                m.position = { x, p[2], z, type = 'VECTOR3' }
                rep.markers.kept = rep.markers.kept + 1
            else
                markers[name] = nil
                gone[name] = true
                table.insert(rep.markers.dropped, name)
                if string.find(name, '^ARMY_%d+$') then table.insert(rep.starts, name) end
            end
        else
            rep.markers.kept = rep.markers.kept + 1
        end
    end
    -- chains lose the markers that are gone (a chain with none left goes), adjacency lists lose them too
    for _, cname in SortedKeys(s.Chains or {}) do
        local c = s.Chains[cname]
        if type(c) == 'table' and c.Markers then
            local keep = {}
            local lost = false
            for _, n in c.Markers do
                if gone[n] then lost = true else table.insert(keep, n) end
            end
            if table.getn(keep) == 0 and lost then
                s.Chains[cname] = nil
                table.insert(rep.chains.dropped, cname)
            else
                if lost then
                    c.Markers = keep
                    table.insert(rep.chains.trimmed, cname)
                end
                rep.chains.kept = rep.chains.kept + 1
            end
        end
    end
    for _, name in SortedKeys(markers) do
        local m = markers[name]
        if type(m.adjacentTo) == 'string' and m.adjacentTo ~= '' then
            local keep = {}
            for token in string.gfind(m.adjacentTo, '%S+') do
                if not gone[token] then table.insert(keep, token) end
            end
            m.adjacentTo = table.concat(keep, ' ')
        end
    end
    for _, name in SortedKeys(s.Areas or {}) do
        local a = s.Areas[name]
        local r = type(a) == 'table' and a.rectangle
        if r then
            if name == 'AREA_1' and opts.playable == 'whole' then
                s.Areas[name] = nil
            else
                local x0, z0, x1, z1 = MapRect(g, r[1], r[2], r[3], r[4])
                if x0 then
                    a.rectangle = { x0, z0, x1, z1, type = 'RECTANGLE' }
                    rep.areas.kept = rep.areas.kept + 1
                else
                    s.Areas[name] = nil
                    table.insert(rep.areas.dropped, name)
                end
            end
        end
    end
    for _, aname in SortedKeys(s.Armies or {}) do
        local a = s.Armies[aname]
        if type(a) == 'table' and a.Units and a.Units.Units then WalkUnits(a.Units.Units, g, rep) end
    end
    return s, rep
end

--- Paths (the terrain tool's splines): points move with the map, points outside go, a path with fewer than two points goes. Widths and falloffs keep their size; handles scale with the map.
function TransformPaths(list, g)
    local out = {}
    local rep = { kept = 0, dropped = {}, points = 0 }
    for _, p in list or {} do
        local c = Copy(p)
        local pts = {}
        for _, q in c.points or {} do
            local x, z = MapPoint(g, q.x, q.z)
            if Inside(g, x, z) then
                q.x, q.z = x, z
                if q.ho then q.ho = { q.ho[1] * g.f, q.ho[2] * g.f } end
                if q.hi then q.hi = { q.hi[1] * g.f, q.hi[2] * g.f } end
                table.insert(pts, q)
            else
                rep.points = rep.points + 1
            end
        end
        if table.getn(pts) >= 2 then
            c.points = pts
            table.insert(out, c)
            rep.kept = rep.kept + 1
        else
            table.insert(rep.dropped, c.name or c.id or '?')
        end
    end
    return out, rep
end

-- ---- props and decals (native lists of the .scmap) ----------------------------------------------------------------------------------------------

--- Props and decals of the open session on the new map: lists of entries and the number dropped.
function CollectObjects(g)
    local props, decals = {}, {}
    local pd, dd = 0, 0
    for i = 1, ed_prop_count() do
        local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
        if bp then
            local nx, nz = MapPoint(g, x, z)
            if Inside(g, nx, nz) then
                table.insert(props, { bp = bp, x = nx, y = y, z = nz, heading = 2 * math.atan2(qy, qw), sx = sx, sy = sy, sz = sz })
            else
                pd = pd + 1
            end
        end
    end
    for i = 1, ed_decal_count() do
        local t0, t1, kind, x, y, z, sx, sy, sz, ox, oy, oz, cutoff = ed_decal_get(i)
        if t0 then
            local nx, nz = MapPoint(g, x, z)
            if Inside(g, nx, nz) then
                table.insert(decals, { tex = t0, kind = kind, x = nx, y = y, z = nz, sx = sx, sy = sy, sz = sz, ox = ox, oy = oy, oz = oz, cutoff = cutoff })
            else
                dd = dd + 1
            end
        end
    end
    return props, decals, pd, dd
end

-- ---- the report --------------------------------------------------------------------------------------------------------------------------------------

local function Names(list, max)
    max = max or 6
    local s = {}
    for i, n in list do
        if i > max then
            table.insert(s, '... +' .. (table.getn(list) - max))
            break
        end
        table.insert(s, tostring(n))
    end
    return table.concat(s, ', ')
end

local function SourceSize()
    local w = ed_terrain_info()
    return (w or 257) - 1
end

--- What a resize with `opts` would do, without doing it. Returns { error = text } or { g, lines, counts... }.
function Plan(opts)
    opts = opts or Options
    if not Map.Doc then Map.Load() end
    if not Map.Doc then return { error = 'no map is open' } end
    if Map.Doc.info.TerrainMesh then return { error = 'mesh terrain maps cannot be resized' } end
    local old = SourceSize()
    local new = opts.size
    if new == old then return { error = 'the map already has this size' } end
    if not TemplateAvailable(new) then return { error = 'the blank map of ' .. new .. ' is missing (scripts/ed_make_blank_map.py --size ' .. new .. ')' } end
    local g = Geometry(old, new, opts)
    local plan = { g = g, old = old, new = new, lines = {}, opts = opts }
    local lines = plan.lines
    local newSave, rep = TransformSave(Map.Doc.save, g, opts)
    plan.save, plan.rep = newSave, rep
    local props, decals, pd, dd = CollectObjects(g)
    plan.props, plan.decals, plan.propsDropped, plan.decalsDropped = props, decals, pd, dd
    local m = (g.mode == 'canvas') and ('canvas, offset ' .. g.ox .. ', ' .. g.oz) or ('scaled by ' .. string.format('%.3f', g.f))
    table.insert(lines, old .. ' -> ' .. new .. '  (' .. m .. ')')
    if g.mode == 'canvas' and new < old then
        table.insert(lines, 'cropped: the map outside the new bounds is cut off')
    elseif g.mode == 'canvas' then
        table.insert(lines, 'padded with ' .. ((opts.fill == 'level') and ('a constant height of ' .. opts.level) or 'the edge heights'))
    end
    table.insert(lines, 'markers: ' .. rep.markers.kept .. ' kept, ' .. table.getn(rep.markers.dropped) .. ' dropped' ..
        (table.getn(rep.markers.dropped) > 0 and (' (' .. Names(rep.markers.dropped) .. ')') or ''))
    if table.getn(rep.starts) > 0 then
        table.insert(lines, 'START POSITIONS DROPPED: ' .. Names(rep.starts))
    end
    table.insert(lines, 'chains: ' .. rep.chains.kept .. ' kept, ' .. table.getn(rep.chains.dropped) .. ' dropped, ' .. table.getn(rep.chains.trimmed) .. ' shortened' ..
        (table.getn(rep.chains.dropped) > 0 and (' (gone: ' .. Names(rep.chains.dropped) .. ')') or ''))
    table.insert(lines, 'areas: ' .. rep.areas.kept .. ' kept, ' .. table.getn(rep.areas.dropped) .. ' dropped' ..
        (table.getn(rep.areas.dropped) > 0 and (' (' .. Names(rep.areas.dropped) .. ')') or ''))
    table.insert(lines, 'units: ' .. rep.units.kept .. ' kept, ' .. rep.units.dropped .. ' dropped')
    table.insert(lines, 'props: ' .. table.getn(props) .. ' kept, ' .. pd .. ' dropped;  decals: ' .. table.getn(decals) .. ' kept, ' .. dd .. ' dropped')
    local paths = {}
    pcall(function() paths = import('/lua/editor/paths.lua').ExportData() end)
    local _, prep = TransformPaths(paths, g)
    plan.paths = prep
    if table.getn(paths) > 0 then
        table.insert(lines, 'paths: ' .. prep.kept .. ' kept, ' .. table.getn(prep.dropped) .. ' dropped, ' .. prep.points .. ' points outside')
    end
    if opts.playable == 'whole' then
        table.insert(lines, 'playable area: the whole new map')
    end
    local graphNodes = 0
    pcall(function() local c = import('/lua/editor/graph.lua').Current graphNodes = c and c.nodes and table.getn(c.nodes) or 0 end)
    if graphNodes > 0 then
        table.insert(lines, 'terrain graph: kept as it is (its outputs were made for the old size; run it again)')
    end
    plan.dropped = table.getn(rep.markers.dropped) + table.getn(rep.chains.dropped) + table.getn(rep.areas.dropped) + rep.units.dropped + pd + dd
    return plan
end

-- ---- the viewport preview -----------------------------------------------------------------------------------------------------------------------

local boundsIds = { 'resize:old', 'resize:new', 'resize:keep' }

local function Rect(id, x0, z0, x1, z1, color, width)
    local y = 40
    ed_overlay_set(id, { x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1 }, color, width, 2, 6, true, false)
end

--- Draws the new bounds (in the coordinates of the open map) in the viewport: the old map in grey, the new map in green, the part that is kept in white. Scale mode shows the same square.
function ShowBounds(plan)
    if rawget(_G, 'ed_overlay_set') == nil then return end
    if not plan or plan.error then ClearBounds() return end
    local g = plan.g
    local S = g.old
    Rect('resize:old', 0, 0, S, S, '80A0A0A0', 0.4)
    if g.mode == 'scale' then
        Rect('resize:new', 0, 0, S, S, 'FF40FF60', 0.8)
        ed_overlay_remove('resize:keep')
    else
        -- the new map in old coordinates: the old map sits at (ox, oz) in the new one
        Rect('resize:new', -g.ox, -g.oz, g.new - g.ox, g.new - g.oz, 'FF40FF60', 0.8)
        local x0, z0 = math.max(0, -g.ox), math.max(0, -g.oz)
        local x1, z1 = math.min(S, g.new - g.ox), math.min(S, g.new - g.oz)
        Rect('resize:keep', x0, z0, x1, z1, 'C0FFFFFF', 0.5)
    end
end

function ClearBounds()
    if rawget(_G, 'ed_overlay_remove') == nil then return end
    for _, id in boundsIds do ed_overlay_remove(id) end
end

-- ---- the remapped native fields -----------------------------------------------------------------------------------------------------------------

--- The resampled fields for the new map: { height = f ((new+1)^2), masks = { [stratum] = f }, maskW, maskH, tt = f, ttW, ttH }. Heights and masks are sampled at the new sample positions
--- (outside the old map the nearest edge value: bilinear, clamped). The caller frees the handles (Free).
function BuildFields(g)
    local N = g.new
    local out = { masks = {}, handles = {} }
    local function Keep(f) table.insert(out.handles, f) return f end
    local src = Keep(ed_field_height())
    local like = Keep(ed_field_new(N + 1, N + 1, 0, (g.mode == 'scale') and (1 / g.f) or 1, -g.ox, -g.oz))
    out.height = Keep(ed_field_op('resample', { a = src, like = like }))
    local mw0, mh0 = ed_stratum_info()
    if mw0 then
        local ps0 = g.old / mw0
        local mw1 = math.max(2, math.floor(mw0 * N / g.old + 0.5))
        out.maskW, out.maskH = mw1, mw1
        for i = 0, 7 do
            local f = ed_field_stratum(i, true)
            if f then
                Keep(f)
                local cell = (g.mode == 'scale') and (ps0 / g.f) or ps0
                local origin = (g.mode == 'scale') and (0.5 * ps0 / g.f) or (0.5 * ps0 - g.ox)
                local originZ = (g.mode == 'scale') and origin or (0.5 * ps0 - g.oz)
                local lk = Keep(ed_field_new(mw1, mw1, 0, cell, origin, originZ))
                out.masks[i] = Keep(ed_field_op('resample', { a = f, like = lk }))
            end
        end
    end
    local tw0, th0 = ed_tt_info()
    if tw0 then
        local ps0 = g.old / tw0
        local tw1 = math.max(2, math.floor(tw0 * N / g.old + 0.5))
        out.ttW, out.ttH = tw1, tw1
        local f = Keep(ed_field_tt())
        if g.mode == 'canvas' then
            local lk = Keep(ed_field_new(tw1, tw1, 0, ps0, 0.5 * ps0 - g.ox, 0.5 * ps0 - g.oz))
            out.tt = Keep(ed_field_op('resample', { a = f, like = lk }))
        else
            -- codes are not numbers to blend: nearest cell
            local values = {}
            local read = {}
            local rowsPer = math.max(1, math.floor(65536 / tw0))
            for z0 = 0, th0 - 1, rowsPer do
                local z1 = math.min(th0 - 1, z0 + rowsPer - 1)
                local rows = ed_field_read(f, 0, z0, tw0 - 1, z1)
                for i = 1, table.getn(rows) do read[z0 * tw0 + i] = rows[i] end
            end
            for z = 0, tw1 - 1 do
                local sz = math.min(th0 - 1, math.max(0, math.floor((z + 0.5) / g.f / ps0)))
                for x = 0, tw1 - 1 do
                    local sx = math.min(tw0 - 1, math.max(0, math.floor((x + 0.5) / g.f / ps0)))
                    values[z * tw1 + x + 1] = read[sz * tw0 + sx + 1]
                end
            end
            out.tt = Keep(ed_field_from_table(tw1, tw1, values))
        end
    end
    return out
end

function Free(fields)
    for _, h in fields.handles or {} do pcall(ed_field_free, h) end
    fields.handles = {}
end

-- ---- phase 1 --------------------------------------------------------------------------------------------------------------------------------------

local function Join(a, b)
    return (string.gsub(a, '/+$', '')) .. '/' .. b
end

local function FreeFolder(base, stem)
    local n = 0
    local dir, name
    repeat
        n = n + 1
        name = (n == 1) and stem or (stem .. '_' .. n)
        dir = Join(base, name .. '.v0001')
    until not ed_file_exists(dir .. '/' .. name .. '_scenario.lua')
    return dir, name
end

local DEFAULT_SCRIPT = "local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')\n\nfunction OnPopulate()\n    ScenarioUtils.InitializeArmies()\nend\n\nfunction OnStart(self)\nend\n"
local HEADER = "--[[  Generated by FAF Studio (Map > Resize)  ]]--\n"

local function MapsBase()
    local b = Maps.UserMapsDir()
    if b then return (string.gsub(b, '\\', '/')) end
    return '../mapout'
end

--- Makes the resized copy and reloads the session on it. Returns true, or false and the reason. The caller has dealt with unsaved changes (they are part of the copy but not of
--- the original on disk).
function Run(opts)
    opts = opts or Options
    local plan = Plan(opts)
    if plan.error then return false, plan.error end
    local g = plan.g
    local doc = Map.Doc
    local stemBase = Maps.Sanitize(doc.info.name or 'map') .. '_' .. g.new
    local dir, stem = FreeFolder(opts.base or MapsBase(), stemBase)
    local mount = '/maps/' .. string.lower(stem .. '.v0001')

    -- the fields first (they read the open session)
    local fields = BuildFields(g)
    local files = { height = DIR .. '/height.r32', tt = DIR .. '/tt.r32' }
    local ok, why = ed_img_write(files.height, fields.height, { bits = 32 })
    if not ok then Free(fields) return false, 'height file: ' .. tostring(why) end
    local maskFiles = {}
    for i, f in fields.masks do
        maskFiles[i] = DIR .. '/mask' .. i .. '.r32'
        ok, why = ed_img_write(maskFiles[i], f, { bits = 32 })
        if not ok then Free(fields) return false, 'mask file: ' .. tostring(why) end
    end
    if fields.tt then
        ok, why = ed_img_write(files.tt, fields.tt, { bits = 32 })
        if not ok then Free(fields) return false, 'terrain type file: ' .. tostring(why) end
    end
    local maskW, maskH, ttW, ttH = fields.maskW, fields.maskH, fields.ttW, fields.ttH
    Free(fields)

    -- the sidecar (mission, graph, terrain types, interop as they are; the paths moved)
    local paths = {}
    pcall(function() paths = import('/lua/editor/paths.lua').ExportData() end)
    local newPaths = TransformPaths(paths, g)
    local pathsText = (table.getn(newPaths) > 0) and Ser.Chunk({ { 'Paths', newPaths } }) or ''

    -- the scenario with the new size and the new file names
    local info = {}
    for k, v in doc.info do info[k] = Copy(v) end
    info.file = nil
    info.size = { g.new, g.new }
    info.map = mount .. '/' .. stem .. '.scmap'
    info.save = mount .. '/' .. stem .. '_save.lua'
    info.script = mount .. '/' .. stem .. '_script.lua'
    info.name = (doc.info.name or 'map') .. ' (' .. g.new .. ')'

    local script
    if doc.scriptPath then
        local disk = ed_vfs_to_disk(doc.scriptPath)
        if disk then script = ed_read_file(disk) end
    end
    script = script or DEFAULT_SCRIPT

    local template = ed_vfs_to_disk(TemplateScmap(g.new))
    local scmap = template and ed_read_file(template)
    if not scmap then return false, 'cannot read the blank map of ' .. g.new end

    local world = ed_world_get()
    local layers = {}
    for i = 0, 19 do
        local path, tile = ed_stratum_layer(i)
        if path and path ~= '' then table.insert(layers, { i = i, path = path, tile = tile }) end
    end

    local payload = {
        size = g.new, old = g.old, mode = g.mode, ox = g.ox, oz = g.oz, f = g.f,
        fill = opts.fill, level = opts.level, dir = dir, stem = stem, name = info.name,
        source = doc.scenarioPath, files = files, maskFiles = maskFiles, maskW = maskW, maskH = maskH, ttW = ttW, ttH = ttH,
        world = world, layers = layers, props = plan.props, decals = plan.decals, lines = plan.lines,
        shader = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or nil,          -- the blank template has its own shader; the masks are copied as raw bytes in the old shader's range
    }
    local good = ed_write_file(dir .. '/' .. stem .. '.scmap', scmap)
    good = ed_write_file(dir .. '/' .. stem .. '_scenario.lua', Ser.ScenarioChunk(info)) and good
    good = ed_write_file(dir .. '/' .. stem .. '_save.lua', HEADER .. Ser.Chunk({ { 'Scenario', plan.save } })) and good
    good = ed_write_file(dir .. '/' .. stem .. '_script.lua', script) and good
    good = ed_write_file(dir .. '/' .. stem .. '_editor.lua', import('/lua/editor/mods.lua').SidecarText(pathsText)) and good
    good = ed_write_file(PAYLOAD, Ser.Chunk({ { 'Payload', payload } })) and good
    good = ed_write_file(DIR .. '/report.txt', table.concat(plan.lines, '\n') .. '\n') and good
    if not good then return false, 'writing the new map folder failed' end
    Say('resizing ' .. g.old .. ' -> ' .. g.new .. ' into ' .. dir)
    ClearBounds()
    Maps.OpenFolder(dir, stem, 'resize=' .. PAYLOAD .. '\n')
    return true
end

-- ---- phase 2 --------------------------------------------------------------------------------------------------------------------------------------

local function LoadPayload(path)
    local text = ed_read_file(path)
    if not text then return nil, 'no payload file' end
    local chunk = loadstring(text, '=resize')
    if not chunk then return nil, 'bad payload file' end
    local env = {}
    doscript('/lua/dataInit.lua', env)
    setfenv(chunk, env)
    local ok, err = pcall(chunk)
    if not ok then return nil, tostring(err) end
    return env.Payload
end

local function ReadField(path, w, h)
    local f = ed_img_read(path, { bits = 32, float = 1, width = w, height = h })
    return f
end

--- Writes the payload into the open session (the new, still blank map). Called from Map.Load; saves the folder a little later (the preview picture needs a running view).
function ApplyPending(doc)
    local path = doc.resizePayload
    doc.resizePayload = nil
    local P, why = LoadPayload(path)
    if not P then Say('resize failed: ' .. tostring(why)) return false end
    local w = ed_terrain_info()
    if (w or 0) - 1 ~= P.size then
        Say('resize failed: the session has a ' .. tostring((w or 0) - 1) .. ' map, not ' .. P.size)
        return false
    end
    local Fields = import('/lua/editor/fields.lua')
    local N = P.size
    local handles = {}
    -- heights
    local h = ReadField(P.files.height, N + 1, N + 1)
    if h then
        table.insert(handles, h)
        Fields.CommitHeight(h, { label = 'resize', noHistory = true })
    else
        Say('resize: the height file could not be read')
    end
    -- constant padding outside the old map (canvas expand)
    if P.mode == 'canvas' and P.fill == 'level' then
        local x0, z0 = P.ox, P.oz
        local x1, z1 = P.ox + P.old, P.oz + P.old
        local lvl = P.level
        if z0 > 0 then ed_terrain_set_rect(0, 0, N, z0 - 1, lvl) end
        if z1 < N then ed_terrain_set_rect(0, z1 + 1, N, N, lvl) end
        local ya, yb = math.max(0, z0), math.min(N, z1)
        if x0 > 0 then ed_terrain_set_rect(0, ya, x0 - 1, yb, lvl) end
        if x1 < N then ed_terrain_set_rect(x1 + 1, ya, N, yb, lvl) end
    end
    -- paint masks and terrain types: the files have the size the old map's cell size gives; the new template may use another grid
    local mw, mh = ed_stratum_info()
    for i, file in P.maskFiles or {} do
        local f = ReadField(file, P.maskW, P.maskH)
        if f then
            table.insert(handles, f)
            if mw and (mw ~= P.maskW or mh ~= P.maskH) then
                local r = ed_field_op('resize', { a = f, width = mw, height = mh })
                if r then table.insert(handles, r) f = r end
            end
            local before = ed_field_commit_mask(f, i, { raw = true })
            if before then table.insert(handles, before) end
        end
    end
    pcall(ed_stratum_flush)
    if P.ttW then
        local f = ReadField(P.files.tt, P.ttW, P.ttH)
        if f then
            table.insert(handles, f)
            local tw, th = ed_tt_info()
            if tw and (tw ~= P.ttW or th ~= P.ttH) then
                local r = ed_field_op('resize', { a = f, width = tw, height = th })
                if r then table.insert(handles, r) f = r end
            end
            local before = ed_field_commit_tt(f)
            if before then table.insert(handles, before) end
        end
    end
    for _, hnd in handles do pcall(ed_field_free, hnd) end
    -- world values and the texture layers of the old map
    if P.world then pcall(ed_world_set, P.world, true) end
    if P.shader and P.shader ~= '' and rawget(_G, 'ed_stratum_shader') then pcall(ed_stratum_shader, P.shader) end
    for _, l in P.layers or {} do pcall(ed_stratum_set_layer, l.i, l.path, l.tile) end
    -- the map-wide pictures (normal map, lighting ...) were restored with the tile size of the old map: give them the new one so the shader keeps using them, and mark them out of date
    local okMT, wide = pcall(function() return import('/lua/editor/maptextures.lua').AfterResize(P.old, P.size) end)
    if okMT and wide and table.getn(wide) > 0 then
        P.lines = P.lines or {}
        table.insert(P.lines, 'map textures (' .. table.concat(wide, ', ') .. '): kept active at the new size; they still show the old map, generate them again in the Map textures panel')
    end
    -- props and decals
    for _, p in P.props or {} do Map.AddProp(p.bp, p.x, p.y, p.z, p.heading, { p.sx, p.sy, p.sz }) end
    for _, d in P.decals or {} do ed_decal_add(d.tex, d.kind, d.x, d.y, d.z, d.ox, d.oy, d.oz, d.sx, d.sy, d.sz, d.cutoff) end
    doc.info.name = P.name or doc.info.name
    LastReport = P.lines
    Say('resized to ' .. P.size .. ': ' .. table.getn(P.props or {}) .. ' props, ' .. table.getn(P.decals or {}) .. ' decals moved')
    -- save the folder so the .scmap holds the new terrain; a few seconds later, when the view is up
    local dir, stem = P.dir, P.stem
    ForkThread(function()
        WaitSeconds(3)
        local scenario, err = Maps.SaveTo(dir, stem)
        Saved = scenario and true or false
        Say(scenario and ('resized map saved: ' .. dir) or ('the resized map could not be saved: ' .. tostring(err)))
    end)
    return true
end

LastReport = false
Saved = false          -- true once the resized folder has been written (a few seconds after the reload)
