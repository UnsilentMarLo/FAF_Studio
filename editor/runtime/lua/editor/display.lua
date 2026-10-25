-- Display diagnostics: what the window, the frame rate and the camera look like on this machine (laptops with two graphics adapters, high DPI screens ...). The command dev.display prints the
-- report in the Console panel and the log; the frame loop notes every change of the window size (a minimized window is 0 x 0) and every frame that took long.
--
--   Frame()          called once per frame (overlay.lua Update): frame times, window size changes
--   Report()         -> lines of text: window, frame rate, the saved graphics settings, the camera, the adapter
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local last = 0
local win = { n = 0, sum = 0, max = 0, hitches = 0, start = 0 }     -- the frames of the current second
local shown = { fps = 0, avg = 0, max = 0, hitches = 0, at = 0 }     -- the last full second
local sizeKey = ''
local sizeAt = 0
local resumeAt = 0

local function WindowSize()
    local ok, w, h = pcall(function()
        local f = GetFrame(0)
        return f.Width(), f.Height()
    end)
    if ok then return w or 0, h or 0 end
    return 0, 0
end

function Frame()
    local now = GetSystemTimeSeconds()
    if last > 0 then
        local dt = now - last
        win.n = win.n + 1
        win.sum = win.sum + dt
        if dt > win.max then win.max = dt end
        if dt > 0.25 then
            win.hitches = win.hitches + 1
            LOG(string.format('EDITOR display: a frame took %.2f s%s', dt, (resumeAt > 0 and now - resumeAt < 5) and ' (right after the window came back)' or ''))
        end
    end
    last = now
    if win.start == 0 then win.start = now end
    if now - win.start >= 1 then
        shown = { fps = win.n / (now - win.start), avg = (win.n > 0) and (win.sum / win.n) or 0, max = win.max, hitches = win.hitches, at = now }
        win = { n = 0, sum = 0, max = 0, hitches = 0, start = now }
    end
    local w, h = WindowSize()
    local key = w .. 'x' .. h
    if key ~= sizeKey then
        LOG('EDITOR display: the window is ' .. key .. (sizeKey ~= '' and (' (was ' .. sizeKey .. ')') or ''))
        if w > 0 and h > 0 and sizeAt > 0 and string.sub(sizeKey, 1, 2) == '0x' then resumeAt = now end
        sizeKey, sizeAt = key, now
    end
end

local function Num(v, f) return string.format(f or '%.2f', v or 0) end

function Report()
    local out = {}
    local w, h = WindowSize()
    local Skin = import('/lua/editor/gui/skin.lua')
    table.insert(out, string.format('window %d x %d, interface scale %.2f', w, h, Skin.scale or 1))
    if shown.at > 0 then
        table.insert(out, string.format('frame rate %.0f per second (average %.1f ms, longest %.0f ms, %d frames over 250 ms in the last second)', shown.fps, shown.avg * 1000, shown.max * 1000, shown.hitches))
    else
        table.insert(out, 'frame rate: not measured yet (the editor is not drawing)')
    end
    local Graphics = import('/lua/editor/graphics.lua')
    local parts, line = {}, {}
    for _, d in Graphics.Defs do
        table.insert(line, d.key .. ' ' .. Graphics.StateText(d.key))
        if table.getn(line) == 4 then table.insert(parts, table.concat(line, ', ')) line = {} end
    end
    if table.getn(line) > 0 then table.insert(parts, table.concat(line, ', ')) end
    for i, text in parts do table.insert(out, (i == 1 and 'saved settings: ' or '    ') .. text) end
    local okCam, cam = pcall(function() return GetCamera('WorldCamera') end)
    if okCam and cam then
        local okZ, zoom = pcall(function() return cam:GetZoom() end)
        local okF, fmin, fmax = pcall(function() return cam:GetMinZoom(), cam:GetMaxZoom() end)
        table.insert(out, string.format('camera: zoom %s (range %s to %s)', okZ and Num(zoom, '%.1f') or '?', okF and Num(fmin, '%.1f') or '?', okF and Num(fmax, '%.1f') or '?'))
    end
    local okP, px = pcall(function() return import('/lua/editor/viewscale.lua').PixelSize() end)
    if okP then table.insert(out, string.format('world units per screen pixel at the view centre: %.3f', px)) end
    local okG, g = pcall(function() return rawget(_G, 'ed_gpu_info') and ed_gpu_info(true) or nil end)
    if okG and type(g) == 'table' and g.adapter and g.adapter ~= '' then
        table.insert(out, string.format('graphics adapter for the field operations: %s (%d MB)', g.adapter, g.vramMB or 0))
    end
    -- the engine prints the value of a console variable when it is typed without one (the Console panel and the log show it)
    for _, name in { 'sc_FrameTimeClamp', 'SC_VerticalSync', 'SC_CameraScaleLOD', 'ren_MeshDissolve', 'ren_MeshDissolveCutoff', 'ren_ShadowLOD', 'ui_AlwaysRenderStrategicIcons', 'SC_PrimaryAdapter' } do
        pcall(ConExecute, name)
    end
    table.insert(out, 'live console values (frame limit, vertical sync, level of detail ...): in the log')
    return out
end
