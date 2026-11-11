-- Lua syntax check of the map's three scripts (`_scenario.lua`, `_save.lua`, `_script.lua`), reported with the line of the first error (the "Check" of upstream's editor, EdDocument::CheckScripts).
--
--   CheckText(text, name)   -> { ok = true } | { ok = false, line = n | nil, message, raw }   compiles with the engine's own parser; nothing is run (native ed_up_check_lua)
--   Scripts()               -> list of { file, vfs, disk } of the open map's three scripts that exist on disk
--   Check()                 -> list of { file, line, message, text, vfs, disk }: one per script that does not compile, `text` = 'x_script.lua:12: message'
--                              nil, 'no native' in an exe without ed_up_check_lua
--
-- The files are checked as they are on disk: the editor does not edit scripts itself (open `_script.lua` in your own editor, save, check again). The generated mission region of the
-- script is part of the file, so a broken Raw Lua node shows up here too.
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

--- Compiles `text` (chunk name `name`); see the header.
function CheckText(text, name)
    if not rawget(_G, 'ed_up_check_lua') then return nil, 'no native' end
    return ed_up_check_lua(text, name)
end

function Scripts()
    local list = {}
    local doc = Map.Doc
    if not doc then return list end
    for _, vfs in { doc.scenarioPath, doc.savePath, doc.scriptPath } do
        if type(vfs) == 'string' and vfs ~= '' then
            local disk = ed_vfs_to_disk(vfs)
            if disk then
                local file = string.gsub(vfs, '^.*/', '')
                table.insert(list, { file = file, vfs = vfs, disk = disk })
            end
        end
    end
    return list
end

function Check()
    if not rawget(_G, 'ed_up_check_lua') then return nil, 'no native' end
    local out = {}
    for _, s in Scripts() do
        local text = ed_read_file(s.disk)
        if text and text ~= '' then
            local r = ed_up_check_lua(text, s.file)
            if r and not r.ok then
                local where = r.line and (s.file .. ':' .. r.line .. ': ') or (s.file .. ': ')
                table.insert(out, { file = s.file, line = r.line, message = r.message, text = where .. tostring(r.message), vfs = s.vfs, disk = s.disk })
            end
        end
    end
    return out
end
