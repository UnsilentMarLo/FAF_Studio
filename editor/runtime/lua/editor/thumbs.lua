-- Thumbnails of maps for the start screen: the preview picture an .scmap carries (the blob after the 30 byte header: an i32 byte count and an uncompressed ARGB DDS,
-- see ed_scmap_set_preview) is cut out once and kept as `thumbs/<name>.dds` in the user folder, which is mounted as /edthumbs so a Bitmap can show it.
-- The name carries the map's size and time stamp, so an edited map gets a fresh picture (textures are cached by name).
--
--   For(scenarioPath) -> vfs path of the picture | nil, why     reads the .scmap once per version of it (a big map takes a moment: the start screen asks for one per frame)
--   Cached(scenarioPath) -> vfs path | nil                     only what is on disk already
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')

local mounted = false

local function Norm(p) return (string.gsub(p or '', '\\', '/')) end

--- The .scmap next to a scenario file (disk path), or nil when the map is not a plain folder.
local function ScmapOf(scenarioPath)
    local disk = scenarioPath and ed_vfs_to_disk(scenarioPath)
    if not disk then return nil end
    disk = Norm(disk)
    local stem = string.gsub(string.gsub(disk, '^.*/', ''), '_scenario%.lua$', '')
    local dir = string.gsub(disk, '/[^/]*$', '')
    local path = dir .. '/' .. stem .. '.scmap'
    if ed_file_exists(path) then return path end
    return nil
end

local function Hash(text)
    local h = 5381
    for i = 1, string.len(text) do
        h = math.mod(h * 33 + string.byte(text, i), 16777216)
    end
    return string.format('%06x', h)
end

local function Name(scmap)
    local stamp = ed_file_stamp(scmap) or '0'
    local stem = string.gsub(string.gsub(scmap, '^.*/', ''), '%.scmap$', '')
    stem = string.gsub(stem, '[^%w_]', '_')
    return stem .. '_' .. Hash(scmap .. '|' .. stamp) .. '.dds'
end

local function Mount()
    if mounted then return true end
    local dir = UserData.Path('thumbs')
    -- the folder must exist to be mounted: a placeholder file creates it
    ed_write_file(dir .. '/.keep', '')
    mounted = ed_vfs_mount(dir, '/edthumbs') and true or false
    return mounted
end

function Cached(scenarioPath)
    local scmap = ScmapOf(scenarioPath)
    if not scmap then return nil end
    local name = Name(scmap)
    if ed_file_exists(UserData.Path('thumbs/' .. name)) and Mount() then return '/edthumbs/' .. name end
    return nil
end

local function LE32(s, i)
    -- (string.byte returns one code per call in this Lua)
    return string.byte(s, i) + string.byte(s, i + 1) * 256 + string.byte(s, i + 2) * 65536 + string.byte(s, i + 3) * 16777216
end

--- The preview blob of the .scmap text, or nil. (Offsets: 30 byte header, then the byte count, then the DDS.)
function PreviewBlob(data)
    if not data or string.len(data) < 40 or string.sub(data, 1, 3) ~= 'Map' then return nil end
    local count = LE32(data, 31)
    if count < 128 or count > 4000000 or 34 + count > string.len(data) then return nil end
    local dds = string.sub(data, 35, 34 + count)
    if string.sub(dds, 1, 4) ~= 'DDS ' then return nil end
    return dds
end

function For(scenarioPath)
    local scmap = ScmapOf(scenarioPath)
    if not scmap then return nil, 'no plain .scmap' end
    local name = Name(scmap)
    local file = UserData.Path('thumbs/' .. name)
    if not ed_file_exists(file) then
        local blob = PreviewBlob(ed_read_file(scmap))
        if not blob then return nil, 'no preview in the map file' end
        if not ed_write_file(file, blob) then return nil, 'could not write the thumbnail' end
    end
    if not Mount() then return nil, 'could not mount the thumbnails' end
    return '/edthumbs/' .. name
end
