-- Editor GUI constants: colours, font, sizes, UI scale. One pragmatic look, no theme system (decision 2026-10-17):
-- plain values in one place, changed by editing this file.
--
--   Skin.S(n)          -> integer pixels for n logical pixels at the current UI scale
--   Skin.FontSize(n)   -> fractional font size for n logical pixels (the native text backend takes fractions)
--   Skin.Font(gray)    -> font family string: 'ed:' LCD text (default) or ';g' gray text for translucent surfaces
--   Skin.SetScale(s)   -> stores the scale; the shell rebuilds its controls (Maui reads scale only at layout time)

scale = 1.0

local FAMILY = 'ed:Segoe UI Variable Text'

color = {
    window   = 'ff17191c',   -- gap between panels
    panel    = 'ff1e2125',   -- panel body
    panelAlt = 'ff23272c',   -- list stripes, field backgrounds
    header   = 'ff262a30',   -- tab bar
    tabOn    = 'ff1e2125',
    tabOff   = 'ff2c3037',
    tabHover = 'ff353a42',
    button   = 'ff30353c',
    buttonHi = 'ff3d444d',
    buttonOn = 'ff3a7a8c',
    accent   = 'ff3fb7d4',
    text     = 'ffd6dce1',
    textDim  = 'ff8a949d',
    textOn   = 'ff04181d',
    line     = 'ff2c3238',
    select   = 'ff24485a',
    hover    = 'ff2a2f35',
    drop     = '803fb7d4',   -- drop target highlight while dragging a tab
    error    = 'ffe5645e',
    warn     = 'ffe2b44a',
    ok       = 'ff5fc07f',
}

-- logical sizes (multiplied by the scale where used)
size = {
    text     = 12,
    small    = 11,
    tabH     = 24,
    rowH     = 20,
    splitter = 4,
    menuBar  = 24,
    topBar   = 28,
    status   = 22,
    scrollW  = 8,
    pad      = 6,
}

function S(n)
    return math.floor(n * scale + 0.5)
end

function FontSize(n)
    return n * scale
end

function Font(gray)
    if gray then
        return FAMILY .. ';g'
    end
    return FAMILY
end

function SetScale(s)
    if s < 0.5 then s = 0.5 end
    if s > 3.0 then s = 3.0 end
    scale = s
end
