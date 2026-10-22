-- Role detection: which KIND of ground a terrain texture shows (grass, rock, sand, dirt, wet ground, high rock, dark rock, snow), found from the texture itself, so the Stratum recipes
-- (recipes.lua) do not depend on which layer number holds what. A map may have sand on the Base layer, grass on layer 1 and snow on layer 3; the recipe asks "which layer is sand?" and
-- gets the answer from here.
--
-- Two sources, combined:
--   (a) the NAME of the file (ClassifyName): words are cut out of the file name (Des_SandMed02_albedo.dds -> des, sand, med; camel case and digits split a word) and matched against a token
--       list (grass, moss, sand, dune, beach, dirt, mud, gravel, rock, cliff, stone, granite, snow, ice, frost, lava, ash, wet ...). Longer tokens consume a word first (sandwet is wet, not sand).
--       "dark" / "light" words move a rock to dark rock / high rock. Two kinds in one name (SandRock) lower the confidence.
--   (b) the COLOUR (ClassifyColour): the albedo reduced natively to 16 x 16 (ed_dds_thumb, then ed_dds_read; cached per path). Features are the mean colour (RGB, HSV), the green dominance
--       and the contrast; the rules: near white = snow; green dominant (hue 60..170) = grass; yellow-tan, bright, not very saturated = sand; brown, mid brightness = dirt; grey = rock
--       (dark = dark rock, pale = high rock); bluish dark = wet ground; bluish bright = ice (snow).
--   Decide(): a clear name wins; a rock name is refined by the colour (dark / pale); when the name says nothing, or says grass AND sand, the colour decides (sand versus grass is the one
--   pair the colour settles even against a weak name); a strong colour against a weak name wins. Every answer carries a confidence 0..1 and its source.
--
-- The result for the layers of the map (Layers) honours the USER'S CHOICE per texture (SetOverride: a role, or 'none' = leave this layer alone), remembered in the user settings
-- ('recipe_roles', keyed by texture path), so a texture the heuristics got wrong is corrected once.
--
--   Roles, Label(role), Choices()            the role ids (texsets.lua order) and their labels; choices for a menu
--   ClassifyName(path) -> role, conf, scores, family, modified
--   Features(px, w, h) -> table      ClassifyColour(feat) -> role, conf, scores      Decide(...)        the pure parts (px = w * h * 4 numbers 0..255, R G B A per pixel)
--   Classify(path) -> { role, conf, source, name, colour, feat }    cached per path; Forget() clears the cache
--   Albedo(layer) -> path | nil     Layers(cap) -> { [0..cap] = { layer, albedo, short, role, conf, source, auto, override, usable } }  layers with a texture only
--   SetOverride(pathOrLayer, role | nil)   Override(path)
--   Fake                                    tests: { albedo = { [layer] = path }, pixels = { [path] = { px, w, h } } } replaces what the map and the disk hold
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

Roles = { 'grass', 'rock', 'sand', 'dirt', 'wet', 'highrock', 'darkrock', 'snow' }
RoleLabels = { grass = 'Grass', rock = 'Rock (cliffs)', sand = 'Sand', dirt = 'Dirt', wet = 'Wet ground', highrock = 'High rock', darkrock = 'Dark rock', snow = 'Snow and ice' }
RockFamily = { rock = true, highrock = true, darkrock = true }

THUMB = 16                          -- pixels, the side of the reduced texture
MIN_CONF = 0.25                     -- below this a texture counts as unknown

Fake = false
Overrides = false                   -- lower case path -> role | 'none' (loaded from the user settings on first use)

local colourCache = {}              -- lower case path -> { feat, role, conf, scores } | false

function Label(role)
    if role == 'none' then return 'Not used' end
    return RoleLabels[role] or tostring(role)
end

--- ids, labels for a menu: every role, then 'none'.
function Choices()
    local ids, labels = {}, {}
    for _, r in Roles do
        table.insert(ids, r)
        table.insert(labels, RoleLabels[r])
    end
    table.insert(ids, 'none')
    table.insert(labels, 'Not used (leave this layer alone)')
    return ids, labels
end

-- ---- names -------------------------------------------------------------------------------------------------------------------------------------------

