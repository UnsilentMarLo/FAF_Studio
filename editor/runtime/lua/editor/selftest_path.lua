-- Pathing follows edited terrain, tested with real movement (Unit:CanPathTo in this engine tree is only a goal
-- check). Drive through /edcmd, with waits of several seconds between the steps:
--   Setup()                 flat ground, a land scout at (60,128)
--   WallWithGap()           a wall across the map (x 100..103) with a gap at z 109..121 (not on the unit's line)
--   Move()                  orders the scout to (180,128)
--   Report(dir)             writes <dir>/path_report.txt with the scout's position
-- With the pathfinder told about the edit the scout walks through the gap and ends near x=180; with stale
-- clusters (Sim.NoDirtyForTest = true) it still believes the straight line is free and stops at the wall (x < 100).

local T = import('/lua/editor/terrain.lua')
local Sim = import('/lua/editor/sim.lua')

function Setup()
    T.SetRect(0, 0, 256, 256, 25)
    SimCallback({ Func = 'EdSpawnUnit', Args = { bp = 'uel0101', army = 'ARMY_1', x = 60, z = 128 } }, false)
    return 'scout spawned at 60,128'
end

function NoDirty(flag)
    Sim.NoDirtyForTest = flag and true or false
    return 'noDirty=' .. tostring(Sim.NoDirtyForTest)
end

function WallWithGap()
    T.SetRect(100, 0, 103, 108, 150)
    T.SetRect(100, 122, 103, 256, 150)
    return 'wall with a gap up'
end

function Move()
    SimCallback({ Func = 'EdMoveUnit', Args = { bp = 'uel0101', x = 180, z = 128 } }, false)
    return 'move ordered'
end

function Report(dir)
    SimCallback({ Func = 'EdDumpUnits', Args = { path = dir .. '/path_report.txt', bp = 'uel0101' } }, false)
    return 'requested'
end
