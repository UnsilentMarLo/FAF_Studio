-- Example editor mod hook (appended to /lua/editor/ui.lua as one chunk, so wrap everything in do ... end).
-- Adds a custom tool: a click digs a crater. `kind = 'custom'` tools get OnPress(wx, wz, event); return false to
-- let the click through to the game, anything else consumes it.
do
    local Terrain = import('/lua/editor/terrain.lua')

    table.insert(Tools, {
        id = 'crater',
        label = 'Crater (example)',
        kind = 'custom',
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
end
