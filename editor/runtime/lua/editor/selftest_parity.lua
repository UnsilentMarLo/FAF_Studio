-- Parity audit additions: history list and jump, marker properties of every type (type change, camera markers), chains, statistics, align / distribute / circle / snap, find and
-- replace, favourites, the PNG writer, map info fields. Through /edcmd in an /editor session:
--   return import('/lua/editor/selftest_parity.lua').Run()
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')
local Tools = import('/lua/editor/tools.lua')
local H = import('/lua/editor/history.lua')

local out, failed = {}, 0

local function Check(ok, text)
    table.insert(out, (ok and '  ok   ' or '  FAIL ') .. text)
    if not ok then failed = failed + 1 end
end

local function Markers() return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end

local function Place(name, kind, x, z)
    Tools.PlaceMarker(x, z, kind, name)
    return Markers()[name]
end

local function Cleanup()
    for _, name in { 'PT_A', 'PT_B', 'PT_C', 'PT_D', 'PT_CAM', 'PT_REPL1', 'PT_REPL2' } do
        if Markers()[name] then Map.RemoveMarker(name) end
    end
    Tools.Select(false)
    local chains = Map.Doc.save.Chains
    for _, name in { 'PT_Chain', 'PT_Renamed', 'PT_Other' } do chains[name] = nil end
end

