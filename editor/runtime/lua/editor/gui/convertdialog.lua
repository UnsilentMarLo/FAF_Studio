-- The Convert layers dialog (Layers panel and shader browser): shows what converting the layers of the map to another terrain shader does (stratumconv.lua), asks what to do with paint the target cannot
-- draw (layer 8) and with the Upper layer, converts in ONE undo step and then lists what was done and what was not.
--
--   Open(targetId, done)       done(report) after a conversion
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local Conv = import('/lua/editor/stratumconv.lua')

last = false      -- the open dialog's state: for the self test

local WIDTH = 700
local CHARS = 100        -- characters of small text per line at this width (a safe guess for sizing the dialog)

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

function Open(targetId, done)
    local plan = Conv.Plan(targetId)
    local c = Skin.color
    -- size: the texts wrap, so the height follows their length
    local texts = {}
    if plan.refused then
        table.insert(texts, plan.refused)
    else
        for _, t in plan.lines do table.insert(texts, t) end
        for _, t in plan.warnings do table.insert(texts, t) end
    end
    local choiceH = (plan.refused == nil and table.getn(plan.extra) > 0) and 110 or 0
    local upperH = (plan.refused == nil and plan.upperAction) and 34 or 0
    local height = math.max(240, math.min(680, 150 + choiceH + upperH + 16 * (Lines(texts) + 8)))
    local d = Dialog.Open('Convert layers to ' .. tostring(targetId) .. '  (one undo step)', WIDTH, height)
    local state = { plan = plan, dyn = {}, sliders = {}, choice = plan.default, mergeInto = 1, upper = true, dialog = d }
    last = state

    local function Keep(ctl)
        table.insert(state.dyn, ctl)
        return ctl
    end
    local function Clear()
        for _, s in state.sliders do DestroySlider(s) end
        state.sliders = {}
        for _, ctl in state.dyn do ctl:Destroy() end
        state.dyn = {}
    end
    local function Para(text, y, opts)
        local lines, after = W.Paragraph(d.group, text, Skin.S(14), Skin.S(y), Skin.S(WIDTH - 28), opts or { color = c.text, size = 'small' }, Skin.S(16), Skin.S(height - 50))
        for _, l in lines do
            d:Raise(l)
            Keep(l)
        end
        return math.floor(after / Skin.S(1)) + 4
    end

    if plan.refused then
        Para('Cannot convert: ' .. plan.refused .. '.', 40, { color = c.warn })
        d:Button('Close', 14, height - 40, 100, 28, function() Dialog.Close() end, { tip = 'Close this window.' })
        return state
    end

    local K = plan.toP.painted
    local choiceButtons = {}
    local function ShowChoice()
        for id, b in choiceButtons do b:SetOn(state.choice == id) end
    end
    local function Build()
        Clear()
        local y = 36
        Keep(d:Label('What the conversion does', 14, y, { color = c.textDim }))
        y = y + 20
        for _, t in plan.lines do y = Para(t, y) end
        -- the layers the target cannot paint
        if table.getn(plan.extra) > 0 then
            y = y + 4
            Keep(d:Label('Paint the new shader cannot draw', 14, y, { color = c.textDim }))
            y = y + 20
            local x = 14
            local function Choice(id, label, w, tip, enabled)
                choiceButtons[id] = Keep(d:Button(label, x, y, w, 24, function()
                    if not enabled then
                        Say('not enough layers without paint to make room: merge it into a layer or drop it')
                    else
                        state.choice = id
                    end
                    ShowChoice()
                end, { toggle = true, tip = tip }))
                if not enabled then choiceButtons[id].label:SetColor(c.textDim) end
                x = x + w + 6
            end
            Choice('move', 'Move to a free layer', 170, 'Layers without paint make room: the painted layers keep their order and move down to fill the free slots, with their textures. Nothing is lost.', plan.canMove)
            Choice('merge', 'Merge into one layer', 170, 'Add the paint to another layer: it shows that layer\'s texture there.', true)
            Choice('drop', 'Drop the paint', 140, 'Remove the paint of the layers the new shader cannot draw.', true)
            ShowChoice()
            y = y + 30
            local s = W.Slider(d.group, { label = 'Merge into layer (when merging)', min = 1, max = K, step = 1, fmt = '%d', compact = true,
                tip = 'The layer that gets the paint of the layers the new shader cannot draw.',
                get = function() return math.min(state.mergeInto, K) end, set = function(v) state.mergeInto = v state.choice = 'merge' ShowChoice() end })
            s:Place(Skin.S(14), Skin.S(y), Skin.S(300))
            for _, ctl in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus } do d:Raise(ctl) end
            d:Raise(s.field) d:Raise(s.field.frame)
            table.insert(state.sliders, s)
            y = y + 50
        end
        -- the Upper layer
        if plan.upperAction and not (plan.upperAction == 'atlas' and plan.atlasMissing) then
            y = y + 4
            local b = Keep(d:Button(plan.upperAction == 'atlas' and 'Replace the Upper layer by a neutral roughness atlas' or 'Replace the Upper layer by a transparent texture', 14, y, 420, 24,
                function(self) state.upper = self.on end, { toggle = true,
                tip = plan.upperAction == 'atlas' and 'The PBR shaders read roughness (and, in the 2xx, heights) for every layer from the Upper layer. Off keeps your Upper texture.' or
                                                     'The new shader would draw your Upper texture in a way it was not made for. Off keeps it.' }))
            b:SetOn(state.upper)
            y = y + 30
        end
        -- what is not done
        if table.getn(plan.warnings) > 0 then
            y = y + 4
            Keep(d:Label('Not done / check', 14, y, { color = c.textDim }))
            y = y + 20
            for _, t in plan.warnings do y = Para(t, y, { color = c.warn, size = 'small' }) end
        end
        Keep(d:Button('Convert', 14, height - 40, 110, 28, function() state.Run() end,
            { tip = 'Convert the layers of the map to the format of ' .. tostring(targetId) .. ' as listed above. One undo step undoes all of it.' }))
        Keep(d:Button('Cancel', 134, height - 40, 100, 28, function() Dialog.Close() end, { tip = 'Close without changing anything.' }))
    end

    function state.Run()
        local report, why = Conv.Run(plan, { layer8 = state.choice, mergeInto = state.mergeInto, upper = state.upper })
        Clear()
        if not report then
            local y = Para('Not converted: ' .. tostring(why), 40, { color = c.error })
            Keep(d:Button('Close', 14, height - 40, 100, 28, function() Dialog.Close() end, { tip = 'Close this window.' }))
            Say('conversion failed: ' .. tostring(why))
            return
        end
        state.report = report
        Keep(d:Label('Done (one undo step)', 14, 36, { color = c.accent }))
        local y = 58
        for _, l in report.lines do
            y = Para((l.kind == 'warn' and 'Check: ' or '') .. l.text, y, { color = l.kind == 'warn' and c.warn or c.text, size = 'small' })
        end
        Keep(d:Button('Close', 14, height - 40, 100, 28, function() Dialog.Close() end, { tip = 'Close this window.' }))
        Say(report.status)
        if done then done(report) end
    end

    Build()
    return state
end
