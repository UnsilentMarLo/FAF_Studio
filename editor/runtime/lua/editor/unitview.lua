-- The unit viewer (docs/projects/MOD_UNIT_EDITOR_DESIGN.md, stages S2 / S5, viewer rework 2026-10-18).
--
-- The chosen unit is a real unit of the editing sim, drawn by the game's own renderer with its real animations. It stands on a stage:
--   Stage 'viewer'   (default) a spot in a far corner of the map, with the terrain, sky and water switched off: an empty dark stage with a floor grid and its own camera. The map is not touched;
--                    the camera of the map is saved on entering and restored on leaving.
--   Stage 'map'      the unit stands at the lab spot beside the middle of the map, on the map's own ground (as it always did).
-- Everything the viewer makes (the unit, wrecks, effect and projectile entities) is taken down again by Remove() / Close(): when the unit changes, the workspace changes, a test run starts, the viewer
-- is switched off. Nothing of it is saved into the map or recorded in the undo history.
--
--   SetStage(name) / Stage     'viewer' | 'map';   Close()  takes everything down and restores the camera and the terrain
--   Spawn(id[, keepCamera])    the unit on the stage, then (a thread) the camera frames it;   Remove()   Id, EntityId, X, Z, Y0
--   Show.<name>                range, senses, footprint (+ skirt), hitbox (3D box of the engine's collision extents), bones, grid;   Refresh() redraws the static drawings, OnFrame() the bones (every frame)
--   Show.lock                  the camera is held on the unit every frame (LockCamera): panning is undone, rotating and zooming work around the unit, the distance stays within a few radii
--   Frame(mode)                'iso' (3/4 from the front left), 'front', 'back', 'side', 'top', 'unit' (= iso), 'range';   Orbit(dHeading, dPitch), Fit()   camera on the unit's centre, zoomed to its bounds
--   Bones / BoneSel            the bones of the shown unit as the renderer poses them this frame (ed_unit_bones): { name, index, parent, x, y, z, fx, fy, fz, ux, uy, uz }
--   LODs(id) / ShowLOD(n)      the mesh LODs and the camera distance for one of them (thread);  Colors / SetColor(name);  Lights / SetLight(name)
--   Animations(id) / Play(path, loop) / SetRate(rate) / Scrub(fraction) / Stop()      animation control (sim callbacks EdAnim*)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Safe = import('/lua/editor/safe.lua')
Stage = 'viewer'
Id = false
EntityId = false
X, Z = 0, 0
Y0 = 0                   -- ground height under the unit
Show = { range = true, senses = false, footprint = true, hitbox = true, bones = false, grid = true, lock = true }   -- lock: the camera stays on the unit (orbit and zoom only)
Bones = {}
BoneSel = false          -- the picked bone (its name)
LODInfo = false          -- the measured LOD range of the shown unit (see ShowLOD); false until one was measured
Rate = 1
Heading, Pitch = -2.5831853, 0.55      -- (3.7 turned into the range -pi .. pi: NormHeading)
Info = false             -- what the sim told about the shown unit: { id, pos = {x,y,z}, ext = {minx,miny,minz,maxx,maxy,maxz} }
local ids = {}
local boneIds = {}
local infoPath = 'ed_view_info.txt'
local saved = false      -- the terrain flags are switched (the viewer stage is on)
local origCamera = false -- the map's camera, saved by the first Spawn and put back by Close
local lockC = false      -- the centre and radius the lock holds the camera on: set by Aim, so a turning turret does not shake the view
local aimUntil = 0       -- the lock waits while Aim is still settling the camera
LastError = false        -- what went wrong the last time a unit was shown (the panel's status line shows it); false = nothing
local spawnedAt = 0
local lastLockAt = -1
local logAt = {}

--- LOG with the 'EDITOR unitview:' prefix, at most once in 5 seconds per key (a failure that repeats every frame must not flood the Console).
local function Log(key, text)
    local now = GetSystemTimeSeconds()
    if logAt[key] and now - logAt[key] < 5 then return end
    logAt[key] = now
    LOG('EDITOR unitview: ' .. text)
end

--- A heading in (-pi, pi]. The engine's culling of mesh instances misbehaves for headings outside that range (units vanished facing some directions, camera.lua NormalizeHeading), and
--- the viewer's own presets used to ask for 3.7 and 4.71: every heading the viewer sets goes through here.
function NormHeading(h)
    while h > 3.1415927 do h = h - 6.2831853 end
    while h <= -3.1415927 do h = h + 6.2831853 end
    return h
end

local function Overlay() return rawget(_G, 'ed_overlay_set') ~= nil end

local function MapGround(x, z) return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0 end

--- Height of the ground the unit stands on at (x, z): the stage's flat floor, or the map's terrain.
local function Ground(x, z)
    if Stage == 'viewer' and Id then return Y0 end
    return MapGround(x, z)
end

-- ---- 3D drawing helpers (pure: the self test checks them) ------------------------------------------------------------------------------------------------

--- The 12 edges of an axis aligned box as one polyline (points x, y, z, ...): bottom square, up, top square, down the three remaining verticals.
function BoxPoints(minx, miny, minz, maxx, maxy, maxz)
    local b = { { minx, miny, minz }, { maxx, miny, minz }, { maxx, miny, maxz }, { minx, miny, maxz } }
    local t = { { minx, maxy, minz }, { maxx, maxy, minz }, { maxx, maxy, maxz }, { minx, maxy, maxz } }
    local order = { b[1], b[2], b[3], b[4], b[1], t[1], t[2], b[2], b[3], t[3], t[2], t[3], t[4], b[4], t[4], t[1] }
    local pts = {}
    for _, p in order do table.insert(pts, p[1]) table.insert(pts, p[2]) table.insert(pts, p[3]) end
    return pts
end

--- A horizontal circle at height y (closed by the overlay).
function CirclePoints(cx, y, cz, r, segs)
    local pts = {}
    for i = 0, segs - 1 do
        local a = (i / segs) * 6.2831853
        table.insert(pts, cx + math.cos(a) * r) table.insert(pts, y) table.insert(pts, cz + math.sin(a) * r)
    end
    return pts
end

--- A rectangle on the ground (x0, z0 .. x1, z1) at height y (closed by the overlay).
function RectPoints(x0, z0, x1, z1, y)
    return { x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1 }
end

--- The footprint and the skirt of a blueprint as ground rectangles around (x, z): { fx0, fz0, fx1, fz1 }, { sx0, sz0, sx1, sz1 } (the skirt nil when the blueprint has none).
--- The skirt starts at the footprint's corner plus SkirtOffsetX / Z and is SkirtSizeX / Z long.
function FootprintRects(bp, x, z)
    local fp = bp.Footprint or {}
    local fx, fz = fp.SizeX or 1, fp.SizeZ or 1
    local foot = { x - fx / 2, z - fz / 2, x + fx / 2, z + fz / 2 }
    local ph = bp.Physics or {}
    local skirt
    if ph.SkirtSizeX and ph.SkirtSizeZ then
        local x0, z0 = foot[1] + (ph.SkirtOffsetX or 0), foot[2] + (ph.SkirtOffsetZ or 0)
        skirt = { x0, z0, x0 + ph.SkirtSizeX, z0 + ph.SkirtSizeZ }
    end
    return foot, skirt
end

local function Clear()
    for id, _ in ids do ed_overlay_remove(id) end
    ids = {}
end

local function ClearBones()
    for id, _ in boneIds do ed_overlay_remove(id) end
    boneIds = {}
end

local function Line(id, pts, color, width, open)
    ed_overlay_set(id, pts, color, width or 0.08, 1, 2, not open, true)
    ids[id] = true
end

-- ---- stage -----------------------------------------------------------------------------------------------------------------------------------------

--- The lab spot of the map stage: beside the start position marker that usually stands in the middle of the map.
function LabSpot()
    local w = ed_terrain_info()
    local mid = ((w or 257) - 1) / 2
    return mid + 24, mid
end

--- The spot of the viewer stage: of the four corners of the map (a margin inside) the one farthest from every object in `objects` (list of { x, z }); a map of fewer than 200 cells uses the middle.
function StageSpotFor(size, objects)
    local m = math.min(40, size / 4)
    local best, bestScore = nil, -1
    for _, c in { { m, m }, { size - m, m }, { m, size - m }, { size - m, size - m } } do
        local score = 1e9
        for _, o in objects or {} do
            local d = math.sqrt((o[1] - c[1]) * (o[1] - c[1]) + (o[2] - c[2]) * (o[2] - c[2]))
            if d < score then score = d end
        end
        if score > bestScore then best, bestScore = c, score end
    end
    return best[1], best[2]
end

local function StageSpot()
    local w = ed_terrain_info() or 257
    local objects = {}
    Safe.Try('unitview:fn155', function()
        local Map = import('/lua/editor/map.lua')
        if Map.Doc then
            for _, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers or {} do
                local p = m.position
                if p then table.insert(objects, { p[1], p[3] }) end
            end
        end
    end)
    return StageSpotFor(w - 1, objects)
end

--- A naval unit needs water under it (on land the engine treats it as beached). The deepest open water of the map within the first `limit` samples scanned, as x, z, waterElevation; nil when the map has no
--- water at least `need` deep. `get(x, z)` is the terrain height, `size` the map's cell count a side; pure, the self test calls it with a fake terrain.
function WaterSpotFor(get, size, water, need)
    local best, bx, bz = need - 0.001, nil, nil
    local step = math.max(4, math.floor(size / 64))
    local m = math.min(24, math.floor(size / 8))
    for z = m, size - m, step do
        for x = m, size - m, step do
            local depth = water - get(x, z)
            if depth > best then
                -- open water: the ring around it is water too, so the unit has room to float
                local ok = true
                for _, d in { { -10, 0 }, { 10, 0 }, { 0, -10 }, { 0, 10 } } do
                    if water - get(x + d[1], z + d[2]) < need then ok = false break end
                end
                if ok then best, bx, bz = depth, x, z end
            end
        end
    end
    if not bx then return nil end
    return bx, bz, water
end

local function IsNaval(bp)
    local mt = bp.Physics and bp.Physics.MotionType
    if mt == 'RULEUMT_Water' or mt == 'RULEUMT_SurfacingSub' then return true end
    for _, c in bp.Categories or {} do
        if c == 'NAVAL' then return true end
    end
    return false
end

--- The spot a naval unit stands on: the deepest open water of the map (x, z, surface height), else nil (the unit then stands on the stage's ordinary spot and the sim keeps it unharmed).
local function WaterSpot()
    local size = ed_terrain_info()
    if not size then return nil end
    local ok, water = pcall(function() return import('/lua/editor/world.lua').Get().water_elev end)
    if not (ok and water) then return nil end
    return WaterSpotFor(MapGround, size - 1, water, 6)
end

--- The terrain, sky and water of the map are not drawn on the viewer stage (console variables of the engine, process wide: put back by StageOff and by every fresh session).
local iconLens = false   -- the icon generator is rendering: the stage keeps the game's own lens

local function Lens(steady)
    if iconLens then steady = false end
    -- the game camera cannot come closer than a zoom of 5 and widens the view to 65 degrees there: a small unit stays a speck. The stage lets it come close with a steady 35 degree lens.
    if steady then
        ConExecute('cam_NearZoom 0.2') ConExecute('cam_NearFOV 35') ConExecute('cam_FarFOV 35')
    else
        ConExecute('cam_NearZoom 5') ConExecute('cam_NearFOV 65') ConExecute('cam_FarFOV 60')
    end
end

local function Flags(on)
    local v = on and 'true' or 'false'
    for _, name in { 'ren_Terrain', 'ren_SkyDome', 'ren_Water', 'ren_WorldBorder' } do ConExecute(name .. ' ' .. v) end
    Lens(not on)
end

--- The icon generator measured its camera constants with the game's own lens; while it renders, the stage's steady lens is taken off (on = true) and put back afterwards (on = false).
function IconLens(on)
    iconLens = on and true or false
    if saved then Lens(true) end
    aimUntil = GetSystemTimeSeconds() + 0.5
end

local function StageOn()
    if saved then return end
    saved = true
    Flags(false)
end

local function StageOff()
    if not saved then return end
    Flags(true)
    saved = false
end

--- 'viewer' or 'map': where the shown unit stands. The unit is made again on the new stage.
function SetStage(name)
    if name ~= 'viewer' and name ~= 'map' then return false end
    if name == Stage then return true end
    local id = Id
    Remove()
    if saved and name == 'map' then StageOff() end
    Stage = name
    if id then Spawn(id) end
    return true
end

--- Everything the viewer made goes: its unit, wrecks and props that appeared around its spot, effect and projectile entities; the stage is switched off again.
function Close()
    Remove(true)
    StageOff()
    if origCamera then
        local cam = GetCamera('WorldCamera')
        Safe.Try('unitview:fn264', function() cam:RestoreSettings(origCamera) end)
        origCamera = false
    end
end

-- ---- drawing the static parts ----------------------------------------------------------------------------------------------------------------------------

local function Grid(bp, radius)
    local y = Y0 + 0.03
    local half = math.max(6, math.ceil(radius * 3 / 2) * 2)
    local step = half / 6
    local water = bp.Physics and bp.Physics.MotionType and string.find(string.lower(bp.Physics.MotionType), 'water') ~= nil
    local color, axis = 'FF2F3C4A', 'FF4C6178'
    if water then color, axis = 'FF1E4766', 'FF2F76AD' end
    for i = -6, 6 do
        local c = i == 0 and axis or color
        Line('uv:gx' .. i, { X + i * step, y, Z - half, X + i * step, y, Z + half }, c, 0.05, true)
        Line('uv:gz' .. i, { X - half, y, Z + i * step, X + half, y, Z + i * step }, c, 0.05, true)
    end
end

--- The bounds of the shown unit: centre (x, y, z) and a radius that holds it. From the collision extents the sim reported, widened by the bones, else from the blueprint.
function Bounds()
    local bp = Id and __blueprints and __blueprints[Id]
    if not bp then return nil end
    local minx, miny, minz, maxx, maxy, maxz
    if Info and Info.ext then
        minx, miny, minz, maxx, maxy, maxz = unpack(Info.ext)
    else
        local sx, sy, sz = bp.SizeX or 1, bp.SizeY or 1, bp.SizeZ or 1
        minx, miny, minz, maxx, maxy, maxz = X - sx / 2, Y0, Z - sz / 2, X + sx / 2, Y0 + sy, Z + sz / 2
    end
    for _, b in Bones do
        if b.x < minx then minx = b.x elseif b.x > maxx then maxx = b.x end
        if b.y < miny then miny = b.y elseif b.y > maxy then maxy = b.y end
        if b.z < minz then minz = b.z elseif b.z > maxz then maxz = b.z end
    end
    local cx, cy, cz = (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2
    local r = 0.5 * math.sqrt((maxx - minx) * (maxx - minx) + (maxy - miny) * (maxy - miny) + (maxz - minz) * (maxz - minz))
    return cx, cy, cz, math.max(r, 0.4)
end

--- Redraws the static drawings: floor grid, rings, footprint and skirt on the ground, the 3D hit box.
function Refresh()
    if not Overlay() then return end
    Clear()
    local bp = Id and __blueprints and __blueprints[Id]
    if not bp then return end
    local gy = Ground(X, Z)
    local _, _, _, radius = Bounds()
    if Stage == 'viewer' and Show.grid then Grid(bp, radius or 1) end
    local function Ring(id, r, color, segs)
        -- rings follow the map's terrain on the map stage and lie on the floor on the viewer stage
        local pts = {}
        for i = 0, segs - 1 do
            local a = (i / segs) * 6.2831853
            local x, z = X + math.cos(a) * r, Z + math.sin(a) * r
            table.insert(pts, x) table.insert(pts, Ground(x, z) + 0.2) table.insert(pts, z)
        end
        Line(id, pts, color)
    end
    if Show.range then
        for _, w in bp.Weapon or {} do
            if w.MaxRadius and w.MaxRadius > 0 and not w.DummyWeapon then
                Ring('uv:max:' .. tostring(w.Label), w.MaxRadius, 'FFE5645E', 96)
                if w.MinRadius and w.MinRadius > 0 then Ring('uv:min:' .. tostring(w.Label), w.MinRadius, 'FFE2B44A', 64) end
            end
        end
    end
    if Show.senses then
        local intel = bp.Intel or {}
        local sets = { { 'VisionRadius', 'FF5FC07F' }, { 'RadarRadius', 'FF3FB7D4' }, { 'SonarRadius', 'FF436EEE' }, { 'OmniRadius', 'FFFF88FF' }, { 'WaterVisionRadius', 'FF2E8B57' } }
        for _, s in sets do
            local r = intel[s[1]]
            if r and r > 0 then Ring('uv:' .. s[1], r, s[2], 96) end
        end
    end
    if Show.footprint then
        local foot, skirt = FootprintRects(bp, X, Z)
        Line('uv:footprint', RectPoints(foot[1], foot[2], foot[3], foot[4], gy + 0.2), 'FFFFFFFF', 0.1)
        if skirt then Line('uv:skirt', RectPoints(skirt[1], skirt[2], skirt[3], skirt[4], gy + 0.2), 'AAFFFFFF', 0.06) end
    end
    if Show.hitbox then
        local minx, miny, minz, maxx, maxy, maxz
        if Info and Info.ext then
            minx, miny, minz, maxx, maxy, maxz = unpack(Info.ext)
        else
            local sx, sy, sz = bp.SizeX or 1, bp.SizeY or 1, bp.SizeZ or 1
            local ox, oy, oz = bp.CollisionOffsetX or 0, bp.CollisionOffsetY or 0, bp.CollisionOffsetZ or 0
            minx, miny, minz, maxx, maxy, maxz = X + ox - sx / 2, gy + oy, Z + oz - sz / 2, X + ox + sx / 2, gy + oy + sy, Z + oz + sz / 2
        end
        if bp.CollisionShape == 'Sphere' then
            -- the engine's sphere collision: the extents are its bounding box; three great circles show it
            local cx, cy, cz = (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2
            local r = (maxx - minx) / 2
            Line('uv:hit1', CirclePoints(cx, cy, cz, r, 48), 'FFFF873E', 0.06)
            local v, w = {}, {}
            for i = 0, 47 do
                local a = (i / 48) * 6.2831853
                table.insert(v, cx + math.cos(a) * r) table.insert(v, cy + math.sin(a) * r) table.insert(v, cz)
                table.insert(w, cx) table.insert(w, cy + math.sin(a) * r) table.insert(w, cz + math.cos(a) * r)
            end
            Line('uv:hit2', v, 'FFFF873E', 0.06) Line('uv:hit3', w, 'FFFF873E', 0.06)
        else
            Line('uv:hitbox', BoxPoints(minx, miny, minz, maxx, maxy, maxz), 'FFFF873E', 0.06, true)
        end
    end
end

-- ---- bones, every frame ----------------------------------------------------------------------------------------------------------------------------------

local function DrawBones()
    local ok, list = pcall(ed_unit_bones, EntityId)
    if not ok or type(list) ~= 'table' then return false end
    Bones = list
    local seen = {}
    for i, b in list do
        local sel = b.name == BoneSel
        local r = sel and 0.12 or 0.05
        local id = 'uv:bj' .. i
        -- a joint: a small 3D cross along the bone's own axes
        local rx, ry, rz = b.uy * b.fz - b.uz * b.fy, b.uz * b.fx - b.ux * b.fz, b.ux * b.fy - b.uy * b.fx
        local pts = {
            b.x - rx * r, b.y - ry * r, b.z - rz * r, b.x + rx * r, b.y + ry * r, b.z + rz * r, b.x, b.y, b.z,
            b.x - b.ux * r, b.y - b.uy * r, b.z - b.uz * r, b.x + b.ux * r, b.y + b.uy * r, b.z + b.uz * r, b.x, b.y, b.z,
            b.x - b.fx * r, b.y - b.fy * r, b.z - b.fz * r, b.x + b.fx * r, b.y + b.fy * r, b.z + b.fz * r,
        }
        ed_overlay_set(id, pts, sel and 'FFFFE070' or 'CC7FD0FF', sel and 0.05 or 0.025, 1, 2, false, true)
        boneIds[id] = true seen[id] = true
        local parent = list[b.parent + 1]
        if parent then
            local pid = 'uv:bp' .. i
            ed_overlay_set(pid, { parent.x, parent.y, parent.z, b.x, b.y, b.z }, 'AA9AA7B5', 0.02, 1, 2, false, false)
            boneIds[pid] = true seen[pid] = true
        end
        if sel then
            local len = 0.6
            local aid = 'uv:ba'
            ed_overlay_set(aid .. 'f', { b.x, b.y, b.z, b.x + b.fx * len, b.y + b.fy * len, b.z + b.fz * len }, 'FF4C8DFF', 0.05, 2, 3, false, false)
            ed_overlay_set(aid .. 'u', { b.x, b.y, b.z, b.x + b.ux * len, b.y + b.uy * len, b.z + b.uz * len }, 'FF5CE05C', 0.05, 2, 3, false, false)
            ed_overlay_set(aid .. 'r', { b.x, b.y, b.z, b.x + rx * len, b.y + ry * len, b.z + rz * len }, 'FFFF5050', 0.05, 2, 3, false, false)
            boneIds[aid .. 'f'] = true boneIds[aid .. 'u'] = true boneIds[aid .. 'r'] = true
            seen[aid .. 'f'] = true seen[aid .. 'u'] = true seen[aid .. 'r'] = true
        end
    end
    for id, _ in boneIds do
        if not seen[id] then ed_overlay_remove(id) boneIds[id] = nil end
    end
    return true
end

function SelectBone(name)
    BoneSel = name
end

--- Called every frame by overlay.lua: the bones follow the animation exactly (the renderer's own interpolated pose).
function OnFrame()
    if lockC then Tick() end
    if Show.bones and EntityId and Overlay() then
        DrawBones()
    elseif next(boneIds) then
        ClearBones()
    end
end

-- ---- spawning and taking down ----------------------------------------------------------------------------------------------------------------------

--- Takes the unit and everything else the viewer made down (the sim destroys its tagged units, new props and wrecks around the spot, effect and projectile entities). final: forget what stood there before.
function Remove(final)
    if Id or final then
        SimCallback({ Func = 'EdViewClear', Args = { x = X, z = Z, radius = 90, final = final and true or false } }, false)
    end
    Id, EntityId, Info = false, false, false
    lockC = false
    LastError = false
    Bones, BoneSel = {}, false
    Clear()
    ClearBones()
end

local function ReadInfo()
    local text = ed_read_file(infoPath)
    if not text or text == '' then return nil end
    local info = {}
    for line in string.gfind(text, '[^\r\n]+') do
        local t = {}
        for token in string.gfind(line, '%S+') do table.insert(t, token) end
        if t[1] == 'id' then info.id = tonumber(t[2])
        elseif t[1] == 'pos' then info.pos = { tonumber(t[2]), tonumber(t[3]), tonumber(t[4]) }
        elseif t[1] == 'ext' then info.ext = { tonumber(t[2]), tonumber(t[3]), tonumber(t[4]), tonumber(t[5]), tonumber(t[6]), tonumber(t[7]) }
        elseif t[1] == 'error' then info.error = line end
    end
    return info
end

--- Spawns the unit for army ARMY_1 on the stage and frames it (keepCamera: leaves the camera where it is). Returns true | nil + reason; the framing happens a moment later (a thread).
--- What goes wrong later (the sim cannot make the unit, no answer, the renderer has no mesh for it) is logged ('EDITOR unitview: ...') and kept in LastError for the panel.
function Spawn(id, keepCamera)
    local bp = __blueprints and __blueprints[id]
    if not bp then
        LastError = 'no such unit: ' .. tostring(id)
        Log('spawn', LastError)
        return nil, 'no such unit'
    end
    Remove()
    LastError = false
    if not origCamera then origCamera = GetCamera('WorldCamera'):SaveSettings() end
    if Stage == 'viewer' then
        StageOn()
        X, Z = StageSpot()
        Y0 = MapGround(X, Z)
    else
        StageOff()
        X, Z = LabSpot()
        Y0 = MapGround(X, Z)
    end
    if IsNaval(bp) then
        local wx, wz, surface = WaterSpot()
        if wx then X, Z, Y0 = wx, wz, surface end
    end
    ed_write_file(infoPath, '')
    SimCallback({ Func = 'EdViewSpawn', Args = { bp = id, army = 'ARMY_1', x = X, y = Y0, z = Z, heading = 0, path = infoPath } }, false)
    Id = id
    Rate = 1
    spawnedAt = GetSystemTimeSeconds()
    Log('spawn:' .. id, string.format('showing %s on the %s stage at %.1f, %.1f, %.1f', id, Stage, X, Y0, Z))
    ForkThread(function()
        -- the sim writes the unit's entity id and extents; the renderer has the unit a frame or two later (a busy sim answers late: wait up to 8 seconds)
        local why
        for i = 1, 80 do
            WaitSeconds(0.1)
            if Id ~= id then return end
            local info = ReadInfo()
            if info then
                if info.error then
                    Info = false
                    LastError = 'the sim could not make ' .. id .. ' (' .. tostring(info.error) .. ')'
                    Log('simerror', LastError)
                    break
                end
                Info = info
                EntityId = (info.id and info.id >= 0) and info.id or false
                if EntityId then
                    if not ed_unit_bones then break end
                    local okBones, bones, message = pcall(ed_unit_bones, EntityId)
                    if okBones and bones then break end
                    why = okBones and message or bones
                end
            end
        end
        if Id ~= id then return end
        if not LastError then
            if not EntityId then
                LastError = 'the sim did not answer for ' .. id .. ' (no unit was made, or it is slow)'
                Log('noanswer', LastError .. '; the camera is held on the stage anyway')
            elseif ed_unit_bones then
                local okB, bonesNow = pcall(ed_unit_bones, EntityId)
                if not (okB and bonesNow) then
                    Log('nomesh', 'the sim made ' .. id .. ' (entity ' .. tostring(EntityId) .. ') but the renderer has no mesh for it: ' .. tostring(why))
                end
            end
        end
        -- a unit settles (an aircraft lands, the collision shape follows): ask again after a moment so the hit box and the framing use the settled extents
        if EntityId then
            ed_write_file(infoPath, '')
            SimCallback({ Func = 'EdViewInfo', Args = { x = X, z = Z, path = infoPath } }, false)
            WaitSeconds(1.2)
            if Id ~= id then return end
            local again = ReadInfo()
            if again and again.ext then Info = again end
        end
        Safe.Try('unitview:DrawBones', DrawBones)
        Refresh()
        if not keepCamera then Frame('iso') end
    end)
    return true
end

-- ---- camera ----------------------------------------------------------------------------------------------------------------------------------------

local aiming = 0

local function PanelRect()
    local ok, wv = pcall(function() return import('/lua/ui/game/worldview.lua').viewLeft end)
    if not (ok and wv) then return nil end
    return wv.Left(), wv.Top(), wv.Right(), wv.Bottom()
end

--- The ground point the camera must look at so that the line of sight through it passes through `c`: (cx, cy, cz) shifted by the screen offset (ox, oy) pixels (the unit appears that far
--- from the middle of the projection), `upp` world units per pixel at the unit's depth. Pure. The terrain snap of the engine puts the camera's focus on the ground along the line of sight, so
--- the focus has to be the point where that line meets the ground (gy).
function FocusFor(cx, cy, cz, heading, pitch, gy, ox, oy, upp)
    local sp, cp, sh, ch = math.sin(pitch), math.cos(pitch), math.sin(heading), math.cos(heading)
    local dx, dy, dz = sh * cp, -sp, ch * cp                      -- the camera looks along this
    local rx, ry, rz = -ch, 0, sh                                  -- screen right
    local ux, uy, uz = ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx      -- screen up = right x forward
    local ax, ay, az = cx - rx * ox * upp + ux * oy * upp, cy - ry * ox * upp + uy * oy * upp, cz - rz * ox * upp + uz * oy * upp
    local s = (gy - ay) / dy
    return ax + dx * s, gy, az + dz * s, s
end

--- Aims the camera at the unit: heading / pitch (radians) around the unit's centre; `fit` zooms so that its bounds fill the panel (else the zoom stays). A thread: it needs a few frames to read what
--- the engine made of the zoom (field of view, eye distance) and to centre the unit in the visible panel instead of the middle of the whole window.
function Aim(heading, pitch, fit)
    if not Id then return end
    heading = NormHeading(heading)
    local oldHeading, oldPitch = Heading, Pitch
    Heading, Pitch = heading, pitch
    aiming = aiming + 1
    local mine = aiming
    ForkThread(function()
        local cam = GetCamera('WorldCamera')
        local cx, cy, cz, radius = Bounds()
        if not cx then Log('aimbounds', 'Aim: the bounds of ' .. tostring(Id) .. ' are unknown') return end
        lockC = { cx, cy, cz, radius }
        aimUntil = GetSystemTimeSeconds() + 0.08 * 5 + 0.5
        local gy = Ground(X, Z)
        local left, top, right, bottom = PanelRect()
        local zoom = fit and math.max(radius * 4, 3) or math.max(cam:GetTargetZoom() or 10, 3)
        local ox, oy, upp = 0, 0, 0
        -- turning the camera around the unit keeps its distance from the unit's centre
        local keepDepth
        if not fit then
            local fov0, eye0 = ed_camera_info()
            if fov0 then
                local _, _, _, s0 = FocusFor(cx, cy, cz, oldHeading, oldPitch, gy, 0, 0, 0)
                keepDepth = eye0 - s0
            end
        end
        for i = 1, 5 do
            local fx, fy, fz = FocusFor(cx, cy, cz, heading, pitch, gy, ox, oy, upp)
            cam:SnapTo(Vector(fx, fy, fz), { heading, pitch, 0 }, zoom)
            WaitSeconds(0.08)
            if mine ~= aiming or not Id then return end
            local fov, eye, _, _, _, _, _, _, vx, vy, vw, vh = ed_camera_info()
            if not fov then Log('aimcam', 'Aim: ed_camera_info answers nothing (no world camera?)') return end
            local _, _, _, s = FocusFor(cx, cy, cz, heading, pitch, gy, 0, 0, 0)
            local depth = eye - s                                       -- from the eye to the unit's centre along the line of sight
            upp = 2 * depth * math.tan(fov / 2) / vh
            if left then
                ox = (left + right) / 2 - (vx + vw / 2)
                oy = (top + bottom) / 2 - (vy + vh / 2)
            end
            if keepDepth then
                zoom = zoom * (keepDepth + s) / eye
                local lo, hi = cam:GetMinZoom() or 1, cam:GetMaxZoom() or 1000
                zoom = math.max(lo, math.min(hi, zoom))
            elseif fit then
                local pw, ph = vw, vh
                if left then pw, ph = right - left, bottom - top end
                local wantUpp = 2.2 * radius / math.min(pw, ph)
                local wantDepth = wantUpp * vh / (2 * math.tan(fov / 2))
                zoom = zoom * (wantDepth + s) / eye          -- the eye must be the wanted depth in front of the unit plus the distance on to the focus
                local lo, hi = cam:GetMinZoom() or 1, cam:GetMaxZoom() or 1000
                zoom = math.max(lo, math.min(hi, zoom))
            end
        end
        Zoom = zoom
        aimUntil = GetSystemTimeSeconds() + 0.1
    end)
end

--- Holds the camera on the unit (Tick calls it every frame; it needs the unit shown and framed, not the sim's answer: a slow sim must not leave the camera free): the focus point is put back where the line of sight meets the unit's centre, so right-drag panning and the move keys do nothing, while rotating and
--- the wheel work around the unit. The pitch stays between 0.05 and 1.5, the eye between 1.3 and 40 radii from the centre.
function LockCamera()
    if not (Show.lock and Id and lockC) or iconLens or GetSystemTimeSeconds() < aimUntil then return end
    local fov, eye, fx, fy, fz, hd, pt, tz, vx, vy, vw, vh = ed_camera_info()
    if not fov or not vh or vh <= 0 then return end
    hd = NormHeading(hd)
    local cx, cy, cz, radius = lockC[1], lockC[2], lockC[3], lockC[4]
    local cam = GetCamera('WorldCamera')
    local gy = Ground(X, Z)
    local p = math.max(0.05, math.min(1.5, pt))
    local _, _, _, s = FocusFor(cx, cy, cz, hd, p, gy, 0, 0, 0)
    local depth = eye - s
    local ox, oy = 0, 0
    local left, top, right, bottom = PanelRect()
    if left then
        ox = (left + right) / 2 - (vx + vw / 2)
        oy = (top + bottom) / 2 - (vy + vh / 2)
    end
    local upp = 2 * math.max(depth, 0.1) * math.tan(fov / 2) / vh
    local gx, gyy, gz = FocusFor(cx, cy, cz, hd, p, gy, ox, oy, upp)
    local dx, dy, dz = gx - fx, gyy - fy, gz - fz
    local err = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- the eye's distance from the unit's centre: too close sees inside the model, too far loses it
    local want = tz
    if depth > 0 then
        local lo, hi = radius * 1.3, radius * 40
        if depth < lo then want = tz * (lo + s) / eye elseif depth > hi then want = tz * (hi + s) / eye end
    end
    local zoomOff = want ~= tz
    if err > math.max(0.05, 0.02 * math.max(depth, 1)) or p ~= pt or zoomOff then
        Heading, Pitch = hd, p
        cam:SnapTo(Vector(gx, gyy, gz), { hd, p, 0 }, want)
    else
        Heading, Pitch = hd, pt
    end
end

--- Every frame (camera.lua Update calls it after the held keys, overlay.lua OnFrame calls it too: whichever of the two runs): LockCamera, not twice in one frame, and a failure is logged
--- ('EDITOR unitview: LockCamera failed: ...') instead of silently leaving the camera free.
function Tick()
    if not (Show.lock and Id and lockC) then return end
    local now = GetSystemTimeSeconds()
    if now - lastLockAt < 0.004 then return end
    lastLockAt = now
    local ok, err = pcall(LockCamera)
    if not ok then Log('lock', 'LockCamera failed: ' .. tostring(err)) end
end

local PRESETS = { iso = { 3.7, 0.55 }, unit = { 3.7, 0.55 }, front = { 3.1416, 0.12 }, back = { 0, 0.12 }, side = { 4.7124, 0.12 }, top = { 3.1416, 1.45 } }

--- Frames the unit: 'iso' 3/4 from the front left, 'front', 'back', 'side', 'top', 'range' (far enough out for the largest ring, from above).
function Frame(mode)
    local bp = Id and __blueprints and __blueprints[Id]
    if not bp then return end
    if mode == 'range' then
        local far = 0
        for _, w in bp.Weapon or {} do if w.MaxRadius and w.MaxRadius > far then far = w.MaxRadius end end
        for _, k in { 'VisionRadius', 'RadarRadius', 'SonarRadius', 'OmniRadius' } do
            local r = bp.Intel and bp.Intel[k]
            if Show.senses and r and r > far then far = r end
        end
        local cx, cy, cz = Bounds()
        -- fit a sphere of the ring radius
        local fake = far * 1.05
        ForkThread(function()
            local saveInfo = Info
            Info = { ext = { X - fake, Y0, Z - fake, X + fake, Y0 + 1, Z + fake } }
            Aim(Heading, 1.2, true)
            WaitSeconds(0.6)
            Info = saveInfo
        end)
        return
    end
    local p = PRESETS[mode or 'iso'] or PRESETS.iso
    Aim(p[1], p[2], true)
end

--- Turns the camera around the unit's centre.
function Orbit(dHeading, dPitch)
    local p = math.max(0.05, math.min(1.5, Pitch + (dPitch or 0)))
    Aim(Heading + (dHeading or 0), p, false)
end

--- Fits the unit into the panel again from the angle the camera has.
function Fit()
    Aim(Heading, Pitch, true)
end

-- ---- animations ------------------------------------------------------------------------------------------------------------------------------------

--- The animations the blueprint names: Display.Animation* strings, and the death animations (a list of { Animation = path }).
function Animations(id)
    local list = {}
    local bp = __blueprints and __blueprints[id]
    local display = bp and bp.Display
    if not display then return list end
    for k, v in display do
        if type(k) == 'string' and string.find(k, '^Animation') then
            if type(v) == 'string' then
                table.insert(list, { label = string.gsub(k, '^Animation', ''), path = v })
            elseif type(v) == 'table' then
                for i, e in v do
                    local path = type(e) == 'table' and e.Animation or (type(e) == 'string' and e)
                    if path then table.insert(list, { label = string.gsub(k, '^Animation', '') .. ' ' .. tostring(i), path = path }) end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

local function Anim(data)
    data.bp, data.x, data.z = Id, X, Z
    SimCallback({ Func = 'EdAnim', Args = data }, false)
end

function Play(path, loop)
    if Id then Anim({ path = path, loop = loop and true or false, rate = Rate }) end
end

function SetRate(rate)
    Rate = rate
    if Id then Anim({ rate = rate }) end
end

--- Jumps to a point of the animation (0..1) and holds it.
function Scrub(fraction)
    if Id then Anim({ fraction = fraction }) end
end

function Stop()
    if Id then Anim({ stop = true }) end
end

-- ---- LOD -------------------------------------------------------------------------------------------------------------------------------------------

--- The mesh LODs of the unit blueprint: list of { index, cutoff, from } (the camera distances a LOD is used for: from the previous cutoff up to its own).
function LODs(id)
    local bp = __blueprints and __blueprints[id]
    local lods = bp and bp.Display and bp.Display.Mesh and bp.Display.Mesh.LODs
    local list = {}
    local previous = 0
    for i, l in lods or {} do
        local cutoff = l.LODCutoff or 0
        table.insert(list, { index = i, cutoff = cutoff, from = previous })
        if cutoff > previous then previous = cutoff end
    end
    return list
end

--- Puts the camera at a distance where the engine uses LOD n: the middle of its range, measured from the eye to the unit's centre along the line of sight (what the engine compares with LODCutoff).
--- A thread. LODInfo = { n, target, depth, from, cutoff, reached }: `reached` is false when the camera's zoom limits do not allow that distance.
function ShowLOD(n)
    local list = LODs(Id)
    local lod = list[n]
    if not lod then return nil, 'the blueprint has no LOD ' .. tostring(n) end
    local target = lod.cutoff > lod.from and (lod.from + lod.cutoff) / 2 or lod.from * 1.33
    if n == 1 then target = math.max(1, lod.cutoff / 2) end
    ForkThread(function()
        local cam = GetCamera('WorldCamera')
        local cx, cy, cz = Bounds()
        if not cx then return end
        local gy = Ground(X, Z)
        local zoom = math.max(cam:GetTargetZoom() or 10, 3)
        local depth = 0
        for i = 1, 6 do
            local fx, fy, fz, s = FocusFor(cx, cy, cz, Heading, Pitch, gy, 0, 0, 0)
            cam:SnapTo(Vector(fx, fy, fz), { Heading, Pitch, 0 }, zoom)
            WaitSeconds(0.08)
            local fov, eye = ed_camera_info()
            if not fov then return end
            depth = eye - s
            zoom = zoom * (target + s) / eye
            local lo, hi = cam:GetMinZoom() or 1, cam:GetMaxZoom() or 1000
            zoom = math.max(lo, math.min(hi, zoom))
        end
        LODInfo = { n = n, target = target, depth = depth, from = lod.from, cutoff = lod.cutoff, reached = math.abs(depth - target) < target * 0.05 }
    end)
    return target
end

-- ---- team colour and light presets -----------------------------------------------------------------------------------------------------------------

Colors = {
    { name = 'Army', rgb = false },
    { name = 'Red', rgb = { 200, 40, 40 } }, { name = 'Blue', rgb = { 50, 90, 220 } }, { name = 'Green', rgb = { 50, 180, 60 } },
    { name = 'Yellow', rgb = { 230, 210, 50 } }, { name = 'White', rgb = { 235, 235, 240 } }, { name = 'Black', rgb = { 25, 25, 30 } },
}
ColorName = 'Army'

--- Team colour of the unit viewer's army (ARMY_1): a preset by name. The colour is read when a unit is made, so the shown unit is made again (the camera stays).
function SetColor(name)
    for _, c in Colors do
        if c.name == name then
            if c.rgb then
                SimCallback({ Func = 'EdArmyColor', Args = { army = 'ARMY_1', r = c.rgb[1], g = c.rgb[2], b = c.rgb[3] } }, false)
            else
                local index = 1
                Safe.Try('unitview:fn826', function()
                    local a = import('/lua/editor/armysetup.lua').Get('ARMY_1')
                    if a and a.color then index = a.color end
                end)
                SimCallback({ Func = 'EdArmyColor', Args = { army = 'ARMY_1', index = index } }, false)
            end
            ColorName = name
            if Id then Spawn(Id, true) end
            return true
        end
    end
    return false
end

Lights = {
    { name = 'Map' },
    { name = 'Noon', set = { light_mult = 1.5, sun_x = 0.2, sun_y = 0.95, sun_z = -0.2, sun_r = 1, sun_g = 1, sun_b = 1, ambient_r = 0.3, ambient_g = 0.3, ambient_b = 0.3, fill_r = 0.7, fill_g = 0.7, fill_b = 0.7 } },
    { name = 'Evening', set = { light_mult = 1.5, sun_x = 0.9, sun_y = 0.25, sun_z = -0.3, sun_r = 1, sun_g = 0.7, sun_b = 0.45, ambient_r = 0.25, ambient_g = 0.22, ambient_b = 0.3, fill_r = 0.5, fill_g = 0.45, fill_b = 0.55 } },
    { name = 'Overcast', set = { light_mult = 1.2, sun_x = 0, sun_y = 1, sun_z = 0, sun_r = 0.6, sun_g = 0.6, sun_b = 0.62, ambient_r = 0.55, ambient_g = 0.55, ambient_b = 0.58, fill_r = 0.8, fill_g = 0.8, fill_b = 0.82 } },
    { name = 'Night', set = { light_mult = 0.7, sun_x = -0.3, sun_y = 0.6, sun_z = 0.4, sun_r = 0.35, sun_g = 0.45, sun_b = 0.8, ambient_r = 0.15, ambient_g = 0.18, ambient_b = 0.3, fill_r = 0.3, fill_g = 0.35, fill_b = 0.5 } },
    { name = 'Icon', set = { light_mult = 2.0, sun_x = -0.5, sun_y = 0.7, sun_z = 0.5, sun_r = 1, sun_g = 1, sun_b = 1, ambient_r = 0.35, ambient_g = 0.35, ambient_b = 0.4, fill_r = 0.9, fill_g = 0.9, fill_b = 0.95 } },
}
LightName = 'Map'
local mapLight = false

--- Lighting preset of the map (the sun, ambient and fill numbers; one undo step). 'Map' puts back what the map had when the first preset was used.
function SetLight(name)
    local World = import('/lua/editor/world.lua')
    for _, l in Lights do
        if l.name == name then
            if not mapLight then
                mapLight = {}
                for _, k in { 'light_mult', 'sun_x', 'sun_y', 'sun_z', 'sun_r', 'sun_g', 'sun_b', 'ambient_r', 'ambient_g', 'ambient_b', 'fill_r', 'fill_g', 'fill_b' } do mapLight[k] = World.Value(k) end
            end
            World.Change(l.set or mapLight, { label = 'unit viewer light: ' .. name })
            LightName = name
            return true
        end
    end
    return false
end

-- ---- hooks -----------------------------------------------------------------------------------------------------------------------------------------

--- Called by the shell when the workspace changes: the viewer lives in the Mod workspace only.
function OnWorkspace(name)
    if name ~= 'Mod' and (Id or saved or origCamera) then Close() end
end

-- a fresh session (map opened, mods applied, a test run stopped) starts with the map's terrain showing: the flags are the engine's, not the Lua state's
if not saved then Flags(true) end
