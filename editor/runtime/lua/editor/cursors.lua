-- Mouse cursor of the world view per tool: a brush crosshair with the sign of its mode, a pin for markers, a box crosshair for areas,
-- and with the select tool the pointer / move cross / resize arrows depending on what is under it.
-- Textures are drawn by editor/tools/gen_cursors.py (editor/runtime/override/textures/editor/cursors). The world view keeps its own
-- `Cursor` table (filename, hotspot x, hotspot y) and applies it whenever the mouse moves over it, so this only sets that table.

local PATH = '/textures/editor/cursors/'

-- hotspots (keep in sync with gen_cursors.py)
local HOT = {
    brush_raise = { 14, 14 }, brush_lower = { 14, 14 }, brush_flatten = { 14, 14 }, brush_smooth = { 14, 14 }, brush_noise = { 14, 14 },
    marker = { 16, 29 }, area = { 12, 12 }, select = { 3, 2 }, move = { 16, 16 },
    size_ew = { 16, 16 }, size_ns = { 16, 16 }, size_nwse = { 16, 16 }, size_nesw = { 16, 16 },
}

local HANDLE_CURSOR = { e = 'size_ew', w = 'size_ew', n = 'size_ns', s = 'size_ns', nw = 'size_nwse', se = 'size_nwse', ne = 'size_nesw', sw = 'size_nesw' }

local current = false
local active = false

local function Set(view, id)
    if id == current then
        return
    end
    current = id
    if id and HOT[id] then
        view.Cursor = { PATH .. id .. '.dds', HOT[id][1], HOT[id][2] }
    else
        view.Cursor = {}
    end
    view.LastCursor = nil     -- make the world view re-apply it on the next mouse move
    if view.CursorOverWorld then
        if id and HOT[id] then
            GetCursor():SetTexture(PATH .. id .. '.dds', HOT[id][1], HOT[id][2])
        else
            GetCursor():Reset()
        end
    end
end

--- The cursor id for the active tool; `hit` = what the select tool is over (from tools.lua Pick) or nil.
function IdFor(tool, hit, dragging)
    if not tool then return false end
    if tool.kind == 'brush' then
        if tool.id == 'paint' then return 'brush_flatten' end      -- no cursors of their own yet
        if tool.id == 'erase' then return 'brush_lower' end
        return 'brush_' .. tool.id
    end
    if tool.kind == 'marker' then return 'marker' end
    if tool.kind == 'area' then return 'area' end
    if tool.kind == 'select' then
        if hit and hit.handle then return HANDLE_CURSOR[hit.handle] end
        if hit then return 'move' end
        return 'select'
    end
    return false
end

--- Applies the cursor of the active tool (call every frame while editing).
function Update(view, tool, hit)
    active = true
    Set(view, IdFor(tool, hit))
end

--- Back to the game's own cursor (play mode, shutdown).
function Reset(view)
    if active and view then
        Set(view, false)
    end
    active = false
end

-- ---- the cursor outside the world view (the shell's panels) ------------------------------------------------------------------------------

--- Sets the cursor right now (resize arrows over a splitter ...); the owner puts it back with ResetDefault when the pointer leaves.
function Use(id)
    local hot = HOT[id]
    if hot then
        GetCursor():SetTexture(PATH .. id .. '.dds', hot[1], hot[2])
    end
end

--- Back to the default cursor (the editor's pointer while it is installed, else the game's own).
function ResetDefault()
    GetCursor():Reset()
end

--- Makes the editor's pointer the default cursor: it shows over the panels and wherever the world view gives the cursor back.
function InstallDefault()
    local cursor = GetCursor()
    cursor:SetDefaultTexture(PATH .. 'select.dds', HOT.select[1], HOT.select[2])
    cursor:Reset()
end

--- The game's own default cursor again (play mode, shutting the editor GUI down).
function RestoreGameDefault()
    local file, hotX, hotY = import('/lua/ui/uiutil.lua').GetCursor('DEFAULT')
    local cursor = GetCursor()
    cursor:SetDefaultTexture(file, hotX, hotY)
    cursor:Reset()
end

