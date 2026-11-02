-- In-world overlays of the editor, drawn by the engine's retained line overlay (EdOverlay.cpp, ed_overlay_*): areas as terrain-aligned
-- boxes, selection and hover highlights, resize handles, the brush ring and the placement ghosts under the pointer.
-- Lines get a width in world units and never go thinner than a few pixels, so they stay readable from any camera distance.
-- Marker names are Lua text labels (pooled); the marker meshes themselves are sim props (markervis.lua).
--
-- Update() is called every frame by ui.lua while editing. Static things (areas, selection) are rebuilt only when tools.Changed moves
-- (and every half second, for terrain edits under them); the pointer things are rebuilt every frame.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Cursors = import('/lua/editor/cursors.lua')
local MarkerVis = import('/lua/editor/markervis.lua')
local MC = import('/lua/editor/markercheck.lua')
local MeshView = import('/lua/editor/meshview.lua')
local Playable = import('/lua/editor/playable.lua')
local Validate = import('/lua/editor/validate.lua')
local Grid = import('/lua/editor/grid.lua')
local Slope = import('/lua/editor/slope.lua')
local UIUtil = import('/lua/ui/uiutil.lua')
local Group = import('/lua/maui/group.lua').Group

local COLOR_AREA = '30C8FF'
local COLOR_AREA_HOVER = '90E4FF'
local COLOR_SELECT = 'FFE040'
local BRUSH_COLORS = { prop = '40E0A0', prop_erase = 'FF6060', decal = 'E0C040', decal_erase = 'FF6060', raise = '60FF60', lower = 'FF6060', flatten = '60A0FF', smooth = 'F0F0F0', noise = 'FFB040' }

local lastChanged = -1
local lastDoc = false
local engineCleared = false     -- the engine's overlay tables outlive a session: cleared once per session, see Update
local frameCount = 0
local areaIds = {}        -- area name -> true for lines registered
local markerIds = {}      -- marker name -> true for dots registered
local selIds = {}         -- selected marker name -> true for highlight rings registered
local fpIds = {}          -- resource marker name -> true for footprint boxes registered
local lastRevision = -1   -- validation results the footprints were drawn for
local lastHover = -1      -- Tools.HoverRev the highlights were drawn for
local lastEpoch = -1      -- groundEpoch the lines and icons were laid onto the terrain for
-- What each registered object was last drawn for: a rebuild skips the objects whose key did not change (it used to lay every outline onto the terrain again, up to 480
-- terrain reads per area, on every selection, hover and half second).
local areaKeys = {}       -- area name -> key string
local fpKeys = {}         -- resource marker name -> key string
local iconKeys = {}       -- marker name -> { x, y, z, tint, path }
local selKeys = {}        -- selected marker name -> { x, y, z }
local handleKeyT = { false, 0, 0, 0, 0, 0, 0 }    -- what the area handles were laid for
local TerrainEpoch = import('/lua/editor/terrainepoch.lua')
-- The overlay's own "the ground may have changed" counter, `groundEpoch`. TerrainEpoch.Epoch moves on every history step and every 5 seconds as a net, and each move laid every area
-- outline and resource footprint onto the terrain again (a 50-70 ms hitch with 600 resource markers and 40 areas, every 5 s). The ground really changes with the history (a stroke,
-- an undo), a height write that records none (the native height revision, TerrainEpoch.Touch) or a mesh terrain edit; so this one moves with those, and the plain net is 90 s (5 s on
-- a mesh map, whose edits it cannot see). Like the TerrainEpoch it stands still while a stroke is dragged.
local groundEpoch = 0
local ground = { rev = -1, touch = -1, hist = -1, at = -100, mode = -1 }
local Perf = import('/lua/editor/perf.lua')
local gridIds = {}        -- build grid view: line id -> true
local gridKey = ''        -- what the grid lines were built for

-- marker icon files (editor/tools/gen_marker_icons.py): one per template, `army` for start positions, `default` for the rest
local ICON_SLUGS = {
    blank_marker = true, mass = true, hydrocarbon = true, combat_zone = true, defensive_point = true, effect = true,
    expansion_area = true, large_expansion_area = true, naval_area = true, naval_defensive_point = true,
    naval_rally_point = true, protected_experimental_construction = true, rally_point = true, island = true,
    naval_exclude = true, weather_definition = true, weather_generator = true, camera_info = true,
    transport_marker = true, naval_link = true, land_path_node = true, water_path_node = true, air_path_node = true,
    amphibious_path_node = true, army = true, default = true,
}
local ICON_PX = 22

local iconPathOfType = {}      -- marker type -> icon file (the slug work is done once per type)
local ICON_ARMY = '/textures/editor/markers/army.dds'

local function IconPath(name, m)
    if string.sub(name, 1, 5) == 'ARMY_' then return ICON_ARMY end
    local t = m.type or ''
    local path = iconPathOfType[t]
    if not path then
        local slug = 'default'
        local candidate = string.gsub(string.lower(t), ' ', '_')
        if ICON_SLUGS[candidate] then slug = candidate end
        path = '/textures/editor/markers/' .. slug .. '.dds'
        iconPathOfType[t] = path
    end
    return path
end

-- The selected markers and areas as sets, rebuilt when Tools.Changed moved (Tools.IsSelected scans the whole selection: asking it for every marker is quadratic).
local selMarkers, selAreas, selSetAt = {}, {}, -1

local function SelectionSets()
    if selSetAt ~= Tools.Changed then
        selSetAt = Tools.Changed
        selMarkers, selAreas = {}, {}
        for _, it in Tools.Items do
            if it.kind == 'marker' then selMarkers[it.name] = true else selAreas[it.name] = true end
        end
    end
    return selMarkers, selAreas
end
local labelGroup = false
local labels = {}
local handleCount = 0
local ghostLabels = {}     -- names beside the ghosts under the pointer (the Start position tool): entries { name, x, y, z } (reused), the first `ghostN` are current; set by Pointer, drawn by UpdateLabels
local ghostN = 0

-- Editor modules this file calls every frame, imported once (an import() call is a path lookup and a call, 11 of them made 11 closures per frame in DrawLayers). `Mod` returns the
-- module; `Call` runs a function of a module under pcall, like the `pcall(function() import(..).X(..) end)` it replaces (an error in the module is swallowed the same way).
local mods = {}

local function Mod(key, path)
    local m = mods[key]
    if m == nil then
        m = import(path)
        mods[key] = m
    end
    return m
end

local function Call(key, path, fname, a, b)
    local m = mods[key]
    if m == nil then
        local ok, r = pcall(import, path)
        m = ok and r or false
        mods[key] = m
    end
    if m then pcall(m[fname], a, b) end
end

local function Available()
    return rawget(_G, 'ed_overlay_set') ~= nil
end

local function GroundHeight(x, z, coarse)
    -- the ground between the height samples (one per world unit) is a slope: reading the nearest sample made every outline a staircase that sank into the ground and floated
    -- above it by up to half a step, which showed when the camera was close. `coarse` (the long outlines of big areas, seen from far) keeps the one read.
    if coarse then
        return MeshView.GroundAt(x, z, ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0)
    end
    local ix, iz = math.floor(x), math.floor(z)
    local h = ed_terrain_get(ix, iz) or 0
    local fx, fz = x - ix, z - iz
    if fx > 0.001 or fz > 0.001 then
        local h10 = ed_terrain_get(ix + 1, iz) or h
        local h01 = ed_terrain_get(ix, iz + 1) or h
        local h11 = ed_terrain_get(ix + 1, iz + 1) or h
        h = (h * (1 - fx) + h10 * fx) * (1 - fz) + (h01 * (1 - fx) + h11 * fx) * fz
    end
    return MeshView.GroundAt(x, z, h)          -- lines and rings hug the visible ground of a mesh map
end

local function View()
    return Mod('worldview', '/lua/ui/game/worldview.lua').viewLeft
end

-- ---- geometry -------------------------------------------------------------------------------------------------------------------

local LIFT = 0.15     -- lines float a little above the ground

local function Push(pts, x, z, coarse)
    table.insert(pts, x)
    table.insert(pts, GroundHeight(x, z, coarse) + LIFT)
    table.insert(pts, z)
end

--- Circle on the terrain. With `base` (the height under the pointer) every point is kept within `span` of it, so a ring that
--- crosses a steep wall or a spike stays compact instead of streaking up the screen.
local function Circle(cx, cz, r, segs, base, span)
    local pts = {}
    for i = 0, segs - 1 do
        local a = (i / segs) * 6.2831853
        local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
        local y = GroundHeight(x, z)
        if base then y = math.max(base - span, math.min(base + span, y)) end
        table.insert(pts, x)
        table.insert(pts, y + LIFT)
        table.insert(pts, z)
    end
    return pts
end

--- Rectangle outline hugging the terrain: every side is sampled about every 2 world units, a small one (a footprint or skirt of a structure, which is looked at from
--- close by) every half unit with the ground read between the height samples, so it lies on the slope instead of cutting across it.
local function Box(x0, z0, x1, z1)
    local pts = {}
    local small = math.max(x1 - x0, z1 - z0) <= 12
    local function Side(ax, az, bx, bz)
        local len = math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
        local n = math.max(2, math.min(120, math.ceil(len / (small and 0.5 or 2))))
        for i = 0, n - 1 do
            local f = i / n
            Push(pts, ax + (bx - ax) * f, az + (bz - az) * f, not small)
        end
    end
    Side(x0, z0, x1, z0)
    Side(x1, z0, x1, z1)
    Side(x1, z1, x0, z1)
    Side(x0, z1, x0, z0)
    return pts
end

local absent = {}         -- overlay id -> true while it is known not to exist in the engine (Remove skips the native call then)
local ringKeys = {}       -- overlay id -> what the ring of RingAt was laid for

local function Line(set, id, pts, color, width, minPx, maxPx, closed)
    absent[id] = nil
    ringKeys[id] = nil
    ed_overlay_set(id, pts, color, width, minPx, maxPx, closed, true)
end

local function PixelSize(view, mx, my)
    return Mod('viewscale', '/lua/editor/viewscale.lua').PixelSize()
end

-- ---- labels -----------------------------------------------------------------------------------------------------------------------

