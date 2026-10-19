-- The graph library (stage T7): the ready graphs of graphpresets/ marked `library = true` in index.lua, and the renderer of their thumbnails. A thumbnail is a coloured picture of what the graph
-- makes: the heights as shaded relief (hillshade with cast shadows) under a land colour ramp and water, the texture layers tinted on top. Rendered at the preview resolution of the open map
-- (use a 1025 map), written as a DXT5 DDS under graphpresets/thumbs/ (the palette shows it) and, for the documentation, as three raw 16 bit channel files that scripts/make_graph_thumbs.py
-- turns into PNG.
--
--   List()                     -> { { id, name, note } } of the library graphs
--   Render(id, size)           -> r, g, b fields (the caller frees them) of the picture, or nil and a message
--   WriteThumb(id, dir, size)  -> true: <dir>/<id>.dds written (a disk folder of the editor tree, e.g. 'lua/editor/graphpresets/thumbs')
--   Export(id, dir)            -> true: <dir>/<id>_r.raw, _g.raw, _b.raw (16 bit little endian words, 0..65535 = 0..1) for make_graph_thumbs.py
--   ThumbPath(id)              -> the VFS path of a shipped thumbnail, or nil
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local Graph = import('/lua/editor/graph.lua')
local Nodes = import('/lua/editor/graphnodes.lua')
local GRun = import('/lua/editor/graphrun.lua')
local History = import('/lua/editor/history.lua')

THUMB_DIR = 'graphpresets/thumbs'

-- the tint of each texture layer in the picture
local TINT = {
    [1] = { 0.30, 0.50, 0.22 }, [2] = { 0.50, 0.45, 0.40 }, [3] = { 0.88, 0.80, 0.55 }, [4] = { 0.96, 0.98, 1.0 },
    [5] = { 0.20, 0.52, 0.18 }, [6] = { 0.38, 0.37, 0.37 }, [7] = { 0.05, 0.05, 0.07 }, [8] = { 0.70, 0.35, 0.20 },
}
local LAND = '0:#cbbd8c;0.06:#6f9d4b;0.35:#4a7834;0.6:#8a7550;0.85:#8d8d8d;1:#ffffff'

function List()
    local out = {}
    local ok, index = pcall(import, '/lua/editor/graphpresets/index.lua')
    if ok and index then
        for _, p in index.List do
            if p.library then table.insert(out, { id = p.id, name = p.name, note = p.note }) end
        end
    end
    return out
end

local function Water()
    local ok, v = pcall(function() return import('/lua/editor/world.lua').Get().water_elev end)
    return (ok and v) or 25
end

local function Op(S, name, p) return S:Op(name, p) end

--- The picture of the current preview run (fields r, g, b owned by `S`), or nil.
local function Picture(S, run, graph)
    local base = run:BaseHere()
    local cur = GRun.FinalHeight(run, S, base)
    if not cur then cur = base end                 -- a graph that only paints: the ground it paints on (the demo terrain)
    local mn, mx = Fields.Stats(cur)
    local water = Water()
    local T7 = import('/lua/editor/graphnodes_t7.lua')
    local stops = T7.RampStops('custom', LAND, false, 1)
    local hi = math.max(mx, water + 8)
    local ramp, extra = Fields.OpMulti('color_ramp', { a = cur, stops = stops, lo = water, hi = hi, interp = 'smooth' })
    S:Add(ramp)
    for _, f in extra do S:Add(f) end
    local ch = { ramp, extra.g, extra.b }
    -- texture layers tinted on top
    for _, id in Graph.Order() do
        local node = Graph.NodeById(id)
        local def = Nodes.Defs[node.type]
        if def and def.output == 'layer' and not node.off then
            local mask = run:Value(node.id, 'view')
            if mask then
                local layer = math.floor((node.params.layer or 2) + 0.5)
                local tint = TINT[layer] or TINT[2]
                local strength = node.params.strength or 1
                for i = 1, 3 do
                    local c = Op(S, 'const', { like = cur, value = tint[i] })
                    ch[i] = Op(S, 'blend', { a = ch[i], b = c, mask = mask, mode = 'normal', opacity = 0.75 * strength * (layer == 7 and 0.4 or (layer == 6 and 0.7 or 1)) })
                end
            end
        end
    end
    -- water
    local wmask = Op(S, 'water_below', { a = cur, level = water, soft = 0.4 })
    local depth = Op(S, 'water_depth', { a = cur, level = water })
    local dk = Op(S, 'affine', { a = Op(S, 'clamp', { a = depth, lo = 0, hi = 14 }), mul = -0.025, add = 1 })
    local blue = { 0.10, 0.30, 0.55 }
    for i = 1, 3 do
        local c = Op(S, 'affine', { a = dk, mul = blue[i], add = 0 })
        ch[i] = Op(S, 'blend', { a = ch[i], b = c, mask = wmask, mode = 'normal', opacity = 0.92 })
    end
    -- light and shadow
    local shade = Op(S, 'hillshade', { a = cur, azimuth = 315, altitude = 38, z = 4.0, shadows = 1, shadow_len = 300, ambient = 0.1 })
    local lit = Op(S, 'affine', { a = shade, mul = 1.0, add = 0.2 })
    for i = 1, 3 do
        ch[i] = Op(S, 'clamp', { a = Op(S, 'mul', { a = ch[i], b = lit }), lo = 0, hi = 1 })
    end
    return ch
