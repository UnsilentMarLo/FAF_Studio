-- FAFME importers and exporters: the preset files of FAForeverMapEditor (the map editor of the FAF community) read and written from the open map. The file formats and their
-- conversions are upstream's logic (faf-re src/editor/doc, bound as ed_* natives in moho/editor/EdUpImportLua.cpp); this module takes the data out of the editor's own models
-- and puts the imported data back with one undo step each. Commands and menu entries: gui/feature_fafme.lua (File > Import / Export).
--
--   markers       .fafmapmarkers   ExportMarkers([path]) the selected markers (all when none is selected)    ImportMarkers([path]) new markers with new names and their links
--   units         .scunits         ExportUnits([path]) the selected units (else every unit of the active army)   ImportUnits([path]) into the active army's INITIAL group
--   paint set     .proppaintset    ExportPaintSet([path]) the Props scatter list    ImportPaintSet([path]) replaces it (rotation and scale ranges per prop)
--   layer         .scmsl           ExportLayer(i [, path]) / ImportLayer(i [, path])     one texture layer (0 = Base ... 9 = Upper)
--   layer set     .scmst           ExportLayers([path]) / ImportLayers([path])           the shader and all ten layers
--   lighting      .scmlighting     ExportLighting([path]) / ImportLighting([path])       sun, ambient, shadow fill, specular, bloom, fog
--   sky           .scmskybox       ExportSky([path]) / ImportSky([path])                 dome, horizon and zenith colours, planets, cirrus
--   water         .scmwtr          ExportWater([path]) / ImportWater([path])             levels, colours, reflections, sun and the four wave layers
--
-- Every function returns true, text (a short report) or nil, reason, and says the same on the status line. `path` nil asks with the file dialog; each also has a `...Text`
-- variant that works on the text instead of a file (the self test and the file functions share them). Not here: .scmwaves (shore wave generators, with the water bodies).
--
-- Lua 5.0 dialect.

local function Map() return import('/lua/editor/map.lua') end
local function Tools() return import('/lua/editor/tools.lua') end
local function History() return import('/lua/editor/history.lua') end
local function Units() return import('/lua/editor/units.lua') end
local function Strata() return import('/lua/editor/strata.lua') end
local function Env() return import('/lua/editor/environment.lua') end
local function Scatter() return import('/lua/editor/scatter.lua') end

FILTERS = {
    markers = 'FAFME markers (*.fafmapmarkers)|*.fafmapmarkers|All files|*.*',
    units = 'FAFME units (*.scunits)|*.scunits|All files|*.*',
    paintset = 'FAFME prop paint set (*.proppaintset)|*.proppaintset|All files|*.*',
    layer = 'FAFME texture layer (*.scmsl)|*.scmsl|All files|*.*',
    layers = 'FAFME layer set (*.scmst)|*.scmst|All files|*.*',
    lighting = 'FAFME lighting (*.scmlighting)|*.scmlighting|All files|*.*',
    sky = 'FAFME sky (*.scmskybox)|*.scmskybox|All files|*.*',
    water = 'FAFME water (*.scmwtr)|*.scmwtr|All files|*.*',
}

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR fafme: ' .. text)
end

local function Fail(text)
    Say(text)
    return nil, text
end

local function Done(text)
    Say(text)
    return true, text
end

local function Available()
    return rawget(_G, 'ed_fafmapmarkers_read') ~= nil
end

local function Editable()
    if not Available() then return false, 'this editor build has no FAFME importers' end
    if not Map().Doc then return false, 'no map is open' end
    if Tools().ReadOnly then return false, 'this workspace is read-only' end
    return true
end

local function Size()
    local w, h = ed_terrain_info()
    if not w then return nil end
    return w - 1, (h or w) - 1
end

local function Ground(x, z)
    return ed_terrain_get(math.floor(x + 0.5), math.floor(z + 0.5)) or 0
end

local function ReadFile(path)
    local text = ed_read_file(path)
    if not text then return nil, 'cannot read ' .. tostring(path) end
    return text
end

local function WriteFile(path, text)
    if not ed_write_file(path, text) then return nil, 'cannot write ' .. tostring(path) end
    return true
end

local function BaseName(path)
    return (string.gsub(path or '', '^.*[/\\]', ''))
end

--- The path of a file to read / write: `path` or the file dialog (nil when the dialog was cancelled).
local function Ask(save, title, key, name, path)
    if path then return path end
    return ed_file_dialog(save, title, FILTERS[key], name or '')
end

