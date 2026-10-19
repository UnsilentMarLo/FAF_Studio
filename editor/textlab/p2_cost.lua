-- P2 cost test: 250 visible labels of about 20 characters drawn for 120 frames in three modes (legacy Arial, ed gray, ed LCD).
-- Writes p2_cost.txt (relative to the engine's working directory) with per-mode averages: frame delta, text render milliseconds
-- per frame (ed_text_stats), quads and flushes per frame, and the one-time raster cost of the cold frame.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text

local root = GetFrame(0)
local fam = 'ed:Segoe UI Variable Text'
local modes = { { 'legacy Arial 12', 'Arial' }, { 'ed gray 12', fam .. ';g' }, { 'ed LCD 12', fam } }
local LABELS, WARM, MEASURE = 250, 20, 120   -- 250 labels fill the 1200 x 700 panel (5 columns x 50 rows), all visible

local words = { 'Mass', 'Energy', 'Armies', 'Markers', 'Props', 'Decals', 'Strata', 'Water', 'Undo', 'Redo' }

local state = { mode = 0, frame = 0, labels = {}, sum = 0, results = {}, bg = nil }

local function Clear()
    for _, t in state.labels do t:Destroy() end
    state.labels = {}
    if state.bg then state.bg:Destroy() state.bg = nil end
end

local function Build(family)
    state.bg = Bitmap(root)
    state.bg:SetSolidColor('ff23262b')
    state.bg.Left:Set(0)
    state.bg.Top:Set(0)
    state.bg.Width:Set(1200)
    state.bg.Height:Set(700)
    state.bg.Depth:Set(10000)
    for i = 1, LABELS do
        local t = Text(state.bg)
        t:SetFont(family, 12)
        t:SetColor('ffe6e6e6')
        t:SetText(words[math.mod(i, 10) + 1] .. ' item ' .. string.format('%04d', i) .. ' ' .. words[math.mod(i * 7, 10) + 1])
        local l, tp = 4 + math.mod(i - 1, 5) * 230, 4 + math.floor((i - 1) / 5) * 14
        t.Left:Set(l)
        t.Top:Set(tp)
        t.Depth:Set(10001)
        state.labels[i] = t
    end
end

local poller = Bitmap(root)
poller:SetSolidColor('00000000')
poller.Width:Set(1)
poller.Height:Set(1)
poller:DisableHitTest()
poller:SetNeedsFrameUpdate(true)
poller.OnFrame = function(self, delta)
    if state.mode > 3 then return end
    if state.frame == 0 then
        state.mode = state.mode + 1
        if state.mode > 3 then
            local out = {}
            for _, line in state.results do out[table.getn(out) + 1] = line end
            ed_write_file('p2_cost.txt', table.concat(out, '\n') .. '\n')
            Clear()
            return
        end
        Clear()
        ed_text_stats()
        Build(modes[state.mode][2])
        state.sum = 0
    end
    state.frame = state.frame + 1
    if state.frame == 2 then   -- the first frame that drew the new labels (cold glyph and layout caches)
        local runs, quads, flushes, raster, rasterMs, renderMs = ed_text_stats()
        state.cold = string.format('cold frame: runs %d quads %d glyph bitmaps %d raster %.2f ms render %.2f ms', runs, quads, raster, rasterMs, renderMs)
    elseif state.frame == WARM then
        ed_text_stats()
        state.sum = 0
    elseif state.frame > WARM then
        state.sum = state.sum + delta
        if state.frame == WARM + MEASURE then
            local runs, quads, flushes, raster, rasterMs, renderMs = ed_text_stats()
            local n = MEASURE
            state.results[state.mode] = string.format('%-16s frame %.2f ms | text render %.3f ms/frame | runs %d quads %d flushes %d per frame | %s',
                modes[state.mode][1], state.sum / n * 1000, renderMs / n, runs / n, quads / n, flushes / n, state.cold)
            state.frame = 0
        end
    end
end
return 'started'
