-- Commands and menu items of the sweep batch (docs/projects/editor/PARITY_FINAL.md): Edit > Select the same / Select units of the same group / Select all of a kind.
-- A self-registering feature module (gui/feature_*.lua are imported by the shell). Logic: selectsame.lua.
--
-- Lua 5.0 dialect.

local Commands = import('/lua/editor/gui/commands.lua')
local Menu = import('/lua/editor/gui/menu.lua')
local Same = import('/lua/editor/selectsame.lua')

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

Commands.Register{ id = 'edit.select.same', title = 'Edit: select same type', run = function()
    local kind, value, text = Same.Describe()
    if not kind then Say('select an object first') return end
    Say('selected ' .. Same.Same() .. ' ' .. text)
end }
Commands.Register{ id = 'edit.select.group', title = 'Edit: select same group', run = function()
    local n = Same.UnitGroup()
    Say(n > 0 and ('selected ' .. n .. ' units of the group') or 'select a unit first')
end }
for _, k in { { 'marker', 'markers' }, { 'area', 'areas' }, { 'unit', 'units' }, { 'prop', 'props' }, { 'decal', 'decals' } } do
    local kind, plural = k[1], k[2]
    Commands.Register{ id = 'edit.select.all.' .. kind, title = 'Edit: select all ' .. plural, run = function() Say('selected ' .. Same.Everything(kind) .. ' ' .. plural) end }
end

Menu.Extend('menubar.Edit', function()
    local function Has() local kind = Same.Describe() return kind ~= nil end
    return {
        { title = function()
            local kind, value, text = Same.Describe()
            return kind and ('Select the same (' .. text .. ')') or 'Select the same'
          end, command = 'edit.select.same', enabled = Has, why = 'nothing selected',
          tip = 'Select every object that has the same marker type, prop or unit blueprint, or decal texture as the selected one.' },
        { command = 'edit.select.group', tip = 'Select all units of the army and group the selected unit belongs to.', enabled = function() return table.getn(import('/lua/editor/units.lua').Selection) > 0 end, why = 'select a unit first' },
        { title = 'Select all of a kind', tip = 'Select every object of one kind.', submenu = {
            { command = 'edit.select.all.marker', nokeys = true, tip = 'Select every marker of the map.' }, { command = 'edit.select.all.area', nokeys = true, tip = 'Select every area of the map.' },
            { command = 'edit.select.all.unit', nokeys = true, tip = 'Select every placed unit.' },
            { command = 'edit.select.all.prop', nokeys = true, tip = 'Select every prop.' }, { command = 'edit.select.all.decal', nokeys = true, tip = 'Select every decal.' },
        } },
    }
end, 45)