local function Label(i)
    if not labelGroup then
        labelGroup = Group(GetFrame(0))
        labelGroup.Depth:Set(GetFrame(0).Depth() + 3990)
        labelGroup.Left:Set(0) labelGroup.Top:Set(0) labelGroup.Width:Set(1) labelGroup.Height:Set(1)
        labelGroup:DisableHitTest()
    end
    if not labels[i] then
        local t = UIUtil.CreateText(labelGroup, '', 11, UIUtil.bodyFont)
        t:SetDropShadow(true)
        t:DisableHitTest()
        labels[i] = t
    end
    return labels[i]
end

local labelTop = 0        -- the highest label index that is shown (the ones above it are known to be hidden)

--- Hides the labels from index `i` up (only the ones that were shown: a Hide per pooled label per frame was 150 native calls with nothing to hide).
local function HideLabelsFrom(i)
    for k = i, labelTop do
        local t = labels[k]
        if t and t.shownVis ~= false then
            t:Hide()
            t.shownVis = false
        end
    end
    if i <= labelTop then labelTop = i - 1 end
end

-- ---- static objects ----------------------------------------------------------------------------------------------------------------------

local function RebuildAreas()
    local seen = {}
    local _, selAreaSet = SelectionSets()
    local epoch = groundEpoch
    for name, a in Map.Doc.save.Areas do
        local r = a.rectangle
        if r then
            local selected = selAreaSet[name]
            local hover = Tools.Hover.kind == 'area' and Tools.Hover.name == name
            local color, minPx, width = COLOR_AREA, 2, 0.7
            if selected then color, minPx, width = COLOR_SELECT, 3, 1.1
            elseif hover then color = COLOR_AREA_HOVER end
            -- the outline follows the terrain (up to 480 terrain reads): drawn again only when its colour, its rectangle or the ground changed
            local key = string.format('%s|%.2f|%.2f|%.2f|%.2f|%d', color, r[1], r[2], r[3], r[4], epoch)
            if areaKeys[name] ~= key or not areaIds[name] then
                areaKeys[name] = key
                Line(nil, 'area:' .. name, Box(r[1], r[2], r[3], r[4]), color, width, minPx, 10, true)
            end
            seen[name] = true
        end
    end
    for name, _ in areaIds do
        if not seen[name] then
            ed_overlay_remove('area:' .. name)
            areaKeys[name] = nil
        end
    end
    areaIds = seen
end

local FOOTPRINT_COLOR = { Mass = '9FDCFF', Hydrocarbon = '70E070' }
local ISSUE_COLOR = { blocked = 'FF4040', stacked = 'FFA030', unaligned = 'FFD040' }
local ISSUE_TINT = { blocked = 'FFFF7070', stacked = 'FFFFB060', unaligned = 'FFFFE070' }
local OUTSIDE_TINT = 'A0909098'      -- markers outside the map or the playable area are greyed out

--- Icon position and tint of a marker: outside the map the icon stands on the terrain at the nearest edge, outside the playable area it is greyed.
local function MarkerIcon(name, m, sx, sz, play)
    local x, y, z, kind = MC.DisplayPos(m, sx, sz)
    local tint = ISSUE_TINT[Validate.ByName[name] or ''] or 'FFFFFFFF'
    if kind then
        tint = OUTSIDE_TINT
    elseif play and (x < play[1] or z < play[2] or x > play[3] or z > play[4]) then
        tint = OUTSIDE_TINT
    end
    return x, y, z, tint
end

local function PlayableRect()
    local x0, z0, x1, z1, exists = Playable.Get()
    if exists then return { x0, z0, x1, z1 } end
    return nil
end

--- What the structure of each Mass / Hydrocarbon marker takes, from the unit blueprint: its footprint (the cells it stands on, solid)
--- and its skirt (the area kept clear around it, faint), as terrain-aligned boxes. The marker should sit at the footprint's centre on the
--- build grid. The colour turns red when the validator found the marker blocked, orange when stacked, yellow when off the grid.
local function RebuildFootprints()
    local seen = {}
    local Filter = Mod('markerfilter', '/lua/editor/markerfilter.lua')
    local selMarkerSet = SelectionSets()
    local epoch = groundEpoch
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        local info = Grid.ResourceInfo(m.type)
        -- a hidden marker layer shows nothing of its markers: not the icon, the prop, the name or the footprint rectangles (a selected marker stays visible)
        if info and (not Filter.IsHidden(m.type) or selMarkerSet[name]) then
            local x, z = m.position[1], m.position[3]
            local issue = Validate.ByName[name]
            local color = (issue and ISSUE_COLOR[issue]) or FOOTPRINT_COLOR[m.type] or 'FFFFFF'
            local fx, fz, sk = info.fx / 2, info.fz / 2, info.skirt / 2
            local key = string.format('%s|%.3f|%.3f|%.2f|%.2f|%d|%d', color, x, z, fx, sk, issue and 1 or 0, epoch)
            if fpKeys[name] ~= key then
                fpKeys[name] = key
                Line(nil, 'fp:' .. name, Box(x - fx, z - fz, x + fx, z + fz), color, 0.15, issue and 2 or 1.5, 3, true)
                Line(nil, 'sk:' .. name, Box(x - sk, z - sk, x + sk, z + sk), '70' .. color, 0.1, 1, 1, true)
            end
            seen[name] = true
        end
    end
    for name, _ in fpIds do
        if not seen[name] then
            ed_overlay_remove('fp:' .. name)
            ed_overlay_remove('sk:' .. name)
            fpKeys[name] = nil
        end
    end
    fpIds = seen
end

--- One icon per marker, constant size on screen: distinct per type, visible at any zoom (the 3D props vanish beyond their LOD).
local function RebuildMarkerIcons()
    local seen = {}
    local sx, sz = ed_terrain_info()
    sx, sz = (sx or 257) - 1, (sz or 257) - 1
    local play = PlayableRect()
    local Filter = Mod('markerfilter', '/lua/editor/markerfilter.lua')
    for name, m in Map.Doc.save.MasterChain._MASTERCHAIN_.Markers do
        if not Filter.IsHidden(m.type) then
            local x, y, z, tint = MarkerIcon(name, m, sx, sz, play)
            local path = IconPath(name, m)
            -- only a changed icon is sent to the engine (3000 markers: 3000 native calls and a string per call on every rebuild)
            local k = iconKeys[name]
            if not k then
                k = {}
                iconKeys[name] = k
            end
            if k[1] ~= x or k[2] ~= y or k[3] ~= z or k[4] ~= tint or k[5] ~= path or not markerIds[name] then
                k[1], k[2], k[3], k[4], k[5] = x, y, z, tint, path
                ed_overlay_icon('mi:' .. name, x, y + LIFT, z, path, ICON_PX, tint)
            end
            seen[name] = true
        end
    end
    for name, _ in markerIds do
        if not seen[name] then
            ed_overlay_remove('mi:' .. name)
            iconKeys[name] = nil
        end
    end
    markerIds = seen
end

local function RebuildMarkerHighlights()
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    local seen = {}
    for _, it in Tools.Items do
        local m = it.kind == 'marker' and markers[it.name]
        if m then
            local x, y, z = MC.DisplayPos(m)
            local k = selKeys[it.name]
            if not k then
                k = {}
                selKeys[it.name] = k
            end
            if k[1] ~= x or k[2] ~= y or k[3] ~= z or not selIds[it.name] then
                k[1], k[2], k[3] = x, y, z
                ed_overlay_icon('ms:' .. it.name, x, y + LIFT, z, '/textures/editor/markers/_select.dds', ICON_PX + 12, 'FFFFFFFF')
            end
            seen[it.name] = true
        end
    end
    for name, _ in selIds do
        if not seen[name] then
            ed_overlay_remove('ms:' .. name)
            selKeys[name] = nil
        end
    end
    selIds = seen

    local hov = Tools.Hover
    local selMarkerSet = SelectionSets()
    local m = hov.kind == 'marker' and not selMarkerSet[hov.name] and markers[hov.name]
    if m then
        local x, y, z = MC.DisplayPos(m)
        ed_overlay_icon('mhov', x, y + LIFT, z, '/textures/editor/markers/_hover.dds', ICON_PX + 10, 'FFFFFFFF')
    else
        ed_overlay_remove('mhov')
    end
end

--- The world rectangle { minx, maxx, minz, maxz } that holds the ground seen through the view, with a margin; nil when a corner of the view looks past the ground (the sky).
local function LabelBounds(view)
    local l, t = view.Left(), view.Top()
    local r, b = l + view.Width(), t + view.Height()
    local minx, maxx, minz, maxz
    for i = 1, 4 do
        local p = UnProject(view, Vector2((i == 1 or i == 3) and l or r, (i <= 2) and t or b))
        if not p then return nil end
        minx = minx and math.min(minx, p[1]) or p[1]
        maxx = maxx and math.max(maxx, p[1]) or p[1]
        minz = minz and math.min(minz, p[3]) or p[3]
        maxz = maxz and math.max(maxz, p[3]) or p[3]
    end
    local padx, padz = 30 + 0.15 * (maxx - minx), 30 + 0.15 * (maxz - minz)
    return minx - padx, maxx + padx, minz - padz, maxz + padz
end

-- ---- name labels, kept between frames ------------------------------------------------------------------------------------------------------
-- Zoomed in every marker on screen carries its name. The names used to be worked out from scratch in every frame: a walk over every marker and area (hidden layer test,
-- display position, bounds test, a closure), 8 ms per frame with 3000 markers. Now there are two levels of keys:
--   * the CANDIDATES (the markers and areas that can have a name: inside the ground the camera sees plus a margin, or selected / hovered; with their display positions) are made
--     again when the objects changed (Tools.Changed), the hover moved, the terrain changed (TerrainEpoch), the document or the zoom class changed, the view left the margin, or
--     after a second (a writer that announces nothing);
--   * the SHOWN labels (the first 150 candidates that project onto the screen) are worked out again when the candidates or the camera changed. A camera at rest costs nothing.
-- Only the ghost names of the Start position tool and the ruler's text are looked at in every frame.
local LC = {
    changed = -1, hover = -1, doc = false, epoch = -1, zoomed = false, at = -100,         -- what the candidates were made for
    all = true, bx0 = 0, bx1 = 0, bz0 = 0, bz1 = 0,                                       -- the ground rectangle they cover (all = no limit)
    nm = 0, mname = {}, mx = {}, my = {}, mz = {}, msel = {},                             -- candidate markers (parallel arrays)
    na = 0, aname = {}, ax = {}, ay = {}, az = {}, asel = {},                             -- candidate areas
    cam = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, camPts = false,                          -- the camera key: where three fixed ground points land on the screen, and the view rectangle
    valid = false, shown = 0,                                                              -- the labels 1..shown are those of the candidates and camera above
}

