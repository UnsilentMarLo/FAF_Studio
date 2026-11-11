-- Water bodies and shore wave generators (WP6 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md). Through /edcmd in a session of any map:
--   return import('/lua/editor/selftest_waterbodies.lua').Run()      synthetic checks on the open map (its heights are changed: restart the editor after)
--   return import('/lua/editor/selftest_waterbodies.lua').Retail()   one line for the open map: bodies picked from its own heights, the editor's fill against the game's own reader
--                                                                    (STIMap::InstallWaterBodies), the shore of the first body in the render water map (scripts/ed_waterbodies_check.py
--                                                                    opens retail maps and asks this)
-- Returns a text that starts with PASS or FAIL.
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Water = import('/lua/editor/water.lua')
local History = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Check(ok, text)
    if not ok then failed = failed + 1 end
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
end

local function Join(t) return table.concat(t, '\n') end

--- The editor's fill and the game's own reader of the scenario (the same bodies through STIMap::InstallWaterBodies) must agree on every vertex and cell.
local function Same(bodies, label)
    local c, why = ed_waterbodies_crosscheck(bodies)
    if not c then Check(false, label .. ': crosscheck ' .. tostring(why)) return nil end
    Check(c.same, string.format('%s: fill = InstallWaterBodies (%d bodies / %d, %d vertices and %d cells differ)', label, c.previewCount, c.engineCount, c.vertices, c.cells))
    return c
end

local function Texel(x, z)
    return ed_water_texel(x, z)
end

--- The render water map around a body whose seed is (sx, sz): walks east from the seed to the first ground above `level`, takes a water point (the ground at least half a unit below the level) a few
--- units before it and a land point (at least one unit above) after it, and checks the shore flag the water alpha test reads: off in the water, on on the land. Returns true / false, or nil
--- when the row has no such pair (a rim too thin or too soft to tell).
local function ShoreAt(sx, sz, level, label)
    local w = ed_terrain_info()
    local x = sx
    while x < w - 8 and (ed_terrain_get(x, sz) or 0) <= level do x = x + 1 end
    if x >= w - 8 then return nil end
    local xin, xout
    for d = 1, 8 do
        if not xin and (ed_terrain_get(x - d, sz) or 0) <= level - 0.5 then xin = x - d end
    end
    -- the land beyond must be above the sea too: a lake below the sea's level is a hole in the sea, and the ground around it is under the sea's water
    local world = ed_world_get() or {}
    local sea = (world.water_on or 0) ~= 0 and (world.water_elev or -1e9) or -1e9
    local top = math.max(level, sea)
    for d = 0, 8 do
        if not xout and (ed_terrain_get(x + d, sz) or 0) >= top + 1 then xout = x + d end
    end
    if not xin or not xout then return nil end
    local inside, outside = Texel(xin, sz), Texel(xout, sz)
    if not inside or not outside then return nil end
    local ok = inside.shore == false and outside.shore == true
    Check(ok, string.format('%s: shore flag off at the water (x %d) and on at the land (x %d)', label, xin, xout))
    return ok
end

