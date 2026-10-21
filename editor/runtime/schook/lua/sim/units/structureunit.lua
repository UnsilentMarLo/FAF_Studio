-- While a map is edited its structures have no tarmac (footprint decal): the editor moves a unit by taking it down and putting it up again, and the decal of the old
-- place stayed behind (it could not be selected or removed), one more with every move. A test run creates the tarmacs (EdSetPlay in schook/lua/simcallbacks.lua).
-- Base: StructureUnit:CreateTarmac(createAlbedoTarmac, createNormalTarmac, createGlowTarmac, orientation, tarmac, lifeTime)
do
    local baseStructureUnit = StructureUnit
    StructureUnit = ClassUnit(baseStructureUnit) {
        CreateTarmac = function(self, createAlbedoTarmac, createNormalTarmac, createGlowTarmac, orientation, tarmac, lifeTime)
            if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode and not ScenarioInfo.EditorPlaying then
                return
            end
            return baseStructureUnit.CreateTarmac(self, createAlbedoTarmac, createNormalTarmac, createGlowTarmac, orientation, tarmac, lifeTime)
        end,

        -- A structure must never change the terrain of an edited map just because it exists (OnCreate calls these for every structure with Physics.FlattenSkirt: when the
        -- editor places, moves (the editor takes the unit down and makes it again), pastes or loads one, and again for one a test run builds). In an editor world both do nothing.
        -- Base: StructureUnit:FlattenSkirt()   StructureUnit:FlattenSkirtHorizontally()   (both flatten the heights under GetSkirtRect() with FlattenMapRect / FlattenGradientMapRect)
        FlattenSkirt = function(self)
            if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
                return
            end
            return baseStructureUnit.FlattenSkirt(self)
        end,

        FlattenSkirtHorizontally = function(self)
            if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
                return
            end
            return baseStructureUnit.FlattenSkirtHorizontally(self)
        end,

        -- OnCreate also turns defensive structures towards the nearest enemy or the map centre: in the editor the unit keeps the heading the mapper gave it (the preview showed that one).
        -- Base: StructureUnit:RotateTowardsEnemy()
        RotateTowardsEnemy = function(self)
            if ScenarioInfo and ScenarioInfo.Options and ScenarioInfo.Options.EditorMode then
                return
            end
            return baseStructureUnit.RotateTowardsEnemy(self)
        end,
    }
end
