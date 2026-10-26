-- How a map's paint is built: per painted layer, how much of its mask lives at fine scales (soft or detailed), what terrain feature it follows, and how many layers blend at a texel.
-- Run in a test instance with the map open: python scripts/editor_inst.py cmd <tag> scripts/mask_analysis.lua --chars 9000
--
--   detail     rms of (mask - blur(mask, r)) for r = 1, 3, 10, 30 divided by the rms of the mask around its mean: 1.0 = all of the variation is at scales finer than r
--   follows    correlation of the mask with: slope, relief (H - blur(H, 32): above / below its surroundings), height, curvature at 4 and 16 units, flow accumulation (log)
--   blend      share of the map where 1, 2, 3, 4 or more layers (the base counted) weigh more than 0.15
--
-- Lua 5.0 dialect.

local Fields = import('/lua/editor/fields.lua')
local out = {}
local function P(...) table.insert(out, string.format(unpack(arg))) end
local function Mean(f) local _, _, m = Fields.Stats(f) return m end

Fields.Run(function(S)
    local H = S:Height(1)
    local function Corr(a, b)
        local ma, mb = Mean(a), Mean(b)
        local cov = Mean(S:Op('mul', { a = a, b = b })) - ma * mb
        local va = Mean(S:Op('mul', { a = a, b = a })) - ma * ma
        local vb = Mean(S:Op('mul', { a = b, b = b })) - mb * mb
        if va <= 1e-12 or vb <= 1e-12 then return 0 end
        return cov / math.sqrt(va * vb)
    end
    local feat = {
        slope = S:Op('slope', { a = H, mode = 'degrees', radius = 1 }),
        relief = S:Op('sub', { a = H, b = S:Op('blur', { a = H, radius = 32 }) }),
        height = H,
        curv4 = S:Op('curvature', { a = H, radius = 4, gain = 25 }),
        curv16 = S:Op('curvature', { a = H, radius = 16, gain = 25 }),
    }
    local okF, flow = pcall(function() return S:Op('flow', { a = H }) end)
    if okF and flow then feat.flow = flow end
    local order = { 'slope', 'relief', 'height', 'curv4', 'curv16', 'flow' }
    local channel = flow and S:Op('threshold', { a = flow, value = 0.3 }) or nil      -- the drainage network: the 10 percent of the ground with the most water
    local chMean = channel and Mean(channel) or 0
    local count = {}
    local masks = {}
    for layer = 8, 1, -1 do
        local ok, m = pcall(function() return S:Stratum(layer) end)
        if ok and m then masks[layer] = S:Op('resample', { a = m, like = H }) end
    end
    for layer = 1, 8 do
        local e = masks[layer]
        if e then
            local mean = Mean(e)
            local c = S:Op('affine', { a = e, mul = 1, add = -mean })
            local _, _, tv = Fields.Stats(S:Op('mul', { a = c, b = c }))
            local tsd = math.sqrt(tv)
            if mean > 0.002 and tsd > 0.002 then
                local line = string.format('layer %d  mean %.3f  sd %.3f  detail', layer, mean, tsd)
                for _, r in { 1, 3, 10, 30 } do
                    local d = S:Op('sub', { a = e, b = S:Op('blur', { a = e, radius = r }) })
                    local _, _, dv = Fields.Stats(S:Op('mul', { a = d, b = d }))
                    line = line .. string.format('  r%d %.2f', r, math.sqrt(dv) / tsd)
                end
                line = line .. '  follows'
                for _, k in order do
                    if feat[k] then line = line .. string.format('  %s %+.2f', k, Corr(e, feat[k])) end
                end
                if channel and chMean > 0 and mean > 0 then
                    local on = Mean(S:Op('mul', { a = e, b = channel })) / chMean
                    line = line .. string.format('  | on drainage lines: %.2f of its mean (%.2f vs %.2f)', on / mean, on, mean)
                end
                table.insert(out, line)
            end
            local over = S:Op('threshold', { a = e, value = 0.15 })
            table.insert(count, over)
        end
    end
    -- how many layers (+ the base) weigh more than 0.15 at a texel
    local total = S:Op('const', { like = H, value = 1 })
    for _, o in count do total = S:Op('add', { a = total, b = o }) end
    local line = 'blend   share of the map with N layers over 0.15 (base counted):'
    for n = 1, 6 do
        local ge = S:Op('threshold', { a = total, value = n - 0.5 })
        local gt = S:Op('threshold', { a = total, value = n + 0.5 })
        line = line .. string.format('  %d: %.2f', n, Mean(ge) - Mean(gt))
    end
    table.insert(out, line)
    table.insert(out, string.format('        mean number of layers %.2f', Mean(total)))
end)
return table.concat(out, '\n')
