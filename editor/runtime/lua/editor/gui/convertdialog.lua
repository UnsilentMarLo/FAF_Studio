-- The Convert layers dialog (Layers panel and shader browser): shows what converting the layers of the map to another terrain shader does (stratumconv.lua), asks what to do with paint the target cannot
-- draw (layer 8) and with the Upper layer, converts in ONE undo step and then reports what was done and what needs a look.
--
--   Open(targetId, done)       done(report) after a conversion
--
-- Layout: the text (what the conversion does, what needs attention; later the report) is a scrolling TextView at the top, measured with the real font; the options (choices, slider, toggle) form a fixed
-- block under it and the buttons sit at the bottom edge, so the content never leaves the dialog. The dialog is clamped to the window.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local TextView = import('/lua/editor/gui/textview.lua')
local Conv = import('/lua/editor/stratumconv.lua')

last = false      -- the open dialog's state: for the self test

local CHARS = 95         -- characters of small text per line at the full width (only used to pick the dialog height; the text view measures for real)
local TOP = 36           -- the text starts here (logical pixels, below the title)
local BUTTON_H = 28

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local function Lines(texts)
    local n = 0
    for _, t in texts do n = n + math.max(1, math.ceil(string.len(t) / CHARS)) end
    return n
end

local function DestroySlider(s)
    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do part:Destroy() end
    s.field:Destroy()
    if s.field.frame then s.field.frame:Destroy() end
end

--- The report as sections: { { title, color, items = { text, ... } }, ... }. `done` lines are "Changed", `warn` lines "Needs your attention", `file` lines (and a
--- report.files list) "Created files", any other kind a section of its own.
local function Sections(report, c)
    local order, byTitle = {}, {}
    local function Section(title, color)
        if not byTitle[title] then
            byTitle[title] = { title = title, color = color, items = {} }
            table.insert(order, byTitle[title])
        end
        return byTitle[title]
    end
    local changed, attention = Section('Changed', c.text), nil
    for _, l in report.lines or {} do
        if l.kind == 'warn' then
            attention = attention or Section('Needs your attention', c.warn)
            table.insert(attention.items, l.text)
        elseif l.kind == 'file' then
            table.insert(Section('Created files', c.text).items, l.text)
        elseif l.kind == 'done' or l.kind == nil then
            table.insert(changed.items, l.text)
        else
            table.insert(Section(string.upper(string.sub(l.kind, 1, 1)) .. string.sub(l.kind, 2), c.text).items, l.text)
        end
    end
    for _, f in report.files or {} do
        table.insert(Section('Created files', c.text).items, type(f) == 'table' and (f.text or f.path or tostring(f)) or tostring(f))
    end
    -- the order is Changed, Needs your attention, then the rest
    local out = {}
    for _, name in { 'Changed', 'Needs your attention' } do
        if byTitle[name] and table.getn(byTitle[name].items) > 0 then table.insert(out, byTitle[name]) end
    end
    for _, sec in order do
        if sec.title ~= 'Changed' and sec.title ~= 'Needs your attention' and table.getn(sec.items) > 0 then table.insert(out, sec) end
    end
    return out
end