--- Reads the file and calls `fn(text)`; returns what it returns.
local function ImportFile(path, title, key, fn)
    local ok, why = Editable()
    if not ok then return Fail(why) end
    path = Ask(false, title, key, '', path)
    if not path then return nil, 'cancelled' end
    local text, err = ReadFile(path)
    if not text then return Fail(err) end
    local done, report = fn(text, path)
    if not done then return nil, report end
    return Done(report .. ' (from ' .. BaseName(path) .. ')')
end

local function ExportFile(path, title, key, name, fn)
    if not Available() then return Fail('this editor build has no FAFME exporters') end
    if not Map().Doc then return Fail('no map is open') end
    path = Ask(true, title, key, name, path)
    if not path then return nil, 'cancelled' end
    local text, report = fn()
    if not text then return Fail(report) end
    local ok, err = WriteFile(path, text)
    if not ok then return Fail(err) end
    return Done(report .. ' to ' .. BaseName(path))
end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local c = {}
    for k, x in v do c[k] = Copy(x) end
    return c
end

-- ---- markers ----------------------------------------------------------------------------------------------------------------------------------

local function MarkerTable()
    return Map().Doc.save.MasterChain._MASTERCHAIN_.Markers
end

local function Triple(v)
    if type(v) == 'table' then return { v[1] or 0, v[2] or 0, v[3] or 0 } end
    return { 0, 0, 0 }
end

--- The .fafmapmarkers text of the markers `names` (all of them when the list is empty). Returns the text and a count, or nil and a reason.
function MarkersToText(names)
    local list, count = {}, 0
    local markers = MarkerTable()
    local sorted = {}
    for name, _ in markers do table.insert(sorted, name) end
    table.sort(sorted)
    for _, name in sorted do
        local m = markers[name]
        table.insert(list, { name = name, type = m.type or 'Blank Marker', position = Triple(m.position), orientation = Triple(m.orientation), adjacentTo = m.adjacentTo or '' })
    end
    local w, h = Size()
    local text, err = ed_fafmapmarkers_write(list, { names = names or {}, width = w or 0, height = h or 0 })
    if not text then return nil, err end
    count = (names and table.getn(names) > 0) and table.getn(names) or table.getn(list)
    return text, count
end

local function SelectedMarkerNames()
    local names = {}
    for _, it in Tools().Items or {} do
        if it.kind == 'marker' then table.insert(names, it.name) end
    end
    return names
end

function ExportMarkers(path)
    return ExportFile(path, 'Export markers', 'markers', 'markers.fafmapmarkers', function()
        local text, count = MarkersToText(SelectedMarkerNames())
        if not text then return nil, count end
        return text, 'exported ' .. count .. ' marker(s)'
    end)
end

