-- The view of a Camera Info marker, drawn in the world while the marker is selected: a line frame of the field of view coming from the camera.
--
--   Update(ui, view)       called every frame by overlay.lua while editing; draws (and removes) the frames of the selected Camera Info markers. Redraws a frame only when its
--                          marker (position, heading / pitch, zoom), the window's aspect ratio, the camera's maximum zoom or the terrain changed.
--   Forget()               drops the bookkeeping (overlay.Clear: the engine's overlay was emptied, another map, play mode)
--
-- Pure geometry (self test: selftest_camframe.lua), all angles in radians, world units:
--   FovFor(zoom, maxZoom)                                   field of view of the engine's camera at a zoom
--   Frustum(fx, fy, fz, heading, pitch, zoom, fov, aspect)  -> { eye = { x, y, z }, dist, fwd, right, up, halfW, halfH, rays = { 4 unit directions } }
--   RayGround(ex, ey, ez, dx, dy, dz, ground, tmax, steps)  -> x, y, z, t, kind ('ground' | 'edge') of the first terrain hit along a ray, or nil
--   Corners(frustum, ground, tmax, steps)                   -> 4 points { x, y, z, kind = 'ground' | 'edge' | 'far' } where the corner rays meet the ground
--
-- The camera model (engine: CameraImpl::UpdateCoords, the ray at CameraImpl.cpp ~2127, GeomCamera3 BuildD3DProjectionMatrixFov, all read from the decompiled sources):
--   * a marker stores the FOCUS point (position), orientation = { heading, pitch, 0 } and `zoom` = the camera's TARGET zoom (what Camera:SaveSettings().Zoom / MoveTo take), which is
--     the world width of the view at the focus point, not the eye distance. Eye distance = zoom / tan(fov / 2) / 2.
--   * the look direction is (sin(heading) cos(pitch), -sin(pitch), cos(heading) cos(pitch)) (heading 0 looks along +z, pi along -z = north; pitch 90 degrees looks straight down);
--     eye = focus - look * distance.
--   * the projection takes `fov` for the LONGER side of the viewport: with aspect = width / height > 1, half width = tan(fov/2), half height = half width / aspect.
--   * fov is interpolated over the log of the zoom between cam_NearFOV (65 degrees, at cam_NearZoom 5) and cam_FarFOV (60 degrees, at the camera's maximum zoom). Those three are the
--     engine's defaults (RuntimeTuningGlobals.cpp); a game that changes them with console variables is not followed.
--   * the viewport's aspect is the one ed_camera_info reports for the world camera (the editor's window); the game's own viewport of a player is another shape.
-- A marker without a zoom (0) takes the editor camera's current zoom, heading and pitch where its own are missing, as Look through does (markerprops.lua LookThrough).
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local MeshView = import('/lua/editor/meshview.lua')
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')

NEAR_ZOOM = 5
NEAR_FOV = 65
FAR_FOV = 60
local DEG = 0.017453292519943295

local COLOR_EDGE = 'B0FFE060'
local COLOR_OUTLINE = 'FFFFE060'
local COLOR_CENTRE = '60FFE060'
local LIFT = 0.15
local SUFFIXES = { 'e1', 'e2', 'e3', 'e4', 'q', 'c' }
local MAX_FRAMES = 6

-- ---- geometry ---------------------------------------------------------------------------------------------------------------------------

--- The camera's field of view (radians) at `zoom`, for a camera whose largest zoom is `maxZoom`.
function FovFor(zoom, maxZoom)
    local z = zoom
    if not maxZoom or maxZoom <= NEAR_ZOOM then return FAR_FOV * DEG end
    if z < NEAR_ZOOM then z = NEAR_ZOOM end
    if z > maxZoom then z = maxZoom end
    local f = (math.log(z) - math.log(NEAR_ZOOM)) / (math.log(maxZoom) - math.log(NEAR_ZOOM))
    return (f * (FAR_FOV - NEAR_FOV) + NEAR_FOV) * DEG
end

local function Normalize(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-12 then return 0, 1, 0 end
    return x / l, y / l, z / l
end

--- The frustum of a camera looking at (fx, fy, fz): eye, axes, half extents at distance 1 and the four corner rays (unit vectors) in the order top left, top right, bottom right,
--- bottom left as seen on the screen.
function Frustum(fx, fy, fz, heading, pitch, zoom, fov, aspect)
    local sh, ch, sp, cp = math.sin(heading), math.cos(heading), math.sin(pitch), math.cos(pitch)
    local fwd = { sh * cp, -sp, ch * cp }
    local right = { -ch, 0, sh }
    local up = { sh * sp, cp, ch * sp }
    local t = math.tan(fov * 0.5)
    local halfW, halfH
    if aspect >= 1 then
        halfW = t
        halfH = t / aspect
    else
        halfH = t
        halfW = t * aspect
    end
    local dist = zoom / t / 2
    local fr = { eye = { fx - fwd[1] * dist, fy - fwd[2] * dist, fz - fwd[3] * dist }, focus = { fx, fy, fz }, dist = dist, fwd = fwd, right = right, up = up, halfW = halfW, halfH = halfH, rays = {} }
    local signs = { { -1, 1 }, { 1, 1 }, { 1, -1 }, { -1, -1 } }
    for i = 1, 4 do
        local sx, sy = signs[i][1], signs[i][2]
        local dx = fwd[1] + sx * halfW * right[1] + sy * halfH * up[1]
        local dy = fwd[2] + sx * halfW * right[2] + sy * halfH * up[2]
        local dz = fwd[3] + sx * halfW * right[3] + sy * halfH * up[3]
        local nx, ny, nz = Normalize(dx, dy, dz)
        fr.rays[i] = { nx, ny, nz }
    end
    return fr
end

-- 0 = outside the terrain, 1 = above the ground, 2 = on or under it
local function Probe(ex, ey, ez, dx, dy, dz, ground, t)
    local x, y, z = ex + dx * t, ey + dy * t, ez + dz * t
    local g = ground(x, z)
    if g == nil then return 0, x, y, z, nil end
    if y <= g then return 2, x, y, z, g end
    return 1, x, y, z, g
end

--- The first point where the ray (unit direction) meets the ground: marched in `steps` steps up to distance `tmax`, then bisected. `ground(x, z)` is the terrain height or nil outside the
--- terrain. Returns x, y, z, t, kind: 'ground' (the ray meets the ground), 'edge' (it leaves the terrain first: the point is the last one inside, on the ground); nil when it does neither.
function RayGround(ex, ey, ez, dx, dy, dz, ground, tmax, steps)
    if dy >= -1e-6 then return nil end          -- a ray that does not go down meets no ground
    local dt = tmax / steps
    local prev, prevT = Probe(ex, ey, ez, dx, dy, dz, ground, 0), 0
    for i = 1, steps do
        local t = i * dt
        local st, x, y, z, g = Probe(ex, ey, ez, dx, dy, dz, ground, t)
        if st ~= prev then
            if prev == 1 then
                local a, b = prevT, t
                for k = 1, 18 do
                    local mid = (a + b) * 0.5
                    if (Probe(ex, ey, ez, dx, dy, dz, ground, mid)) == st then b = mid else a = mid end
                end
                local _, px, py, pz, pg = Probe(ex, ey, ez, dx, dy, dz, ground, a)
                return px, pg or py, pz, a, (st == 2) and 'ground' or 'edge'
            elseif prev == 0 and st == 2 then
                return x, g, z, t, 'ground'          -- the ray entered the terrain already below the surface (a steep rim)
            end
        end
        prev, prevT = st, t
    end
    return nil
end

--- Where the four corner rays of `fr` meet the ground (see RayGround). A ray that meets nothing (it points at the sky, or the terrain ends before it comes down) gives a 'far' point:
--- on the eye's height, a long way out along the ray's horizontal direction; the caller lays it onto the terrain.
function Corners(fr, ground, tmax, steps)
    local out = {}
    local far = math.min(tmax, fr.dist * 4 + 300)
    for i = 1, 4 do
        local d = fr.rays[i]
        local x, y, z, t, kind = RayGround(fr.eye[1], fr.eye[2], fr.eye[3], d[1], d[2], d[3], ground, tmax, steps)
        if x then
            out[i] = { x, y, z, kind = kind, t = t }
        else
            local hx, hz = d[1], d[3]
            local l = math.sqrt(hx * hx + hz * hz)
            if l < 1e-6 then hx, hz, l = fr.fwd[1], fr.fwd[3], math.sqrt(fr.fwd[1] * fr.fwd[1] + fr.fwd[3] * fr.fwd[3]) end
            if l < 1e-6 then hx, hz, l = 0, 1, 1 end
            out[i] = { fr.eye[1] + hx / l * far, fr.eye[2], fr.eye[3] + hz / l * far, kind = 'far', t = far }
        end
    end
    return out
end

-- ---- drawing ----------------------------------------------------------------------------------------------------------------------------

local drawn = {}          -- marker name -> key of the frame on screen
local names = {}          -- selected Camera Info markers (rescanned when Tools.Changed moves)
local scannedFor = -1

function Forget()
    drawn = {}
    names = {}
    scannedFor = -1
end

local function RemoveFrame(name)
    for _, s in SUFFIXES do ed_overlay_remove('camfr:' .. name .. ':' .. s) end
    drawn[name] = nil
end

local function Finite(v)
    return v ~= nil and v == v and v > -1e7 and v < 1e7
end

--- The terrain height at (x, z) between the height samples (nil outside the terrain), for the outline that lies on the ground.
local function Draped(x, z, w, h)
    if x < 0 or z < 0 or x > w - 1 or z > h - 1 then
        x = math.max(0, math.min(w - 1, x))
        z = math.max(0, math.min(h - 1, z))
    end
    local ix, iz = math.floor(x), math.floor(z)
    local g = ed_terrain_get(ix, iz) or 0
    local fx, fz = x - ix, z - iz
    if fx > 0.001 or fz > 0.001 then
        local g10 = ed_terrain_get(ix + 1, iz) or g
        local g01 = ed_terrain_get(ix, iz + 1) or g
        local g11 = ed_terrain_get(ix + 1, iz + 1) or g
        g = (g * (1 - fx) + g10 * fx) * (1 - fz) + (g01 * (1 - fx) + g11 * fx) * fz
    end
    return MeshView.GroundAt(x, z, g)          -- an outline hugs the visible ground of a mesh map, as the other overlays do
end

--- The aspect ratio of the world camera's viewport and its largest zoom (nil where the engine does not say).
local function ViewInfo(view)
    local aspect, maxZoom
    if rawget(_G, 'ed_camera_info') then
        local ok, fov, dist, fx, fy, fz, hd, pt, tz, vx, vy, vw, vh = pcall(ed_camera_info)
        if ok and vw and vh and vh > 0 and vw > 0 then aspect = vw / vh end
    end
    if not aspect and view then
        local ok, w, h = pcall(function() return view.Width(), view.Height() end)
        if ok and w and h and h > 0 and w > 0 then aspect = w / h end
    end
    local cam = rawget(_G, 'GetCamera') and GetCamera('WorldCamera')
    if cam then
        local ok, z = pcall(function() return cam:GetMaxZoom() end)
        if ok and type(z) == 'number' then maxZoom = z end
    end
    return aspect or (16 / 9), maxZoom
end

local function Settings()
    local cam = rawget(_G, 'GetCamera') and GetCamera('WorldCamera')
    if not cam then return nil end
    local ok, s = pcall(function() return cam:SaveSettings() end)
    return ok and s or nil
end

--- The values the frame of marker `m` is drawn from: focus x, y, z, heading, pitch, zoom (nil when the marker has no usable position).
local function Pose(m, s)
    local p = m.position
    if not p or not Finite(p[1]) or not Finite(p[2]) or not Finite(p[3]) then return nil end
    local o = m.orientation or {}
    local zoom = tonumber(m.zoom)
    if not zoom or zoom <= 0 then zoom = s and s.Zoom or 100 end
    local heading = Finite(o[1]) and o[1] or (s and s.Heading) or 0
    local pitch = Finite(o[2]) and o[2] or (s and s.Pitch) or 0.8
    if not Finite(zoom) or zoom <= 0 then return nil end
    return p[1], p[2], p[3], heading, pitch, zoom
end

local function DrawFrame(name, fx, fy, fz, heading, pitch, zoom, aspect, maxZoom)
    local w, h = ed_terrain_info()
    w, h = w or 257, h or 257
    -- the march reads the nearest height sample: four rays of several hundred steps stay cheap
    local function Ground(x, z)
        if x < 0 or z < 0 or x > w - 1 or z > h - 1 then return nil end
        return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5))
    end
    local fov = FovFor(zoom, maxZoom)
    local fr = Frustum(fx, fy, fz, heading, pitch, zoom, fov, aspect)
    local tmax = math.min(8000, fr.dist * 6 + 400)
    local pts = Corners(fr, Ground, tmax, 600)
    local eye = fr.eye
    local ring = {}
    for i = 1, 4 do
        local c = pts[i]
        if c.kind == 'far' then
            c[1] = math.max(0, math.min(w - 1, c[1]))
            c[3] = math.max(0, math.min(h - 1, c[3]))
        end
        c[2] = Draped(c[1], c[3], w, h)
        ed_overlay_set('camfr:' .. name .. ':e' .. i, { eye[1], eye[2], eye[3], c[1], c[2] + LIFT, c[3] }, COLOR_EDGE, 0.12, 1, 2, false, true)
    end
    -- the quadrilateral on the ground: every side sampled about every 2 world units, each point on the terrain
    for i = 1, 4 do
        local a, b = pts[i], pts[math.mod(i, 4) + 1]
        local len = math.sqrt((b[1] - a[1]) * (b[1] - a[1]) + (b[3] - a[3]) * (b[3] - a[3]))
        local n = math.max(2, math.min(80, math.ceil(len / 2)))
        for k = 0, n - 1 do
            local f = k / n
            local x, z = a[1] + (b[1] - a[1]) * f, a[3] + (b[3] - a[3]) * f
            table.insert(ring, x)
            table.insert(ring, Draped(x, z, w, h) + LIFT)
            table.insert(ring, z)
        end
    end
    ed_overlay_set('camfr:' .. name .. ':q', ring, COLOR_OUTLINE, 0.2, 2, 3, true, true)
    -- the line of sight to the focus point, the marker itself
    ed_overlay_set('camfr:' .. name .. ':c', { eye[1], eye[2], eye[3], fx, fy + LIFT, fz }, COLOR_CENTRE, 0.08, 1, 1, false, true)