end

--- Loads the graph, evaluates it at the preview resolution and draws it. The channels belong to the scope S.
local function RenderIn(S, id)
    local ok, err = Graph.LoadPreset(id)
    if not ok then return nil, err end
    GRun.Release()
    local run = GRun.NewRun{ step = GRun.PreviewStep(), thumbs = false, only = GRun.OutputNeeds(Graph.Current) }
    local good, report = pcall(run.Evaluate, run)
    if not good then
        run:Free()
        return nil, tostring(report)
    end
    for nid, msg in report.errors do
        run:Free()
        return nil, 'node ' .. nid .. ': ' .. tostring(msg)
    end
    local ch, why = Picture(S, run, Graph.Current)
    run:Free()
    return ch, why
end

function Render(id, size)
    local out
    Fields.Run(function(S)
        local ch, why = RenderIn(S, id)
        if ch then
            out = {}
            for i = 1, 3 do out[i] = S:Keep(ch[i]) end
        else
            out = why
        end
    end)
    if type(out) == 'string' or out == nil then return nil, out end
    return out[1], out[2], out[3]
end

--- Heights of a demo mountain range written into the map for graphs that only paint (they have no height output of their own); undone by the caller.
local function DemoTerrain()
    local w, h = ed_terrain_info()
    return Fields.Run(function(S)
        local m = S:Op('musgrave', { width = w, height = h, seed = 7, scale = w * 0.3, octaves = 7 })
        local hgt = S:Op('affine', { a = m, mul = 100, add = 18 })
        local depth = History.Depth()
        Fields.Apply{ height = hgt, masks = {}, label = 'demo terrain' }
        return History.Depth() > depth
    end)
end

local function HasHeightOutput()
    for _, n in Graph.Current.nodes do
        local d = Nodes.Defs[n.type]
        if d and d.output == 'height' and not n.off then return true end
    end
    return false
end

--- Runs fn(S, id) for the graph on a clean map (a demo terrain under graphs that only paint) and cleans up afterwards.
local function WithGraph(id, fn)
    local ok, err = Graph.LoadPreset(id)
    if not ok then return nil, err end
    local demo = false
    if not HasHeightOutput() then
        GRun.Release()
        demo = DemoTerrain()
        GRun.Release()
    end
    local result, msg
    Fields.Run(function(S)
        local ch, why = RenderIn(S, id)
        if not ch then
            msg = why
            return
        end
        result = fn(S, ch)
    end)
    GRun.Release()
    if demo then
        History.Undo()
        GRun.Release()
    end
    return result, msg
end

local shown = {}

--- The VFS path of the shipped thumbnail of a library graph, or nil. The DDS beside the graph files is read from disk and handed to the preview folder of the field engine (the same way the
--- node thumbnails reach a Bitmap), so it does not matter where the editor tree lives.
function ThumbPath(id)
    if shown[id] then return shown[id] end
    local ok, disk = pcall(ed_vfs_to_disk, '/lua/editor/graphlib.lua')
    if not (ok and disk) then return nil end
    local file = string.gsub(disk, '[^/\\]*$', '') .. 'graphpresets/thumbs/' .. id .. '.dds'
    local good, px, w, h = pcall(ed_dds_read, file)
    if not (good and px and w and h) then return nil end
    local path = Fields.PreviewPixels(px, w, h)
    shown[id] = path
    return path
end

--- <dir>/<id>.dds: a size x size DXT5 picture for the palette.
function WriteThumb(id, dir, size)
    local GraphColor = import('/lua/editor/graphcolor.lua')
    return WithGraph(id, function(S, ch)
        local a = S:Op('const', { like = ch[1], value = 1 })
        return GraphColor.Write({ r = ch[1], g = ch[2], b = ch[3], a = a }, dir .. '/' .. id .. '.dds', size)
    end)
end

--- <dir>/<id>_r.raw, _g.raw, _b.raw: the channels as 16 bit words at the preview resolution of the open map; returns the sample count of a side.
function Export(id, dir)
    return WithGraph(id, function(S, ch)
        local w = Fields.Info(ch[1])
        local names = { 'r', 'g', 'b' }
        for i = 1, 3 do
            local ok, err = ed_img_write(dir .. '/' .. id .. '_' .. names[i] .. '.raw', ch[i], { bits = 16, lo = 0, hi = 1 })
            if not ok then error(tostring(err)) end
        end
        return w
    end)
end
