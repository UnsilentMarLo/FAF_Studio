-- Golden cases of the stage T7 ops (docs/projects/editor/TERRAIN_GEN_DESIGN.md, section T7). One line per case: label | op[@extra] | params | inputs | checksum.
-- Shared by the native test (engine/faf-re/src/sdk/moho/editor/tests/EdT7Test.cpp: builds and checks these with 1, 2, 3, 5 and 8 threads, rewrites the checksums with --update) and the in-editor
-- self test (selftest_t7.lua: the same cases through the ed_field_* natives). op@name checks the extra output `name` of an op with several results.
-- params: k=v,k=v with v a number, a word, or a list x:y;x:y (flattened). inputs: name=Fixture,... with the fixtures (65 x 65 samples)
--   A = perlin seed=7,scale=20,octaves=3        H = affine(A, mul=30, add=20) (gentle heights)       G = affine(A, mul=3, add=20)
--   R = ridged seed=4,scale=24,octaves=4        T = affine(R, mul=70) (mountains 0..70)              L = const 20
--   M = voronoi scale=14,seed=5                 N = perlin seed=9,scale=16,octaves=2                 P = threshold(N, 0.45) (a 0 / 1 mask)
--   S = affine(N, mul=4) (a soil depth)         W = affine(N, mul=0.6, add=0.3) (a talus map)
-- The checksum is FNV-1a over the float32 bit patterns (ed_field_checksum); it holds for the editor build (MSVC x64, fp:precise, no FMA contraction).

