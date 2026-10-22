-- Converts the texture layers of the open map to the format of another terrain shader (Layers panel / shader browser > Convert layers...; dialog: gui/convertdialog.lua).
--
-- What differs between the shaders (shaders.lua Profile): how a paint mask byte is read ('half' = saturate(2m - 1), 'full' = the byte), how many painted layers the shader blends (TTerrain 4, TTerrainXP 8, the
-- numbered ones 7), what layer 8 is (a painted layer; the roughness multiplier mask of the 1xx / 2xx shaders; map-wide data in its textures), what the Upper layer is (an overlay, a specular texture, a
-- roughness / height atlas) and what the alpha of the albedo textures means. Convert does the part that is about masks and layer slots, with the native field engine on the raw mask bytes (no loop in Lua),
-- and reports the rest as not done (it would need other texture files).
--
--   Plan(targetId) -> plan     what a conversion to that shader would do: plan.refused (a message) | plan.lines (done), plan.warnings (not done / check), plan.extra (layers the target cannot paint),
--                              plan.canMove, plan.default ('move' | 'merge' | 'drop'), plan.upperAction ('atlas' | 'clear' | nil), plan.atlasMissing
--   Run(plan, opts) -> report | nil, message       opts: layer8 = 'move' | 'merge' | 'drop' (for the layers the target cannot paint), mergeInto = layer 1..7, upper = true (replace the Upper layer
--                              as plan.upperAction says). ONE undo step. report = { lines = { { kind = 'done' | 'warn', text }, ... }, cells = n, status = 'one line' }
--   ATLAS                      the neutral roughness / height atlas the editor puts on the Upper layer of the 1xx / 2xx shaders (editor/tools/gen_layer_textures.py writes it)
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Shaders = import('/lua/editor/shaders.lua')
local Strata = import('/lua/editor/strata.lua')

ATLAS = '/textures/editor/layers/pbr_atlas_neutral.dds'

local RANGE_NAME = { half = 'half range', full = 'full range' }

local function Textured(i)
    local albedo = ed_stratum_layer(i)
    return albedo ~= nil and albedo ~= '' and albedo ~= Strata.CLEAR
end

local function Basename(path)
    return (string.gsub(path or '', '^.*/', ''))
end

--- Whether raw mask bytes up to `max` hold paint for a shader that reads them in `range` (half range: bytes up to 127 mean nothing).
local function HasPaint(max, range)
    if range == 'half' then return max > 127 end
    return max > 0
end

--- What a layer slot (1..8) is for a profile: 'paint' (blended with its mask), 'rough' / 'data' (layer 8 only) or 'none' (not drawn).
local function RoleOf(p, slot)
    if slot < 8 then return (slot <= p.painted) and 'paint' or 'none' end
    if p.painted >= 8 then return 'paint' end
    return p.l8
end

--- Layers as text, runs joined: "layer 3", "layers 5 and 8", "layers 1-7", "layers 1-3, 5 and 8".
local function LayerList(list)
    local n = table.getn(list)
    if n == 1 then return 'layer ' .. list[1] end
    local parts = {}
    local i = 1
    while i <= n do
        local j = i
        while j < n and list[j + 1] == list[j] + 1 do j = j + 1 end
        if j - i >= 2 then table.insert(parts, list[i] .. '-' .. list[j])
        else
            for k = i, j do table.insert(parts, tostring(list[k])) end
        end
        i = j + 1
    end
    local text = ''
    local m = table.getn(parts)
    for k, part in parts do
        if k == m and m > 1 then text = text .. ' and ' .. part elseif k > 1 then text = text .. ', ' .. part else text = part end
    end
    return 'layers ' .. text
end

-- ---- the plan ------------------------------------------------------------------------------------------------------------------------------------

