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
    }
end
