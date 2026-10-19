-- Mesh terrain in the viewport (docs/projects/editor/MESH_VIEW.md). A map whose scenario says TerrainSystem = 'mesh' has its ground in SCM patches (manifest
-- TerrainMesh); the engine draws them in place of the height field (EdMeshTerrain). This module loads the manifest with the map, switches what the viewport shows and
-- answers "where is the ground under this point" for placing things.
--
--   OnMapLoaded()            called by map.lua when the document is read: loads the map's mesh, or unloads the previous one
--   Active()                 a mesh is loaded
--   Mode() / SetMode(m)      0 height field, 1 mesh, 2 both (m also 'field' | 'mesh' | 'both')
--   Info()                   ed_mesh_info() table or nil
--   GroundAt(x, z, fallback) height of the visible ground: the mesh surface when the mesh is shown (the highest one not more than REACH above the field), else
--                            `fallback` (the height field's)
--   MouseRay()               the ground point under the mouse: x, y, z, normal x, y, z | nil (mesh ray when the mesh is shown, else the engine's field pick)
--
-- Lua 5.0 dialect.

local Map = import('/lua/editor/map.lua')

--- Things stand on the highest mesh surface up to this far above the height field (a bridge deck is not "the ground" of a cell, scenery is not either).
REACH = 40

local loadedPath = false
local synced = false
local meshOn = false       -- a mesh is loaded (cached: GroundAt runs in loops)

local function Available()
    return rawget(_G, 'ed_mesh_load') ~= nil
end

function Active()
    return meshOn
end

function Info()
    return Available() and ed_mesh_info() or nil
end

local MODES = { field = 0, heightfield = 0, mesh = 1, both = 2 }

function Mode()
    return Available() and ed_mesh_mode() or 0
end

function SetMode(m)
    if not Available() then return 0 end
    if type(m) == 'string' then m = MODES[string.lower(m)] or 1 end
    return ed_mesh_mode(m)
end

--- Loads (or drops) the map's mesh. Safe to call again: the same manifest is not read twice.
function OnMapLoaded()
    if not Available() or not Map.Doc then return end
    local info = Map.Doc.info
    local path = info and info.TerrainSystem == 'mesh' and info.TerrainMesh or false
    -- the engine keeps the loaded mesh across sessions but this Lua state starts empty: the first call of a session always settles it
    if synced and path == loadedPath and (path == false or meshOn) then return end
    synced = true
    if not path then
        ed_mesh_unload()
        loadedPath, meshOn = false, false
        return
    end
    local ok, why = ed_mesh_load(path)
    if ok then
        loadedPath, meshOn = path, true
        LOG('EDITOR meshview: loaded ' .. path)
    else
        loadedPath, meshOn = false, false
        LOG('EDITOR meshview: ' .. tostring(why))
    end
end

function GroundAt(x, z, fallback)
    if meshOn and ed_mesh_mode() ~= 0 then
        local y = ed_mesh_height(x, z, (fallback or 0) + REACH)
        if y then return y end
    end
    return fallback
end

--- The ground point under a window position (x, y in window pixels): x, y, z, normal | nil. The mesh when it is shown, else the engine's own pick.
function ScreenRay(sx, sy)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if not view then return nil end
    if meshOn and ed_mesh_mode() ~= 0 then
        local t, x, y, z, nx, ny, nz = ed_mesh_pick(sx - view.Left(), sy - view.Top(), view.Width(), view.Height())
        if t then return x, y, z, nx, ny, nz end
    end
    local p = UnProject(view, Vector2(sx, sy))
    if p then return p[1], p[2], p[3], 0, 1, 0 end
    return nil
end

function MouseRay()
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    if meshOn and ed_mesh_mode() ~= 0 and view then
        local pos = GetMouseScreenPos()
        local mx, my = (pos and (pos[1] or pos.x)) or 0, (pos and (pos[2] or pos.y)) or 0
        local t, x, y, z, nx, ny, nz = ed_mesh_pick(mx - view.Left(), my - view.Top(), view.Width(), view.Height())
        if t then return x, y, z, nx, ny, nz end
    end
    local p = GetMouseWorldPos()
    if p then return p[1], p[2], p[3], 0, 1, 0 end
    return nil
end
