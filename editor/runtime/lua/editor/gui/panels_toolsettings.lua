-- The Tool settings panel: the settings that every tool of the showing workspace shares. It sits beside Properties, View and Symmetry; what it shows depends on the workspace
-- (ui.lua State.workspace, known before the shell builds the panels of a workspace):
--
--   Terrain     radius and falloff of the brush (the same variables as the Brush and Texture brush panels)
--   Objects     units: snap to the build grid, free or stepped rotation; props: snap, random rotation, random scale; decals: snap, random rotation, random size;
--               markers: a note; areas: limit to the map bounds (shown when the editor has that setting, tools.lua LimitAreas); selection: the box of the Select tools follows the
--               camera (tools.lua SelectBoxFollowsCamera)
--   Mission     units, markers and areas like Objects
--   others      a short note
--
-- Nothing is stored twice: the panel edits the variables the tools read (props.lua Settings ...) or the keys of toolopts.lua, which the placement code asks through
-- Units.SnapToGrid(), Props.RotationStep() and so on. toolopts.lua keeps the values in the user folder (Restore at start, Sync from the shell's tick).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Opts = import('/lua/editor/toolopts.lua')

live = {}

Opts.Restore()

--- Keeps the values of the settings that live in other modules in the user folder (the shell ticks a module-level Refresh about four times a second).
function Refresh()
    pcall(Opts.Sync)
    for _, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end

-- which sections each workspace shows
local SECTIONS = {
    Terrain = { 'terrain' },
    Objects = { 'units', 'props', 'decals', 'markers', 'areas', 'select' },
    Mission = { 'units', 'markers', 'areas', 'select' },
}

local STEP_TIP = 'The angle of one step. The rotation ring of the Select tools and the random turns of the brushes use whole steps of it.'

Panels.Register{
    id = 'toolsettings', title = 'Tool settings', minW = 200, minH = 120,
    addedInLayout = 2,          -- layouts saved before this panel existed get it added (workspace.lua Migrate)
    stack = {
        { workspace = 'Terrain', with = 'properties' }, { workspace = 'Terrain', with = 'symmetry' }, { workspace = 'Terrain', with = 'view' },
        { workspace = 'Objects', with = 'properties' }, { workspace = 'Objects', with = 'symmetry' }, { workspace = 'Objects', with = 'view' },
        { workspace = 'Mission', with = 'properties' }, { workspace = 'Mission', with = 'view' },
    },
    create = function(group, host)
        local P = { blocks = {}, updaters = {}, paras = {}, w = Skin.S(220), sig = '' }
        live.toolsettings = P
        local workspace = UI.State.workspace

        local function Add(block) table.insert(P.blocks, block) return block end
        local function Title(text, show)
            Add{ type = 'title', ctl = W.Label(group, text, 0, 0, { color = Skin.color.textDim }), show = show }
        end
        local function Note(text, show)
            Add{ type = 'note', text = text, show = show }
        end
        --- A toggle button in a row; returns it (the row is made by Row).
        local function Toggle(text, width, tip, get, set)
            local b = W.Button(group, text, 0, 0, width, Skin.S(24), function(self)
                set(self.on)
                P:Refresh()
            end, { toggle = true, tip = tip })
            table.insert(P.updaters, function() b:SetOn(get() and true or false) end)
            return { b, width }
        end
        --- A button that does something once (not a toggle).
        local function Choice(text, width, tip, get, set)
            local b = W.Button(group, text, 0, 0, width, Skin.S(24), function(self)
                set()
                P:Refresh()
            end, { tip = tip })
            table.insert(P.updaters, function() b:SetOn(get() and true or false) end)
            return { b, width }
        end
        local function Row(items, show)
            Add{ type = 'row', items = items, show = show }
        end
        local function Slide(o, show)
            local s = W.Slider(group, o)
            table.insert(P.updaters, function() s:Refresh() end)
            Add{ type = 'slider', ctl = s, show = show }
        end

        --- Free or stepped rotation of one kind of object, with the step size (a slider and the usual angles).
        local function Rotation(kind)
            local stepped = function() return Opts.Stepped(kind) end
            Row({
                Choice('Free rotation', Skin.S(104), 'Turn by any angle.', function() return not Opts.Stepped(kind) end, function() Opts.SetStepped(kind, false) end),
                Choice('Stepped rotation', Skin.S(120), 'Turn in whole steps of the step size below.', function() return Opts.Stepped(kind) end, function() Opts.SetStepped(kind, true) end),
            })
            Slide({ label = 'Step (degrees)', min = Opts.STEP_MIN, max = Opts.STEP_MAX, step = Opts.STEP_UNIT, fmt = '%.1f', tip = STEP_TIP,
                get = function() return Opts.StepSize(kind) end, set = function(v) Opts.SetStepSize(kind, v) end }, stepped)
            local presets = {}
            for _, loopDeg in Opts.STEP_PRESETS do
                local deg = loopDeg          -- closures share the loop variable: each button needs its own copy
                table.insert(presets, Choice(tostring(deg), Skin.S(46), 'Use steps of ' .. tostring(deg) .. ' degrees.',
                    function() return math.abs(Opts.StepSize(kind) - deg) < 0.01 end, function() Opts.SetStepSize(kind, deg) end))
            end
            Row(presets, stepped)
        end

        local function Sections()
            local list = SECTIONS[workspace]
            if not list then
                Note('This workspace has no tool settings. Terrain, Objects and Mission have them.')
                return
            end
            for _, loopName in list do
                local name = loopName
                if name == 'terrain' then
                    Title('Terrain brushes')
                    Slide({ label = 'Radius', min = 1, max = 64, step = 1, fmt = '%d', tip = 'Radius of the brush, in world units. Every brush tool uses it.',
                        get = function() return Terrain.Brush.radius end, set = function(v) UI.SetRadius(v) end })
                    Slide({ label = 'Falloff % (0 flat, 100 full)', min = 0, max = 100, step = 1, fmt = '%d', tip = 'How much of the radius the edge fades over. 0 is a flat disc, 100 a smooth fade from the centre.',
                        get = function() return Terrain.Brush.falloff * 100 end, set = function(v) Terrain.Brush.falloff = v / 100 end })
                    Note('Strength and the weight shape are in the Brush and Texture brush panels.')
                elseif name == 'units' then
                    Title('Units')
                    local items = {
                        Toggle('Snap to build grid', Skin.S(140), 'Units stand on the build grid when placed or moved. Off: exactly where you click.',
                            function() return Opts.SnapToGrid('units') end, function(v) Opts.SetSnapToGrid('units', v) end),
                    }
                    -- the symmetry setting that decides which army the mirrored units belong to (the same variable as in the Symmetry panel)
                    table.insert(items, Toggle('Mirror to the other army', Skin.S(170), 'With symmetry on, the mirrored copies of a unit belong to the mirrored army. Same setting as in the Symmetry panel.',
                        function() return import('/lua/editor/mirrorhalf.lua').ArmyMode == 'map' end,
                        function(v) import('/lua/editor/mirrorhalf.lua').ArmyMode = v and 'map' or 'keep' end))
                    Row(items)
                    Rotation('units')
                elseif name == 'props' then
                    local Props = import('/lua/editor/props.lua')
                    Title('Props')
                    Row({
                        Toggle('Snap to build grid', Skin.S(140), 'Props snap to the grid (half a unit) when placed or moved. Off: exactly where you click.',
                            function() return Opts.SnapToGrid('props') end, function(v) Opts.SetSnapToGrid('props', v) end),
                        Toggle('Random rotation', Skin.S(124), 'Every new prop gets a random heading. Same setting as Random turn in the Properties panel of the prop tools.',
                            function() return Props.Settings.randomHeading end, function(v) Props.Settings.randomHeading = v end),
                    })
                    Rotation('props')
                    Slide({ label = 'Random scale min %', min = 10, max = 300, step = 5, fmt = '%d', tip = 'The smallest size a new prop gets, in percent of its normal size.',
                        get = function() return Props.Settings.scaleMin end, set = function(v) Props.Settings.scaleMin = v end })
                    Slide({ label = 'Random scale max %', min = 10, max = 300, step = 5, fmt = '%d', tip = 'The largest size a new prop gets, in percent of its normal size.',
                        get = function() return Props.Settings.scaleMax end, set = function(v) Props.Settings.scaleMax = v end })
                elseif name == 'decals' then
                    local Decals = import('/lua/editor/decals.lua')
                    Title('Decals')
                    Row({
                        Toggle('Snap to build grid', Skin.S(140), 'Decals snap to the grid (half a unit) when placed. Off: exactly where you click.',
                            function() return Opts.SnapToGrid('decals') end, function(v) Opts.SetSnapToGrid('decals', v) end),
                        Toggle('Random rotation', Skin.S(124), 'Every new decal gets a random heading. Same setting as Random turn in the Properties panel of the decal tools.',
                            function() return Decals.Settings.randomHeading end, function(v) Decals.Settings.randomHeading = v end),
                    })
                    Rotation('decals')
                    Slide({ label = 'Random size variance %', min = 0, max = 100, step = 5, fmt = '%d', tip = 'How much the size of new decals varies around the size in the decal brush settings.',
                        get = function() return Decals.Settings.sizeVar end, set = function(v) Decals.Settings.sizeVar = v end })
                elseif name == 'markers' then
                    Title('Markers')
                    Note('Mass and hydrocarbon markers always snap to the build grid; other markers go where you click.')
                elseif name == 'areas' then
                    local has = function() return Opts.LimitAreas() ~= nil end
                    Title('Areas', has)
                    Row({
                        Toggle('Limit to map bounds', Skin.S(150), 'Areas cannot be drawn or resized past the edge of the map.',
                            function() return Opts.LimitAreas() end, function(v) Opts.SetLimitAreas(v) end),
                    }, has)
                elseif name == 'select' then
                    local has = function() return Opts.SelectBoxCamera() ~= nil end
                    Title('Selection', has)
                    Row({
                        Toggle('Selection box follows the camera', Skin.S(230), 'The box you drag with a Select tool is a rectangle on the screen and selects what lies inside it, however the view is turned. Off: a box on the ground, aligned with the map axes. Area drawing and the other world-rectangle tools are not affected.',
                            function() return Opts.SelectBoxCamera() end, function(v) Opts.SetSelectBoxCamera(v) end),
                    }, has)
                end
            end
            if workspace ~= 'Terrain' then
                Note('Stepped rotation applies to the rotation ring of the Select tools and to the random turns of the brushes.')
            end
        end
        Sections()

        --- Puts every control where the panel's width allows: rows wrap, sliders take the width.
        function P:Layout(w)
            P.w = w
            W.BeginLayout(group)      -- the content height is measured anew: it only ever grew, so blocks that are hidden now (or a wider panel) left empty scroll space below
            for _, l in P.paras do l:Destroy() end
            P.paras = {}
            local pad = Skin.S(10)
            local iw = math.max(Skin.S(80), w - 2 * pad)
            local y = pad
            for _, b in P.blocks do
                local shown = (b.show == nil) or b.show()
                b.shown = shown
                if b.type == 'title' then
                    if shown then
                        W.Place(b.ctl, group, pad, y + Skin.S(2))
                        y = y + Skin.S(22)
                    else
                        W.Place(b.ctl, group, -4000, 0)
                    end
                elseif b.type == 'row' then
                    if shown then
                        y = W.Flow(group, b.items, pad, y, iw, Skin.S(24), Skin.S(6)) + Skin.S(8)
                    else
                        for _, it in b.items do W.Place(it[1], group, -4000, 0, it[2], Skin.S(24)) end
                    end
                elseif b.type == 'slider' then
                    if shown then
                        b.ctl:Place(pad, y, iw)
                        y = y + Skin.S(52)
                    else
                        b.ctl:Place(-4000, 0, iw)
                    end
                elseif b.type == 'note' then
                    if shown then
                        local labels, endY = W.Paragraph(group, b.text, pad, y, iw, { color = Skin.color.textDim, size = 'small' })
                        for _, l in labels do table.insert(P.paras, l) end
                        y = endY + Skin.S(8)
                    end
                end
            end
        end

        --- What is shown depends on the settings (the step controls only while the rotation is stepped, the areas row when the editor has the setting).
        local function Signature()
            local s = ''
            for _, b in P.blocks do
                local shown = (b.show == nil) or b.show()
                s = s .. (shown and '1' or '0')
            end
            return s
        end

        function P:Refresh()
            local sig = Signature()
            if sig ~= P.sig then
                P.sig = sig
                P:Layout(P.w)
            end
            for _, u in P.updaters do u() end
        end

        function P:OnResize(w, h)
            P.sig = Signature()
            P:Layout(w)
            P:Refresh()
        end
        return P
    end,
}
