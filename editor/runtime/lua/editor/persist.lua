-- What the editor remembers of the user's working state between runs (the user folder, userdata.lua): the brush (radius, strength, falloff), the tool each
-- workspace was left with, the build grid and slope views. Layouts, UI scale and the last workspace are the shell's (gui/shell.lua).
--
--   Restore()     puts the remembered values back (the shell calls it once the first workspace stands)
--   Tick()        notes changes (the shell calls it a few times a second while editing); they are written by UserData.Flush()
--
-- Lua 5.0 dialect.

local UserData = import('/lua/editor/userdata.lua')

local lastBrush = false

local function UI() return import('/lua/editor/ui.lua') end

local function BrushText(b)
    return string.format('%d|%.2f|%.3f|%d', b.radius or 0, b.strength or 0, b.falloff or 0, b.sign or 1)
end

--- Puts the remembered brush, tool and view toggles back. Values that do not fit (a radius out of range, a tool of another workspace) are ignored.
function Restore()
    local Terrain = import('/lua/editor/terrain.lua')
    -- the brush settings of each kind of brush (terrain, texture, props, decals ...: ui.lua BRUSH_KIND); an older editor kept one brush: it becomes the terrain brush
    local function Valid(brush)
        if type(brush) ~= 'table' then return nil end
        local p = {}
        if type(brush.radius) == 'number' and brush.radius >= 1 and brush.radius <= 64 then p.radius = brush.radius end
        if type(brush.strength) == 'number' and brush.strength >= 0.1 and brush.strength <= 10 then p.strength = brush.strength end
        if type(brush.falloff) == 'number' and brush.falloff >= 0 and brush.falloff <= 1 then p.falloff = brush.falloff end
        if brush.sign == 1 or brush.sign == -1 then p.sign = brush.sign end
        return p
    end
    local saved = UserData.Get('brushes', false)
    if type(saved) ~= 'table' then
        local old = Valid(UserData.Get('brush', false))
        saved = old and { terrain = old } or {}
    end
    local uiMod = UI()
    for kind, brush in saved do
        local p = Valid(brush)
        if p then
            local live = { radius = Terrain.Brush.radius, strength = Terrain.Brush.strength, sign = Terrain.Brush.sign or 1, falloff = Terrain.Brush.falloff }
            for k, v in p do live[k] = v end
            uiMod.BrushProfiles[kind] = live
        end
    end
    local kind = uiMod.BRUSH_KIND[uiMod.State.tool]
    if kind and uiMod.BrushProfiles[kind] then
        local p = uiMod.BrushProfiles[kind]
        local B = Terrain.Brush
        B.radius, B.strength, B.sign, B.falloff = p.radius, p.strength, p.sign, p.falloff
    end
    import('/lua/editor/grid.lua').Visible = UserData.Get('grid', false) == true
    import('/lua/editor/slope.lua').Visible = UserData.Get('slope', false) == true
    local ui = UI()
    local tools = UserData.Get('tools', false)
    local id = type(tools) == 'table' and tools[ui.State.workspace or '']
    if id then pcall(ui.SelectTool, id) end
    lastBrush = BrushText(Terrain.Brush)
end

function Tick()
    local ui = UI()
    local Terrain = import('/lua/editor/terrain.lua')
    local B = Terrain.Brush
    local text = BrushText(B) .. '|' .. tostring(ui.State.tool)
    if text ~= lastBrush then
        lastBrush = text
        UserData.Set('brushes', ui.BrushSnapshot())
    end
    local grid, slope = import('/lua/editor/grid.lua').Visible and true or false, import('/lua/editor/slope.lua').Visible and true or false
    UserData.Set('grid', grid)
    UserData.Set('slope', slope)
    local ws, tool = ui.State.workspace, ui.State.tool
    if ws and tool then
        local tools = UserData.Get('tools', false)
        if type(tools) ~= 'table' then tools = {} end
        if tools[ws] ~= tool then
            local copy = {}
            for k, v in tools do copy[k] = v end
            copy[ws] = tool
            UserData.Set('tools', copy)
        end
    end
end
