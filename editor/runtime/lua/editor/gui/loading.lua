-- The editor's loading screen: shown by the game's loading dialog hooks (schook/lua/ui/game/gamemain.lua) in place of the game's movie, "IN TRANSIT" and game tips.
--
--   Start()   covers the window with the editor's dark background, its name, the version and an editor tip (the pulsing line says what is going on)
--   Stop()    takes it down
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')

group = false

function Stop()
    if group then
        group:Destroy()
        group = false
    end
end

function Start()
    Stop()
    local frame = GetFrame(0)
    local bg = Bitmap(frame)
    bg:SetSolidColor('ff0d1114')
    LayoutHelpers.FillParent(bg, frame)
    bg.Depth:Set(10000)
    group = bg

    local Version = import('/lua/editor/version.lua')
    local accent = 'ff3fb6d6'
    local dim = 'ff8a969c'

    local title = UIUtil.CreateText(bg, 'FAF Studio', 54, UIUtil.titleFont or UIUtil.bodyFont)
    title:SetColor(accent)
    LayoutHelpers.AtCenterIn(title, frame, -60)
    local line = Bitmap(bg)
    line:SetSolidColor('ff1f2a30')
    line.Depth:Set(function() return bg.Depth() + 1 end)
    line.Left:Set(function() return frame.Left() + math.floor(frame.Width() * 0.3) end)
    line.Right:Set(function() return frame.Right() - math.floor(frame.Width() * 0.3) end)
    line.Top:Set(function() return title.Bottom() + 14 end)
    line.Height:Set(2)
    local sub = UIUtil.CreateText(bg, 'Loading the map ...', 20, UIUtil.bodyFont)
    sub:SetColor(dim)
    LayoutHelpers.AtHorizontalCenterIn(sub, frame)
    sub.Top:Set(function() return line.Bottom() + 16 end)
    pcall(function() import('/lua/maui/effecthelpers.lua').Pulse(sub, 1, 0.25, 0.9) end)

    local tips = import('/lua/editor/tips.lua')
    local tip = UIUtil.CreateText(bg, tips.Get(Random(1, tips.Count())), 16, UIUtil.bodyFont)
    tip:SetColor('ffb8c4ca')
    LayoutHelpers.AtCenterIn(tip, frame, 150)
    local ver = UIUtil.CreateText(bg, Version.Text(), 14, UIUtil.bodyFont)
    ver:SetColor(dim)
    LayoutHelpers.AtLeftBottomIn(ver, frame, 14, 10)
end