function Run()
    out, failed = {}, 0
    if not Map.Doc then Map.Load() end
    Cleanup()
    local Arr = import('/lua/editor/arrange.lua')
    local MP = import('/lua/editor/markerprops.lua')
    local Chains = import('/lua/editor/chains.lua')
    local FR = import('/lua/editor/findreplace.lua')
    local Fav = import('/lua/editor/favourites.lua')
    local Png = import('/lua/editor/png.lua')
    local Stats = import('/lua/editor/mapstats.lua')

    -- ---- history list ----------------------------------------------------------------------------------------------------------------------------
    H.Clear()      -- the stack holds 200 entries at most: after enough earlier tests it is full and 'applied + 3' no longer holds (the order dependent failure of the shuffled loop)
    local _, base = H.Entries()
    Place('PT_A', 'Blank Marker', 40, 40)
    Place('PT_B', 'Blank Marker', 60, 70)
    Place('PT_C', 'Blank Marker', 90, 50)
    local entries, pos = H.Entries()
    Check(pos == base + 3 and entries[pos].label == 'place PT_C', 'History.Entries lists the applied entries (' .. tostring(entries[pos] and entries[pos].label) .. ')')
    H.JumpTo(base)
    Check(not Markers().PT_A and not Markers().PT_B and not Markers().PT_C, 'JumpTo(start) undoes all three placements')
    H.JumpTo(base + 3)
    Check(Markers().PT_A and Markers().PT_B and Markers().PT_C, 'JumpTo goes forward again')
    H.JumpTo(base + 1)
    Check(Markers().PT_A and not Markers().PT_B, 'JumpTo(1) leaves the first only')
    H.JumpTo(base + 3)

    -- ---- marker properties -------------------------------------------------------------------------------------------------------------------------
    local cam = Place('PT_CAM', 'Camera Info', 100, 100)
    local fields = {}
    for _, f in MP.Fields('Camera Info', cam) do fields[f.key] = f.kind end
    Check(fields.zoom == 'number' and fields.canSetCamera == 'bool' and fields.canSyncCamera == 'bool', 'Camera Info fields come from the template')
    MP.Set('PT_CAM', 'zoom', 120)
    Check(cam.zoom == 120 and MP.Get('PT_CAM', 'zoom') == 120, 'a field is set with Set / Get')
    H.Undo()
    Check(cam.zoom == 0 or cam.zoom == nil, 'and undone')
    H.Redo()
    local ok, why = MP.ChangeType('PT_CAM', 'Land Path Node')
    Check(ok and cam.type == 'Land Path Node' and cam.graph == 'DefaultLand' and cam.zoom == nil, 'ChangeType takes the new template fields and drops the old ones (' .. tostring(why) .. ')')
    local pathFields = {}
    for _, f in MP.Fields(cam.type, cam) do pathFields[f.key] = true end
    Check(pathFields.graph and pathFields.adjacentTo, 'path node fields: graph and adjacentTo')
    H.Undo()
    Check(cam.type == 'Camera Info' and cam.zoom == 120 and cam.graph == nil, 'one undo restores the camera marker with its zoom')
    Check(not MP.ChangeType('PT_CAM', 'No Such Type'), 'an unknown type is refused')
    Check(MP.ParseVector('1, 2.5 3')[2] == 2.5 and MP.ParseVector('1 2') == nil and MP.VectorText({ 1, 2, 3 }) == '1, 2, 3', 'vector text round trip')
    local before = cam.position[1]
    local hasCam = GetCamera and GetCamera('WorldCamera')
    if hasCam then
        Check(MP.LookThrough('PT_CAM') == true, 'LookThrough moves the camera')
        local set = MP.SetFromCamera('PT_CAM')
        Check(set == true and cam.zoom ~= nil, 'SetFromCamera stores the view (zoom ' .. tostring(cam.zoom) .. ')')
        H.Undo()
        Check(cam.position[1] == before, 'and undoes')
    end

    -- ---- chains ---------------------------------------------------------------------------------------------------------------------------------------
    Tools.Select('marker', 'PT_A')
    Tools.Select('marker', 'PT_B', 'add')
    Tools.Select('marker', 'PT_C', 'add')
    Check(Chains.FromSelection('PT_Chain') == true, 'a chain from the selected markers')
    local list = Chains.Markers('PT_Chain')
    Check(list and table.getn(list) == 3 and list[1] == 'PT_A' and list[3] == 'PT_C', 'in selection order')
    Check(not Chains.Create('PT_Chain', {}) and not Chains.Create('bad/name', {}), 'a duplicate or invalid name is refused')
    Check(Chains.MoveMarker('PT_Chain', 1, 1) and Chains.Markers('PT_Chain')[1] == 'PT_B', 'MoveMarker')
    Check(Chains.RemoveMarker('PT_Chain', 2) and table.getn(Chains.Markers('PT_Chain')) == 2, 'RemoveMarker')
    Check(Chains.AddMarker('PT_Chain', 'PT_A', 1) and Chains.Markers('PT_Chain')[1] == 'PT_A', 'AddMarker at a position')
    H.Undo() H.Undo() H.Undo()
    Check(table.getn(Chains.Markers('PT_Chain')) == 3 and Chains.Markers('PT_Chain')[1] == 'PT_A', 'three undos back to the first state')
    Check(Chains.Length('PT_Chain') > 10, 'chain length')
    Check(Chains.Create('PT_Other', { 'PT_A' }) and table.getn(Chains.Problems()) >= 1, 'a chain with one marker is a problem')
    local problem = false
    for _, p in Chains.Problems() do if string.find(p.text, 'PT_Other', 1, true) then problem = true end end
    Check(problem, 'the problem names the chain')
    Markers().PT_D = nil
    Chains.AddMarker('PT_Other', 'PT_B')
    Map.RemoveMarker('PT_B')
    local dead = false
    for _, p in Chains.Problems() do if string.find(p.text, 'does not exist', 1, true) then dead = true end end
    Check(dead, 'a chain member that no longer exists is reported')
    Place('PT_B', 'Blank Marker', 60, 70)
    -- the mission follows a rename
    local M = import('/lua/editor/mission.lua')
    local savedData = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    M.AddStage('S')
    local _, p1 = M.AddNode(1, 'ready', 'group_patrol')
    M.SetParam(1, 'ready', p1, 'chain', 'PT_Chain')
    local renamed, refs = Chains.Rename('PT_Chain', 'PT_Renamed')
    Check(renamed == true and refs == 1 and M.Data.stages[1].ready[1].chain == 'PT_Renamed' and Chains.Markers('PT_Renamed'), 'rename follows the mission node (' .. tostring(refs) .. ' reference)')
    H.Undo()
    Check(M.Data.stages[1].ready[1].chain == 'PT_Chain' and Chains.Markers('PT_Chain') and not Chains.Markers('PT_Renamed'), 'one undo reverts the chain and the mission reference')
    M.Data = savedData
    Check(Chains.Delete('PT_Other') == true and not Chains.Markers('PT_Other'), 'Delete')
    H.Undo()
    Check(Chains.Markers('PT_Other') ~= nil, 'and undo')
    Chains.Delete('PT_Other')

    -- ---- align / distribute / circle / snap -------------------------------------------------------------------------------------------------------
    local function Select3()
        Tools.Select('marker', 'PT_A')
        Tools.Select('marker', 'PT_B', 'add')
        Tools.Select('marker', 'PT_C', 'add')
    end
    local ui = import('/lua/editor/ui.lua')
    local oldTool = ui.State.tool
    ui.State.tool = 'select'
    Select3()
    Check(Arr.Kind() == 'markers' and Arr.Count() == 3, 'Arrange sees the three selected markers')
    local depth0 = H.Depth()
    Arr.Align('left')
    Check(Markers().PT_A.position[1] == 40 and Markers().PT_B.position[1] == 40 and Markers().PT_C.position[1] == 40, 'Align left puts all on the westmost x')
    Check(H.Depth() == depth0 + 1, 'the align is one undo step')
    H.Undo()
    Check(Markers().PT_C.position[1] == 90, 'and undone together')
    Select3()
    Arr.Distribute('x')
    Check(Markers().PT_B.position[1] == 65, 'Distribute spaces evenly (B at ' .. tostring(Markers().PT_B.position[1]) .. ')')
    H.Undo()
    Select3()
    Arr.Align('centerz')
    local z = Markers().PT_A.position[3]
    Check(z == Markers().PT_B.position[3] and z == Markers().PT_C.position[3] and z == 55, 'Align centre vertically (z ' .. tostring(z) .. ')')
    H.Undo()
    Select3()
    local moved = Arr.Circle()
    local cx, cz, radii = 0, 0, {}
    for _, n in { 'PT_A', 'PT_B', 'PT_C' } do cx, cz = cx + Markers()[n].position[1], cz + Markers()[n].position[3] end
    cx, cz = cx / 3, cz / 3
    for _, n in { 'PT_A', 'PT_B', 'PT_C' } do
        local dx, dz = Markers()[n].position[1] - cx, Markers()[n].position[3] - cz
        table.insert(radii, math.sqrt(dx * dx + dz * dz))
    end
    Check(math.abs(radii[1] - radii[2]) < 0.05 and math.abs(radii[2] - radii[3]) < 0.05, 'Circle: equal distances from the centre')
    H.Undo()
    Markers().PT_A.position[1] = 40.3
    Markers().PT_A.position[3] = 40.7
    Tools.Select('marker', 'PT_A')
    Arr.Snap(2)
    Check(Markers().PT_A.position[1] == 40 and Markers().PT_A.position[3] == 40, 'Snap to a 2 unit grid')
    ui.State.tool = oldTool

    -- ---- statistics ---------------------------------------------------------------------------------------------------------------------------------
    local stats = Stats.Compute()
    Check(stats.markers['Blank Marker'] and stats.markers['Blank Marker'] >= 3 and stats.size and stats.size > 0, 'statistics count markers by type')
    Check(table.getn(Stats.Rows(stats)) > 5, 'statistics rows')

    -- ---- find and replace ---------------------------------------------------------------------------------------------------------------------------
    Place('PT_REPL1', 'Combat Zone', 30, 30)
    Place('PT_REPL2', 'Combat Zone', 35, 35)
    Check(FR.Count('marker type', 'Combat Zone') == 2, 'Count finds two Combat Zone markers')
    local depth1 = H.Depth()
    local n = FR.Replace('marker type', 'Combat Zone', 'Rally Point')
    Check(n == 2 and Markers().PT_REPL1.type == 'Rally Point' and Markers().PT_REPL2.type == 'Rally Point', 'Replace changes the marker type of both')
    Check(H.Depth() == depth1 + 1, 'one undo step')
    H.Undo()
    Check(Markers().PT_REPL1.type == 'Combat Zone', 'undone')
    Check(FR.Select('marker type', 'Combat Zone') == 2 and Tools.SelectionCount() == 2, 'Select matches')
    local props = import('/lua/editor/props.lua')
    local cat = props.Catalog()
    if table.getn(cat) >= 2 then
        local a, b = cat[1].path, cat[2].path
        local idx = Map.AddProp(a, 20, 0, 20, 0, { 1, 1, 1 })
        local c1 = FR.Count('prop blueprint', a)
        local r = FR.Replace('prop blueprint', a, b)
        Check(c1 >= 1 and r >= 1 and FR.Count('prop blueprint', a) == 0, 'props: replace by blueprint (' .. tostring(r) .. ' replaced)')
        H.Undo()
        Check(FR.Count('prop blueprint', a) >= 1, 'props: undone')
        props.Selection = {}
        for i = ed_prop_count(), 1, -1 do
            local bp, x, y, zz = ed_prop_get(i)
            if bp == a and math.abs(x - 20) < 0.01 and math.abs(zz - 20) < 0.01 then Map.RemoveProp(i) end
        end
    end

    -- ---- favourites -------------------------------------------------------------------------------------------------------------------------------------
    Fav.Reset()
    Check(not Fav.Is('props', '/x/a') and Fav.Toggle('props', '/x/a') == true and Fav.Is('props', '/x/a'), 'Toggle stars an entry')
    local arranged = Fav.Arrange('props', { { p = '/x/b' }, { p = '/x/a' }, { p = '/x/c' } }, function(e) return e.p end, false)
    Check(arranged[1].p == '/x/a' and arranged[2].p == '/x/b' and table.getn(arranged) == 3, 'starred entries first')
    Check(table.getn(Fav.Arrange('props', { { p = '/x/b' }, { p = '/x/a' } }, function(e) return e.p end, true)) == 1, 'starred only')
    Fav.Toggle('props', '/x/a')
    Check(not Fav.Is('props', '/x/a'), 'toggled off')
    Fav.Reset()

    -- ---- PNG writer ---------------------------------------------------------------------------------------------------------------------------------------
    local hi, lo = Png.Crc32('123456789')
    Check(hi == 0xCBF4 and lo == 0x3926, 'CRC-32 of 123456789 (' .. string.format('%04X%04X', hi, lo) .. ')')
    hi, lo = Png.Crc32('IEND')
    Check(hi == 0xAE42 and lo == 0x6082, 'CRC-32 of IEND')
    local px = { 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF, 0x000000, 0x808080 }
    local data = Png.Encode(3, 2, px)
    Check(string.sub(data, 2, 4) == 'PNG' and string.len(data) > 60, 'PNG signature and size (' .. string.len(data) .. ' bytes)')
    Check(Png.Write('../parity_test.png', 3, 2, px) == true, 'PNG written to a file')
    local pv = import('/lua/editor/preview.lua')
    Check(pv.ExportPng('../parity_preview.png', 64) == true, 'preview exported as PNG')

    -- ---- map info ---------------------------------------------------------------------------------------------------------------------------------------
    local Maps = import('/lua/editor/maps.lua')
    local oldInfo = Maps.Info()
    Maps.SetInfo({ version = 7, norush = 45, starts = false })
    local info = Maps.Info()
    Check(info.version == 7 and info.norush == 45 and info.starts == false and Map.Doc.info.map_version == 7 and Map.Doc.info.norushradius == 45, 'map info version, no-rush radius and starts')
    Maps.SetInfo({ version = oldInfo.version, norush = oldInfo.norush, starts = oldInfo.starts })

    -- ---- mirror through the symmetry -------------------------------------------------------------------------------------------------------------
    local Sym = import('/lua/editor/symmetry.lua')
    local Mir = import('/lua/editor/mirror.lua')
    local oldMode = Sym.Mode
    Sym.SetMode('off')
    -- Mirror also copies selected props, units and decals: whatever another test left selected would count too (shuffled order)
    import('/lua/editor/props.lua').ClearSelection()
    import('/lua/editor/units.lua').ClearSelection()
    import('/lua/editor/decals.lua').ClearSelection()
    Tools.Select('marker', 'PT_A')
    local n0, why0 = Mir.Mirror()
    Check(n0 == 0, 'Mirror needs a symmetry mode (' .. tostring(why0) .. ')')
    Sym.SetMode('mirror_x')
    local count0 = 0
    for _ in Markers() do count0 = count0 + 1 end
    Markers().PT_A.position[1] = 40
    Markers().PT_A.orientation = { 0, 0.5, 0 }
    Tools.Select('marker', 'PT_A')
    local depth2 = H.Depth()
    local made = Mir.Mirror()
    local count1 = 0
    for _ in Markers() do count1 = count1 + 1 end
    local cx = Sym.Centre()
    local found
    for name, m in Markers() do
        if name ~= 'PT_A' and m.type == 'Blank Marker' and math.abs(m.position[1] - (2 * cx - 40)) < 0.01 and math.abs(m.position[3] - Markers().PT_A.position[3]) < 0.01 then found = m end
    end
    Check(made == 1 and count1 == count0 + 1 and found, 'Mirror copies the marker to the image position')
    Check(found and math.abs(found.orientation[2] + 0.5) < 0.001, 'with the mirrored heading (' .. tostring(found and found.orientation[2]) .. ')')
    Check(H.Depth() == depth2 + 1, 'one undo step')
    H.Undo()
    local count2 = 0
    for _ in Markers() do count2 = count2 + 1 end
    Check(count2 == count0, 'undone')
    Sym.SetMode(oldMode)

    -- ---- environment styles --------------------------------------------------------------------------------------------------------------------------
    local Styles = import('/lua/editor/styles.lua')
    local World = import('/lua/editor/world.lua')
    local text = Styles.Text(false)
    Check(string.find(text, 'light_mult', 1, true) and not string.find(text, 'water_elev', 1, true), 'style text holds lighting values, not the water levels')
    local parsed = Styles.Parse(text)
    Check(parsed and parsed.light_mult == World.Value('light_mult') or (parsed and math.abs(parsed.light_mult - World.Value('light_mult')) < 0.001), 'style text parses back')
    local oldMult = World.Value('light_mult')
    ed_write_file('../parity_style.lua', 'Style = { light_mult = 2.5, water_elev = 99, not_a_key = 3 }\n')
    local applied = Styles.Load('../parity_style.lua', false)
    Check(applied == 1 and math.abs(World.Value('light_mult') - 2.5) < 0.001, 'Load applies the known values and leaves the water level (' .. tostring(applied) .. ')')
    H.Undo()
    Check(math.abs(World.Value('light_mult') - oldMult) < 0.001, 'one undo step restores it')
    Check(Styles.Load('../does_not_exist.lua') == 0, 'a missing file loads nothing')

    -- ---- range rings ----------------------------------------------------------------------------------------------------------------------------------
    local Rings = import('/lua/editor/unitrings.lua')
    local kinds = {}
    for _, r in Rings.Radii('uel0106') do kinds[r.kind] = r.radius end
    Check(kinds.weapon and kinds.weapon > 5 and kinds.vision and kinds.vision > 5, 'a light assault bot has a weapon and a vision ring (' .. tostring(kinds.weapon) .. ' / ' .. tostring(kinds.vision) .. ')')
    Check(table.getn(Rings.Radii('no_such_unit')) == 0, 'an unknown unit has none')

    -- ---- camera marker node in a cutscene ---------------------------------------------------------------------------------------------------------
    local M = import('/lua/editor/mission.lua')
    local savedData = M.Data
    M.Data = { mode = 'campaign', stages = {}, bases = {}, dialogues = {} }
    M.AddStage('Cut')
    local _, cut = M.AddNode(1, 'ready', 'cutscene')
    local _, cm = M.AddNode(1, 'ready', 'cam_marker', nil, cut)
    M.SetParam(1, 'ready', cm, 'marker', 'PT_CAM')
    M.AddNode(1, 'ready', 'end')
    local bad = {}
    for _, f in M.Check() do if f.sev ~= 'I' then table.insert(bad, f.text) end end
    Check(table.getn(bad) == 0, 'a Camera Info marker is accepted by the cutscene node (' .. table.concat(bad, ' | ') .. ')')
    Check(string.find(M.Compile(true), "Cinematics.CameraMoveToMarker(ScenarioUtils.GetMarker('PT_CAM'), 4)", 1, true) ~= nil, 'and compiles to CameraMoveToMarker')
    M.SetParam(1, 'ready', cm, 'marker', 'PT_A')
    local wrongType = false
    for _, f in M.Check() do if string.find(f.text, 'is not a Camera Info marker', 1, true) then wrongType = true end end
    Check(wrongType, 'another marker type is refused')
    Check(table.getn(M.MarkerNames('Camera Info')) >= 1 and table.getn(M.MarkerNames()) > table.getn(M.MarkerNames('Camera Info')), 'the picker can filter by marker type')
    M.Data = savedData

    Cleanup()
    table.insert(out, failed == 0 and 'ALL PASS' or (failed .. ' FAILED'))
    return table.concat(out, '\n')
end