--- Adds the markers of a .fafmapmarkers text under new names (upstream's: the type's next free one, a start position is ARMY_<n> clear of the scenario's armies), with their links;
--- one undo step; they become the selection. Returns true and a report, or nil and a reason.
function ImportMarkersText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local markers = MarkerTable()
    local doc = Map().Doc
    local existing, reserved = {}, {}
    for name, _ in markers do table.insert(existing, name) end
    for name, _ in doc.save.Armies or {} do table.insert(reserved, name) end
    local result, err = ed_fafmapmarkers_read(text, { existing = existing, reserved = reserved })
    if not result then return nil, err end
    local templates = Tools().Templates()
    local made = {}
    for _, m in result.markers do
        local x, y, z = m.position[1], m.position[2], m.position[3]
        local fields = {}
        for k, v in templates[m.type] or {} do
            if type(v) ~= 'function' then fields[k] = Copy(v) end
        end
        local marker = Map().AddMarker(m.name, m.type, x, Ground(x, z), z, fields)
        marker.position = Map().MakeVec3(x, Ground(x, z), z)
        marker.orientation = Map().MakeVec3(m.orientation[1], m.orientation[2], m.orientation[3])
        if table.getn(m.links) > 0 then marker.adjacentTo = table.concat(m.links, ' ') end
        table.insert(made, { name = m.name, marker = marker })
    end
    local n = table.getn(made)
    if n > 0 then
        local T = Tools()
        local function Select()
            local sel = {}
            for _, e in made do table.insert(sel, { kind = 'marker', name = e.name }) end
            T.SelectMany(sel, false)
        end
        Select()
        History().Push({
            label = 'import ' .. n .. ' marker(s)',
            undo = function()
                for _, e in made do MarkerTable()[e.name] = nil end
                T.Prune()
                T.Changed = T.Changed + 1
            end,
            redo = function()
                for _, e in made do MarkerTable()[e.name] = e.marker end
                Select()
                T.Changed = T.Changed + 1
            end,
        })
    end
    local report = 'imported ' .. n .. ' marker(s), ' .. result.links .. ' link(s)'
    if result.skipped > 0 then report = report .. ', ' .. result.skipped .. ' of a type the editor does not place left out' end
    return true, report
end

function ImportMarkers(path)
    return ImportFile(path, 'Import markers', 'markers', ImportMarkersText)
end

-- ---- units ------------------------------------------------------------------------------------------------------------------------------------

--- The .scunits text of `list` (units as Units.All() / Units.SelectedData() give them).
function UnitsToText(list)
    local flat = {}
    for _, u in list do
        table.insert(flat, { bp = u.bp, x = u.x, y = u.y or 0, z = u.z, heading = u.heading or 0 })
    end
    local text, err = ed_scunits_write(flat)
    if not text then return nil, err end
    return text, table.getn(flat)
end

function ExportUnits(path)
    return ExportFile(path, 'Export units', 'units', 'units.scunits', function()
        local U = Units()
        local list = U.SelectedData()
        if table.getn(list) == 0 then
            for _, u in U.All() do
                if u.army == U.ArmyName then table.insert(list, u) end
            end
        end
        if table.getn(list) == 0 then return nil, 'there are no units to export' end
        local text, count = UnitsToText(list)
        if not text then return nil, count end
        return text, 'exported ' .. count .. ' unit(s)'
    end)
end

--- Adds the units of a .scunits text to the active army's INITIAL group (new names, on the ground; when one lies off this map they all move so their centre is the map's), one undo step.
function ImportUnitsText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local U = Units()
    local army = U.ArmyName
    local armies = U.Armies()
    local found = false
    for _, a in armies do if a == army then found = true end end
    if not found then army = armies[1] end
    if not army then return nil, 'the map has no army to put the units in' end
    local w, h = Size()
    local result, err = ed_scunits_read(text, { width = w, height = h, fit = true })
    if not result then return nil, err end
    if table.getn(result.units) == 0 then return nil, 'the file has no units' end
    local list = {}
    for _, u in result.units do
        local x = math.max(0, math.min(w, u.x))
        local z = math.max(0, math.min(h, u.z))
        table.insert(list, { army = army, group = 'INITIAL', bp = u.bp, x = x, z = z, y = Ground(x, z), heading = u.heading })
    end
    local n = U.PasteExact(list, 'import ' .. table.getn(list) .. ' unit(s)')
    local report = 'imported ' .. n .. ' unit(s) into ' .. army
    if result.moved then report = report .. ' (moved onto this map)' end
    return true, report
end

function ImportUnits(path)
    return ImportFile(path, 'Import units', 'units', ImportUnitsText)
end

-- ---- prop paint sets --------------------------------------------------------------------------------------------------------------------------

--- The Props scatter list as paint set entries (rotation in whole degrees, scale as a factor, chance = the weight in percent).
function PaintSetToText()
    local S = Scatter()
    local list = {}
    local set = S.Settings
    for _, e in S.Entries do
        local rot0, rot1 = e.rotMin, e.rotMax
        if not rot0 and not rot1 then
            if set.randomHeading then rot0, rot1 = 0, 360 else rot0, rot1 = 0, 0 end
        end
        local s0, s1 = e.scaleMin, e.scaleMax
        if not s0 and not s1 then s0, s1 = set.scaleMin, set.scaleMax end
        s0, s1 = s0 or s1 or 100, s1 or s0 or 100
        table.insert(list, { blueprint = e.bp, rotationMin = math.floor((rot0 or 0) + 0.5), rotationMax = math.floor((rot1 or 360) + 0.5),
                             scaleMin = s0 / 100, scaleMax = s1 / 100, chance = math.floor((e.weight or 1) * 100 + 0.5) })
    end
    if table.getn(list) == 0 then return nil, 'the Props scatter list is empty' end
    local text, err = ed_proppaintset_write(list)
    if not text then return nil, err end
    return text, table.getn(list)
end

function ExportPaintSet(path)
    if not Available() then return Fail('this editor build has no FAFME exporters') end
    return ExportFile(path, 'Export prop paint set', 'paintset', 'props.proppaintset', function()
        local text, count = PaintSetToText()
        if not text then return nil, count end
        return text, 'exported ' .. count .. ' prop(s)'
    end)
end