end

--- Per-frame: the frames of the selected Camera Info markers (and no others).
function Update(ui, view)
    if rawget(_G, 'ed_overlay_set') == nil or not Map.Doc then return end
    local mode = ui and ui.State and ui.State.mode
    if mode == 'play' then
        if next(drawn) ~= nil then for n, _ in drawn do RemoveFrame(n) end end
        return
    end
    if scannedFor ~= Tools.Changed then
        scannedFor = Tools.Changed
        names = {}
        local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
        local Filter = import('/lua/editor/markerfilter.lua')
        for _, it in Tools.Items do
            if it.kind == 'marker' and table.getn(names) < MAX_FRAMES then
                local m = markers[it.name]
                if m and m.type == 'Camera Info' and not Filter.IsHidden(m.type) then table.insert(names, it.name) end
            end
        end
    end
    if table.getn(names) == 0 then
        if next(drawn) ~= nil then for n, _ in drawn do RemoveFrame(n) end end
        return
    end
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    local aspect, maxZoom = ViewInfo(view)
    local s = Settings()
    local wanted = {}
    for _, name in names do
        local m = markers[name]
        local fx, fy, fz, heading, pitch, zoom
        if m then fx, fy, fz, heading, pitch, zoom = Pose(m, s) end
        if fx then
            wanted[name] = true
            local key = string.format('%.3f|%.3f|%.3f|%.4f|%.4f|%.3f|%.3f|%.1f|%d', fx, fy, fz, heading, pitch, zoom, aspect, maxZoom or 0, TerrainEpoch.Epoch)
            if drawn[name] ~= key then
                DrawFrame(name, fx, fy, fz, heading, pitch, zoom, aspect, maxZoom)
                drawn[name] = key
            end
        end
    end
    for n, _ in drawn do
        if not wanted[n] then RemoveFrame(n) end
    end
end
