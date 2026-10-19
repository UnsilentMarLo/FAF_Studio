-- Golden cases of the erosion suite (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3). One line per case: label | op | params | inputs | checksum.
-- Shared by the native test (engine/faf-re/src/sdk/moho/editor/tests/EdErosionTest.cpp: runs these with 1, 2, 3, 5 and 8 threads and rewrites the checksums with --update) and the
-- in-editor self test (selftest_erosion.lua: the same cases through the ed_field_* natives). Fixtures: H = mountain field 65 x 65 = add(affine(ridged seed=11 scale=26 octaves=3 persistence=0.4, mul=55), affine(perlin seed=111 scale=13 octaves=3, mul=8)),
-- R = perlin 65 x 65 seed=4 scale=14 octaves=3 (0..1 erodibility), F = const 33 x 33 value=10. The checksum is FNV-1a over the float32 bit patterns (ed_field_checksum), valid for the editor build (MSVC x64, no FMA contraction).

Cases = [[
hydraulic|erode_hydraulic|iterations=60|a=H|c322f2e192afd840
hydraulic_wear|erode_hydraulic|iterations=60,output=wear|a=H|e95522ac6b8a2dd8
hydraulic_deposit|erode_hydraulic|iterations=60,output=deposit|a=H|89110264525c76df
hydraulic_flow|erode_hydraulic|iterations=60,output=flow|a=H|db300d5a429f4b3c
hydraulic_water|erode_hydraulic|iterations=60,output=water|a=H|b05f780e08a906f0
hydraulic_thermal|erode_hydraulic|iterations=60,thermal=0.5,talus=0.6|a=H|4bcfe56f44740175
hydraulic_closed|erode_hydraulic|iterations=60,edge=closed|a=H|34185f2eb54c6c40
hydraulic_mask|erode_hydraulic|iterations=60|a=H,mask=R|fd025f995252ee1f
droplet|erode_droplet|density=0.8,seed=3|a=H|c22e08ec0cd54f14
droplet_wear|erode_droplet|density=0.8,seed=3,output=wear|a=H|d12fb346a64b5586
droplet_deposit|erode_droplet|density=0.8,seed=3,output=deposit|a=H|897e50b6b9061a86
droplet_thermal|erode_droplet|density=0.8,seed=3,thermal=0.5,thermal_steps=10|a=H|1fbaefb079812b2e
droplet_mask|erode_droplet|density=0.8,seed=3|a=H,mask=R|d7665f3dcc2dfd91
stream|erode_stream|iterations=6|a=H|9d04adc084d5a970
stream_wear|erode_stream|iterations=6,output=wear|a=H|abeb6d978487de30
stream_flow|erode_stream|iterations=6,output=flow|a=H|6e67331d7805c198
stream_mask|erode_stream|iterations=6|a=H,mask=R|a4af97faae5e03cf
slope_area|slope_area|bins=10,first=2|a=H|707ff2bdee825b0d
hydraulic_nomasks|erode_hydraulic|iterations=60,masks=0|a=H|c322f2e192afd840
basin_depth|basin_depth||a=H|506840f3723647f5
]]