local function LabelsForget()
    LC.valid = false
    LC.changed = -1
    LC.doc = false
    LC.camPts = false
end

--- True when the camera and the view rectangle are those of the last call (and stores them). Three projections: a camera that rests gives bit-identical numbers.
local function CameraSame(view, ox, oy, w, h)
    local pts = LC.camPts
    if not pts then
        local sx, sz = ed_terrain_info()
        sx, sz = (sx or 257) - 1, (sz or 257) - 1
        pts = { Vector(0, 0, 0), Vector(sx, 0, 0), Vector(0, 0, sz) }
        LC.camPts = pts
    end
    local k = LC.cam
    local same = true
    for i = 1, 3 do
        local p = view:Project(pts[i])
        local x, y = p.x, p.y
        if x ~= k[2 * i - 1] or y ~= k[2 * i] or x ~= x then same = false end        -- (a NaN never equals itself: such a frame is worked out again)
        k[2 * i - 1], k[2 * i] = x, y
    end
    if ox ~= k[7] or oy ~= k[8] or w ~= k[9] or h ~= k[10] then same = false end
    k[7], k[8], k[9], k[10] = ox, oy, w, h
    return same
end

--- Makes the candidate lists (see above) for the objects as they are now.
local function LabelCandidates(view, zoomedIn, now)
    local markers = Map.Doc.save.MasterChain._MASTERCHAIN_.Markers
    local areas = Map.Doc.save.Areas
    local Filter = Mod('markerfilter', '/lua/editor/markerfilter.lua')
    local selMarkerSet, selAreaSet = SelectionSets()
    local hov = Tools.Hover
    local hovKind, hovName = hov.kind, hov.name
    LC.changed, LC.hover, LC.doc, LC.epoch, LC.zoomed, LC.at = Tools.Changed, Tools.HoverRev, Map.Doc, groundEpoch, zoomedIn, now
    LC.sumA, LC.sumB, LC.sumC = Mod('markersig', '/lua/editor/markersig.lua').Sums(now)
    local bx0, bx1, bz0, bz1
    if zoomedIn then
        bx0, bx1, bz0, bz1 = LabelBounds(view)
        if bx0 then
            -- a wider rectangle than the view needs, so that a camera that pans a little keeps the lists
            local ex, ez = 0.5 * (bx1 - bx0), 0.5 * (bz1 - bz0)
            bx0, bx1, bz0, bz1 = bx0 - ex, bx1 + ex, bz0 - ez, bz1 + ez
        end
    end
    LC.all = not bx0
    if bx0 then LC.bx0, LC.bx1, LC.bz0, LC.bz1 = bx0, bx1, bz0, bz1 end
    local sx, sz = ed_terrain_info()
    sx, sz = (sx or 257) - 1, (sz or 257) - 1
    local nm, na = 0, 0
    local mname, mx, my, mz, msel = LC.mname, LC.mx, LC.my, LC.mz, LC.msel
    local aname, ax, ay, az, asel = LC.aname, LC.ax, LC.ay, LC.az, LC.asel
    if zoomedIn then
        for name, m in markers do
            local isSel = selMarkerSet[name]
            local pos = m.position
            if isSel or (hovKind == 'marker' and hovName == name) or not bx0 or (pos[1] >= bx0 and pos[1] <= bx1 and pos[3] >= bz0 and pos[3] <= bz1) then
                if isSel or not Filter.IsHidden(m.type) then
                    nm = nm + 1
                    mname[nm] = name
                    mx[nm], my[nm], mz[nm] = MC.DisplayPos(m, sx, sz)
                    msel[nm] = isSel and true or false
                end
            end
        end
        for name, a in areas do
            local r = a.rectangle
            if r then
                local isSel = selAreaSet[name]
                if isSel or (hovKind == 'area' and hovName == name) or not bx0 or (r[1] >= bx0 and r[1] <= bx1 and r[2] >= bz0 and r[2] <= bz1) then
                    na = na + 1
                    aname[na] = name
                    ax[na], ay[na], az[na] = r[1], GroundHeight(r[1], r[2]), r[2]
                    asel[na] = isSel and true or false
                end
            end
        end
    else
        -- zoomed out only the selected and the hovered ones carry a name, found without a walk over the whole map
        for _, it in Tools.Items do
            local m = it.kind == 'marker' and markers[it.name]
            if m then
                nm = nm + 1
                mname[nm] = it.name
                mx[nm], my[nm], mz[nm] = MC.DisplayPos(m, sx, sz)
                msel[nm] = true
            end
        end
        local m = hovKind == 'marker' and not selMarkerSet[hovName] and markers[hovName]
        if m and not Filter.IsHidden(m.type) then
            nm = nm + 1
            mname[nm] = hovName
            mx[nm], my[nm], mz[nm] = MC.DisplayPos(m, sx, sz)
            msel[nm] = false
        end
        for _, it in Tools.Items do
            local a = it.kind == 'area' and areas[it.name]
            local r = a and a.rectangle
            if r then
                na = na + 1
                aname[na] = it.name
                ax[na], ay[na], az[na] = r[1], GroundHeight(r[1], r[2]), r[2]
                asel[na] = true
            end
        end
        local a = hovKind == 'area' and not selAreaSet[hovName] and areas[hovName]
        local r = a and a.rectangle
        if r then
            na = na + 1
            aname[na] = hovName
            ax[na], ay[na], az[na] = r[1], GroundHeight(r[1], r[2]), r[2]
            asel[na] = false
        end
    end
    LC.nm, LC.na = nm, na
end

--- Sets label `n` (text, colour, place) when it differs from what it shows, and shows it.
local function ShowLabel(n, name, lx, ly, selected)
    local t = Label(n)
    if t.shownText ~= name then t:SetText(name) t.shownText = name end
    local color = selected and 'FFFFE040' or 'FFE8F0F8'
    if t.shownColor ~= color then t:SetColor(color) t.shownColor = color end
    if t.shownX ~= lx then t.Left:Set(lx) t.shownX = lx end
    if t.shownY ~= ly then t.Top:Set(ly) t.shownY = ly end
    if t.shownVis ~= true then t:Show() t.shownVis = true end
    if n > labelTop then labelTop = n end
end

--- Projects a world point; returns the label place (left, top) when it is inside the view, else nil.
local function LabelPlace(view, wx, wy, wz, ox, oy, w, h)
    local p = view:Project(Vector(wx, wy, wz))
    local x, y = p.x, p.y
    if x < 0 or y < 0 or x > w or y > h then return nil end
    return ox + x + 17, oy + y - 7
end

--- The names of the markers and areas, the Start position ghosts and the ruler's result.
local function UpdateLabels(view, px)
    local now = GetSystemTimeSeconds()
    local ox, oy = view.Left(), view.Top()
    local w, h = view.Width(), view.Height()
    local zoomedIn = px < 0.45
    -- (zoomed out only the selected and the hovered names are projected, a handful: they follow the camera without the camera key)
    local camSame
    if zoomedIn then camSame = CameraSame(view, ox, oy, w, h) else camSame = (LC.nm + LC.na == 0) end
    -- (zoomed in the hover changes nothing: a hovered object is on screen, so it is a candidate anyway and is not coloured differently; zoomed out the hovered one is the candidate)
    local candidatesSame = LC.changed == Tools.Changed and (zoomedIn or LC.hover == Tools.HoverRev) and LC.doc == Map.Doc and LC.epoch == groundEpoch
        and LC.zoomed == zoomedIn
    if candidatesSame and now - LC.at >= 1 then
        -- the net (a writer that announces nothing): once a second a sum over the positions, a rebuild only when it moved
        local a, b, c = Mod('markersig', '/lua/editor/markersig.lua').Sums(now)
        if a == LC.sumA and b == LC.sumB and c == LC.sumC then LC.at = now else candidatesSame = false end
    end
    if candidatesSame and zoomedIn and not LC.all then
        -- the view must still lie inside the rectangle the candidates cover
        local bx0, bx1, bz0, bz1 = LabelBounds(view)
        if not bx0 or bx0 < LC.bx0 or bx1 > LC.bx1 or bz0 < LC.bz0 or bz1 > LC.bz1 then candidatesSame = false end
    end
    if not (camSame and candidatesSame and LC.valid) then
        if not candidatesSame then LabelCandidates(view, zoomedIn, now) end
        local n = 0
        local mname, mx, my, mz, msel = LC.mname, LC.mx, LC.my, LC.mz, LC.msel
        for i = 1, LC.nm do
            if n >= 150 then break end
            local lx, ly = LabelPlace(view, mx[i], my[i], mz[i], ox, oy, w, h)
            if lx then
                n = n + 1
                ShowLabel(n, mname[i], lx, ly, msel[i])
            end
        end
        local aname, ax, ay, az, asel = LC.aname, LC.ax, LC.ay, LC.az, LC.asel
        for i = 1, LC.na do
            if n >= 150 then break end
            local lx, ly = LabelPlace(view, ax[i], ay[i], az[i], ox, oy, w, h)
            if lx then
                n = n + 1
                ShowLabel(n, aname[i], lx, ly, asel[i])
            end
        end
        LC.shown = n
        LC.valid = true
    end
    local n = LC.shown
    for i = 1, ghostN do
        local g = ghostLabels[i]
        local lx, ly = LabelPlace(view, g.x, g.y, g.z, ox, oy, w, h)
        if lx then
            n = n + 1
            ShowLabel(n, g.name, lx, ly, true)
        end
    end
    -- the ruler's result at its end point
    local Ruler = Mod('ruler', '/lua/editor/ruler.lua')
    local rp = Ruler.Points[table.getn(Ruler.Points)]
    local text = rp and Ruler.Text()
    if text then
        local lx, ly = LabelPlace(view, rp.x, GroundHeight(rp.x, rp.z) + 1, rp.z, ox, oy, w, h)
        if lx then
            n = n + 1
            ShowLabel(n, text, lx, ly, true)
        end
    end
    HideLabelsFrom(n + 1)
end

-- ---- build grid view ----------------------------------------------------------------------------------------------------------------

