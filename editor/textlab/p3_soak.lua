-- Pop-out lifecycle soak (run through /edcmd): 50 x (create window, put a bitmap and a text in its root frame, wait, destroy).
-- Result in p3_soak.txt (engine working directory) when finished.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text
local root = GetFrame(0)
local state = { step = 0, id = nil, created = 0, destroyed = 0, failed = 0 }
local poller = Bitmap(root)
poller:SetSolidColor('00000000')
poller.Width:Set(1)
poller.Height:Set(1)
poller:DisableHitTest()
poller:SetNeedsFrameUpdate(true)
poller.frames = 0
poller.OnFrame = function(self, delta)
    if state.step >= 100 then return end
    self.frames = self.frames + 1
    if math.mod(self.frames, 10) ~= 0 then return end
    state.step = state.step + 1
    if state.id == nil then
        local id, err = ed_window_create(300 + math.mod(state.step, 7) * 30, 200 + math.mod(state.step, 5) * 20, 360, 260, 'soak ' .. state.step)
        if id then
            state.id = id
            state.created = state.created + 1
            local f = GetFrame(id)
            local b = Bitmap(f)
            b:SetSolidColor('ff3b7a57')
            b.Left:Set(8) b.Top:Set(8) b.Width:Set(200) b.Height:Set(80)
            local t = Text(f)
            t:SetNewFont('ed:Segoe UI Variable Text', 13)
            t:SetColor('ffffffff')
            t:SetText('soak ' .. state.step)
            t.Left:Set(16) t.Top:Set(110)
        else
            state.failed = state.failed + 1
        end
    else
        if ed_window_destroy(state.id) then state.destroyed = state.destroyed + 1 end
        state.id = nil
    end
    if state.step >= 100 then
        ed_write_file('p3_soak.txt', string.format('created %d destroyed %d failed %d', state.created, state.destroyed, state.failed))
    end
end
return 'started'
