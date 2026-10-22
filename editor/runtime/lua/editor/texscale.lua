-- Tile size of a terrain texture layer from texel density: the default size a layer gets when it is given a texture (texture sets, looks, generators, the Layers panel).
--
-- THE MATHS
--   A layer shows one texture repeat over T world units. A texture R pixels wide then has R / T texels per world unit. The screen at the closest normal view shows p pixels per
--   world unit. Texels are sharp while R / T >= p (no magnification blur); a larger T repeats the texture less often (less visible tiling) but blurs it. So the best tile is the
--   largest one that is still sharp:
--
--       T = R / d      with d = p, the screen pixels per world unit at the reference view
--
--   p of a perspective view of height H pixels, vertical field of view f, at eye distance D from the ground point looked at:  p = H / (2 D tan(f / 2)).
--   Reference view (an assumption, not read from the engine): H = 1080 px, f = 45 degrees, D = 27 world units (the near end of the zoom range of the game camera):
--       p = 1080 / (2 * 27 * 0.41421) = 48.3 texels per world unit.
--   That gives a 1024 px texture T = 21.2 (the 18 - 24 band mapmakers use), 2048 px T = 42.4; a smaller texture would ask for less (512 px: 10.6) but is lifted to REPEAT_MIN = 20, because a tile of about 10 units repeats so often that the grain shows as a regular pattern. The result is rounded to STEP (0.5) and clamped to [MIN, MAX] = [4, 64]
--   (a 128 px texture would ask for 2.7, a 4096 px one for 85). A camera zoomed in further, or a taller screen, shows the blur; only DENSITY (or REF_DISTANCE) needs changing then.
--
--   The normal map defaults to the SAME tile size as its albedo: the two are sampled with the same UVs and a different size would let the bumps drift off the colours they belong to.
--
-- REPETITION
--   The same T for every layer is fine: layers are different textures. What must not happen is two overlays whose tiles have a simple ratio (2 : 1, 3 : 1): their repeat patterns then
--   line up every few tiles and a pattern shows up. The golden ratio phi = 1.618... is the number least well approximated by fractions (its continued fraction is all ones), so
--   the ratios phi^2 = 2.618, phi^3 = 4.236, phi^4 = 6.854, phi^5 = 11.09 stay 0.09 or more from a whole number (phi^6 = 17.94, phi^7 = 29.03 and higher do not: they approach the
--   Lucas numbers). Decorrelate(size[, k]) is size * phi^k rounded to STEP. MacroTile(baseSize) uses it for the Upper layer (the macrotexture: a low frequency colour overlay with no
--   matching normal map): baseSize * phi^k with k = 2 .. 5, the one nearest 128 (the engine's default for that slot) in log scale. Layers that must stay aligned (an albedo and its
--   normal map) are never decorrelated. The base layer uses plain Optimal (the former rule "base = 2 x painted layers" only halved its sharpness).
--
--   Optimal(albedoPath[, fallback])    tile size in world units; the texture width is read once per path (cached); `fallback` replaces the result when the file cannot be read
--   NormalSize(albedoPath)             the same value for the normal map
--   ForPixels(px)                      the formula alone
--   Pixels(path)                       pixel width of a DDS in the game data or on disk (nil when it cannot be read); Remember(path, px) / Forget() set and clear the cache
--   TexelsPerUnit(path, size)          texels per world unit of a texture at a tile size
--   Decorrelate(size[, steps])         size * phi^steps rounded to STEP (steps default 1)
--   MacroTile(baseSize[, target])      tile for the Upper layer, decorrelated from baseSize, near `target` (default 128)
--   IsEmpty(albedo)                    the layer has no texture ('' or the transparent placeholder)
--   IsDefault(albedo, size)            the size is one nobody chose: the engine slot default (4 or 1) or the Optimal size of that texture
--   Carry(oldAlbedo, oldSize, oldNsize, newAlbedo) -> size, nsize    swapping a texture keeps a size the user tuned, but an empty or default layer takes Optimal of the new texture
--
-- How the width is read: ed_dds_thumb(src, scratch, 4) (EdIcon.cpp) decodes the DDS from a plain file or from inside a game archive and returns its size; it is the only native that
-- reads archive entries and reports the size (ed_img_info goes through WIC, which does not read DDS or archives). It decodes the whole texture once (a few ms for 2048 x 2048).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

REF_HEIGHT = 1080                       -- pixels, height of the reference screen
REF_FOV = 45                            -- degrees, vertical field of view
REF_DISTANCE = 27                       -- world units, eye distance at the closest normal zoom
DENSITY = REF_HEIGHT / (2 * REF_DISTANCE * math.tan(REF_FOV * 3.14159265 / 360))     -- screen pixels per world unit (texels per unit a tile must keep): 48.3
STEP = 0.5
MIN = 4
MAX = 64
REPEAT_MIN = 20                         -- world units: below this a tile repeats so often that the pattern shows as a regular grain over the ground (a 512 px texture at 10.5 did)
FALLBACK_PIXELS = 1024                  -- width assumed when the file cannot be read
ENGINE_DEFAULT = 4                      -- tile size of an empty slot in the engine and in the blank map templates
PHI = 1.6180339887
MACRO_TARGET = 128                      -- the engine's default tile of the Upper layer
MACRO_MIN = 32
MACRO_MAX = 256

