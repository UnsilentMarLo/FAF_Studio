-- Heightmap import and export. Files: 16-bit greyscale PNG or TIFF, or a raw 16-bit little-endian square (`.raw`). The map's height samples are
-- the engine's 16-bit words (world height = word / 128), so a file round trip is exact; an imported image of another size is resampled
-- (bilinear) onto the map's grid.
--
--   Export([path])   writes the whole height field (asks for the file with the save dialog when no path is given)
--   Import([path])   replaces the whole height field (one undo step); asks with the open dialog when no path is given
--
-- Lua 5.0 dialect.

local Sim = import('/lua/editor/sim.lua')
local History = import('/lua/editor/history.lua')

local FILTER = '16-bit heightmap (*.png;*.tif;*.raw)|*.png;*.tif;*.tiff;*.raw|All files|*.*'

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
    LOG('EDITOR heightmap: ' .. text)
end

function Export(path)
    local w, h = ed_terrain_info()
    if not w then Say('no terrain') return false end
    path = path or ed_file_dialog(true, 'Export heightmap', FILTER, 'heightmap.png')
    if not path then return false end
    local words = ed_terrain_read_rect(0, 0, w - 1, h - 1)
    if not words then Say('cannot read the terrain') return false end
    local ok, err = ed_image_write16(path, w, h, words)
    if not ok then Say('export failed: ' .. tostring(err)) return false end
    Say(string.format('exported %dx%d heights to %s', w, h, path))
    return true
end

function Import(path)
    local w, h = ed_terrain_info()
    if not w then Say('no terrain') return false end
    path = path or ed_file_dialog(false, 'Import heightmap', FILTER, '')
    if not path then return false end
    local words, iw, ih = ed_image_read16(path, w, h)
    if not words then Say('import failed: ' .. tostring(iw)) return false end
    ed_cmd_begin('Import heightmap')
    local n = ed_doc_height_write(0, 0, w - 1, h - 1, words)
    ed_cmd_end()
    if n and n > 0 then
        History.PushTerrain()
        Sim.Resnap(0, 0, w - 1, h - 1)
    end
    Say(string.format('imported %s (%dx%d%s)', path, iw, ih, (iw ~= w or ih ~= h) and (', resampled to ' .. w .. 'x' .. h) or ''))
    return true
end
