-- Colour values of the terrain graph (stage T7): a `color` value is { r = field, g = field, b = field, a = field } (four 0..1 fields, made by the Colour ramp node). This module turns it into
-- pixels, a node thumbnail and a DDS file. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')

CHANNELS = { 'r', 'g', 'b', 'a' }

--- pw x ph pixels (a list of pw * ph * 4 numbers 0..255, row major, r g b a) of a colour value; each channel is box averaged from its field.
function Pixels(c, pw, ph)
    local chan = {}
    for _, k in CHANNELS do
        local px = ed_field_preview(c[k], pw, ph, { lo = 0, hi = 1, ramp = 'grey' })
        if not px then return nil end
        chan[k] = px
    end
    local out = {}
    for i = 0, pw * ph - 1 do
        local o = i * 4
        out[o + 1] = chan.r[o + 1]
        out[o + 2] = chan.g[o + 1]
        out[o + 3] = chan.b[o + 1]
        out[o + 4] = chan.a[o + 1]
    end
    return out
end

--- A thumbnail of the colour value for a node (a Bitmap path) or nil.
function Thumb(c, size)
    local w, h = ed_field_info(c.r)
    local pw, ph = size, size
    if w > h then ph = math.max(1, math.floor(size * h / w + 0.5)) elseif h > w then pw = math.max(1, math.floor(size * w / h + 0.5)) end
    local px = Pixels(c, pw, ph)
    if not px then return nil end
    return Fields.PreviewPixels(px, pw, ph)
end

--- Writes the colour value as a DXT5 DDS file of size x size pixels (a relative path is relative to the editor's working folder). Returns true, or nil and a message.
function Write(c, path, size)
    size = math.max(4, math.floor(size))
    local px = Pixels(c, size, size)
    if not px then return nil, 'the colour could not be read' end
    local bytes, err = ed_dds_write(path, size, size, px, 1)
    if not bytes then return nil, tostring(err) end
    return true
end
