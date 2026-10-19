-- Prop scale round trip, run in the live editor through the /edcmd channel by scripts/ed_prop_roundtrip.py:
--   return import('/lua/editor/selftest_props.lua').Run('<disk dir>', '<stem>')
-- 1. dumps the props the map was opened with (ed_prop_get, incl. scale)
-- 2. saves the map untouched as <stem>_pure (load -> save must keep every lane)
-- 3. adds two props with a scale, rescales prop 1, removes prop 2, saves as <stem>_edit and dumps again
-- Returns the dumps as text; the driver compares the saved files with the Python .scmap reader.

local Map = import('/lua/editor/map.lua')

local function Dump(tag)
    local lines = {}
    for i = 1, ed_prop_count() do
        local bp, x, y, z, qw, qx, qy, qz, sx, sy, sz = ed_prop_get(i)
        table.insert(lines, string.format('%s %d %s %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f', tag, i, bp,
            x, y, z, qw, qx, qy, qz, sx, sy, sz))
    end
    return lines
end

function Run(diskDir, stem)
    local out = Dump('LOADED')
    local scenario, why = Map.SaveAs(diskDir .. '/pure', stem .. '_pure')
    if not scenario then
        return 'FAIL save pure: ' .. tostring(why)
    end
    local blank = '/env/common/props/markers/M_Blank_prop.bp'
    local added = Map.AddProp(blank, 200, 25, 200, 0.3, { 2, 3, 4 })
    local uniform = Map.AddProp(blank, 210, 25, 200, 0, 1.75)
    local rescaled = Map.SetPropScale(1, 0.25, 0.5, 0.75)
    local removed = Map.RemoveProp(2)
    for _, l in Dump('EDITED') do
        table.insert(out, l)
    end
    scenario, why = Map.SaveAs(diskDir .. '/edit', stem .. '_edit')
    if not scenario then
        return 'FAIL save edit: ' .. tostring(why)
    end
    table.insert(out, string.format('INFO added=%s uniform=%s rescaled=%s removed=%s', tostring(added),
        tostring(uniform), tostring(rescaled), tostring(removed)))
    return table.concat(out, '\n')
end