function Plan(targetId)
    local fromId = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or nil
    local plan = { from = fromId, to = targetId, lines = {}, warnings = {}, extra = {}, layers = {}, default = 'drop' }
    if not fromId or not rawget(_G, 'ed_stratum_info') or not ed_stratum_info() or not Fields.IsAvailable() then
        plan.refused = 'the map has no paint masks'
        return plan
    end
    if fromId == targetId then
        plan.refused = 'the map already uses ' .. tostring(targetId)
        return plan
    end
    local from, to = Shaders.Profile(fromId), Shaders.Profile(targetId)
    plan.fromP, plan.toP = from, to
    if not from.supported then
        plan.refused = 'the layers of ' .. fromId .. ' cannot be converted: ' .. tostring(from.reason)
        return plan
    end
    if not to.supported then
        plan.refused = 'the layers cannot be converted to ' .. targetId .. ': ' .. tostring(to.reason)
        return plan
    end
    local function Line(text) table.insert(plan.lines, text) end
    local function Warn(text) table.insert(plan.warnings, text) end

    -- what the masks hold
    local K = to.painted
    local okScan, scanErr = pcall(function()
        Fields.Run(function(S)
            for l = 1, 8 do
                local f = S:Stratum(l, true)
                local mn, mx = Fields.Stats(f)
                local role = RoleOf(from, l)
                plan.layers[l] = { min = mn, max = mx, role = role, textured = Textured(l) }
                plan.layers[l].painted = (role == 'paint') and HasPaint(mx, from.range)
                -- paint in a mask the source shader does not draw (it shows when the target paints that layer)
                plan.layers[l].hidden = (role == 'none' or role == 'data') and HasPaint(mx, from.range)
            end
        end)
    end)
    if not okScan then
        plan.refused = 'cannot read the paint masks: ' .. tostring(scanErr)
        return plan
    end
    local usedCount = 0
    for l = 1, 8 do
        if plan.layers[l].painted then usedCount = usedCount + 1 end
    end
    plan.used = usedCount
    for l = K + 1, 8 do
        if plan.layers[l].painted then table.insert(plan.extra, l) end
    end
    plan.canMove = usedCount <= K
    if table.getn(plan.extra) > 0 then
        plan.default = plan.canMove and 'move' or 'merge'
    end

    Line(fromId .. ' -> ' .. targetId .. '.')
    -- masks
    if from.range ~= to.range then
        Line('Mask bytes are re-encoded from the ' .. RANGE_NAME[from.range] .. ' to the ' .. RANGE_NAME[to.range] .. ', so the picture stays the same' ..
             (to.range == 'half' and ' (the full range has 255 steps, the half range 128: the masks lose one bit).' or '.'))
    else
        Line('Both shaders read masks in the ' .. RANGE_NAME[from.range] .. ': the bytes stay as they are.')
    end
    if to.l8 == 'rough' and from.l8 ~= 'rough' then
        Line('The mask of layer 8 becomes the roughness multiplier and is set to 128 (neutral) everywhere.')
    elseif from.l8 == 'rough' and to.l8 ~= 'rough' then
        local l8 = plan.layers[8]
        Line('The roughness multiplier of layer 8 is cleared' .. ((l8.min ~= 128 or l8.max ~= 128) and ' (it was not neutral: the roughness variation is lost).' or '.'))
        if l8.min ~= 128 or l8.max ~= 128 then Warn('The mask of layer 8 held a roughness variation (not all 128). It is cleared; the new shader has no use for it.') end
    end
    -- hidden paint that becomes visible
    local hidden = {}
    for l = 1, 8 do
        if plan.layers[l].hidden and RoleOf(to, l) == 'paint' then table.insert(hidden, l) end
    end
    if table.getn(hidden) > 0 then
        Warn('Paint on ' .. LayerList(hidden) .. ' was not drawn by ' .. fromId .. ' and is now visible. Use Clear in the Layers panel to remove it.')
    end
    -- layers the target cannot paint
    local fewer = {}
    for l = K + 1, 8 do
        if RoleOf(from, l) == 'paint' and plan.layers[l].textured and not plan.layers[l].painted then table.insert(fewer, l) end
    end
    if table.getn(plan.extra) > 0 then
        Line(targetId .. ' paints only layers 1-' .. K .. '. ' .. string.upper(string.sub(LayerList(plan.extra), 1, 1)) .. string.sub(LayerList(plan.extra), 2) ..
             (table.getn(plan.extra) > 1 and ' have' or ' has') .. ' paint: choose what happens to it.')
    end
    if table.getn(fewer) > 0 and to.painted < 8 then
        Warn('The textures of ' .. LayerList(fewer) .. ' have no paint and are not drawn by ' .. targetId .. '; they stay in their slots.')
    end
    -- the Upper layer
    local upperNow = ed_stratum_layer(9)
    local function UpperClear() return not upperNow or upperNow == '' or upperNow == Strata.CLEAR end
    if from.upper ~= to.upper then
        if to.upper == 'atlas' then
            if upperNow ~= ATLAS then
                plan.upperAction = 'atlas'
                plan.atlasMissing = not DiskGetFileInfo(ATLAS)
                if plan.atlasMissing then
                    Warn('The Upper layer has to be a roughness / height atlas for ' .. targetId .. ', but the editor\'s neutral atlas is missing (run: python scripts/studio.py generate). Without it the roughness looks wrong.')
                end
            end
        elseif from.upper == 'atlas' or from.upper == 'specular' then
            if not UpperClear() then plan.upperAction = 'clear' end
        end
        if to.upper == 'specular' then
            Warn('The Upper layer of ' .. targetId .. ' is a specular texture (RGB = specular colour, alpha = sharpness). Yours is ' .. (UpperClear() and 'empty' or ('an overlay (' .. Basename(upperNow) .. ')')) .. ': set one by hand.')
        end
    end
    if plan.upperAction == 'atlas' then
        Line('The Upper layer (' .. (UpperClear() and 'empty' or Basename(upperNow)) .. ') is replaced by a neutral roughness / height atlas' .. (plan.atlasMissing and ' (missing, see below)' or '') .. '.')
    elseif plan.upperAction == 'clear' then
        Line('The Upper layer (' .. Basename(upperNow) .. ') is replaced by a transparent texture: ' .. targetId .. ' would draw it as ' .. (to.upper == 'specular' and 'a specular texture' or 'an overlay') .. '.')
    end
    -- what the editor cannot do
    if from.alpha ~= to.alpha then
        if (from.alpha == 'matte' and to.alpha == 'spec') or (from.alpha == 'spec' and to.alpha == 'matte') then
            Warn('Not done: the albedo alpha means the opposite in these shaders (TTerrain: specular amount = 1 - alpha; TTerrainXP and the 0xx: alpha = specularity). The texture files are not changed; shiny and dull ground swap.')
        elseif to.alpha == 'unused' then
            Warn('Not done: ' .. targetId .. ' ignores the albedo alpha of the layers (roughness comes from the Upper layer). The texture files are not changed.')
        elseif from.alpha == 'unused' then
            Warn('Not done: ' .. targetId .. ' reads the albedo alpha as specularity, and the textures were made for a shader that ignores it. Check how shiny the layers look.')
        elseif from.alpha == 'glow' or to.alpha == 'glow' then
            Warn('Not done: the alpha of layer 1 is a glow mask in TTerrainGlow only. The texture files are not changed.')
        end
    end
    if to.upper == 'atlas' then
        Warn('Not done: the roughness and heights of the layers come from the Upper atlas, one tile per layer. The neutral atlas gives every layer the same roughness' ..
             (string.find(targetId, '^Terrain2') and ' and no height variation, so the 2xx splatting blends by opacity only' or '') .. '; paint a real atlas for a finished map.')
    end
    if to.l8 ~= 'paint' and to.l8 ~= 'none' and (string.find(targetId, 'B$') or targetId == 'Terrain001' or targetId == 'Terrain051') and plan.layers[8].textured then
        Warn(targetId .. ' reads the albedo and normal of layer 8 as map-wide data (' .. ((targetId == 'Terrain001' or targetId == 'Terrain051') and 'alpha = baked shadow' or 'R = water depth, terrain normal') ..
             '). Layer 8 keeps ' .. Basename(ed_stratum_layer(8)) .. '; a ground texture there disturbs the shading.')
    end
    Warn('Normal maps are not changed. ' .. targetId .. ' blends them in its own way, so the lighting can differ a little.')
    return plan