-- { token, role, weight, mode }  mode 's' = inside a word, 'w' = the whole word, 'p' = the start of a word. Longer tokens are tried first and consume the word.
local TOKENS = {
    -- compounds first
    { 'sandwet', 'wet', 1.2, 's' }, { 'wetsand', 'wet', 1.2, 's' }, { 'drysand', 'sand', 1.1, 's' }, { 'sandstone', 'rock', 1.0, 's' },
    { 'darkrock', 'darkrock', 1.2, 's' }, { 'highrock', 'highrock', 1.2, 's' }, { 'icerock', 'highrock', 1.2, 's' }, { 'snowrock', 'highrock', 1.2, 's' },
    { 'lavarock', 'darkrock', 1.1, 's' }, { 'permafrost', 'snow', 1.0, 's' },
    -- grass
    { 'grass', 'grass', 1.0, 's' }, { 'gras', 'grass', 1.0, 's' }, { 'moss', 'grass', 0.8, 's' }, { 'hosta', 'grass', 1.0, 's' }, { 'jungle', 'grass', 0.9, 's' },
    { 'jung', 'grass', 0.8, 'p' }, { 'fern', 'grass', 0.7, 's' }, { 'meadow', 'grass', 1.0, 's' }, { 'lawn', 'grass', 1.0, 's' }, { 'turf', 'grass', 1.0, 's' },
    { 'weed', 'grass', 0.6, 's' }, { 'shrub', 'grass', 0.5, 's' }, { 'bush', 'grass', 0.5, 'w' }, { 'leaf', 'grass', 0.5, 'w' }, { 'leaves', 'grass', 0.6, 'w' },
    { 'veget', 'grass', 0.9, 'p' }, { 'foliage', 'grass', 0.8, 's' }, { 'sphagnum', 'grass', 0.7, 's' }, { 'clover', 'grass', 1.0, 's' }, { 'forest', 'grass', 0.6, 'w' },
    { 'pasture', 'grass', 1.0, 's' }, { 'green', 'grass', 0.7, 'w' }, { 'heather', 'grass', 0.8, 's' },
    -- sand
    { 'sand', 'sand', 1.0, 's' }, { 'dune', 'sand', 1.0, 's' }, { 'desert', 'sand', 0.9, 's' }, { 'beach', 'sand', 1.0, 's' }, { 'dust', 'sand', 0.6, 's' },
    { 'silt', 'sand', 0.5, 's' }, { 'arid', 'sand', 0.7, 's' }, { 'coast', 'sand', 0.6, 's' },
    -- dirt
    { 'dirt', 'dirt', 1.0, 's' }, { 'mud', 'dirt', 1.0, 's' }, { 'soil', 'dirt', 1.0, 's' }, { 'earth', 'dirt', 0.6, 'w' }, { 'ground', 'dirt', 0.8, 's' },
    { 'gravel', 'dirt', 0.9, 's' }, { 'gravil', 'dirt', 0.9, 's' }, { 'pebble', 'dirt', 0.8, 's' }, { 'clay', 'dirt', 0.9, 's' }, { 'path', 'dirt', 0.6, 'w' },
    { 'trail', 'dirt', 0.6, 'w' }, { 'road', 'dirt', 0.5, 'w' }, { 'loam', 'dirt', 1.0, 's' }, { 'rubble', 'dirt', 0.7, 's' }, { 'hardpan', 'dirt', 0.9, 's' },
    { 'crack', 'dirt', 0.4, 'p' },
    -- rock
    { 'rock', 'rock', 1.0, 's' }, { 'cliff', 'rock', 1.0, 's' }, { 'stone', 'rock', 0.9, 's' }, { 'granite', 'rock', 1.0, 's' }, { 'boulder', 'rock', 1.0, 's' },
    { 'basalt', 'rock', 0.9, 's' }, { 'slate', 'rock', 0.8, 's' }, { 'crag', 'rock', 0.9, 's' }, { 'cobble', 'rock', 0.7, 's' }, { 'shale', 'rock', 0.8, 's' },
    { 'limestone', 'rock', 1.0, 's' }, { 'strata', 'rock', 0.5, 'p' },
    -- wet ground
    { 'wet', 'wet', 0.9, 'w' }, { 'water', 'wet', 0.9, 's' }, { 'melt', 'wet', 0.8, 's' }, { 'lava', 'wet', 0.8, 's' }, { 'swamp', 'wet', 0.7, 's' }, { 'bog', 'wet', 0.8, 'w' },
    { 'marsh', 'wet', 0.8, 's' }, { 'puddle', 'wet', 1.0, 's' }, { 'river', 'wet', 0.6, 's' }, { 'damp', 'wet', 0.9, 's' }, { 'slime', 'wet', 0.6, 's' },
    { 'algae', 'wet', 0.6, 's' }, { 'lake', 'wet', 0.6, 'w' }, { 'ooze', 'wet', 0.7, 's' },
    -- high rock
    { 'peak', 'highrock', 0.8, 'w' }, { 'alpine', 'highrock', 0.7, 's' }, { 'summit', 'highrock', 0.8, 's' }, { 'mountain', 'highrock', 0.6, 's' }, { 'mount', 'highrock', 0.6, 'w' },
    -- dark rock
    { 'obsidian', 'darkrock', 1.0, 's' }, { 'ash', 'darkrock', 0.8, 'w' }, { 'ashes', 'darkrock', 0.8, 'w' }, { 'coal', 'darkrock', 0.9, 's' }, { 'soot', 'darkrock', 0.9, 's' },
    { 'cinder', 'darkrock', 0.9, 's' }, { 'burnt', 'darkrock', 0.8, 's' }, { 'scorch', 'darkrock', 0.8, 's' }, { 'volcan', 'darkrock', 0.8, 'p' }, { 'magma', 'darkrock', 0.6, 's' },
    -- snow
    { 'snow', 'snow', 1.0, 's' }, { 'ice', 'snow', 1.0, 'w' }, { 'frost', 'snow', 1.0, 's' }, { 'glacier', 'snow', 1.0, 's' }, { 'frozen', 'snow', 1.0, 's' }, { 'white', 'snow', 0.6, 'w' },
    { 'arctic', 'snow', 0.7, 's' },
}

