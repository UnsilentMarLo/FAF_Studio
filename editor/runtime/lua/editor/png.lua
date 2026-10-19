-- A small PNG writer for RGB pictures (8 bit, uncompressed deflate blocks): the preview / minimap export. Lua numbers here are 32-bit floats, which cannot hold a CRC (32 bits),
-- so the CRC runs on two 16-bit halves (every intermediate value stays below 2^24).
--
--   Encode(w, h, pixels)        -> the file as a string; pixels = array of w * h numbers 0xRRGGBB, row major, top row first
--   Write(path, w, h, pixels)   -> true | false, reason (ed_write_file; binary safe)
--   Crc32(text)                 -> hi, lo (the two 16-bit halves of the CRC-32 of the string; used by the tests against zlib's value)
--
-- Lua 5.0 dialect.

local crcHi, crcLo = {}, {}

local function Xor16(a, b)
    return a + b - 2 * (a & b)
end

local function InitTable()
    if table.getn(crcHi) > 0 then return end
    for n = 0, 255 do
        local hi, lo = 0, n
        for _ = 1, 8 do
            local carry = math.mod(lo, 2)
            lo = math.floor(lo / 2) + math.mod(hi, 2) * 32768
            hi = math.floor(hi / 2)
            if carry == 1 then
                -- polynomial 0xEDB88320
                hi = Xor16(hi, 0xEDB8)
                lo = Xor16(lo, 0x8320)
            end
        end
        crcHi[n + 1], crcLo[n + 1] = hi, lo
    end
end

function Crc32(text)
    InitTable()
    local hi, lo = 0xFFFF, 0xFFFF
    for i = 1, string.len(text) do
        local idx = Xor16(math.mod(lo, 256), string.byte(text, i))
        -- crc = table[idx] xor (crc >> 8)
        local nlo = math.floor(lo / 256) + math.mod(hi, 256) * 256
        local nhi = math.floor(hi / 256)
        hi = Xor16(crcHi[idx + 1], nhi)
        lo = Xor16(crcLo[idx + 1], nlo)
    end
    return Xor16(hi, 0xFFFF), Xor16(lo, 0xFFFF)
end

local function Be32(v)
    return string.char(math.floor(v / 16777216), math.mod(math.floor(v / 65536), 256), math.mod(math.floor(v / 256), 256), math.mod(v, 256))
end

local function Be16Pair(hi, lo)
    return string.char(math.floor(hi / 256), math.mod(hi, 256), math.floor(lo / 256), math.mod(lo, 256))
end

local function Chunk(kind, data)
    local body = kind .. data
    local hi, lo = Crc32(body)
    return Be32(string.len(data)) .. body .. Be16Pair(hi, lo)
end

--- Raw scanlines: a filter byte 0 and the RGB bytes of every row.
local function Scanlines(w, h, pixels)
    local rows = {}
    for y = 0, h - 1 do
        local bytes = { '\0' }
        local base = y * w
        local n = 1
        local chunk = {}
        for x = 1, w do
            local v = pixels[base + x] or 0
            local r = math.floor(v / 65536)
            local g = math.mod(math.floor(v / 256), 256)
            local b = math.mod(v, 256)
            chunk[table.getn(chunk) + 1] = string.char(r, g, b)
        end
        rows[y + 1] = '\0' .. table.concat(chunk)
    end
    return table.concat(rows)
end

--- zlib stream with stored blocks.
local function Zlib(raw)
    local out = { '\120\1' }
    local len = string.len(raw)
    local pos = 1
    if len == 0 then
        table.insert(out, '\1\0\0\255\255')
    end
    while pos <= len do
        local n = math.min(65535, len - pos + 1)
        local final = (pos + n > len) and 1 or 0
        table.insert(out, string.char(final, math.mod(n, 256), math.floor(n / 256), math.mod(65535 - n, 256), math.floor((65535 - n) / 256)))
        table.insert(out, string.sub(raw, pos, pos + n - 1))
        pos = pos + n
    end
    -- Adler-32 of the raw data (a and b stay below 65521)
    local a, b = 1, 0
    for i = 1, len do
        a = a + string.byte(raw, i)
        if a >= 65521 then a = a - 65521 end
        b = b + a
        if b >= 65521 then b = b - 65521 end
    end
    table.insert(out, string.char(math.floor(b / 256), math.mod(b, 256), math.floor(a / 256), math.mod(a, 256)))
    return table.concat(out)
end

function Encode(w, h, pixels)
    local ihdr = Be32(w) .. Be32(h) .. string.char(8, 2, 0, 0, 0)
    return '\137PNG\13\10\26\10' .. Chunk('IHDR', ihdr) .. Chunk('IDAT', Zlib(Scanlines(w, h, pixels))) .. Chunk('IEND', '')
end

function Write(path, w, h, pixels)
    local ok = ed_write_file(path, Encode(w, h, pixels))
    if ok then return true end
    return false, 'could not write ' .. tostring(path)
end
