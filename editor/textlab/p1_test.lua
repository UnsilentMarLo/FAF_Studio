-- P1 in-engine text test, run through the /edcmd channel (copy to engine/run/edcmd.lua).
-- Draws the same sample with the legacy font (Arial, GDI + DXT5) and the ed: backend (DirectWrite) at 11 / 12 / 14 px on a dark and a light panel.
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Text = import('/lua/maui/text.lua').Text

-- Moho Lua 5.0 has no \x escapes: the UTF-8 bytes of "A-umlaut sharp-s e-acute Omega Zhe CJK" are written as decimal escapes.
local sample = 'The quick brown fox  AVATAR To Wa  0123 -1.5  \195\132 \195\159 \195\169 \206\169 \208\150 \230\151\165\230\156\172\232\170\158'
local root = GetFrame(0)
local panels = { { 'ff23262b', 'ffe6e6e6', 8 }, { 'fff4f5f7', 'ff191b1f', 330 } }
local report = {}
for _, p in panels do
    local bg = Bitmap(root)
    bg:SetSolidColor(p[1])
    bg.Left:Set(8)
    bg.Top:Set(p[3])
    bg.Width:Set(980)
    bg.Height:Set(310)
    bg.Depth:Set(10000)
    local y = 6
    for _, size in { 11, 12, 14 } do
        for _, family in { 'Arial', 'ed:Segoe UI Variable Text' } do
            local t = Text(bg)
            t:SetFont(family, size)
            t:SetColor(p[2])
            t:SetText(sample)
            local top = y    -- closures share the loop variable: each lazy value needs its own copy
            local panelBg = bg
            t.Left:Set(function() return panelBg.Left() + 8 end)
            t.Top:Set(function() return panelBg.Top() + top end)
            t.Depth:Set(10001)
            report[table.getn(report) + 1] = family .. ' ' .. size .. ' w=' .. tostring(t.Width()) .. ' h=' .. tostring(t.Height())
            y = y + size + 10
        end
    end
end
return table.concat(report, ' | ')