--- The game's 1 x 1 build grid, fixed to the map: lines at whole world coordinates over the part of the map the camera sees (plus a margin),
--- every 4th brighter. Cells smaller than a few pixels are drawn coarser (every 4th, 16th, 64th line). It is rebuilt only when the view
--- leaves the built region, the step changes, or now and then so the lines follow terrain edits.
local gridStep, gridX0, gridX1, gridZ0, gridZ1 = 0, 0, 0, 0, 0

local function MapSize()
    local sx, sz = ed_terrain_info()
    return (sx or 257) - 1, (sz or 257) - 1
end

--- World rectangle seen through the view, clamped to the map: { minx, minz, maxx, maxz } or nil.
local function VisibleRect(view)
    local mapX, mapZ = MapSize()
    local l, t = view.Left(), view.Top()
    local r, b = l + view.Width(), t + view.Height()
    local minx, minz, maxx, maxz
    for _, c in { { l, t }, { r, t }, { l, b }, { r, b }, { (l + r) / 2, (t + b) / 2 } } do
        local p = UnProject(view, Vector2(c[1], c[2]))
        if p then
            minx = minx and math.min(minx, p[1]) or p[1]
            maxx = maxx and math.max(maxx, p[1]) or p[1]
            minz = minz and math.min(minz, p[3]) or p[3]
            maxz = maxz and math.max(maxz, p[3]) or p[3]
        end
    end
    if not minx then return nil end
    return { math.max(0, minx), math.max(0, minz), math.min(mapX, maxx), math.min(mapZ, maxz) }
end

local function GridView(view, px)
    if not Grid.Visible then
        if next(gridIds) ~= nil then
            for id, _ in gridIds do ed_overlay_remove(id) end
            gridIds, gridKey, gridStep = {}, '', 0
        end
        return
    end
    local vis = VisibleRect(view)
    if not vis or vis[3] <= vis[1] or vis[4] <= vis[2] then return end
    local ppu = 1 / px                                   -- screen pixels per world unit at the view centre
    local step = 1
    if ppu < 6 then step = 4 end
    if ppu * 4 < 6 then step = 16 end
    if ppu * 16 < 6 then step = 64 end
    while (vis[3] - vis[1]) / step > 90 or (vis[4] - vis[2]) / step > 90 do step = step * 4 end

    local inside = gridStep == step and vis[1] >= gridX0 and vis[3] <= gridX1 and vis[2] >= gridZ0 and vis[4] <= gridZ1
    -- the lines are laid onto the terrain again (up to ~50000 height reads) when the ground changed (TerrainEpoch), not on a timer
    if inside and gridKey == groundEpoch then return end

    local mapX, mapZ = MapSize()
    local pad = 10 * step
    local x0 = math.max(0, math.floor((vis[1] - pad) / step) * step)
    local x1 = math.min(mapX, math.ceil((vis[3] + pad) / step) * step)
    local z0 = math.max(0, math.floor((vis[2] - pad) / step) * step)
    local z1 = math.min(mapZ, math.ceil((vis[4] + pad) / step) * step)
    gridStep, gridX0, gridX1, gridZ0, gridZ1 = step, x0, x1, z0, z1
    gridKey = groundEpoch

    local seen = {}
    local sample = math.max(1, math.floor(step / 2))      -- sample finer than the line spacing so the lines follow slopes
    local function Lines(vertical)
        local from, to, a0, a1 = z0, z1, x0, x1                      -- vertical lines: constant x, running along z
        if not vertical then from, to, a0, a1 = x0, x1, z0, z1 end
        for g = a0, a1, step do
            local pts = {}
            for h = from, to, sample do
                if vertical then Push(pts, g, h) else Push(pts, h, g) end
            end
            local id = (vertical and 'gx:' or 'gz:') .. g
            ed_overlay_set(id, pts, math.mod(g, step * 4) == 0 and 'C0FFFFFF' or '55FFFFFF', 0.05, 1, 1, false, false, false)
            seen[id] = true
        end
    end
    Lines(true)
    Lines(false)
    for id, _ in gridIds do
        if not seen[id] then ed_overlay_remove(id) end
    end
    gridIds = seen
end

--- The world rectangle { minx, minz, maxx, maxz } of the ground the slope view has to cover. VisibleRect skips every sample point of the view that misses the ground (the sky above the
--- horizon, or beyond the edge of the map), so a low camera got a rectangle that ended halfway to the horizon and jumped when the camera height changed. Here a sample that misses is
--- walked back on the screen towards the nearest sample that hits (bisection), and the rectangle takes the last ground point found: the farthest ground that is visible in that
--- direction (the horizon, or the map's edge). How many cells that is does not matter here: the native layer blocks a wide view together (EdOverlay.cpp, block levels).
--- Nine sample points; the bisection runs only when the nine results differ from the last call (the rectangle is kept while the view does not move).
local slopeRectCache = { key = '', rect = false }
local SLOPE_SAMPLES = { { 0, 0 }, { 0.5, 0 }, { 1, 0 }, { 0, 0.5 }, { 0.5, 0.5 }, { 1, 0.5 }, { 0, 1 }, { 0.5, 1 }, { 1, 1 } }

local function SlopeRect(view)
    local l, t = view.Left(), view.Top()
    local w, h = view.Width(), view.Height()
    if not w or w < 1 or not h or h < 1 then return nil end
    local hits, misses, parts = {}, {}, {}
    for _, f in SLOPE_SAMPLES do
        local sx, sy = l + f[1] * w, t + f[2] * h
        local p = UnProject(view, Vector2(sx, sy))
        if p then
            table.insert(hits, { sx, sy, p[1], p[3] })
            table.insert(parts, string.format('%.2f,%.2f', p[1], p[3]))
        else
            table.insert(misses, { sx, sy })
            table.insert(parts, 'x')
        end
    end
    if table.getn(hits) == 0 then return nil end
    local key = table.concat(parts, ';')
    if key == slopeRectCache.key and slopeRectCache.rect then return slopeRectCache.rect end

    local minx, minz, maxx, maxz = hits[1][3], hits[1][4], hits[1][3], hits[1][4]
    for _, q in hits do
        minx, maxx = math.min(minx, q[3]), math.max(maxx, q[3])
        minz, maxz = math.min(minz, q[4]), math.max(maxz, q[4])
    end
    for _, m in misses do
        local best, bestD
        for _, q in hits do
            local d = (q[1] - m[1]) * (q[1] - m[1]) + (q[2] - m[2]) * (q[2] - m[2])
            if not bestD or d < bestD then best, bestD = q, d end
        end
        local ax, ay, bx, by = best[1], best[2], m[1], m[2]      -- (ax, ay) hits the ground, (bx, by) does not
        for _ = 1, 10 do
            local mx, my = (ax + bx) / 2, (ay + by) / 2
            local p = UnProject(view, Vector2(mx, my))
            if p then
                ax, ay = mx, my
                minx, maxx = math.min(minx, p[1]), math.max(maxx, p[1])
                minz, maxz = math.min(minz, p[3]), math.max(maxz, p[3])
            else
                bx, by = mx, my
            end
        end
    end
    local mapX, mapZ = MapSize()
    local rect = { math.max(0, minx), math.max(0, minz), math.min(mapX, maxx), math.min(mapZ, maxz) }
    slopeRectCache.key, slopeRectCache.rect = key, rect
    return rect
end

--- Tells the native slope layer which cells to rate: the visible part of the map (it blocks them together when the view is very wide).
local slopeShown = false

local function SlopeView(view)
    if not Slope.Visible then
        if slopeShown then
            ed_overlay_slope_off()
            slopeShown = false
        end
        return
    end
    local vis = SlopeRect(view)
    if not vis then return end
    local x0, z0, x1, z1 = math.floor(vis[1]) - 1, math.floor(vis[2]) - 1, math.ceil(vis[3]) + 1, math.ceil(vis[4]) + 1
    ed_overlay_slope(Slope.NativeKind(), math.max(0, x0), math.max(0, z0), x1, z1, Slope.Window, Slope.Limit)    -- 'path' | 'build' (area rule) | 'ring' (edge rule; slope.lua falls back to 'build' on an engine without it)
    slopeShown = true
end

--- The build grid. The engine draws it every frame (ed_overlay_grid, EdOverlay.cpp): a quadtree over the visible ground, so there are lines every cell where a cell is big on
--- screen and every 2, 4, 8 ... cells where it is small, fading with the distance, laid on the real ground and hidden by hills. Nothing is built here: this only passes the visible
--- rectangle. Without the native (an older engine) the Lua line set (GridView) is drawn, as before.
local nativeGridShown = false

local function GridNative(view, px)
    if rawget(_G, 'ed_overlay_grid') == nil then
        GridView(view, px)
        return
    end
    if next(gridIds) ~= nil then                         -- lines of the Lua fallback: gone
        for id, _ in gridIds do ed_overlay_remove(id) end
        gridIds, gridKey, gridStep = {}, '', 0
    end
    if not Grid.Visible then
        if nativeGridShown then
            ed_overlay_grid_off()
            nativeGridShown = false
        end
        return
    end
    local vis = SlopeRect(view)
    if not vis then return end
    ed_overlay_grid(math.max(0, math.floor(vis[1]) - 1), math.max(0, math.floor(vis[2]) - 1), math.ceil(vis[3]) + 1, math.ceil(vis[4]) + 1)
    nativeGridShown = true
end

-- ---- pointer ------------------------------------------------------------------------------------------------------------------------

local function Remove(id)
    if absent[id] then return end          -- (was removed and not set since: the Pointer removes a dozen ids every frame that are not there)
    absent[id] = true
    ringKeys[id] = nil
    ed_overlay_remove(id)
end

--- A ring on the terrain (Circle) as overlay line `id`, laid again only when its inputs changed: the place, radius, height under it, colour, the ground (the native height
--- revision moves with every height write, TerrainEpoch with the net for the rest). A pointer at rest used to lay the brush ring onto the terrain (~190 height reads, 144 table
--- inserts) and send it to the engine in every frame.
local frameRev = 0          -- the native height revision of this frame (set at the start of Pointer)

local function RingAt(id, cx, cz, r, segs, base, span, color, width, minPx, maxPx)
    local k = ringKeys[id]
    local epoch = groundEpoch
    if k and k[1] == cx and k[2] == cz and k[3] == r and k[4] == segs and k[5] == base and k[6] == span and k[7] == color and k[8] == width and k[9] == minPx
        and k[10] == maxPx and k[11] == frameRev and k[12] == epoch then
        return
    end
    if not k then
        k = {}
        ringKeys[id] = k
    end
    local pts = Circle(cx, cz, r, segs, base, span)
    ed_overlay_set(id, pts, color, width, minPx, maxPx, true, true)
    absent[id] = nil
    k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9], k[10], k[11], k[12] = cx, cz, r, segs, base, span, color, width, minPx, maxPx, frameRev, epoch
