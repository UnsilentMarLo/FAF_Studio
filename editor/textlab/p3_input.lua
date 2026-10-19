-- Pop-out input test (run through /edcmd): a window with a hit-test bitmap that records events and an Edit control that takes keyboard input.
-- Read the result with p3_input_read.lua.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Edit = import('/lua/maui/edit.lua').Edit
local Text = import('/lua/maui/text.lua').Text

local id, err = ed_window_create(150, 150, 500, 300, 'input test')
if not id then return 'create failed: ' .. tostring(err) end
local f = GetFrame(id)
rawset(_G, 'EdPopoutInput', { id = id, events = {}, count = 0 })
local store = EdPopoutInput

local hit = Bitmap(f)
hit:SetSolidColor('ff7a3b3b')
hit.Left:Set(20) hit.Top:Set(20) hit.Width:Set(200) hit.Height:Set(100)
hit.HandleEvent = function(self, event)
    store.count = store.count + 1
    store.events[table.getn(store.events) + 1] = tostring(event.Type) .. '@' .. tostring(event.MouseX) .. ',' .. tostring(event.MouseY)
    return true
end

local edit = Edit(f)
edit:SetNewFont('Arial', 14)
edit:SetForegroundColor('ffffffff')
edit:SetBackgroundColor('ff1c1e22')
edit.Left:Set(20) edit.Top:Set(160) edit.Width:Set(300) edit.Height:Set(26)
edit:AcquireFocus()
store.edit = edit
return 'ready id=' .. id
