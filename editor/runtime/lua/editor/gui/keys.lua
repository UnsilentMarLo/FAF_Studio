-- Editor key bindings. Commands (commands.lua) may carry `keys = 'Ctrl+Shift+P'`; Apply() turns them into an engine key map
-- (IN_AddKeyMapTable, the same mechanism the game uses: the key runs a console command, here `UI_Lua ...Run('<id>')`).
-- Nothing is written to the user's preferences or key map files: the map only lives in this process.
--
--   Keys.Apply{ exclusive = true }    exclusive: clear the game's key map first (the editor must not inherit game hotkeys)
--   Keys.Run(id)                      what a bound key calls
--   Keys.Rebind(id, 'Ctrl+K')         change a binding at run time (user keymap UI comes later; bindings are data)
--
-- Key names use the engine's spelling joined with '-' ('Ctrl-Shift-P', 'F9', 'Numpad5'); '+' is accepted and converted.
-- The engine decides modifiers from the real keyboard state, so tests with posted messages can only exercise unmodified keys.

local Commands = import('/lua/editor/gui/commands.lua')

applied = false

local function EngineKey(keys)
    return string.gsub(keys, '%+', '-')
end

function Run(id)
    return Commands.Run(id)
end

function BuildTable()
    local map = {}
    for _, id in Commands.order do
        local def = Commands.registry[id]
        -- held keys (camera movement) are polled each frame by camera.lua, not run through the engine's key map
        if not def.hold then
            local action = { action = 'UI_Lua import("/lua/editor/gui/keys.lua").Run("' .. id .. '")', category = 'editor' }
            -- the engine's map values are key action tables {action = console command, category = ...}, not strings
            if def.keys and def.keys ~= '' then map[EngineKey(def.keys)] = action end
            if def.keys2 and def.keys2 ~= '' then map[EngineKey(def.keys2)] = action end
        end
    end
    return map
end

function Apply(opts)
    opts = opts or {}
    if opts.exclusive then
        IN_ClearKeyMap()
    end
    IN_AddKeyMapTable(BuildTable())
    applied = true
end

--- A test run uses the game's own key map (its hotkeys, the spawn menu, control groups ...): the editor's map would swallow them. Apply() brings the editor's keys back.
function UseGame()
    local KeyMapper = import('/lua/keymap/keymapper.lua')
    IN_ClearKeyMap()
    IN_AddKeyMapTable(KeyMapper.GetKeyMappings(true))
    pcall(function() IN_AddKeyMapTable(KeyMapper.GenerateHotbuildModifiers()) end)
    pcall(function() import('/lua/keymap/hotbuild.lua').addModifiers() end)
    pcall(function() import('/lua/keymap/hotkeylabels.lua').init() end)
    applied = false
end

function Rebind(id, keys)
    local def = Commands.registry[id]
    if not def then return false end
    def.keys = keys
    IN_ClearKeyMap()
    IN_AddKeyMapTable(BuildTable())
    return true
end