end

-- ---- running it -----------------------------------------------------------------------------------------------------------------------------------

local function Recode(S, f, from, to)
    if from == to then return f end
    if from == 'half' then
        -- half -> full: max(0, 2b - 255)
        return S:Op('clamp', { a = S:Op('affine', { a = f, mul = 2, add = -255 }), lo = 0, hi = 255 })
    end
    -- full -> half: (b + 255) / 2, and 0 stays 0
    local lin = S:Op('affine', { a = f, mul = 0.5, add = 127.5 })
    return S:Op('mul', { a = lin, b = S:Op('threshold', { a = f, value = 0 }) })
end

local function ApplyLayers(snaps)
    for i = 0, 9 do
        if snaps[i] and snaps[i].albedo ~= '' then Strata.Restore(snaps[i]) end
    end
end

function Run(plan, opts)
    if not plan or plan.refused then return nil, plan and plan.refused or 'nothing to convert' end
    opts = opts or {}
    local from, to = plan.fromP, plan.toP
    local K = to.painted
    local choice = opts.layer8 or plan.default
    if choice == 'move' and not plan.canMove then choice = 'merge' end
    local report = { lines = {}, cells = 0 }
    local function Add(kind, text) table.insert(report.lines, { kind = kind, text = text }) end
    local ok, why = Shaders.Set(plan.to)
    if not ok then return nil, why end
    local before = {}
    for i = 0, 9 do before[i] = Strata.Snapshot(i) end
    local parts = {}
    local function Undo()
        for i = table.getn(parts), 1, -1 do parts[i].undo() end
        ApplyLayers(before)
        ed_stratum_shader(plan.from)
    end

    -- the arrangement of the layers: perm[j] = the source layer whose paint and textures slot j gets
    local perm = {}
    for j = 1, 8 do perm[j] = j end
    local extra = plan.extra
    local movedTo = {}
    if table.getn(extra) > 0 and choice == 'move' and plan.canMove then
        local used, rest = {}, {}
        for l = 1, 8 do
            if plan.layers[l].painted then table.insert(used, l) else table.insert(rest, l) end
        end
        local n = 0
        for _, l in used do n = n + 1 perm[n] = l end
        for _, l in rest do n = n + 1 perm[n] = l end
        for j = 1, 8 do
            if perm[j] ~= j and plan.layers[perm[j]].painted then table.insert(movedTo, { from = perm[j], to = j }) end
        end
    end

    local failed
    local okRun, err = pcall(function()
        -- textures first (a texture in slot 5..8 makes SetTexture switch TTerrain to TTerrainXP; the shader is set again at the end)
        local texMoved = 0
        for j = 1, 8 do
            if perm[j] ~= j then
                local snap = before[perm[j]]
                if snap.albedo ~= '' then
                    Strata.SetTexture(j, snap.albedo, snap.normal, snap.size, snap.nsize)
                    texMoved = texMoved + 1
                end
            end
        end
        if texMoved > 0 then
            for _, m in movedTo do
                Add('done', 'Paint and textures of layer ' .. m.from .. ' moved to layer ' .. m.to .. ' (' .. Basename(before[m.from].albedo) .. ').')
            end
        end
        if opts.upper and plan.upperAction == 'atlas' and not plan.atlasMissing then
            local w = ed_terrain_info()
            local size = 2 * ((w or 512) - 1)          -- a tile size above the map size: the shader reads a tile value below 1 as "PBR rendering" (decals follow it)
            Strata.SetTexture(9, ATLAS, Strata.NONE_NORMAL, size, size)
            Add('done', 'Upper layer: ' .. Basename(before[9].albedo) .. ' replaced by the neutral roughness / height atlas (tile size ' .. size .. ').')
        elseif opts.upper and plan.upperAction == 'clear' then
            if Strata.Clear(9) then
                Add('done', 'Upper layer: ' .. Basename(before[9].albedo) .. ' replaced by a transparent texture.')
            else
                Add('warn', 'Upper layer: ' .. Basename(before[9].albedo) .. ' could not be replaced (the transparent texture is missing, run: python scripts/studio.py generate).')
            end
        elseif plan.upperAction and not opts.upper then
            Add('warn', 'Upper layer left as it is (' .. Basename(before[9].albedo) .. '): ' .. plan.to .. ' reads it as ' .. (to.upper == 'atlas' and 'a roughness / height atlas' or (to.upper == 'specular' and 'a specular texture' or 'an overlay')) .. '.')
        end

        -- the masks
        Fields.Run(function(S)
            local raw = {}
            for l = 1, 8 do raw[l] = S:Stratum(l, true) end
            local zero = S:Op('const', { like = raw[1], value = 0 })
            local neutral = S:Op('const', { like = raw[1], value = 128 })
            local fin = {}
            for j = 1, 8 do fin[j] = raw[perm[j]] end
            -- layers the target cannot paint
            if table.getn(extra) > 0 then
                if choice == 'merge' then
                    local k = math.max(1, math.min(K, math.floor(opts.mergeInto or K)))
                    for _, e in extra do
                        fin[k] = S:Op('max', { a = fin[k], b = raw[e] })
                        fin[e] = zero
                        Add('done', 'Paint of layer ' .. e .. ' merged into layer ' .. k .. ': it shows ' .. Basename(before[k].albedo) .. ' there now.')
                    end
                elseif choice == 'drop' then
                    for _, e in extra do
                        fin[e] = zero
                        Add('warn', 'Paint of layer ' .. e .. ' (' .. Basename(before[e].albedo) .. ') dropped.')
                    end
                end
            end
            -- the slots after the arrangement
            local recoded = {}
            for j = 1, 8 do
                local role = RoleOf(to, j)
                if role == 'paint' then
                    if j == 8 and from.l8 == 'rough' then
                        fin[j] = zero
                    elseif from.range ~= to.range and fin[j] ~= zero then
                        fin[j] = Recode(S, fin[j], from.range, to.range)
                        recoded[j] = true
                    end
                elseif j == 8 and role == 'rough' then
                    if from.l8 ~= 'rough' then fin[j] = neutral else fin[j] = raw[8] end
                else
                    -- not painted by the target ('data', 'none'): a mask that held paint or roughness is cleared, one that was not used stays
                    local srcRole = RoleOf(from, perm[j])
                    if (srcRole == 'paint' or srcRole == 'rough') and fin[j] ~= zero then fin[j] = zero end
                end
            end
            -- commit what differs
            local recodedCells, recodedLayers = 0, {}
            for j = 1, 8 do
                if fin[j] ~= raw[j] then
                    local entry, n = Fields.CommitMask(fin[j], j, { raw = true, noPush = true, label = 'convert layer ' .. j })
                    if entry then
                        table.insert(parts, entry)
                        report.cells = report.cells + n
                        if recoded[j] then
                            recodedCells = recodedCells + n
                            table.insert(recodedLayers, j)
                        end
                        if j == 8 and to.l8 == 'rough' and from.l8 ~= 'rough' then Add('done', 'Mask of layer 8 set to the neutral roughness multiplier (' .. n .. ' cells).') end
                    end
                end
            end
            if table.getn(recodedLayers) > 0 then
                Add('done', 'Masks of ' .. LayerList(recodedLayers) .. ' re-encoded from the ' .. RANGE_NAME[from.range] .. ' to the ' .. RANGE_NAME[to.range] .. ': ' .. recodedCells .. ' cells changed, the picture stays the same.')
            end
        end)
    end)
    if not okRun then
        failed = tostring(err)
        pcall(Undo)
        return nil, 'converting failed (nothing changed): ' .. failed
    end
    ed_stratum_shader(plan.to)
    if Strata.Active > K then Strata.Active = K end

    local after = {}
    for i = 0, 9 do after[i] = Strata.Snapshot(i) end
    History.Push({
        label = 'convert layers to ' .. plan.to,
        undo = Undo,
        redo = function()
            ApplyLayers(after)
            ed_stratum_shader(plan.to)
            for i = 1, table.getn(parts) do parts[i].redo() end
        end,
        release = function() for _, e in parts do e.release() end end,
    })

    -- the report: the plan's lines that apply, then what was done, then the warnings
    local lines = {}
    table.insert(lines, { kind = 'done', text = 'Shader: ' .. plan.from .. ' -> ' .. plan.to .. '.' })
    for _, l in report.lines do table.insert(lines, l) end
    local nWarn = 0
    for _, w in plan.warnings do
        table.insert(lines, { kind = 'warn', text = w })
    end
    for _, l in lines do
        if l.kind == 'warn' then nWarn = nWarn + 1 end
    end
    report.lines = lines
    report.warnings = nWarn
    report.status = 'converted layers to ' .. plan.to .. ': ' .. report.cells .. ' mask cells changed, ' .. nWarn .. ' notes (one undo step)'
    return report
end
