-- Marker layers: which categories of markers are shown in the world (display only: hidden markers stay in the map, can still be listed in the outliner and are saved).
-- Categories are those of tools.lua MarkerTypes: Resources, Areas and points, Paths, Other. The toggles are in the View panel.
--
--   CATEGORIES            { 'Resources', 'Areas and points', 'Paths', 'Other' }
--   IsHidden(markerType)  true when the type's category is switched off
--   Toggle(category)      show / hide a category (the overlay and the marker props follow at once)
--   Hidden                set: category name -> true
--
-- Lua 5.0 dialect.

local Tools = import('/lua/editor/tools.lua')

CATEGORIES = { 'Resources', 'Areas and points', 'Paths', 'Other' }
Hidden = {}

local categoryOf = {}

local function Category(markerType)
    local c = categoryOf[markerType]
    if c then return c end
    if next(categoryOf) == nil then
        for _, t in Tools.MarkerTypes() do categoryOf[t.name] = t.category end
    end
    return categoryOf[markerType] or 'Other'
end

function IsHidden(markerType)
    if next(Hidden) == nil then return false end
    return Hidden[Category(markerType)] and true or false
end

function Toggle(category)
    if Hidden[category] then Hidden[category] = nil else Hidden[category] = true end
    Tools.Changed = Tools.Changed + 1
end
