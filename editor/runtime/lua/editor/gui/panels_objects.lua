-- Panels for map objects (markers and areas), built on tools.lua:
--
--   'markers'    palette of every marker type (from the game's MarkerTemplates, so mods add types); picking one arms the Marker tool
--   'outliner'   every marker and area of the map; a click selects
--   'properties' context-sensitive: the selected marker / area (edit fields and info), else the active tool, else the map
--
-- Also registers the editing commands and their keys (Delete, Ctrl+Z, Ctrl+Y, digits for the tools of the workspace).

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Commands = import('/lua/editor/gui/commands.lua')
local UI = import('/lua/editor/ui.lua')
local Terrain = import('/lua/editor/terrain.lua')
local Tools = import('/lua/editor/tools.lua')
local Map = import('/lua/editor/map.lua')

live = {}      -- panel id -> instance, for Refresh

function Refresh()
    for _, inst in live do
        if inst.Refresh then pcall(inst.Refresh, inst) end
    end
end

-- ---- shared bits ------------------------------------------------------------------------------------------------------------------

local function Lighten(argb)
    -- template colours are dark game colours ('ff800080'): mix with white so they read on the panel
    local hex = Tools.ColorHex(argb)
    local r = tonumber(string.sub(hex, 1, 2), 16) or 128
    local g = tonumber(string.sub(hex, 3, 4), 16) or 128
    local b = tonumber(string.sub(hex, 5, 6), 16) or 128
    return string.format('ff%02x%02x%02x', math.floor((r + 255) / 2), math.floor((g + 255) / 2), math.floor((b + 255) / 2))
end

local function RowText(row, text, color)
    local rh = row.bg.Height()
    W.Fit(row.text, text, math.max(Skin.S(40), row.bg.Width() - Skin.S(24)))
    row.text:SetColor(color or Skin.color.text)
    local ty = math.floor((rh - row.text.Height()) / 2)
    row.text.Left:Set(function() return row.bg.Left() + Skin.S(8) end)
    row.text.Top:Set(function() return row.bg.Top() + ty end)
end

local function MarkerTable()
    if Map.Doc then return Map.Doc.save.MasterChain._MASTERCHAIN_.Markers end
    return {}
end

local function AreaTable()
    if Map.Doc then return Map.Doc.save.Areas end
    return {}
end

local function Basename(path)
    return (string.gsub(path or '', '^.*/', ''))
end

-- ---- marker palette ---------------------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'markers', title = 'Markers',
    create = function(group, host)
        local P = {}
        live.markers = P
        local rows = {}
        local lastCategory = false
        for _, t in Tools.MarkerTypes() do
            if t.category ~= lastCategory then
                lastCategory = t.category
                table.insert(rows, { header = t.category })
            end
            table.insert(rows, { name = t.name, color = t.color })
        end
        local function IndexOf(name)
            for i, r in rows do
                if r.name == name then return i end
            end
            return nil
        end
        P.list = W.VirtualList(group, {
            getCount = function() return table.getn(rows) end,
            bind = function(row, index)
                local r = rows[index]
                if r.header then
                    RowText(row, string.upper(r.header), Skin.color.textDim)
                else
                    RowText(row, r.name, Lighten(r.color))
                end
            end,
            onSelect = function(index)
                local r = rows[index]
                if r and r.name then
                    Tools.SetMarkerType(r.name)
                    UI.SelectTool('marker')
                    P:Refresh()
                end
            end,
            onContext = function(index, x, y)
                local r = rows[index]
                if r and r.name then Menu.Context('context.list', { list = 'markers', name = r.name }, x, y) end
            end,
            bgColor = Skin.color.panel,
        })
        function P:Refresh()
            local i = IndexOf(Tools.MarkerType)
            -- (SetSelected binds every visible row again: only when the choice moved)
            if i and P.list.selected ~= i then P.list:SetSelected(i) end
        end
        function P:OnResize(w, h)
            local pad = Skin.S(6)
            P.list:SetRect(pad, pad, w - 2 * pad, h - 2 * pad)
            P:Refresh()
        end
        return P
    end,
}

-- ---- outliner ---------------------------------------------------------------------------------------------------------------------

-- the outliner's filter survives a re-created panel (workspace switch): the search text and which kinds are listed
OutlinerFilter = { text = '', markers = true, areas = true, chains = true }

