-- Golden cases of the path ops (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T4). One line per case: label | op | params | inputs | checksum.
-- Shared by the native test (engine/faf-re/src/sdk/moho/editor/tests/EdPathTest.cpp: builds and checks these with 1, 2, 3, 5 and 8 threads, and rewrites the checksums with
-- --update) and the in-editor self test (selftest_paths.lua: the same cases through the ed_field_* natives). Same format as selftest_fields_cases.lua.
-- pts = 8 numbers per point: x, z, y, w, f, bank, off, s. params: k=v,k=v with v a number, a word, or a list x:y;x:y (flattened). inputs: name=Fixture,... with the fixtures
--   A = perlin width=65,height=65,seed=7,scale=20,octaves=3      H = affine(A, mul=30, add=20) (a height field)      L = const width=65,height=65,value=20
--   M = voronoi width=65,height=65,scale=14,seed=5               B = perlin width=9,height=7,seed=3,scale=5,ox=4,oz=6 (a small field placed at sample 4, 6)
-- The checksum is FNV-1a over the float32 bit patterns (ed_field_checksum).

Cases = [[
dist|path_dist|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,far=-1|like=L|a4a00ec5c9696151
dist_signed|path_dist|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,signed=1|like=L|c149df6655dd7bad
dist_far|path_dist|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,far=99|like=L|0c18a2be3dab1e81
along|path_along|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451|like=L|aa04b04dec8b5673
along_norm|path_along|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,normalize=1,outside=-5|like=L|23daebb243b0b7c5
u|path_u|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451|like=L|85987cc43a01ee94
mask_weight|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,profile=0:1;1:0.2|like=L|2e5cd6be67bd168a
mask_core|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,kind=core|like=L|fced67ec20cd9c83
mask_reach|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,kind=reach,soft=2|like=L|dd569ba20d79e0c7
mask_bank|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,kind=bank|like=L|5dbb016a3aee39f3
mask_asym|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,symmetric=0,profile=0:0;0.4:1;1:0.3|like=L|a79013fe8f1d56e9
mask_linear|path_mask|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,profile=0:1;0.5:0.2;1:0.9,smooth=0|like=L|4f7664046b29a1d4
shape_offset|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=offset|a=H|78e3d04fb53840f1
shape_offset_v|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=offset,profile=0:1;1:0|a=H|fb2ed7163a05b353
shape_offset_u|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=offset,profile=0:1;0.6:0.95;0.9:0.15;1:0|a=H|9ba6a790a84eea93
shape_target|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=target|a=H|b2bb100a6c9eef7f
shape_target_min|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=target,clip=min|a=H|edac81e8e198ea6b
shape_target_max|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=target,clip=max,strength=0.8|a=H|394d08d87d0d391c
shape_target_bank|path_shape|pts=6:8:30:5:3:6:-6:0;20:14:34:6:3:-4:-6:15.23155;34:26:38:6:3:8:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:3:-6:72.27451,mode=target,profile=0:1;0.8:1;1:0.4|a=H|295de6b3b4daa676
shape_masked|path_shape|pts=6:8:30:5:3:0:-6:0;20:14:34:6:3:0:-6:15.23155;34:26:38:6:3:0:-6:33.67064;46:44:40:5:3:0:-6:55.30394;58:56:44:5:3:0:-6:72.27451,mode=target,strength=0.7|a=H,mask=M|ee6882c6f4947e71
shape_disc|path_shape|pts=32:32:35:8:4:0:5:0,mode=offset,profile=0:1;1:0|a=H|3cc722afbd7b4b9f
paste_add|path_paste|mode=add|a=H,b=B|97e06d057b0f7cd3
paste_sub|path_paste|mode=sub,scale=0.5|a=H,b=B|b836a4c2fb0f768c
paste_set|path_paste|mode=set|a=H,b=B|0edec026a05c3a3f
paste_max|path_paste|mode=max|a=H,b=B|7c8af48793c91a69
paste_min|path_paste|mode=min|a=H,b=B|0edec026a05c3a3f
]]
