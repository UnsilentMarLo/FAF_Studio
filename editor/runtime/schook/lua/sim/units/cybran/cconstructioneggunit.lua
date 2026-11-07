-- A Cybran crab egg hatches the moment it is finished: OnStopBeingBuilt creates the unit it holds (Economy.BuildUnit), plays the opening animation and destroys the egg. In the editor
-- every unit is made that way (CreateUnitHPR), so a placed egg showed its unit at once, a second unit that was not in the map file and could neither be selected nor removed, and the
-- egg was gone. While a map is edited the egg stays an egg; what it would have done is kept in `self.EdDeferred` and runs when a test run starts (EdSetPlay in schook/lua/simcallbacks.lua).
-- Base: CConstructionEggUnit:OnStopBeingBuilt(builder, layer)
-- baseline: OnStopBeingBuilt
do
    local baseOnStopBeingBuilt = CConstructionEggUnit.OnStopBeingBuilt
    pcall(function() import('/lua/editor/hookcheck.lua').Expect('cconstructioneggunit', CConstructionEggUnit, { 'OnStopBeingBuilt' }) end)       -- best effort (the check only warns)
    CConstructionEggUnit.OnStopBeingBuilt = function(self, builder, layer)
        if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode and not ScenarioInfo.EditorPlaying then
            self.EdDeferred = function() baseOnStopBeingBuilt(self, builder, layer) end
            CStructureUnit.OnStopBeingBuilt(self, builder, layer)
            return
        end
        return baseOnStopBeingBuilt(self, builder, layer)
    end
end