Panels.Register{
    id = 'outliner', title = 'Outliner',
    create = function(group, host)
        local P = { items = {}, seen = -1, sel = '', fkey = '', chainRev = -1 }
        live.outliner = P
        local Chains = import('/lua/editor/chains.lua')
        local F = OutlinerFilter
        local function Build()
            P.items = {}
            if not Map.Doc then return end
            local needle = string.lower(F.text or '')
            local function Wanted(text) return needle == '' or string.find(string.lower(text), needle, 1, true) ~= nil end
            if F.markers then
                for _, name in Map.MarkerNames() do
                    local text = name .. '   ' .. tostring(MarkerTable()[name].type)
                    if Wanted(text) then table.insert(P.items, { kind = 'marker', name = name, text = text }) end
                end
            end
            if F.areas then
                for _, name in Map.AreaNames() do
                    local text = name .. '   area'
                    if Wanted(text) then table.insert(P.items, { kind = 'area', name = name, text = text }) end
                end
            end
            if F.chains then
                for _, name in Chains.Names() do
                    local text = name .. '   chain (' .. table.getn(Chains.Markers(name) or {}) .. ')'
                    if Wanted(text) then table.insert(P.items, { kind = 'chain', name = name, text = text }) end
                end
            end
        end
        P.search = W.TextField(group, 0, 0, 100, Skin.S(22), { onChange = function(text) F.text = text if P.Refresh then P:Refresh(true) end end })
        P.search:SetText(F.text or '')
        P.searchLabel = W.Label(group, 'Find', 0, 0, { color = Skin.color.textDim })
        local function Toggle(label, key)
            local b = W.Button(group, label, 0, 0, Skin.S(64), Skin.S(22), function(self) F[key] = self.on P:Refresh(true) end, { toggle = true })
            b:SetOn(F[key] and true or false)
            return b
        end
        P.tMarkers = Toggle('Markers', 'markers')
        P.tAreas = Toggle('Areas', 'areas')
        P.tChains = Toggle('Chains', 'chains')
        P.list = W.VirtualList(group, {
            getCount = function() return table.getn(P.items) end,
            bind = function(row, index)
                local it = P.items[index]
                RowText(row, it.text, (it.kind == 'area' and 'ff90e4ff') or (it.kind == 'chain' and 'ffffb050') or Skin.color.text)
            end,
            onSelect = function(index)
                local it = P.items[index]
                if not it then return end
                if it.kind == 'chain' then
                    local Chains2 = import('/lua/editor/chains.lua')
                    Chains2.Current = it.name
                    Chains2.Revision = Chains2.Revision + 1
                    Chains2.SelectMarkers(it.name)
                else
                    Tools.Select(it.kind, it.name)
                end
            end,
            onContext = function(index, x, y)
                local it = P.items[index]
                if it and it.kind ~= 'chain' then Menu.Context('context.list', { list = 'outliner', kind = it.kind, name = it.name }, x, y) end
            end,
            bgColor = Skin.color.panel,
        })
        function P:Refresh(force)
            local sel = tostring(Tools.Selection.kind) .. tostring(Tools.Selection.name)
            local fkey = tostring(F.text) .. tostring(F.markers) .. tostring(F.areas) .. tostring(F.chains)
            if not force and Tools.Changed == P.seen and sel == P.sel and fkey == P.fkey and Chains.Revision == P.chainRev then return end
            -- The list is built again (every marker, area and chain of the map: thousands of rows' worth of strings) when the filter or the chains changed, or when the objects
            -- changed and the last build is older than 0.75 s: a marker dragged over the map moves Tools.Changed every frame. A changed selection alone only moves the highlight.
            local now = GetSystemTimeSeconds()
            local rebuild = force or fkey ~= P.fkey or Chains.Revision ~= P.chainRev or (Tools.Changed ~= P.seen and now - (P.builtAt or -10) > 0.75)
            if not rebuild and sel == P.sel then return end
            P.sel = sel
            if rebuild then
                P.seen, P.fkey, P.chainRev, P.builtAt = Tools.Changed, fkey, Chains.Revision, now
                Build()
            end
            local found = false
            for i, it in P.items do
                if it.kind == Tools.Selection.kind and it.name == Tools.Selection.name then
                    found = i
                end
            end
            -- no match (the selection was deleted, or cleared): the old row index must not stay highlighted over some other object
            P.list.selected = found or nil
            P.list:Refresh()
        end
        function P:OnResize(w, h)
            local pad = Skin.S(6)
            W.Place(P.searchLabel, group, pad, pad + Skin.S(3))
            W.Place(P.search.frame, group, pad + Skin.S(34), pad, w - 2 * pad - Skin.S(34), Skin.S(22))
            P.search.Width:Set(w - 2 * pad - Skin.S(34) - 2)
            local y = W.Flow(group, { { P.tMarkers, Skin.S(64) }, { P.tAreas, Skin.S(64) }, { P.tChains, Skin.S(64) } }, pad, pad + Skin.S(26), w - 2 * pad, Skin.S(22), Skin.S(4)) + Skin.S(4)
            P.list:SetRect(pad, y, w - 2 * pad, math.max(Skin.S(40), h - y - pad))
            P.seen = -1
            P:Refresh(true)
        end
        return P
    end,
}

-- ---- properties (context sensitive) ---------------------------------------------------------------------------------------------------

Panels.Register{
    id = 'properties', title = 'Properties',
    create = function(group, host)
        local P = { items = {}, updaters = {}, w = 200, h = 200, key = '', seen = -1 }
        live.properties = P

        local function Clear()
            for _, c in P.items do pcall(c.Destroy, c) end
            P.items, P.updaters = {}, {}
        end

        local y = 0
        local function Title(text)
            table.insert(P.items, W.Label(group, text, Skin.S(10), y, { size = 'text' }))
            y = y + Skin.S(26)
        end
        local function Info(text, color)
            local l = W.Label(group, text, Skin.S(10), y, { color = color or Skin.color.textDim, size = 'small' })
            table.insert(P.items, l)
            y = y + Skin.S(18)
            return l
        end
        local function Help(text)
            local labels, below = W.Paragraph(group, text, Skin.S(10), y, math.max(Skin.S(80), P.w - Skin.S(20)), { color = Skin.color.textDim, size = 'small' })
            for _, l in labels do table.insert(P.items, l) end
            y = below
        end
        local function Gap(n)
            y = y + Skin.S(n or 8)
        end
        local function Field(name, get, apply)
            table.insert(P.items, W.Label(group, name, Skin.S(10), y + Skin.S(4), { color = Skin.color.textDim }))
            local fx = Skin.S(92)
            if P.w < fx + Skin.S(140) then      -- narrow panel: the label gets a line of its own above the field
                fx = Skin.S(10)
                y = y + Skin.S(20)
            end
            local f = W.TextField(group, fx, y, math.max(Skin.S(40), P.w - fx - Skin.S(10)), Skin.S(22), {
                text = get(),
                onEnter = function(text) apply(text) end,
            })
            table.insert(P.items, f.frame)
            table.insert(P.updaters, function() f:SetText(get()) end)
            y = y + Skin.S(28)
            return f
        end
        --- A number with - and + buttons beside its field (a position, an angle, an amount: nothing a slider bar suits). `apply(text)` gets the
        --- text of the field, as with Field; a button press adds or subtracts `step` first. `fmt` formats the field.
        local function Stepper(name, get, apply, step, fmt)
            table.insert(P.items, W.Label(group, name, Skin.S(10), y + Skin.S(4), { color = Skin.color.textDim }))
            local fx, bw, gap = Skin.S(92), Skin.S(22), Skin.S(3)
            if P.w < fx + 2 * bw + Skin.S(110) then      -- narrow panel: the label gets a line of its own above the buttons and the field
                fx = Skin.S(10)
                y = y + Skin.S(20)
            end
            local fw = math.max(Skin.S(24), P.w - fx - 2 * bw - 2 * gap - Skin.S(10) - gap * 2)
            local f
            local function Bump(dir)
                local v = tonumber(f:GetText())
                if not v then f:SetText(get()) return end
                f:SetText(string.format(fmt, v + dir * step))
                apply(f:GetText())
            end
            table.insert(P.items, W.Button(group, '-', fx, y, bw, Skin.S(22), function() Bump(-1) end))
            f = W.TextField(group, fx + bw + gap, y, fw, Skin.S(22), {
                text = get(),
                onEnter = function(text) apply(text) end,
            })
            table.insert(P.items, f.frame)
            table.insert(P.items, W.Button(group, '+', fx + bw + gap + fw + gap, y, bw, Skin.S(22), function() Bump(1) end))
            table.insert(P.updaters, function() f:SetText(get()) end)
            y = y + Skin.S(28)
            return f
        end
        local function ReadOnly(name, get)
            table.insert(P.items, W.Label(group, name, Skin.S(10), y, { color = Skin.color.textDim }))
            local v = W.Label(group, get(), Skin.S(92), y, {})
            table.insert(P.items, v)
            table.insert(P.updaters, function() v:SetText(get()) end)
            y = y + Skin.S(24)
        end
        local function Action(text, onClick)
            local b = W.Button(group, text, Skin.S(10), y, math.max(Skin.S(60), P.w - Skin.S(20)), Skin.S(26), onClick)
            table.insert(P.items, b)
            y = y + Skin.S(34)
        end

        --- Two compact sliders in one row (a, b: W.Slider options without `compact`); b may be nil.
        local function SliderPair(a, b)
            local avail = math.max(Skin.S(100), P.w - Skin.S(20))
            local stack = b and avail < Skin.S(330)      -- too narrow for two sliders side by side: one above the other
            local half = stack and avail or math.floor((avail - Skin.S(10)) / 2)
            local function Make(o, x)
                o.compact = true
                local s = W.Slider(group, o)
                s:Place(x, y, half)
                for _, c in { s.label, s.track, s.fill, s.thumb, s.minus, s.plus, s.field, s.field.frame } do table.insert(P.items, c) end
                table.insert(P.updaters, function() s:Refresh() end)
            end
            Make(a, Skin.S(10))
            if stack then
                y = y + Skin.S(52)
                Make(b, Skin.S(10))
            elseif b then
                Make(b, Skin.S(20) + half)
            end
            y = y + Skin.S(52)
        end
        local function Toggle(text, get, set, w)
            local b = W.Button(group, text, Skin.S(10), y, w or math.max(Skin.S(60), P.w - Skin.S(20)), Skin.S(24), function(self) set(self.on) end, { toggle = true })
            table.insert(P.items, b)
            table.insert(P.updaters, function() b:SetOn(get()) end)
            y = y + Skin.S(28)
        end
        local function Setting(S, label, key, min, max, step, fmt)
            return { label = label, min = min, max = max, step = step, fmt = fmt, get = function() return S[key] end, set = function(v) S[key] = v end }
        end
        local function RadiusSetting()
            return { label = 'Radius', min = 1, max = 64, step = 1, fmt = '%d', get = function() return Terrain.Brush.radius end, set = function(v) UI.SetRadius(v) end }
        end

        --- The settings of the prop brush / eraser (props.lua Settings).
        local function PropBrushPanel(tool)
            local Props = import('/lua/editor/props.lua')
            local S = Props.Settings
            Title(tool.label)
            P.live = true
            SliderPair(RadiusSetting(), Setting(S, 'Density', 'density', 0, 40, 0.5, '%.1f'))
            SliderPair(Setting(S, 'Spacing', 'minDist', 0, 20, 0.5, '%.1f'), Setting(S, 'Scale min', 'scaleMin', 10, 300, 5, '%d'))
            SliderPair(Setting(S, 'Scale max', 'scaleMax', 10, 300, 5, '%d'))
            Toggle('Random turn', function() return S.randomHeading end, function(v) S.randomHeading = v end)
            Toggle('Eraser: only this prop', function() return S.onlyActive end, function(v) S.onlyActive = v end)
            ReadOnly('Placing', function() return Props.Active and Basename(Props.Active) or 'none' end)
        end

        --- The settings of the decal brush / eraser (decals.lua Settings).
        local function DecalBrushPanel(tool)
            local Decals = import('/lua/editor/decals.lua')
            local S = Decals.Settings
            Title(tool.label)
            P.live = true
            SliderPair(RadiusSetting(), Setting(S, 'Size', 'size', 1, 120, 1, '%d'))
            SliderPair(Setting(S, 'Variance %', 'sizeVar', 0, 100, 5, '%d'), Setting(S, 'Density', 'density', 0, 10, 0.1, '%.1f'))
            SliderPair(Setting(S, 'Spacing', 'minDist', 0, 60, 1, '%d'), Setting(S, 'View dist.', 'cutoff', 100, 4000, 50, '%d'))
            Toggle('Random turn', function() return S.randomHeading end, function(v) S.randomHeading = v end)
            Toggle('With normals', function() return S.withNormals end, function(v) S.withNormals = v end)
            Toggle('Eraser: only this decal', function() return S.onlyActive end, function(v) S.onlyActive = v end)
            ReadOnly('Placing', function() return Decals.Active and Basename(Decals.Active) or 'none' end)
        end

        local function MarkerPanel(name)
            local function M() return MarkerTable()[name] end
            Title('Marker')
            Field('Name', function() return name end, function(t) if Tools.RenameSelection(t) then P.key = '' end end)
            -- the type: a button that opens the list of marker types; the marker takes the fields of the new type (markerprops.lua)
            do
                local MP = import('/lua/editor/markerprops.lua')
                table.insert(P.items, W.Label(group, 'Type', Skin.S(10), y + Skin.S(4), { color = Skin.color.textDim }))
                local b = W.Button(group, tostring(M() and M().type), Skin.S(92), y, math.max(Skin.S(60), P.w - Skin.S(102)), Skin.S(22), function()
                    local names = {}
                    for _, t in Tools.MarkerTypes() do table.insert(names, t.name) end
                    import('/lua/editor/gui/dialogs_mission.lua').PickName('Marker type of ' .. name, names, M() and M().type, function(newType)
                        local ok, why = MP.ChangeType(name, newType)
                        if not ok then pcall(function() UI.Say('marker: ' .. tostring(why)) end) end
                        P.key = ''
                    end)
                end)
                table.insert(P.items, b)
                table.insert(P.updaters, function() b:SetText(tostring(M() and M().type)) end)
                y = y + Skin.S(28)
            end
            local fx, fz
            fx = Stepper('X', function() return M() and string.format('%.2f', M().position[1]) or '' end,
                function(t)
                    local x, z = tonumber(t), tonumber(fz:GetText())
                    if x and z then Tools.SetMarkerPosition(name, x, z) end
                end, 1, '%.2f')
            fz = Stepper('Z', function() return M() and string.format('%.2f', M().position[3]) or '' end,
                function(t)
                    local x, z = tonumber(fx:GetText()), tonumber(t)
                    if x and z then Tools.SetMarkerPosition(name, x, z) end
                end, 1, '%.2f')
            ReadOnly('Height', function() return M() and string.format('%.2f', M().position[2]) or '' end)
            local MP = import('/lua/editor/markerprops.lua')
            if MP.IsCamera(M()) then
                -- a camera marker stores the view: heading and pitch in orientation (degrees here), zoom in its own field
                Stepper('Heading', function() return M() and string.format('%.0f', math.deg((M().orientation and M().orientation[1]) or 0)) or '' end,
                    function(t) local d = tonumber(t) if d and M() then M().orientation = M().orientation or { 0, 0, 0 } Tools.SetField(M(), { 'orientation', 1 }, math.rad(d), 'heading ' .. name) end end, 15, '%.0f')
                Stepper('Pitch', function() return M() and string.format('%.0f', math.deg((M().orientation and M().orientation[2]) or 0)) or '' end,
                    function(t) local d = tonumber(t) if d and M() then M().orientation = M().orientation or { 0, 0, 0 } Tools.SetField(M(), { 'orientation', 2 }, math.rad(d), 'pitch ' .. name) end end, 5, '%.0f')
            else
            Stepper('Rotation', function()
                    return M() and string.format('%.0f', math.deg((M().orientation and M().orientation[2]) or 0)) or ''
                end,
                function(t)
                    local d = tonumber(t)
                    if d and M() then
                        M().orientation = M().orientation or { 0, 0, 0 }
                        Tools.SetField(M(), { 'orientation', 2 }, math.rad(d), 'rotate ' .. name)
                    end
                end, 15, '%.0f')
            end
            if M() and M().resource then
                Stepper('Amount', function() return M() and tostring(M().amount or 100) or '' end,
                    function(t) local v = tonumber(t) if v and M() then Tools.SetField(M(), { 'amount' }, v, 'amount ' .. name) end end, 10, '%d')
                Stepper('Size', function() return M() and tostring(M().size or 1) or '' end,
                    function(t) local v = tonumber(t) if v and M() then Tools.SetField(M(), { 'size' }, math.floor(v), 'size ' .. name) end end, 1, '%d')
            end
            -- one row per field of the marker's template (camera zoom, path graph and adjacency, weather, effect ...)
            for _, f in MP.Fields(M() and M().type, M()) do
                local key = f.key
                if f.kind == 'number' then
                    local step = (f.default == math.floor(f.default)) and 1 or 0.1
                    Stepper(key, function() local v = MP.Get(name, key) return v ~= nil and string.format('%g', v) or '' end,
                        function(t) local v = tonumber(t) if v then MP.Set(name, key, v) end end, step, '%g')
                elseif f.kind == 'bool' then
                    Toggle(key, function() return MP.Get(name, key) and true or false end, function(on) MP.Set(name, key, on and true or false) end)
                elseif f.kind == 'vector' then
                    Field(key, function() return MP.VectorText(MP.Get(name, key)) end,
                        function(t) local v = MP.ParseVector(t) if v then MP.Set(name, key, v) end end)
                else
                    Field(key, function() return tostring(MP.Get(name, key) or '') end, function(t) MP.Set(name, key, t) end)
                end
            end
            if MP.IsCamera(M()) then
                Action('View through this camera', function() MP.LookThrough(name) end)
                Action('Set from the current camera', function() MP.SetFromCamera(name) end)
            end
            Gap(4)
            Info('Prop  ' .. Basename(M() and M().prop))
            local nearest, nd
            local m = M()
            if m then
                for other, o in MarkerTable() do
                    if other ~= name then
                        local dx, dz = o.position[1] - m.position[1], o.position[3] - m.position[3]
                        local d = math.sqrt(dx * dx + dz * dz)
                        if not nd or d < nd then nearest, nd = other, d end
                    end
                end
            end
            Info(nearest and string.format('Nearest  %s  (%.1f)', nearest, nd) or 'No other marker')
            Gap(6)
            Action('Delete', function() Tools.DeleteSelection() end)
        end

        local function AreaPanel(name)
            local function R() return AreaTable()[name] and AreaTable()[name].rectangle end
            Title('Area')
            Field('Name', function() return name end, function(t) if Tools.RenameSelection(t) then P.key = '' end end)
            local f = {}
            local function Apply()
                local x0, z0 = tonumber(f[1]:GetText()), tonumber(f[2]:GetText())
                local x1, z1 = tonumber(f[3]:GetText()), tonumber(f[4]:GetText())
                if x0 and z0 and x1 and z1 then Tools.SetAreaRect(name, x0, z0, x1, z1) end
            end
            f[1] = Stepper('X from', function() return R() and string.format('%.1f', R()[1]) or '' end, Apply, 1, '%.1f')
            f[2] = Stepper('Z from', function() return R() and string.format('%.1f', R()[2]) or '' end, Apply, 1, '%.1f')
            f[3] = Stepper('X to', function() return R() and string.format('%.1f', R()[3]) or '' end, Apply, 1, '%.1f')
            f[4] = Stepper('Z to', function() return R() and string.format('%.1f', R()[4]) or '' end, Apply, 1, '%.1f')
            local size = Info('')
            local function UpdateSize()
                local r = R()
                if r then
                    size:SetText(string.format('Size  %.1f x %.1f   (%.0f sq units)', r[3] - r[1], r[4] - r[2], (r[3] - r[1]) * (r[4] - r[2])))
                end
            end
            table.insert(P.updaters, UpdateSize)
            Gap(6)
            Action('Delete', function() Tools.DeleteSelection() end)
        end

        local function PropPanel()
            local Props = import('/lua/editor/props.lua')
            local n = table.getn(Props.Selection)
            Title(n == 1 and 'Prop' or (n .. ' props selected'))
            local info = Props.Info()
            if info then
                ReadOnly('Blueprint', function() return Basename(info.bp) end)
                local fx, fz
                fx = Stepper('X', function() local i = Props.Info() return i and string.format('%.2f', i.x) or '' end,
                    function(t) local x, z = tonumber(t), tonumber(fz:GetText()) if x and z then Props.MoveTo(x, z) end end, 1, '%.2f')
                fz = Stepper('Z', function() local i = Props.Info() return i and string.format('%.2f', i.z) or '' end,
                    function(t) local x, z = tonumber(fx:GetText()), tonumber(t) if x and z then Props.MoveTo(x, z) end end, 1, '%.2f')
                ReadOnly('Height', function() local i = Props.Info() return i and string.format('%.2f', i.y) or '' end)
                Stepper('Rotation', function() local i = Props.Info() return i and string.format('%.0f', math.mod(math.deg(i.heading) + 360, 360)) or '' end,
                    function(t) local d = tonumber(t) if d then Props.SetHeading(d) end end, 15, '%.0f')
                Stepper('Scale %', function() local i = Props.Info() return i and string.format('%.0f', i.sx * 100) or '' end,
                    function(t)
                        local v = tonumber(t)
                        local i = Props.Info()
                        if v and v > 0 and i and i.sx > 0 then Props.ScaleSelected((v / 100) / i.sx) end
                    end, 5, '%.0f')
            else
                Gap(2)
                Info('Rotate / scale the whole selection:')
                Action('Rotate +15', function() Props.RotateSelected(15) end)
                Action('Scale +10 %', function() Props.ScaleSelected(1.1) end)
                Action('Scale -10 %', function() Props.ScaleSelected(1 / 1.1) end)
            end
            Gap(6)
            Action('Delete', function() Props.DeleteSelected() end)
            Action('Deselect', function() Props.ClearSelection() end)
        end

        local function DecalPanel()
            local Decals = import('/lua/editor/decals.lua')
            local n = table.getn(Decals.Selection)
            Title(n <= 2 and 'Decal' or (n .. ' decals selected'))
            local info = Decals.Info()
            if info then
                ReadOnly('Texture', function() return Basename(info.tex) end)
                local fx, fz
                fx = Stepper('X', function() local i = Decals.Info() return i and string.format('%.2f', i.x) or '' end,
                    function(t) local x, z = tonumber(t), tonumber(fz:GetText()) if x and z then Decals.MoveTo(x, z) end end, 1, '%.2f')
                fz = Stepper('Z', function() local i = Decals.Info() return i and string.format('%.2f', i.z) or '' end,
                    function(t) local x, z = tonumber(fx:GetText()), tonumber(t) if x and z then Decals.MoveTo(x, z) end end, 1, '%.2f')
                Stepper('Rotation', function() local i = Decals.Info() return i and string.format('%.0f', math.mod(math.deg(i.heading) + 360, 360)) or '' end,
                    function(t) local d = tonumber(t) if d then Decals.SetHeading(d) end end, 15, '%.0f')
                Stepper('Size', function() local i = Decals.Info() return i and string.format('%.1f', i.size) or '' end,
                    function(t) local v = tonumber(t) if v and v > 0 then Decals.SetSize(v) end end, 1, '%.1f')
            end
            Gap(6)
            Action('Delete', function() Decals.DeleteSelected() end)
            Action('Deselect', function() Decals.ClearSelection() end)
        end

        local function UnitPanel()
            local Units = import('/lua/editor/units.lua')
            local n = table.getn(Units.Selection)
            Title(n == 1 and 'Unit' or (n .. ' units selected'))
            local info = Units.Info()
            if info then
                ReadOnly('Blueprint', function() return info.bp end)
                ReadOnly('Army', function() return info.army end)
                local fx, fz
                fx = Stepper('X', function() local i = Units.Info() return i and string.format('%.2f', i.x) or '' end,
                    function(t) local x, z = tonumber(t), tonumber(fz:GetText()) if x and z then Units.MoveTo(x, z) end end, 1, '%.2f')
                fz = Stepper('Z', function() local i = Units.Info() return i and string.format('%.2f', i.z) or '' end,
                    function(t) local x, z = tonumber(fx:GetText()), tonumber(t) if x and z then Units.MoveTo(x, z) end end, 1, '%.2f')
                Stepper('Rotation', function() local i = Units.Info() return i and string.format('%.0f', math.mod(math.deg(i.heading) + 360, 360)) or '' end,
                    function(t) local d = tonumber(t) if d then Units.SetHeading(d) end end, 15, '%.0f')
            else
                Action('Rotate +15', function() Units.RotateSelected(15) end)
            end
            Action('Give to the army of the Units panel', function() Units.SetArmy(Units.ArmyName) end)
            Gap(6)
            Action('Delete', function() Units.DeleteSelected() end)
            Action('Deselect', function() Units.ClearSelection() end)
        end

        local function ToolPanel()
            local tool
            for _, t in UI.Tools do
                if t.id == UI.State.tool then tool = t end
            end
            local kind = tool and tool.kind
            if kind == 'marker' then
                local tpl = Tools.Templates()[Tools.MarkerType] or {}
                Title('Marker tool')
                ReadOnly('Type', function() return Tools.MarkerType end)
                ReadOnly('Prop', function() return Basename(tpl.prop) end)
                if tpl.resource then
                    ReadOnly('Resource', function() return string.format('amount %s, size %s', tostring(tpl.amount), tostring(tpl.size)) end)
                end
                Gap(6)
                Help('Click in the world to place one. Pick another type in the Markers panel. Mass and hydrocarbon markers snap to the build grid.')
            elseif kind == 'area' then
                Title('Area tool')
                Help('Drag in the world to draw a rectangle. With the Select area tool you can move it, or drag its handles to resize.')
            elseif tool and tool.id == 'army' then
                Title('Start position tool')
                ReadOnly('Next', function() return import('/lua/editor/armies.lua').NextName() end)
                Gap(6)
                Help('Click to place the next start position (ARMY_n). A ghost with its name follows the pointer; with symmetry on the mirror images show too and are placed together.')
            elseif tool and tool.id == 'chain' then
                local Chains = import('/lua/editor/chains.lua')
                Title('Draw chain')
                P.live = true      -- the chain changes outside of Tools.Changed
                ReadOnly('Chain', function() return Chains.Current or '(a new chain)' end)
                Gap(6)
                Help('Click to place a marker at the end of the chain. Ctrl+click starts a new chain; pick a chain in the Chains panel to extend it. With symmetry on the mirror images get chains of their own.')
            elseif tool and (tool.id == 'prop' or tool.id == 'prop_erase') then
                PropBrushPanel(tool)
            elseif tool and (tool.id == 'decal' or tool.id == 'decal_erase') then
                DecalBrushPanel(tool)
            elseif kind == 'brush' then
                Title(string.find(string.lower(tool.label or ''), 'brush', 1, true) and tool.label or ((tool.label or 'Brush') .. ' brush'))
                P.live = true      -- the values change from the Brush panel, outside of Tools.Changed
                ReadOnly('Radius', function() return string.format('%d', Terrain.Brush.radius) end)
                if tool.id == 'paint' or tool.id == 'erase' then
                    local Strata = import('/lua/editor/strata.lua')
                    ReadOnly('Layer', function() return Strata.LayerName(Strata.Active) end)
                    ReadOnly('Strength', function() return string.format('%d%%', Strata.Brush.strength) end)
                else
                    ReadOnly('Strength', function() return string.format('%d%%', UI.GetStrengthPercent()) end)
                end
                if tool.id == 'flatten' or tool.id == 'plateau' then
                    -- the height the ground is brought to: the height under the first dab of the stroke, or a fixed level
                    local B = Terrain.Brush
                    Toggle('Fixed level', function() return B.level ~= nil end, function(on) B.level = on and (B.levelValue or 30) or nil end)
                    SliderPair({ label = 'Level (units)', min = 0, max = 300, step = 0.5, fmt = '%.1f',
                                 get = function() return B.levelValue or 30 end,
                                 set = function(v) B.levelValue = v if B.level ~= nil then B.level = v end end })
                end
                Gap(6)
                Help('Drag over the terrain. The ring shows the footprint of one dab.')
            else
                Title('Map')
                local mk, ar = 0, 0
                for _ in MarkerTable() do mk = mk + 1 end
                for _ in AreaTable() do ar = ar + 1 end
                ReadOnly('Markers', function() return tostring(mk) end)
                ReadOnly('Areas', function() return tostring(ar) end)
                Gap(6)
                if tool and tool.id == 'select' then
                    Help('Select marker: click a marker to select it, drag on empty ground for a box, Shift adds or removes. Drag a selected marker to move it. Areas are not picked here: use the Select area tool.')
                elseif tool and tool.id == 'area_select' then
                    Help('Select area: click inside an area to select it (the smallest one under the pointer), drag on empty ground for a box, Shift adds or removes. Drag a selected area to move it, or its handles to resize. Markers are not picked here: use the Select marker tool.')
                else
                    Help('Click a marker or area to select it. Drag on empty ground to box select; Shift adds or removes.')
                end
            end
        end

        local function MultiPanel()
            local markers, areas = 0, 0
            local types = {}
            for _, it in Tools.Items do
                if it.kind == 'marker' then
                    markers = markers + 1
                    local m = MarkerTable()[it.name]
                    local t = m and tostring(m.type) or '?'
                    types[t] = (types[t] or 0) + 1
                else
                    areas = areas + 1
                end
            end
            Title(table.getn(Tools.Items) .. ' objects selected')
            ReadOnly('Markers', function() return tostring(markers) end)
            ReadOnly('Areas', function() return tostring(areas) end)
            Gap(4)
            local names = {}
            for t, n in types do table.insert(names, t) end
            table.sort(names)
            for i, t in names do
                if i <= 6 then Info(string.format('%s  x%d', t, types[t])) end
            end
            if table.getn(names) > 6 then Info('...') end
            Gap(6)
            Help('Drag one of them to move all. Shift+click adds or removes.')
            Gap(6)
            Action('Delete all', function() Tools.DeleteSelection() end)
            Action('Deselect', function() Tools.Select(false) end)
        end

        local function ContextKey()
            local sel = Tools.Selection
            if Tools.SelectionCount() > 1 then
                local first, last = Tools.Items[1], Tools.Items[table.getn(Tools.Items)]
                return 'multi:' .. Tools.SelectionCount() .. ':' .. first.name .. ':' .. last.name
            end
            if UI.State.tool == 'unit_select' and table.getn(import('/lua/editor/units.lua').Selection) > 0 then
                return 'units:' .. import('/lua/editor/units.lua').SelRevision
            end
            if UI.State.tool == 'decal_select' and table.getn(import('/lua/editor/decals.lua').Selection) > 0 then
                return 'decals:' .. import('/lua/editor/decals.lua').SelRevision
            end
            if UI.State.tool == 'prop_select' and table.getn(import('/lua/editor/props.lua').Selection) > 0 then
                return 'props:' .. import('/lua/editor/props.lua').SelRevision
            end
            if sel.kind and Map.Doc and ((sel.kind == 'marker' and MarkerTable()[sel.name]) or (sel.kind == 'area' and AreaTable()[sel.name])) then
                return sel.kind .. ':' .. tostring(sel.name)
            end
            return 'tool:' .. tostring(UI.State.tool) .. ':' .. Tools.MarkerType
        end

        local function BuildBody()
            Clear()
            P.live = false
            y = Skin.S(10)
            local sel = Tools.Selection
            if UI.State.tool == 'unit_select' and table.getn(import('/lua/editor/units.lua').Selection) > 0 then
                UnitPanel()
            elseif UI.State.tool == 'decal_select' and table.getn(import('/lua/editor/decals.lua').Selection) > 0 then
                DecalPanel()
            elseif UI.State.tool == 'prop_select' and table.getn(import('/lua/editor/props.lua').Selection) > 0 then
                PropPanel()
            elseif Map.Doc and Tools.SelectionCount() > 1 then
                MultiPanel()
            elseif Map.Doc and sel.kind == 'marker' and MarkerTable()[sel.name] then
                MarkerPanel(sel.name)
            elseif Map.Doc and sel.kind == 'area' and AreaTable()[sel.name] then
                AreaPanel(sel.name)
            else
                ToolPanel()
            end
            P.key = ContextKey()
            P.seen = Tools.Changed
            for _, u in P.updaters do pcall(u) end
        end

        local function Build()
            W.BeginLayout(group)   -- the content height is measured anew (what does not fit the panel scrolls)
            local ok, err = pcall(BuildBody)
            W.EndLayout(group)
            if not ok then LOG('EDITOR gui: properties build failed: ' .. tostring(err)) end
        end

        function P:Refresh()
            if ContextKey() ~= P.key then
                Build()
            elseif Tools.Changed ~= P.seen or P.live then
                P.seen = Tools.Changed
                for _, u in P.updaters do pcall(u) end
            end
        end
        function P:OnResize(w, h)
            P.w, P.h = w, h
            Build()
        end
        function P:Destroy()
            Clear()
        end
        return P
    end,
}

-- ---- validation ------------------------------------------------------------------------------------------------------------------------

local Validate = import('/lua/editor/validate.lua')
local ModCheck = import('/lua/editor/modcheck.lua')
local Bp = import('/lua/editor/bpedit.lua')
local Grid = import('/lua/editor/grid.lua')

--- Selects the objects of an issue and moves the camera over them.
local function ShowIssue(issue)
    Tools.Select(false)
    for _, name in issue.names do
        if MarkerTable()[name] then Tools.Select('marker', name, 'add') end
    end
    local cam = GetCamera('WorldCamera')
    if cam and issue.x then
        cam:MoveToRegion(Rect(issue.x - 24, issue.z - 18, issue.x + 24, issue.z + 18), 0.4)
    end
end

Panels.Register{
    id = 'validation', title = 'Validation',
    create = function(group, host)
        local P = { rev = -1 }
        live.validation = P
        P.summary = W.Label(group, '', Skin.S(10), Skin.S(8), { color = Skin.color.textDim })
        P.run = W.Button(group, 'Check now', 0, 0, Skin.S(90), Skin.S(22), function() Validate.Run() ModCheck.Run() end)
        P.snap = W.Button(group, 'Snap to grid', 0, 0, Skin.S(100), Skin.S(22), function() Validate.FixAlignment() end)
        P.pull = W.Button(group, 'Pull inside', 0, 0, Skin.S(84), Skin.S(22), function() Validate.PullMarkersInside() end)
        -- problems of a mod project's new units can carry a fix (unitcheck.lua: write the files, add the builders ...): the button runs the selected one, `fixAll` every one
        P.modSel = false
        P.fix = W.Button(group, 'Fix', 0, 0, Skin.S(150), Skin.S(22), function()
            local issue = P.modSel and ModCheck.Issues[P.modSel]
            if issue and issue.fix then
                pcall(issue.fix)
                ModCheck.Touch()
                ModCheck.Run()
            end
        end)
        P.fixAll = W.Button(group, 'Fix all', 0, 0, Skin.S(60), Skin.S(22), function()
            local fixes = {}
            for _, issue in ModCheck.Issues do
                if issue.fix then table.insert(fixes, issue.fix) end
            end
            for _, fix in fixes do pcall(fix) end
            ModCheck.Touch()
            ModCheck.Run()
        end)
        P.list = W.VirtualList(group, {
            -- the map checks first, then the problems of the open mod project (modcheck.lua)
            getCount = function() return table.getn(Validate.Issues) + table.getn(ModCheck.Issues) end,
            bind = function(row, index)
                local mapCount = table.getn(Validate.Issues)
                if index > mapCount then
                    local issue = ModCheck.Issues[index - mapCount]
                    local colors = { E = 'ffff7070', W = 'ffffb060', I = 'ffb0b8c0' }
                    RowText(row, 'Mod project: ' .. issue.text .. (issue.fix and ('   [fix: ' .. tostring(issue.fixLabel or 'fix') .. ']') or ''), colors[issue.sev] or 'ffffb060')
                    return
                end
                local issue = Validate.Issues[index]
                local colors = { blocked = 'ffff7070', stacked = 'ffffb060', unaligned = 'ffffe070', map = 'ffffc880', start = 'ffffe070', water = 'ff80b8ff', prop = 'ffff7070' }
                RowText(row, issue.text, colors[issue.kind] or 'ffffb060')
            end,
            onSelect = function(index)
                local mapCount = table.getn(Validate.Issues)
                if index > mapCount then
                    P.modSel = index - mapCount
                    P.rev = -1
                    P:Refresh()
                    return
                end
                P.modSel = false
                local issue = Validate.Issues[index]
                if issue then ShowIssue(issue) end
                P.rev = -1
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        function P:Refresh()
            ModCheck.Update()
            local key = Validate.Revision * 1000 + ModCheck.Revision
            if P.rev == key then return end
            P.rev = key
            local total = table.getn(Validate.ResourceMarkers())
            local text
            if Validate.State == 'running' then
                text = 'Checking ' .. total .. ' resource markers ...'
            elseif table.getn(Validate.Issues) == 0 then
                text = total .. ' resource markers, no problems found'
            else
                text = string.format('%d resource markers, %d problem(s)', total, table.getn(Validate.Issues))
            end
            if Bp.Project then
                local e, w = 0, 0
                for _, issue in ModCheck.Issues do
                    if issue.sev == 'E' then e = e + 1 elseif issue.sev == 'W' then w = w + 1 end
                end
                text = text .. string.format('   |   project %s: %d error(s), %d warning(s)', Bp.Project, e, w)
            end
            P.text = text
            if P.w then P:LayoutTop() end       -- the summary's width changed: the buttons beside it may no longer fit
            P.list:Refresh()
            local sel = P.modSel and ModCheck.Issues[P.modSel]
            local fixable = 0
            for _, issue in ModCheck.Issues do if issue.fix then fixable = fixable + 1 end end
            P.fix:SetHidden(not (sel and sel.fix))
            if sel and sel.fix then P.fix:SetText(string.sub(tostring(sel.fixLabel or 'Fix'), 1, 24)) end
            P.fixAll:SetHidden(fixable == 0)
        end
        --- The summary text on the left and the three buttons on the right of the same row when both fit; otherwise the buttons go on a row of their own under the summary
        --- (Maui does not clip: on a narrow panel the buttons used to sit on top of the summary text). The list takes what is left.
        function P:LayoutTop()
            local w, h = P.w, P.h
            local pad, bh, gap = Skin.S(6), Skin.S(22), Skin.S(6)
            local bw = Skin.S(84) + Skin.S(100) + Skin.S(90) + 2 * gap
            local sx, sy = Skin.S(10), Skin.S(8)
            W.Fit(P.summary, P.text or '', w - sx - pad)
            local top
            if sx + P.summary.Width() + Skin.S(12) + bw + pad <= w then
                W.Place(P.pull, group, w - bw - pad, pad, Skin.S(84), bh)
                W.Place(P.snap, group, w - bw - pad + Skin.S(84) + gap, pad, Skin.S(100), bh)
                W.Place(P.run, group, w - Skin.S(90) - pad, pad, Skin.S(90), bh)
                top = Skin.S(34)
            else
                local below = sy + P.summary.Height() + Skin.S(4)
                local bottom = W.Flow(group, { { P.run, Skin.S(90) }, { P.snap, Skin.S(100) }, { P.pull, Skin.S(84) } }, pad, below, w - 2 * pad, bh, gap)
                top = bottom + pad
            end
            P.list:SetRect(pad, top, w - 2 * pad, math.max(Skin.S(40), h - top - Skin.S(28) - pad))
        end
        function P:OnResize(w, h)
            local pad = Skin.S(6)
            P.w, P.h = w, h
            W.Place(P.fix, group, pad, h - Skin.S(22) - pad, Skin.S(150), Skin.S(22))
            W.Place(P.fixAll, group, pad + Skin.S(154), h - Skin.S(22) - pad, Skin.S(60), Skin.S(22))
            P.rev = -1
            P:Refresh()
            P:LayoutTop()
        end
        return P
    end,
}

-- ---- commands and keys ------------------------------------------------------------------------------------------------------------------

Commands.Register{ id = 'view.grid', title = 'View: build grid', keys = 'G', run = function()
    Grid.Visible = not Grid.Visible
    local shell = import('/lua/editor/gui/shell.lua')
    if shell.S and shell.S.gridButton then shell.S.gridButton:SetOn(Grid.Visible) end
end }
Commands.Register{ id = 'validate.snap', title = 'Snap resource markers to grid', run = function() Validate.FixAlignment() end }
Commands.Register{ id = 'validate.pullmarkers', title = 'Move stray markers onto the map', run = function() Validate.PullMarkersInside() end }
Commands.Register{ id = 'validate.run', title = 'Validate resource markers', run = function() Validate.Run() end }
Commands.Register{ id = 'edit.copy', title = 'Copy', keys = 'Ctrl+C', run = function()
    if UI.State.tool == 'paths' then import('/lua/editor/paths.lua').CopyCurrent() return end
    import('/lua/editor/clipboard.lua').Copy()
end }
Commands.Register{ id = 'edit.cut', title = 'Cut', keys = 'Ctrl+X', run = function() import('/lua/editor/clipboard.lua').Cut() end }
Commands.Register{ id = 'edit.paste', title = 'Paste at cursor', keys = 'Ctrl+V', run = function()
    if UI.State.tool == 'paths' then
        local p = GetMouseWorldPos()
        import('/lua/editor/paths.lua').Paste(p and p[1], p and p[3])
        return
    end
    import('/lua/editor/clipboard.lua').Paste()
end }
Commands.Register{ id = 'edit.duplicate', title = 'Duplicate', keys = 'Ctrl+D', run = function()
    if UI.State.tool == 'paths' then
        local Paths = import('/lua/editor/paths.lua')
        if Paths.Current then Paths.Duplicate(Paths.Current) end
        return
    end
    import('/lua/editor/clipboard.lua').Duplicate()
end }
Commands.Register{ id = 'edit.delete', title = 'Delete selection', keys = 'Delete', run = function()
    if UI.State.tool == 'paths' then
        local Paths = import('/lua/editor/paths.lua')
        if not Paths.DeletePoints() and Paths.Current then Paths.Delete(Paths.Current) end
        return
    end
    local Props = import('/lua/editor/props.lua')
    local Decals = import('/lua/editor/decals.lua')
    local Units = import('/lua/editor/units.lua')
    if UI.State.tool == 'unit_select' and table.getn(Units.Selection) > 0 then
        Units.DeleteSelected()
    elseif UI.State.tool == 'decal_select' and table.getn(Decals.Selection) > 0 then
        Decals.DeleteSelected()
    elseif UI.State.tool == 'prop_select' and table.getn(Props.Selection) > 0 then
        Props.DeleteSelected()
    else
        Tools.DeleteSelection()
    end
end }
Commands.Register{ id = 'edit.undo', title = 'Undo', keys = 'Ctrl+Z', run = function() UI.DoUndo() end }
Commands.Register{ id = 'edit.redo', title = 'Redo', keys = 'Ctrl+Y', keys2 = 'Ctrl+Shift+Z', run = function() UI.DoRedo() end }
--- Every selection of every select tool (markers and areas, units, props, decals), the way the menus ask for it.
function SelectionCounts()
    return Tools.SelectionCount(), table.getn(import('/lua/editor/units.lua').Selection), table.getn(import('/lua/editor/props.lua').Selection), table.getn(import('/lua/editor/decals.lua').Selection)
end

function AnySelection()
    local a, b, c, d = SelectionCounts()
    return a + b + c + d > 0
end

Commands.Register{ id = 'edit.deselect', title = 'Deselect', keys = 'Ctrl+Shift+A', run = function()
    Tools.Select(false)
    import('/lua/editor/units.lua').ClearSelection()
    import('/lua/editor/props.lua').ClearSelection()
    import('/lua/editor/decals.lua').ClearSelection()
end }
--- Select all: the markers and areas with the select tool, the units with the unit select tool.
Commands.Register{ id = 'edit.selectall', title = 'Select all', keys = 'Ctrl+A', run = function()
    if UI.State.tool == 'unit_select' then
        local Units = import('/lua/editor/units.lua')
        Units.ClearSelection()
        for _, u in Units.All() do Units.Select(u, 'add') end
    elseif (UI.State.tool == 'select' or UI.State.tool == 'area_select') and Map.Doc then
        -- every object the tool can pick: the Select marker tool the markers, the Select area tool the areas
        local list = {}
        if UI.State.tool == 'select' then
            for _, name in Map.MarkerNames() do table.insert(list, { kind = 'marker', name = name }) end
        else
            for _, name in Map.AreaNames() do table.insert(list, { kind = 'area', name = name }) end
        end
        Tools.SelectMany(list, false)
    end
end }
-- the tools without a digit slot (the table order of ui.lua keeps the digits of the older tools)
Commands.Register{ id = 'tool.area_select', title = 'Tool: Select area', keys = 'Alt+A', run = function()
    UI.SelectTool('area_select')
end }
Commands.Register{ id = 'tool.chain', title = 'Tool: Draw chain', keys = 'Alt+C', run = function()
    UI.SelectTool('chain')
end }
-- digits pick the Nth tool of the showing workspace (Terrain: raise, lower, ...; Objects: select, marker, area, ...)
for n = 1, 8 do
    local slot = n
    Commands.Register{ id = 'tool.slot' .. slot, title = 'Tool: slot ' .. slot .. ' of the workspace', keys = tostring(slot), run = function()
        local tool = UI.AllowedTools()[slot]
        if tool then UI.SelectTool(tool.id) end
    end }
end
