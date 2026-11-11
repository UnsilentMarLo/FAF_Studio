-- The Particle preview panel (WP8 of docs/projects/editor/EDITOR_PORT_ANALYSIS.md): the open emitter, beam or trail played alone on a grid, seen from an orbit camera. The engine renders the effect
-- through the game's own particle renderer into an offscreen picture (ed_fxv_*, EdFxView.cpp) and offers it to the UI as the texture `/ed_dyn/fxview`; this panel shows it in a Maui Bitmap, so it
-- works the same docked and in a pop-out window (the browser opens it in one: Shell.OpenPanelWindow).
--
-- A drag with the mouse turns the camera, the wheel zooms. Every edit of the open file reaches the picture within a frame (fxparticle.lua Apply). The view renders only while a panel shows it
-- (the panel's 4 Hz refresh calls ed_fxv_touch; one second after the last touch the engine stops rendering it).
--
-- Lua 5.0 dialect.

local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Dragger = import('/lua/maui/dragger.lua').Dragger
local Fx = import('/lua/editor/fxparticle.lua')

live = {}

TEXTURE = '/ed_dyn/fxview'
WIDTH, HEIGHT = 1024, 640      -- at least 1024 wide: a smaller Maui texture is packed into the UI atlas once and never updated (EdFxView.cpp)

--- The view's options, kept across panel instances (a panel moved to a pop-out is built again).
Opts = { background = 0, ground = true, grid = true, height = 0, turn = false, playing = true, loop = true, scale = 1 }

--- (Re)opens the view with the current options. false when this engine has no preview natives.
function Open()
    if not ed_fxv_view then return false end
    ed_fxv_view({ pictureWidth = WIDTH, pictureHeight = HEIGHT, background = Opts.background, ground = Opts.ground, grid = Opts.grid, turn = Opts.turn, playing = Opts.playing,
                  loop = Opts.loop, scale = Opts.scale, height = Opts.height })
    return true
end

local function ShowControl(c, shown)
    local parts = c.track and { c.label, c.track, c.fill, c.thumb, c.minus, c.plus, c.field and c.field.frame } or { c }
    for _, part in parts do
        if part then
            if shown then part:Show() else part:Hide() end
        end
    end
end

Panels.Register{
    id = 'particleview', title = 'Particle preview',
    minW = 240,
    create = function(group, host)
        local P = { w = 300, h = 400 }
        live.particleview = P
        local c = Skin.color
        local available = Open()
        local function Push() Open() end

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        P.img = Bitmap(group)
        P.img.Depth:Set(function() return group.Depth() + 5 end)
        if available then P.img:SetTexture(TEXTURE) else P.img:SetSolidColor(c.panelAlt) end
        P.msg = W.Label(group, available and '' or 'This engine build has no particle preview.', 0, 0, { color = c.textDim })

        -- the mouse: drag = orbit, wheel = zoom
        P.img.HandleEvent = function(self, event)
            if event.Type == 'ButtonPress' then
                local last = { event.MouseX, event.MouseY }
                local dragger = Dragger()
                dragger.OnMove = function(d, x, y)
                    ed_fxv_camera('turn', last[1] - x, y - last[2])
                    last = { x, y }
                end
                dragger.OnRelease = function(d) d:Destroy() end
                dragger.OnCancel = function(d) d:Destroy() end
                PostDragger(GetFrame(0), event.KeyCode, dragger)
                return true
            elseif event.Type == 'WheelRotation' then
                ed_fxv_camera('zoom', event.WheelRotation > 0 and 1 or -1)
                return true
            end
            return false
        end

        P.bPlay = Btn('Pause', 56, function() Opts.playing = not Opts.playing Push() P:Refresh() end)
        P.bRestart = Btn('Restart', 60, function() if ed_fxv_restart then ed_fxv_restart() end end)
        P.bLoop = Btn('Loop', 50, function() Opts.loop = not Opts.loop Push() P:Refresh() end, { toggle = true })
        P.bTurn = Btn('Turn', 50, function() Opts.turn = not Opts.turn Push() P:Refresh() end, { toggle = true })
        P.bGround = Btn('Ground', 60, function() Opts.ground = not Opts.ground Push() P:Refresh() end, { toggle = true })
        P.bGrid = Btn('Grid', 46, function() Opts.grid = not Opts.grid Push() P:Refresh() end, { toggle = true })
        P.bg = {}
        for i, name in { 'Night', 'Grey', 'Sky', 'Black' } do
            local mode = i - 1
            P.bg[i] = Btn(name, 52, function() Opts.background = mode Push() P:Refresh() end, { toggle = true, tip = 'Background: ' .. string.lower(name) .. '.' })
        end
        P.views = {}
        for i, v in { { 'Front', 0, 0.1 }, { 'Side', 1.5708, 0.1 }, { 'Top', 0, 1.5 }, { 'Reset', nil, nil } } do
            local heading, pitch = v[2], v[3]
            P.views[i] = Btn(v[1], 52, function()
                if heading then ed_fxv_camera('look', heading, pitch) else ed_fxv_camera('reset', 12) end
            end, { tip = 'Camera: ' .. string.lower(v[1]) .. ' view.' })
        end
        P.height = W.Slider(group, { label = 'Emitter height above the ground', min = 0, max = 30, step = 0.5, fmt = '%.1f',
            get = function() return Opts.height end, set = function(v) Opts.height = v Push() end })
        P.scale = W.Slider(group, { label = 'Effect scale', min = 0.1, max = 4, step = 0.1, fmt = '%.1f',
            get = function() return Opts.scale end, set = function(v) Opts.scale = v Push() end })
        P.status = W.Label(group, '', 0, 0, { color = c.textDim, size = 'small' })

        function P:Refresh()
            if ed_fxv_touch then ed_fxv_touch() end
            P.bPlay:SetText(Opts.playing and 'Pause' or 'Play')
            P.bLoop:SetOn(Opts.loop)
            P.bTurn:SetOn(Opts.turn)
            P.bGround:SetOn(Opts.ground)
            P.bGrid:SetOn(Opts.grid)
            for i, b in P.bg do b:SetOn(Opts.background == i - 1) end
            P.height:Refresh() P.scale:Refresh()
            local st = ed_fxv_stats and ed_fxv_stats()
            if st then
                local what = Fx.IsOpen() and (Fx.Name .. (Fx.Dirty and ' *' or '')) or 'no file open'
                W.Fit(P.status, what .. '   age ' .. string.format('%d', st.age) .. ' ticks   ' .. st.emitted .. ' particles', (P.w or 300) - Skin.S(16))
            end
        end

        function P:OnResize(w, h)
            P.w, P.h = w, h
            local pad = Skin.S(8)
            local iw = w - 2 * pad
            local ih = math.floor(iw * HEIGHT / WIDTH)
            W.Place(P.img, group, pad, pad, iw, ih)
            W.Place(P.msg, group, pad + Skin.S(8), pad + Skin.S(8))
            local y = pad + ih + Skin.S(6)
            W.Flow(group, { { P.bPlay, Skin.S(56) }, { P.bRestart, Skin.S(60) }, { P.bLoop, Skin.S(50) }, { P.bTurn, Skin.S(50) }, { P.bGround, Skin.S(60) }, { P.bGrid, Skin.S(46) } },
                   pad, y, iw, Skin.S(22), Skin.S(4))
            y = y + Skin.S(28)
            W.Flow(group, { { P.bg[1], Skin.S(52) }, { P.bg[2], Skin.S(52) }, { P.bg[3], Skin.S(52) }, { P.bg[4], Skin.S(52) } }, pad, y, iw, Skin.S(22), Skin.S(4))
            y = y + Skin.S(28)
            W.Flow(group, { { P.views[1], Skin.S(52) }, { P.views[2], Skin.S(52) }, { P.views[3], Skin.S(52) }, { P.views[4], Skin.S(52) } }, pad, y, iw, Skin.S(22), Skin.S(4))
            y = y + Skin.S(30)
            P.height:Place(pad, y, iw)
            y = y + Skin.S(50)
            P.scale:Place(pad, y, iw)
            y = y + Skin.S(50)
            W.Place(P.status, group, pad, y)
            P:Refresh()
        end

        -- no Destroy that closes the view: another instance of the panel (a moved or rebuilt one) shows the same picture; the engine stops rendering it a second after the last touch
        return P
    end,
}

--- Called by the shell about four times a second while the panel shows: keeps the engine rendering the picture.
function Refresh()
    local P = live.particleview
    if P and not P.dead then pcall(P.Refresh, P) end
end
