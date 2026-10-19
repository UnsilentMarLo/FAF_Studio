-- Frame time of the main viewport with N pop-outs open (run through /edcmd). Replace WANT below. Result in p3_perf.txt.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text
local WANT = 3
local root = GetFrame(0)
local made = {}
for n = 1, WANT do
    local id = ed_window_create(60 + n * 40, 80 + n * 30, 420, 300, 'perf ' .. n)
    made[n] = id
    local f = GetFrame(id)
    for i = 1, 40 do
        local t = Text(f)
        t:SetNewFont('ed:Segoe UI Variable Text', 12)
        t:SetColor('ffe6e6e6')
        t:SetText('static label ' .. i .. ' in pop-out ' .. n)
        t.Left:Set(8 + math.mod(i - 1, 2) * 200) t.Top:Set(4 + math.floor((i - 1) / 2) * 14)
    end
end
local poller = Bitmap(root)
poller:SetSolidColor('00000000')
poller.Width:Set(1) poller.Height:Set(1)
poller:DisableHitTest()
poller:SetNeedsFrameUpdate(true)
poller.frames, poller.sum = 0, 0
poller.OnFrame = function(self, delta)
    self.frames = self.frames + 1
    if self.frames > 30 and self.frames <= 180 then self.sum = self.sum + delta end
    if self.frames == 180 then
        ed_write_file('p3_perf.txt', string.format('popouts=%d avg frame %.3f ms', WANT, self.sum / 150 * 1000))
        for _, id in made do ed_window_destroy(id) end
    end
end
return 'started with ' .. WANT
