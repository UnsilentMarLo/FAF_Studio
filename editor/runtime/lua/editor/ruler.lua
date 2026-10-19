-- The ruler: drag in the world to measure a straight line over the terrain; hold Shift while pressing to continue the line from its last end
-- (a path with a total). The result is drawn on the ground with a label at the end point and shown in the status line.
--
--   Points      list of { x, z } of the measured path (empty = nothing measured)
--   Press(wx, wz, event)       the ruler tool's click handler (ui.lua tool.OnPress)
--   Clear()
--   Text()      the measurement as text, or false
--
-- A world unit is 1 / 51.2 of a 5 km map width per 256 units, about 19.5 m; the text gives units, which is what the build grid and every blueprint use.
-- Lua 5.0 dialect.

local Dragger = import('/lua/maui/dragger.lua').Dragger

Points = {}
local dragging = false

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

function Clear()
    Points = {}
    dragging = false
end

--- Lengths of the path: horizontal, along the ground (3D), the height change start to end, and the slope of the last segment in percent.
function Measure()
    local n = table.getn(Points)
    if n < 2 then return nil end
    local flat, ground = 0, 0
    for i = 2, n do
        local a, b = Points[i - 1], Points[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        flat = flat + l
        -- walk the segment in steps of one unit so the ground length follows the terrain
        local steps = math.max(1, math.ceil(l))
        local px, pz, py = a.x, a.z, Ground(a.x, a.z)
        for s = 1, steps do
            local f = s / steps
            local x, z = a.x + dx * f, a.z + dz * f
            local y = Ground(x, z)
            local ddx, ddz, ddy = x - px, z - pz, y - py
            ground = ground + math.sqrt(ddx * ddx + ddz * ddz + ddy * ddy)
            px, pz, py = x, z, y
        end
    end
    local first, last = Points[1], Points[n]
    local dh = Ground(last.x, last.z) - Ground(first.x, first.z)
    local lastSeg = Points[n - 1]
    local ldx, ldz = last.x - lastSeg.x, last.z - lastSeg.z
    local ll = math.sqrt(ldx * ldx + ldz * ldz)
    local slope = ll > 0.01 and ((Ground(last.x, last.z) - Ground(lastSeg.x, lastSeg.z)) / ll * 100) or 0
    return { flat = flat, ground = ground, dh = dh, slope = slope, segments = n - 1 }
end

function Text()
    local m = Measure()
    if not m then return false end
    local text = string.format('%.1f units', m.flat)
    if m.segments > 1 then text = text .. string.format(' (%d segments)', m.segments) end
    return text .. string.format('   ground %.1f   dh %+.1f   slope %.0f%%', m.ground, m.dh, math.abs(m.slope))
end

--- Tool click: starts a path (or continues one with Shift) and follows the pointer until the button is released.
function Press(wx, wz, event)
    local extend = IsKeyDown and IsKeyDown('Shift') and table.getn(Points) >= 2
    if not extend then
        Points = { { x = wx, z = wz } }
    end
    table.insert(Points, { x = wx, z = wz })
    local idx = table.getn(Points)
    dragging = true
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if mx then Points[idx] = { x = mx, z = mz } end
    end
    local function Done(self)
        dragging = false
        if table.getn(Points) >= 2 then
            local a, b = Points[idx - 1], Points[idx]
            if a and b and math.abs(a.x - b.x) + math.abs(a.z - b.z) < 0.2 then table.remove(Points, idx) end
        end
        self:Destroy()
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end
