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
--   }
--
-- A panel keeps its model in module-level state (not in its controls): moving it to another window destroys and recreates
-- the controls from `create`.

registry = {}
order = {}

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
            return inner(group, host)
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
