-- Converts the texture layers of the open map to the format of another terrain shader (Layers panel / shader browser > Convert layers...; dialog: gui/convertdialog.lua).
-- Findings about every shader, with the lines of effects/terrain.fx they come from: docs/projects/editor/LAYER_CONVERSION.md.
--
-- What differs between the shaders (shaders.lua Profile): how a paint mask byte is read ('half' = saturate(2m - 1), 'full' = the byte), how many painted layers the shader blends (TTerrain 4, TTerrainXP 8,
-- the numbered ones 7), what layer 8 is (a painted layer; the roughness multiplier mask of the 1xx / 2xx shaders; map-wide data in its textures), what the Upper layer is (an overlay, a specular texture, a
-- roughness / height atlas), what the alpha of the albedo textures means (specularity, 1 - specularity, ignored, the opacity of the base layer's macrotexture) and the settings the shader takes from
-- the map's lighting (the splat settings of the 2xx in SpecularColor). Convert does all of it:
--   * the paint masks with the native field engine on the raw bytes (no loop in Lua): range recode, layer 8, the arrangement of the layers (the biplanar shaders draw layers 3 and 4 from the side only:
--     the layers painted on steep ground move there);
--   * textures (option "Also convert textures", on by default): new DXT5 files written by the natives ed_tex_convert / ed_tex_atlas (texconv.lua): the albedo alpha made right for the target (inverted,
--     derived from the Upper atlas or a medium value, macrotexture opacity 0), the Upper roughness / height atlas made from the layers' own textures, layer 8's map-wide normal map and water depth
--     (maptextures.lua). Layers point at the new files; the old files are untouched; undo points them back;
--   * the splat settings (SpecularColor) of the lighting for the Terrain2xx shaders, and back.
--
--   Plan(targetId) -> plan     what a conversion to that shader would do: plan.refused (a message) | plan.lines (done), plan.warnings (what needs a look), plan.warningsNoTex (the same when textures are not
--                              converted), plan.extra (layers the target cannot paint), plan.canMove, plan.default ('move' | 'merge' | 'drop'), plan.upperAction ('atlas' | 'clear' | nil), plan.atlasMissing,
--                              plan.tex = { available, any, alpha = 'invert' | 'derive' | nil, baseClear, atlas, light = 'generate' | 'neutral' | nil, normal = 'generate' | nil, lighting = 'enter' | 'fix' | 'leave' | nil }
--   Run(plan, opts) -> report | nil, message       opts: layer8 = 'move' | 'merge' | 'drop' (for the layers the target cannot paint), mergeInto = layer 1..7, upper = true (replace the Upper layer
--                              as plan.upperAction says), textures = false (masks only; default true). ONE undo step.
--                              report = { lines = { { kind = 'done' | 'warn' | 'file', text }, ... }, cells = n, files = n, status = 'one line' }
--   Arrange(plan, choice) -> perm       perm[j] = the source layer whose paint and textures slot j gets (pure: the self test checks it)
--   ATLAS                      the neutral roughness / height atlas (editor/tools/gen_layer_textures.py writes it): used when textures are not converted
--   CLIFF_SLOPE                mean slope (degrees) from which a layer counts as a cliff layer for the biplanar shaders
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Fields = import('/lua/editor/fields.lua')
local History = import('/lua/editor/history.lua')
local Shaders = import('/lua/editor/shaders.lua')
local Strata = import('/lua/editor/strata.lua')
local TexConv = import('/lua/editor/texconv.lua')

ATLAS = '/textures/editor/layers/pbr_atlas_neutral.dds'
CLIFF_SLOPE = 20

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

local function Cap(text)
    return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- ---- the arrangement of the layers ---------------------------------------------------------------------------------------------------------------------

local function SlotOf(perm, layer)
    for j = 1, 8 do
        if perm[j] == layer then return j end
    end
    return nil
end

--- The biplanar (B) shaders texture layers 3 and 4 only from the side (terrain.fx Terrain2xxBAlbedoPS: strata 2 and 3 are sampled with position.xz and position.yz, never with position.xy): a layer there is
--- stretched on flat ground. The two layers painted on the steepest ground (mean slope from CLIFF_SLOPE) swap into slots 3 and 4; a painted layer that is not steep is swapped out of them into a slot
--- whose layer has no paint, when there is one.
local function Cliffs(plan, perm)
    local K = plan.toP.painted
    local cand = {}
    for j = 1, K do
        local info = plan.layers[perm[j]]
        if info.painted and info.slope and info.slope >= CLIFF_SLOPE then
            table.insert(cand, { layer = perm[j], slope = info.slope, slot = j })
        end
    end
    table.sort(cand, function(a, b)
        if a.slope ~= b.slope then return a.slope > b.slope end
        return a.slot < b.slot
    end)
    local placed = {}
    for n = 1, math.min(2, table.getn(cand)) do
        local want = 2 + n
        local at = SlotOf(perm, cand[n].layer)
        if at ~= want then perm[at], perm[want] = perm[want], perm[at] end
        placed[want] = true
    end
    for want = 3, 4 do
        if not placed[want] and plan.layers[perm[want]].painted then
            for _, u in { 5, 6, 7, 1, 2 } do
                if u <= K and not plan.layers[perm[u]].painted then
                    perm[u], perm[want] = perm[want], perm[u]
                    break
                end
            end
        end
    end
end

--- perm[j] = the source layer whose paint and textures slot j gets. choice 'move' puts the layers with paint first (when the target paints fewer layers than the map has painted: plan.canMove),
--- the biplanar shaders then get their cliff layers into slots 3 and 4 (Cliffs).
function Arrange(plan, choice)
    local perm = {}
    for j = 1, 8 do perm[j] = j end
    if table.getn(plan.extra) > 0 and choice == 'move' and plan.canMove then
        local used, rest = {}, {}
        for l = 1, 8 do
            if plan.layers[l].painted then table.insert(used, l) else table.insert(rest, l) end
        end
        local n = 0
        for _, l in used do n = n + 1 perm[n] = l end
        for _, l in rest do n = n + 1 perm[n] = l end
    end
    if plan.toP and plan.fromP and plan.toP.biplanar and not plan.fromP.biplanar then Cliffs(plan, perm) end
    return perm
end

-- ---- the plan ------------------------------------------------------------------------------------------------------------------------------------

--- The mean slope (degrees) under the paint of a raw mask field: sum(mask * slope) / sum(mask). nil for a mask without paint.
local function Weighted(S, raw, slope, range)
    local e
    if range == 'half' then
        e = S:Op('clamp', { a = S:Op('affine', { a = raw, mul = 2 / 255, add = -1 }), lo = 0, hi = 1 })
    else
        e = S:Op('affine', { a = raw, mul = 1 / 255, add = 0 })
    end
    local _, _, meanE = Fields.Stats(e)
    if not meanE or meanE < 0.0005 then return nil end
    local s = S:Op('resample', { a = slope, like = e })
    local _, _, meanP = Fields.Stats(S:Op('mul', { a = e, b = s }))
    return meanP / meanE
end

--- Whether layer slot `index` of ed_stratum_layer (8 = albedo of layer 8, 18 = its normal map) holds a map-wide picture now (a tile size above the map: the shaders only read it then).
local function MapDataActive(index)
    local path, size = ed_stratum_layer(index)
    local w = rawget(_G, 'ed_terrain_info') and ed_terrain_info()
    if not path or path == '' or not w then return false end
    local low = string.lower(path)
    if low == string.lower(Strata.CLEAR) or low == string.lower(Strata.NONE_NORMAL) then return false end
    return (size or 0) > (w - 1)
end

--- The texture work a conversion from profile `from` to `to` needs (see the header). Fills plan.tex and returns it.
local function TexPlan(plan)
    local from, to = plan.fromP, plan.toP
    local t = { available = TexConv.Available() }
    if (from.alpha == 'matte' and to.alpha == 'spec') or (from.alpha == 'spec' and to.alpha == 'matte') then
        t.alpha = 'invert'
    elseif from.alpha == 'unused' and (to.alpha == 'spec' or to.alpha == 'matte') then
        t.alpha = 'derive'
    end
    t.baseClear = (to.baseAlpha == 'opacity' and from.baseAlpha ~= 'opacity' and t.alpha == nil) or false
    t.atlas = plan.upperAction == 'atlas'
    if to.need and to.need.light and not MapDataActive(8) then t.light = to.biplanar and 'generate' or 'neutral' end
    if to.need and to.need.normal and not MapDataActive(18) then t.normal = 'generate' end
    local cls = Shaders.ClassOf
    local curSplat = plan.cur and cls(plan.cur) == 'splat'
    if cls(plan.to) == 'splat' then t.lighting = curSplat and 'fix' or 'enter'
    elseif curSplat then t.lighting = 'leave' end
    t.any = (t.alpha or t.baseClear or t.atlas or t.light or t.normal) and true or false
    plan.tex = t
    return t
end

function Plan(targetId)
    local cur = rawget(_G, 'ed_stratum_shader') and ed_stratum_shader() or nil
    -- after a plain shader switch (Shaders.Set) the masks are still in the range of the shader they were made for (shaders.lua Mismatch): the conversion starts from that shader
    local mis = cur and Shaders.Mismatch() or nil
    local fromId = mis and mis.shader or cur
    local plan = { from = fromId, cur = cur, to = targetId, lines = {}, warnings = {}, warningsNoTex = {}, extra = {}, layers = {}, default = 'drop', tex = { available = false, any = false } }
    if not fromId or not rawget(_G, 'ed_stratum_info') or not ed_stratum_info() or not Fields.IsAvailable() then
        plan.refused = 'the map has no paint masks'
        return plan
    end
    if fromId == targetId then
        plan.refused = mis and ('the paint was made for ' .. tostring(targetId) .. ': use that shader to go back') or ('the map already uses ' .. tostring(targetId))
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
    local function Warn(text) table.insert(plan.warnings, text) table.insert(plan.warningsNoTex, text) end
    local function WarnOn(text) table.insert(plan.warnings, text) end
    local function WarnOff(text) table.insert(plan.warningsNoTex, text) end

    -- what the masks hold
    local K = to.painted
    local wantSlope = to.biplanar and not from.biplanar
    local okScan, scanErr = pcall(function()
        Fields.Run(function(S)
            local slope
            if wantSlope then
                local okS, f = pcall(function() return S:Op('slope', { a = S:Height(1), mode = 'degrees' }) end)
                if okS then slope = f end
            end
            for l = 1, 8 do
                local f = S:Stratum(l, true)
                local mn, mx = Fields.Stats(f)
                local role = RoleOf(from, l)
                plan.layers[l] = { min = mn, max = mx, role = role, textured = Textured(l) }
                plan.layers[l].painted = (role == 'paint') and HasPaint(mx, from.range)
                -- paint in a mask the source shader does not draw (it shows when the target paints that layer)
                plan.layers[l].hidden = (role == 'none' or role == 'data') and HasPaint(mx, from.range)
                if slope and plan.layers[l].painted then
                    local okW, w = pcall(Weighted, S, f, slope, from.range)
                    if okW then plan.layers[l].slope = w end
                end
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

    if mis then
        Line('The paint masks were made for ' .. fromId .. ' (' .. RANGE_NAME[mis.range] .. '); the map\'s shader is now ' .. tostring(cur) .. ', which reads the ' .. RANGE_NAME[mis.now] .. '.')
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
        Line(targetId .. ' paints only layers 1-' .. K .. '. ' .. Cap(LayerList(plan.extra)) ..
             (table.getn(plan.extra) > 1 and ' have' or ' has') .. ' paint: choose what happens to it.')
    end
    if table.getn(fewer) > 0 and to.painted < 8 then
        Warn('The textures of ' .. LayerList(fewer) .. ' have no paint and are not drawn by ' .. targetId .. '; they stay in their slots.')
    end
    -- the Upper layer
    local upperNow = ed_stratum_layer(9)
    local function UpperClear() return not upperNow or upperNow == '' or upperNow == Strata.CLEAR end
    local nativeTex = TexConv.Available()
    if to.upper == 'atlas' then
        -- an atlas of the map's own (a PBR map) stays; the editor's neutral one, an overlay or an empty layer is replaced
        if from.upper ~= 'atlas' or upperNow == ATLAS or UpperClear() then
            plan.upperAction = 'atlas'
            plan.atlasMissing = (not nativeTex) and not DiskGetFileInfo(ATLAS)
            if plan.atlasMissing then
                Warn('The Upper layer has to be a roughness / height atlas for ' .. targetId .. ', but the editor\'s neutral atlas is missing (run: python scripts/studio.py generate). Without it the roughness looks wrong.')
            end
        end
    elseif from.upper ~= to.upper and (from.upper == 'atlas' or from.upper == 'specular') then
        if not UpperClear() then plan.upperAction = 'clear' end
    end
    if to.upper == 'specular' and from.upper ~= to.upper then
        Warn('The Upper layer of ' .. targetId .. ' is a specular texture (RGB = specular colour, alpha = sharpness). Yours is ' .. (UpperClear() and 'empty' or ('an overlay (' .. Basename(upperNow) .. ')')) .. ': set one by hand.')
    end
    local t = TexPlan(plan)
    local texOn = t.available
    if plan.upperAction == 'atlas' then
        Line('The Upper layer (' .. (UpperClear() and 'empty' or Basename(upperNow)) .. ') is replaced by a roughness / height atlas' ..
             (texOn and ' made from the layer textures (roughness from their alpha, heights from their detail; a new file).' or ' (neutral: every layer alike).'))
    elseif plan.upperAction == 'clear' then
        Line('The Upper layer (' .. Basename(upperNow) .. ') is replaced by a transparent texture: ' .. targetId .. ' would draw it as ' .. (to.upper == 'specular' and 'a specular texture' or 'an overlay') .. '.')
    end

    -- the arrangement of the layers for the biplanar shaders
    if to.biplanar and not from.biplanar then
        local perm = Arrange(plan, plan.default)
        local any = false
        for l = 1, 8 do any = any or plan.layers[l].slope ~= nil end
        Line(targetId .. ' textures layers 3 and 4 only from the side (cliffs), never from above, also on flat ground: a layer painted on gentle ground looks stretched there.')
        if not any then
            Warn('The steepness under the paint could not be measured, so the layers stay where they are. Put cliff textures on layers 3 and 4 and paint them on steep ground only.')
        else
            for s = 3, 4 do
                local l = perm[s]
                local info = plan.layers[l]
                if info.painted and info.slope and info.slope >= CLIFF_SLOPE then
                    Line('Layer ' .. s .. ' (from the side) is ' .. Basename(ed_stratum_layer(l)) .. ', painted on steep ground (mean slope ' .. math.floor(info.slope + 0.5) .. ' degrees)' ..
                         (l ~= s and (': moved from layer ' .. l .. '.') or '.'))
                elseif info.painted then
                    Warn('Layer ' .. s .. ' (' .. Basename(ed_stratum_layer(l)) .. ') is painted on gentle ground' .. (info.slope and (' (mean slope ' .. math.floor(info.slope + 0.5) .. ' degrees)') or '') ..
                         ' but ' .. targetId .. ' draws it only from the side: it looks stretched. Repaint it with a cliff texture on steep ground, or paint your cliff on another layer and swap.')
                end
            end
        end
    end

    -- the texture work and what is not done without it
    if from.alpha ~= to.alpha then
        if t.alpha == 'invert' then
            WarnOff('Not done: the albedo alpha means the opposite in these shaders (TTerrain: specular amount = 1 - alpha; TTerrainXP and the 0xx: alpha = specularity). The texture files are not changed; shiny and dull ground swap.')
            if texOn then Line('Textures: the albedo alpha of the layers is inverted (TTerrain: specular amount = 1 - alpha; TTerrainXP and the 0xx: alpha = specularity). New texture files; the colours are not touched.') end
        elseif t.alpha == 'derive' then
            WarnOff('Not done: ' .. targetId .. ' reads the albedo alpha as specularity, and the textures were made for a shader that ignores it. Check how shiny the layers look.')
            if texOn then Line('Textures: ' .. targetId .. ' reads the albedo alpha as ' .. (to.alpha == 'matte' and '1 - specularity' or 'specularity') .. ', and the textures were made for a shader that ignores it: new texture files get an alpha from the roughness of the Upper atlas (a medium value where there is none).') end
        elseif to.alpha == 'unused' then
            if texOn and (from.alpha == 'spec' or from.alpha == 'matte') and to.upper == 'atlas' then
                Line('The old albedo alpha (specularity) becomes the roughness of the layers in the new Upper atlas; ' .. targetId .. ' itself ignores the alpha of the layers.')
            else
                WarnOff('Not done: ' .. targetId .. ' ignores the albedo alpha of the layers (roughness comes from the Upper layer). The texture files are not changed.')
            end
        elseif from.alpha == 'glow' or to.alpha == 'glow' then
            Warn('Not done: the alpha of layer 1 is a glow mask in TTerrainGlow only. The texture files are not changed.')
        end
    end
    if t.baseClear then
        WarnOff('Not done: ' .. targetId .. ' lays the texture of the base layer over the whole map by its own alpha (a macrotexture), and the alpha of yours is a specularity: the base texture shows through everywhere. The texture file is not changed.')
        if texOn then Line('Textures: ' .. targetId .. ' lays the base layer over the whole map by its alpha (a macrotexture). A copy of the base texture with alpha 0 is made so that nothing is laid over the paint.') end
    end
    if to.upper == 'atlas' and plan.upperAction == 'atlas' then
        WarnOff('Not done: the roughness and heights of the layers come from the Upper atlas, one tile per layer. The neutral atlas gives every layer the same roughness' ..
                (string.find(targetId, '^Terrain2') and ' and no height variation, so the 2xx splatting switches at a mask value of about one half (hard edges); make an atlas for a finished map' or '') .. '.')
        if texOn and string.find(targetId, '^Terrain2') then
            WarnOn('The heights of the atlas are the detail of each texture (a rough guess): rock does not win over grass by itself. Make an atlas by hand (roughness R / B, height G / A) for a finished map.')
        end
    end
    if t.light or t.normal then
        local what = {}
        if t.normal then table.insert(what, 'the map normal map (normal map of layer 8)') end
        if t.light then table.insert(what, to.biplanar and 'the water depth (albedo of layer 8, R)' or 'a neutral light texture (albedo of layer 8: no shadow, no occlusion, alpha 1)') end
        local why = to.biplanar and ('always reads ' .. table.concat(what, ' and ') .. ' (the normal map decides which side texture each point gets)')
                    or 'always reads the alpha of layer 8 as baked shadow (a ground texture there darkens the map)'
        WarnOff(targetId .. ' ' .. why .. '. Layer 8 keeps ' .. (plan.layers[8].textured and Basename(ed_stratum_layer(8)) or 'its texture') .. ': the shading is wrong (dark, streaky).')
        if texOn then Line('Layer 8 holds map-wide data in ' .. targetId .. ': it is given ' .. table.concat(what, ' and ') .. ' (new files, made from the terrain).') end
    end
    if t.lighting == 'enter' or t.lighting == 'fix' then
        local L = Shaders.SPLAT_LIGHT
        Line('Lighting: the splat settings of ' .. targetId .. ' are the map\'s SpecularColor, which is (0, 0, 0, 0) in a map made for another shader (flat colours, hard edges). It is set to ' ..
             string.format('(%.2f, %.2f, %.3f, %.2f)', L.spec_r, L.spec_g, L.spec_b, L.spec_a) .. ': softness, contrast, and the rotation (30 degrees) of every second layer.')
    elseif t.lighting == 'leave' then
        Line('Lighting: the SpecularColor the splat settings used is put back (' .. targetId .. ' uses it as the specular highlight).')
    end
    if from.biplanar and not to.biplanar then
        Warn('The cliff textures of layers 3 and 4 were mapped from the side by ' .. fromId .. '; ' .. targetId .. ' maps them from above, so they stretch on steep ground. Use a B shader (Terrain...B) for cliffs.')
    end
    Line('Normal maps stay as they are: every terrain shader reads them the same way (RGB = x, y, z)' .. (to.class == 'splat' and ', but the Terrain2xx shaders sample them at the albedo tile size of the layer (the normal tile size is the far scale of the heights)' or '') .. '.')
    if not texOn and t.any then
        -- without the natives the warnings are the ones of a conversion that leaves the textures alone
        local w = {}
        for _, x in plan.warningsNoTex do table.insert(w, x) end
        table.insert(w, 'This editor build cannot convert textures (ed_tex_convert is missing): the texture files stay as they are.')
        plan.warnings = w
        plan.warningsNoTex = w
    end
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

--- The albedo alpha of the textured layers made right for the target (a new file per layer): ctx = { plan, Add, files, srcAtlas }. mode 'invert' | 'derive' (plan.tex.alpha) and / or the base layer's alpha 0.
local function StepAlpha(ctx)
    local plan = ctx.plan
    local t = plan.tex
    if not t.alpha and not t.baseClear then return end
    local from, to = plan.fromP, plan.toP
    local toKind = to.alpha
    local slots = { 0, 1, 2, 3, 4, 5, 6, 7 }
    -- layer 8 is a texture layer only when both shaders paint it
    if from.l8 == 'paint' and to.l8 == 'paint' then table.insert(slots, 8) end
    local made, lossy = 0, 0
    for _, slot in slots do
        local path = ed_stratum_layer(slot)
        if TexConv.IsTexture(path) and (t.alpha or slot == 0) then
            local chan, what
            if t.alpha == 'invert' then
                chan, what = { invert = true }, 'alpha inverted'
            elseif t.alpha == 'derive' then
                if ctx.srcAtlas and slot <= 7 then
                    chan, what = TexConv.SpecFromRoughChan(toKind, ctx.srcAtlas, slot + 1), 'alpha from the roughness of the old atlas'
                else
                    local v = (toKind == 'matte') and (1 - TexConv.SPEC_DEFAULT) or TexConv.SPEC_DEFAULT
                    chan, what = { from = 'const', value = v }, 'alpha ' .. string.format('%.2f', v)
                end
            else
                chan, what = { from = 'const', value = 0 }, 'alpha 0 (no macrotexture)'
            end
            local vfs, lossless = TexConv.Alpha(path, chan)
            if vfs then
                local s = Strata.Snapshot(slot)
                Strata.SetTexture(slot, vfs, s.normal, s.size, s.nsize)
                made = made + 1
                if not lossless then lossy = lossy + 1 end
                ctx.Add('file', Basename(vfs) .. ': layer ' .. slot .. ' (' .. Basename(path) .. '), ' .. what .. (lossless and '' or ' (re-compressed)'))
            else
                ctx.Add('warn', 'Layer ' .. slot .. ' (' .. Basename(path) .. '): the alpha could not be converted (' .. tostring(lossless) .. '); the texture stays.')
            end
        end
    end
    ctx.files = ctx.files + made
end

--- The Upper layer's atlas: made from the layers' textures (ctx.texOn) or the editor's neutral file. Returns the VFS path or nil.
local function StepAtlas(ctx)
    local plan = ctx.plan
    if ctx.texOn then
        local paths = {}
        for slot = 0, 7 do paths[slot] = ed_stratum_layer(slot) end
        local kind = (plan.fromP.alpha == 'spec' or plan.fromP.alpha == 'matte') and plan.fromP.alpha or nil
        local vfs, report = TexConv.Atlas(paths, kind, 1024)
        if vfs then
            local bad = {}
            for k = 1, 8 do
                if type(report) == 'table' and report[k] and string.sub(report[k], 1, 6) == 'cannot' then table.insert(bad, k) end
            end
            ctx.files = ctx.files + 1
            ctx.Add('file', Basename(vfs) .. ': roughness / height atlas of the Upper layer (' .. (kind and 'roughness from the albedo alpha, ' or 'neutral roughness, ') .. 'heights from the detail of the textures)')
            if table.getn(bad) > 0 then
                ctx.Add('warn', 'The atlas has neutral tiles for ' .. LayerList(bad) .. ' (tile numbers; their texture could not be read).')
            end
            return vfs
        end
        ctx.Add('warn', 'The roughness / height atlas could not be made (' .. tostring(report) .. '): the neutral one is used.')
    end
    if DiskGetFileInfo(ATLAS) then return ATLAS end
    return nil
end

--- Layer 8 of the shaders that read it as map-wide data: the map normal map and / or the water depth / light texture (maptextures.lua), unless the layer holds one already.
local function StepMapData(ctx)
    local t = ctx.plan.tex
    if not (t.light or t.normal) then return end
    local MT = import('/lua/editor/maptextures.lua')
    local function Done(what, entry, err)
        if entry then
            ctx.Add('done', what)
        else
            ctx.Add('warn', what .. ' could not be made (' .. tostring(err) .. ').')
        end
    end
    local function Quiet(f)
        local n0 = table.getn(MT.State.created)
        local entry, err = f()
        -- conversion files are never pruned (undo and redo must find them; saving removes the unused ones)
        while table.getn(MT.State.created) > n0 do table.remove(MT.State.created) end
        return entry, err
    end
    if t.normal and not MapDataActive(18) then
        local entry, err = Quiet(function() return MT.Generate('normal', { noPush = true }) end)
        Done('Layer 8 normal map: the map normal map (made from the terrain)', entry, err)
        if entry then
            ctx.files = ctx.files + 1
            ctx.Add('file', Basename(ed_stratum_layer(18)) .. ': map normal map (normal map of layer 8)')
        end
    end
    if t.light and not MapDataActive(8) then
        local entry, err
        if t.light == 'generate' then
            entry, err = Quiet(function() return MT.Generate('light', { noPush = true, shadow = false }) end)
            Done('Layer 8 albedo: the water depth of the terrain (no baked shadow)', entry, err)
        else
            entry, err = Quiet(function() return MT.Clear('light', { noPush = true }) end)
            Done('Layer 8 albedo: a neutral light texture (no shadow, no occlusion)', entry, err)
        end
        if entry then
            ctx.files = ctx.files + 1
            ctx.Add('file', Basename(ed_stratum_layer(8)) .. ': ' .. (t.light == 'generate' and 'water depth' or 'neutral light texture') .. ' (albedo of layer 8)')
        end
    end
end

function Run(plan, opts)
    if not plan or plan.refused then return nil, plan and plan.refused or 'nothing to convert' end
    opts = opts or {}
    local from, to = plan.fromP, plan.toP
    local K = to.painted
    local choice = opts.layer8 or plan.default
    if choice == 'move' and not plan.canMove then choice = 'merge' end
    local texOn = opts.textures ~= false and plan.tex and plan.tex.available and true or false
    local report = { lines = {}, cells = 0, files = 0 }
    local function Add(kind, text) table.insert(report.lines, { kind = kind, text = text }) end
    local maskBefore = Shaders.MaskState()          -- the range the masks were made for, kept for the undo
    local specBefore = Shaders.SpecColor()
    local ok, why = Shaders.Set(plan.to, true)
    if not ok then return nil, why end
    local before = {}
    for i = 0, 9 do before[i] = Strata.Snapshot(i) end
    local parts = {}
    local specAfter = false
    local function Undo()
        for i = table.getn(parts), 1, -1 do parts[i].undo() end
        ApplyLayers(before)
        ed_stratum_shader(plan.cur or plan.from)
        Shaders.SetMaskState(maskBefore)
        Shaders.SetSpecColor(specBefore)
    end

    -- the arrangement of the layers: perm[j] = the source layer whose paint and textures slot j gets
    local extra = plan.extra
    local perm = Arrange(plan, choice)
    local movedTo = {}
    for j = 1, 8 do
        if perm[j] ~= j and plan.layers[perm[j]].painted then table.insert(movedTo, { from = perm[j], to = j }) end
    end

    local ctx = { plan = plan, Add = Add, files = 0, texOn = texOn }
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
        -- the atlas the source map had, for an alpha made from its roughness (read before the Upper layer changes)
        if from.upper == 'atlas' and plan.tex.alpha == 'derive' and before[9].albedo ~= ATLAS and TexConv.IsTexture(before[9].albedo) then ctx.srcAtlas = before[9].albedo end
        -- the Upper layer
        if opts.upper and plan.upperAction == 'atlas' then
            local path = StepAtlas(ctx)
            if path then
                local w = ed_terrain_info()
                local size = 2 * ((w or 512) - 1)          -- a tile size above the map size: the shader reads a tile value below 1 as "PBR rendering" (decals follow it); the atlas itself is read with the layers' tiles
                Strata.SetTexture(9, path, Strata.NONE_NORMAL, size, size)
                Add('done', 'Upper layer: ' .. Basename(before[9].albedo) .. ' replaced by the ' .. (path == ATLAS and 'neutral ' or '') .. 'roughness / height atlas.')
            else
                Add('warn', 'Upper layer: the roughness / height atlas is missing (run: python scripts/studio.py generate); the Upper layer stays as it is.')
            end
        elseif opts.upper and plan.upperAction == 'clear' then
            if Strata.Clear(9) then
                Add('done', 'Upper layer: ' .. Basename(before[9].albedo) .. ' replaced by a transparent texture.')
            else
                Add('warn', 'Upper layer: ' .. Basename(before[9].albedo) .. ' could not be replaced (the transparent texture is missing, run: python scripts/studio.py generate).')
            end
        elseif plan.upperAction and not opts.upper then
            Add('warn', 'Upper layer left as it is (' .. Basename(before[9].albedo) .. '): ' .. plan.to .. ' reads it as ' .. (to.upper == 'atlas' and 'a roughness / height atlas' or (to.upper == 'specular' and 'a specular texture' or 'an overlay')) .. '.')
        end
        -- the albedo alpha, layer 8's map-wide pictures
        if texOn then
            StepAlpha(ctx)
            StepMapData(ctx)
        end
        -- the splat settings of the lighting
        local mode = plan.tex.lighting
        if mode then
            local b, a = Shaders.SplatLighting(mode)
            specAfter = a and Shaders.SpecColor() or false
            if a then
                if mode == 'leave' then
                    Add('done', 'Lighting: SpecularColor put back to (' .. string.format('%.2f, %.2f, %.2f, %.2f', a.spec_r, a.spec_g, a.spec_b, a.spec_a) .. ').')
                else
                    Add('done', 'Lighting: SpecularColor set to ' .. string.format('(%.2f, %.2f, %.3f, %.2f)', a.spec_r, a.spec_g, a.spec_b, a.spec_a) .. ' (splat softness, contrast, rotation).')
                end
            end
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
    Shaders.SetMaskState(false)          -- the masks are in the range of the new shader now
    if Strata.Active > K then Strata.Active = K end
    report.files = ctx.files

    local after = {}
    for i = 0, 9 do after[i] = Strata.Snapshot(i) end
    History.Push({
        label = 'convert layers to ' .. plan.to,
        undo = Undo,
        redo = function()
            ApplyLayers(after)
            ed_stratum_shader(plan.to)
            Shaders.SetMaskState(false)
            if specAfter then Shaders.SetSpecColor(specAfter) end
            for i = 1, table.getn(parts) do parts[i].redo() end
        end,
        release = function() for _, e in parts do e.release() end end,
    })

    -- the report: what was done, then the warnings of the plan that apply (the ones for a conversion without textures when they were not converted)
    local lines = {}
    table.insert(lines, { kind = 'done', text = 'Shader: ' .. plan.from .. ' -> ' .. plan.to .. '.' })
    for _, l in report.lines do table.insert(lines, l) end
    for _, w in (texOn and plan.warnings or plan.warningsNoTex) do
        table.insert(lines, { kind = 'warn', text = w })
    end
    local nWarn = 0
    for _, l in lines do
        if l.kind == 'warn' then nWarn = nWarn + 1 end
    end
    report.lines = lines
    report.warnings = nWarn
    report.status = 'converted layers to ' .. plan.to .. ': ' .. report.cells .. ' mask cells changed, ' .. report.files .. ' texture files made, ' .. nWarn .. ' notes (one undo step)'
    return report
end
