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

    table.insert(out, failed == 0 and 'unitfit: all checks passed' or ('unitfit: ' .. failed .. ' FAILED'))
    return table.concat(out, '\n')
end
