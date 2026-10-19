-- Mesh map manifest round trip and checks. Through /edcmd, in an /editor session, with a fixture folder made by scripts (terrain/terrain.lua + scm files):
--   return import('/lua/editor/selftest_mesh.lua').Run('<fixture folder on disk>')
-- Parse(text) then Write must give the text back byte for byte; Check lists what the open map and the files disagree about.

local Mesh = import('/lua/editor/meshmap.lua')

function Run(dir)
    local out = {}
    local path = dir .. '/terrain/terrain.lua'
    local text = ed_read_file(path)
    if not text then return 'no fixture at ' .. path end
    local m = Mesh.Parse(text)
    table.insert(out, string.format('parsed: %d settings keys, %d materials, %d patch entries, %d warnings', table.getn(Mesh.Keys), table.getn(m.materials), table.getn(m.patches), table.getn(m.warnings)))
    for _, w in m.warnings do table.insert(out, 'warning: ' .. w) end
    local again = Mesh.Write(m)
    if again == text then
        table.insert(out, 'ROUNDTRIP OK (' .. string.len(text) .. ' bytes)')
    else
        -- first difference
        local n = math.min(string.len(text), string.len(again))
        local at = n + 1
        for i = 1, n do
            if string.sub(text, i, i) ~= string.sub(again, i, i) then at = i break end
        end
        table.insert(out, 'ROUNDTRIP DIFFERS at byte ' .. at .. ': file [' .. string.sub(text, at - 20, at + 30) .. '] written [' .. string.sub(again, at - 20, at + 30) .. ']')
    end
    -- a dialect error is reported
    local bad = Mesh.Parse("TerrainMesh = {\n    size = 1e3,\n    water = \"5\",\n    materials = {\n    },\n    patches = {\n    },\n}\n")
    table.insert(out, 'dialect warnings on a bad manifest: ' .. table.getn(bad.warnings))
    for _, w in bad.warnings do table.insert(out, '  ' .. w) end
    -- checks (the open map is not the fixture's, so some findings are expected)
    local list = Mesh.Check(m, dir)
    for _, i in list do table.insert(out, i.sev .. ' ' .. i.code .. ' ' .. i.text) end
    -- a model made from the map
    local fm = Mesh.FromMap()
    table.insert(out, 'FromMap: size ' .. tostring(fm.settings.size) .. ' ground ' .. tostring(fm.settings.ground_low) .. ' .. ' .. tostring(fm.settings.ground_high))
    return table.concat(out, '\n')
end
