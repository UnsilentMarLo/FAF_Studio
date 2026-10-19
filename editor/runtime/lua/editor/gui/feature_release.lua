-- File > Release map... (the checks, the next version folder, one click) and File > Open recent. A self-registering feature module (gui/feature_*.lua are imported by the shell):
-- it adds its own commands and menu items, so no shared file has to be edited. Logic: release.lua, recent.lua.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Release = import('/lua/editor/release.lua')
local Recent = import('/lua/editor/recent.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

function ReleaseDialog()
    local list = Release.Findings()
    local errors, warnings = Release.Count(list)
    local dir, stem, version = Release.Target()
    local d = Dialog.Open('Release map', 600, 460)
    local c = Skin.color
    local next = d:Label('', 14, 30, { color = c.textDim, size = 'small' })
    W.Fit(next, 'Next version: ' .. tostring(stem) .. '.v' .. string.format('%04d', version) .. '   (' .. tostring(dir) .. ')', d.width - Skin.S(28))    -- the folder path is long
    d:Label(string.format('%d error(s), %d warning(s). Errors must be fixed before a release.', errors, warnings), 14, 48, { color = errors > 0 and c.error or c.text })
    local view = W.VirtualList(d.group, {
        rowH = 22, extra = true,
        getCount = function() return table.getn(list) end,
        bind = function(row, index)
            local i = list[index]
            if not i then return end
            W.Fit(row.text, i.text, math.max(Skin.S(60), row.bg.Width() - Skin.S(40)))
            row.text:SetColor(i.sev == 'E' and c.error or (i.sev == 'W' and c.warn or c.textDim))
            row.extra:SetText(i.sev)
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
    })
    view:SetRect(Skin.S(8), Skin.S(72), Skin.S(584), Skin.S(330))
    local go = d:Button('Release', 14, 418, 110, 28, function()
        local folder, n = Release.Release()
        Dialog.Close()
        if folder then
            Say('released as version ' .. n .. ': ' .. folder .. '  (zip it with scripts/pack_map.py)')
        else
            Say('release failed: ' .. tostring(n))
        end
    end)
    d:Button('Cancel', 134, 418, 90, 28, function() Dialog.Close() end)
    if errors > 0 then go:SetText('Fix errors first') end
    d.releaseButton = go
    return d
end

Commands.Register{ id = 'file.release', title = 'File: release map...', run = function() ReleaseDialog() end }

local function RecentItems()
    local items = {}
    for _, m in Recent.List() do
        local path = m.path
        table.insert(items, { title = m.name .. '   (' .. m.folder .. ')', run = function() import('/lua/editor/maps.lua').Open(path) end })
    end
    return items
end

Menu.Extend('menubar.File', function()
    return {
        { title = 'Open recent', submenu = RecentItems, enabled = function() return table.getn(Recent.List()) > 0 end },
    }
end, 6)
Menu.Extend('menubar.File', function()
    return {
        { command = 'file.release' },
    }
end, 20)