--- The Props scatter list becomes the paint set (weights = the chances / 100, each prop with its own rotation and scale range).
function ImportPaintSetText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local entries, err = ed_proppaintset_read(text)
    if not entries then return nil, err end
    if table.getn(entries) == 0 then return nil, 'the file has no props' end
    local list = {}
    for _, e in entries do
        table.insert(list, { bp = e.blueprint, weight = e.chance / 100, rotMin = e.rotationMin, rotMax = e.rotationMax, scaleMin = e.scaleMin * 100, scaleMax = e.scaleMax * 100 })
    end
    local S = Scatter()
    local before = S.Entries
    local modeBefore = S.Settings.mode
    S.Entries = list
    S.Settings.mode = 'props'
    pcall(function() import('/lua/editor/gui/panels_scatter.lua').live.scatter.list:Refresh() end)
    History().Push({
        label = 'import prop paint set',
        undo = function() S.Entries = before S.Settings.mode = modeBefore end,
        redo = function() S.Entries = list S.Settings.mode = 'props' end,
    })
    return true, 'imported ' .. table.getn(list) .. ' prop(s) into the Props scatter list'
end

function ImportPaintSet(path)
    return ImportFile(path, 'Import prop paint set', 'paintset', ImportPaintSetText)
end

-- ---- texture layers ---------------------------------------------------------------------------------------------------------------------------

local function LayerOf(i)
    local list = Strata().Layers()
    return list[i + 1]
end

local function LayerSettings(l)
    return { albedo = l.albedo or '', normals = l.normal or '', albedoSize = l.size or 4, normalsSize = l.nsize or l.size or 4 }
end

function LayerToText(i)
    local l = LayerOf(i)
    if not l then return nil, 'no layer ' .. tostring(i) end
    return ed_scmsl_write(LayerSettings(l))
end

function ExportLayer(i, path)
    return ExportFile(path, 'Export texture layer', 'layer', 'layer' .. tostring(i) .. '.scmsl', function()
        local text, err = LayerToText(i)
        if not text then return nil, err end
        return text, 'exported layer ' .. i
    end)
end

--- Sets layer `i` from a .scmsl text (its albedo and normal map with their tile sizes); one undo step.
function ImportLayerText(i, text)
    local ok, why = Editable()
    if not ok then return nil, why end
    if not rawget(_G, 'ed_stratum_layer') then return nil, 'no terrain' end
    local layer, err = ed_scmsl_read(text)
    if not layer then return nil, err end
    local S = Strata()
    if layer.albedo == '' or not DiskGetFileInfo(layer.albedo) then
        return nil, 'the albedo texture ' .. tostring(layer.albedo) .. ' is not in the game data'
    end
    local before = S.Snapshot(i)
    S.SetTexture(i, layer.albedo, layer.normals, layer.albedoSize, layer.normalsSize)
    local after = S.Snapshot(i)
    History().Push({ label = 'import texture layer ' .. i, undo = function() S.Restore(before) end, redo = function() S.Restore(after) end })
    return true, 'layer ' .. i .. ' set to ' .. BaseName(layer.albedo)
end

function ImportLayer(i, path)
    return ImportFile(path, 'Import texture layer', 'layer', function(text) return ImportLayerText(i, text) end)
end

function LayersToText()
    if not rawget(_G, 'ed_stratum_shader') then return nil, 'no terrain' end
    local layers = {}
    for i = 0, 9 do
        local l = LayerOf(i)
        table.insert(layers, l and LayerSettings(l) or { albedo = '', normals = '', albedoSize = 4, normalsSize = 4 })
    end
    return ed_scmst_write({ shader = ed_stratum_shader(), layers = layers })
end

function ExportLayers(path)
    return ExportFile(path, 'Export layer set', 'layers', 'layers.scmst', function()
        local text, err = LayersToText()
        if not text then return nil, err end
        return text, 'exported the ten layers'
    end)
end

