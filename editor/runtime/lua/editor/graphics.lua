-- Graphics settings of the editor (Settings panel, File > Settings...). The editor starts on the highest quality: a map editor draws one scene, so there is no frame budget to save.
-- Every setting is a console variable of the engine, the same ones the game's own options use (lua/options/options.lua); the choice is kept in the user folder (userdata.lua).
--
--   Defs                 the settings in display order: { key, label, states = { { text, value }, ... } or states = function() -> list, apply = function(value) }
--   Presets              low / medium / high / ultra: setting key -> value (the game's own fidelity presets; Ultra also has the sharpest shadows and the longest shadow distance)
--   Get(key)             the chosen value (the default is the Ultra value; anti-aliasing and vertical sync default to what the window starts with)
--   Set(key, value)      chooses and applies one setting;   Cycle(key)  the next state
--   SetPreset(name)      chooses and applies a whole preset;   PresetName()  'low' .. 'ultra' or 'custom'
--   Reset()              back to the defaults;   Apply(startup)  applies every setting (startup: leaves out the two that need the window's device: anti-aliasing and vertical sync)
--   StateText(key)       the text of the chosen state
--   GpuStatus(probe)     two lines for the Settings panel: the adapter, and whether GPU compute is on (probe: try to create the device if that has not been tried)
--   GpuTest()            runs the native GPU self test: a one line summary and the lines per part (also logged by the callers)
--   GpuReport(runTest)   the lines of the dev.gpu command: adapter, status, GPU ops, and the self test results when runTest
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local UserData = import('/lua/editor/userdata.lua')

local function Con(name) return function(v) ConExecute(name .. ' ' .. tostring(v)) end end

--- The anti-aliasing options are the engine's packed modes: (sample type << 5) | quality level (GetAntiAliasingOptions; the FAF client stores 256 for 8x). The text names the
--- sample count; a mode with a quality level (the NVIDIA coverage modes) says so.
local function AALabel(n)
    local samples, quality = math.floor(n / 32), math.mod(n, 32)
    if quality == 0 then return tostring(samples) .. 'x' end
    return string.format('%dx (coverage %d)', samples, quality)
end

--- Vertical sync is on or off with a reset of the graphics device while the editor runs; with an NVIDIA adapter installed (hybrid laptops) such a reset never came back, so the
--- setting stays On there.
local function VSyncStates()
    local ok, info = pcall(function() return rawget(_G, 'ed_engine_info') and ed_engine_info() or nil end)
    if ok and type(info) == 'table' and info.nvidia then return { { 'On', 1 } } end
    return { { 'Off', 0 }, { 'On', 1 } }
end

local function AAStates()
    local list = { { 'Off', 0 } }
    local ok, options = pcall(function() return GetAntiAliasingOptions() end)
    if ok and options then
        for _, n in options do
            if n > 0 then table.insert(list, { AALabel(n), n }) end
        end
    end
    return list
end

Defs = {
    { key = 'fidelity', tip = 'Overall detail of the terrain and the models: terrain shading, water and effects. Click to cycle.', label = 'Fidelity', states = { { 'Low', 0 }, { 'Medium', 1 }, { 'High', 2 } }, apply = Con('graphics_Fidelity') },
    { key = 'shadow_quality', tip = 'Whether and how well objects cast shadows. Click to cycle.', label = 'Shadows', states = { { 'Off', 0 }, { 'Low', 1 }, { 'Medium', 2 }, { 'High', 3 } }, apply = Con('shadow_Fidelity') },
    { key = 'shadow_resolution', tip = 'The sharpness of shadows. Higher is sharper and uses more video memory.', label = 'Shadow resolution', states = { { '512', 512 }, { '1024', 1024 }, { '1536', 1536 }, { '2048', 2048 } },
      apply = function(v) ConExecute(string.format('ren_ShadowSize %d', v)) end },
    { key = 'shadow_render_distance', tip = 'How far from the camera shadows are drawn.', label = 'Shadow distance', states = { { 'Short', 200 }, { 'Normal', 260 }, { 'Long', 340 }, { 'Longest', 440 } },
      apply = function(v) ConExecute(string.format('ren_ShadowLOD %d', v)) end },
    { key = 'texture_level', tip = 'The size of the textures the editor loads. High shows the full resolution.', label = 'Texture detail', states = { { 'Low', 2 }, { 'Medium', 1 }, { 'High', 0 } }, apply = Con('ren_MipSkipLevels') },
    { key = 'level_of_detail', tip = 'How long models keep their detailed meshes as the camera moves away.', label = 'Model detail', states = { { 'Low', 0 }, { 'Medium', 1 }, { 'High', 2 } }, apply = Con('SC_CameraScaleLOD') },
    { key = 'bloom_render', tip = 'A soft glow around bright areas.', label = 'Bloom', states = { { 'Off', 0 }, { 'On', 1 } }, apply = Con('ren_bloom') },
    { key = 'antialiasing', tip = 'Smooths jagged edges by drawing each pixel several times. Applies at once; the window may flicker for a moment.', label = 'Anti-aliasing', states = AAStates, apply = Con('SC_AntiAliasingSamples'), device = true },
    { key = 'gpu_compute', tip = 'Runs heavy terrain operations (blur, and later erosion and noise) on the graphics card with Direct3D 11 compute shaders, where a GPU version exists. On any problem the editor uses the processor instead. Off: always the processor.', label = 'GPU compute', states = { { 'Off', 0 }, { 'On', 1 } },
      apply = function(v) local f = rawget(_G, 'ed_gpu_enable') if f then f(v == 1) end end },
    { key = 'vsync', tip = 'Wait for the monitor before showing a frame: no tearing, and the card draws at most one frame per refresh. Off, the editor draws as many frames as the card can make (hundreds per second: a heavy load for a still scene).', label = 'Vertical sync', states = VSyncStates, apply = Con('SC_VerticalSync'), device = true },
}

Presets = {
    low = { fidelity = 0, shadow_quality = 0, shadow_resolution = 512, shadow_render_distance = 200, texture_level = 2, level_of_detail = 0, bloom_render = 0 },
    medium = { fidelity = 1, shadow_quality = 1, shadow_resolution = 1024, shadow_render_distance = 260, texture_level = 1, level_of_detail = 1, bloom_render = 0 },
    high = { fidelity = 2, shadow_quality = 2, shadow_resolution = 1536, shadow_render_distance = 340, texture_level = 0, level_of_detail = 2, bloom_render = 0 },
    ultra = { fidelity = 2, shadow_quality = 3, shadow_resolution = 2048, shadow_render_distance = 440, texture_level = 0, level_of_detail = 2, bloom_render = 0 },
}
PresetOrder = { 'low', 'medium', 'high', 'ultra' }
PresetLabels = { low = 'Low', medium = 'Medium', high = 'High', ultra = 'Ultra' }

local function Def(key)
    for _, d in Defs do
        if d.key == key then return d end
    end
    return nil
end

--- The states of a setting as a list of { text, value } (anti-aliasing asks the graphics device which sample counts it supports).
function States(key)
    local d = Def(key)
    if not d then return {} end
    if type(d.states) == 'function' then return d.states() end
    return d.states
end

--- The value a setting has until it is chosen: Ultra's; the two device settings leave the window as it starts (no anti-aliasing, vertical sync on).
function Default(key)
    if key == 'antialiasing' then return 0 end
    if key == 'vsync' then return 1 end
    if key == 'gpu_compute' then return 1 end        -- not part of the quality presets: the GPU is used whenever it works
    return Presets.ultra[key]
end

function Get(key)
    local value = UserData.Get('gfx_' .. key, Default(key))
    -- A saved anti-aliasing mode the adapter does not offer (an older editor saved the sample count, 8, where the engine wants the packed mode, 256; another adapter) is "Off":
    -- asking the graphics device for it made its reset fail (and hang on a hybrid laptop GPU).
    if key == 'vsync' and value ~= 1 then
        local offered = false
        for _, st in VSyncStates() do
            if st[2] == value then offered = true end
        end
        if not offered then return 1 end
    end
    if key == 'antialiasing' and value ~= 0 then
        local offered = false
        for _, st in AAStates() do
            if st[2] == value then offered = true end
        end
        if not offered then return 0 end
    end
    return value
end

function Set(key, value)
    local d = Def(key)
    if not d then return false end
    UserData.Set('gfx_' .. key, value)
    local ok, err = pcall(d.apply, value)
    if not ok then LOG('EDITOR graphics: ' .. key .. ' could not be applied (' .. tostring(err) .. ')') end
    return ok
end

--- The next state of a setting (wraps around). Returns the new value.
function Cycle(key)
    local states = States(key)
    local cur = Get(key)
    local index = 0
    for i, s in states do
        if s[2] == cur then index = i end
    end
    local nextState = states[index + 1] or states[1]
    if not nextState then return cur end
    Set(key, nextState[2])
    return nextState[2]
end

function SetPreset(name)
    local p = Presets[name]
    if not p then return false end
    for key, value in p do Set(key, value) end
    return true
end

--- 'low' .. 'ultra' when the chosen values are exactly a preset's, else 'custom'.
function PresetName()
    for _, name in PresetOrder do
        local same = true
        for key, value in Presets[name] do
            if Get(key) ~= value then same = false end
        end
        if same then return name end
    end
    return 'custom'
end

function StateText(key)
    local cur = Get(key)
    for _, s in States(key) do
        if s[2] == cur then return s[1] end
    end
    return tostring(cur)
end

function Reset()
    for _, d in Defs do UserData.Set('gfx_' .. d.key, Default(d.key)) end
    Apply(false)
end

--- Applies every chosen setting. At start the two that need the window's graphics device (anti-aliasing resets it, vertical sync is read when it is made) are left to what the window
--- started with, unless the user chose something else for them before.
function Apply(startup)
    for _, d in Defs do
        local value = Get(d.key)
        -- (vertical sync is applied at start too: a profile that never ran the game has it off, and the editor then draws as many frames as the card can make)
        if not (startup and d.device and d.key ~= 'vsync' and value == Default(d.key)) then
            local ok, err = pcall(d.apply, value)
            if not ok then LOG('EDITOR graphics: ' .. d.key .. ' could not be applied (' .. tostring(err) .. ')') end
        end
    end
end

-- ---- GPU compute (native: EdGpuLua.cpp, docs/projects/editor/GPU_COMPUTE.md) -------------------------------------------------------------------------------

local function GpuInfo(probe)
    local fn = rawget(_G, 'ed_gpu_info')
    if not fn then return nil end
    local ok, g = pcall(fn, probe and true or false)
    if ok and type(g) == 'table' then return g end
    return nil
end

function GpuStatus(probe)
    local g = GpuInfo(probe)
    if not g then return 'GPU compute is not part of this version of the editor.', '' end
    if g.failed then
        return 'Adapter: ' .. ((g.adapter ~= '') and g.adapter or 'unknown'), 'Switched off for this session: ' .. g.lastError
    end
    if g.available then
        local second = g.enabled and 'On: heavy terrain operations use the GPU.' or 'Off: everything runs on the processor.'
        if g.lastOpError ~= '' then second = second .. ' Last fall-back: ' .. g.lastOpError end
        return string.format('Adapter: %s (%d MB, Direct3D feature level %s)', g.adapter, g.vramMB, g.featureLevel), second
    end
    if g.tried then
        return 'No usable GPU found.', g.lastError
    end
    return 'Adapter: not checked yet.', 'Press Test GPU compute to check it.'
end

function GpuTest()
    local fn = rawget(_G, 'ed_gpu_selftest')
    if not fn then return 'GPU compute is not part of this version of the editor.', {} end
    local ok, r = pcall(fn)
    if not ok or type(r) ~= 'table' then return 'The test could not run: ' .. tostring(r), {} end
    local lines = {}
    for _, p in r.parts do
        table.insert(lines, string.format('%s: %s (%.1f ms) %s', p.name, p.ok and 'ok' or 'FAILED', p.ms, p.detail))
    end
    local summary
    if r.error ~= '' then
        summary = 'The test could not finish: ' .. r.error
    elseif r.ok then
        summary = string.format('Test passed in %.0f ms%s.', r.ms, r.texturesOk and '' or ' (texture sampling is not supported by this adapter)')
    else
        summary = 'Test failed: the GPU gave different results than the processor. See the Console panel.'
    end
    return summary, lines
end

function GpuReport(runTest)
    local out = {}
    local g = GpuInfo(true)
    if not g then
        table.insert(out, 'GPU compute is not part of this version of the editor.')
        return out
    end
    table.insert(out, string.format('GPU compute: %s, %s, adapter %s (%d MB), Direct3D feature level %s, shader compiler %s, textures %s',
        g.enabled and 'on' or 'off', g.available and 'available' or (g.failed and 'switched off for this session' or 'not available'),
        (g.adapter ~= '') and g.adapter or 'none', g.vramMB, (g.featureLevel ~= '') and g.featureLevel or '-', (g.compiler ~= '') and g.compiler or '-', g.textures and 'yes' or 'no'))
    if g.lastError ~= '' then table.insert(out, 'last device error: ' .. g.lastError) end
    if g.lastOpError ~= '' then table.insert(out, 'last fall-back to the processor: ' .. g.lastOpError) end
    local names = ''
    for _, n in g.ops do names = names .. ((names ~= '') and ', ' or '') .. n end
    table.insert(out, string.format('ops with a GPU version: %s; used for fields of at least %d samples (console variable ed_gpu_min_cells)', (names ~= '') and names or 'none', g.minCells))
    if runTest then
        local summary, lines = GpuTest()
        for _, l in lines do table.insert(out, l) end
        table.insert(out, summary)
    end
    return out
end