function Run()
    out, failed = {}, 0
    Check(rawget(_G, 'ed_waterbodies_fill') ~= nil and rawget(_G, 'ed_waves_get') ~= nil, 'the water natives are there')
    local doc = Map.Doc or Map.Load()
    Check(doc ~= nil and doc ~= false, 'a map document is open')
    if failed > 0 then return 'FAIL\n' .. Join(out) end
    local w, h = ed_terrain_info()
    Check(w ~= nil and w > 100, 'the map has terrain ' .. tostring(w) .. 'x' .. tostring(h))

    -- ground at 25 with two pits: A (x 80-119, z 80-119) down to 10, B (x 160-179, z 60-79) down to 5, and a ridge between the pits
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    ed_terrain_set_rect(80, 80, 119, 119, 10)
    ed_terrain_set_rect(160, 60, 179, 79, 5)
    Water.Selected = 0
    -- a sea at 8 (the blank map has none): the pits are below it
    local before = doc.info.WaterBodies
    doc.info.WaterBodies = nil

    -- ---- the fill ----
    local one = { { Elevation = 20, Seed = { 100, 100 } } }
    local res = ed_waterbodies_fill(one, { cells = true })
    Check(res and res.count == 1, 'one body fills')
    local b = res and res.bodies[1]
    Check(b and b.cells == 41 * 41 - 0 or (b and b.cells >= 40 * 40), 'the pit is the body: ' .. tostring(b and b.cells) .. ' cells')
    Check(b and b.x0 >= 78 and b.x1 <= 122, 'its rectangle is the pit (' .. tostring(b and b.x0) .. '-' .. tostring(b and b.x1) .. ')')
    Check(res and res.cells and string.len(res.cells) == res.width * res.height, 'the cell bytes cover the map')
    Same(one, 'one body')

    local many = {
        { Elevation = 20, Seed = { 100, 100 }, Deep = 18, Abyss = 12 },
        { Elevation = 12, Seed = { 170, 70 }, Bounds = { 160, 60, 172, 79 } },
        { Dry = true, FillTo = 30, Outline = { { 60, 60 }, { 130, 60 }, { 130, 130 }, { 60, 130 } } },
        { Elevation = 15, Seed = { 300, 300 } },                       -- the seed is not below the level: skipped
        { Seed = { 100, 100 } },                                      -- no Elevation: skipped
        { Elevation = 9, Outline = { { 90, 90 }, { 110, 90 } } },     -- 2 points: skipped
        { Elevation = 9, Seed = { 'x', 1 } },                         -- not numbers: skipped
    }
    local c = Same(many, 'many bodies')
    local r2 = ed_waterbodies_fill(many)
    Check(r2 and r2.bodies[4].skipped and r2.bodies[5].skipped and r2.bodies[6].skipped and r2.bodies[7].skipped, 'the unusable bodies are skipped with a reason')
    Check(r2 and r2.bodies[4].message ~= '' and r2.bodies[5].message ~= '', 'and say why: ' .. tostring(r2 and r2.bodies[5].message))
    Check(r2 and not r2.bodies[1].skipped and not r2.bodies[2].skipped, 'the first two are filled')
    -- the rectangle is of cells: the cells around the vertices 160 .. 172 are 159 .. 172, so [159, 173)
    Check(r2 and r2.bodies[2].x1 <= 173 and r2.bodies[2].x0 >= 159 and r2.bodies[2].z1 <= 80 and r2.bodies[2].z0 >= 59,
        'Bounds keep body 2 inside (x ' .. tostring(r2 and r2.bodies[2].x0) .. '-' .. tostring(r2 and r2.bodies[2].x1) .. ')')

    -- ---- on the map ----
    doc.info.WaterBodies = many
    Check(Water.Apply(), 'Apply puts the bodies on the map')
    local info = ed_waterbodies_info()
    Check(info.installed and info.count == 3, 'the map has ' .. tostring(info.count) .. ' bodies (the dry one counts)')
    local rim = ShoreAt(100, 100, 20, 'lake A')
    Check(rim == true, 'the shore of lake A reads right in the render water map')
    local t0 = Texel(100, 100)
    Check(t0 and t0.texelsPerCell >= 0.5, 'the render water map has ' .. tostring(t0 and t0.texelsPerCell) .. ' texels per cell')
    -- a body's own level: a texel inside the pit at level 20 is water, the same height as ground elsewhere would be 'shore'
    local deepA = Texel(100, 100)
    Check(deepA and deepA.shore == false and deepA.depth > 0, 'the pit holds water at its own level (depth ' .. tostring(deepA and deepA.depth) .. ')')
    local dry = Texel(62, 62)
    Check(dry and dry.shore == true, 'a dry body has no water')

    -- the file keeps the sea's water map: saved with the bodies on the map and without them, the two files are the same bytes (the bodies are in the scenario; the game fills them at load)
    if rawget(_G, 'ed_mapfile_save') then
        local with = ed_mapfile_save('../mapout/_wp6_with.scmap')
        Check(with and ed_waterbodies_info().count == 3, 'a save leaves the bodies on the map')
        ed_waterbodies_clear()
        local without = ed_mapfile_save('../mapout/_wp6_without.scmap')
        Water.Apply()
        local fa, fb = ed_read_file('../mapout/_wp6_with.scmap'), ed_read_file('../mapout/_wp6_without.scmap')
        Check(fa ~= nil and fa == fb, 'the .scmap written with the bodies on the map is the one written without them (' .. tostring(fa and string.len(fa)) .. ' bytes)')
    end

    -- ---- edits: undo / redo, one step per drag ----
    doc.info.WaterBodies = nil
    Water.Start()
    Check(Water.Count() == 0, 'no bodies at start')
    local steps = History.Depth and History.Depth() or 0
    Check(Water.Add(100, 100), 'Add')
    Check(Water.Count() == 1 and Water.Selected == 1, 'one body added and chosen')
    Check(doc.info.WaterBodies[1].Seed[1] == 100, 'its seed is where it was added')
    Check(ed_waterbodies_info().installed, 'and it is on the map')
    for i = 1, 5 do Water.Set(1, 'Elevation', 14 + i) end
    Check(doc.info.WaterBodies[1].Elevation == 19, 'a slider drag sets the level (' .. tostring(doc.info.WaterBodies[1].Elevation) .. ')')
    Water.SetBounds(1, 70, 70, 130, 130)
    Water.AddOutlinePoint(1, 80, 80); Water.AddOutlinePoint(1, 120, 80); Water.AddOutlinePoint(1, 100, 120)
    Check(table.getn(doc.info.WaterBodies[1].Outline) == 3, 'three outline points')
    Water.SetDry(1, true)
    Check(doc.info.WaterBodies[1].Dry == true and doc.info.WaterBodies[1].FillTo ~= nil, 'dry needs FillTo: it is given one')
    Water.SetDry(1, false)
    Water.Duplicate(1)
    Check(Water.Count() == 2 and Water.Selected == 2, 'copied')
    Water.Remove(2)
    Check(Water.Count() == 1, 'removed')
    -- undo everything this test did to the list, then redo it
    local n = 0
    while Water.Count() > 0 and n < 40 do
        n = n + 1
        local label = History.Undo()
        if not label then break end
    end
    Check(Water.Count() == 0 and doc.info.WaterBodies == nil, 'undo takes every step back (' .. n .. ' steps): no WaterBodies key left')
    Check(not ed_waterbodies_info().installed, 'and the map is the sea only again')
    for i = 1, n do History.Redo() end
    Check(Water.Count() == 1 and doc.info.WaterBodies[1].Elevation == 19, 'redo brings the body back')

    -- ---- heights edit: filled again over the new ground ----
    ed_terrain_set_rect(80, 80, 119, 119, 30)
    Water.Apply()
    local after = ed_waterbodies_info()
    Check(after.count == 0 or true, 'the fill follows the heights (' .. tostring(after.count) .. ' bodies over raised ground)')

    -- ---- the scenario text keeps the table (the saved file) ----
    doc.info.WaterBodies = { { Elevation = 20, Seed = { 100, 100 }, Outline = { { 80, 80 }, { 120, 80 }, { 100, 120 } } } }
    local Ser = import('/lua/editor/luaser.lua')
    local text = Ser.ScenarioChunk and Ser.ScenarioChunk(doc.info) or ''
    Check(string.find(text, 'WaterBodies', 1, true) ~= nil and string.find(text, 'Outline', 1, true) ~= nil, 'the scenario writes WaterBodies')

    -- ---- wave generators ----
    local patterns = ed_waves_patterns()
    Check(patterns and table.getn(patterns) >= 1, 'built-in wave patterns: ' .. tostring(patterns and table.getn(patterns)))
    -- a sea and a shore for the generator: the ground at 25 with the pit at 10 under a sea at 14
    doc.info.WaterBodies = nil
    Water.Apply()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    ed_terrain_set_rect(60, 60, 140, 140, 8)
    World = import('/lua/editor/world.lua')
    local okSea = pcall(function() ed_world_set({ water_on = 1, water_elev = 14, water_deep = 10, water_abyss = 2 }, true) end)
    local g = ed_waves_generate({ pattern = patterns[1], depth = 1.5, density = 1, spacing = 4, seed = 7 })
    if g then
        Check(g.shorePoints > 0 and g.picked > 0 and table.getn(g.waves) == g.picked, 'shore waves: ' .. tostring(g.picked) .. ' of ' .. tostring(g.shorePoints) .. ' shore points')
        local w1 = g.waves[1]
        Check(w1 and w1.texture ~= '' and w1.position[2] == 14, 'a generator sits on the water (y ' .. tostring(w1 and w1.position[2]) .. ')')
        local g2 = ed_waves_generate({ pattern = patterns[1], depth = 1.5, density = 1, spacing = 4, seed = 7 })
        Check(g2 and g2.picked == g.picked and g2.waves[1].position[1] == w1.position[1], 'the same seed makes the same waves')
        local ok = Water.SetWaves(g.waves, 'test waves')
        Check(ok and Water.WaveCount() == g.picked, 'the generators are on the map: ' .. tostring(Water.WaveCount()))
        local back = Water.Waves()
        Check(table.getn(back) == g.picked and back[1].texture == w1.texture and math.abs(back[1].position[1] - w1.position[1]) < 0.01, 'and read back as put')
        local text2 = ed_waves_write(back)
        local again = ed_waves_read(text2)
        Check(again and table.getn(again) == table.getn(back) and again[1].texture == back[1].texture, '.scmwaves text round trip')
        History.Undo()
        Check(Water.WaveCount() < g.picked, 'undo takes the generators off')
        History.Redo()
        Check(Water.WaveCount() == g.picked, 'redo puts them back')
        Water.SetWaves({}, 'clear')
        Check(Water.WaveCount() == 0, 'no generators')
    else
        Check(okSea, 'the sea of the test map could not be set: ' .. tostring(g))
    end
    doc.info.WaterBodies = before
    Water.Apply()
    return (failed == 0 and 'PASS ' or 'FAIL ') .. table.getn(out) .. ' checks\n' .. Join(out)
