-- Self test of unitfit.lua (footprints, spacing, build grid, the map-edge rule). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_unitfit.lua').Run()
-- Pure geometry: it needs no map, the blueprints are made up here.
--
-- Lua 5.0 dialect.

local Fit = import('/lua/editor/unitfit.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Near(a, b) return math.abs(a - b) < 0.001 end

-- ---- the placement rules on synthetic terrain (ctx.height stands in for ed_terrain_get): flat ground must be fine for every kind of unit, ramps and water must be refused with the right reason

local function Bp(foot, phys, extra)
    local bp = { Footprint = { SizeX = foot, SizeZ = foot }, Physics = phys }
    for k, v in extra or {} do bp[k] = v end
    return bp
end

local function Ctx(height, water, play)
    return { rects = {}, grid = {}, waterOn = water ~= nil, waterElev = water or 0, w = 256, h = 256, play = play or { 0, 0, 256, 256 }, height = height }
end

function Rules()
    local fac = Bp(5, { MotionType = 'RULEUMT_None', SkirtSizeX = 8, SkirtSizeZ = 8, SkirtOffsetX = -1.5, SkirtOffsetZ = -1.5, FlattenSkirt = true, MaxGroundVariation = 1.1,
        BuildOnLayerCaps = { LAYER_Land = true } })
    local mex = Bp(1, { MotionType = 'RULEUMT_None', SkirtSizeX = 2, SkirtSizeZ = 2, SkirtOffsetX = -0.5, SkirtOffsetZ = -0.5, FlattenSkirt = false, MaxGroundVariation = 512,
        BuildOnLayerCaps = { LAYER_Land = true } })
    local wall = Bp(1, { MotionType = 'RULEUMT_None', SkirtSizeX = 1, SkirtSizeZ = 1, FlattenSkirt = true, MaxGroundVariation = 1.2, BuildOnLayerCaps = { LAYER_Land = true } })
    local plain = Bp(3, { MotionType = 'RULEUMT_None', SkirtSizeX = 3, SkirtSizeZ = 3, MaxGroundVariation = 1.0 })       -- not flattened, no layer caps listed: the area rule, land
    local navy = Bp(5, { MotionType = 'RULEUMT_None', SkirtSizeX = 8, SkirtSizeZ = 8, SkirtOffsetX = -1.5, SkirtOffsetZ = -1.5, FlattenSkirt = true, MaxGroundVariation = 1.1,
        BuildOnLayerCaps = { LAYER_Water = true } })
    local tank = Bp(1, { MotionType = 'RULEUMT_Land' }, { SizeX = 1.2, SizeZ = 2 })
    local eng = Bp(1, { MotionType = 'RULEUMT_Biped' })
    local air = Bp(1, { MotionType = 'RULEUMT_Air' })
    local hover = Bp(3, { MotionType = 'RULEUMT_Hover' })
    local amph = Bp(2, { MotionType = 'RULEUMT_Amphibious' })
    local boat = Bp(3, { MotionType = 'RULEUMT_Water' })
    local sub = Bp(3, { MotionType = 'RULEUMT_SurfacingSub' })
    local nomt = Bp(1, {})                                                                                                  -- no MotionType: nothing to check against the ground
    local all = { { 'land factory', fac }, { 'extractor', mex }, { 'wall', wall }, { 'plain structure', plain }, { 'tank', tank }, { 'engineer', eng }, { 'air unit', air },
        { 'hover unit', hover }, { 'amphibious unit', amph }, { 'no motion type', nomt } }

    local function Flat(h) return function() return h end end
    local x, z = 100.5, 100.5

    -- flat ground, no water: every land and air unit fits, from the new map's height (25) to a hill and a valley
    for _, h in { 25, 25.4, 0, 3, 200.75 } do
        local ctx = Ctx(Flat(h), nil)
        local bad = ''
        for _, e in all do
            local ok, why = Fit.Check(e[2], x, z, 0, ctx)
            if not ok then bad = bad .. e[1] .. ' (' .. tostring(why) .. ') ' end
        end
        Check(bad == '', 'flat ground at ' .. h .. ', no water: everything fits ' .. bad)
    end
    -- the blueprints the engine loaded hold BuildOnLayerCaps as a string: a layer name, or a number with one bit per layer (1 land, 2 seabed, 4 sub, 8 water)
    local function Strs(caps) return Bp(5, { MotionType = 'RULEUMT_None', SkirtSizeX = 8, SkirtSizeZ = 8, FlattenSkirt = true, MaxGroundVariation = 1.1, BuildOnLayerCaps = caps }) end
    Check(Fit.Check(Strs('Land'), x, z, 0, Ctx(Flat(25), nil)), 'caps "Land" (the loaded form): a structure fits on dry ground')
    Check(Fit.Check(Strs('9'), x, z, 0, Ctx(Flat(25), nil)), 'caps "9" (land and water): fits on dry ground')
    Check(Fit.Check(Strs(9), x, z, 0, Ctx(Flat(25), nil)), 'caps 9 as a number: fits on dry ground')
    Check(not Fit.Check(Strs('Water'), x, z, 0, Ctx(Flat(25), nil)), 'caps "Water": does not fit on dry ground')
    Check(Fit.Check(Strs('Water'), x, z, 0, Ctx(Flat(0), 20)), 'caps "Water": fits in deep water')
    Check(not Fit.Check(Strs('Land'), x, z, 0, Ctx(Flat(0), 20)), 'caps "Land": does not fit under water')
    Check(Fit.Check(Strs('8'), x, z, 0, Ctx(Flat(0), 20)), 'caps "8" (water): fits in deep water')
    local real = rawget(_G, '__blueprints') and (__blueprints['uab1101'] or __blueprints['ueb1101'])
    if real then Check(Fit.Check(real, x, z, 0, Ctx(Flat(25), nil)), 'a loaded extractor fits on flat dry ground') end
    local ok, why, kind = Fit.Check(navy, x, z, 0, Ctx(Flat(25), nil))
    Check(not ok and kind == 'water', 'a naval factory on dry ground: ' .. tostring(why))
    ok, why, kind = Fit.Check(boat, x, z, 0, Ctx(Flat(25), nil))
    Check(not ok and kind == 'water', 'a ship on a map without water: ' .. tostring(why))

    -- a new map: ground 25, water switched on at the default elevation 25: the ground is not under water
    local ctx = Ctx(Flat(25), 25)
    local bad = ''
    for _, e in all do
        if not Fit.Check(e[2], x, z, 0, ctx) then bad = bad .. e[1] .. ' ' end
    end
    Check(bad == '', 'ground exactly at the water level counts as dry: ' .. bad)

    -- water above the ground
    ctx = Ctx(Flat(25), 26)
    ok, why, kind = Fit.Check(fac, x, z, 0, ctx)
    Check(not ok and kind == 'water' and string.find(why, 'under water', 1, true), 'a land factory under 1 unit of water: ' .. tostring(why))
    ok, why, kind = Fit.Check(tank, x, z, 0, ctx)
    Check(not ok and kind == 'water', 'a tank in 1 unit of water: ' .. tostring(why))
    Check(Fit.Check(tank, x, z, 0, Ctx(Flat(25), 25.04)), 'a tank may stand in 0.04 of water (the footprint allows 0.05)')
    Check(Fit.Check(air, x, z, 0, ctx) and Fit.Check(hover, x, z, 0, ctx) and Fit.Check(amph, x, z, 0, ctx), 'air, hover and amphibious units do not mind the water')
    Check(Fit.Check(boat, x, z, 0, ctx) and Fit.Check(navy, x, z, 0, ctx), 'ships and naval factories fit in 1 unit of water')
    ok, why, kind = Fit.Check(boat, x, z, 0, Ctx(Flat(25), 25.1))
    Check(not ok and kind == 'water', 'a ship in 0.1 of water is stranded: ' .. tostring(why))
    ok = Fit.Check(sub, x, z, 0, Ctx(Flat(25), 26))
    Check(not ok, 'a surfacing sub in 1 unit of water is refused')
    -- the ground dips under the water on one side only
    local half = function(px) return px < 100 and 20 or 30 end
    ok, why, kind = Fit.Check(fac, 100.5, 100.5, 0, Ctx(half, 25))
    Check(not ok, 'a factory half in the water is refused: ' .. tostring(why))

    -- a ramp: the rise per cell decides
    -- (a flattened structure is judged against ceil(the height of the last sample of the ring round its skirt, here x = 105): the ramps pass through whole heights there)
    local ramp = function(r) return function(px) return 25 + (px - 105) * r end end
    ok, why, kind = Fit.Check(fac, x, z, 0, Ctx(ramp(0.05), nil))
    Check(ok, 'a land factory on a gentle ramp (0.05 per cell)')
    ok, why, kind = Fit.Check(fac, x, z, 0, Ctx(ramp(0.5), nil))
    Check(not ok and kind == 'slope' and string.find(why, 'uneven', 1, true), 'a land factory on a ramp of 0.5 per cell: ' .. tostring(why))
    Check(Fit.Check(mex, x, z, 0, Ctx(ramp(0.5), nil)), 'an extractor accepts a ramp of 0.5 per cell (MaxGroundVariation 512)')
    Check(Fit.Check(tank, x, z, 0, Ctx(ramp(0.5), nil)), 'a tank stands on a ramp of 0.5 per cell')
    ok, why, kind = Fit.Check(tank, x, z, 0, Ctx(ramp(1), nil))
    Check(not ok and kind == 'slope' and string.find(why, 'too steep', 1, true), 'a tank on a ramp of 1 per cell: ' .. tostring(why))
    ok, why, kind = Fit.Check(plain, x, z, 0, Ctx(ramp(0.4), nil))
    Check(not ok and kind == 'slope', 'a plain structure over a rise of 1.2 across its skirt (limit 1.0): ' .. tostring(why))
    Check(Fit.Check(plain, x, z, 0, Ctx(ramp(0.2), nil)), 'a plain structure over a rise of 0.6 across its skirt')
    Check(Fit.Check(air, x, z, 0, Ctx(ramp(3), nil)), 'an air unit does not care about the ground')

    -- flattened structures look at the ring round the skirt only: a hole inside the skirt is levelled away, for a plain structure it is not
    local hole = function(px, pz) if px == 100 and pz == 100 then return 20 end return 25 end
    Check(Fit.Check(fac, x, z, 0, Ctx(hole, nil)), 'a hole inside the skirt of a land factory is levelled by the game')
    ok, why, kind = Fit.Check(plain, 100.5, 100.5, 0, Ctx(hole, nil))
    Check(not ok and kind == 'slope', 'the same hole under a structure that is not levelled: ' .. tostring(why))

    -- the playable area and the map edge
    ctx = Ctx(Flat(25), nil, { 50, 50, 200, 200 })
    Check(Fit.Check(fac, 100.5, 100.5, 0, ctx), 'inside the playable area')
    ok, why, kind = Fit.Check(fac, 30.5, 100.5, 0, ctx)
    Check(not ok and kind == 'area', 'outside the playable area: ' .. tostring(why))
    ok, why, kind = Fit.Check(fac, 2.5, 100.5, 0, Ctx(Flat(25), nil))
    Check(not ok and kind == 'map', 'a land factory whose skirt reaches over the map edge: ' .. tostring(why))
    Check(Fit.Check(tank, 0.5, 0.5, 0, Ctx(Flat(25), nil)), 'a tank in the corner of the map')

    -- other structures
    ctx = Ctx(Flat(25), nil)
    local foot, skirt = Fit.Rects(fac, 100.5, 100.5, 0)
    local r = { skirt, foot }
    table.insert(ctx.rects, r)
    ctx.grid[math.floor(skirt[1] / 32) * 4096 + math.floor(skirt[2] / 32)] = { r }
    ok, why, kind = Fit.Check(fac, 104.5, 100.5, 0, ctx)
    Check(not ok and kind == 'overlap', 'two factories 4 apart overlap: ' .. tostring(why))
    Check(Fit.Check(fac, 130.5, 100.5, 0, Ctx(Flat(25), nil)), 'a factory with nothing near it')
    ok, why, kind = Fit.Check(tank, 100.5, 100.5, 0, ctx)
    Check(not ok and kind == 'overlap', 'a tank inside a factory: ' .. tostring(why))
end

function Run()
    out, failed = {}, 0
    local mex = { Footprint = { SizeX = 1, SizeZ = 1 }, Physics = { MotionType = 'RULEUMT_None', SkirtSizeX = 2, SkirtSizeZ = 2, SkirtOffsetX = -0.5, SkirtOffsetZ = -0.5 } }
    local fac = { Footprint = { SizeX = 5, SizeZ = 5 }, Physics = { MotionType = 'RULEUMT_None', SkirtSizeX = 8, SkirtSizeZ = 8, SkirtOffsetX = -1.5, SkirtOffsetZ = -1.5 } }
    local wide = { Footprint = { SizeX = 3, SizeZ = 5 }, Physics = { MotionType = 'RULEUMT_None', SkirtSizeX = 3, SkirtSizeZ = 5 } }
    local tank = { SizeX = 1.2, SizeZ = 2, Footprint = { SizeX = 1, SizeZ = 1 }, Physics = { MotionType = 'RULEUMT_Land' } }

    local foot, skirt = Fit.Rects(mex, 10.5, 10.5, 0)
    Check(Near(foot[1], 10) and Near(foot[3], 11) and Near(skirt[1], 9.5) and Near(skirt[3], 11.5), 'footprint 1 x 1 and skirt 2 x 2 around a cell centre')
    foot = Fit.Rects(wide, 10.5, 10.5, 0)
    Check(Near(foot[3] - foot[1], 3) and Near(foot[4] - foot[2], 5), 'a 3 x 5 footprint is 3 wide on x')
    foot = Fit.Rects(wide, 10.5, 10.5, math.rad(90))
    Check(Near(foot[3] - foot[1], 5) and Near(foot[4] - foot[2], 3), 'turned a quarter it is 5 wide on x')

    local sx, sz = Fit.Spacing(fac)
    Check(sx == 8 and sz == 8, 'spacing of a factory is its 8 x 8 skirt')
    sx, sz = Fit.Spacing(wide)
    Check(sx == 3 and sz == 5, 'spacing of the 3 x 5 structure is 3 by 5')
    sx, sz = Fit.Spacing(tank)
    Check(sx == 3 and sz == 3, 'spacing of a mobile unit is its collision box plus a margin, in whole cells')

    local x, z = Fit.Snap(mex, 10.2, 10.9, 0)
    Check(Near(x, 10.5) and Near(z, 10.5), 'a 1 x 1 structure snaps to a cell centre')
    x, z = Fit.Snap({ Footprint = { SizeX = 2, SizeZ = 2 }, Physics = { MotionType = 'RULEUMT_None' } }, 10.2, 10.9, 0)
    Check(Near(x, 10) and Near(z, 11), 'a 2 x 2 structure snaps to a cell corner')
    x, z = Fit.Snap(wide, 10.2, 10.9, 0)
    Check(Near(x, 10.5) and Near(z, 10.5), 'a 3 x 5 structure snaps to centres on both axes')
    x, z = Fit.Snap(tank, 10.2, 10.9, 0)
    Check(Near(x, 10) and Near(z, 11), 'a mobile unit snaps to half a cell')

    local ctx = { rects = {}, grid = {}, waterOn = false, waterElev = 0, w = 256, h = 256, play = { 0, 0, 256, 256 } }
    local ok, why = Fit.Check(mex, -3, 10, 0, ctx)
    Check(not ok and why == 'outside the map', 'off the map is refused with a reason')
    ctx.play = { 50, 50, 200, 200 }
    ok, why = Fit.Check(mex, 10.5, 10.5, 0, ctx)
    Check(not ok and why == 'outside the playable area', 'outside the playable area is refused with a reason')

    Rules()

    table.insert(out, failed == 0 and 'unitfit: all checks passed' or ('unitfit: ' .. failed .. ' FAILED'))
    return table.concat(out, '\n')
end
