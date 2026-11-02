-- Example editor mod hook (appended to /lua/editor/ui.lua as one chunk, so wrap everything in do ... end).
-- Adds a custom tool and a command through the extension API (lua/editor/api.lua, docs/EDITOR_MODDING.md):
--   * a click with the Crater tool digs a crater. `kind = 'custom'` tools get OnPress(wx, wz, event); return false to let the click through to the game, anything else consumes it.
--   * a command, found in the command palette, that says the crater tool's settings.
-- Everything registered through Editor.Mod(name) carries the mod's name: a failure is logged with it (Console) and turns the tool / command off for the session instead of taking the editor down.
do
    local Terrain = import('/lua/editor/terrain.lua')
    local Editor = import('/lua/editor/api.lua')
    local mod = Editor.Mod('Editor example: crater tool')

    mod.Tool(Tools, {
        id = 'crater',
        label = 'Crater (example)',
        OnPress = function(wx, wz, event)
            local brush = Terrain.Brush
            local mode, strength = brush.mode, brush.strength
            brush.mode = 'lower'
            brush.strength = 6
            Terrain.BeginStroke()
            Terrain.Dab(wx, wz)
            Terrain.EndStroke()
            brush.mode = mode
            brush.strength = strength
            return true
        end,
    })

    mod.Command{
        id = 'example.crater_info',
        title = 'Example mod: say the crater tool settings',
        run = function()
            local brush = Terrain.Brush
            Say('Crater tool: strength 6, radius ' .. tostring(brush.radius) .. ' (the brush radius of the Terrain tools)')
        end,
    }
end
