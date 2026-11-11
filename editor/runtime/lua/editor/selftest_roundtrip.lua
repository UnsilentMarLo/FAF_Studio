-- The exact save (WP3 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): upstream's classic .scmap writer with the file's own records, and the text-preserving `_save.lua` / `_scenario.lua`.
-- Through /edcmd in a session of any map:
--   return import('/lua/editor/selftest_roundtrip.lua').Run()         the checks below (the open map's document is edited and put back)
--   return import('/lua/editor/selftest_roundtrip.lua').Retail()      one line for the open map: the untouched save compared with the file the map was read from (scripts/ed_roundtrip.py
--                                                                      opens every retail map and asks this)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local TS = import('/lua/editor/textsave.lua')

local out, failed = {}, 0

local function Check(ok, text)
    if not ok then failed = failed + 1 end
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
end

local PROP_BP = '/env/common/props/markers/M_Blank_prop.bp'

--- The first and the last index at which two texts differ, from both ends: what lies between is all a save changed.
local function Changed(a, b)
    local la, lb = string.len(a), string.len(b)
    local p = 0
    local n = math.min(la, lb)
    while p < n and string.byte(a, p + 1) == string.byte(b, p + 1) do p = p + 1 end
    local q = 0
    while q < n - p and string.byte(a, la - q) == string.byte(b, lb - q) do q = q + 1 end
    return p, q, la - p - q, lb - p - q
end

local function Folder()
    local base = '../mapout/_roundtrip'
    return base
end

function Retail()
    local session = SessionGetScenarioInfo()
    local file = session and session.file or '?'
    local head = '[' .. string.lower(file) .. '] '
    local state = ed_mapfile_state and ed_mapfile_state()
    if not state or not state.captured then return head .. 'NOT CAPTURED' end
    local res, why = ed_mapfile_roundtrip(Folder(), true)
    if not res then return head .. 'ERROR ' .. tostring(why) end
    return head .. string.format('%s stable=%s same=%s kept=%s images=%d props=%d %s', res.ok and 'OK' or 'DIFF', tostring(res.stable), tostring(res.sameAsOriginal), tostring(res.kept),
                         state.images or 0, state.props or 0, res.differences or '') .. ' | ' .. TextLine()
end

--- The text files of the open map written untouched: `_save.lua` and `_scenario.lua` must come back as the files are (the document is the files' own tables), or say why not.
function TextLine()
    local doc = Map.Doc or Map.Load()
    if not doc then return 'no document' end
    local parts = {}
    local function One(name, path, make)
        local original = path and ed_game_file_read(path)
        if not original then table.insert(parts, name .. '=none') return end
        local ok, text, why = pcall(make, original)
        if not ok then table.insert(parts, name .. '=ERROR ' .. tostring(text))
        elseif text == original then table.insert(parts, name .. '=same')
        elseif text then
            -- how much: the lines that differ (the editor puts a marker on the ground when it loads, so a map's markers can come back changed)
            local a, b, n, k = {}, {}, 0, 0
            for line in string.gfind(original, '([^\n]*)\n') do n = n + 1 a[n] = line end
            local m = 0
            for line in string.gfind(text, '([^\n]*)\n') do m = m + 1 b[m] = line end
            for i = 1, math.max(n, m) do
                if a[i] ~= b[i] then k = k + 1 end
            end
            table.insert(parts, string.format('%s=CHANGED(%d of %d lines, %d -> %d)', name, k, n, n, m))
        else table.insert(parts, name .. '=fallback(' .. tostring(why) .. ')') end
    end
    One('save', doc.savePath, function(o) return TS.Save(o, doc.save) end)
    One('scenario', doc.scenarioPath, function(o)
        local info = {}
        for k, v in doc.info do info[k] = v end
        info.file = nil
        return TS.Scenario(o, info)
    end)
    return table.concat(parts, ' ')
end

function Run()
    out, failed = {}, 0
    if not (rawget(_G, 'ed_mapfile_save') and rawget(_G, 'ed_savefile_entries')) then return 'FAIL: the exact-save natives are not in this engine' end
    local doc, why = Map.Load()
    Check(doc ~= nil, 'document loads ' .. tostring(why))
    if not doc then return 'FAIL (1)\n' .. table.concat(out, '\n') end

    -- 1. an untouched map saves the bytes it was read from
    local state = ed_mapfile_state()
    Check(state.captured, 'the session captured the file records')
    Check(state.heights and state.water and state.masks, 'nothing is marked changed in a fresh session')
    local res, err = ed_mapfile_roundtrip(Folder(), true)
    Check(res ~= nil, 'round trip runs ' .. tostring(err))
    if res then
        Check(res.ok, 'the saved file reads back as the open map ' .. tostring(res.differences))
        Check(res.stable, 'saving twice gives the same bytes')
        -- the byte for byte claim is the retail maps' (scripts/ed_roundtrip.py): the blank templates are written by scripts/ed_make_blank_map.py, not by the engine, so their bytes may
        -- differ in what the engine lays out its own way (strings, decal and layer records); what must hold for any map is the read-back and the stable second save above
        table.insert(out, '  info  an untouched map saves the bytes of its file: ' .. tostring(res.sameAsOriginal))
    end

    -- 2. a prop's scale edit survives the save (the file record is not written back over it)
    local before = ed_prop_count()
    local index = Map.AddProp(PROP_BP, 60, 25, 60, 0.7, { 1.5, 0.5, 2.25 })
    Check(index ~= nil, 'prop added')
    if index then
        local deep, why2 = ed_mapfile_roundtrip(Folder(), true)
        Check(deep ~= nil and deep.ok, 'a prop with scale 1.5 / 0.5 / 2.25 reads back as it is ' .. tostring(deep and deep.differences or why2))
        Map.SetPropScale(index, 3, 1, 0.25)
        local again = ed_mapfile_roundtrip(Folder(), true)
        Check(again ~= nil and again.ok, 'the scale edit after the first save reads back as edited ' .. tostring(again and again.differences))
        Map.RemoveProp(index)
        Check(ed_prop_count() == before, 'prop removed again')
    end

    -- 3. what an edit marks changed: the heights of the file are not written back over an edit
    local h0 = ed_terrain_get(30, 30)
    ed_terrain_set_rect(28, 28, 32, 32, h0 + 3)
    local edited = ed_mapfile_state()
    Check(not edited.heights, 'a height edit is marked: the normal maps are made again')
    Check(not edited.water, 'the water map depends on the heights')
    Check(edited.masks, 'the masks were not touched')
    ed_terrain_set_rect(28, 28, 32, 32, h0)
    local engineSave = ed_mapfile_save(Folder() .. '/engine.scmap', { engine = true })
    Check(engineSave and engineSave.writer == 'engine' and ed_file_exists(Folder() .. '/engine.scmap'), 'a mesh terrain map keeps the engine writer')
    local meshWas = doc.info.TerrainSystem
    doc.info.TerrainSystem = 'mesh'
    local meshOk, meshWriter = Map.SaveMapFile(Folder() .. '/mesh.scmap')
    doc.info.TerrainSystem = meshWas
    Check(meshOk and meshWriter == 'engine' and ed_file_exists(Folder() .. '/mesh.scmap'), 'a map with TerrainSystem = mesh is saved by the engine writer (Map.SaveMapFile) ' .. tostring(meshWriter))
    local exactSave = ed_mapfile_save(Folder() .. '/exact.scmap')
    Check(exactSave and exactSave.writer == 'exact', 'the exact writer is the default')

    -- 4. the text of _save.lua keeps its comments and layout; an edit changes only what it touched
    local original = Map.SaveText()       -- (written as the editor writes it: the identifier keys bare, as the game's files have them, which SaveFile finds its blocks by)
    if not original then
        table.insert(out, '  skip  no _save.lua text')
    else
        local marked = '-- kept by the exact save\n' .. original
        local same, why3 = TS.Save(marked, doc.save)
        Check(same == marked, 'an untouched document gives the file back unchanged ' .. tostring(why3))
        Map.AddMarker('RT_MARKER', 'Blank Marker', 40, 25, 40)
        local patched, why4 = TS.Save(marked, doc.save)
        Check(patched ~= nil, 'a marker edit is patched into the text ' .. tostring(why4))
        if patched then
            Check(string.sub(patched, 1, 26) == '-- kept by the exact save\n', 'the comment before the table is kept')
            local p, q, dropped, added = Changed(marked, patched)
            Check(dropped == 0 and added > 0 and added < 700, string.format('only the new marker was added (prefix %d bytes, suffix %d, text removed %d, added %d)', p, q, dropped, added))
            Check(string.find(patched, 'RT_MARKER', 1, true) ~= nil, 'the marker is in the text')
        end
        local moved = Map.GetMarker('RT_MARKER')
        if moved then moved.position[1] = 41 end
        local patched2 = TS.Save(marked, doc.save)
        Check(patched2 ~= nil and patched ~= nil and patched2 ~= patched, 'a marker move changes the text again')
        Map.RemoveMarker('RT_MARKER')
        local restored, why5 = TS.Save(marked, doc.save)
        Check(restored == marked, 'removing the marker again gives the file back byte for byte ' .. tostring(why5))
    end

    -- 5. the scenario text: a changed value is replaced in place, the rest kept
    local scenario = ed_game_file_read(doc.scenarioPath)
    if scenario then
        local info = {}
        for k, v in doc.info do info[k] = v end
        info.file = nil
        local text, why6 = TS.Scenario('-- keep\n' .. scenario, info)
        Check(text == '-- keep\n' .. scenario, 'an untouched scenario comes back unchanged ' .. tostring(why6))
        local name = info.name
        info.name = 'Round trip test name'
        local renamed = TS.Scenario('-- keep\n' .. scenario, info)
        Check(renamed ~= nil and string.find(renamed, 'Round trip test name', 1, true) ~= nil and string.sub(renamed, 1, 8) == '-- keep\n', 'a renamed map changes the name only')
        info.name = name
    end

    local text = (failed == 0 and 'PASS' or ('FAIL (' .. failed .. ')')) .. '\n' .. table.concat(out, '\n')
    return text
end