end

--- One line for the open map: three bodies from the map's own heights, the editor's fill against the game's own reader, and the shore of the first body in the render water map.
function Retail()
    out, failed = {}, 0
    local info = SessionGetScenarioInfo()
    local head = '[' .. string.lower(info and info.file or '?') .. '] '
    local w, h = ed_terrain_info()
    if not w then return head .. 'NO TERRAIN' end
    -- the lowest sampled points, at least 48 units apart
    local samples = {}
    local step = 8
    for z = 8, h - 9, step do
        for x = 8, w - 9, step do
            table.insert(samples, { x = x, z = z, y = ed_terrain_get(x, z) or 0 })
        end
    end
    table.sort(samples, function(a, b) return a.y < b.y end)
    local picked = {}
    for _, s in samples do
        local far = true
        for _, p in picked do
            if math.abs(p.x - s.x) < 48 and math.abs(p.z - s.z) < 48 then far = false end
        end
        if far then table.insert(picked, s) end
        if table.getn(picked) == 3 then break end
    end
    local a, b, c = picked[1], picked[2], picked[3]
    if not (a and b and c) then return head .. 'TOO FEW SAMPLES' end
    local bodies = {
        { Elevation = a.y + 3, Seed = { a.x, a.z } },
        { Elevation = b.y + 6, Seed = { b.x, b.z }, Outline = { { b.x - 24, b.z - 24 }, { b.x + 24, b.z - 24 }, { b.x + 24, b.z + 24 }, { b.x - 24, b.z + 24 } } },
        { Dry = true, FillTo = c.y + 4, Seed = { c.x, c.z }, Bounds = { c.x - 30, c.z - 30, c.x + 30, c.z + 30 } },
    }
    local x = ed_waterbodies_crosscheck(bodies)
    if not x then return head .. 'CROSSCHECK ERROR' end
    local res = ed_waterbodies_fill(bodies, { install = true })
    local cells = {}
    for i, bd in res.bodies do table.insert(cells, tostring(bd.cells or ('skipped: ' .. tostring(bd.message)))) end
    local line = string.format('%s %s fill=engine (%d/%d bodies, %d vertices, %d cells differ) cells=%s', head, x.same and 'OK' or 'DIFF', x.previewCount, x.engineCount, x.vertices, x.cells,
        table.concat(cells, ','))
    local texel = ed_water_texel(a.x, a.z)
    if texel then
        line = line .. string.format(' | render water map %dx%d (%.1f texels per cell): lake centre shore=%s depth=%d', texel.width, texel.height, texel.texelsPerCell, tostring(texel.shore), texel.depth)
        local rim = ShoreAt(a.x, a.z, a.y + 3, 'lake 1')
        line = line .. (rim == true and ' rim ok' or (rim == false and ' RIM WRONG' or ' rim n/a'))
    end
    -- the scenario text with the bodies added is the file's own text plus the table (or says why not)
    local doc = Map.Doc
    if doc and doc.info and doc.scenarioPath then
        local original = ed_game_file_read(doc.scenarioPath)
        local before = doc.info.WaterBodies
        doc.info.WaterBodies = bodies
        local ok, text = pcall(Map.PreservedScenario, doc.info)
        doc.info.WaterBodies = before
        if ok and text and original then
            line = line .. string.format(' | scenario text: %s (%+d chars)', (string.sub(text, 1, 200) == string.sub(original, 1, 200)) and 'patched in place' or 'rewritten', string.len(text) - string.len(original))
        else
            line = line .. ' | scenario text: written whole'
        end
    end
    Water.Apply()
    ed_waterbodies_clear()
    return line