local DARK_WORDS = { dark = true, dk = true, black = true, blk = true, dim = true, shadow = true }
local LIGHT_WORDS = { light = true, lt = true, pale = true, bright = true, high = true, top = true, white = true }

--- The words of a file name, lower case: case changes, digits and punctuation separate them.
function Words(name)
    local words, cur, prevLower = {}, '', false
    for i = 1, string.len(name) do
        local ch = string.sub(name, i, i)
        local up = (ch >= 'A' and ch <= 'Z')
        local lo = (ch >= 'a' and ch <= 'z')
        if up or lo then
            if up and prevLower and cur ~= '' then
                table.insert(words, string.lower(cur))
                cur = ''
            end
            cur = cur .. ch
            prevLower = lo
        else
            if cur ~= '' then table.insert(words, string.lower(cur)) end
            cur = ''
            prevLower = false
        end
    end
    if cur ~= '' then table.insert(words, string.lower(cur)) end
    return words
end

local sortedTokens = false

local function Tokens()
    if sortedTokens then return sortedTokens end
    sortedTokens = {}
    for i, t in TOKENS do sortedTokens[i] = { string.lower(t[1]), t[2], t[3], t[4], i } end
    table.sort(sortedTokens, function(a, b)
        local la, lb = string.len(a[1]), string.len(b[1])
        if la ~= lb then return la > lb end
        return a[5] < b[5]
    end)
    return sortedTokens
end

local function WordHas(word, tok, mode)
    if mode == 'w' then return word == tok end
    if mode == 'p' then return string.sub(word, 1, string.len(tok)) == tok end
    return string.find(word, tok, 1, true) ~= nil
end

