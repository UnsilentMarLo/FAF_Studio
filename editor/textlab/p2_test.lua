-- P2 visual test (run through /edcmd): legacy Arial, ed gray (;g) and ed LCD at 11 / 12 / 13.75 / 14 px on a dark panel, a light panel and
-- directly over the world. Moho Lua 5.0: no \x escapes, closures share loop variables (copy to locals).
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text

local sample = 'The quick brown fox  AVATAR To Wa  0123 -1.5  \195\132 \195\159 \195\169 \206\169 \208\150 \230\151\165\230\156\172\232\170\158'
local root = GetFrame(0)
local fam = 'ed:Segoe UI Variable Text'
local variants = { { 'Arial', 'legacy' }, { fam .. ';g', 'ed gray' }, { fam, 'ed LCD' } }
local sizes = { 11, 12, 13.75, 14 }

local function Panel(color, textColor, left, top, width, height)
    local bg
    if color then
        bg = Bitmap(root)
        bg:SetSolidColor(color)
        bg.Left:Set(left)
        bg.Top:Set(top)
        bg.Width:Set(width)
        bg.Height:Set(height)
        bg.Depth:Set(10000)
    end
    local y = 6
    for _, size in sizes do
        for _, v in variants do
            local t = Text(bg or root)
            t:SetFont(v[1], size)
            t:SetColor(textColor)
            t:SetText(sample)
            local top0, left0 = top + y, left + 8
            t.Left:Set(left0)
            t.Top:Set(top0)
            t.Depth:Set(10001)
            y = y + math.floor(size) + 8
        end
    end
    return bg
end

Panel('ff23262b', 'ffe6e6e6', 8, 8, 640, 240)
Panel('fff4f5f7', 'ff191b1f', 8, 256, 640, 240)
Panel(nil, 'ffffffff', 660, 8, 600, 240)      -- directly over the world, white text
return 'ok'
