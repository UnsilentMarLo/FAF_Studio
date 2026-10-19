-- Dialogs of the environment libraries (lighting presets, strata themes).
--
--   AskName(title, default, done)          a name field; done(text) when the user presses Save (or Enter)
--   PickMap(title, done)                   the maps the game knows with a filter; done(entry, scmapPath, why): the .scmap file on disk the look / theme is read from
--                                          (nil and a reason for a map that is packed in a game archive)
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Maps = import('/lua/editor/maps.lua')

function AskName(title, default, done)
    local d = Dialog.Open(title, 420, 120)
    d:Label('Name', 14, 40, { color = Skin.color.textDim })
    local name = d:Field(70, 36, 330, 22, { text = default or '' })
    local function Go()
        local text = name:GetText()
        if text == '' then return end
        Dialog.Close()
        done(text)
    end
    d:Button('Save', 14, 80, 100, 26, Go)
    d:Button('Cancel', 124, 80, 100, 26, function() Dialog.Close() end)
    name.OnEnterPressed = function(self, text) Go() return true end
    name:AcquireFocus()
end

--- The .scmap file of a map entry (Maps.List): next to its scenario file on disk. nil, reason for maps inside game archives.
function ScmapPath(entry)
    local disk = ed_vfs_to_disk(entry.path)
    if not disk then return nil, entry.name .. ' is packed in a game archive: only maps on disk can be read' end
    local path = string.gsub(disk, '_scenario%.lua$', '.scmap')
    if path == disk or not ed_file_exists(path) then return nil, 'no .scmap file next to ' .. disk end
    return path
end

function PickMap(title, done)
    local d = Dialog.Open(title, 560, 470)
    local c = Skin.color
    local all = {}
    for _, m in Maps.List() do
        if string.sub(m.folder, 1, 1) ~= '_' then table.insert(all, m) end
    end
    local state = { shown = all }
    local list
    local field = d:Field(14, 30, 530, 22, {
        onChange = function(text)
            local f = string.lower(text or '')
            state.shown = {}
            for _, m in all do
                if f == '' or string.find(string.lower(m.name), f, 1, true) or string.find(string.lower(m.folder), f, 1, true) then table.insert(state.shown, m) end
            end
            list:Refresh()
        end,
        onEscape = function() Dialog.Close() end,
    })
    d:Label(table.getn(all) .. ' maps. Only maps on disk can be read.', 14, 446, { color = c.textDim, size = 'small' })
    list = W.VirtualList(d.group, {
        rowH = 22,
        extra = true,
        getCount = function() return table.getn(state.shown) end,
        bind = function(row, index)
            local m = state.shown[index]
            row.extra:SetText(m.folder)
            local ew = math.min(row.extra.Width(), Skin.S(220))
            W.Fit(row.text, m.name, math.max(Skin.S(40), row.bg.Width() - ew - Skin.S(30)))
            row.text:SetColor(c.text)
            row.extra:SetColor(c.textDim)
            local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
            row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
            row.text.Top:Set(function() return row.bg.Top() + ty end)
            local w2 = row.extra.Width()
            row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
            row.extra.Top:Set(function() return row.bg.Top() + ty end)
        end,
        onSelect = function(index)
            local m = state.shown[index]
            if m then
                Dialog.Close()
                local path, why = ScmapPath(m)
                done(m, path, why)
            end
        end,
    })
    list:SetRect(Skin.S(8), Skin.S(58), Skin.S(544), Skin.S(380))
    field:AcquireFocus()
end
