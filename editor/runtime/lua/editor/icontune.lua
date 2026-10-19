-- Tuning of the icon recipe per kind of unit (docs/projects/MOD_UNIT_EDITOR_DESIGN.md section 9). Every function RUNS IN A THREAD (icongen captures wait for frames) and in the foreground window.
--
--   Sets                      vanilla units per category (land, air, naval, structure), every faction, tech 1 to 3: the measuring sets
--   Sweep(category, grid, path [, ids])     renders the units of the category with every recipe of `grid` (a list of recipe overrides, `noCategory` is set), appends one line per recipe to the file `path`:
--                             category | recipe | n | iou | color | tint | coarse   (means over the units; icongen.Compare)
--   Report(path [, sets])     renders every unit of `sets` (default Sets; Holdout is the other one) with the recipe as it is (category overrides included) and writes the per unit and the mean numbers
--   Grid(headings, pitches, fovs, fills)    the product of the lists as a grid
--
-- Usage (from the edcmd channel): `ForkThread(function() import('/lua/editor/icontune.lua').Sweep('air', import('/lua/editor/icontune.lua').Grid({3.4, 3.7, 4.0}, {0.55}, {22}, {0.9}), '../icotune_air.txt') end)`.
--
-- Lua 5.0 dialect.

local Gen = import('/lua/editor/icongen.lua')

Sets = {
    land = { 'uel0106', 'uel0201', 'uel0202', 'uel0303', 'url0106', 'url0107', 'url0202', 'url0303', 'ual0106', 'ual0201', 'ual0202', 'ual0303', 'xsl0101', 'xsl0201', 'xsl0202', 'xsl0303' },
    air = { 'uea0102', 'uea0103', 'uea0203', 'uea0303', 'ura0102', 'ura0103', 'ura0203', 'ura0303', 'uaa0102', 'uaa0103', 'uaa0203', 'uaa0303', 'xsa0102', 'xsa0103', 'xsa0203', 'xsa0303' },
    naval = { 'ues0103', 'ues0201', 'ues0302', 'urs0103', 'urs0201', 'urs0302', 'uas0103', 'uas0201', 'uas0302', 'xss0103', 'xss0201', 'xss0302' },
    structure = { 'ueb1101', 'ueb2101', 'ueb2301', 'ueb0101', 'urb1101', 'urb2101', 'urb2301', 'urb0101', 'uab1101', 'uab2101', 'uab2301', 'uab0101', 'xsb1101', 'xsb2101', 'xsb2301', 'xsb0101' },
}

-- Units that are in none of `Sets`: the curves are fitted on `Sets`, `Holdout` shows what they do for units they have not seen.
Holdout = {
    land = { 'uel0203', 'uel0205', 'url0203', 'url0204', 'ual0203', 'ual0204', 'xsl0203', 'xsl0204' },
    air = { 'uea0101', 'uea0202', 'ura0101', 'ura0202', 'uaa0101', 'uaa0202', 'xsa0101', 'xsa0202' },
    naval = { 'ues0202', 'urs0202', 'uas0202', 'xss0202' },
    structure = { 'ueb1102', 'ueb1103', 'ueb2204', 'urb1102', 'urb1103', 'urb2204', 'uab1102', 'uab1103', 'uab2204', 'xsb1102', 'xsb1103', 'xsb2204' },
}

--- The product of the lists as a list of recipe overrides.
function Grid(headings, pitches, fovs, fills, halfMins)
    local list = {}
    for _, h in headings or {} do
        for _, p in pitches or { false } do
            for _, f in fovs or { false } do
                for _, fl in fills or { false } do
                    for _, hm in halfMins or { false } do
                        local r = {}
                        if h then r.heading = h end
                        if p then r.pitch = p end
                        if f then r.fov = f end
                        if fl then r.fill = fl end
                        if hm then r.halfMin = hm end
                        table.insert(list, r)
                    end
                end
            end
        end
    end
    return list
end

local function Describe(r)
    local keys = {}
    for k, _ in r do table.insert(keys, k) end
    table.sort(keys)
    local parts = {}
    for _, k in keys do
        if k ~= 'noCategory' then table.insert(parts, k .. '=' .. tostring(r[k])) end
    end
    return table.concat(parts, ' ')
end

local function Append(path, line)
    local old = ed_read_file(path) or ''
    ed_write_file(path, old .. line .. '\n')
end

local function Existing(ids)
    local list = {}
    for _, id in ids do
        if __blueprints and __blueprints[id] and Gen.Shipped(id) then table.insert(list, id) end
    end
    return list
end

function Sweep(category, grid, path, ids)
    ids = Existing(ids or Sets[category] or {})
    for _, override in grid do
        local recipe = { noCategory = true }
        for k, v in override do recipe[k] = v end
        local e = Gen.Evaluate(ids, recipe)
        Append(path, string.format('%s | %s | n %d | iou %.4f | color %.2f | tint %.2f | coarse %.2f', category, Describe(override), e.n, e.iou, e.color, e.tint, e.coarse))
    end
    Append(path, 'done ' .. category)
end

function Report(path, sets)
    sets = sets or Sets
    local lines = {}
    local totals = {}
    for _, category in { 'land', 'air', 'naval', 'structure' } do
        local list = Existing(sets[category] or {})
        local e = Gen.Evaluate(list)
        table.insert(lines, string.format('%s: n %d  iou %.3f  color %.1f  tint %.1f  coarse %.1f  failed %d', category, e.n, e.iou, e.color, e.tint, e.coarse, 0))
        local names = {}
        for id, _ in e.per do table.insert(names, id) end
        table.sort(names)
        for _, id in names do
            local c = e.per[id]
            table.insert(lines, string.format('  %s  iou %.2f  color %.0f  tint %.0f  coarse %.0f', id, c.iou, c.color, c.tint, c.coarse))
        end
        for id, why in e.failed do table.insert(lines, '  ' .. id .. ' FAILED ' .. tostring(why)) end
        totals[category] = e
    end
    local n, iou, color, tint, coarse = 0, 0, 0, 0, 0
    for _, e in totals do
        n = n + e.n
        iou = iou + e.iou * e.n
        color = color + e.color * e.n
        tint = tint + e.tint * e.n
        coarse = coarse + e.coarse * e.n
    end
    table.insert(lines, string.format('all: n %d  iou %.3f  color %.1f  tint %.1f  coarse %.1f', n, iou / math.max(1, n), color / math.max(1, n), tint / math.max(1, n), coarse / math.max(1, n)))
    ed_write_file(path, table.concat(lines, '\n') .. '\n')
    return n
end