--- The kind of ground a file name says: role, confidence 0..1, scores (role -> sum of token weights), family (the answer is a kind of rock), modified (a dark / light word decided which).
--- nil, 0 when no token matches.
function ClassifyName(path)
    local base = string.gsub(tostring(path or ''), '^.*[/\\]', '')
    base = string.gsub(base, '%.[%w]+$', '')                    -- the extension
    base = string.gsub(base, '_?[aA][lL][bB][eE][dD][oO]$', '') -- _albedo
    local words = Words(base)
    local nwords = table.getn(words)
    local scores, used, hit = {}, {}, {}
    for _, t in Tokens() do
        for wi = 1, nwords do
            if not used[wi] and not hit[t[1]] and WordHas(words[wi], t[1], t[4]) then
                local w = t[3]
                if wi == nwords or (wi == nwords - 1 and words[nwords] and string.len(words[nwords]) <= 3) then w = w + 0.15 end      -- the noun of a compound comes last
                scores[t[2]] = (scores[t[2]] or 0) + w
                hit[t[1]] = true
                if string.len(t[1]) >= 4 or t[4] == 'w' then used[wi] = true end
            end
        end
    end
    local dark, light = false, false
    for _, w in words do
        if DARK_WORDS[w] then dark = true end
        if LIGHT_WORDS[w] then light = true end
    end
    -- ice + rock is a pale rock, not snow
    if (scores.snow or 0) >= 0.5 and (scores.rock or 0) >= 0.5 then
        scores.highrock = (scores.highrock or 0) + scores.snow + scores.rock - 0.3
        scores.snow, scores.rock = nil, nil
    end
    local top, second, role = 0, 0, nil
    for r, s in scores do
        if s > top then second, top, role = top, s, r
        elseif s > second then second = s end
    end
    if not role then return nil, 0, scores, false, false end
    local modified = false
    if RockFamily[role] then
        if dark and not light then role, modified = 'darkrock', true
        elseif light and not dark then role, modified = 'highrock', true end
    end
    local conf = math.min(0.95, 0.45 + 0.5 * math.min(1, top))
    if second > 0.5 * top then conf = conf * 0.6 end
    return role, conf, scores, RockFamily[role] and not modified and role == 'rock', modified
end

-- ---- colours ------------------------------------------------------------------------------------------------------------------------------------------

local function Ramp(x, a, b)
    if x <= a then return 0 end
    if x >= b then return 1 end
    return (x - a) / (b - a)
end

--- 0 below a, rising to 1 at b, 1 up to c, falling to 0 at d.
local function Band(x, a, b, c, d)
    return math.min(Ramp(x, a, b), 1 - Ramp(x, c, d))
end