end

local function Handles(view, px)
    local handleArea = Tools.HandleArea()
    local a = handleArea and Map.Doc.save.Areas[handleArea]
    local count = 0
    if a and a.rectangle then
        local r = a.rectangle
        local s = 4 * px
        -- (8 squares of 4 terrain reads each, only when the rectangle, the zoom or the ground changed; the key is compared field by field, and the handle list is not even made
        -- when nothing changed: it was a string and 8 tables per frame)
        local k = handleKeyT
        local same = handleCount == 8 and k[1] == handleArea and k[2] == r[1] and k[3] == r[2] and k[4] == r[3] and k[5] == r[4] and k[6] == s and k[7] == groundEpoch
        if same then
            count = 8
        else
            k[1], k[2], k[3], k[4], k[5], k[6], k[7] = handleArea, r[1], r[2], r[3], r[4], s, groundEpoch
            for _, h in Tools.HandlesOf(r) do
                count = count + 1
                local pts = {}
                Push(pts, h.x - s, h.z - s) Push(pts, h.x + s, h.z - s) Push(pts, h.x + s, h.z + s) Push(pts, h.x - s, h.z + s)
                Line(nil, 'ah' .. count, pts, 'FFFFFF', 0.2, 2, 4, true)
            end
        end
    else
        handleKeyT[1] = false
    end
    for i = count + 1, handleCount do
        Remove('ah' .. i)
    end
    handleCount = count
end

-- The brush's weight map as a greyscale gradient on the ground: every height sample inside the radius shows the weight a dab would give it
-- (brighter = stronger), scaled by the strength setting; the ring marks the radius.
local previewKeys = {}        -- per image of the brush under symmetry: slot -> { numbers } of what is drawn (compared field by field: no string per frame)
local previewValues = {}      -- slot -> { key, values } the table of weights of a round brush (BrushPreview)
lastBrushPos = false

