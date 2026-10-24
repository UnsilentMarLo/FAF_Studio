-- Golden cases of the Supreme Commander ops (docs/projects/editor/TERRAIN_GEN_DESIGN.md, stage T6). One line per case: label | op | params | inputs | checksum.
-- Shared by the native test (engine/faf-re/src/sdk/moho/editor/tests/EdScTest.cpp: builds and checks these with 1, 2, 3, 5 and 8 threads, and rewrites the checksums with
-- --update) and the in-editor self test (selftest_sctools.lua: the same cases through the ed_field_* natives). Same format as selftest_fields_cases.lua.
-- params: k=v,k=v with v a number, a word, or a list x:y;x:y (flattened). inputs: name=Fixture,... with the fixtures
--   A = perlin width=65,height=65,seed=7,scale=20,octaves=3      H = affine(A, mul=30, add=20) (a steep height field)      G = affine(A, mul=3, add=20) (gentle ground)
--   L = const width=65,height=65,value=20                         M = voronoi width=65,height=65,scale=14,seed=5            N = perlin width=65,height=65,seed=9,scale=16,octaves=2
--   P = threshold(N, 0.45) (a passable mask)                      C = affine(M, mul=3, add=1) (a cost multiplier)
-- The checksum is FNV-1a over the float32 bit patterns (ed_field_checksum).

Cases = [[
pad_basic|pad_flatten|pads=20.3:20.4:3:5:0:0;44:40:3:5:0:0|a=H|aea3d7cb5f7e98b0
pad_group|pad_flatten|pads=16:16:2:4:0:1;40:16:2:4:0:1;28:44:3:6:35:-1|a=H|0ce299933ef51f97
pad_weight|pad_flatten|pads=16:16:2:4:0:1;40:16:2:4:0:1;28:44:3:6:35:-1,output=weight|a=H|20c43ab187dafe82
pad_core|pad_flatten|pads=16:16:2:4:0:1;40:16:2:4:0:1;28:44:3:6:35:-1,output=core|a=H|b5f1fa0bd83a808a
pad_min|pad_flatten|pads=20:20:4:6:0:0;44:40:3:5:0:0,level=1|a=H|b5423572c8c17822
pad_max_strength|pad_flatten|pads=20:20:4:6:0:0;44:40:3:5:0:0,level=2,strength=0.6|a=H|c931a0a56269ec7b
pad_nosnap|pad_flatten|pads=20.5:20.5:3.2:4:0:0,snap=0,word=0|a=H|fbf737dba493c575
pad_grid4|pad_flatten|pads=21:21:5:8:0:0;50:44:6:3:0:0,grid=4|a=H|c3c2ab34f8aca8a4
pad_overlap|pad_flatten|pads=20:20:6:8:10:-1;28:22:6:8:50:-1|a=H|10e2047c161e4cc4
sym_mirror_x|symmetrize|mode=mirror_x|a=H|49b5a43a54b65896
sym_mirror_x_side1|symmetrize|mode=mirror_x,side=1|a=H|8dd3091c9b6af0b2
sym_mirror_z|symmetrize|mode=mirror_z|a=H|bbe6646da50e4547
sym_mirror_xz|symmetrize|mode=mirror_xz|a=H|b00a9d9736224238
sym_mirror_xz_q2|symmetrize|mode=mirror_xz,side=2|a=H|c831f126ad1d9240
sym_diag|symmetrize|mode=diag|a=H|7bf4c83298cf7673
sym_adiag|symmetrize|mode=adiag,side=1|a=H|eab8080b31c4b604
sym_diag_both|symmetrize|mode=diag_both|a=H|464225f7bcd032bc
sym_rot2|symmetrize|mode=rot2|a=H|1c190075da3ec138
sym_rot4|symmetrize|mode=rot4|a=H|eba17ebb50593034
sym_rot4_sector1|symmetrize|mode=rot4,sector=1|a=H|8a40f6705068dda4
sym_rot3|symmetrize|mode=rotn,n=3,cx=30.5,cz=34.25|a=H|d8c62289c655f13b
sym_rot5_angle|symmetrize|mode=rotn,n=5,angle=20|a=H|07625a375b025875
sym_nearest|symmetrize|mode=rotn,n=3,cx=30.5,cz=34.25,nearest=1|a=H|3ac3415cc203df50
sym_rot3_seam|symmetrize|mode=rotn,n=3,cx=32,cz=32,seam=6|a=H|1a0d1858e7056705
sym_rot4_seam|symmetrize|mode=rot4,seam=8|a=H|b330b26f23d3dc54
sym_rot4_angle90|symmetrize|mode=rot4,angle=90|a=H|8a40f6705068dda4
sym_rot2_seam|symmetrize|mode=rot2,seam=8,side=1|a=H|db8e07d685d5dfbc
sym_avg|symmetrize|mode=mirror_x,combine=avg|a=H|7139c28f36e09b16
sym_max_rot4|symmetrize|mode=rot4,combine=max|a=H|b39f6c7890d61e64
sym_min_diag_both|symmetrize|mode=diag_both,combine=min|a=H|0b2788c0e6c0b7a0
limit_lower|slope_limit|limit=0.75,mode=lower|a=H|513cfec00af587fe
limit_raise|slope_limit|limit=0.75,mode=raise|a=H|948418cc870f759e
limit_both|slope_limit|limit=0.75,mode=both|a=H|5339ca19775293d8
limit_balance|slope_limit|limit=0.4,mode=both,balance=0.2,margin=0.05|a=H|94c3184dfb79d686
limit_masked|slope_limit|limit=0.5,mode=both,strength=0.7|a=H,mask=M|0f822917d3be10b7
limit_gentle|slope_limit|limit=0.75,mode=both|a=G|06acb8ee9965fc03
reach_open|reach|src=3:4|a=L|a11b6f7cb5c6768e
reach_mask|reach|src=3:4;60:55|a=P|795491757ba686b5
reach_cost|reach|src=10:10,unreach=-5|a=P,b=C|afca12d1abda3c84
regions_label|regions||a=P|9edcff40efb26fea
regions_size|regions|mode=size|a=P|a24cbef1036c91b1
regions_4|regions|connectivity=4|a=P|9edcff40efb26fea
]]
