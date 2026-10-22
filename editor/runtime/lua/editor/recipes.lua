-- Stratum recipes (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T2): a preset says which kinds of ground the map has (grass, dirt, sand, rock, cliff, snow ...), from which slope / height /
-- curvature / water / noise rules each one is made, and in which order they lie on top of each other. Apply fills the paint masks of the texture layers (and, if asked, the terrain-type
-- grid) in one undo step. The rules are the mask generator's (maskgen.lua), so every role is also something you can open there.
--
-- Roles are listed from the bottom up. The first role is the base layer (no mask: it is what is left). The other roles go to texture layers 1..Cap() (Layers[i] = the layer of role i, 0 = skip
-- the role); the layers above take away: the shader lets a higher layer cover a lower one, and the terrain types follow what is seen most in each cell, so a cell gets the type of its
-- visible ground (the default type of the layer's texture, terraintype.lua).
--
-- The shader of the map decides two things (strata.lua Profile / Range): how many layers have a paint mask (TTerrainXP 8; the numbered shaders 7, their 8th mask is the roughness multiplier or unused;
-- TTerrainGlow 4; TTerrain 4 too, but layers 5-8 switch the map to TTerrainXP as before) and how a mask byte is read (half or full range). A role on a layer the shader cannot paint is moved to the highest
-- free layer (or shares the top layer: the masks are merged); the masks are written in the shader's encoding by the field commit (fields.lua), so a recipe looks the same on every shader.
--
--   Presets                       { id, name, uses = { knob names }, roles = function(knobs, stats) -> list of { id, label, keywords, rules } }
--   Knobs, KnobInfo               the settings shared by the presets (cliff / rock angle, snow line, beach width, breakup, patch size, seed)
--   State                         { preset, layers = { [roleIndex] = layer }, types = bool }
--   Roles() -> list               the roles of the current preset with the current knobs
--   Cap()                         the highest layer the shader of the map paints with a mask       FitLayers(layers) -> layers the roles really get       Notes(roles) -> { shaderLine, warnings }
--   AutoLayers(roles)             layer numbers in order (1, 2, 3 ...)      MatchTextures(roles)     layer numbers by the names of the textures the layers hold now
--   PreviewRole(i) -> field       evaluates one role at preview resolution and shows it (maskgen preview)
--   Apply() -> summary | nil, message       writes everything: ONE undo step; the summary lists the share of each role
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local MaskGen = import('/lua/editor/maskgen.lua')
local Strata = import('/lua/editor/strata.lua')

local function Rule(type, values, op, invert)
    local r = MaskGen.NewRule(type)
    for k, x in (values or {}) do r.v[k] = x end
    r.op = op or 'and'
    r.invert = invert or false
    return r
end

Knobs = { cliff = 45, rock = 28, snow = 0.78, beach = 3, breakup = 0.5, patch = 50, seed = 1 }

KnobInfo = {
    { key = 'cliff', label = 'Cliff slope from (degrees)', min = 20, max = 85, step = 1, fmt = '%d' },
    { key = 'rock', label = 'Rock slope from (degrees)', min = 5, max = 80, step = 1, fmt = '%d' },
    { key = 'snow', label = 'Snow line (share of the height range)', min = 0, max = 1, step = 0.01, fmt = '%.2f' },
    { key = 'beach', label = 'Beach half width (units)', min = 0, max = 20, step = 0.5, fmt = '%.1f' },
    { key = 'breakup', label = 'Edge breakup (noise)', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
    { key = 'patch', label = 'Patch size (units)', min = 8, max = 300, step = 2, fmt = '%d' },
    { key = 'seed', label = 'Seed', min = 0, max = 9999, step = 1, fmt = '%d' },
}

--- Noise that breaks a hard edge up: 1 where the noise is high, falling off where it is low; the stronger the knob the more is taken away.
local function Breakup(k, seedAdd, size)
    return Rule('noise', { kind = 1, seed = k.seed + seedAdd, size = size or k.patch, octaves = 4, from = 0.05, to = 0.05 + k.breakup * 0.5 }, 'mul')
end

local function Slope(lo, hi, soft) return Rule('slope', { lo = lo, hi = hi, soft = soft or 5 }) end

local function Role(id, label, keywords, rules) return { id = id, label = label, keywords = keywords, rules = rules } end

local function Beach(k)
    return { Rule('water', { mode = 3, offset = 0.5, width = k.beach, soft = 2 }), Slope(0, 24, 6), Rule('blur', { radius = 1.2 }) }
end

local function Cliff(k)
    return { Slope(k.cliff, 90, 4), Rule('blur', { radius = 1.5 }) }
end

local function Rock(k, seedAdd)
    return { Slope(k.rock, 90, 6), Breakup(k, seedAdd, k.patch * 0.6), Rule('blur', { radius = 1.5 }) }
end

Presets = {
    { id = 'temperate', name = 'Temperate (grass, dirt, sand, rock, cliff)', uses = { 'cliff', 'rock', 'beach', 'breakup', 'patch', 'seed' },
      roles = function(k, st)
        return {
            Role('grass', 'Grass (base)', { 'grass', 'hostas', 'jung' }, {}),
            Role('dirt', 'Dirt patches', { 'dirt', 'mud', 'soil' }, {
                Rule('noise', { kind = 1, seed = k.seed, size = k.patch, octaves = 4, from = 0.5, to = 0.62 }), Slope(0, 30, 8), Rule('blur', { radius = 1.5 }) }),
            Role('sand', 'Sand (shore)', { 'sand' }, Beach(k)),
            Role('rock', 'Rock', { 'rock', 'stone', 'gravel' }, Rock(k, 11)),
            Role('cliff', 'Cliff', { 'cliff' }, Cliff(k)),
        } end },
    { id = 'alpine', name = 'Alpine (grass, rock, snow, cliff)', uses = { 'cliff', 'rock', 'snow', 'breakup', 'patch', 'seed' },
      roles = function(k, st)
        local lo = st.hmin + (st.hmax - st.hmin) * k.snow
        return {
            Role('grass', 'Grass (base)', { 'grass', 'hostas' }, {}),
            Role('dirt', 'Dirt on the slopes', { 'dirt', 'mud', 'soil', 'gravel' }, { Slope(12, k.cliff, 8), Breakup(k, 3, k.patch), Rule('blur', { radius = 2 }) }),
            Role('rock', 'Rock', { 'rock', 'stone' }, Rock(k, 11)),
            Role('snow', 'Snow', { 'snow', 'ice' }, {
                Rule('height', { lo = lo, hi = st.hmax + 100, soft = math.max(1, (st.hmax - st.hmin) * 0.06) }), Slope(0, k.cliff - 4, 8), Breakup(k, 21, k.patch * 0.7), Rule('blur', { radius = 1.5 }) }),
            Role('cliff', 'Cliff', { 'cliff' }, Cliff(k)),
        } end },
    { id = 'desert', name = 'Desert (sand, dust, rock, cliff)', uses = { 'cliff', 'rock', 'beach', 'breakup', 'patch', 'seed' },
      roles = function(k, st)
        return {
            Role('sand', 'Sand (base)', { 'sand' }, {}),
            Role('dust', 'Dust and hardpan', { 'dirt', 'soil', 'gravel', 'mud' }, {
                Rule('noise', { kind = 2, seed = k.seed, size = k.patch, octaves = 4, from = 0.48, to = 0.6 }), Rule('blur', { radius = 1.5 }) }),
            Role('wet', 'Wet sand (shore)', { 'sandwet', 'wet' }, Beach(k)),
            Role('rock', 'Rock', { 'rock', 'stone' }, Rock(k, 7)),
            Role('cliff', 'Cliff', { 'cliff' }, Cliff(k)),
        } end },
    { id = 'arctic', name = 'Arctic (snow, rock, ice, cliff)', uses = { 'cliff', 'rock', 'beach', 'breakup', 'patch', 'seed' },
      roles = function(k, st)
        return {
            Role('snow', 'Snow (base)', { 'snow' }, {}),
            Role('rock', 'Rock', { 'rock', 'stone', 'gravel' }, Rock(k, 5)),
            Role('ice', 'Ice (shore)', { 'ice' }, Beach(k)),
            Role('cliff', 'Cliff', { 'cliff', 'rock' }, Cliff(k)),
        } end },
    { id = 'rocky', name = 'Rocky (rock, gravel, grass pockets, cliff)', uses = { 'cliff', 'rock', 'breakup', 'patch', 'seed' },
      roles = function(k, st)
        return {
            Role('rock', 'Rock (base)', { 'rock', 'stone' }, {}),
            Role('gravel', 'Gravel', { 'gravel', 'dirt' }, { Slope(0, k.rock, 8), Breakup(k, 2, k.patch), Rule('blur', { radius = 2 }) }),
            Role('grass', 'Grass pockets', { 'grass' }, {
                Rule('noise', { kind = 1, seed = k.seed + 9, size = k.patch, octaves = 3, from = 0.55, to = 0.65 }), Slope(0, 14, 6), Rule('blur', { radius = 1.5 }) }),
            Role('cliff', 'Cliff', { 'cliff' }, Cliff(k)),
        } end },
}

State = { preset = 1, layers = {}, types = true, selected = 1 }

local function Stats()
    local lo, hi = 0, 100
    if Fields.IsAvailable() and ed_terrain_info() then
        lo, hi = Fields.Run(function(S)
            local mn, mx = Fields.Stats(S:Height(4))
            return mn, mx
        end)
    end
    return { hmin = lo, hmax = hi }
end

--- The roles of the current preset (rules built from the current knobs).
function Roles()
    local p = Presets[State.preset]
    return p.roles(Knobs, Stats())
end

--- The highest painted layer the shader of the map draws with a mask: 8 for TTerrainXP and for TTerrain (writing layers 5-8 switches it to TTerrainXP, as it always did), 7 for the numbered
--- shaders, 4 for TTerrainGlow. Without a terrain: 8.
function Cap()
    return Strata.PaintCap()
end

--- The layers the roles really get: a role on a layer the shader cannot paint takes the highest free layer it can, or shares the top layer when none is free (Apply merges the masks).
function FitLayers(layers)
    local cap = Cap()
    local fit, used = {}, {}
    for i = 1, table.getn(layers) do
        fit[i] = layers[i] or 0
        if fit[i] >= 1 and fit[i] <= cap then used[fit[i]] = true end
    end
    for i = table.getn(layers), 1, -1 do
        if fit[i] > cap then
            local free
            for k = cap, 1, -1 do
                if not used[k] then free = k break end
            end
            fit[i] = free or cap
            used[fit[i]] = true
        end
    end
    return fit
end

--- What the panel says about the shader: a line (which shader, mask range, painted layers) and the warnings (roles that had to move, a shader nobody described).
function Notes(roles)
    local name = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or '?'
    local p = rawget(_G, 'ed_stratum_shader') and Strata.Profile() or {}
    local cap = Cap()
    local line = 'Shader ' .. tostring(name) .. ': masks in the ' .. (p.range or 'half') .. ' range, ' .. cap .. ' painted layers'
    local warnings = {}
    if p.supported == false and p.reason then
        table.insert(warnings, 'No notes about this shader: masks are written in the half range')
    end
    local want = State.layers or {}
    local fit = FitLayers(want)
    for i, role in roles do
        local w = want[i] or 0
        if w > cap then
            local shared = false
            for j = 1, table.getn(roles) do
                if j ~= i and fit[j] == fit[i] then shared = true end
            end
            table.insert(warnings, role.label .. ': layer ' .. w .. ' is not painted here, ' .. (shared and ('merged into layer ' .. fit[i]) or ('moved to layer ' .. fit[i])))
        end
    end
    return line, warnings
end

--- Role i goes to layer i (the first role is the base layer, 0).
function AutoLayers(roles)
    local layers = {}
    local cap = Cap()
    for i = 1, table.getn(roles) do layers[i] = math.min(cap, i - 1) end
    return layers
end

local function Lower(path) return string.lower(string.gsub(path or '', '^.*/', '')) end

--- Layer numbers by the textures the layers hold: a role takes the first unused layer whose texture name contains one of its keywords; roles without a match take the next free layer
--- (the base role stays on 0).
function MatchTextures(roles)
    local layers, used = {}, { [0] = true }
    layers[1] = 0
    local names = {}
    local cap = Cap()
    for l = 1, cap do
        local albedo = ed_stratum_layer(l)
        names[l] = albedo and Lower(albedo) or ''
    end
    for i = 2, table.getn(roles) do
        for l = 1, cap do
            if not used[l] and names[l] ~= '' then
                for _, key in roles[i].keywords do
                    if string.find(names[l], key, 1, true) then
                        layers[i] = l
                        used[l] = true
                        break
                    end
                end
            end
            if layers[i] then break end
        end
    end
    for i = 2, table.getn(roles) do
        if not layers[i] then
            for l = 1, cap do
                if not used[l] then
                    layers[i] = l
                    used[l] = true
                    break
                end
            end
        end
        layers[i] = layers[i] or 0
    end
    return layers
end

--- Shows role i's mask on the map at preview resolution. Returns the field, or nil and a message.
function PreviewRole(i)
    local roles = Roles()
    local role = roles[i]
    if not role then return nil, 'no such role' end
    if table.getn(role.rules) == 0 then
        return nil, role.label .. ' has no mask: it is what the other roles leave free'
    end
    return MaskGen.PreviewDef({ rules = role.rules })
end

--- Writes all roles: the paint masks of their layers and (State.types) the terrain-type grid. ONE undo step. Returns a summary { { label, share }, ... } or nil, message.
function Apply()
    if not Fields.IsAvailable() or not ed_stratum_info() then return nil, 'the map has no paint masks' end
    local roles = Roles()
    local layerOf = State.layers
    if not layerOf or table.getn(layerOf) ~= table.getn(roles) then
        layerOf = AutoLayers(roles)
        State.layers = layerOf
    end
    layerOf = FitLayers(layerOf)          -- roles on layers the shader cannot paint move to free ones (State.layers keeps the wish)
    local cap = Cap()
    local TT = import('/lua/editor/terraintype.lua')
    return Fields.Run(function(S)
        local c = MaskGen.NewContext(S, { step = 1 })
        -- the mask of every layer a role writes
        local p, owner = {}, {}
        for i, role in roles do
            local layer = layerOf[i]
            if table.getn(role.rules) > 0 and layer >= 1 then
                local m, err = MaskGen.Evaluate(c, { rules = role.rules })
                if not m then return nil, role.label .. ': ' .. tostring(err) end
                if p[layer] then
                    p[layer] = S:Op('max', { a = p[layer], b = m })
                else
                    p[layer] = m
                    owner[layer] = i
                end
            end
        end
        -- masks first (history entries are collected, not pushed)
        local parts = {}
        local cells = 0
        for layer = 1, cap do
            if p[layer] then
                local entry, n = MaskGen.WriteLayer(c, p[layer], layer, { mode = 1, strength = 1, takeAway = false }, true)
                if entry then
                    table.insert(parts, entry)
                    cells = cells + n
                end
            end
        end
        -- shares: what each layer shows after the layers above took theirs
        local rest = S:Op('const', { like = c.H, value = 1 })
        local share = {}
        local covered = {}
        for layer = cap, 1, -1 do
            local m = p[layer]
            if not m then
                local albedo = ed_stratum_layer(layer)
                if albedo and albedo ~= '' and not string.find(albedo, 'clear_albedo', 1, true) then m = S:Op('resample', { a = S:Stratum(layer), like = c.H }) end      -- layers outside the recipe still count
            end
            if m then
                share[layer] = S:Op('mul', { a = m, b = rest })
                rest = S:Op('mul', { a = rest, b = S:Op('invert', { a = m, lo = 0, hi = 1 }) })
            end
        end
        -- terrain types by the layer seen most
        if State.types and rawget(_G, 'ed_tt_info') and ed_tt_info() then
            local best = rest
            local codes = S:Op('const', { like = c.H, value = TT.TypeOfLayer(0) })
            for layer = 1, cap do
                if share[layer] then
                    local win = S:Op('threshold', { a = S:Op('sub', { a = share[layer], b = best }), value = 0 })
                    codes = S:Op('blend', { a = codes, b = S:Op('const', { like = c.H, value = TT.TypeOfLayer(layer) }), mask = win })
                    best = S:Op('max', { a = best, b = share[layer] })
                end
            end
            local entry, n = Fields.CommitTypes(codes, { noPush = true, label = 'recipe terrain types' })
            if entry then
                table.insert(parts, entry)
                cells = cells + n
            end
        end
        if table.getn(parts) == 0 then return nil, 'nothing changed' end
        History.Push({
            label = 'stratum recipe ' .. Presets[State.preset].name,
            undo = function() for i = table.getn(parts), 1, -1 do parts[i].undo() end end,
            redo = function() for i = 1, table.getn(parts) do parts[i].redo() end end,
            release = function() for _, e in parts do e.release() end end,
        })
        local summary = {}
        for i, role in roles do
            local layer = layerOf[i]
            local s = (layer >= 1) and share[layer] or (i == 1 and rest or nil)
            if s and (layer >= 1 or i == 1) then
                local _, _, mean = Fields.Stats(s)
                table.insert(summary, { label = role.label, share = mean, layer = layer })
            end
        end
        return summary, cells
    end)
end
