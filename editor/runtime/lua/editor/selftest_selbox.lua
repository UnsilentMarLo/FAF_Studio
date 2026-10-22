-- Self test of the camera-aligned selection box (tools.lua BoxHas / BoxHasRect). Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_selbox.lua').Run()
-- Returns text that starts with PASS or FAIL. Pure: a fake world view with a simple perspective stands in for view:Project (eye at (0, 50, 0) looking along +z, 500 pixels of focal
-- length, a 1000 x 800 view whose origin is (100, 50) in the window); no map is needed.
--
-- Lua 5.0 dialect.

local Tools = import('/lua/editor/tools.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

-- like the engine's Project: a point behind the camera is NOT refused, it divides by a negative w and lands mirrored on the screen
local fake = {
    Left = function() return 100 end,
    Top = function() return 50 end,
    Project = function(self, v)
        local w = v[3]
        if w == 0 then w = 0.0001 end
        return { x = 500 + 500 * v[1] / w, y = 400 - 500 * (v[2] - 50) / w }
    end,
}
local CAM = { ex = 0, ey = 50, ez = 0, lx = 0, ly = 0, lz = 1 }

function Run()
    out, failed = {}, 0

    -- the screen rectangle: window x 400 .. 800, y 250 .. 650 (view x 300 .. 700, y 200 .. 600)
    local box = { -5, 90, 5, 110, screen = { 400, 250, 800, 650 }, view = fake, cam = CAM }

    Check(Tools.BoxHas(box, 0, 100, 50), 'a point straight ahead (the centre of the view) is inside')
    Check(Tools.BoxHas(box, 10, 100, 50), 'a point a little to the right (x 550) is inside')
    Check(not Tools.BoxHas(box, 100, 100, 50), 'a point far to the right (x 1000) is outside')
    Check(not Tools.BoxHas(box, -100, 100, 50), 'a point far to the left is outside')
    Check(Tools.BoxHas(box, 0, 100, 40), 'a point a little below the eye line is inside')
    Check(not Tools.BoxHas(box, 0, 100, 0), 'a point far below (y 650 in the view) is outside')
    Check(Tools.BoxHas(box, 0, 1000, 50), 'a far point straight ahead is inside (perspective: far things crowd to the centre)')
    Check(Tools.BoxHas(box, 100, 1000, 50), 'a far point 100 to the right is inside, the same offset near the camera was not')

    -- behind the camera: Project mirrors the point onto the screen; without the camera frame it would count as inside
    local p = fake:Project(Vector(0, 50, -100))
    Check(p.x == 500 and p.y == 400, 'the fake projection mirrors a point behind the camera onto the centre, as the engine does')
    Check(not Tools.BoxHas(box, 0, -100, 50), 'a point straight behind the camera is never inside')
    Check(not Tools.BoxHas(box, 10, -100, 50), 'a point behind and to the side is never inside')
    Check(not Tools.BoxHas(box, 0, 0.2, 50), 'a point closer than the near plane is not inside')
    local noCam = { -5, 90, 5, 110, screen = { 400, 250, 800, 650 }, view = fake }
    Check(Tools.BoxHas(noCam, 0, 100, 50), 'without a camera frame the projection alone decides (inside)')

    -- the cached origin of the view is used when the box has one
    local shifted = { -5, 90, 5, 110, screen = { 400, 250, 800, 650 }, view = fake, cam = CAM, ox = 0, oy = 0 }
    Check(not Tools.BoxHas(box, 50, 100, 50), 'a point at view x 750 is outside with the view origin at 100 (window x 850)')
    Check(Tools.BoxHas(shifted, 50, 100, 50), 'the same point is inside when box.ox / box.oy say the origin is 0 (window x 750)')

    -- a rectangle (area) goes by its centre (the ground height under it is read from the open map, if there is one)
    local ok, res = pcall(Tools.BoxHasRect, box, 995, 90, 1005, 110)
    if ok then
        Check(res == false, 'an area whose centre is far to the right is outside')
    else
        table.insert(out, '  skip BoxHasRect on the screen box needs the terrain natives: ' .. tostring(res))
    end

    -- the old world box
    local world = { 0, 0, 10, 10 }
    Check(Tools.BoxHas(world, 5, 5), 'world box: a point inside')
    Check(not Tools.BoxHas(world, 11, 5), 'world box: a point outside in x')
    Check(not Tools.BoxHas(world, 5, -1), 'world box: a point outside in z')
    Check(Tools.BoxHas({ 10, 10, 0, 0 }, 5, 5), 'world box: the corners may come in either order')
    Check(Tools.BoxHas(world, 0, 10) and Tools.BoxHas(world, 10, 0), 'world box: the border counts')
    Check(Tools.BoxHasRect(world, 2, 2, 8, 8), 'world box: an area whose centre is inside is in')
    Check(not Tools.BoxHasRect(world, 8, 8, 30, 30), 'world box: an area whose centre is outside is out, though it overlaps')
    Check(Tools.BoxHas({ 0, 0, 10, 10, screen = { 0, 0, 1, 1 } }, 5, 5), 'a box with a screen rectangle but no view falls back to the world test')

    -- the setting
    local before = Tools.SelectBoxFollowsCamera
    Tools.SetSelectBoxFollowsCamera(false)
    Check(Tools.SelectBoxFollowsCamera == false, 'the setting can be turned off')
    Tools.SetSelectBoxFollowsCamera(before)
    Check(Tools.SelectBoxFollowsCamera == before, 'and back to what it was')

    table.insert(out, 1, (failed == 0 and 'PASS' or 'FAIL') .. ' selbox: ' .. failed .. ' failed')
    return table.concat(out, '\n')
end
