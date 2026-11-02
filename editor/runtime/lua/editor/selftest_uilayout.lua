-- Self test of the layout primitives (gui/widgets.lua, gui/dialog.lua, gui/dock.lua): buttons and labels fit their text, Center never goes left of its box, a scrolling panel
-- scrolls sideways when its controls are wider than it, a dialog stays inside a small window and scrolls, the dock keeps a stack as wide as its panels need. The same things
-- the layout check (layoutcheck.lua) looks for in every panel, pinned on small cases that fail without the change.
-- Through /edcmd in an /editor session:  return import('/lua/editor/selftest_uilayout.lua').Run()
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')

local LONG = 'a button text that is much longer than the button it is on'

local function Run1(check)
    local frame = GetFrame(0)
    local holder = Group(frame)
    holder.Left:Set(40) holder.Top:Set(40) holder.Width:Set(Skin.S(240)) holder.Height:Set(Skin.S(300)) holder.Depth:Set(9000)
    local content = W.ScrollContent(holder, nil)
    content.panelId = 'selftest_uilayout'
    local ctx = content.scroll
    local ok, err = pcall(function()
        -- a button fits its text: cut with "...", inside the button, the whole text still finds the tooltip
        local b = W.Button(content, LONG, Skin.S(10), Skin.S(10), Skin.S(70), Skin.S(22), function() end)
        check('a button label is not wider than its button', b.label.Width() <= b.Width(), b.label.Width() .. ' > ' .. b.Width())
        check('a button label starts inside the button', b.label.Left() >= b.Left(), b.label.Left() .. ' < ' .. b.Left())
        check('the cut label ends with ...', string.sub(b.label:GetText(), -3) == '...', b.label:GetText())
        check('the whole text is kept for the tooltip', b.label.fullText == LONG)
        b:SetText('Ok')
        check('a short text is not cut', b.label:GetText() == 'Ok')
        local b2 = W.Button(content, LONG, Skin.S(10), Skin.S(40), Skin.S(70), Skin.S(22), function() end, { nofit = true })
        check('opts.nofit keeps the whole text', b2.label:GetText() == LONG)
        -- Center never moves a label left of its box
        local lab = W.Label(content, LONG, 0, 0, { nofit = true })
        W.Center(lab, b2, 0, 0, b2.Width(), b2.Height())
        check('Center clamps a wide text to the left edge', lab.Left() >= b2.Left(), lab.Left() .. ' < ' .. b2.Left())
        -- a label directly in a scrolling panel is cut to the panel
        ctx:Update()
        local wide = W.Label(content, LONG .. ' ' .. LONG, Skin.S(20), Skin.S(80), {})
        ctx:Update()
        check('a label in a panel is cut to the panel width', wide.Left() + wide.Width() <= holder.Right(), (wide.Left() + wide.Width()) .. ' > ' .. holder.Right())
        local whole = W.Label(content, 'short', Skin.S(20), Skin.S(100), {})
        check('a short label is not cut', whole:GetText() == 'short')
        -- the panel gets narrower: the label is cut again
        holder.Width:Set(Skin.S(120))
        ctx:Update()
        check('a label is cut again when the panel gets narrower', wide.Left() + wide.Width() <= holder.Right(), (wide.Left() + wide.Width()) .. ' > ' .. holder.Right())
        holder.Width:Set(Skin.S(240))
        ctx:Update()
        -- a control wider than the panel: the panel scrolls sideways and the control can be brought in
        local bar = import('/lua/maui/bitmap.lua').Bitmap(content)
        bar:SetSolidColor('ff808080')
        W.Place(bar, content, Skin.S(100), Skin.S(160), Skin.S(150), Skin.S(22))
        ctx:Update()
        check('a control wider than the panel makes it scroll sideways', ctx.maxOffX > 0, ctx.maxOffX)
        check('the wide control is parked while it does not fit', bar.Left() < 0 or bar.Right() > holder.Right() + Skin.S(8))
        ctx:ScrollX(Skin.S(100))
        check('the wide control is shown at the end of the sideways scroll', bar.Right() <= holder.Right() + Skin.S(8) and bar.Left() >= holder.Left() - Skin.S(8), bar.Left() .. ',' .. bar.Right())
        ctx:ScrollX(-Skin.S(1000))
        check('the sideways scroll is clamped', ctx.offX == 0)
        -- a control that is tall: the vertical scroll still works
        local tall = import('/lua/maui/bitmap.lua').Bitmap(content)
        tall:SetSolidColor('ff808080')
        W.Place(tall, content, Skin.S(10), Skin.S(900), Skin.S(60), Skin.S(22))
        ctx:Update()
        check('a tall content scrolls up and down', ctx.maxOff > 0)
    end)
    if not ok then check('the panel part ran', false, err) end
    W.ScrollRelease(content)
    holder:Destroy()

    -- the dialog: clamped to the window, scrollable, built on the same widgets
    local fw, fh = frame.Width(), frame.Height()
    local d = Dialog.Open('A very long dialog title that goes on and on and on and on and on and on and on and on and on and on and on and on and on', 3000, 3000)
    local okD, errD = pcall(function()
        local r = Dialog.Rect()
        check('a huge dialog is clamped to the window', r.l >= 0 and r.t >= 0 and r.r <= fw and r.b <= fh, r.l .. ',' .. r.t .. ',' .. r.r .. ',' .. r.b .. ' in ' .. fw .. 'x' .. fh)
        d:Button('Far', 2800, 2800, 100, 26, function() end)
        d:Field(10, 40, 5000, 22, {})
        local label = d:Label(LONG .. LONG .. LONG .. LONG .. LONG, 14, 80, {})
        d.group.scroll:Update()
        check('a dialog scrolls what is outside its box', d.group.scroll.maxOff > 0 or d.group.scroll.maxOffX > 0)
        check('a dialog label is cut to the box', label.Left() + label.Width() <= r.r, label.Left() + label.Width() .. ' > ' .. r.r)
        local items, row = {}, nil
        for i = 1, 4 do items[i] = { d:Button('B' .. i, 0, 0, 400, 24, function() end), 400 } end
        local bottom = d:Flow(items, 200, 24)
        check('Flow wraps buttons that do not fit the box into rows', bottom > 200 + 24, bottom)
    end)
    if not okD then check('the dialog part ran', false, errD) end
    Dialog.Close()
    check('the dialog is closed', not Dialog.IsOpen())

    -- the dock: a stack is not narrower than its panels declare
    local Panels = import('/lua/editor/gui/panels.lua')
    check('panels without a minimum have a default one', Panels.DEFAULT_MIN_W ~= nil and Panels.DEFAULT_MIN_W > 120)
    local id = 'selftest_uilayout_probe'
    Panels.Register{ id = id, title = 'Probe', minW = 300, create = function(group) return {} end }
    Panels.Register{ id = id .. '2', title = 'Probe 2', create = function(group) return {} end }
    local Dock = import('/lua/editor/gui/dock.lua')
    local host = Dock.NewHost(frame, {})
    host:SetRect(0, 0, Skin.S(900), Skin.S(300))
    host:SetTree({ kind = 'split', dir = 'row', ratio = 0.05, a = { kind = 'stack', tabs = { id }, active = 1 }, b = { kind = 'stack', tabs = { id .. '2' }, active = 1 } })
    check('a stack is as wide as its panel declares', host.tree.a.rect[3] >= Skin.S(300), host.tree.a.rect[3])
    host:Destroy()
    Panels.registry[id] = nil
    Panels.registry[id .. '2'] = nil
    local keep = {}
    for _, v in Panels.order do if v ~= id and v ~= id .. '2' then table.insert(keep, v) end end
    Panels.order = keep
end

function Run()
    local fails, checks = {}, 0
    local function check(name, ok, detail)
        checks = checks + 1
        if not ok then table.insert(fails, name .. (detail and (' (' .. tostring(detail) .. ')') or '')) end
    end
    local ok, err = pcall(Run1, check)
    if not ok then table.insert(fails, 'error: ' .. tostring(err)) end
    if table.getn(fails) == 0 then return 'PASS ui layout (' .. checks .. ' checks)' end
    return 'FAIL ui layout: ' .. table.concat(fails, '; ')
end
