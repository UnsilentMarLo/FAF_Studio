-- The Unit viewer panel (unitview.lua): put the unit chosen in the Units panel (or the one open in the Unit lab) on the viewer stage (an empty stage with its own camera; "Stage" switches to the map)
-- and frame it (Iso / Front / Side / Back / Top / Fit, or turn the camera around the unit's centre with the two angle sliders), show its ranges, senses, footprint and skirt, its 3D hit box and its bones,
-- and play, slow down or scrub the animations its blueprint names. The list below shows the animations or the bones (a click picks the bone: its axes are drawn); the buttons in the fourth row cycle
-- the LOD the camera distance selects, the team colour and the lighting preset.
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Units = import('/lua/editor/units.lua')
local View = import('/lua/editor/unitview.lua')

live = {}

--- Shows or hides a button, label or slider (a slider is several controls).
local function ShowControl(c, shown)
    local parts = c.track and { c.label, c.track, c.fill, c.thumb, c.minus, c.plus, c.field and c.field.frame } or { c }
    for _, part in parts do
        if part then
            if shown then part:Show() else part:Hide() end
        end
    end
end

local function Say(text)
    pcall(function() UI.Say(text) end)
end

Panels.Register{
    id = 'unitview', title = 'Unit viewer',
    create = function(group, host)
        local P = { anims = {}, playing = false, listMode = 'animations', lodIndex = 0, colorIndex = 1, lightIndex = 1, errorShown = false }
        live.unitview = P

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end
        P.spawn = Btn('Show unit', 76, function()
            local id = Units.Active
            local ok, labPanel = pcall(function() return import('/lua/editor/gui/panels_unitlab.lua').live.unitlab end)
            if ok and labPanel and labPanel.unit then id = labPanel.unit end
            if not id then Say('pick a unit in the Units panel first') return end
            local good, why = View.Spawn(id)
            if not good then Say('unit viewer: ' .. tostring(why)) end
            P.anims = View.Animations(id)
            P.lodIndex = 0
            P:Refresh()
        end)
        P.remove = Btn('Remove', 60, function() View.Remove() P.anims = {} P:Refresh() end)
        P.stage = Btn('Stage: Viewer', 104, function()
            View.SetStage(View.Stage == 'viewer' and 'map' or 'viewer')
            P:Refresh()
        end)

        -- camera row
        P.cam = {}
        for _, c in { { 'Iso', 'iso', 44 }, { 'Front', 'front', 50 }, { 'Side', 'side', 46 }, { 'Back', 'back', 46 }, { 'Top', 'top', 42 }, { 'Fit', 'fit', 38 }, { 'Range', 'range', 52 } } do
            local mode = c[2]
            table.insert(P.cam, { btn = Btn(c[1], c[3], function()
                if mode == 'fit' then View.Fit() else View.Frame(mode) end
            end), w = c[3] })
        end
        P.sHeading = W.Slider(group, { label = 'Camera heading around the unit (radians)', min = -6.3, max = 6.3, step = 0.05, fmt = '%.2f', get = function() return View.Heading end,
            set = function(v) View.Orbit(v - View.Heading, 0) end })
        P.sPitch = W.Slider(group, { label = 'Camera pitch (radians)', min = 0.05, max = 1.5, step = 0.02, fmt = '%.2f', get = function() return View.Pitch end,
            set = function(v) View.Orbit(0, v - View.Pitch) end })

        local function Toggle(key, text, w)
            local b
            b = Btn(text, w, function(self)
                View.Show[key] = self.on
                View.Refresh()
            end, { toggle = true })
            return b
        end
        P.tog = {
            { Toggle('range', 'Rings', 50), 50, 'range' }, { Toggle('senses', 'Senses', 58), 58, 'senses' }, { Toggle('footprint', 'Footprint', 68), 68, 'footprint' },
            { Toggle('hitbox', 'Hit box', 60), 60, 'hitbox' }, { Toggle('bones', 'Bones', 52), 52, 'bones' }, { Toggle('grid', 'Grid', 44), 44, 'grid' }, { Toggle('lock', 'Lock', 44), 44, 'lock' },
        }

        -- fourth row: LOD, team colour, light, list mode
        P.bLod = Btn('LOD', 74, function()
            local lods = View.LODs(View.Id)
            if table.getn(lods) == 0 then Say('unit viewer: the blueprint names no LODs (show a unit first)') return end
            P.lodIndex = P.lodIndex + 1
            if P.lodIndex > table.getn(lods) then P.lodIndex = 1 end
            View.ShowLOD(P.lodIndex)
            P:Refresh()
        end)
        P.bColor = Btn('Team: Army', 110, function()
            P.colorIndex = P.colorIndex + 1
            if P.colorIndex > table.getn(View.Colors) then P.colorIndex = 1 end
            View.SetColor(View.Colors[P.colorIndex].name)
            P:Refresh()
        end)
        P.bLight = Btn('Light: Map', 110, function()
            P.lightIndex = P.lightIndex + 1
            if P.lightIndex > table.getn(View.Lights) then P.lightIndex = 1 end
            View.SetLight(View.Lights[P.lightIndex].name)
            P:Refresh()
        end)
        P.bList = Btn('Bones', 76, function()
            P.listMode = P.listMode == 'animations' and 'bones' or 'animations'
            if P.listMode == 'bones' then
                View.Show.bones = true
                View.Refresh()
            end
            P:Refresh()
        end)

        P.list = W.VirtualList(group, {
            extra = true, rowH = 22,
            getCount = function() return P.listMode == 'bones' and table.getn(View.Bones) or table.getn(P.anims) end,
            bind = function(row, index)
                local c = Skin.color
                if P.listMode == 'bones' then
                    local b = View.Bones[index]
                    if not b then return end
                    W.Fit(row.text, b.name, math.max(Skin.S(30), row.bg.Width() - Skin.S(150)))
                    row.text:SetColor(View.BoneSel == b.name and c.accent or c.text)
                    row.extra:SetText(string.format('%.2f %.2f %.2f', b.x, b.y, b.z))
                    row.extra:SetColor(c.textDim)
                    local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                    row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                    row.text.Top:Set(function() return row.bg.Top() + ty end)
                    local w2 = row.extra.Width()
                    row.extra.Left:Set(function() return row.bg.Right() - w2 - Skin.S(8) end)
                    row.extra.Top:Set(function() return row.bg.Top() + ty end)
                    return
                end
                local a = P.anims[index]
                if not a then return end
                W.Fit(row.text, a.label, math.max(Skin.S(30), row.bg.Width() - Skin.S(30)))
                row.text:SetColor(P.playing == a.path and c.accent or c.text)
                row.extra:SetText('')
                local ty = math.floor((row.bg.Height() - row.text.Height()) / 2)
                row.text.Left:Set(function() return row.bg.Left() + Skin.S(6) end)
                row.text.Top:Set(function() return row.bg.Top() + ty end)
            end,
            onSelect = function(index)
                if P.listMode == 'bones' then
                    local b = View.Bones[index]
                    if b then View.SelectBone(b.name) P.list:Refresh() end
                    return
                end
                local a = P.anims[index]
                if not a then return end
                P.playing = a.path
                View.Play(a.path, true)
                P:Refresh()
            end,
            bgColor = Skin.color.panel,
        })
        P.stop = Btn('Stop animation', 100, function() P.playing = false View.Stop() P:Refresh() end)
        P.rate = W.Slider(group, { label = 'Animation speed', min = 0, max = 3, step = 0.05, fmt = '%.2f', get = function() return View.Rate end,
            set = function(v) View.SetRate(v) end })
        P.scrub = W.Slider(group, { label = 'Position in the animation (holds it)', min = 0, max = 100, step = 1, fmt = '%d', get = function() return P.pos or 0 end,
            set = function(v) P.pos = v View.Scrub(v / 100) end })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })

        function P:Refresh()
            P.list:Refresh()
            for _, t in P.tog do t[1]:SetOn(View.Show[t[3]]) end
            P.rate:Refresh() P.scrub:Refresh() P.sHeading:Refresh() P.sPitch:Refresh()
            P.stage:SetText(View.Stage == 'viewer' and 'Stage: Viewer' or 'Stage: Map')
            P.bList:SetText(P.listMode == 'bones' and 'Animations' or 'Bones')
            if P.shownMode ~= P.listMode and P.w then
                P.shownMode = P.listMode
                P:OnResize(P.w, P.h)
                return
            end
            local lods = View.LODs(View.Id)
            P.bLod:SetText(P.lodIndex > 0 and ('LOD ' .. P.lodIndex .. '/' .. table.getn(lods)) or ('LOD (' .. table.getn(lods) .. ')'))
            P.bColor:SetText('Team: ' .. View.ColorName)
            P.bLight:SetText('Light: ' .. View.LightName)
            local text = View.Id and ('Showing ' .. View.Id .. ', ' .. table.getn(P.anims) .. ' animations, ' .. table.getn(View.Bones) .. ' bones') or 'No unit shown'
            if View.BoneSel then text = text .. '   bone ' .. View.BoneSel end
            if View.LastError then text = View.LastError end        -- (what went wrong: the Console has the same line)
            P.errorShown = View.LastError
            local info = View.LODInfo
            if info and P.lodIndex > 0 and info.n == P.lodIndex then
                text = text .. string.format('   LOD %d: used from %d to %d, camera at %d%s', info.n, info.from, info.cutoff, info.depth, info.reached and '' or ' (the camera cannot go further)')
            end
            W.Fit(P.status, text, (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            P.shownMode = P.listMode
            local pad = Skin.S(8)
            local iw = w - 2 * pad
            local y = W.Flow(group, { { P.spawn, Skin.S(76) }, { P.remove, Skin.S(60) }, { P.stage, Skin.S(104) } }, pad, pad, iw, Skin.S(22), Skin.S(4)) + Skin.S(4)
            local cam = {}
            for _, c in P.cam do table.insert(cam, { c.btn, Skin.S(c.w) }) end
            y = W.Flow(group, cam, pad, y, iw, Skin.S(22), Skin.S(3)) + Skin.S(4)
            local half = math.floor((w - 3 * pad) / 2)
            P.sHeading:Place(pad, y, half)
            P.sPitch:Place(pad * 2 + half, y, half)
            y = y + Skin.S(48)
            local tog = {}
            for _, t in P.tog do table.insert(tog, { t[1], Skin.S(t[2]) }) end
            y = W.Flow(group, tog, pad, y, iw, Skin.S(22), Skin.S(3)) + Skin.S(4)
            y = W.Flow(group, { { P.bLod, Skin.S(74) }, { P.bColor, Skin.S(110) }, { P.bLight, Skin.S(110) }, { P.bList, Skin.S(76) } }, pad, y, iw, Skin.S(22), Skin.S(4)) + Skin.S(4)
            W.Place(P.status, group, pad, y)
            local top = y + Skin.S(18)
            -- the animation controls (stop, speed, position) sit below the list in the animation mode only: the bone list takes their room
            local anim = P.listMode == 'animations'
            for _, c in { P.stop, P.rate, P.scrub } do ShowControl(c, anim) end
            local foot = anim and Skin.S(84) or 0
            local listH = math.max(Skin.S(44), h - top - foot - pad)
            P.list:SetRect(pad, top, w - 2 * pad, listH)
            y = math.max(h - foot, top + listH + Skin.S(4))      -- a short panel scrolls instead of laying the controls over each other
            W.Place(P.stop, group, pad, y, Skin.S(100), Skin.S(22))
            P.rate:Place(pad, y + Skin.S(26), half)
            P.scrub:Place(pad * 2 + half, y + Skin.S(26), half)
            P:Refresh()
        end
        return P
    end,
}

--- Called by the shell about four times a second: the bone list follows the bones (they are redrawn every frame by unitview.OnFrame).
function Refresh()
    local P = live.unitview
    if P and View.Show.bones and P.listMode == 'bones' then pcall(function() P.list:Refresh() end) end
    if P and P.errorShown ~= View.LastError then pcall(function() P:Refresh() end) end        -- the sim's answer arrives a moment after Show unit
end