--- hue (degrees), saturation, value of a colour with channels 0..1.
function HSV(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0.0001 then
        if mx == r then h = 60 * (g - b) / d
        elseif mx == g then h = 60 * (2 + (b - r) / d)
        else h = 60 * (4 + (r - g) / d) end
        if h < 0 then h = h + 360 end
    end
    return h, (mx > 0.0001) and (d / mx) or 0, mx
end

--- The colour statistics of a reduced texture: mean r g b (0..1), hue / saturation / value of the mean, green dominance (g - max(r, b)), warmth (r - b), contrast (the spread of the
--- brightness relative to its mean). px = w * h * 4 numbers 0..255, R G B A per pixel; nil when there is no pixel.
function Features(px, w, h)
    local n = (w or 0) * (h or 0)
    if not px or n < 1 then return nil end
    local sr, sg, sb, sl, sl2 = 0, 0, 0, 0, 0
    for i = 0, n - 1 do
        local r, g, b = (px[i * 4 + 1] or 0) / 255, (px[i * 4 + 2] or 0) / 255, (px[i * 4 + 3] or 0) / 255
        sr, sg, sb = sr + r, sg + g, sb + b
        local l = 0.299 * r + 0.587 * g + 0.114 * b
        sl, sl2 = sl + l, sl2 + l * l
    end
    local r, g, b = sr / n, sg / n, sb / n
    local ml = sl / n
    local sd = math.sqrt(math.max(0, sl2 / n - ml * ml))
    local hue, sat, val = HSV(r, g, b)
    return { r = r, g = g, b = b, hue = hue, sat = sat, val = val, lum = ml, gdom = g - math.max(r, b), warm = r - b, contrast = sd / (ml + 0.05) }
end

--- Scores 0..1 for every role from the features, the best role and its confidence (the score, less when the runner up is close). nil, 0 below MIN_CONF.
function ClassifyColour(f)
    if not f then return nil, 0, {} end
    local s, sat, val, hue = {}, f.sat, f.val, f.hue
    local white = Ramp(val, 0.70, 0.86) * (1 - Ramp(sat, 0.10, 0.26))
    local icy = Ramp(val, 0.60, 0.78) * Band(hue, 165, 190, 250, 275) * Ramp(sat, 0.05, 0.12) * (1 - Ramp(sat, 0.30, 0.45))
    s.snow = math.max(white, icy * 0.85)
    s.grass = Ramp(f.gdom, 0.0, 0.05) * Band(hue, 58, 72, 150, 175) * Ramp(sat, 0.12, 0.28)
    s.sand = Band(hue, 18, 30, 56, 64) * Band(sat, 0.08, 0.16, 0.50, 0.70) * Ramp(val, 0.42, 0.62) * Ramp(f.warm, 0.0, 0.06)
    s.dirt = Band(hue, 5, 14, 40, 52) * Band(sat, 0.14, 0.24, 0.70, 0.85) * Band(val, 0.16, 0.26, 0.50, 0.66)
    local grey = 1 - Ramp(sat, 0.14, 0.30)
    s.rock = grey * Band(val, 0.22, 0.32, 0.60, 0.74)
    s.highrock = grey * Ramp(val, 0.56, 0.70) * (1 - Ramp(val, 0.80, 0.90))
    s.darkrock = (1 - Ramp(sat, 0.40, 0.60)) * (1 - Ramp(val, 0.20, 0.32))
    s.wet = math.max(Band(hue, 165, 185, 265, 285) * Ramp(sat, 0.08, 0.18) * (1 - Ramp(val, 0.42, 0.58)),
                     Band(hue, 10, 20, 50, 60) * Ramp(sat, 0.35, 0.50) * (1 - Ramp(val, 0.20, 0.30)) * 0.8)
    local top, second, role = 0, 0, nil
    for r, v in s do
        if v > top then second, top, role = top, v, r
        elseif v > second then second = v end
    end
    if top < MIN_CONF then return nil, 0, s end
    local margin = (top - second) / math.max(top, 0.001)
    return role, math.min(0.95, top * (0.55 + 0.45 * margin)), s
end

-- ---- the decision --------------------------------------------------------------------------------------------------------------------------------------

--- Combines the name's answer with the colour's. Returns role | nil, confidence, source ('name', 'name+colour', 'colour', 'none').
function Decide(nameRole, nconf, nscores, family, modified, colRole, cconf)
    if not nameRole then
        if colRole then return colRole, cconf * 0.85, 'colour' end
        return nil, 0, 'none'
    end
    local role, conf, src = nameRole, nconf, 'name'
    -- a rock by name: the colour says which rock (dark, ordinary, pale) unless the name already did
    if family and colRole and RockFamily[colRole] then
        role, conf, src = colRole, math.min(nconf, 0.5 + 0.5 * cconf), 'name+colour'
    end
    -- sand and grass are the pair that gets mixed up: the colour decides when the name is weak, names both, or the colour is sure
    if (role == 'grass' or role == 'sand') and (colRole == 'grass' or colRole == 'sand') and colRole ~= role then
        local both = (nscores.grass or 0) > 0 and (nscores.sand or 0) > 0
        if nconf < 0.8 or both or (cconf > 0.8 and nconf < 0.9) then
            role, conf, src = colRole, cconf * 0.85, 'name+colour'
        else
            conf = conf * 0.7
        end
    elseif nconf < 0.6 and colRole and colRole ~= role and cconf > nconf then
        role, conf, src = colRole, cconf * 0.85, 'name+colour'
    end
    return role, conf, src
end

-- ---- reading a texture ----------------------------------------------------------------------------------------------------------------------------------

local function Key(path)
    return string.lower(string.gsub(tostring(path or ''), '\\', '/'))
end

--- The 16 x 16 reduction of a DDS (game data or disk) as pixels; nil, true when this build has no natives (not cached), nil when the file cannot be read.
local function ReadSmall(path)
    if not (rawget(_G, 'ed_dds_thumb') and rawget(_G, 'ed_dds_read')) then return nil, true end
    local src = path
    if rawget(_G, 'ed_vfs_to_disk') then src = ed_vfs_to_disk(path) or path end
    local ok, scratch = pcall(function() return import('/lua/editor/userdata.lua').Path('roledetect_scratch.dds') end)
    if not ok or not scratch then return nil, true end
    local ok2, w = pcall(ed_dds_thumb, src, scratch, THUMB, 1)
    if not ok2 or type(w) ~= 'number' or w < 1 then return nil end
    local ok3, px, tw, th = pcall(ed_dds_read, scratch)
    if not ok3 or not px then return nil end
    return px, tw, th
end

--- The colour answer for a texture: { feat, role, conf, scores } or false (unreadable). Cached per path.
function Colour(path)
    local k = Key(path)
    local fake = Fake and Fake.pixels and Fake.pixels[path]
    if fake then
        local feat = Features(fake[1], fake[2], fake[3])
        local role, conf, scores = ClassifyColour(feat)
        return { feat = feat, role = role, conf = conf, scores = scores }
    end
    local c = colourCache[k]
    if c ~= nil then return c end
    local px, tw, th = ReadSmall(path)
    if not px then
        if tw == true then return false end          -- no natives: ask again later
        colourCache[k] = false
        return false
    end
    local feat = Features(px, tw, th)
    local role, conf, scores = ClassifyColour(feat)
    c = { feat = feat, role = role, conf = conf, scores = scores }
    colourCache[k] = c
    return c
end

function Forget()
    colourCache = {}
end

--- What a texture is: { role, conf, source, name = { role, conf }, colour = { role, conf }, feat }. role nil when nothing is known (confidence below MIN_CONF).
function Classify(path)
    local nrole, nconf, nscores, family, modified = ClassifyName(path)
    local col = Colour(path)
    local crole, cconf = nil, 0
    if col then crole, cconf = col.role, col.conf end
    local role, conf, src = Decide(nrole, nconf, nscores, family, modified, crole, cconf)
    if role and conf < MIN_CONF then role, src = nil, 'none' end
    return { role = role, conf = conf, source = src, name = { role = nrole, conf = nconf }, colour = { role = crole, conf = cconf }, feat = col and col.feat or nil }
end

-- ---- the user's choices ------------------------------------------------------------------------------------------------------------------------------------

local function LoadOverrides()
    if Overrides then return Overrides end
    Overrides = {}
    local ok, saved = pcall(function() return import('/lua/editor/userdata.lua').Get('recipe_roles', false) end)
    if ok and type(saved) == 'table' then
        for k, v in saved do
            if type(k) == 'string' and (RoleLabels[v] or v == 'none') then Overrides[k] = v end
        end
    end
    return Overrides
end

function Override(path)
    return LoadOverrides()[Key(path)]
end

--- The user's choice for a texture (a path, or a layer number): a role, 'none' (do not use this texture), or nil (go back to the detected role).
function SetOverride(target, role)
    local path = target
    if type(target) == 'number' then path = Albedo(target) end
    if not path then return false end
    local o = LoadOverrides()
    if role ~= nil and role ~= 'none' and not RoleLabels[role] then return false end
    o[Key(path)] = role
    pcall(function()
        local copy = {}
        for k, v in o do copy[k] = v end
        import('/lua/editor/userdata.lua').Set('recipe_roles', copy)
    end)
    return true
end

function ClearOverrides()
    Overrides = {}
    pcall(function() import('/lua/editor/userdata.lua').Set('recipe_roles', {}) end)
end

-- ---- the layers of the map ---------------------------------------------------------------------------------------------------------------------------------------

--- The albedo path of layer 0..9, nil when the layer is empty (no texture, or the transparent placeholder).
function Albedo(layer)
    local a
    if Fake and Fake.albedo then
        a = Fake.albedo[layer]
    elseif rawget(_G, 'ed_stratum_layer') then
        a = ed_stratum_layer(layer)
    end
    if not a or a == '' then return nil end
    if string.find(string.lower(a), 'clear_albedo', 1, true) then return nil end
    return a
end

--- The kind of ground of every layer 0..cap that has a texture: a table by layer number, each { layer, albedo, short, role (nil = unknown or not used), conf, source, auto (the detected role),
--- override, usable }.
function Layers(cap)
    local out = {}
    for l = 0, cap or 8 do
        local a = Albedo(l)
        if a then
            local c = Classify(a)
            local ov = Override(a)
            local e = { layer = l, albedo = a, short = string.gsub(string.gsub(a, '^.*[/\\]', ''), '[_]?[aA][lL][bB][eE][dD][oO]%.[dD][dD][sS]$', ''),
                        auto = c.role, autoConf = c.conf, source = c.source, override = ov, nameRole = c.name.role, colourRole = c.colour.role }
            if ov == 'none' then
                e.role, e.conf, e.source = nil, 1, 'user'
            elseif ov then
                e.role, e.conf, e.source = ov, 1, 'user'
            else
                e.role, e.conf = c.role, c.conf
            end
            e.usable = e.role ~= nil
            out[l] = e
        end
    end
    return out
end