local function BrushPreview(p, r, mode, slot)
    slot = slot or ''
    local B = Terrain.Brush
    local ref = (mode == 'flatten' or mode == 'smooth') and 1.0 or 6.0
    local scale = 0.25 + 0.75 * math.min(1, B.strength / ref)
    if mode == 'paint' or mode == 'erase' then
        scale = 0.25 + 0.75 * math.min(1, math.abs(Mod('strata', '/lua/editor/strata.lua').Brush.strength) / 100)
    end
    local Brushes = Mod('brushes', '/lua/editor/brushes.lua')
    local extra = ''
    local isStamp = (mode == 'stamp' or mode == 'stamp_paint')
    if isStamp then
        -- the stamp's own picture, rotation and fade (stamp.lua)
        local St = Mod('stamp', '/lua/editor/stamp.lua').S
        scale = 0.25 + 0.75 * math.min(1, St.strength / 100)
        extra = St.shape .. '|' .. St.rotation .. '|' .. St.falloff
    end
    -- A round brush's weights depend on the pointer only through its offset inside a sample cell: that is snapped to 1/4 unit, and the table of values is kept per radius /
    -- falloff / strength / offset, so moving the pointer over the map rebuilds nothing but the position (the table used to be rebuilt, ~10000 weight calls for a radius of 50, on
    -- every frame the pointer moved, also while a stroke was dragged).
    -- A shaped brush (brushes.lua) is the same: its weights depend on the offset inside a cell, the shape, the turn and the radius, and the last 16 offsets' tables are kept
    -- (Brushes.Fill makes one in a tight loop; the old loop called Terrain.BrushWeight per sample).
    local round = (Brushes.Active == 'round') and not isStamp
    local shaped = (not round) and not isStamp
    local turn = shaped and Terrain.StrokeTurn() or 0
    local px, pz = p[1], p[3]
    if round or shaped then
        px = math.floor(px * 4 + 0.5) / 4
        pz = math.floor(pz * 4 + 0.5) / 4
    end
    -- (the pointer is snapped to 1/4 unit above for round and shaped brushes; the stamp's pointer is exact. The rest of the key is what the weights depend on.)
    local turnKey = shaped and math.floor(turn * 10 + 0.5) or 0
    local pk = previewKeys[slot]
    local active, angle = Brushes.Active, Brushes.Angle
    if pk and pk[1] == px and pk[2] == pz and pk[3] == r and pk[4] == B.falloff and pk[5] == scale and pk[6] == mode and pk[7] == active and pk[8] == angle and pk[9] == turnKey
        and (not isStamp or pk[10] == extra) then
        return
    end
    if shaped then extra = string.format('%.1f', turn) end
    if not pk then
        pk = {}
        previewKeys[slot] = pk
    end
    pk[1], pk[2], pk[3], pk[4], pk[5], pk[6], pk[7], pk[8], pk[9], pk[10] = px, pz, r, B.falloff, scale, mode, active, angle, turnKey, extra
    absent['cur:brush' .. slot] = nil
    local x0, z0, x1, z1 = math.floor(px - r), math.floor(pz - r), math.ceil(px + r), math.ceil(pz + r)
    local nw, nh = x1 - x0 + 1, z1 - z0 + 1
    local values
    local valuesKey
    if round or shaped then
        valuesKey = string.format('%.2f|%.2f|%.2f|%s|%.2f|%.2f', r, B.falloff, scale, mode, px - math.floor(px), pz - math.floor(pz))
        if shaped then valuesKey = valuesKey .. '|' .. Brushes.Active .. '|' .. Brushes.Angle .. '|' .. extra end
        local cached = previewValues[slot]
        if cached and cached.key == valuesKey then
            values = cached.values
        elseif shaped and cached and cached.multi then
            values = cached.multi[valuesKey]
        end
    end
    if not values then
        values = {}
        local n = 0
        if round then
            local disc = (mode == 'ttype' or mode == 'prop' or mode == 'prop_erase' or mode == 'decal' or mode == 'decal_erase')
            local profile, steps = Terrain.RoundProfile(r)           -- the weight at k / steps units, cached for this radius and falloff
            local sqrt, floor = math.sqrt, math.floor
            local top = 255 * scale
            for z = z0, z1 do
                local dz = z - pz
                local dz2 = dz * dz
                for x = x0, x1 do
                    local dx = x - px
                    local d = sqrt(dx * dx + dz2)
                    n = n + 1
                    if disc then
                        values[n] = (d <= r) and 120 or 0        -- hard discs: terrain type, props
                    elseif d >= r then
                        values[n] = 0
                    else
                        local f = d * steps
                        local k = floor(f)
                        local t = f - k
                        values[n] = floor(top * (profile[k] * (1 - t) + profile[k + 1] * t))
                    end
                end
            end
        elseif shaped then
            values = Brushes.Fill(Brushes.Active, r, turn, px, pz, x0, z0, x1, z1, 255 * scale)
        else
            for z = z0, z1 do
                for x = x0, x1 do
                    local dx, dz = x - p[1], z - p[3]
                    n = n + 1
                    local d = math.sqrt(dx * dx + dz * dz)
                    values[n] = math.floor(255 * Terrain.BrushWeight(d, r, dx, dz) * scale)
                end
            end
        end
        if valuesKey then
            local old = previewValues[slot]
            local entry = { key = valuesKey, values = values }
            if shaped then
                local multi = old and old.multi
                if not multi or old.count >= 16 then multi = {} ; entry.count = 0 else entry.count = old.count end
                multi[valuesKey] = values
                entry.count = entry.count + 1
                entry.multi = multi
            end
            previewValues[slot] = entry
        end
    end
    ed_overlay_nodes('cur:brush' .. slot, x0, z0, nw, nh, values, 'FFFFFF', 190)
end

-- ---- symmetry: the axes across the map and a ring at every image of the brush ----------------------------------------------------------

local axisKey = ''
local axisIds = {}

local function DrawAxes()
    local Sym = Mod('symmetry', '/lua/editor/symmetry.lua')
    local cx, cz = Sym.Centre()
    local key = string.format('%s|%.1f|%.1f', Sym.Mode, cx, cz)
    if key == axisKey then return end
    axisKey = key
    for id, _ in axisIds do ed_overlay_remove(id) end
    axisIds = {}
    local size = ed_terrain_info and ed_terrain_info() or 256
    local max = (size or 256) - 1
    for i, l in Sym.Axes() do
        local pts = {}
        local len = math.sqrt((l[3] - l[1]) * (l[3] - l[1]) + (l[4] - l[2]) * (l[4] - l[2]))
        local n = math.max(2, math.min(400, math.ceil(len / 3)))
        for k = 0, n do
            local f = k / n
            local x, z = l[1] + (l[3] - l[1]) * f, l[2] + (l[4] - l[2]) * f
            if x >= 0 and z >= 0 and x <= max and z <= max then Push(pts, x, z) end
        end
        if table.getn(pts) >= 6 then
            local id = 'sym:' .. i
            ed_overlay_set(id, pts, 'D0FF40FF', 0.08, 1, 2, false, true)
            axisIds[id] = true
        end
    end
end

-- ---- terrain type grid -------------------------------------------------------------------------------------------------------------

--- The terrain type cells (ttoverlay.lua keeps the layers and redraws only the cells a dab changed).
local function DrawTypes(view)
    Mod('ttoverlay', '/lua/editor/ttoverlay.lua').Draw(view)
end

-- ---- selected props ----------------------------------------------------------------------------------------------------------------

local propSelKey = ''
local propSelIds = {}

local function DrawPropSelection(ui)
    local Props = Mod('props', '/lua/editor/props.lua')
    local active = ui.State.tool == 'prop_select'
    local sel = active and Props.Selection or {}
    local off = Props.DragOffset
    local key = string.format('%d|%d|%s|%s', Props.SelRevision, table.getn(sel), tostring(off and off[1]), tostring(off and off[2]))
    if key == propSelKey then return end
    propSelKey = key
    local seen = {}
    local n = 0
    for _, p in sel do
        n = n + 1
        if n > 150 then break end
        local x, z = p.x + (off and off[1] or 0), p.z + (off and off[2] or 0)
        local id = 'psel:' .. n
        ed_overlay_set(id, Circle(x, z, 1.4, 16, GroundHeight(x, z), 3), 'FFFFFF40', 0.12, 2, 3, true, true)
        seen[id] = true
        propSelIds[id] = true
    end
    for id, _ in propSelIds do
        if not seen[id] then
            ed_overlay_remove(id)
            propSelIds[id] = nil
        end
    end
end

-- ---- ramp preview ------------------------------------------------------------------------------------------------------------------

local rampKey = ''

local function DrawRamp()
    local Ramp = Mod('ramp', '/lua/editor/ramp.lua')
    local p = Ramp.Preview
    local key = p and string.format('%.1f,%.1f,%.1f,%.1f|%d', p[1], p[2], p[3], p[4], Terrain.Brush.radius) or ''
    if key == rampKey then return end
    rampKey = key
    if not p then
        ed_overlay_remove('ramp:line')
        ed_overlay_remove('ramp:a')
        ed_overlay_remove('ramp:b')
        return
    end
    local r = Terrain.Brush.radius
    local pts = {}
    local len = math.sqrt((p[3] - p[1]) * (p[3] - p[1]) + (p[4] - p[2]) * (p[4] - p[2]))
    local steps = math.max(1, math.min(200, math.ceil(len / 2)))
    for s = 0, steps do
        local f = s / steps
        Push(pts, p[1] + (p[3] - p[1]) * f, p[2] + (p[4] - p[2]) * f)
    end
    ed_overlay_set('ramp:line', pts, 'FF60A0FF', 0.15, 2, 3, false, true)
    ed_overlay_set('ramp:a', Circle(p[1], p[2], r, 32, GroundHeight(p[1], p[2]), math.max(2, r)), 'FF60A0FF', 0.2, 2, 3, true, true)
    ed_overlay_set('ramp:b', Circle(p[3], p[4], r, 32, GroundHeight(p[3], p[4]), math.max(2, r)), 'FF60A0FF', 0.2, 2, 3, true, true)
end

-- ---- selected decals ---------------------------------------------------------------------------------------------------------------

local decalSelKey = ''
local decalSelIds = {}

local function DrawDecalSelection(ui)
    local Decals = Mod('decals', '/lua/editor/decals.lua')
    local active = ui.State.tool == 'decal_select'
    local sel = active and Decals.Selection or {}
    local off = Decals.DragOffset
    local key = string.format('%d|%d|%s|%s', Decals.SelRevision, table.getn(sel), tostring(off and off[1]), tostring(off and off[2]))
    if key == decalSelKey then return end
    decalSelKey = key
    local seen = {}
    local n = 0
    local drawn = {}
    for _, p in sel do
        local k = string.format('%.2f,%.2f', p.x, p.z)
        if not drawn[k] then
            drawn[k] = true
            n = n + 1
            if n > 100 then break end
            local idx
            for i = 1, ed_decal_count() do
                local t0, t1, kind, x, y, z, sx = ed_decal_get(i)
                if t0 == p.tex and math.abs(x - p.x) < 0.01 and math.abs(z - p.z) < 0.01 then idx = sx break end
            end
            local x, z = p.x + (off and off[1] or 0), p.z + (off and off[2] or 0)
            local id = 'dsel:' .. n
            ed_overlay_set(id, Circle(x, z, math.max(1, (idx or 8) / 2), 32, GroundHeight(x, z), 4), 'FFE0C040', 0.15, 2, 3, true, true)
            seen[id] = true
            decalSelIds[id] = true
        end
    end
    for id, _ in decalSelIds do
        if not seen[id] then
            ed_overlay_remove(id)
            decalSelIds[id] = nil
        end
    end
end

-- ---- units: markers and selection ---------------------------------------------------------------------------------------------------

local unitKeyT = { 0, 0, 0, 0, 0, 0, 0, 0, -100 }       -- what the rings were laid for
local unitIds = {}
local UNIT_NET_SECONDS = 5      -- the rings are laid again at least this often (a writer that bypasses the stamp); a clock, not a frame count: at an unlimited frame rate 120 frames were a fraction of a second

--- Rings at every unit of the map (a unit tool is active) and a brighter one for the selected units.
local function DrawUnits(ui)
    local Units = Mod('units', '/lua/editor/units.lua')
    local active = (ui.State.tool == 'unit_select')      -- (the Place unit tool shows a ghost instead of a ring on every unit)
    local off = Units.DragOffset
    -- the key is made without looking at the units (All() builds a table for each of them: 2000 on a mission map, every frame): a stored / removed unit, a history step
    -- and the selection move it, and the terrain epoch lays the rings onto the ground again
    -- (the numbers are compared one by one: the key used to be a formatted string, built in every frame)
    local uk = unitKeyT
    local unitRev, histVersion = Units.Rev, Mod('history', '/lua/editor/history.lua').Version
    local selRev, selN = Units.SelRevision, table.getn(Units.Selection)
    local ox, oz = off and off[1] or false, off and off[2] or false
    local epoch = groundEpoch
    local now = GetSystemTimeSeconds()
    if uk[1] == unitRev and uk[2] == histVersion and uk[3] == selRev and uk[4] == selN and uk[5] == ox and uk[6] == oz and uk[7] == active and uk[8] == epoch and now - uk[9] < UNIT_NET_SECONDS then return end
    uk[1], uk[2], uk[3], uk[4], uk[5], uk[6], uk[7], uk[8], uk[9] = unitRev, histVersion, selRev, selN, ox, oz, active, epoch, now
    local list = active and Units.CachedAll() or {}
    local seen = {}
    local n = 0
    for _, u in list do
        n = n + 1
        if n > 400 then break end
        local selected = Units.IsSelected(u)
        local x, z = u.x + ((selected and off) and off[1] or 0), u.z + ((selected and off) and off[2] or 0)
        local id = 'unit:' .. n
        ed_overlay_set(id, Circle(x, z, 1.6, 14, GroundHeight(x, z), 3), selected and 'FFFFFFFF' or 'C040C0FF', 0.1, 2, 3, true, true)
        seen[id] = true
        unitIds[id] = true
    end
    for id, _ in unitIds do
        if not seen[id] then
            ed_overlay_remove(id)
            unitIds[id] = nil
        end
    end
end

-- ---- transform gizmo ---------------------------------------------------------------------------------------------------------------------

local gizmoIds = {}
local gizmoKeys = {}

local function DrawGizmo()
    local shapes = Mod('gizmo', '/lua/editor/gizmo.lua').Shapes()
    local seen = {}
    local epoch = groundEpoch
    for _, s in shapes do
        -- the same shape as last frame (the pointer rests, the selection stands still) is not laid onto the terrain again: ~80 terrain reads and 10 engine calls per frame
        local n, sx, sz = 0, 0, 0
        for _, p in s.points do
            n = n + 1
            sx = sx + p[1] * n
            sz = sz + p[2] * (n + 0.5)
        end
        -- (the key is a table of the values, compared one by one: it used to be a string of ten concatenations per shape and frame)
        local k = gizmoKeys[s.id]
        local same = k and k[1] == s.color and k[2] == s.px and k[3] == s.width and k[4] == s.closed and k[5] == s.fill and k[6] == n and k[7] == sx and k[8] == sz and k[9] == epoch
        if not same or not gizmoIds[s.id] then
            if not k then
                k = {}
                gizmoKeys[s.id] = k
            end
            k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9] = s.color, s.px, s.width, s.closed, s.fill, n, sx, sz, epoch
            local pts = {}
            for _, p in s.points do Push(pts, p[1], p[2]) end
            if s.fill then
                -- a filled square: one wide ribbon (world width), no halo, no vertex caps
                ed_overlay_set(s.id, pts, s.color, s.width, 1, 800, false, false, false)
            elseif s.px then
                -- a line of constant width on screen (s.px pixels; the world width is far below that, so the pixel limits decide)
                ed_overlay_set(s.id, pts, s.color, 0.02, s.px, s.px, s.closed and true or false, true)
            else
                ed_overlay_set(s.id, pts, s.color, 0.2, 2, 4, false, true)
            end
        end
        seen[s.id] = true
        gizmoIds[s.id] = true
    end
    for id, _ in gizmoIds do
        if not seen[id] then
            ed_overlay_remove(id)
            gizmoIds[id] = nil
            gizmoKeys[id] = nil
        end
    end
end

-- ---- ruler -------------------------------------------------------------------------------------------------------------------------

local rulerKey = ''

local function DrawRuler()
    local Ruler = Mod('ruler', '/lua/editor/ruler.lua')
    local pts = Ruler.Points
    local n = table.getn(pts)
    local key = n .. ''
    for _, p in pts do key = key .. string.format('|%.1f,%.1f', p.x, p.z) end
    if key == rulerKey then return end
    rulerKey = key
    if n < 2 then
        ed_overlay_remove('ruler')
        for i = 1, 40 do ed_overlay_remove('ruler:p' .. i) end
        return
    end
    local line = {}
    for i = 2, n do
        local a, b = pts[i - 1], pts[i]
        local len = math.sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z))
        local steps = math.max(1, math.min(200, math.ceil(len / 2)))
        for s = (i == 2) and 0 or 1, steps do
            local f = s / steps
            Push(line, a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f)
        end
    end
    ed_overlay_set('ruler', line, 'FFFFE040', 0.12, 2, 3, false, true)
    for i = 1, math.min(n, 40) do
        ed_overlay_set('ruler:p' .. i, Circle(pts[i].x, pts[i].z, 0.8, 12, GroundHeight(pts[i].x, pts[i].z), 2), 'FFFFE040', 0.1, 2, 3, true, true)
    end
end

local armyGhosts = 0      -- how many ghosts of the Start position tool are on the map

-- The pointer's ghost of the marker, area and chain tools (ring, cross, footprint) is laid again only when what it is made of changed.
local ghostSig = { kind = false, 0, 0, 0, 0, 0, 0, rev = -1, epoch = -1 }

local function GhostSame(kind, a, b, c, d, e, f)
    local g = ghostSig
    local epoch = groundEpoch
    local same = g.kind == kind and g[1] == a and g[2] == b and g[3] == c and g[4] == d and g[5] == e and g[6] == f and g.rev == frameRev and g.epoch == epoch
    g.kind, g[1], g[2], g[3], g[4], g[5], g[6], g.rev, g.epoch = kind, a, b, c, d, e, f, frameRev, epoch
    return same