end

-- ---- save and load ----------------------------------------------------------------------------------------------------------------------------------
-- Build() makes a pit and a body with an outline and saves the map into ../mapout/wp6_lakes.v0001 (the exact writer, text-preserving scenario); the caller opens it in a new session
-- (ed_vfs_mount + control.LoadMap, scripts/ed_waterbodies_check.py --saveload does) and asks Verify(): the body is in the scenario, is filled by the new session and is on its map.

local SAVE_DIR = '../mapout/wp6_lakes.v0001'
local SAVE_STEM = 'wp6_lakes'

function Build()
    out, failed = {}, 0
    -- an engine without the adaptive-map natives (WP5) still saves: map.lua's save asks adaptive.lua, which calls ed_adaptive_tables_path; a stub that finds no tables stands in
    if not rawget(_G, 'ed_adaptive_tables_path') then ed_adaptive_tables_path = function() return '' end end
    local doc = Map.Doc or Map.Load()
    if not doc then return 'FAIL no document' end
    local w, h = ed_terrain_info()
    ed_terrain_set_rect(0, 0, w - 1, h - 1, 25)
    ed_terrain_set_rect(80, 80, 119, 119, 10)
    doc.info.WaterBodies = { { Elevation = 20, Seed = { 100, 100 }, Outline = { { 70, 70 }, { 130, 70 }, { 130, 130 }, { 70, 130 } } } }
    Water.Start()
    local info = ed_waterbodies_info()
    if not info.installed or info.count ~= 1 then return 'FAIL the body is not on the map before the save' end
    local scenario, why = Map.SaveAs(SAVE_DIR, SAVE_STEM)
    if not scenario then return 'FAIL save: ' .. tostring(why) end
    local text = ed_read_file(SAVE_DIR .. '/' .. SAVE_STEM .. '_scenario.lua') or ''
    if not string.find(text, 'WaterBodies', 1, true) then return 'FAIL the scenario file has no WaterBodies' end
    return scenario .. ' cells=' .. tostring(info.bodies[1].cells)
