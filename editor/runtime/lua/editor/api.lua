-- The editor's extension API: its version, what it offers, and the error isolation around the code mods register. Reference: docs/EDITOR_MODDING.md.
--
--   ApiVersion, MinApiVersion      the version of the extension points (raised when one changes shape) and the oldest version a mod may declare (`editor_api` in mod_info.lua)
--   Has(capability [, version])    true when the editor offers the extension point at that version or newer;  Capabilities = { name = version }
--   Compatible(modInfo)            -> true | false, why   (mod_info.lua `editor_api`; missing = 1)
--   Mod(name)                      -> registrar for a mod: .Panel(def) .Command(def) .Tool(tools, def) .Try(site, fn, ...) .Log(text); everything it registers carries the mod's name
--   Failed(kind, id, mod, err)     the one place failures of registered code end: logged once per site with the mod's name (Console), and a MOD's code is disabled for the session
--   Disabled() / IsDisabled(kind, id) / Reenable(kind, id)      what was disabled and why
--   GuardPanel(def, create, group, host)   Panels.Register wraps every create with it: a panel that raises shows a message instead of a blank page, its methods run protected
--   RunTool(tool, wx, wz, event)   ui.lua runs a 'custom' tool's OnPress through it
--
-- "A mod's code" is code registered with a `mod` name (through Mod(name), or a def with `mod = '...'`): after its first failure it is disabled until the editor restarts. Code without a mod name
-- (the editor's own panels and commands) is not disabled, only protected and reported once per site (safe.lua), because turning off a built-in command for a transient error is worse than the error.
--
-- Lua 5.0 dialect: no `#`, no `%`, no `...` as an expression.

ApiVersion = 1
MinApiVersion = 1

--- The extension points and the version of each (raised when that one changes shape; ApiVersion is raised with it).
Capabilities = {
    panels = 1,             -- gui/panels.lua Register
    commands = 1,           -- gui/commands.lua Register / Run / Intercept
    tools = 1,              -- ui.lua Tools entries (kind 'custom', OnPress)
    hooks = 1,              -- hook/<vfs path> of an editor mod (appended to the module, one chunk)
    sim_hooks = 1,          -- the same for the sim state (needs ui_only = false in mod_info.lua)
    sidecar = 1,            -- safeload.lua, mods.SidecarEnv: protected reads of the map's sidecar
    safe = 1,               -- safe.lua Try / Wrap / Call
    mission_nodes = 1,      -- mission.lua Register / KindChecks / Edit
}

function Has(name, version)
    local v = Capabilities[name]
    return v ~= nil and v >= (version or 1)
end

--- mod_info.lua `editor_api = N`: the extension API version the mod was written for. Missing means 1.
function Compatible(info)
    local need = tonumber(info and info.editor_api) or 1
    if need > ApiVersion then
        return false, 'it needs editor API ' .. need .. ' and this editor has ' .. ApiVersion
    end
    if need < MinApiVersion then
        return false, 'it was written for editor API ' .. need .. ' and the oldest this editor still supports is ' .. MinApiVersion
    end
    return true
end

-- ---- failures --------------------------------------------------------------------------------------------------------------------------------------

local S = rawget(_G, 'EdApiState')
if not S then
    S = { disabled = {} }
    rawset(_G, 'EdApiState', S)
end

local function Site(kind, id) return kind .. ':' .. tostring(id) end

local function Safe() return import('/lua/editor/safe.lua') end

function Failed(kind, id, mod, err)
    local site = Site(kind, id)
    Safe().Report(site, (mod and ('[mod ' .. tostring(mod) .. '] ') or '') .. tostring(err))
    if mod and not S.disabled[site] then
        S.disabled[site] = { kind = kind, id = tostring(id), mod = tostring(mod), err = tostring(err) }
        WARN('EDITOR ' .. site .. ': mod ' .. tostring(mod) .. ' is disabled until the editor restarts')
    end
end

function IsDisabled(kind, id) return S.disabled[Site(kind, id)] ~= nil end

function Reenable(kind, id) S.disabled[Site(kind, id)] = nil end

function Disabled()
    local list = {}
    for site, d in S.disabled do table.insert(list, d) end
    table.sort(list, function(a, b) return a.mod .. a.kind .. a.id < b.mod .. b.kind .. b.id end)
    return list
end

--- Forgets what failed (the self test).
function Clear()
    S.disabled = {}
end

-- ---- panels ----------------------------------------------------------------------------------------------------------------------------------------

local PANEL_METHODS = { OnResize = true, Refresh = true, Destroy = true, OnShow = true, OnHide = true, Update = true, Tick = true }

--- Shown in the panel's place when its create raised (a blank page is no answer): the panel's name and the error.
local function ShowFailure(group, def, err)
    local ok, why = pcall(function()
        local W = import('/lua/editor/gui/widgets.lua')
        local Skin = import('/lua/editor/gui/skin.lua')
        local text = 'The panel "' .. tostring(def.title or def.id) .. '" could not be built' .. (def.mod and (' (mod ' .. tostring(def.mod) .. ')') or '') .. ': ' .. tostring(err)
        local labels = W.Paragraph(group, text, Skin.S(8), Skin.S(8), Skin.S(260), { color = Skin.color.error, size = 'small' })
        return labels
    end)
    if not ok then LOG('EDITOR api: the failure message of panel ' .. tostring(def.id) .. ' could not be shown (' .. tostring(why) .. ')') end
end

--- A panel method that runs protected (and, for a mod's panel, is off after its first failure).
local function GuardMethod(def, name, method)
    local site = 'panel:' .. tostring(def.id) .. '.' .. name
    local id = tostring(def.id) .. '.' .. name
    return function(...)
        if def.mod and S.disabled[site] then return nil end
        local r = { pcall(method, unpack(arg)) }
        if not r[1] then
            Failed('panel', id, def.mod, r[2])
            return nil
        end
        table.remove(r, 1)
        return unpack(r)
    end
end

--- Panels.Register wraps `def.create` with this. -> the panel object (a stub when the build failed).
function GuardPanel(def, create, group, host)
    local kind = 'panel'
    if IsDisabled(kind, def.id) then
        ShowFailure(group, def, S.disabled[Site(kind, def.id)].err)
        return { failed = true }
    end
    local ok, inst = pcall(create, group, host)
    if not ok then
        Failed(kind, def.id, def.mod, inst)
        local panels = import('/lua/editor/gui/panels.lua')
        panels.failed[def.id] = tostring(inst)
        for _, fn in panels.failureListeners do pcall(fn, def.id, tostring(inst), def.mod) end
        ShowFailure(group, def, inst)
        return { failed = true }
    end
    if type(inst) == 'table' and not inst.Left and not inst.Depth then            -- (a plain panel object; a Maui control returned as the panel is left alone. Every table has a metatable here, so that cannot tell them apart)
        for name, method in inst do
            if type(method) == 'function' and PANEL_METHODS[name] then
                inst[name] = GuardMethod(def, name, method)         -- (a function, not the loop body: closures in a for loop share the loop variable)
            end
        end
    end
    return inst
end

-- ---- tools -----------------------------------------------------------------------------------------------------------------------------------------

--- ui.lua: a 'custom' tool's click. The result is "the tool took the click"; a failing tool lets the click through (and a mod's tool is off for the session).
function RunTool(tool, wx, wz, event)
    if IsDisabled('tool', tool.id) then return false end
    local ok, result = pcall(tool.OnPress, wx, wz, event)
    if not ok then
        Failed('tool', tool.id, tool.mod, result)
        return false
    end
    return result ~= false
end

-- ---- the registrar a mod uses ----------------------------------------------------------------------------------------------------------------------

--- local Editor = import('/lua/editor/api.lua')
--- local mod = Editor.Mod('My mod')
--- mod.Command{ id = 'my.thing', title = 'My mod: do the thing', run = function() ... end }
function Mod(name)
    name = tostring(name)
    local reg = { name = name }
    function reg.Panel(def)
        def.mod = name
        return import('/lua/editor/gui/panels.lua').Register(def)
    end
    function reg.Command(def)
        def.mod = name
        return import('/lua/editor/gui/commands.lua').Register(def)
    end
    --- `tools` is the Tools table of ui.lua (a hook on ui.lua sees it as a global).
    function reg.Tool(tools, def)
        def.mod = name
        def.kind = def.kind or 'custom'
        table.insert(tools, def)
        return def
    end
    function reg.Try(site, fn, ...)
        local ok, a, b, c = pcall(fn, unpack(arg))
        if not ok then Failed('mod', name .. ':' .. tostring(site), name, a) return false end
        return true, a, b, c
    end
    function reg.Log(text) LOG('EDITOR mod ' .. name .. ': ' .. tostring(text)) end
    return reg
end