Cases = [[
musgrave_ridged|musgrave|width=33,height=33,seed=3,scale=12,octaves=5||d59908400c8ffaa0
musgrave_hybrid|musgrave|width=33,height=33,seed=3,scale=12,octaves=5,mode=hybrid,offset=0.7||e8b6cc5bbb474b96
musgrave_hetero|musgrave|width=33,height=33,seed=3,scale=12,octaves=5,mode=hetero,offset=0.7||cf25a9f240fb2b37
musgrave_cell2|musgrave|width=33,height=33,seed=5,scale=30,octaves=4,cell=2,ox=4,oz=6||d6a3415c34937bcf
fbm_damped|fbm_damped|width=33,height=33,seed=6,scale=14,octaves=6,damp=1.5||c514081e14800c23
cells_f1|cells|width=33,height=33,seed=2,scale=10||93c21a775e0d2a69
cells_f2|cells|width=33,height=33,seed=2,scale=10,mode=f2||2e8d2fa24e8a9f1d
cells_f3|cells|width=33,height=33,seed=2,scale=10,mode=f3||7211adebc727b971
cells_edge|cells|width=33,height=33,seed=2,scale=10,mode=edge,jitter=0.8||82a2800fd8577d6e
cells_crack|cells|width=33,height=33,seed=2,scale=10,mode=crack,thickness=0.2||b8838b5e08a14a46
cells_id|cells|width=33,height=33,seed=2,scale=10,mode=id||4141cf0ff0ec748f
cells_smooth|cells|width=33,height=33,seed=2,scale=10,mode=smooth,smooth=5||34bfd2d39bb8b41d
cells_border|cells|width=33,height=33,seed=2,scale=10,mode=border||ab18a1764f88fde1
cells_plate|cells|width=33,height=33,seed=2,scale=10,mode=plate,bevel=0.2,drop=0.5||95166c096695f036
cells_facet|cells|width=33,height=33,seed=2,scale=10,mode=facet||20d15def7c26a1ef
cells_manhattan|cells|width=33,height=33,seed=2,scale=10,metric=manhattan||aff28b644440145e
cells_chebyshev|cells|width=33,height=33,seed=2,scale=10,metric=chebyshev,mode=f2||461e7e2517250d30
cells_minkowski|cells|width=33,height=33,seed=2,scale=10,metric=minkowski,p=0.7||5af790979660a64b
cells_warp|cells|width=33,height=33,seed=2,scale=10,mode=id,warp=6,warp_scale=15||7f513bb0d55488dd
craters|craters|width=33,height=33,seed=4,scale=12,density=0.9||d62a8e97acb34582
craters_flat|craters|width=33,height=33,seed=4,scale=12,density=0.9,rim=0,shape=3,base=0.6||fa2af38d826470c8
dunes|dunes|width=33,height=33,seed=4,wavelength=9,angle=25||863771749598239d
dunes_sharp|dunes|width=33,height=33,seed=4,wavelength=9,angle=70,asym=1.4,ripples=0.3,warp=4||21a84f730af846dc
cracks|cracks|width=33,height=33,seed=4,scale=12,crack_width=2||5fa4232cc9789962
cracks_u3|cracks|width=33,height=33,seed=4,scale=14,crack_width=3,profile=u,levels=3||d41b4ee00d191f18
cracks_flat|cracks|width=33,height=33,seed=4,scale=14,crack_width=2,profile=flat,levels=1,warp=0||8ea152345c3bdcea
island_height|island|width=33,height=33,seed=4||ea319824badfe536
island_mask|island|width=33,height=33,seed=4,output=mask,aspect=1.5,angle=30||dc337affeb3d03b5
island_distance|island|width=33,height=33,seed=9,output=distance,roughness=0.8,radius=14||319368a0c881c3c6
dwarp_fbm|dwarp|strength=6,size=14|a=H|2fab4ff5e6c25577
dwarp_fbm2|dwarp|strength=6,size=14,iterations=2,octaves=2|a=H|487d8a67ef55a9fc
dwarp_curl|dwarp|kind=curl,strength=8,size=16|a=H|0e07e56f6792ba52
dwarp_swirl|dwarp|kind=swirl,strength=100,size=14|a=H|81ae4970b820732a
dwarp_ripple|dwarp|kind=ripple,strength=3,wavelength=12,angle=30,phase=1|a=H|bf8fc182b1b2b5db
dwarp_pinch|dwarp|kind=pinch,strength=0.4,size=16|a=H|10f68217f3732a46
dwarp_wrap_mask|dwarp|strength=8,size=14,edge=wrap|a=H,mask=P|9983336a4db6530e
bilateral|bilateral|radius=3,sigma_r=2|a=H|4da588c12f1981d8
bilateral_mask|bilateral|radius=3,sigma_r=1|a=T,mask=P|926e5039d8a88e79
diffuse|diffuse|iterations=15,kappa=0.4|a=T|276d3d81674efcf8
diffuse_exp|diffuse|iterations=15,kappa=0.4,g=exp,rate=0.15|a=T,mask=P|96c946bf9e4ee186
unsharp|unsharp|radius=2,amount=1.5|a=H|56019830ea65a8e4
unsharp_thr|unsharp|radius=3,amount=2,threshold=1|a=T,mask=P|9ee1212a6c7f4086
edge_sobel|edge|mode=sobel,gain=1.5|a=T|e15cca817bcd0407
edge_prewitt|edge|mode=prewitt,gain=1.5|a=T|47aaeb754a273c24
edge_laplace|edge|mode=laplace,gain=8,smooth=1|a=T|5db53cc5f76cf218
edge_laplace_signed|edge|mode=laplace,gain=8,signed=1|a=T|86a061f334c428eb
edge_dog|edge|mode=dog,radius=2,gain=2|a=T|56d8a2be3ffe8aeb
morph_dilate|morph|op=dilate,radius=3|a=T|a271e7626ae1921e
morph_erode_disc|morph|op=erode,radius=3,shape=disc|a=T|1a6aa1628f81fe11
morph_open_cross|morph|op=open,radius=3,shape=cross|a=T|f3ad75e6e1218c01
morph_close_diamond|morph|op=close,radius=3,shape=diamond|a=T|47b0433f26e9e99c
morph_gradient|morph|op=gradient,radius=2,shape=disc|a=T|2b4a80c9d3564ce4
morph_tophat|morph|op=tophat,radius=4|a=T|99f5d49f5a8fc841
morph_bothat|morph|op=bothat,radius=4,shape=disc|a=T|e85407f4918de6d0
convolve_emboss|convolve|kernel=-2:-1:0;-1:1:1;0:1:2,normalize=0,bias=20|a=H|59a30e3b687a15b5
convolve_gauss5|convolve|kernel=1:4:6:4:1;4:16:24:16:4;6:24:36:24:6;4:16:24:16:4;1:4:6:4:1|a=H|bc5a676961574fa7
convolve_wrap|convolve|kernel=0:1:0;1:-4:1;0:1:0,normalize=0,edge=wrap|a=H|30abcbeb3f674dc6
blur_dir_box|blur_dir|angle=30,length=9|a=T|ffdb0d1807764ca2
blur_dir_tri|blur_dir|angle=100,length=12,shape=tri|a=T,mask=P|b54f7ab707abcca5
blur_dir_gauss|blur_dir|angle=200,length=15,shape=gauss|a=T|9ad0936992167781
blur_slope_flat|blur_slope|radius=3,lo=0.1,hi=0.4|a=T|a191ee472180f7e2
blur_slope_steep|blur_slope|radius=3,lo=0.1,hi=0.4,mode=steep,amount=0.8|a=T,mask=P|08c168639b20153b
stratify|stratify|thickness=2.5,variation=0.5,warp=1.5,tilt_x=0.02,sharpness=0.8,seed=3|a=H|4b2024d1cddeaf05
stratify_slope|stratify|thickness=3,slope_lo=0.1,slope_hi=0.4,sharpness=0.9|a=T,mask=P|db9c726aaf83e660
occlusion_cavity|occlusion|radius=12,gain=2|a=T|95e2684b65f6f3be
occlusion_convex|occlusion|radius=12,mode=convex,gain=2,directions=8|a=T|ce2e7d5f0ed4d28b
occlusion_both|occlusion|radius=20,mode=both,gain=2,directions=16|a=T|14cd3513fc79c896
hillshade|hillshade|azimuth=225,altitude=35|a=T|469fcecad066b9e6
hillshade_shadows|hillshade|azimuth=300,altitude=25,shadows=1,ambient=0.3|a=T|ba4b6e36f3e02dd4
hillshade_lit|hillshade|mode=lit,azimuth=225,altitude=30|a=T|3c4bf221c78fa40f
hillshade_shadow|hillshade|mode=shadow,azimuth=45,altitude=20,shadow_len=60|a=T|0e74d328e388a8c3
wetness|wetness||a=T|15ef68cfa435104c
wetness_twi|wetness|mode=twi,smooth=1.5|a=T|bcbb1227e48af6e5
wetness_area|wetness|mode=area,p=2|a=T|c46a95a9f78d7a85
rockiness|rockiness|seed=3|a=T|15d6926c1e93f75e
rockiness_soil|rockiness|breakup=0,soil_full=2|a=T,b=S|3176d0230bce6f96
color_ramp|color_ramp|stops=0:0.1:0.3:0.7:1;0.4:0.8:0.8:0.5:1;1:1:1:1:0.5|a=N|e99f99fbc93b3d07
color_ramp_g|color_ramp@g|stops=0:0.1:0.3:0.7:1;0.4:0.8:0.8:0.5:1;1:1:1:1:0.5|a=N|6f16cfddd22d8dd8
color_ramp_b|color_ramp@b|stops=0:0.1:0.3:0.7:1;0.4:0.8:0.8:0.5:1;1:1:1:1:0.5|a=N|60072e9ade4f0796
color_ramp_a|color_ramp@a|stops=0:0.1:0.3:0.7:1;0.4:0.8:0.8:0.5:1;1:1:1:1:0.5,interp=smooth,lo=0.2,hi=0.8|a=N|40b83d337ebdc94c
thermal_map|thermal_map|iterations=20,talus_lo=0.25,talus_hi=1|a=T,b=W|17135329714cec2b
thermal_map_scree|thermal_map@scree|iterations=20,talus_lo=0.25,talus_hi=1,scree_scale=0.5|a=T,b=W|b993fff1602aa0ec
thermal_map_moved|thermal_map@moved|iterations=20,talus=0.4|a=T,mask=P|453a4cc0ada3321b
rocksoil|erode_rocksoil|iterations=30,weather=0.02,soil=0.5|a=T|22f207a700b1cce0
rocksoil_soil|erode_rocksoil@soil|iterations=30,weather=0.02,soil=0.5|a=T|b6f46365f9a2ee02
rocksoil_rock|erode_rocksoil@rock|iterations=30,weather=0.02,soil=0.5,rock_vis=0.8|a=T,b=S|bca13b2c4cbe496a
snow|erode_snow|snowline=35,band=6,amount=3,iterations=20|a=T|5cd3f9749e848742
snow_cover|erode_snow@cover|snowline=35,band=6,amount=3,iterations=20,cover_depth=1|a=T,mask=P|e8bc7c4f5ddaa552
snow_depth|erode_snow@snow|snowline=35,band=6,amount=3,iterations=20|a=T|b545159d07c8adbc
wind|erode_wind|iterations=25,azimuth=20,sand=0.8,abrade=0.03|a=H|0bc2b3bc0d09e464
wind_sand|erode_wind@sand|iterations=25,azimuth=20,sand=0.8,abrade=0.03|a=H|eb850cf6f9f31099
wind_abrasion|erode_wind@abrasion|iterations=25,azimuth=200,abrade=0.05|a=T,b=S|b9667b788ed0c0bb
glacier|erode_glacier|iterations=80,ela=30,erode=0.002|a=T|b43e2b503073929e
glacier_ice|erode_glacier@ice|iterations=80,ela=30,erode=0.002|a=T|5929e9cdddddbab0
glacier_carve|erode_glacier@carve|iterations=80,ela=30,erode=0.002|a=T,b=W|e71bd13608d26368
settle|settle|iterations=15,rate=0.5,cap=1|a=T|cf04af7ce727ec65
settle_deposit|settle@deposit|iterations=15,rate=0.5,cap=1,deposit_scale=2|a=T,mask=P|2dacd779ee58a0a3
]]
