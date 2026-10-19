-- The test scene of the preset thumbnails (editor/tools/gen_env_thumbs.py drives it): hills, a lake, a temperate stratum recipe, the camera low over the lake with the sky behind the hills; the same
-- scene for every look, so the pictures differ only by the look. Themes are shown in the same terrain from higher up. Meant for a throw-away editor instance (it changes the map).
--
--   Setup()                 builds the scene; returns the viewport rectangle { x, y, w, h } (screen pixels of the editor window)
--   Counts() -> looks, themes             the shipped ones
--   Look(i) -> id, name     the i-th shipped look on the scene (the camera turns to face the sun of the look)
--   Theme(i) -> id, name    the i-th shipped theme on the scene
--
-- Lua 5.0 dialect.

local Lib = import('/lua/editor/envlib.lua')
local Env = import('/lua/editor/environment.lua')
local World = import('/lua/editor/world.lua')

local function Shipped(list)
    local out = {}
    for _, e in list do
        if not e.user then table.insert(out, e) end
    end
    return out
end

local function Cam() return GetCamera('WorldCamera') end

function Setup()
    local Gen = import('/lua/editor/terraingen.lua')
    local Recipes = import('/lua/editor/recipes.lua')
    local Strata = import('/lua/editor/strata.lua')
    local Shell = import('/lua/editor/gui/shell.lua')
    local size = ed_terrain_info() or 257
    Gen.Generate({ seed = 4, scale = 70, octaves = 5, amplitude = 34, base = 14, mode = 'fbm', island = 0, replace = true })
    World.Change({ water_on = 1, water_elev = 24, water_deep = 18, water_abyss = 8 }, { label = 'scene', refresh = true })
    for _, t in Lib.Themes() do
        if t.name == 'Grassland' then Lib.ApplyTheme(t, { clearUnused = true }) break end
    end
    Recipes.State.preset = 1
    Recipes.State.layers = nil
    Recipes.Knobs.cliff, Recipes.Knobs.rock, Recipes.Knobs.beach = 38, 22, 3
    Recipes.State.layers = Recipes.AutoLayers(Recipes.Roles())
    Recipes.State.types = false
    Recipes.Apply()
    -- no markers in the picture
    local MF = import('/lua/editor/markerfilter.lua')
    for _, c in MF.CATEGORIES do MF.Hidden[c] = true end
    import('/lua/editor/tools.lua').Changed = import('/lua/editor/tools.lua').Changed + 1
    -- a wide viewport: the world view takes the main area
    pcall(function() Shell.ShowWorkspace('Environment') end)
    local view = import('/lua/ui/game/worldview.lua').viewLeft
    return { x = view.Left(), y = view.Top(), w = view.Width(), h = view.Height() }
end

function Counts()
    return table.getn(Shipped(Lib.Looks())), table.getn(Shipped(Lib.Themes()))
end

function Look(i)
    local entry = Shipped(Lib.Looks())[i]
    if not entry then return nil end
    Lib.RevertPreview('look')
    local ok, revert = Lib.ApplyLook(entry, { preview = true })
    Lib.SetPreview('look', revert)
    -- face the sun: the camera turns to the azimuth of the lighting
    local az = World.SunAngles()
    local half = ((ed_terrain_info() or 257) - 1) / 2
    Cam():SnapTo(Vector(half, 26, half), { math.rad(az) + 1.5708, 0.30, 0 }, 170)
    return entry.id, entry.name
end

function Theme(i)
    local entry = Shipped(Lib.Themes())[i]
    if not entry then return nil end
    Lib.RevertPreview('theme')
    local ok, revert = Lib.ApplyTheme(entry, { preview = true })
    Lib.SetPreview('theme', revert)
    local half = ((ed_terrain_info() or 257) - 1) / 2
    Cam():SnapTo(Vector(half, 26, half), { 0, 1.35, 0 }, 105)
    return entry.id, entry.name
end
