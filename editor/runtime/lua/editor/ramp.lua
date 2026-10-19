-- The ramp tool: drag from one point to another; the ground between them becomes a straight slope from the height under the start to the height under the
-- end, as wide as the brush (radius = half the width, the brush falloff shapes the sides). One undo step. Symmetry applies (the images of both points).
--
--   Press(wx, wz, event)       the tool's click (ui.lua tool.OnPress)
--   Apply(x0, z0, x1, z1)      builds the ramp (also for scripts)
--   Preview                    { x0, z0, x1, z1 } while dragging, or false
--
-- Lua 5.0 dialect.

local Dragger = import('/lua/maui/dragger.lua').Dragger
local Terrain = import('/lua/editor/terrain.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local Sim = import('/lua/editor/sim.lua')
local History = import('/lua/editor/history.lua')

Preview = false

local WORD = 128

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

--- One ramp from (x0, z0) to (x1, z1) with the heights found under the ends now. Returns the number of samples changed.
local function RampOne(x0, z0, x1, z1, h0, h1)
    local width = Terrain.Brush.radius
    local mx0 = math.floor(math.min(x0, x1) - width) - 1
    local mz0 = math.floor(math.min(z0, z1) - width) - 1
    local mx1 = math.ceil(math.max(x0, x1) + width) + 1
    local mz1 = math.ceil(math.max(z0, z1) + width) + 1
    local words, ax0, az0, ax1, az1 = ed_terrain_read_rect(mx0, mz0, mx1, mz1)
    if not words or ax1 < ax0 or az1 < az0 then return 0 end
    local w = ax1 - ax0 + 1
    local dx, dz = x1 - x0, z1 - z0
    local len2 = dx * dx + dz * dz
    if len2 < 0.01 then return 0 end
    local changed = 0
    for z = az0, az1 do
        for x = ax0, ax1 do
            local t = ((x - x0) * dx + (z - z0) * dz) / len2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local px, pz = x0 + dx * t, z0 + dz * t
            local d = math.sqrt((x - px) * (x - px) + (z - pz) * (z - pz))
            local weight = Terrain.BrushWeight(d, width, d, 0)
            if weight > 0 then
                local i = (z - az0) * w + (x - ax0) + 1
                local target = (h0 + (h1 - h0) * t) * WORD
                local value = math.floor(words[i] + (target - words[i]) * weight + 0.5)
                if value < 0 then value = 0 elseif value > 65535 then value = 65535 end
                if value ~= words[i] then
                    words[i] = value
                    changed = changed + 1
                end
            end
        end
    end
    if changed > 0 then
        ed_doc_height_write(ax0, az0, ax1, az1, words)
        Sim.Resnap(ax0, az0, ax1, az1)
    end
    return changed
end

function Apply(x0, z0, x1, z1)
    local a = Symmetry.Points(x0, z0)
    local b = Symmetry.Points(x1, z1)
    -- heights are taken before anything changes, so every image gets the same slope
    local heights = {}
    for i = 1, table.getn(a) do
        heights[i] = { Ground(a[i].x, a[i].z), Ground(b[i].x, b[i].z) }
    end
    local depth = Terrain.UndoDepth()
    ed_cmd_begin('Terrain ramp')
    local total = 0
    for i = 1, table.getn(a) do
        if b[i] then total = total + RampOne(a[i].x, a[i].z, b[i].x, b[i].z, heights[i][1], heights[i][2]) end
    end
    ed_cmd_end()
    if Terrain.UndoDepth() ~= depth then History.PushTerrain() end
    return total
end

--- Tool click: follows the pointer and builds the ramp on release.
function Press(wx, wz, event)
    Preview = { wx, wz, wx, wz }
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if mx then Preview = { wx, wz, mx, mz } end
    end
    local function Done(self)
        local p = Preview
        Preview = false
        if p and math.abs(p[1] - p[3]) + math.abs(p[2] - p[4]) > 2 then Apply(p[1], p[2], p[3], p[4]) end
        self:Destroy()
    end
    dragger.OnRelease = function(self, x, y) Done(self) end
    dragger.OnCancel = function(self) Done(self) end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end
