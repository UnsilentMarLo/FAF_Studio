-- Mission nodes that use platoon templates, order queues and platoon builders of the map (platoons.lua). They register themselves in the mission catalogue (mission.lua imports this
-- file last) and add parameter kinds 'platoon', 'orders' and 'builder' to the mission check.
--
--   platoon_group   Spawn a group as a platoon (an optional platoon template of the map replaces the one the group names, an optional order queue is given to it); keeps the platoon in
--                   a variable of type 'platoon'
--   orders_apply    Give a platoon variable an order queue
--   pbm_remove      Stop a platoon builder (the campaign AI forms no more platoons from it)
--
-- An order of a queue compiles to the platoon calls ScenarioFramework offers: Move / Patrol / Attack along a chain (PlatoonMoveChain, PlatoonPatrolChain, PlatoonAttackChain) or to one
-- marker (MoveToLocation, Patrol, AggressiveMoveToLocation), Stop to platoon:Stop().
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no string.match.

local M = import('/lua/editor/mission.lua')
local P = import('/lua/editor/platoons.lua')
local Map = import('/lua/editor/map.lua')

local Q = M.Quote

local FORMATIONS = { 'GrowthFormation', 'AttackFormation', 'NoFormation' }

local function Pos(marker)
    return 'ScenarioUtils.MarkerToPosition(' .. Q(marker) .. ')'
end

--- The lines that give platoon expression `target` the orders of queue `name`. An unknown queue gives a comment (the check reports it).
function OrderLines(target, name)
    local queue = (Map.Doc and Map.Doc.save.Orders and Map.Doc.save.Orders[name]) or nil
    if not queue then return { '-- (order queue ' .. M.Comment(name) .. ' does not exist)' } end
    local out = {}
    for _, o in queue do
        local chain = (o.chain or '') ~= '' and o.chain or nil
        local marker = (o.target or '') ~= '' and o.target or nil
        if o.type == 'Stop' then
            table.insert(out, target .. ':Stop()')
        elseif o.type == 'Move' then
            if chain then table.insert(out, 'ScenarioFramework.PlatoonMoveChain(' .. target .. ', ' .. Q(chain) .. ')')
            elseif marker then table.insert(out, target .. ':MoveToLocation(' .. Pos(marker) .. ', false)') end
        elseif o.type == 'Patrol' then
            if chain then table.insert(out, 'ScenarioFramework.PlatoonPatrolChain(' .. target .. ', ' .. Q(chain) .. ')')
            elseif marker then table.insert(out, target .. ':Patrol(' .. Pos(marker) .. ')') end
        elseif o.type == 'Attack' then
            if chain then table.insert(out, 'ScenarioFramework.PlatoonAttackChain(' .. target .. ', ' .. Q(chain) .. ')')
            elseif marker then table.insert(out, target .. ':AggressiveMoveToLocation(' .. Pos(marker) .. ')') end
        end
    end
    if table.getn(out) == 0 then table.insert(out, '-- (order queue ' .. M.Comment(name) .. ' is empty)') end
    return out
end

local function VarName(name)
    if type(name) ~= 'string' or not string.find(name, '^[%a_][%w_]*$') then return 'V.UNSET' end
    return 'V.' .. name
end

M.Register({ id = 'platoon_group', family = 'action', title = 'Spawn a group as a platoon (template, orders)',
    params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'group', label = 'Group', kind = 'group' },
               { key = 'platoon', label = 'Platoon template (optional)', kind = 'platoon', optional = true },
               { key = 'formation', label = 'Formation', kind = 'choice', choices = FORMATIONS, default = 'GrowthFormation' },
               { key = 'orders', label = 'Order queue (optional)', kind = 'orders', optional = true },
               { key = 'var', label = 'Keep as variable (optional)', kind = 'var', defines = true, vtype = 'platoon' } },
    emit = function(n)
        local out = {}
        local target = (n.var and n.var ~= '') and VarName(n.var) or 'platoon'
        if (n.platoon or '') ~= '' then
            -- the group's units are matched against this template when the platoon is made
            table.insert(out, 'do')
            table.insert(out, '    local node = ScenarioUtils.FindUnitGroup(' .. Q(n.group) .. ', Scenario.Armies[' .. Q(n.army) .. '].Units)')
            table.insert(out, '    if node then node.platoon = ' .. Q(n.platoon) .. ' end')
            table.insert(out, 'end')
        end
        table.insert(out, (target == 'platoon' and 'local ' or '') .. target .. ' = ScenarioUtils.CreateArmyGroupAsPlatoon(' .. Q(n.army) .. ', ' .. Q(n.group) .. ', ' .. Q(n.formation or 'GrowthFormation') .. ')')
        if (n.orders or '') ~= '' then
            for _, l in OrderLines(target, n.orders) do table.insert(out, l) end
        end
        return out
    end })

M.Register({ id = 'orders_apply', family = 'action', title = 'Give a platoon an order queue',
    params = { { key = 'var', label = 'Platoon variable', kind = 'var', vtype = 'platoon' }, { key = 'orders', label = 'Order queue', kind = 'orders' },
               { key = 'clear', label = 'Stop what it is doing first', kind = 'bool', default = true } },
    emit = function(n)
        local target = VarName(n.var)
        local out = {}
        if n.clear ~= false then table.insert(out, target .. ':Stop()') end
        for _, l in OrderLines(target, n.orders) do table.insert(out, l) end
        return out
    end })

M.Register({ id = 'pbm_remove', family = 'action', title = 'Stop a platoon builder',
    params = { { key = 'army', label = 'Army', kind = 'army' }, { key = 'builder', label = 'Builder', kind = 'builder' } },
    emit = function(n)
        return { 'do',
                 '    local brain = GetArmyBrain(' .. Q(n.army) .. ')',
                 '    if brain and brain.PBMRemoveBuilder then brain:PBMRemoveBuilder(' .. Q(n.builder) .. ') end',
                 'end' }
    end })

-- ---- the checks ---------------------------------------------------------------------------------------------------------------------------------------

M.KindChecks['platoon'] = function(v, n, p, doc)
    if not v or v == '' then
        if p.optional then return nil end
        return 'no platoon chosen'
    end
    if doc and doc.save.Platoons and not doc.save.Platoons[v] then return 'there is no platoon template ' .. tostring(v) .. ' (Platoons panel)' end
    return nil
end

M.KindChecks['orders'] = function(v, n, p, doc)
    if not v or v == '' then
        if p.optional then return nil end
        return 'no order queue chosen'
    end
    if doc and not (doc.save.Orders and doc.save.Orders[v]) then return 'there is no order queue ' .. tostring(v) .. ' (Platoons panel)' end
    return nil
end

M.KindChecks['builder'] = function(v, n, p, doc)
    if not v or v == '' then return 'no builder chosen' end
    if not (n.army and P.Builders(n.army) and P.Builders(n.army)[v]) then return 'army ' .. tostring(n.army) .. ' has no platoon builder ' .. tostring(v) end
    return nil
end