local cache = {}        -- lower case path -> pixel width, or false (could not be read)
local PLACEHOLDER = '/textures/editor/layers/clear_albedo.dds'
local SCRATCH = 'texscale_probe.dds'

local function Round(v)
    return math.floor(v / STEP + 0.5) * STEP
end

--- The formula: tile size in world units for a texture `px` pixels wide.
function ForPixels(px)
    px = tonumber(px) or FALLBACK_PIXELS
    if px < 1 then px = FALLBACK_PIXELS end
    local t = Round(px / DENSITY)
    if t < REPEAT_MIN then t = REPEAT_MIN end         -- small textures are stretched a little (a bit blurrier at the closest zoom) rather than tiled densely
    if t < MIN then t = MIN end
    if t > MAX then t = MAX end
    return t
end

local function Key(path)
    local p = string.gsub(tostring(path or ''), '\\', '/')
    return string.lower(p)
end

function Remember(path, px)
    cache[Key(path)] = px or false
end

function Forget()
    cache = {}
end

local function Probe(path)
    if not rawget(_G, 'ed_dds_thumb') then return nil, true end          -- no native in this build: not cached, asked again later
    local src = path
    if rawget(_G, 'ed_vfs_to_disk') then src = ed_vfs_to_disk(path) or path end
    local ok, scratch = pcall(function() return import('/lua/editor/userdata.lua').Path(SCRATCH) end)
    if not ok or not scratch then return nil, true end
    local ok2, w = pcall(ed_dds_thumb, src, scratch, 4)
    if ok2 and type(w) == 'number' and w >= 1 then return w end
    return nil
end

--- Pixel width of the DDS at `path` (a VFS path or a disk path); nil when it cannot be read. Cached per path.
function Pixels(path)
    if not path or path == '' then return nil end
    local k = Key(path)
    local c = cache[k]
    if c ~= nil then return c or nil end
    local w, transient = Probe(path)
    if not transient then cache[k] = w or false end
    return w
end

function IsEmpty(albedo)
    return albedo == nil or albedo == '' or Key(albedo) == PLACEHOLDER
end

--- Tile size in world units for the albedo texture at `path`; `fallback` (when given) stands in for a texture that cannot be read, else a 1024 px texture is assumed.
function Optimal(path, fallback)
    local px = Pixels(path)
    if not px then
        if fallback then return fallback end
        px = FALLBACK_PIXELS
    end
    return ForPixels(px)
end

--- Tile size of the normal map that belongs to an albedo: the same one.
function NormalSize(path, fallback)
    return Optimal(path, fallback)
end

--- Texels per world unit of a texture at a tile size (nil when the width is unknown).
function TexelsPerUnit(path, size)
    local px = Pixels(path)
    if not px or not size or size <= 0 then return nil end
    return px / size
end

--- size * phi^steps (steps may be negative), rounded to STEP and never below MIN.
function Decorrelate(size, steps)
    local v = Round((size or MIN) * math.pow(PHI, steps or 1))
    if v < MIN then v = MIN end
    return v
end

--- The tile of the Upper layer (a macrotexture): baseSize * phi^k for k = 2 .. 5 (k = 1 is too close to the base, powers above 5 are within 0.06 of a whole number: phi^6 = 17.94, phi^7 = 29.03
--- and so line up), within [MACRO_MIN, MACRO_MAX], whose ratio to baseSize after rounding is at least 0.08 from a whole number; of those the one nearest `target` in log scale.
function MacroTile(baseSize, target)
    target = target or MACRO_TARGET
    baseSize = baseSize or MIN
    if baseSize < 1 then baseSize = MIN end
    local best, bestErr, loose, looseErr
    for k = 2, 5 do
        local v = baseSize * math.pow(PHI, k)
        if v >= MACRO_MIN and v <= MACRO_MAX then
            local err = math.abs(math.log(v / target))
            local r = Round(v) / baseSize
            if math.abs(r - math.floor(r + 0.5)) >= 0.08 then
                if not bestErr or err < bestErr then best, bestErr = v, err end
            elseif not looseErr or err < looseErr then
                loose, looseErr = v, err
            end
        end
    end
    best = best or loose or target
    return Round(best)
end

--- True when `size` is a number nobody chose for the texture `albedo`: unset, the engine's slot default (4, or 1) or the Optimal size of that texture.
function IsDefault(albedo, size)
    if not size or size <= 0 then return true end
    if math.abs(size - ENGINE_DEFAULT) < 0.01 or math.abs(size - 1) < 0.01 then return true end
    if IsEmpty(albedo) then return true end
    return math.abs(size - Optimal(albedo)) < 0.01
end

--- The sizes a layer gets when its albedo is swapped: a size the user tuned stays, an empty layer or a default size takes Optimal of the new texture.
function Carry(oldAlbedo, oldSize, oldNsize, newAlbedo)
    local opt = Optimal(newAlbedo)
    local size, nsize = oldSize, oldNsize
    if IsDefault(oldAlbedo, oldSize) then size = opt end
    if IsDefault(oldAlbedo, oldNsize) then nsize = opt end
    return size, nsize
end
