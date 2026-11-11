-- Water bodies (lakes at their own levels, ScenarioInfo.WaterBodies, faf-re docs/WATER_BODIES.md) and shore wave generators of the open map. The fill and the wave section are the
-- engine's and upstream's (faf-re src/editor/doc/EdWaterBodies, src/editor/tools/EdWaves, bound as ed_waterbodies_* and ed_waves_* in moho/editor/EdUpWaterLua.cpp); this module
-- holds the editor's model, every change as one undo step, and the clicks that place a body's seed and outline. Panels: gui/panels_waterbodies.lua. `.scmwtr` is fafme.lua's.
--
-- A body is a table of the scenario's own fields, kept in Map.Doc.info.WaterBodies (saved with the scenario by map.lua / textsave.lua):
--   { Elevation = 30, Seed = { 512, 512 }, FillTo = 31, Deep = 28, Abyss = 20, Dry = true, Outline = { { x, z }, ... }, Bounds = { x0, z0, x1, z1 } }   (a field left out stays out)
-- The open map shows the bodies as the game fills them: every edit fills again (ed_waterbodies_fill with install) and the water, its shore and the water map follow. A height edit fills
-- again when the stroke is over. The game needs sim_FixWaterBodies for a map's bodies: it is switched on as soon as a map has some (a Play of the editor is never a multiplayer game).
--
--   Bodies() / Count() / Selected / Select(i)                  the list, its size, the body the panel edits
--   Add([x, z])  Duplicate(i)  Remove(i)                      a new body (seed at x, z; else at the camera's target; level at the ground there + 2), a copy, one removed
--   Set(i, field, value)  Clear(i, field)  SetSeed(i, x, z)    one number field (Elevation, FillTo, Deep, Abyss); a field taken out; the seed
--   SetDry(i, on)  AddOutlinePoint(i, x, z)  MovePoint(i, k, x, z)  ClearOutline(i)  SetBounds(i, x0, z0, x1, z1)  ClearBounds(i)
--   Report[i]                                                  what the last fill said about body i: { cells, skipped, message }, Other = the lines that belong to no body
--   Apply()                                                    fills the document's bodies over the heights and puts them on the open map
--   Mode  'seed' | 'outline' | false                          what a click of the Water body tool does (Press)
--   Draw()                                                     the seeds, outlines and bounds over the ground (overlay), when Guides is on
--   Waves: Waves() / SetWaves(list, label) / Generate(opts, mode) / ExportWaves([path]) / ImportWaves([path]) / WaveCount()
--
-- Lua 5.0 dialect.

local function Map() return import('/lua/editor/map.lua') end
local function History() return import('/lua/editor/history.lua') end

Selected = 0
Mode = false
Guides = true
Report = {}
Other = {}
local listeners = {}
local appliedRevision = -1         -- the heights' revision the fill on the map was made for
local lastEdit = false             -- { key, version, state } of the latest undo entry this module pushed (a drag of one slider is one step)
local pending = false
local watching = false
local simfix = false

function Listen(fn) table.insert(listeners, fn) end

local function Changed()
    for _, fn in listeners do pcall(fn) end
end

function Available() return rawget(_G, 'ed_waterbodies_fill') ~= nil and Map().Doc ~= false and Map().Doc ~= nil end

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR water: ' .. text)
end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in v do out[k] = Copy(x) end
    return out
end

function Bodies()
    local doc = Map().Doc
    if not doc or not doc.info then return {} end
    return doc.info.WaterBodies or {}
end

function Count() return table.getn(Bodies()) end

local function MapSize()
    local w, h = ed_terrain_info()
    return (w or 257) - 1, (h or 257) - 1
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

-- ---- the fill ------------------------------------------------------------------------------------------------------------------------------------

--- Fills the document's bodies and puts them on the map; the reports of the fill are kept in Report / Other.
function Apply()
    pending = false
    if not Available() then return false end
    local list = Bodies()
    if table.getn(list) > 0 and not simfix then
        simfix = true
        if rawget(_G, 'ed_waterbodies_simfix') then ed_waterbodies_simfix(true) end
    end
    local res, why = ed_waterbodies_fill(list, { install = true })
    if not res then
        Report, Other = {}, { why or 'the bodies could not be filled' }
        Changed()
        return false
    end
    Report = res.bodies or {}
    Other = res.other or {}
    local _, _, _, rev = ed_cmd_depth()
    appliedRevision = rev or -1
    Changed()
    return true
end

--- A fill soon: a slider moving makes many edits, one fill a moment after the last is enough.
local function Soon()
    pending = true
    if watching == 'soon' then return end
    local was = watching
    watching = 'soon'
    ForkThread(function()
        WaitSeconds(0.15)
        if pending then Apply() end
        watching = was
    end)
end

--- Follows the heights: after the editor's height edits (a stroke, undo, redo) the bodies are filled again over the new ground. A thread polls the document's revision; it fills when
--- the revision has stayed the same for a moment (not during a stroke).
local function Watch()
    if watching == true then return end
    if watching == 'soon' then return end
    watching = true
    ForkThread(function()
        local last = -1
        while true do
            WaitSeconds(0.3)
            if not Available() or Count() == 0 then
                watching = false
                return
            end
            local _, _, _, rev = ed_cmd_depth()
            if rev == last and rev ~= appliedRevision then
                Apply()
            end
            last = rev
        end
    end)
end

--- At the start of a session (control.lua): the bodies of the map's scenario go on the open map, and a thread follows the heights.
function Start()
    Selected = 0
    Mode = false
    Report, Other = {}, {}
    lastEdit = false
    watching = false
    simfix = false
    appliedRevision = -1
    if Available() and Count() > 0 then
        Selected = 1
        Apply()
        Watch()
    end
end

-- ---- edits ---------------------------------------------------------------------------------------------------------------------------------------

local function SetList(list)
    local info = Map().Doc.info
    if table.getn(list) == 0 then info.WaterBodies = nil else info.WaterBodies = list end
end

--- Sets the list to `after` as one undo step; the same `key` again right after (the same slider still moving) only changes that step.
local function Commit(key, label, after, immediate)
    local doc = Map().Doc
    if not doc then return false end
    local H = History()
    if lastEdit and key and lastEdit.key == key and lastEdit.version == H.Version then
        lastEdit.state.after = Copy(after)
        SetList(Copy(after))
    else
        local state = { before = Copy(Bodies()), after = Copy(after), selected = Selected }
        SetList(Copy(after))
        H.Push({
            label = label,
            undo = function() SetList(Copy(state.before)); if Selected > table.getn(state.before) then Selected = table.getn(state.before) end; Apply(); Watch() end,
            redo = function() SetList(Copy(state.after)); Apply(); Watch() end,
        })
        lastEdit = { key = key, version = H.Version, state = state }
    end
    if immediate then Apply() else Soon() end
    Watch()
    Changed()
    return true
end

local function Edit(i, key, label, fn, immediate)
    local list = Copy(Bodies())
    local body = list[i]
    if not body then return false end
    fn(body)
    return Commit(key and (key .. i) or false, label, list, immediate)
end

function Select(i)
    local n = Count()
    if n == 0 then Selected = 0 else Selected = math.max(1, math.min(n, i)) end
    Changed()
end

local function CameraTarget()
    local ok, x, z = pcall(function()
        local cam = GetCamera('WorldCamera')
        local pos = cam and cam:GetFocusPosition()
        if pos then return pos[1], pos[3] end
    end)
    if ok and x then return x, z end
    local mw, mh = MapSize()
    return mw / 2, mh / 2
end

function Add(x, z)
    if not Map().Doc then return false end
    if not x then x, z = CameraTarget() end
    x, z = math.floor(x + 0.5), math.floor(z + 0.5)
    local list = Copy(Bodies())
    table.insert(list, { Elevation = math.floor((Ground(x, z) + 2) * 2 + 0.5) / 2, Seed = { x, z } })
    Selected = table.getn(list)
    Commit(false, 'add a water body', list, true)
    return true
end

function Duplicate(i)
    local list = Copy(Bodies())
    local body = list[i]
    if not body then return false end
    local twin = Copy(body)
    if twin.Seed then twin.Seed = { twin.Seed[1] + 10, twin.Seed[2] + 10 } end
    table.insert(list, i + 1, twin)
    Selected = i + 1
    return Commit(false, 'duplicate a water body', list, true)
end

function Remove(i)
    local list = Copy(Bodies())
    if not list[i] then return false end
    table.remove(list, i)
    if Selected > table.getn(list) then Selected = table.getn(list) end
    return Commit(false, 'remove a water body', list, true)
end

local NUMBERS = { Elevation = true, FillTo = true, Deep = true, Abyss = true }

function Set(i, field, value)
    if not NUMBERS[field] then return false end
    return Edit(i, field, 'water body ' .. string.lower(field), function(b) b[field] = value end)
end

function Clear(i, field)
    return Edit(i, 'clear' .. field, 'water body: ' .. string.lower(field) .. ' off', function(b) b[field] = nil end, true)
end

function SetDry(i, on)
    return Edit(i, 'dry', on and 'dry water body' or 'wet water body', function(b)
        if on then
            b.Dry = true
            if b.FillTo == nil then b.FillTo = b.Elevation or 0 end
        else
            b.Dry = nil
        end
    end, true)
end

function SetSeed(i, x, z)
    x, z = math.floor(x + 0.5), math.floor(z + 0.5)
    return Edit(i, 'seed', 'move a water body seed', function(b) b.Seed = { x, z } end, true)
end

function ClearSeed(i)
    return Edit(i, 'clearseed', 'remove a water body seed', function(b) b.Seed = nil end, true)
end

function AddOutlinePoint(i, x, z)
    x, z = math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
    return Edit(i, false, 'add an outline point', function(b)
        b.Outline = b.Outline or {}
        table.insert(b.Outline, { x, z })
    end, true)
end

function MovePoint(i, k, x, z)
    x, z = math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
    return Edit(i, 'point' .. k, 'move an outline point', function(b)
        if b.Outline and b.Outline[k] then b.Outline[k] = { x, z } end
    end, true)
end

function ClearOutline(i)
    return Edit(i, 'clearoutline', 'clear the outline of a water body', function(b) b.Outline = nil end, true)
end

function SetBounds(i, x0, z0, x1, z1)
    local mw, mh = MapSize()
    x0, x1 = math.max(0, math.min(mw, math.floor(math.min(x0, x1)))), math.max(0, math.min(mw, math.floor(math.max(x0, x1))))
    z0, z1 = math.max(0, math.min(mh, math.floor(math.min(z0, z1)))), math.max(0, math.min(mh, math.floor(math.max(z0, z1))))
    return Edit(i, 'bounds', 'water body bounds', function(b) b.Bounds = { x0, z0, x1, z1 } end)
end

function ClearBounds(i)
    return Edit(i, 'clearbounds', 'remove the bounds of a water body', function(b) b.Bounds = nil end, true)
end

-- ---- the Water body tool -------------------------------------------------------------------------------------------------------------------------

local function ScreenToWorld(x, y)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    local p = UnProject(view, Vector2(x, y))
    if p then return p[1], p[3] end
    return nil
end

--- The tool's click (ui.lua tool.OnPress): seed mode puts the seed of the selected body where the click is (and follows the pointer until the button is released); outline mode adds a
--- point to the outline, or picks up the point under the click and moves it.
function Press(wx, wz, event)
    local i = Selected
    local body = Bodies()[i]
    if not body or not Mode then
        Say('select a water body in the Water bodies panel, then Pick seed or Draw outline')
        return false
    end
    local Dragger = import('/lua/maui/dragger.lua').Dragger
    if Mode == 'seed' then
        SetSeed(i, wx, wz)
        local dragger = Dragger()
        dragger.OnMove = function(self, x, y)
            local mx, mz = ScreenToWorld(x, y)
            if mx then Edit(i, 'seed', 'move a water body seed', function(b) b.Seed = { math.floor(mx + 0.5), math.floor(mz + 0.5) } end) end
        end
        dragger.OnRelease = function(self, x, y) self:Destroy() end
        dragger.OnCancel = function(self) self:Destroy() end
        PostDragger(GetFrame(0), event.KeyCode, dragger)
        return true
    end
    -- outline
    local picked = false
    local near = 4
    for k, p in (body.Outline or {}) do
        if math.abs(p[1] - wx) < near and math.abs(p[2] - wz) < near then picked = k; near = math.max(math.abs(p[1] - wx), math.abs(p[2] - wz)) end
    end
    if not picked then
        AddOutlinePoint(i, wx, wz)
        return true
    end
    local dragger = Dragger()
    dragger.OnMove = function(self, x, y)
        local mx, mz = ScreenToWorld(x, y)
        if mx then MovePoint(i, picked, mx, mz) end
    end
    dragger.OnRelease = function(self, x, y) self:Destroy() end
    dragger.OnCancel = function(self) self:Destroy() end
    PostDragger(GetFrame(0), event.KeyCode, dragger)
    return true
end

-- ---- guides on the map ---------------------------------------------------------------------------------------------------------------------------

local drawn = {}

local function DrawLine(id, pts, color, width, closed)
    drawn[id] = true
    ed_overlay_set(id, pts, color, width, 1, 3, closed, true)
end

--- Seeds (a pin), outlines (the curve the game fills inside), and bounds (the rectangle) of the bodies, drawn over the ground; the chosen body brighter.
function Draw()
    if not rawget(_G, 'ed_overlay_set') then return end
    local seen = {}
    if Guides and Map().Doc then
        for i, b in Bodies() do
            local chosen = (i == Selected)
            local color = b.Dry and (chosen and 'FFE0B060' or '90E0B060') or (chosen and 'FF50C8FF' or '9050C8FF')
            local level = b.Dry and -1e9 or (b.Elevation or -1e9)
            local function At(x, z, lift) return math.max(Ground(x, z), level) + lift end
            if b.Outline and table.getn(b.Outline) >= 3 then
                local pts = {}
                local n = table.getn(b.Outline)
                -- the spline is the engine's (Catmull-Rom, 8 steps a span); the guide draws the control polygon through the points, smoothed by the same curve
                for k = 1, n do
                    local p0, p1, p2, p3 = b.Outline[math.mod(k + n - 2, n) + 1], b.Outline[k], b.Outline[math.mod(k, n) + 1], b.Outline[math.mod(k + 1, n) + 1]
                    for s = 0, 7 do
                        local t = s / 8
                        local t2, t3 = t * t, t * t * t
                        local function C(a)
                            return 0.5 * ((2 * p1[a]) + (p2[a] - p0[a]) * t + (2 * p0[a] - 5 * p1[a] + 4 * p2[a] - p3[a]) * t2 + (3 * p1[a] - p0[a] - 3 * p2[a] + p3[a]) * t3)
                        end
                        local x, z = C(1), C(2)
                        table.insert(pts, x); table.insert(pts, At(x, z, 0.5)); table.insert(pts, z)
                    end
                end
                seen['wb:o' .. i] = true
                DrawLine('wb:o' .. i, pts, color, 0.5, true)
            elseif b.Outline and table.getn(b.Outline) > 0 then
                local pts = {}
                for _, p in b.Outline do table.insert(pts, p[1]); table.insert(pts, At(p[1], p[2], 0.5)); table.insert(pts, p[2]) end
                seen['wb:o' .. i] = true
                DrawLine('wb:o' .. i, pts, color, 0.5, false)
            end
            if chosen and b.Outline then
                for k, p in b.Outline do
                    local y = At(p[1], p[2], 0.8)
                    local r = 1.2
                    seen['wb:h' .. k] = true
                    DrawLine('wb:h' .. k, { p[1] - r, y, p[2] - r, p[1] + r, y, p[2] - r, p[1] + r, y, p[2] + r, p[1] - r, y, p[2] + r }, 'FFFFFFFF', 0.4, true)
                end
            end
            if b.Seed then
                local sx, sz = b.Seed[1], b.Seed[2]
                local base = Ground(sx, sz)
                local top = math.max(base, level) + 6
                seen['wb:s' .. i] = true
                DrawLine('wb:s' .. i, { sx, base, sz, sx, top, sz }, color, chosen and 0.9 or 0.5, false)
            end
            if b.Bounds then
                local x0, z0, x1, z1 = b.Bounds[1], b.Bounds[2], b.Bounds[3], b.Bounds[4]
                local pts = {}
                local function Side(ax, az, bx, bz)
                    local steps = math.max(1, math.floor(math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)) / 4))
                    for s = 0, steps - 1 do
                        local x, z = ax + (bx - ax) * s / steps, az + (bz - az) * s / steps
                        table.insert(pts, x); table.insert(pts, At(x, z, 0.5)); table.insert(pts, z)
                    end
                end
                Side(x0, z0, x1, z0); Side(x1, z0, x1, z1); Side(x1, z1, x0, z1); Side(x0, z1, x0, z0)
                seen['wb:b' .. i] = true
                DrawLine('wb:b' .. i, pts, chosen and 'FFFFFFFF' or '60FFFFFF', 0.3, true)
            end
        end
    end
    for id, _ in drawn do
        if not seen[id] then
            ed_overlay_remove(id)
            drawn[id] = nil
        end
    end
