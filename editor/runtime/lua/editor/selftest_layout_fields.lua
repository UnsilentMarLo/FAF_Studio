-- Layout self test of the Fields panel (gui/panels_fields.lua): the panel is built in a scrolling content group (widgets.lua ScrollContent, as the dock does) and laid out at several widths and for
-- ops with a different number of sliders, one after the other in the same instance (the order a user resizes and picks ops in). It checks that
--   * the status line sits within 40 logical pixels below the info line, the info line within 40 below the last slider / picture / op list (no huge gaps between the text blocks),
--   * the scroll content ends where the status line ends (the content height is measured anew on every layout: it used to keep the tallest value ever seen, so the panel scrolled on into empty space),
--   * no control reaches outside the panel and none is parked off screen (the holder here is tall enough that nothing is culled),
--   * the status line stays one line high, also for an error text with line breaks.
-- Through /edcmd in an /editor session:  return import('/lua/editor/selftest_layout_fields.lua').Run()
--
-- Lua 5.0 dialect.

local Group = import('/lua/maui/group.lua').Group
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')

local function Run1(check)
    local PF = import('/lua/editor/gui/panels_fields.lua')
    local def = Panels.Get('fields')
    check('the Fields panel is registered', def ~= nil)
    if not def then return end
    local savedOp, savedText, savedLive = PF.state.op, PF.state.text, PF.live.fields
    local frame = GetFrame(0)
    local holder = Group(frame)
    holder.Left:Set(0) holder.Top:Set(0) holder.Width:Set(Skin.S(1200)) holder.Height:Set(Skin.S(4000))
    W.scrollMemory['selftest-layout-fields'] = nil
    local content = W.ScrollContent(holder, 'selftest-layout-fields')
    content.panelId = 'fields'
    local ok, err = pcall(function()
        local Pn = def.create(content, {})
        local ctx = content.scroll
        local gl, gt = content.Left(), content.Top()
        local ops = { 'perlin', 'levels', 'abs', 'perlin' }
        -- logical widths / heights in the order a user changes them: narrow, wide, narrow again, in between
        local sizes = { { 260, 300 }, { 700, 300 }, { 260, 600 }, { 400, 500 }, { 1000, 600 }, { 240, 200 } }
        PF.state.text = 'applied perlin'
        for _, op in ops do
            for _, sz in sizes do
                PF.state.op = op
                Pn:Build()
                local w = math.max(Skin.S(60), Skin.S(sz[1]) - Skin.S(Skin.size.scrollW) - Skin.S(2))   -- the width the dock hands a scrolling panel
                holder.Width:Set(Skin.S(sz[1])) holder.Height:Set(Skin.S(4000))
                Pn:OnResize(w, Skin.S(sz[2]))
                W.EndLayout(content)
                local what = op .. ' at ' .. sz[1] .. 'x' .. sz[2]
                local controls = { Pn.bMap, Pn.bApply, Pn.bPreview, Pn.bBack, Pn.bClear, Pn.bLive, Pn.bRamp, Pn.bCommit, Pn.bMask, Pn.pic, Pn.frame, Pn.list.root, Pn.info, Pn.status, Pn.opLabel }
                local sliders = {}
                for _, s in Pn.sliders do table.insert(sliders, s) end
                table.insert(sliders, Pn.sLayer)
                local blockBottom = Pn.pic.Top() + Pn.pic.Height()
                for _, s in sliders do
                    for _, part in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus, s.field.frame } do table.insert(controls, part) end
                    blockBottom = math.max(blockBottom, s.label.Top() + Skin.S(44))
                end
                -- inside the panel, nothing parked
                local bad
                for _, ctl in controls do
                    local l, t, r = ctl.Left(), ctl.Top(), ctl.Right()
                    if t < -5000 or l < -1000 then
                        bad = bad or ('a control is parked at ' .. l .. ',' .. t)
                    elseif l < gl - 1 or r > gl + w + 1 or t < gt then
                        bad = bad or ('a control at ' .. (l - gl) .. ',' .. (t - gt) .. ' .. ' .. (r - gl) .. ' reaches outside the panel width ' .. w)
                    end
                end
                check(what .. ': every control lies inside the panel', bad == nil, bad)
                local infoTop, infoBottom = Pn.info.Top(), Pn.info.Top() + Pn.info.Height()
                local statusTop, statusBottom = Pn.status.Top(), Pn.status.Top() + Pn.status.Height()
                check(what .. ': the info line follows the sliders closely', infoTop >= blockBottom - 1 and infoTop - blockBottom <= Skin.S(40), infoTop - blockBottom)
                check(what .. ': the status line follows the info line closely', statusTop >= infoBottom - Skin.S(4) and statusTop - infoBottom <= Skin.S(40), statusTop - infoBottom)
                local rel = statusBottom - gt
                check(what .. ': the content ends at the status line', ctx.extent >= rel - 1 and ctx.extent - rel <= Skin.S(10), ctx.extent .. ' vs ' .. rel)
                -- the panel at its real height: it scrolls exactly as far as the content reaches
                local view = Skin.S(sz[2])
                holder.Height:Set(view)
                ctx:Update()
                local want = 0
                if ctx.extent > view + Skin.S(10) then want = ctx.extent + Skin.S(8) - view end
                check(what .. ': the scroll range matches the content', ctx.maxOff == want and (want == 0 or ctx.extent - rel <= Skin.S(10)), ctx.maxOff .. ' vs ' .. want)
                holder.Height:Set(Skin.S(4000))
                ctx:Update()
            end
        end
        -- an error text with line breaks keeps the status line one line high and inside the width
        PF.state.text = 'perlin: bad parameter\nstack traceback:\n    one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen'
        PF.state.op = 'perlin'
        Pn:Build()
        local w = Skin.S(300)
        Pn:OnResize(w, Skin.S(400))
        check('a multi line text keeps the status line one line high', Pn.status.Height() <= Skin.S(26), Pn.status.Height())
        check('a long status text is cut to the panel width', Pn.status.Right() <= gl + w + 1, Pn.status.Right() - gl)
    end)
    check('the panel can be built and laid out', ok, err)
    W.ScrollRelease(content)
    holder:Destroy()
    W.scrollMemory['selftest-layout-fields'] = nil
    PF.state.op, PF.state.text, PF.live.fields = savedOp, savedText, savedLive
end

function Run()
    local fails, checks = {}, 0
    local function check(name, ok, detail)
        checks = checks + 1
        if not ok then table.insert(fails, name .. (detail and (' (' .. tostring(detail) .. ')') or '')) end
    end
    local ok, err = pcall(Run1, check)
    if not ok then table.insert(fails, 'error: ' .. tostring(err)) end
    if table.getn(fails) == 0 then return 'PASS layout fields (' .. checks .. ' checks)' end
    return 'FAIL layout fields: ' .. table.concat(fails, '; ')
end
