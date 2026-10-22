-- Built-in sample panels (outliner, properties, brushes, viewport; the console is gui/panels_console.lua). They exist to exercise the framework; real editor panels
-- register the same way (see panels.lua).

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Model = import('/lua/editor/gui/model.lua')

local function Rows(row, text, color)
    local rh = row.bg.Height()
    row.text:SetText(text)
    row.text:SetColor(color or Skin.color.text)
    local ty = math.floor((rh - row.text.Height()) / 2)
    row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
    row.text.Top:Set(function() return row.bg.Top() + ty end)
end

-- The viewport panel is a hole in the shell: the engine's world view is resized to the hole (the game's own split-view code does the same
-- with the lazy variables of viewLeft), so the camera, picking and the aspect ratio match what the user sees. Only the main window's
-- viewport drives the world view.
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local attached = false     -- holder the world view follows right now
local remembered = false   -- last holder, for re-attaching after play mode
local released = false     -- a test run: the world view fills the frame and EnsureWorldView must not pull it back into the viewport

local function WorldView()
    local ok, wv = pcall(import, '/lua/ui/game/worldview.lua')
    return ok and wv.viewLeft or false
end

--- Releases the world view to fill its parent again (play mode, no viewport in the workspace).
function ReleaseWorldView(forPlay)
    attached = false
    released = forPlay and true or false
    local view = WorldView()
    if view then
        LayoutHelpers.FillParent(view, view:GetParent())
        view:GetsGlobalCameraCommands(true)     -- a test run uses the game's own camera keys again
    end
end

--- Makes the world view follow the viewport holder; with no argument it re-attaches the last holder (after play mode).
function AttachWorldView(holder)
    released = false
    holder = holder or remembered
    if holder then remembered = holder end        -- the world view may not exist yet at start-up: EnsureWorldView retries
    local view = WorldView()
    if not holder or not view then return end
    attached = holder
    -- The engine moves the camera by itself from polled keys while a view "gets global camera commands" (CUIWorldView::Frame):
    -- Insert / Delete rotate, the arrow keys pan, the screen edge scrolls. The editor's camera is explicit (camera.lua), so all
    -- of that is off while editing.
    view:GetsGlobalCameraCommands(false)
    -- The holder of a hidden viewport tab is parked far off screen (dock.lua HideHolder). The world view must not follow it there: a view whose viewport lies
    -- outside the back buffer makes every D3D call of the frame fail ('DeviceD3D9.cpp Invalid call' thousands of times) and the whole editor stays black for good
    -- (found 2026-10-19: the Console tab next to the viewport in the Generate workspace). While the holder is parked the view keeps its last position.
    local last = { 0, 0, 100, 100 }
    local function Follow(i, v)
        return function()
            local x = v()
            if x > -5000 then last[i] = x end
            return last[i]
        end
    end
    view.Left:Set(Follow(1, function() return holder.Left() end))
    view.Top:Set(Follow(2, function() return holder.Top() end))
    view.Right:Set(Follow(3, function() return holder.Right() end))
    view.Bottom:Set(Follow(4, function() return holder.Bottom() end))
end

--- Called every frame by the shell: attaches the world view once it exists (it is created after the shell at start-up).
function EnsureWorldView()
    if remembered and not released and attached ~= remembered and WorldView() then
        AttachWorldView()
    end
end

Panels.Register{
    id = 'viewport', title = 'Viewport', transparent = true,
    create = function(group, host)
        local P = {}
        local main = (host.frame == GetFrame(0))
        function P:OnResize(w, h)
            if main then AttachWorldView(group) end
        end
        function P:Destroy()
            if main and attached == group then ReleaseWorldView() end
            if remembered == group then remembered = false end
        end
        return P
    end,
}

Panels.Register{
    id = 'outliner', title = 'Outliner',
    create = function(group, host)
        Model.Init()
        local P = { filter = '', shown = {} }
        local function Rebuild()
            P.shown = {}
            local f = string.lower(P.filter)
            for i, it in Model.items do
                if f == '' or string.find(string.lower(it.name), f, 1, true) then P.shown[table.getn(P.shown) + 1] = i end
            end
            if P.list then P.list:Refresh() end
        end
        local field = W.TextField(group, Skin.S(6), Skin.S(6), 100, Skin.S(22), { onChange = function(t) P.filter = t Rebuild() end })
        P.field = field
        P.list = W.VirtualList(group, {
            getCount = function() return table.getn(P.shown) end,
            bind = function(row, index, selected)
                local it = Model.items[P.shown[index]]
                Rows(row, it.name .. '   ' .. it.kind, Skin.color.text)
            end,
            onSelect = function(index) Model.Select(P.shown[index]) end,
            bgColor = Skin.color.panel,
        })
        Rebuild()
        function P:OnResize(w, h)
            local pad = Skin.S(6)
            W.Place(field.frame, group, pad, pad, w - 2 * pad, Skin.S(22))
            field.Width:Set(w - 2 * pad - 2)
            P.list:SetRect(pad, pad * 2 + Skin.S(22), w - 2 * pad, h - pad * 3 - Skin.S(22))
        end
        return P
    end,
}

Panels.Register{
    id = 'properties', title = 'Properties',
    create = function(group, host)
        Model.Init()
        local P = { labels = {} }
        local function Refresh()
            local it = Model.selection and Model.items[Model.selection]
            local vals = it and { it.name, it.kind, string.format('%d, %d', it.x, it.z), tostring(it.team) } or { '-', '-', '-', '-' }
            for i, l in P.labels do l:SetText(vals[i]) end
        end
        local names = { 'Name', 'Kind', 'Position', 'Team' }
        local y = Skin.S(10)
        for i = 1, 4 do
            W.Label(group, names[i], Skin.S(10), y, { color = Skin.color.textDim })
            P.labels[i] = W.Label(group, '-', Skin.S(90), y, {})
            y = y + Skin.S(24)
        end
        W.Label(group, 'Select an item in the outliner.', Skin.S(10), y + Skin.S(8), { color = Skin.color.textDim, size = 'small' })
        Model.OnChange(function(what) if what == 'selection' then pcall(Refresh) end end)
        Refresh()
        return P
    end,
}

Panels.Register{
    id = 'brushes', title = 'Brushes',
    create = function(group, host)
        local P = { buttons = {} }
        local names = { 'Soft round', 'Hard round', 'Peaks', 'Ridge', 'Craters', 'Plateau', 'Rings', 'Sluff' }
        local selected = 1
        for i = 1, table.getn(names) do
            local index = i
            local b = W.Button(group, names[i], 0, 0, Skin.S(90), Skin.S(24), function()
                selected = index
                for j, other in P.buttons do other:SetOn(j == index) end
                Model.Log('brush: ' .. names[index])
            end)
            b:SetOn(i == 1)
            P.buttons[i] = b
        end
        function P:OnResize(w, h)
            local pad, bw, bh = Skin.S(8), Skin.S(90), Skin.S(24)
            local perRow = math.max(1, math.floor((w - pad) / (bw + pad)))
            for i, b in P.buttons do
                local col, row = math.mod(i - 1, perRow), math.floor((i - 1) / perRow)
                W.Place(b, group, pad + col * (bw + pad), pad + row * (bh + pad), bw, bh)
            end
        end
        return P
    end,
}
