-- lab camera: CAM = { x, z, zoom, heading (deg), pitch (deg) }; hides the editor UI the first time
local c0 = rawget(_G, 'CAM') or { 0.5, 0.5, 1, 0, 60 }
local size = (ed_terrain_info() or 257) - 1
local c = { c0[1] * size, c0[2] * size, c0[3] * size, c0[4], c0[5] }
if not rawget(_G, 'LAB_UI_HIDDEN') then
    LAB_UI_HIDDEN = true
    pcall(function() import('/lua/editor/gui/panels_builtin.lua').ReleaseWorldView(true) end)
    local sh = import('/lua/editor/gui/shell.lua')
    pcall(function() sh.S.main.root:Hide() end)
    pcall(function() sh.S.bar:Hide() end)
    pcall(function() sh.S.status:Hide() end)
    pcall(function()          -- a map with markers (resources, areas, paths): none drawn over the terrain
        local MF = import('/lua/editor/markerfilter.lua')
        for _, c in MF.CATEGORIES do if not MF.Hidden[c] then MF.Toggle(c) end end
    end)
end
local cam = GetCamera('WorldCamera')
local y = ed_terrain_get(math.floor(c[1]), math.floor(c[2])) or 0
cam:SnapTo(Vector(c[1], y, c[2]), { c[4] * math.pi / 180, c[5] * math.pi / 180, 0 }, c[3])
return 'cam ok'
