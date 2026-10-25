-- Props scatter (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2): fills the map with props from a list of blueprints, steered by a density mask (the mask generator's rules), slope and
-- height limits and a minimum distance between props (dart throwing on a grid = Poisson disc sampling with a variable density). Seeded and deterministic: the same settings on the same terrain
-- place the same props. Symmetry aware: with a symmetry mode on, every prop is placed together with its images (heading mirrored or turned), judged once at the original position.
-- ONE undo step.
--
--   Settings       mode ('props' or 'decals': the same rules scatter terrain decals, Decals.Active style: Entries then hold albedo decal textures), decalSize (units at scale 100 percent),
--                  withNormals (decals: add the matching normals decal), seed, count (most props placed), minDist, fill (0..1: how much of the density mask is used), slopeMin / slopeMax (degrees), heightMin / heightMax, scaleMin / scaleMax (percent),
--                  randomHeading, avoidExisting (keep minDist to the props already on the map), margin (units from the map edge)
--   Entries        list of { bp = path, weight = number } (prop blueprints, or albedo decal textures when Settings.mode is 'decals'); each mode keeps its own list: Entries and DecalEntries
--   Density        the mask definition (maskgen.lua) that says where props go; no rules = everywhere
--   Plan() -> list, report | nil, message     { bp, x, z, heading, scale } for every prop (no change to the map)
--   Apply() -> placed | nil, message          places them
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Map = import('/lua/editor/map.lua')
local Props = import('/lua/editor/props.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local GenSym = import('/lua/editor/gensym.lua')
local History = import('/lua/editor/history.lua')

Settings = {
    mode = 'props', decalSize = 10, withNormals = true,
    seed = 1, count = 1000, minDist = 6, fill = 1, slopeMin = 0, slopeMax = 35, heightMin = -100, heightMax = 600,
    scaleMin = 80, scaleMax = 120, randomHeading = true, avoidExisting = true, margin = 4, underWater = false,
}

Entries = {}
DecalEntries = {}
Density = { rules = {} }

-- ---- a random stream that does not depend on the engine's math.random --------------------------------------------------------------------------------
-- Wichmann and Hill (1982): three small linear congruential generators; every product stays below 2^24, so the 32 bit floats of Lua compute it exactly.

local function Stream(seed)
    seed = math.floor(seed)
    local s1 = math.mod(seed * 7 + 1, 30268) + 1
    local s2 = math.mod(seed * 13 + 5, 30306) + 1
    local s3 = math.mod(seed * 29 + 11, 30322) + 1
    local R = { }
    function R.next()
        s1 = math.mod(171 * s1, 30269)
        s2 = math.mod(172 * s2, 30307)
        s3 = math.mod(170 * s3, 30323)
        local r = s1 / 30269 + s2 / 30307 + s3 / 30323
        return r - math.floor(r)
    end
    for i = 1, 10 do R.next() end      -- the first values of nearby seeds are alike
    return R
end

Stream_ = Stream      -- for the self test

-- ---- the plan ---------------------------------------------------------------------------------------------------------------------------------------

local PI2 = 6.2831853

--- Where the props go. Returns the list { bp, x, z, heading, scale } and a report { attempts, tooClose, rejected, placed }, or nil and a message.
function Plan(opts)
    -- opts (the terrain graph, graphrun.lua): settings, entries, density (a mask field, instead of the Density rules), symmetry (a spec of gensym.lua, false = none; default: the editor's)
    opts = opts or {}
    local s = opts.settings or Settings
    local entries = opts.entries or ((s.mode == 'decals') and DecalEntries or Entries)
    if table.getn(entries) == 0 then return nil, (s.mode == 'decals') and 'pick at least one decal texture' or 'pick at least one prop blueprint' end
    if not Fields.IsAvailable() or not ed_terrain_info() then return nil, 'no terrain' end
    local size = ed_terrain_info() - 1
    local weightSum = 0
    for _, e in entries do weightSum = weightSum + math.max(0, e.weight or 1) end
    if weightSum <= 0 then return nil, 'all weights are zero' end

    return Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        -- acceptance: the density mask times the slope and height limits (and dry land unless asked otherwise)
        local accept
        if opts.density then
            accept = S:Op('resample', { a = opts.density, like = c.H })
        elseif table.getn(Density.rules) > 0 then
            local m, err = MaskGen.Evaluate(c, Density)
            if not m then return nil, err end
            accept = m
        else
            accept = S:Op('const', { like = c.H, value = 1 })
        end
        local slope = S:Op('slope', { a = c.H, mode = 'degrees', radius = 1 })
        accept = S:Op('mul', { a = accept, b = S:Op('height_band', { a = slope, lo = s.slopeMin, hi = s.slopeMax, soft = 0 }) })
        accept = S:Op('mul', { a = accept, b = S:Op('height_band', { a = c.H, lo = s.heightMin, hi = s.heightMax, soft = 0 }) })
        if not s.underWater then
            accept = S:Op('mul', { a = accept, b = S:Op('water_above', { a = c.H, level = c.water, soft = 0 }) })
        end

        local _, openMax = Fields.Stats(accept)          -- 0: no ground passes the density, slope, height and water limits (said in the report, not only "off the density")
        local R = Stream(s.seed)
        local d = math.max(0.5, s.minDist)
        local grid = {}
        local function Key(x, z) return math.floor(x / d) * 100003 + math.floor(z / d) end
        local function Near(x, z)
            local gx, gz = math.floor(x / d), math.floor(z / d)
            for ix = gx - 1, gx + 1 do
                for iz = gz - 1, gz + 1 do
                    local cell = grid[ix * 100003 + iz]
                    if cell then
                        for _, q in cell do
                            local dx, dz = q[1] - x, q[2] - z
                            if dx * dx + dz * dz < d * d then return true end
                        end
                    end
                end
            end
            return false
        end
        local function Remember(x, z)
            local k = Key(x, z)
            local cell = grid[k]
            if not cell then
                cell = {}
                grid[k] = cell
            end
            table.insert(cell, { x, z })
        end
        if s.avoidExisting then
            if s.mode == 'decals' then
                for i = 1, ed_decal_count() do
                    local t0, t1, kind, x, y, z = ed_decal_get(i)
                    if t0 and kind ~= 2 then Remember(x, z) end          -- (a normals decal stands where its albedo decal does)
                end
            else
                for i = 1, ed_prop_count() do
                    local bp, x, y, z = ed_prop_get(i)
                    if bp then Remember(x, z) end
                end
            end
        end

        local margin = math.max(0, s.margin)
        local span = size - 2 * margin
        if span <= 0 then return nil, 'the margin is bigger than the map' end
        local lo, hi = s.scaleMin / 100, s.scaleMax / 100
        if hi < lo then lo, hi = hi, lo end
        local out = {}
        local report = { attempts = 0, tooClose = 0, rejected = 0, placed = 0, open = openMax, water = c.water }
        local maxAttempts = math.min(600000, math.max(2000, s.count * 60))
        local limit = math.max(1, math.floor(s.count))
        local sym = opts.symmetry
        if sym == nil then sym = GenSym.FromEditor() end
        while table.getn(out) < limit and report.attempts < maxAttempts do
            report.attempts = report.attempts + 1
            local x = margin + R.next() * span
            local z = margin + R.next() * span
            local a = Fields.Sample(accept, x, z)
            local roll = R.next()
            if a <= 0.001 or roll > a * s.fill then
                report.rejected = report.rejected + 1
            else
                local images = sym and GenSym.Points(sym, x, z) or { { x = x, z = z, kind = 'id', angle = 0 } }
                local ok = true
                for _, im in images do
                    if im.x < margin or im.z < margin or im.x > size - margin or im.z > size - margin or Near(im.x, im.z) then ok = false break end
                end
                -- the images must keep their distance from each other too
                if ok then
                    for i = 1, table.getn(images) do
                        for j = i + 1, table.getn(images) do
                            local dx, dz = images[i].x - images[j].x, images[i].z - images[j].z
                            if dx * dx + dz * dz < d * d then ok = false end
                        end
                    end
                end
                if not ok then
                    report.tooClose = report.tooClose + 1
                else
                    -- which blueprint, heading and scale: one draw for the whole group
                    local pick = R.next() * weightSum
                    local bp = entries[table.getn(entries)].bp
                    for _, e in entries do
                        pick = pick - math.max(0, e.weight or 1)
                        if pick <= 0 then bp = e.bp break end
                    end
                    local heading = s.randomHeading and (R.next() * PI2) or 0
                    local scale = lo + (hi - lo) * R.next()
                    for _, im in images do
                        Remember(im.x, im.z)
                        table.insert(out, { bp = bp, x = im.x, z = im.z, heading = Symmetry.Heading(heading, im), scale = scale })
                    end
                end
            end
        end
        report.placed = table.getn(out)
        return out, report
    end)
end

-- ---- applying ---------------------------------------------------------------------------------------------------------------------------------------

local function FindIndex(bp, x, z)
    for i = ed_prop_count(), 1, -1 do
        local b, px, py, pz = ed_prop_get(i)
        if b == bp and math.abs(px - x) < 0.01 and math.abs(pz - z) < 0.01 then return i end
    end
    return nil
end

local function NormalsOf(path)
    local n = string.gsub(path, '_[aA][lL][bB][eE][dD][oO]%.dds$', '_normals.dds')
    if n ~= path and DiskGetFileInfo(n) then return n end
    return nil
end

--- Places a plan of decals (an albedo decal and, with Settings.withNormals, its normals decal): one undo step. Returns the number of places decorated.
local function PlaceDecals(plan, label)
    local countBefore = ed_decal_count()
    local added = {}
    local cutoff = import('/lua/editor/decals.lua').Settings.cutoff
    for _, p in plan do
        local y = ed_terrain_get(math.floor(p.x + 0.5), math.floor(p.z + 0.5)) or 0
        local size = math.max(0.5, Settings.decalSize * p.scale)
        if Map.AddDecal(p.bp, 'albedo', p.x, y, p.z, p.heading, size, cutoff) then
            table.insert(added, { tex = p.bp, kind = 'albedo', x = p.x, y = y, z = p.z, heading = p.heading, size = size, cutoff = cutoff })
            local n = Settings.withNormals and NormalsOf(p.bp)
            if n and Map.AddDecal(n, 'normals', p.x, y, p.z, p.heading, size, cutoff) then
                table.insert(added, { tex = n, kind = 'normals', x = p.x, y = y, z = p.z, heading = p.heading, size = size, cutoff = cutoff })
            end
        end
    end
    local countAfter = ed_decal_count()
    if table.getn(added) == 0 then return 0 end
    local function FindIndex(tex, x, z)
        for i = ed_decal_count(), 1, -1 do
            local t0, t1, kind, px, py, pz = ed_decal_get(i)
            if t0 == tex and math.abs(px - x) < 0.01 and math.abs(pz - z) < 0.01 then return i end
        end
        return nil
    end
    History.Push({
        label = label or ('scatter ' .. table.getn(added) .. ' decals'),
        undo = function()
            if ed_decal_count() == countAfter then
                for i = countAfter, countBefore + 1, -1 do Map.RemoveDecal(i) end
            else
                for i = table.getn(added), 1, -1 do
                    local d = added[i]
                    local idx = FindIndex(d.tex, d.x, d.z)
                    if idx then Map.RemoveDecal(idx) end
                end
            end
        end,
        redo = function()
            for _, d in added do Map.AddDecal(d.tex, d.kind, d.x, d.y, d.z, d.heading, d.size, d.cutoff) end
        end,
    })
    return table.getn(plan)
end

--- Places a plan (props, or decals with Settings.mode = 'decals'). One undo step. Returns the number of props / decal spots placed.
function Place(plan, label, mode)
    if (mode or Settings.mode) == 'decals' then return PlaceDecals(plan, label) end
    local added = {}
    local countBefore = ed_prop_count()
    for _, p in plan do
        local y = ed_terrain_get(math.floor(p.x + 0.5), math.floor(p.z + 0.5)) or 0
        local index = Map.AddProp(p.bp, p.x, y, p.z, p.heading, p.scale)
        if index then table.insert(added, { bp = p.bp, x = p.x, y = y, z = p.z, heading = p.heading, scale = p.scale }) end
    end
    local countAfter = ed_prop_count()
    Props.Revision = Props.Revision + 1
    if table.getn(added) == 0 then return 0 end
    History.Push({
        label = label or ('scatter ' .. table.getn(added) .. ' props'),
        undo = function()
            if ed_prop_count() == countAfter then
                -- the usual case: the scattered props are the last ones, removed from the end
                for i = countAfter, countBefore + 1, -1 do Map.RemoveProp(i) end
            else
                for i = table.getn(added), 1, -1 do
                    local a = added[i]
                    local idx = FindIndex(a.bp, a.x, a.z)
                    if idx then Map.RemoveProp(idx) end
                end
            end
            Props.Revision = Props.Revision + 1
        end,
        redo = function()
            for _, a in added do Map.AddProp(a.bp, a.x, a.y, a.z, a.heading, a.scale) end
            Props.Revision = Props.Revision + 1
        end,
    })
    return table.getn(added)
end

function Apply()
    local plan, report = Plan()
    if not plan then return nil, report end
    local n = Place(plan)
    return n, report
end