--- Sets the terrain shader and all ten layers from a .scmst text; one undo step. A shader this game version does not have stops the import before anything changes.
function ImportLayersText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    if not rawget(_G, 'ed_stratum_shader') then return nil, 'no terrain' end
    local set, err = ed_scmst_read(text)
    if not set then return nil, err end
    local S = Strata()
    local Shaders = import('/lua/editor/shaders.lua')
    local shaderBefore = ed_stratum_shader()
    local before = {}
    for i = 0, 9 do before[i] = S.Snapshot(i) end
    if set.shader ~= '' and set.shader ~= shaderBefore then
        local done, reason = Shaders.Set(set.shader)
        if not done then return nil, reason end
    end
    local missing = 0
    for i = 0, 9 do
        local l = set.layers[i + 1]
        if l and l.albedo ~= '' then
            if DiskGetFileInfo(l.albedo) then
                S.SetTexture(i, l.albedo, l.normals, l.albedoSize, l.normalsSize)
            else
                missing = missing + 1
            end
        end
    end
    -- setting a texture of layer 5..8 switches a legacy shader to TerrainXP (strata.lua EnsureShader): the file's shader wins
    if set.shader ~= '' and ed_stratum_shader() ~= set.shader then Shaders.Set(set.shader, true) end
    local after = {}
    for i = 0, 9 do after[i] = S.Snapshot(i) end
    local shaderAfter = ed_stratum_shader()
    local function Put(shader, snaps)
        if ed_stratum_shader() ~= shader then Shaders.Set(shader) end
        for i = 0, 9 do S.Restore(snaps[i]) end
    end
    History().Push({ label = 'import layer set', undo = function() Put(shaderBefore, before) end, redo = function() Put(shaderAfter, after) end })
    local report = 'layer set imported (shader ' .. tostring(shaderAfter) .. ')'
    if missing > 0 then report = report .. ', ' .. missing .. ' albedo texture(s) not found in the game data' end
    return true, report
end

function ImportLayers(path)
    return ImportFile(path, 'Import layer set', 'layers', ImportLayersText)
end

-- ---- lighting, sky, water (through environment.lua's parts) -----------------------------------------------------------------------------------------

function LightingToText()
    local E = Env()
    if not E.Available() then return nil, 'no map lighting' end
    return ed_scmlighting_write(E.Capture({ 'light' }).num)
end

function ExportLighting(path)
    return ExportFile(path, 'Export lighting', 'lighting', 'lighting.scmlighting', function()
        local text, err = LightingToText()
        if not text then return nil, err end
        return text, 'exported the lighting'
    end)
end

function ImportLightingText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local num, err = ed_scmlighting_read(text)
    if not num then return nil, err end
    if not Env().Apply({ num = num }, { label = 'import lighting' }) then return nil, 'no map lighting' end
    return true, 'lighting imported'
end

function ImportLighting(path)
    return ImportFile(path, 'Import lighting', 'lighting', ImportLightingText)
end

function SkyToText()
    local E = Env()
    if not E.Available() then return nil, 'no map sky' end
    local p = E.Capture({ 'sky', 'skyshape' })
    return ed_scmskybox_write({ num = p.num, texts = p.texts, billboards = p.billboards })
end

function ExportSky(path)
    return ExportFile(path, 'Export sky', 'sky', 'sky.scmskybox', function()
        local text, err = SkyToText()
        if not text then return nil, err end
        return text, 'exported the sky'
    end)
end

local SKY_TEXTS = { 'sky_billboards', 'sky_glow', 'sky_cirrus' }

--- The texture paths a file has (an empty one would blank the map's texture).
local function NonEmpty(texts)
    local out = {}
    for k, v in texts or {} do
        if v ~= '' then out[k] = v end
    end
    return out
end

function ImportSkyText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local sky, err = ed_scmskybox_read(text)
    if not sky then return nil, err end
    local texts = {}
    for _, k in SKY_TEXTS do texts[k] = sky.texts[k] end
    texts = NonEmpty(texts)
    if not Env().Apply({ num = sky.num, texts = texts, billboards = sky.billboards }, { label = 'import sky' }) then return nil, 'no map sky' end
    return true, 'sky imported (' .. math.floor(table.getn(sky.billboards) / 10) .. ' planet(s))'
end

function ImportSky(path)
    return ImportFile(path, 'Import sky', 'sky', ImportSkyText)
end

function WaterToText()
    local E = Env()
    if not E.Available() then return nil, 'no map water' end
    local p = E.Capture({ 'water', 'waves', 'levels' })
    return ed_scmwtr_write({ num = p.num, texts = p.texts })
end

function ExportWater(path)
    return ExportFile(path, 'Export water', 'water', 'water.scmwtr', function()
        local text, err = WaterToText()
        if not text then return nil, err end
        return text, 'exported the water'
    end)
end

function ImportWaterText(text)
    local ok, why = Editable()
    if not ok then return nil, why end
    local water, err = ed_scmwtr_read(text)
    if not water then return nil, err end
    if not Env().Apply({ num = water.num, texts = NonEmpty(water.texts) }, { label = 'import water' }) then return nil, 'no map water' end
    return true, 'water imported'
end

function ImportWater(path)
    return ImportFile(path, 'Import water', 'water', ImportWaterText)
end
