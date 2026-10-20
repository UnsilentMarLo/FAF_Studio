-- The "Import mesh" dialog of the Mesh import panel: an OBJ file becomes SCM v5 patches in <map folder>/terrain and entries in the manifest (meshimport.lua).
--
--   Open()      the dialog; Preview runs the conversion without writing, Import writes patches + manifest
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Imp = import('/lua/editor/meshimport.lua')
local Mesh = import('/lua/editor/meshmap.lua')
local Map = import('/lua/editor/map.lua')

-- the options live here, so a second import starts where the first ended
Opts = false
Path = ''
Replace = false
Cache = false                     -- { path, stamp, obj, groupBy }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Reset()
    Opts = {}
    for k, v in Imp.Defaults do Opts[k] = v end
end

--- The text of the OBJ at `path` (absolute, or relative to the map folder), and the disk path it was found at.
local function ReadObj(path)
    path = string.gsub(path, '\\', '/')
    local candidates = { path }
    local dir = Mesh.Dir()
    if dir then
        table.insert(candidates, dir .. '/' .. path)
        table.insert(candidates, dir .. '/terrain/' .. path)
    end
    for _, p in candidates do
        if ed_file_stamp(p) then return ed_read_file(p), p end
    end
end

local function Raise(d, s)
    for _, c in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(c) end
    d:Raise(s.field) d:Raise(s.field.frame)
end

Show = function(lines) end        -- the open dialog replaces this with its info labels

--- Reads the OBJ named in Path and converts it with Opts; -> result, or nil (the reason is shown).
function Preview()
    if Path == '' then Show({ 'Enter the path of an OBJ file first.' }) return nil end
    local text, found = ReadObj(Path)
    if not text then Show({ 'File not found: ' .. Path }) return nil end
    local model = Mesh.Current
    local o = {}
    for k, v in Opts or Imp.Defaults do o[k] = v end
    o.mapSize = (model and model.settings.size) or 1024
    local stamp = ed_file_stamp(found)
    if not (Cache and Cache.path == found and Cache.stamp == stamp and Cache.groupBy == o.groupBy) then
        Show({ 'Reading ' .. found .. ' ...' })
        Cache = { path = found, stamp = stamp, groupBy = o.groupBy, obj = Imp.ParseObj(text, o.groupBy) }
    end
    local result = Imp.Build(Cache.obj, o)
    Show(Imp.Describe(result))
    return result
end

--- Converts and writes the patches and the manifest of the open map. -> list of file names, or nil + reason.
function Import()
    local folder = Mesh.Dir()
    if not folder then Show({ 'The map has no folder yet: save it first.' }) return nil, 'no folder' end
    local m = Mesh.Current
    if not m then m = Mesh.Load() or Mesh.FromMap() end
    local result = Preview()
    if not result then return nil, 'no result' end
    if result.stats.patches == 0 then Show({ 'Nothing to import: no triangles left.' }) return nil, 'empty' end
    local files, why = Imp.Commit(m, result, folder, { replace = Replace })
    if not files then Show({ 'Import failed: ' .. tostring(why) }) return nil, why end
    local path = Mesh.Save(m)
    Dialog.Close()
    import('/lua/editor/gui/panels_mesh.lua').SetModel(m)
    Say('mesh import: ' .. table.getn(files) .. ' patch files written, manifest ' .. (path and 'saved' or 'NOT saved'))
    if Map.Doc and Map.Doc.info.TerrainSystem ~= 'mesh' then
        Say('mesh import: turn on "Mesh map in scenario" in the Mesh terrain panel so the game loads the manifest')
    end
    return files
end

function Open()
    if not Opts then Reset() end
    local c = Skin.color
    local d = Dialog.Open('Import mesh: turns an OBJ file into terrain patches of the mesh map (old patch files stay on disk)', 640, 560)

    d:Label('OBJ file (full path, or relative to the map folder)', 14, 30, { color = c.textDim })
    local field = d:Field(14, 50, 612, 22, { text = Path, onChange = function(t) Path = t end })

    -- toggles
    local function Choice(label, x, y, key, values, names)
        d:Label(label, x, y + 4, { color = c.textDim })
        local buttons = {}
        local bx = x + 108
        for i, v in values do
            local value = v
            buttons[value] = d:Button(names[i], bx, y, 74, 22, function()
                Opts[key] = value
                for k, b in buttons do b:SetOn(k == value) end
            end, { toggle = true })
            bx = bx + 78
        end
        buttons[Opts[key]]:SetOn(true)
        return buttons
    end
    local function Toggle(label, x, y, w, key)
        local b = d:Button(label, x, y, w, 22, function(self) Opts[key] = self.on end, { toggle = true })
        b:SetOn(Opts[key] and true or false)
        return b
    end
    Choice('Up axis', 14, 82, 'axis', { 'y_up', 'z_up' }, { 'Y up', 'Z up' })
    Toggle('Mirror X', 330, 82, 74, 'mirrorX')
    Toggle('Mirror Z', 408, 82, 74, 'mirrorZ')
    Toggle('Flip faces', 486, 82, 84, 'flipWinding')
    Toggle('Flip V', 574, 82, 52, 'flipV')
    Choice('Normals', 14, 110, 'normals', { 'auto', 'smooth', 'flat' }, { 'File / auto', 'Smooth', 'Flat' })
    Choice('Light mask uv', 14, 138, 'uv2', { 'planar', 'copy' }, { 'Over map', 'Copy uv' })
    Choice('Materials by', 14, 166, 'groupBy', { 'material', 'object', 'none' }, { 'usemtl', 'o / g', 'One' })

    local function Slider(label, key, min, max, step, fmt, x, y, curve)
        local s = W.Slider(d.group, { label = label, min = min, max = max, step = step, fmt = fmt, compact = true, curve = curve,
            get = function() return Opts[key] end, set = function(v) Opts[key] = v end })
        s:Place(Skin.S(x), Skin.S(y), Skin.S(290))
        Raise(d, s)
        return s
    end
    Slider('Scale (OBJ unit to world unit)', 'scale', 0.01, 100, 0.01, '%.2f', 14, 198, 3)
    Slider('Height offset (world units)', 'offsetY', -200, 300, 0.5, '%.1f', 326, 198)
    Slider('Offset X', 'offsetX', -2000, 5000, 1, '%d', 14, 250)
    Slider('Offset Z', 'offsetZ', -2000, 5000, 1, '%d', 326, 250)
    Slider('Texture repeat when the file has no uv (units)', 'uvTile', 4, 512, 4, '%d', 14, 302)
    Slider('Patch tile (units)', 'tile', 32, 2048, 32, '%d', 326, 302)
    Slider('Vertices per patch (at most 65,535)', 'limit', 1000, 65535, 1000, '%d', 14, 354)
    local replace = d:Button('Replace the existing patches (their files stay on disk)', 326, 366, 300, 22, function(self) Replace = self.on end, { toggle = true })
    replace:SetOn(Replace)

    local info = {}
    for i = 1, 5 do info[i] = d:Label('', 14, 412 + (i - 1) * 16, { color = c.textDim, size = 'small' }) end
    Show = function(lines)
        for i = 1, 5 do info[i]:SetText(lines[i] or '') end
    end

    d:Button('Preview', 14, 516, 100, 28, function() Preview() end)
    d:Button('Import', 124, 516, 100, 28, function() Import() end)
    d:Button('Defaults', 234, 516, 100, 28, function() Reset() Dialog.Close() Open() end)
    d:Button('Close', 344, 516, 100, 28, function() Dialog.Close() end)
    return d
end
