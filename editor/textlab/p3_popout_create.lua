-- Pop-out prototype test 1 (run through /edcmd): create a window, build a few Maui controls in its root frame, report the geometry.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text

local id, err = ed_window_create(120, 120, 640, 480, 'T1 pop-out')
if not id then
    return 'create failed: ' .. tostring(err)
end
local f = GetFrame(id)
local out = {}
out[1] = 'id=' .. id
out[2] = 'GetNumRootFrames=' .. tostring(GetNumRootFrames())
out[3] = 'frame ' .. tostring(f.Width()) .. 'x' .. tostring(f.Height())

local bg = Bitmap(f)
bg:SetSolidColor('ff2b5d8a')
bg.Left:Set(10)
bg.Top:Set(10)
bg.Width:Set(300)
bg.Height:Set(120)

local label = Text(bg)
label:SetNewFont('ed:Segoe UI Variable Text', 14)
label:SetColor('ffffffff')
label:SetText('Pop-out panel: kerned LCD text AVATAR To Wa')
label.Left:Set(18)
label.Top:Set(20)

local old = Text(f)
old:SetFont('Arial', 12)
old:SetColor('ffe6e6e6')
old:SetText('legacy Arial label in the same window')
old.Left:Set(18)
old.Top:Set(150)

-- stash the id for the following steps
rawset(_G, 'EdPopoutTestId', id)
return table.concat(out, ' | ')
