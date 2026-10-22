-- Golden cases of the erosion suite (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T3). One line per case: label | op | params | inputs | checksum.
-- Shared by the native test (engine/faf-re/src/sdk/moho/editor/tests/EdErosionTest.cpp: runs these with 1, 2, 3, 5 and 8 threads and rewrites the checksums with --update) and the
-- in-editor self test (selftest_erosion.lua: the same cases through the ed_field_* natives). Fixtures: H = mountain field 65 x 65 = add(affine(ridged seed=11 scale=26 octaves=3 persistence=0.4, mul=55), affine(perlin seed=111 scale=13 octaves=3, mul=8)),
-- R = perlin 65 x 65 seed=4 scale=14 octaves=3 (0..1 erodibility), F = const 33 x 33 value=10. The checksum is FNV-1a over the float32 bit patterns (ed_field_checksum), valid for the editor build (MSVC x64, no FMA contraction).

-- The cases from hydraulic_pinned on cover the map edge option (edge=pinned is the old behaviour) and the settings that vary the erosion or keep the terrain's range and volume.

Cases = [[
hydraulic|erode_hydraulic|iterations=60|a=H|4e24ea4c5e5dcd93
hydraulic_wear|erode_hydraulic|iterations=60,output=wear|a=H|e40d60a1bbc562b2
hydraulic_deposit|erode_hydraulic|iterations=60,output=deposit|a=H|aa621a4b5dc0a6c8
hydraulic_flow|erode_hydraulic|iterations=60,output=flow|a=H|25fdf4eb1a8b1fcc
hydraulic_water|erode_hydraulic|iterations=60,output=water|a=H|8ddb57d1d2d25c78
hydraulic_thermal|erode_hydraulic|iterations=60,thermal=0.5,talus=0.6|a=H|b5e355ea15602b4f
hydraulic_closed|erode_hydraulic|iterations=60,edge=closed|a=H|4b07ed21402cf6e9
hydraulic_mask|erode_hydraulic|iterations=60|a=H,mask=R|52f33e431d89e757
droplet|erode_droplet|density=0.8,seed=3|a=H|f7485e61e7eed0fa
droplet_wear|erode_droplet|density=0.8,seed=3,output=wear|a=H|76894324f6f6dafb
droplet_deposit|erode_droplet|density=0.8,seed=3,output=deposit|a=H|be5457bb208a39c8
droplet_thermal|erode_droplet|density=0.8,seed=3,thermal=0.5,thermal_steps=10|a=H|05c748f556a07ea9
droplet_mask|erode_droplet|density=0.8,seed=3|a=H,mask=R|6c50d54288e63777
stream|erode_stream|iterations=6|a=H|15d8265f439e1c62
stream_wear|erode_stream|iterations=6,output=wear|a=H|7861b209536d5089
stream_flow|erode_stream|iterations=6,output=flow|a=H|4427fb4ea005e617
stream_mask|erode_stream|iterations=6|a=H,mask=R|5ce482e8dcabca3a
slope_area|slope_area|bins=10,first=2|a=H|707ff2bdee825b0d
hydraulic_nomasks|erode_hydraulic|iterations=60,masks=0|a=H|4e24ea4c5e5dcd93
basin_depth|basin_depth||a=H|506840f3723647f5
hydraulic_pinned|erode_hydraulic|iterations=60,edge=pinned|a=H|c322f2e192afd840
hydraulic_vary|erode_hydraulic|iterations=60,vary=0.6,rain_vary=0.5,protect=0.5,keep_range=1,seed=5|a=H|c14e755412a55273
droplet_old_rule|erode_droplet|density=0.8,seed=3,accel=0|a=H|c5c392e31d4cf158
droplet_vary|erode_droplet|density=0.8,seed=3,vary=0.6,rain_vary=0.5,protect=0.5,drop_vary=0.5,thermal=0.4,thermal_steps=4|a=H|f2be71089f41df45
droplet_conserve|erode_droplet|density=0.8,seed=3,conserve=1,max_change=2|a=H|2bd2c91466f5ae14
stream_jitter|erode_stream|iterations=6,jitter=0.5,vary=0.5,rain_vary=0.5,protect=0.5,seed=2|a=H|0a0f0486e29060aa
]]
