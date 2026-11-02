-- Panel registry. Editor mods add panels by calling Register from a hook on this file or from their own module.
--
--   Panels.Register{
--       id = 'outliner',                 unique key (also the key in saved workspaces)
--       title = 'Outliner',              tab text
--       create = function(group, host)   build the panel's controls as children of `group` (positioned with widgets.Place);
--                    return panel        `panel` may define OnResize(w, h) and Destroy()
--       transparent = false,             true: no background or tab bar, the world shows through (the viewport)
--       minW = 160, minH = 80,           logical pixels
--       stack = { workspace = 'Mod', with = 'unitlab' },   optional: where the panel sits in a workspace preset (a tab beside `with`); no edit of workspace.lua needed
--       mod = 'My mod',                  optional: the mod that registers it (api.lua Mod(name).Panel does this); a mod's panel is turned off for the session after its first failure
--   }
--
-- Error isolation (api.lua GuardPanel): `create` raising does not leave a blank page, the panel shows the error and `Panels.failed[id]` holds the message; `failureListeners` (fn(id, message, mod))
-- are called for every failed create (the dock can show it where it wants). The methods OnResize, Refresh, Destroy, OnShow, OnHide, Update, Tick of the returned table run protected.
--
-- A panel keeps its model in module-level state (not in its controls): moving it to another window destroys and recreates
-- the controls from `create`.

registry = {}
order = {}
failed = {}                 -- panel id -> message of the last failed create
failureListeners = {}       -- fn(id, message, mod): called when a panel's create raised

--- Registers fn(id, message, mod) to be called when a panel could not be built.
function OnFailure(fn)
    table.insert(failureListeners, fn)
end

--   The narrowest a panel can be drawn without its controls running past the edge (logical pixels) when it does not declare `minW`. The dock keeps every stack at least that wide
--   (as far as the window allows); narrower than that the panel scrolls sideways.
DEFAULT_MIN_W = 200

function Register(def)
    if not def or not def.id then
        error('Panels.Register: a panel needs an id')
    end
    if not registry[def.id] then
        order[table.getn(order) + 1] = def.id
    end
    -- the group a panel builds into carries the panel's id: a widget looks it up (tooltips.lua ForWidget) to find its tooltip text
    local inner = def.create
    if inner and not def.tipScoped then
        def.tipScoped = true
        def.create = function(group, host)
            group.panelId = def.id
            return import('/lua/editor/api.lua').GuardPanel(def, inner, group, host)
        end
    end
    registry[def.id] = def
end

function Get(id)
    return registry[id]
end

function Title(id)
    local def = registry[id]
    return (def and def.title) or id
end

function All()
    local list = {}
    for i = 1, table.getn(order) do
        list[i] = registry[order[i]]
    end
    return list
end
