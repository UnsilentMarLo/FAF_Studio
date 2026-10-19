-- Units follow edited terrain. Through /edcmd, in an /editor session:
--   return import('/lua/editor/selftest_snap.lua').Run('<disk dir for the report>')
-- Spawns a land unit on flat ground, raises a hill under it with the terrain tool (which re-snaps through the
-- sim callback) and, one call later, Report('<disk dir>') compares the unit's height with the terrain.

local T = import('/lua/editor/terrain.lua')

function Run(dir)
    ed_terrain_set_rect(0, 0, 256, 256, 25)
    SimCallback({ Func = 'EdSpawnUnit', Args = { bp = 'uel0106', army = 'ARMY_1', x = 60, z = 60 } }, false)
    return 'spawned; now call Raise()'
end

function Raise()
    T.ClearHistory()
    T.Brush.mode = 'raise'
    T.Brush.radius = 16
    T.Brush.strength = 12
    T.BeginStroke()
    T.Dab(60, 60)
    T.EndStroke()
    return 'raised, terrain at unit = ' .. tostring(ed_terrain_get(60, 60))
end

function Report(dir)
    SimCallback({ Func = 'EdDumpUnits', Args = { path = dir .. '/snap_report.txt', bp = 'uel0106' } }, false)
    return 'requested'
end