end

local function ArmyGhostOff()
    if armyGhosts > 0 then
        for i = 1, armyGhosts do
            Remove('cur:armyi' .. i)
            Remove('cur:armyr' .. i)
        end
        armyGhosts = 0
    end
    MarkerVis.Ghost(nil)
end

--- The Start position tool's preview, like the marker tool's: at the pointer (and at every image of it under the symmetry) the icon a placed start position gets, its
--- 3D marker prop, the ring in the template's colour and the name it would get (ARMY_<n>, the next free numbers in the order armies.lua Place uses).
local function ArmyGhost(p)
    local Armies = Mod('armies', '/lua/editor/armies.lua')
    local tpl = Tools.Templates()['Blank Marker']
    local color = Tools.ColorHex(tpl and tpl.color)
    local used = {}
    for _, nm in Armies.Names() do used[nm] = true end
    local points = Mod('symmetry', '/lua/editor/symmetry.lua').Points(p[1], p[3])
    local count = table.getn(points)
    local spots = {}
    local n = 0
    for i, q in points do
        repeat n = n + 1 until not used['ARMY_' .. n]
        local gx, gz = Grid.SnapMarker('Blank Marker', q.x, q.z)
        local gy = GroundHeight(gx, gz)
        ed_overlay_icon('cur:armyi' .. i, gx, gy + LIFT, gz, '/textures/editor/markers/army.dds', ICON_PX, 'C0FFFFFF')
        Line(nil, 'cur:armyr' .. i, Circle(gx, gz, 1.6, 24, gy, 3), color, 0.4, 2, 4, true)
        ghostN = ghostN + 1
        local g = ghostLabels[ghostN]
        if not g then
            g = {}
            ghostLabels[ghostN] = g
        end
        g.name, g.x, g.y, g.z = 'ARMY_' .. n, gx, gy, gz
        table.insert(spots, { gx, gy, gz })
    end
    for i = count + 1, armyGhosts do
        Remove('cur:armyi' .. i)
        Remove('cur:armyr' .. i)
    end
    armyGhosts = count
    MarkerVis.Ghost(spots, tpl and tpl.prop, 'Blank Marker', 'ARMY_1')
end

--- The Draw chain tool's preview: the ring and cross of a marker at the pointer, and a line from the end of the chain being drawn (chains.lua DrawTail) to it.
local function ChainGhost(p, px)
    local color = 'FFA020'
    local tx, tz = Mod('chains', '/lua/editor/chains.lua').DrawTail()
    if GhostSame('chain', p[1], p[2], p[3], px, tx or 0, tz or 0) then return end
    RingAt('cur:ring', p[1], p[3], 1.6, 24, p[2], 3, color, 0.4, 2, 4)
    local s = 4 * px
    local pts = {}
    Push(pts, p[1] - s, p[3]) Push(pts, p[1] + s, p[3])
    Line(nil, 'cur:cross', pts, color, 0.2, 2, 3, false)
    if tx then
        Line(nil, 'cur:chain', { tx, GroundHeight(tx, tz) + LIFT + 0.45, tz, p[1], GroundHeight(p[1], p[3]) + LIFT + 0.45, p[3] }, color, 0.2, 2, 3, false)
    else
        Remove('cur:chain')
    end
end

local RING_IDS = { 'cur:ring1', 'cur:ring2', 'cur:ring3', 'cur:ring4' }
local BRUSH_IDS = { 'cur:brush1', 'cur:brush2', 'cur:brush3', 'cur:brush4' }
local SLOT_IDS = { '1', '2', '3', '4' }

local function Pointer(view, ui, mouseX, mouseY)
    ghostN = 0
    local ghostDrawn = false
    local tool = ui.ActiveTool()
    local over = view.CursorOverWorld
    local p = over and GetMouseWorldPos() or nil
    -- while a stroke is being dragged the engine no longer tracks the hover position: follow the dragger's own pointer instead
    local dp = ui.State.dragPointer
    if dp then p = { dp[1], GroundHeight(dp[1], dp[2]), dp[2] } end
    -- just after a stroke: stay where it ended until the real mouse moves (see ui.lua OnWorldPress)
    local hold = ui.State.holdPointer
    if hold then
        if dp or math.abs(mouseX - hold[3]) + math.abs(mouseY - hold[4]) > 2 then
            ui.State.holdPointer = nil
        else
            p = { hold[1], GroundHeight(hold[1], hold[2]), hold[2] }
        end
    end
    -- the brush preview stays where the pointer last was in the world while a panel is used (so its settings can be tuned with feedback)
    if p then
        local lb = lastBrushPos
        if not lb then
            lb = {}
            lastBrushPos = lb
        end
        lb[1], lb[2], lb[3] = p[1], p[2], p[3]
    elseif tool and tool.kind == 'brush' and lastBrushPos then
        p = lastBrushPos
    end
    local px = PixelSize(view, mouseX, mouseY)
    local _, _, _, rev = ed_cmd_depth()          -- the native height revision: a ring is laid onto the ground again when it moves (RingAt)
    frameRev = rev or 0

    -- brush ring: the footprint of one dab, with an inner ring where the falloff starts
    if tool and tool.kind == 'brush' and p then
        local r = Terrain.Brush.radius
        local color = BRUSH_COLORS[tool.id] or 'FFFFFF'
        RingAt('cur:ring', p[1], p[3], r, 48, p[2], math.max(2, r), color, 0.4, 2, 4)
        BrushPreview(p, r, tool.id)
        -- the images of the brush under the symmetry
        local images = Mod('symmetry', '/lua/editor/symmetry.lua').Points(p[1], p[3])
        for i = 2, 4 do
            local q = images[i]
            if q then
                local gy = GroundHeight(q.x, q.z)
                RingAt(RING_IDS[i], q.x, q.z, r, 48, gy, math.max(2, r), color, 0.3, 2, 3)
                BrushPreview({ q.x, gy, q.z }, r, tool.id, SLOT_IDS[i])        -- every image shows the weights, not only the first
            else
                Remove(RING_IDS[i])
                Remove(BRUSH_IDS[i])
                previewKeys[SLOT_IDS[i]] = nil
            end
        end
        Remove('cur:inner')
        Remove('cur:cross')
    elseif tool and tool.kind == 'marker' and p then
        -- ghost of the marker about to be placed: ring and cross in the template's colour
        local tpl = Tools.Templates()[Tools.MarkerType]
        local color = Tools.ColorHex(tpl and tpl.color)
        local gx, gz = Grid.SnapMarker(Tools.MarkerType, p[1], p[3])      -- resource markers sit on the build grid
        ghostDrawn = true
        if not GhostSame('marker', gx, gz, p[2], px, color, Tools.MarkerType) then
            RingAt('cur:ring', gx, gz, 1.6, 24, p[2], 3, color, 0.4, 2, 4)
            local s = 4 * px
            local pts = {}
            Push(pts, gx - s, gz) Push(pts, gx + s, gz)
            Line(nil, 'cur:cross', pts, color, 0.2, 2, 3, false)
            local info = Grid.ResourceInfo(Tools.MarkerType)
            if info then
                local fx, fz, sk = info.fx / 2, info.fz / 2, info.skirt / 2
                Line(nil, 'cur:fp', Box(gx - fx, gz - fz, gx + fx, gz + fz), FOOTPRINT_COLOR[Tools.MarkerType] or 'FFFFFF', 0.15, 1.5, 3, true)
                Line(nil, 'cur:sk', Box(gx - sk, gz - sk, gx + sk, gz + sk), '70' .. (FOOTPRINT_COLOR[Tools.MarkerType] or 'FFFFFF'), 0.1, 1, 1, true)
            else
                Remove('cur:fp') Remove('cur:sk')
            end
        end
        Remove('cur:inner')
    elseif tool and tool.kind == 'area' and p then
        ghostDrawn = true
        if not GhostSame('area', p[1], p[3], px, 0, '', '') then
            local s = 10 * px
            local pts = {}
            Push(pts, p[1] - s, p[3]) Push(pts, p[1] + s, p[3])
            Line(nil, 'cur:ring', pts, COLOR_AREA, 0.2, 2, 3, false)
            pts = {}
            Push(pts, p[1], p[3] - s) Push(pts, p[1], p[3] + s)
            Line(nil, 'cur:cross', pts, COLOR_AREA, 0.2, 2, 3, false)
        end
        Remove('cur:inner')
    elseif tool and tool.id == 'army' and p then
        ArmyGhost(p)
        Remove('cur:ring') Remove('cur:inner') Remove('cur:cross')
    elseif tool and tool.id == 'chain' and p then
        ChainGhost(p, px)
        ghostDrawn = true
        Remove('cur:inner')
    else
        Remove('cur:ring') Remove('cur:inner') Remove('cur:cross')
    end
    if not (tool and tool.id == 'army' and p) then ArmyGhostOff() end
    if not (tool and tool.id == 'chain' and p) then Remove('cur:chain') end
    if not (tool and tool.kind == 'brush' and p) then
        Remove('cur:brush')
        -- the images of the brush under symmetry go with it (one ring stayed on the map after the tool was changed)
        for i = 2, 4 do
            Remove(RING_IDS[i])
            Remove(BRUSH_IDS[i])
        end
        if next(previewKeys) ~= nil then previewKeys = {} end
    end
    if not ghostDrawn then ghostSig.kind = false end          -- (another tool drew over the ring and cross: the ghost is laid again when this tool comes back)
    if not (tool and tool.kind == 'marker' and p) then
        Remove('cur:fp') Remove('cur:sk')
    end

    -- the selection box being dragged out with the select tool
    -- (a camera-aligned box is a rectangle on the screen: its outline is the sides dropped onto the ground, in one closed line or, where a side reaches the sky, in pieces)
    local mq = Tools.Marquee
    local runs = mq and Tools.MarqueeRuns()
    local shown = 0
    if runs then
        for _, run in runs do
            if shown >= 4 then break end
            shown = shown + 1
            local pts = {}
            for i = 1, table.getn(run), 2 do Push(pts, run[i], run[i + 1], true) end
            Line(nil, shown == 1 and 'cur:marquee' or ('cur:marquee' .. shown), pts, '80F0FF', 0.4, 2, 3, run.closed)
        end
    elseif mq then
        shown = 1
        Line(nil, 'cur:marquee', Box(math.min(mq[1], mq[3]), math.min(mq[2], mq[4]), math.max(mq[1], mq[3]), math.max(mq[2], mq[4])), '80F0FF', 0.4, 2, 3, true)
    end
    for i = shown + 1, 4 do Remove(i == 1 and 'cur:marquee' or ('cur:marquee' .. i)) end

    -- the area being dragged out
    local s, e = ui.State.areaStart, ui.State.areaEnd
    if s and e then
        Line(nil, 'cur:area', Box(math.min(s[1], e[1]), math.min(s[2], e[2]), math.max(s[1], e[1]), math.max(s[2], e[2])), 'FFFFFF', 0.8, 2, 8, true)
    else
        Remove('cur:area')
    end
    return px
