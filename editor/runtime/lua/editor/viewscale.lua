-- World size of one screen pixel for everything that is drawn or picked at a constant size on screen (gizmo, area handles, selection rings, path handles,
-- pick tolerances). Measured at the CENTRE of the world view: it follows the camera (distance, zoom) and never the pointer, so nothing grows or shrinks
-- while the mouse moves over the perspective ground.
--
--   PixelSize()      world units per screen pixel at the view centre (1 when there is no view)

function PixelSize()
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return 1 end
    local mx, my = view.Left() + view.Width() / 2, view.Top() + view.Height() / 2
    local a = UnProject(view, Vector2(mx, my))
    local b = UnProject(view, Vector2(mx + 10, my))
    if not a or not b then return 1 end
    local dx, dz = b[1] - a[1], b[3] - a[3]
    return math.max(0.01, math.sqrt(dx * dx + dz * dz) / 10)
end
