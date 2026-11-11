-- The decal path tool (upstream's "decal path": EdDecalShape.cpp DecalsAlongPath, native ed_up_decal_path): click points on the ground, then Place: the active decal texture (Decals panel) is laid
-- end to end along the Catmull-Rom curve through the points, every decal turned along the curve. It does not touch the terrain (the Paths tool cannot do this: it always shapes the ground, and its
-- decals are scattered at random headings with a spacing, not laid as a continuous strip). One undo step per Place; symmetry applies (each image gets the strip of the images of the points).
-- Decals in this editor are square (decals.lua), so the length along the curve equals the width across it.
--
--   Points                  { { x, z }, ... } the clicked points
--   Settings                size (world units: length and width of a decal), overlap (0..0.9 of the length), withNormals (the matching normals decal), cutoff
--   Press(wx, wz, event)    the tool's click (ui.lua tool.OnPress): adds a point; Ctrl+click removes the last one
--   AddPoint / RemoveLast / Clear
--   Plan([points])          -> list of { cx, cz, x, z, sizeX, sizeZ, yaw } for the points (native; nil, 'no native' in an exe without it)
--   Place()                 -> number of decals placed (one undo entry), or nil, reason
--   Revision                bumped by every change (the overlay redraws)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Symmetry = import('/lua/editor/symmetry.lua')
local History = import('/lua/editor/history.lua')

Points = {}
Settings = { size = 8, overlap = 0, withNormals = true, cutoff = 1000 }
Revision = 0

local function Touch() Revision = Revision + 1 end

function AddPoint(x, z)
    table.insert(Points, { x = x, z = z })
    Touch()
    return table.getn(Points)
end

function RemoveLast()
    if table.getn(Points) > 0 then
        table.remove(Points)
        Touch()
    end
end

function Clear()
    Points = {}
    Touch()
end

function Press(wx, wz, event)
    if event and event.Modifiers and event.Modifiers.Ctrl then
        RemoveLast()
    else
        AddPoint(wx, wz)
    end
    return true
end

--- The footprints of the strip through `points` (default: the clicked ones).
function Plan(points)
    if not rawget(_G, 'ed_up_decal_path') then return nil, 'no native' end
    return ed_up_decal_path(points or Points, Settings.size, Settings.size, Settings.overlap)
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function FindIndex(tex, x, z)
    for i = ed_decal_count(), 1, -1 do
        local t0 = ed_decal_get(i)
        if t0 == tex then
            local _, _, _, px, py, pz = ed_decal_get(i)
            if math.abs(px - x) < 0.01 and math.abs(pz - z) < 0.01 then return i end
        end
    end
    return nil
end

local function Normals(tex)
    local n = string.gsub(tex, '_[aA][lL][bB][eE][dD][oO]%.dds$', '_normals.dds')
    if n ~= tex and DiskGetFileInfo(n) then return n end
    return nil
end

--- Lays the active decal texture along the curve (and along its symmetry images); one undo step. Returns the number of decals, or nil and the reason.
function Place()
    local Decals = import('/lua/editor/decals.lua')
    local tex = Decals.Active
    if not tex then return nil, 'pick a decal in the Decals panel first' end
    if table.getn(Points) < 2 then return nil, 'click at least two points first' end
    if not rawget(_G, 'ed_up_decal_path') then return nil, 'this build has no ed_up_decal_path' end
    local w, h = ed_terrain_info()
    local images = Symmetry.Points(Points[1].x, Points[1].z)
    local added = {}
    for slot = 1, table.getn(images) do
        local pts = {}
        for i, p in Points do
            local img = Symmetry.Points(p.x, p.z)[slot]
            if not img then pts = nil break end
            pts[i] = { x = img.x, z = img.z }
        end
        if pts then
            for _, d in Plan(pts) or {} do
                if d.cx >= 1 and d.cz >= 1 and d.cx <= (w or 257) - 2 and d.cz <= (h or 257) - 2 then
                    local y = Ground(d.cx, d.cz)
                    local one = { tex = tex, kind = 'albedo', x = d.cx, y = y, z = d.cz, heading = d.yaw, size = d.sizeX, cutoff = Settings.cutoff }
                    if Map.AddDecal(one.tex, one.kind, one.x, one.y, one.z, one.heading, one.size, one.cutoff) then
                        table.insert(added, one)
                        local ntex = Settings.withNormals and Normals(tex)
                        if ntex then
                            local two = { tex = ntex, kind = 'normals', x = d.cx, y = y, z = d.cz, heading = d.yaw, size = d.sizeX, cutoff = Settings.cutoff }
                            if Map.AddDecal(two.tex, two.kind, two.x, two.y, two.z, two.heading, two.size, two.cutoff) then table.insert(added, two) end
                        end
                    end
                end
            end
        end
    end
    local n = table.getn(added)
    if n == 0 then return 0 end
    History.Push({
        label = 'decal path (' .. n .. ' decals)',
        undo = function()
            for i = n, 1, -1 do
                local a = added[i]
                local idx = FindIndex(a.tex, a.x, a.z)
                if idx then Map.RemoveDecal(idx) end
            end
        end,
        redo = function()
            for _, a in added do Map.AddDecal(a.tex, a.kind, a.x, a.y, a.z, a.heading, a.size, a.cutoff) end
        end,
    })
    Clear()
    return n
end