end

-- ---- entry points ------------------------------------------------------------------------------------------------------------------

--- Removes every overlay line and label (play mode, shutdown).
-- (Clear touches more module locals than one Lua 5.0 function may hold as upvalues, 32: the resets are split over two helpers.)
local function ForgetIds()
    areaIds = {}
    markerIds = {}
    selIds = {}
    fpIds = {}
    gridIds = {}
    gridKey = ''
    axisIds = {}
    axisKey = ''
    rulerKey = ''
    gizmoIds = {}
    gizmoKeys = {}
    areaKeys, fpKeys, iconKeys, selKeys = {}, {}, {}, {}
    handleKeyT[1] = false
    lastHover, lastEpoch = -1, -1
    selSetAt = -1
    LabelsForget()
end

local function ForgetObjects()
    unitIds = {}
    unitKeyT[9] = -100
    decalSelIds = {}
    decalSelKey = ''
    rampKey = ''
    propSelIds = {}
    propSelKey = ''
    import('/lua/editor/ttoverlay.lua').Forget()
    lastRevision = -1
    lastChanged = -1
    handleCount = 0
    absent, ringKeys, previewKeys = {}, {}, {}          -- (the engine's overlay was emptied: nothing of the pointer's lines is there any more)
    ghostSig.kind = false
end

function Clear()
    Cursors.Reset(View())
    if Available() then ed_overlay_slope_off() end
    slopeShown = false
    if nativeGridShown then
        ed_overlay_grid_off()
        nativeGridShown = false
    end
    MarkerVis.Clear()
    Validate.Clear()
    if Available() then
        ed_overlay_clear()
    end
    ForgetIds()
    TerrainEpoch.Bump()
    groundEpoch = groundEpoch + 1
    pcall(function() import('/lua/editor/pathtool.lua').Forget() end)
    pcall(function() import('/lua/editor/chains.lua').Forget() end)
    pcall(function() import('/lua/editor/camframe.lua').Forget() end)
    pcall(function() import('/lua/editor/unitrings.lua').Forget() end)
    pcall(function() import('/lua/editor/gizmo.lua').Forget() end)
    pcall(function() import('/lua/editor/placer.lua').Clear() end)
    ForgetObjects()
    pcall(function() import('/lua/editor/maskgen.lua').OverlayReset() end)
    HideLabelsFrom(1)
end

--- The layers that do not need the map document (grid, slope, axes, ruler, gizmo, rings, paths, chains, ghosts, terrain types). Split from Update: Lua 5.0 refuses a function with more than 32 upvalues.
local function DrawLayers(ui, view, px)
    local t0
    t0 = Perf.Begin()
    GridNative(view, px)
    SlopeView(view)
    DrawAxes()
    DrawRuler()
    Perf.End('overlay: grid, slope, axes, ruler', t0)
    t0 = Perf.Begin()
    DrawGizmo()
    Perf.End('overlay: gizmo', t0)
    t0 = Perf.Begin()
    DrawUnits(ui)
    DrawDecalSelection(ui)
    DrawRamp()
    Perf.End('overlay: unit rings, decal sel, ramp', t0)
    t0 = Perf.Begin()
    Call('unitview', '/lua/editor/unitview.lua', 'OnFrame')       -- the unit viewer's bones follow the animation every frame
    Perf.End('overlay: unitview', t0)
    t0 = Perf.Begin()
    Call('pathtool', '/lua/editor/pathtool.lua', 'Draw', ui)      -- spline paths (stage T4)
    Perf.End('overlay: pathtool', t0)
    t0 = Perf.Begin()
    Call('chains', '/lua/editor/chains.lua', 'Draw', ui)        -- marker chains (parity audit)
    Call('camframe', '/lua/editor/camframe.lua', 'Update', ui, view)      -- the field of view of a selected Camera Info marker
    Perf.End('overlay: chains', t0)
    t0 = Perf.Begin()
    Call('unitrings', '/lua/editor/unitrings.lua', 'Draw', ui)     -- range rings of the selected units
    DrawPropSelection(ui)
    Perf.End('overlay: range rings, prop sel', t0)
    t0 = Perf.Begin()
    Call('placer', '/lua/editor/placer.lua', 'Update', ui, view)      -- the ghost of what the Place tools put down
    Call('placer', '/lua/editor/placer.lua', 'UpdateMoves', ui)        -- the ghosts of what the select tools drag
    Perf.End('overlay: placer', t0)
    t0 = Perf.Begin()
    DrawTypes(view)
    Call('maskgen', '/lua/editor/maskgen.lua', 'DrawOverlay', view)       -- the mask generator's preview
    Perf.End('overlay: terrain types, maskgen', t0)

end

--- The document's objects: validation, marker meshes, outlines, icons, handles, labels (see DrawLayers for why this is a function of its own).
local function UpdateObjects(view, px)
    local t0
    t0 = Perf.Begin()
    Validate.Update()
    Perf.End('overlay: validate', t0)
    -- (before the rebuild below: the meshes sync the markers' heights to the terrain, and the icons are drawn at those heights)
    t0 = Perf.Begin()
    MarkerVis.Update()
    Perf.End('overlay: marker meshes', t0)
    -- The objects are laid onto the terrain again only when something changed: an edit of the objects (Tools.Changed), the validation, or the ground (TerrainEpoch). A hover alone
    -- touches the area outlines and the hovered marker only. (It used to rebuild everything on every change and every half second.)
    t0 = Perf.Begin()
    if lastChanged ~= Tools.Changed or lastRevision ~= Validate.Revision or lastEpoch ~= groundEpoch then
        lastChanged = Tools.Changed
        lastRevision = Validate.Revision
        lastEpoch = groundEpoch
        lastHover = Tools.HoverRev
        local t1 = Perf.Begin()
        RebuildFootprints()
        Perf.End('overlay: rebuild footprints', t1)
        t1 = Perf.Begin()
        RebuildAreas()
        Perf.End('overlay: rebuild areas', t1)
        t1 = Perf.Begin()
        RebuildMarkerIcons()
        Perf.End('overlay: rebuild icons', t1)
        RebuildMarkerHighlights()
    elseif lastHover ~= Tools.HoverRev then
        lastHover = Tools.HoverRev
        RebuildAreas()
        RebuildMarkerHighlights()
    end
    Perf.End('overlay: rebuild objects', t0)
    t0 = Perf.Begin()
    Handles(view, px)
    Perf.End('overlay: area handles', t0)
    t0 = Perf.Begin()
    UpdateLabels(view, px)      -- every frame: the names follow a moving marker or camera without lag (only the position is set per frame, text and colour when they change)
    Perf.End('overlay: labels', t0)
end

--- Moves `groundEpoch` when the ground may have changed (see its declaration).
local function StepGround(stroking)
    if stroking then return end
    local g = ground
    local _, _, _, rev = ed_cmd_depth()
    rev = rev or 0
    local hist = Mod('history', '/lua/editor/history.lua').Version
    local mode = Mod('meshview', '/lua/editor/meshview.lua').Mode()
    local now = GetSystemTimeSeconds()
    local net = Mod('meshview', '/lua/editor/meshview.lua').Active() and 5 or 90
    if rev ~= g.rev or TerrainEpoch.Revision ~= g.touch or hist ~= g.hist or mode ~= g.mode or now - g.at >= net then
        g.rev, g.touch, g.hist, g.mode, g.at = rev, TerrainEpoch.Revision, hist, mode, now
        groundEpoch = groundEpoch + 1
    end
end

--- Per-frame update while editing. `ui` is the ui.lua module. Returns false when the engine has no overlay natives (the old dots
--- are used then).
function Update(ui)
    if not Available() then
        return false
    end
    local view = View()
    if not view then
        return true
    end
    frameCount = frameCount + 1
    Call('display', '/lua/editor/display.lua', 'Frame')
    -- The engine keeps its overlay objects (icons, lines, decals) in static tables that outlive a session, and this module's own id lists are lost with the
    -- Lua state: after opening another map the markers of the previous one stayed on screen (outside the new terrain, hanging at their old heights).
    if not engineCleared then
        engineCleared = true
        Clear()
    end
    if Map.Doc ~= lastDoc then
        if lastDoc then Clear() end
        lastDoc = Map.Doc
    end

    local tAll = Perf.Begin()
    local stroking = ui.State.dragPointer ~= nil and ui.State.dragPointer ~= false
    TerrainEpoch.Step(stroking)
    StepGround(stroking)
    local pos = GetMouseScreenPos()
    local mx, my = (pos and (pos[1] or pos.x)) or 0, (pos and (pos[2] or pos.y)) or 0
    local t0 = Perf.Begin()
    local px = Pointer(view, ui, mx, my)
    Perf.End('overlay: pointer', t0)
    DrawLayers(ui, view, px)

    -- hover feedback for the select tool
    t0 = Perf.Begin()
    local tool = ui.ActiveTool()
    local p = view.CursorOverWorld and tool and tool.kind == 'select' and GetMouseWorldPos() or nil
    local hit = Tools.UpdateHover(p and p[1], p and p[3], mx, my, tool and tool.pick)       -- (Select marker only hovers markers, Select area only areas)
    Cursors.Update(view, tool, hit)
    Perf.End('overlay: hover pick + cursor', t0)

    -- everything above works without a map document (the build grid, the slope view, the pointer); the rest draws the document's objects
    if not Map.Doc then
        Perf.End('overlay: update (all)', tAll)
        return true
    end

    UpdateObjects(view, px)
    Perf.End('overlay: update (all)', tAll)
    return true
end
