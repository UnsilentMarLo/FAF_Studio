-- Docking host: a tree of splits and tab stacks inside one Maui root frame (the main window or a pop-out window).
--
--   Tree nodes   { kind = 'stack', tabs = { 'outliner', 'properties' }, active = 1 }
--                { kind = 'split', dir = 'row' | 'col', ratio = 0.25, a = node, b = node }
--                ('row' puts a and b side by side, 'col' puts a above b; ratio is a's share)
--
--   host = Dock.NewHost(frame, { OnDragOut = function(panelId, screenX, screenY, host) end, OnChange = function(host) end })
--   host:SetRect(x, y, w, h)        host area inside the frame (frame coordinates)
--   host:SetTree(tree)              build chrome and panels from a tree (copied by reference)
--   host:Layout()                   re-place everything after a size or ratio change (no controls are created)
--   host:Remove(panelId)            take a panel out of the tree (collapses empty stacks)
--   host:AddPanel(panelId)          append to the first stack
--   host:Destroy()
--
-- Panels live in holder groups that belong to the host, not to a stack, so rebuilding the chrome (after a drop) never destroys
-- panel controls. Tabs can be dragged: onto a stack's middle or tab bar (join its tabs), onto an edge (split), or out of the host
-- (OnDragOut, the shell turns it into a pop-out window).

local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local Skin = import('/lua/editor/gui/skin.lua')
local Cursors = import('/lua/editor/cursors.lua')
local W = import('/lua/editor/gui/widgets.lua')
local Panels = import('/lua/editor/gui/panels.lua')

-- ---- tree helpers ----------------------------------------------------------------------------------------------------

local function Walk(node, fn)
    if not node then return end
    fn(node)
    if node.kind == 'split' then
        Walk(node.a, fn)
        Walk(node.b, fn)
    end
end

function FindStack(tree, panelId)
    local found
    Walk(tree, function(n)
        if n.kind == 'stack' and not found then
            for _, id in n.tabs do
                if id == panelId then found = n end
            end
        end
    end)
    return found
end

function FindStackNode(tree, node)
    local found
    Walk(tree, function(n) if n == node then found = n end end)
    return found
end

local function ParentOf(tree, target)
    local parent
    Walk(tree, function(n)
        if n.kind == 'split' and (n.a == target or n.b == target) then parent = n end
    end)
    return parent
end

--- Removes a panel from the tree; empty stacks disappear and their split collapses into the sibling. Returns the new root.
function RemovePanel(tree, panelId)
    local stack = FindStack(tree, panelId)
    if not stack then return tree end
    local kept = {}
    for _, id in stack.tabs do
        if id ~= panelId then kept[table.getn(kept) + 1] = id end
    end
    stack.tabs = kept
    if stack.active > table.getn(kept) then stack.active = math.max(1, table.getn(kept)) end
    if table.getn(kept) > 0 then return tree end
    local parent = ParentOf(tree, stack)
    if not parent then return nil end   -- last stack of the host
    local sibling = parent.a
    if parent.a == stack then sibling = parent.b end
    local grand = ParentOf(tree, parent)
    if not grand then return sibling end
    if grand.a == parent then grand.a = sibling else grand.b = sibling end
    return tree
end

--- Docks `panelId` relative to `target` (a stack). zone: 'tabs' joins the stack, 'left' | 'right' | 'top' | 'bottom' splits it.
function DockPanel(tree, panelId, target, zone)
    if zone == 'tabs' then
        target.tabs[table.getn(target.tabs) + 1] = panelId
        target.active = table.getn(target.tabs)
        return tree
    end
    local fresh = { kind = 'stack', tabs = { panelId }, active = 1 }
    local copy = { kind = 'stack', tabs = target.tabs, active = target.active }
    local dir = (zone == 'left' or zone == 'right') and 'row' or 'col'
    local first, second = fresh, copy
    if zone == 'right' or zone == 'bottom' then first, second = copy, fresh end
    -- the target node is turned into the split in place so its parent keeps pointing at it
    target.kind, target.dir, target.ratio, target.a, target.b = 'split', dir, 0.5, first, second
    target.tabs, target.active = nil, nil
    return tree
end

-- ---- host ------------------------------------------------------------------------------------------------------------

function NewHost(frame, ctx)
    ctx = ctx or {}
    local H = { frame = frame, ctx = ctx, tree = nil, x = 0, y = 0, w = 100, h = 100, instances = {}, holders = {}, contents = {} }
    H.root = Group(frame)
    H.root.Depth:Set(5000)
    H.root.Left:Set(0) H.root.Top:Set(0) H.root.Width:Set(100) H.root.Height:Set(100)
    H.root:DisableHitTest()   -- containers must not swallow clicks: an unhandled event never falls through to the world view below

    local function Changed()
        if ctx.OnChange then ctx.OnChange(H) end
    end

    -- ---- panel instances -------------------------------------------------------------------------------------------
    function H:EnsureInstance(id)
        if self.instances[id] then return self.instances[id] end
        local def = Panels.Get(id)
        if not def then return nil end
        local holder = Group(self.root)
        if def.transparent then holder:DisableHitTest() end   -- the viewport hole must let the mouse through to the world
        holder.Depth:Set(function() return self.root.Depth() + 10 end)
        holder.Left:Set(0) holder.Top:Set(0) holder.Width:Set(10) holder.Height:Set(10)
        self.holders[id] = holder
        -- the panel builds its controls in a content group that scrolls inside the holder (the viewport hole has nothing to scroll)
        local group = holder
        if not def.transparent then
            group = W.ScrollContent(holder, id)
            self.contents[id] = group
        end
        local ok, inst = pcall(def.create, group, self)
        if not ok then
            LOG('EDITOR gui: panel ' .. tostring(id) .. ' failed: ' .. tostring(inst))
            inst = {}
        end
        self.instances[id] = inst or {}
        return self.instances[id]
    end

    local function HideHolder(id)
        local holder = H.holders[id]
        if holder then
            -- Hide() alone is not enough: panels that refresh themselves show their controls again (Maui shows a child that is
            -- shown explicitly even under a hidden parent), so the holder also leaves the screen, and everything in it with it.
            holder.Left:Set(-20000)
            holder.Top:Set(-20000)
        end
    end

    function H:PlaceHolder(id, x, y, w, h)
        -- a panel that lays all its controls out when it is created (rebuildOnResize) is created again at its new size
        local def = Panels.Get(id)
        local existing = self.instances[id]
        if existing and def and def.rebuildOnResize and existing.sizedH ~= nil and (existing.sizedW ~= w or existing.sizedH ~= h) then
            self:DropInstance(id)
        end
        self:EnsureInstance(id)
        local holder = self.holders[id]
        if not holder then return end
        W.Place(holder, self.root, x, y, w, h)
        local inst = self.instances[id]
        -- a panel is only told when its size really changed: switching tabs or re-laying the dock out must not rebuild its controls
        -- (scroll positions, edited text and selections would be lost)
        if inst and inst.OnResize and (inst.sizedW ~= w or inst.sizedH ~= h) then
            inst.sizedW, inst.sizedH = w, h
            -- A panel that scrolls gets an overlay bar on its right edge (widgets.lua ScrollContent). The panel is told it is that much narrower, so sliders, value fields
            -- and buttons that end at its right edge stay clear of the bar (they ran under it, hiding the right border of the fields). The space is always kept, not only
            -- while the bar shows: the layout must not jump when the content grows past the panel.
            local pw = w
            if self.contents[id] then pw = math.max(Skin.S(60), w - Skin.S(Skin.size.scrollW) - Skin.S(2)) end
            local ok, err = pcall(inst.OnResize, inst, pw, h)
            if not ok then LOG('EDITOR gui: panel ' .. tostring(id) .. ' resize failed: ' .. tostring(err)) end
        end
        -- what does not fit the panel scrolls: measure the content and set up the bar
        if self.contents[id] then W.EndLayout(self.contents[id]) end
    end

    function H:DropInstance(id)
        local inst = self.instances[id]
        if inst and inst.Destroy then pcall(inst.Destroy, inst) end
        -- the panel modules keep their last instance (`live.x = P`) and tick its Refresh: on destroyed controls that failed four times a second
        -- (the Properties panel logged 'Game object has been destroyed' without end), so a dropped instance stops refreshing
        if inst then inst.Refresh = function() end inst.dead = true end
        if self.contents[id] then W.ScrollRelease(self.contents[id]) end
        if self.holders[id] then self.holders[id]:Destroy() end
        self.instances[id] = nil
        self.holders[id] = nil
        self.contents[id] = nil
    end

    -- ---- geometry --------------------------------------------------------------------------------------------------
    local function MinW() return Skin.S(120) end
    local function MinH() return Skin.S(60) end

    local function Compute(node, x, y, w, h)
        node.rect = { x, y, w, h }
        if node.kind ~= 'split' then return end
        local gap = Skin.S(Skin.size.splitter)
        if node.dir == 'row' then
            local aw = math.floor((w - gap) * node.ratio)
            aw = math.max(MinW(), math.min(w - gap - MinW(), aw))
            node.gap = { x + aw, y, gap, h }
            Compute(node.a, x, y, aw, h)
            Compute(node.b, x + aw + gap, y, w - aw - gap, h)
        else
            local ah = math.floor((h - gap) * node.ratio)
            ah = math.max(MinH(), math.min(h - gap - MinH(), ah))
            node.gap = { x, y + ah, w, gap }
            Compute(node.a, x, y, w, ah)
            Compute(node.b, x, y + ah + gap, w, h - ah - gap)
        end
    end

    -- ---- chrome ----------------------------------------------------------------------------------------------------
    local function TabHeight() return Skin.S(Skin.size.tabH) end

    local function SelectTab(stack, i)
        stack.active = i
        H:Layout()
        Changed()
    end

    -- zone under the cursor for a drop (frame coordinates); returns stack, zone
    local function DropTarget(mx, my)
        local best, zone
        Walk(H.tree, function(n)
            if n.kind == 'stack' and n.rect then
                local r = n.rect
                if mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4] then
                    best = n
                    local fx, fy = (mx - r[1]) / r[3], (my - r[2]) / r[4]
                    if my < r[2] + TabHeight() then zone = 'tabs'
                    elseif fx < 0.25 then zone = 'left'
                    elseif fx > 0.75 then zone = 'right'
                    elseif fy < 0.25 then zone = 'top'
                    elseif fy > 0.75 then zone = 'bottom'
                    else zone = 'tabs' end
                end
            end
        end)
        return best, zone
    end

    local function ZoneRect(stack, zone)
        local r = stack.rect
        if zone == 'left' then return r[1], r[2], math.floor(r[3] / 2), r[4] end
        if zone == 'right' then return r[1] + math.floor(r[3] / 2), r[2], math.ceil(r[3] / 2), r[4] end
        if zone == 'top' then return r[1], r[2], r[3], math.floor(r[4] / 2) end
        if zone == 'bottom' then return r[1], r[2] + math.floor(r[4] / 2), r[3], math.ceil(r[4] / 2) end
        return r[1], r[2], r[3], r[4]
    end

    local function StartTabDrag(stack, panelId, event)
        local startX, startY = event.MouseX, event.MouseY
        local drag = Dragger()
        local moved = false
        local ghost
        drag.OnMove = function(d, mx, my)
            if not moved and math.abs(mx - startX) + math.abs(my - startY) < Skin.S(6) then return end
            moved = true
            if not H.dropPreview then
                H.dropPreview = Bitmap(H.chrome)
                H.dropPreview:SetSolidColor(Skin.color.drop)
                H.dropPreview.Depth:Set(function() return H.root.Depth() + 60 end)
                H.dropPreview:DisableHitTest()
            end
            local inside = mx >= H.x and mx < H.x + H.w and my >= H.y and my < H.y + H.h
            if inside then
                local target, zone = DropTarget(mx, my)
                if target then
                    local zx, zy, zw, zh = ZoneRect(target, zone)
                    W.Place(H.dropPreview, H.root, zx - H.x, zy - H.y, zw, zh)
                    H.dropPreview:Show()
                    d.target, d.zone = target, zone
                    return
                end
            end
            d.target, d.zone = nil, nil
            H.dropPreview:Hide()
        end
        drag.OnRelease = function(d, mx, my)
            if H.dropPreview then H.dropPreview:Hide() end
            local target, zone = d.target, d.zone
            d:Destroy()
            if not moved then return end
            local inside = mx >= H.x and mx < H.x + H.w and my >= H.y and my < H.y + H.h
            if inside and target then
                if zone == 'tabs' and target == stack then return end
                if zone ~= 'tabs' and target == stack and table.getn(stack.tabs) == 1 then return end
                H.tree = RemovePanel(H.tree, panelId)
                -- the target may have been collapsed away only if it was the source's own empty stack; re-find it
                local live = target
                if not FindStackNode(H.tree, live) then live = H.tree end
                if live then H.tree = DockPanel(H.tree, panelId, live, zone) else H.tree = { kind = 'stack', tabs = { panelId }, active = 1 } end
                H:Rebuild()
                Changed()
            elseif not inside and ctx.OnDragOut then
                ctx.OnDragOut(panelId, mx, my, H)
            end
        end
        drag.OnCancel = function(d)
            if H.dropPreview then H.dropPreview:Hide() end
            d:Destroy()
        end
        PostDragger(frame, event.KeyCode, drag)
    end

    local function BuildStack(node)
        local c = Skin.color
        local ui = {}
        node.ui = ui
        ui.group = Group(H.chrome)
        ui.group:DisableHitTest()   -- its children (background, tabs) take events themselves
        ui.group.Depth:Set(function() return H.root.Depth() + 1 end)
        ui.group.Left:Set(0) ui.group.Top:Set(0) ui.group.Width:Set(10) ui.group.Height:Set(10)
        -- siblings share a depth by default and the first created wins: stack bg < header < tabs explicitly
        ui.bg = Bitmap(ui.group)
        ui.bg.Depth:Set(function() return ui.group.Depth() + 1 end)
        ui.bg:SetSolidColor(c.panel)
        ui.bg.Left:Set(function() return ui.group.Left() end)
        ui.bg.Top:Set(function() return ui.group.Top() end)
        ui.bg.Right:Set(function() return ui.group.Right() end)
        ui.bg.Bottom:Set(function() return ui.group.Bottom() end)
        ui.header = Bitmap(ui.group)
        ui.header.Depth:Set(function() return ui.group.Depth() + 2 end)
        ui.header:SetSolidColor(c.header)
        ui.tabs = {}
        for i = 1, table.getn(node.tabs) do
            local panelId = node.tabs[i]
            local tab = Bitmap(ui.group)
            tab.Depth:Set(function() return ui.group.Depth() + 3 end)
            tab.label = W.Label(tab, Panels.Title(panelId), 0, 0, {})
            tab.panelId = panelId
            local index = i
            tab.hot = false
            tab.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then
                    self.hot = true
                    H:StyleTabs(node)
                    pcall(function()
                        import('/lua/editor/gui/tooltip.lua').Hover(self, function() return import('/lua/editor/tooltips.lua').ForPanel(panelId) end, event)
                    end)
                    return true
                elseif event.Type == 'MouseExit' then
                    self.hot = false
                    H:StyleTabs(node)
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Leave(self) end)
                    return true
                elseif event.Type == 'ButtonPress' then
                    pcall(function() import('/lua/editor/gui/tooltip.lua').Hide() end)
                    if node.active ~= index then SelectTab(node, index) end
                    StartTabDrag(node, panelId, event)
                    return true
                end
                return false
            end
            ui.tabs[i] = tab
        end
        -- the overflow button: a stack with more tabs than its header holds shows the ones around the active tab and this ">>" opens a menu of all of them
        local more = Bitmap(ui.group)
        more.Depth:Set(function() return ui.group.Depth() + 4 end)
        more:SetSolidColor(c.tabOff)
        more.label = W.Label(more, '>>', 0, 0, {})
        more.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then self:SetSolidColor(c.tabHover) return true
            elseif event.Type == 'MouseExit' then self:SetSolidColor(c.tabOff) return true
            elseif event.Type == 'ButtonPress' then
                local Menu = import('/lua/editor/gui/menu.lua')
                local items = {}
                for i = 1, table.getn(node.tabs) do
                    local index = i
                    local id = node.tabs[i]
                    table.insert(items, { title = Panels.Title(id), checked = (index == node.active), nokeys = true, run = function() SelectTab(node, index) end })
                end
                Menu.Show(GetFrame(0), self.Left(), self.Bottom(), items)
                return true
            end
            return false
        end
        ui.more = more
        W.Place(more, ui.group, -20000, -20000, 10, 10)
        more:Hide()
        return ui
    end

    function H:StyleTabs(node)
        local c = Skin.color
        for i, tab in node.ui.tabs do
            local on = (i == node.active)
            local col = on and c.tabOn or (tab.hot and c.tabHover or c.tabOff)
            tab:SetSolidColor(col)
            tab.label:SetColor(on and c.text or c.textDim)
        end
    end

    local function BuildNode(node)
        if node.kind == 'stack' then
            BuildStack(node)
        else
            local c = Skin.color
            local s = Bitmap(H.chrome)
            s:SetSolidColor(c.window)
            s.Depth:Set(function() return H.root.Depth() + 3 end)
            node.splitter = s
            s.HandleEvent = function(self, event)
                if event.Type == 'MouseEnter' then
                    self:SetSolidColor(c.accent)
                    Cursors.Use(node.dir == 'row' and 'size_ew' or 'size_ns')      -- resize arrows over the splitter
                    return true
                elseif event.Type == 'MouseExit' then
                    self:SetSolidColor(c.window)
                    Cursors.ResetDefault()
                    return true
                elseif event.Type == 'ButtonPress' then
                    local drag = Dragger()
                    drag.OnMove = function(d, mx, my)
                        local r = node.rect
                        local gap = Skin.S(Skin.size.splitter)
                        if node.dir == 'row' then
                            node.ratio = math.max(0.05, math.min(0.95, (mx - r[1] - gap / 2) / math.max(1, r[3] - gap)))
                        else
                            node.ratio = math.max(0.05, math.min(0.95, (my - r[2] - gap / 2) / math.max(1, r[4] - gap)))
                        end
                        H:Layout()
                    end
                    drag.OnRelease = function(d) d:Destroy() Changed() end
                    drag.OnCancel = function(d) d:Destroy() end
                    PostDragger(frame, event.KeyCode, drag)
                    return true
                end
                return false
            end
            BuildNode(node.a)
            BuildNode(node.b)
        end
    end

    local function PlaceNode(node)
        if node.kind == 'split' then
            local g = node.gap
            W.Place(node.splitter, H.root, g[1] - H.x, g[2] - H.y, g[3], g[4])
            PlaceNode(node.a)
            PlaceNode(node.b)
            return
        end
        local r, ui = node.rect, node.ui
        local pad, th = Skin.S(Skin.size.pad), TabHeight()
        local activeId = node.tabs[node.active]
        local def = activeId and Panels.Get(activeId)
        local transparent = def and def.transparent
        W.Place(ui.group, H.root, r[1] - H.x, r[2] - H.y, r[3], r[4])
        if transparent then
            ui.bg:Hide()
            ui.header:Hide()
            W.Place(ui.header, ui.group, 0, 0, 1, 1)
            for _, t in ui.tabs do
                W.Place(t, ui.group, 0, 0, 1, 1)   -- keep every control's layout defined even when hidden
                t:Hide()
            end
            ui.more:Hide()
        else
            ui.bg:Show()
            ui.header:Show()
            W.Place(ui.header, ui.group, 0, 0, r[3], th)
            -- which tabs fit: all of them, or a window of them that holds the active tab (the rest sit behind the ">>" menu)
            local widths, total = {}, 0
            for i, tab in ui.tabs do
                widths[i] = tab.label.Width() + 2 * pad + Skin.S(4)
                total = total + widths[i] + 1
            end
            local count = table.getn(ui.tabs)
            local first, last = 1, count
            local moreW = Skin.S(30)
            if total > r[3] then
                local avail = r[3] - moreW
                first = math.max(1, math.min(node.firstTab or 1, count))
                if node.active and node.active < first then first = node.active end
                local function Fit(from)
                    local used, to = 0, from - 1
                    for i = from, count do
                        if used + widths[i] + 1 > avail and i > from then break end
                        used = used + widths[i] + 1
                        to = i
                    end
                    return to
                end
                last = Fit(first)
                while node.active and node.active > last and first < count do
                    first = first + 1
                    last = Fit(first)
                end
                node.firstTab = first
            else
                node.firstTab = 1
            end
            local tx = 0
            for i, loopTab in ui.tabs do
                local tab = loopTab    -- closures share the loop variable (nil after the loop): the lazy vars need their own copy
                if i >= first and i <= last then
                    tab:Show()
                    local tw = widths[i]
                    W.Place(tab, ui.group, tx, 0, tw, th)
                    local ly = math.floor((th - tab.label.Height()) / 2)
                    local lx = pad + Skin.S(2)
                    tab.label.Left:Set(function() return tab.Left() + lx end)
                    tab.label.Top:Set(function() return tab.Top() + ly end)
                    tx = tx + tw + 1
                else
                    W.Place(tab, ui.group, -20000, -20000, widths[i], th)      -- outside the visible window: parked off screen
                    tab.label.Left:Set(function() return tab.Left() end)
                    tab.label.Top:Set(function() return tab.Top() end)
                end
            end
            if first > 1 or last < count then
                ui.more:Show()
                W.Place(ui.more, ui.group, r[3] - moreW, 0, moreW, th)
                local mly = math.floor((th - ui.more.label.Height()) / 2)
                local mlx = math.floor((moreW - ui.more.label.Width()) / 2)
                ui.more.label.Left:Set(function() return ui.more.Left() + mlx end)
                ui.more.label.Top:Set(function() return ui.more.Top() + mly end)
            else
                ui.more:Hide()
                W.Place(ui.more, ui.group, -20000, -20000, moreW, th)
            end
            H:StyleTabs(node)
        end
        for i, id in node.tabs do
            if i == node.active then
                if transparent then
                    H:PlaceHolder(id, r[1] - H.x, r[2] - H.y, r[3], r[4])
                else
                    H:PlaceHolder(id, r[1] - H.x, r[2] - H.y + th, r[3], r[4] - th)
                end
            else
                HideHolder(id)
            end
        end
    end

    function H:Layout()
        if not self.tree then return end
        Compute(self.tree, self.x, self.y, self.w, self.h)
        PlaceNode(self.tree)
    end

    function H:Rebuild()
        if self.chrome then self.chrome:Destroy() end
        self.dropPreview = nil
        self.chrome = Group(self.root)
        self.chrome:DisableHitTest()
        self.chrome.Depth:Set(function() return self.root.Depth() + 1 end)
        self.chrome.Left:Set(function() return self.root.Left() end)
        self.chrome.Top:Set(function() return self.root.Top() end)
        self.chrome.Width:Set(function() return self.root.Width() end)
        self.chrome.Height:Set(function() return self.root.Height() end)
        -- panels no longer in the tree lose their controls
        local present = {}
        Walk(self.tree, function(n)
            if n.kind == 'stack' then for _, id in n.tabs do present[id] = true end end
        end)
        for id, _ in self.instances do
            if not present[id] then self:DropInstance(id) end
        end
        if self.tree then BuildNode(self.tree) end
        self:Layout()
    end

    function H:SetRect(x, y, w, h)
        self.x, self.y, self.w, self.h = x, y, w, h
        self.root.Left:Set(x) self.root.Top:Set(y) self.root.Width:Set(w) self.root.Height:Set(h)
        self:Layout()
    end

    function H:SetTree(tree)
        self.tree = tree
        self:Rebuild()
    end

    function H:Remove(panelId)
        self.tree = RemovePanel(self.tree, panelId)
        self:DropInstance(panelId)
        self:Rebuild()
        Changed()
    end

    function H:AddPanel(panelId)
        if FindStack(self.tree, panelId) then return end
        local first
        Walk(self.tree, function(n) if n.kind == 'stack' and not first then first = n end end)
        if first then
            first.tabs[table.getn(first.tabs) + 1] = panelId
            first.active = table.getn(first.tabs)
        else
            self.tree = { kind = 'stack', tabs = { panelId }, active = 1 }
        end
        self:Rebuild()
        Changed()
    end

    --- Brings a panel to the front of its tab stack (adds it to the first stack when the layout does not contain it).
    function H:ShowPanel(panelId)
        local stack = FindStack(self.tree, panelId)
        if not stack then
            self:AddPanel(panelId)
            return true
        end
        for i, id in stack.tabs do
            if id == panelId then stack.active = i end
        end
        self:Layout()
        Changed()
        return true
    end

    function H:Panels()
        local list = {}
        Walk(self.tree, function(n)
            if n.kind == 'stack' then for _, id in n.tabs do list[table.getn(list) + 1] = id end end
        end)
        return list
    end

    function H:Destroy()
        for id, _ in self.instances do self:DropInstance(id) end
        self.root:Destroy()
    end

    return H
end