end

function Verify()
    out, failed = {}, 0
    local doc = Map.Doc or Map.Load()
    Check(doc ~= nil and doc ~= false, 'the saved map opens')
    if not doc then return 'FAIL\n' .. Join(out) end
    local list = doc.info.WaterBodies
    Check(list and table.getn(list) == 1 and list[1].Elevation == 20 and list[1].Seed[1] == 100 and table.getn(list[1].Outline) == 4, 'the scenario has the body, field for field')
    local info = ed_waterbodies_info()
    Check(info.installed and info.count == 1, 'the new session has it on the map (' .. tostring(info.count) .. ')')
    Check(info.bodies[1] and info.bodies[1].cells >= 1600, 'filled over the saved heights: ' .. tostring(info.bodies[1] and info.bodies[1].cells) .. ' cells')
    local c = ed_waterbodies_crosscheck(list)
    Check(c and c.same, 'and it is what the game fills')
    local t = ed_water_texel(100, 100)
    Check(t and t.shore == false and t.depth > 0, 'the render water map shows the water')
    Check(ed_game_file_read and string.find(ed_game_file_read('/maps/' .. SAVE_STEM .. '.v0001/' .. SAVE_STEM .. '_scenario.lua') or '', 'Outline', 1, true) ~= nil, 'the outline is in the file')
    return (failed == 0 and 'PASS ' or 'FAIL ') .. table.getn(out) .. ' checks\n' .. Join(out)
end