function Open(targetId, done)
    local plan = Conv.Plan(targetId)
    local c = Skin.color
    local frame = GetFrame(0)
    local WIDTH = math.max(520, math.min(700, math.floor(frame.Width() / Skin.scale) - 40))
    local maxHeight = math.max(320, math.floor(frame.Height() / Skin.scale) - 60)
    local INNER = WIDTH - 28
    local K = plan.refused == nil and plan.toP and plan.toP.painted or 0
    local hasExtra = plan.refused == nil and table.getn(plan.extra) > 0
    local hasUpper = plan.refused == nil and plan.upperAction and not (plan.upperAction == 'atlas' and plan.atlasMissing)

    -- sizes: the options block under the text has a known height; the text gets the rest
    local CHOICES = { { 'move', 'Move to a free layer', 170 }, { 'merge', 'Merge into one layer', 170 }, { 'drop', 'Drop the paint', 140 } }
    local choiceItems = {}
    for _, ch in CHOICES do table.insert(choiceItems, { false, ch[3] }) end
    local choiceH = math.ceil(W.Flow(nil, choiceItems, 0, 0, Skin.S(INNER), Skin.S(24), Skin.S(6), true) / Skin.scale)
    local optH = 0
    if hasExtra then optH = optH + 22 + choiceH + 8 + 44 + 10 end
    if hasUpper then optH = optH + 24 + 10 end
    local texts = {}
    if plan.refused then
        table.insert(texts, plan.refused)
    else
        for _, t in plan.lines do table.insert(texts, t) end
        for _, t in plan.warnings do table.insert(texts, t) end
    end
    local textH = 40 + 17 * Lines(texts) + 8 * table.getn(texts)
    local height = math.max(260, math.min(maxHeight, 130 + optH + textH))
    local buttonsY = height - 40
    local d = Dialog.Open('Convert layers to ' .. tostring(targetId) .. '  (one undo step)', WIDTH, height)
    local state = { plan = plan, dyn = {}, sliders = {}, choice = plan.default, mergeInto = 1, upper = true, dialog = d, width = WIDTH, height = height }
    last = state

    local view = TextView.New(d, 14, TOP, INNER, buttonsY - 8 - optH - TOP)
    state.view = view

    local function Keep(ctl)
        table.insert(state.dyn, ctl)
        return ctl
    end
    local function Clear()
        for _, s in state.sliders do DestroySlider(s) end
        state.sliders = {}
        for _, ctl in state.dyn do ctl:Destroy() end
        state.dyn = {}
        view:Clear()
    end
    local function CloseButton()
        Keep(d:Button('Close', 14, buttonsY, 100, BUTTON_H, function() Dialog.Close() end, { tip = 'Close this window.' }))
    end

    --- Controls that exist now, for the layout self test.
    function state.controls()
        local out = {}
        for _, ctl in state.dyn do
            table.insert(out, ctl)
            if ctl.label then table.insert(out, ctl.label) end
        end
        for _, s in state.sliders do
            for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus, s.field, s.field.frame } do table.insert(out, part) end
        end
        for _, ctl in view:Controls() do table.insert(out, ctl) end
        return out
    end

    if plan.refused then
        view:Text('Cannot convert: ' .. plan.refused .. '.', { color = c.warn, size = 'text' })
        view:Show()
        CloseButton()
        return state
    end

    local choiceButtons = {}
    local function ShowChoice()
        for id, b in choiceButtons do b:SetOn(state.choice == id) end
    end

    local function Build()
        Clear()
        local viewH = buttonsY - 8 - optH - TOP
        view:SetRect(14, TOP, INNER, viewH)
        view:Heading('What the conversion does', { before = 0 })
        for _, t in plan.lines do view:Bullet(t) end
        if table.getn(plan.warnings) > 0 then
            view:Heading('Needs your attention', { color = c.warn })
            for _, t in plan.warnings do view:Bullet(t, { color = c.warn }) end
        end
        view:Show()

        -- the options: a fixed block from y0 down to the buttons
        local y = buttonsY - 8 - optH + 8
        if hasExtra then
            Keep(d:Label('Paint the new shader cannot draw', 14, y, { color = c.textDim }))
            y = y + 22
            local buttons = {}
            for _, ch in CHOICES do
                local id, label, bw = ch[1], ch[2], ch[3]
                local enabled = (id ~= 'move') or plan.canMove
                local tip = (id == 'move') and 'Layers without paint make room: the painted layers keep their order and move down to fill the free slots, with their textures. Nothing is lost.'
                    or (id == 'merge') and 'Add the paint to another layer: it shows that layer\'s texture there.'
                    or 'Remove the paint of the layers the new shader cannot draw.'
                local b = Keep(d:Button(label, 14, y, bw, 24, function()
                    if not enabled then
                        Say('not enough layers without paint to make room: merge it into a layer or drop it')
                    else
                        state.choice = id
                    end
                    ShowChoice()
                end, { toggle = true, tip = tip }))
                if not enabled then b.label:SetColor(c.textDim) end
                choiceButtons[id] = b
                table.insert(buttons, { b, bw })
            end
            local after = W.Flow(d.group, buttons, Skin.S(14), Skin.S(y), Skin.S(INNER), Skin.S(24), Skin.S(6))
            ShowChoice()
            y = math.ceil(after / Skin.scale) + 8
            local s = W.Slider(d.group, { label = 'Merge into layer (when merging)', min = 1, max = K, step = 1, fmt = '%d', compact = true,
                tip = 'The layer that gets the paint of the layers the new shader cannot draw.',
                get = function() return math.min(state.mergeInto, K) end, set = function(v) state.mergeInto = v state.choice = 'merge' ShowChoice() end })
            s:Place(Skin.S(14), Skin.S(y), Skin.S(math.min(330, INNER)))
            for _, ctl in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(ctl) end
            d:Raise(s.field) d:Raise(s.field.frame)
            table.insert(state.sliders, s)
            y = y + 44 + 10
        end
        if hasUpper then
            local atlas = plan.upperAction == 'atlas'
            local b = Keep(d:Button(atlas and 'Replace Upper layer with a neutral roughness atlas' or 'Replace Upper layer with a transparent texture', 14, y, math.min(440, INNER), 24,
                function(self) state.upper = self.on end, { toggle = true,
                tip = atlas and 'The PBR shaders read roughness (and, in the 2xx, heights) for every layer from the Upper layer. Off keeps your Upper texture.' or
                                'The new shader would draw your Upper texture in a way it was not made for. Off keeps it.' }))
            b:SetOn(state.upper)
        end
        Keep(d:Button('Convert', 14, buttonsY, 110, BUTTON_H, function() state.Run() end,
            { tip = 'Convert the layers of the map to the format of ' .. tostring(targetId) .. ' as listed above. One undo step undoes all of it.' }))
        Keep(d:Button('Cancel', 134, buttonsY, 100, BUTTON_H, function() Dialog.Close() end, { tip = 'Close without changing anything.' }))
    end

    function state.Run()
        local report, why = Conv.Run(plan, { layer8 = state.choice, mergeInto = state.mergeInto, upper = state.upper })
        Clear()
        -- the report gets the room of the options block too
        view:SetRect(14, TOP, INNER, buttonsY - 8 - TOP)
        if not report then
            view:Heading('Failed', { color = c.error, before = 0 })
            view:Text(tostring(why), { color = c.error, size = 'text' })
            view:Show()
            CloseButton()
            Say('conversion failed: ' .. tostring(why))
            return
        end
        state.report = report
        view:Heading('Done (one undo step)', { color = c.accent, before = 0 })
        for _, sec in Sections(report, c) do
            view:Heading(sec.title, { color = sec.color == c.text and c.textDim or sec.color })
            for _, t in sec.items do view:Bullet(t, { color = sec.color }) end
        end
        view:Show()
        CloseButton()
        Say(report.status)
        if done then done(report) end
    end

    Build()
    return state
end