end

-- ---- wave generators -----------------------------------------------------------------------------------------------------------------------------

local waveShown = {}
WaveGuides = false

function WaveCount()
    if not rawget(_G, 'ed_waves_get') then return 0 end
    local list = ed_waves_get()
    return list and table.getn(list) or 0
end

function Waves()
    if not rawget(_G, 'ed_waves_get') then return {} end
    return ed_waves_get() or {}
end

--- Puts `list` on the map as one undo step (the generators before and after are kept: a retail map has thousands, a few steps are enough).
function SetWaves(list, label)
    if not rawget(_G, 'ed_waves_set') then return false end
    local before = Waves()
    local ok, why = ed_waves_set(list)
    if not ok then
        Say('waves: ' .. tostring(why))
        return false
    end
    local H = History()
    H.Push({
        label = label or 'wave generators',
        undo = function() ed_waves_set(before); DrawWaves() end,
        redo = function() ed_waves_set(list); DrawWaves() end,
        bytes = (table.getn(before) + table.getn(list)) * 300,
    })
    DrawWaves()
    Changed()
    return true
end

--- Generators along the shore of the sea (upstream's rule: the cells where the ground crosses `depth` below the water, facing uphill). opts: pattern (a table of ed_waves_patterns),
--- depth, centre / range (degrees, the direction of the shore: 180 and 180 = all), density, spacing, seed. mode 'replace' puts them in place of the map's generators, 'add' keeps those.
function Generate(opts, mode)
    if not rawget(_G, 'ed_waves_generate') then return nil, 'this editor build has no wave generators' end
    local res, why = ed_waves_generate(opts)
    if not res then Say('waves: ' .. tostring(why)); return nil, why end
    local list = res.waves
    if mode == 'add' then
        local all = Waves()
        for _, w in list do table.insert(all, w) end
        list = all
    end
    if not SetWaves(list, mode == 'add' and 'add shore waves' or 'make shore waves') then return nil end
    Say(string.format('waves: %d generators made on %d shore points (%d found)', res.picked, res.picked, res.shorePoints))
    return res
end

--- The generators as short lines on the water: each starts where the wave is born and points the way it travels (up to 400 are drawn).
function DrawWaves()
    if not rawget(_G, 'ed_overlay_set') then return end
    local seen = {}
    if WaveGuides then
        local list = Waves()
        local n = math.min(400, table.getn(list))
        local step = table.getn(list) > 400 and (table.getn(list) / 400) or 1
        for k = 1, n do
            local w = list[math.floor((k - 1) * step) + 1]
            local a = (w.angle or 0) - math.pi / 2
            local x, y, z = w.position[1], w.position[2], w.position[3]
            local id = 'wv:' .. k
            seen[id] = true
            waveShown[id] = true
            ed_overlay_set(id, { x, y + 0.3, z, x + math.cos(a) * 6, y + 0.3, z + math.sin(a) * 6 }, 'FFFFFFFF', 0.4, 1, 2, false, true)
        end
    end
    for id, _ in waveShown do
        if not seen[id] then
            ed_overlay_remove(id)
            waveShown[id] = nil
        end
    end
end

local FILTER = 'FAFME waves (*.scmwaves)|*.scmwaves|All files|*.*'

function ExportWaves(path)
    if not rawget(_G, 'ed_waves_write') then return nil, 'this editor build has no wave generators' end
    if not path and rawget(_G, 'ed_file_dialog') then path = ed_file_dialog(true, 'Export wave generators', FILTER, 'waves.scmwaves') end
    if not path or path == '' then return nil, 'cancelled' end
    local ok = ed_write_file(path, ed_waves_write(Waves()))
    if not ok then Say('waves: could not write ' .. path); return nil, 'could not write ' .. path end
    Say(string.format('waves: %d generators written to %s', WaveCount(), path))
    return true, path
end

function ImportWaves(path)
    if not rawget(_G, 'ed_waves_read') then return nil, 'this editor build has no wave generators' end
    if not path and rawget(_G, 'ed_file_dialog') then path = ed_file_dialog(false, 'Import wave generators', FILTER, '') end
    if not path or path == '' then return nil, 'cancelled' end
    local text = ed_read_file(path)
    if not text then Say('waves: could not read ' .. path); return nil, 'could not read ' .. path end
    local list, why = ed_waves_read(text)
    if not list then Say('waves: ' .. tostring(why)); return nil, why end
    if not SetWaves(list, 'import wave generators') then return nil end
    Say(string.format('waves: %d generators imported from %s', table.getn(list), path))
    return true, path
end
