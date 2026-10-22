-- Settings shared by all tools of one kind of object, kept in the user folder: snapping to the build grid and free or stepped rotation for units, props and decals.
-- The Tool settings panel (gui/panels_toolsettings.lua) edits them; the placement code (placer.lua, units.lua, props.lua, decals.lua, gizmo.lua) reads them through the small
-- accessors of its own module (Units.SnapToGrid(), Props.RotationStep() ...), which call this module.
--
--   kind                          'units' | 'props' | 'decals'
--   SnapToGrid(kind) / SetSnapToGrid(kind, on)     default on (what the editor always did)
--   Stepped(kind) / SetStepped(kind, on)           rotation in steps; default off = free rotation
--   StepSize(kind) / SetStepSize(kind, degrees)    default 90
--   RotationStep(kind) -> degrees, or 0 when the rotation is free
--   Quantize(kind, degrees) -> degrees              a turn rounded to the step (unchanged when free)
--   RandomHeading(kind) -> radians                  a random heading, rounded to the step when stepped
--   LimitAreas() -> bool | nil                      the areas' "limit to map bounds" (tools.lua LimitAreas, when it exists); SetLimitAreas(on)
--   SelectBoxCamera() -> bool | nil                 "Selection box follows the camera" (tools.lua SelectBoxFollowsCamera: the select tools' box is a rectangle on the screen); SetSelectBoxCamera(on)
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')

STEP_PRESETS = { 15, 22.5, 45, 90 }
STEP_MIN, STEP_MAX, STEP_UNIT = 7.5, 180, 7.5

local function Key(kind, what) return 'ts.' .. tostring(kind) .. '.' .. what end

function SnapToGrid(kind)
    return UserData.Get(Key(kind, 'snap'), true) ~= false
end

function SetSnapToGrid(kind, on)
    UserData.Set(Key(kind, 'snap'), on and true or false)
end

function Stepped(kind)
    return UserData.Get(Key(kind, 'stepped'), false) == true
end

function SetStepped(kind, on)
    UserData.Set(Key(kind, 'stepped'), on and true or false)
end

function StepSize(kind)
    local v = UserData.Get(Key(kind, 'step'), 90)
    if type(v) ~= 'number' or v < STEP_MIN then return 90 end
    return v
end

function SetStepSize(kind, deg)
    UserData.Set(Key(kind, 'step'), deg)
end

function RotationStep(kind)
    if Stepped(kind) then return StepSize(kind) end
    return 0
end

function Quantize(kind, deg)
    local step = RotationStep(kind)
    if step <= 0 then return deg end
    return math.floor(deg / step + 0.5) * step
end

function RandomHeading(kind)
    local h = math.random() * 6.2831853
    local step = RotationStep(kind)
    if step > 0 then
        local s = math.rad(step)
        h = math.floor(h / s) * s
    end
    return h
end

-- ---- settings that live in another module's variables ---------------------------------------------------------------------------------------------
-- The panel edits the variables the tools read (props.lua Settings, decals.lua Settings ...) so nothing is stored twice; this keeps their values in the user folder: Restore() puts
-- the kept values back at start, Sync() writes the live ones (the panel module ticks it).

local MIRRORED = {
    { key = 'ts.props.random',    module = '/lua/editor/props.lua',  table = 'Settings', field = 'randomHeading' },
    { key = 'ts.props.scaleMin',  module = '/lua/editor/props.lua',  table = 'Settings', field = 'scaleMin' },
    { key = 'ts.props.scaleMax',  module = '/lua/editor/props.lua',  table = 'Settings', field = 'scaleMax' },
    { key = 'ts.decals.random',   module = '/lua/editor/decals.lua', table = 'Settings', field = 'randomHeading' },
    { key = 'ts.decals.sizeVar',  module = '/lua/editor/decals.lua', table = 'Settings', field = 'sizeVar' },
}

local restored = false

local function Target(e)
    local ok, mod = pcall(import, e.module)
    local t = ok and mod and mod[e.table]
    if type(t) == 'table' then return t end
    return nil
end

function Restore()
    if restored then return end
    restored = true
    for _, e in MIRRORED do
        local t = Target(e)
        local v = UserData.Get(e.key, nil)
        if t and v ~= nil and type(v) == type(t[e.field]) then t[e.field] = v end
    end
    local ok, Tools = pcall(import, '/lua/editor/tools.lua')
    local v = UserData.Get('ts.areas.limit', nil)
    if ok and Tools and v ~= nil and rawget(Tools, 'LimitAreas') ~= nil then Tools.LimitAreas = v end
end

function Sync()
    if not restored then return end
    for _, e in MIRRORED do
        local t = Target(e)
        if t and t[e.field] ~= nil then UserData.Set(e.key, t[e.field]) end
    end
    local v = LimitAreas()
    if v ~= nil then UserData.Set('ts.areas.limit', v) end
end

--- Whether areas are limited to the map bounds, or nil when this editor has no such setting (tools.lua LimitAreas: a boolean).
function LimitAreas()
    local ok, v = pcall(function()
        local Tools = import('/lua/editor/tools.lua')
        local f = rawget(Tools, 'LimitAreas')
        if type(f) == 'function' then return f() end
        return f
    end)
    if ok and type(v) == 'boolean' then return v end
    return nil
end

function SetLimitAreas(on)
    pcall(function()
        local Tools = import('/lua/editor/tools.lua')
        local f = rawget(Tools, 'LimitAreas')
        local set = rawget(Tools, 'SetLimitAreas')
        if type(set) == 'function' then set(on and true or false)      -- tools.lua keeps its own saved copy (the Properties panel reads the same switch)
        elseif type(f) ~= 'function' and f ~= nil then Tools.LimitAreas = on and true or false end
    end)
end

--- Whether the box of the select tools is a rectangle on the screen (true) or on the ground, aligned with the world (false); nil when this editor has no such setting.
--- tools.lua keeps the switch in the user settings itself.
function SelectBoxCamera()
    local ok, v = pcall(function() return import('/lua/editor/tools.lua').SelectBoxFollowsCamera end)
    if ok and type(v) == 'boolean' then return v end
    return nil
end

function SetSelectBoxCamera(on)
    pcall(function()
        local set = rawget(import('/lua/editor/tools.lua'), 'SetSelectBoxFollowsCamera')
        if type(set) == 'function' then set(on and true or false) end
    end)
end
