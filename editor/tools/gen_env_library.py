#!/usr/bin/env python3
"""Generates the shipped environment libraries of FAF Studio from the game's own campaign maps:

    editor/runtime/lua/editor/data/envlib_looks.lua    lighting / water / sky looks (the "presets")
    editor/runtime/lua/editor/data/envlib_themes.lua   strata themes (texture sets)

    python editor/tools/gen_env_library.py             # write both files
    python editor/tools/gen_env_library.py --check     # exit 1 when the files are stale

Sources: the 60 campaign and skirmish `.scmap` files of the retail install (fa_base/.../maps, read with map_editor/server/scmap.py), plus hand made looks and themes below: the hand made looks are
the nearest real map look with the sun, colours, fog and sky changed (dawn, noon, sunset, overcast, night ...), the hand made themes pick textures of the game's /env folders by name (every name
is checked against the asset index, a missing one stops the script). A look keeps the shape of `ed_scmap_env` (EdScmapEnv.cpp): { width, light, water (with texts), sky (with texts, billboards),
lookups, skycube, background } so that environment.lua applies it like a map imported from disk. Near identical looks (same lighting and water colour) are listed once.
Thumbnails of the looks and themes are rendered by editor/tools/gen_env_thumbs.py.
"""
import copy
import glob
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "pylib"))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from scmap import ScMap  # noqa: E402
import studio_paths as P  # noqa: E402

# Maintainer tool: its output (data/envlib_*.lua) is committed. Inputs: the retail install's maps (FAF_STUDIO_RETAIL, else fa_path of the FAForever client)
# and a folder of texture listings `env*.tsv` of the game archives (FAF_STUDIO_ASSET_INDEX; one path per line, first column).
MAPS = os.path.join(P.retail_install() or "", "maps")
OUT = os.path.join(ROOT, "editor", "runtime", "lua", "editor", "data")
INDEX = os.environ.get("FAF_STUDIO_ASSET_INDEX") or os.path.join(ROOT, "external", "asset_index")


def clean(x):
    """No denormals (the retail maps carry 1e-38 garbage in unused lanes), no -0."""
    x = float(x)
    if abs(x) < 1e-20:
        return 0.0
    return x


def triple(d, names, values):
    for n, v in zip(names, values):
        d[n] = clean(v)


def env_table(m):
    """What EdScmapEnv.cpp returns for a .scmap."""
    L = m.lighting
    light = {"light_mult": clean(L["multiplier"]), "bloom": clean(L["bloom"]), "fog_start": clean(L["fog_start"]), "fog_end": clean(L["fog_end"])}
    triple(light, ("sun_x", "sun_y", "sun_z"), L["sun_direction"])
    triple(light, ("ambient_r", "ambient_g", "ambient_b"), L["ambience"])
    triple(light, ("sun_r", "sun_g", "sun_b"), L["sun_color"])
    triple(light, ("fill_r", "fill_g", "fill_b"), L["shadow_fill"])
    triple(light, ("spec_r", "spec_g", "spec_b", "spec_a"), L["specular"])
    triple(light, ("fog_r", "fog_g", "fog_b"), L["fog_color"])
    W = m.water
    water = {"water_on": 1.0 if W["present"] else 0.0, "water_elev": clean(W["elevation"]), "water_deep": clean(W["elevation_deep"]), "water_abyss": clean(W["elevation_abyss"]),
             "w_lerp_0": clean(W["color_lerp"][0]), "w_lerp_1": clean(W["color_lerp"][1]), "w_refraction": clean(W["refraction_scale"]), "w_fresnel_bias": clean(W["fresnel_bias"]),
             "w_fresnel_power": clean(W["fresnel_power"]), "w_unit_refl": clean(W["unit_reflection"]), "w_sky_refl": clean(W["sky_reflection"]), "w_shininess": clean(W["sun_shininess"]),
             "w_strength": clean(W["sun_strength"]), "w_sun_refl": clean(W["sun_reflection"]), "w_glow": clean(W["sun_glow"])}
    triple(water, ("w_color_r", "w_color_g", "w_color_b"), W["surface_color"])
    triple(water, ("w_sundir_x", "w_sundir_y", "w_sundir_z"), W["sun_direction"])
    triple(water, ("w_suncol_r", "w_suncol_g", "w_suncol_b"), W["sun_color"])
    texts = {"water_cubemap": W["cubemap"], "water_ramp": W["ramp"]}
    for i, wave in enumerate(W["waves"]):
        water["w_repeat_%d" % i] = clean(wave["repeat"])
        water["w_move%d_x" % (i + 1)] = clean(wave["movement"][0])
        water["w_move%d_z" % (i + 1)] = clean(wave["movement"][1])
        texts["water_wave%d" % (i + 1)] = wave["texture"]
    water["texts"] = texts
    t = {"width": int(m.width), "minor": int(m.minor), "light": light, "water": water, "skycube": m.skycube, "background": m.background,
         "lookups": [x for pair in m.cubemaps for x in pair]}
    s = m.skybox
    if s:
        sky = {"dome_ox": s["position"][0], "dome_oy": s["position"][1], "dome_oz": s["position"][2], "dome_height": s["horizon_height"], "dome_radius": s["scale"],
               "dome_start": s["sub_height"], "dome_w": s["sub_div_ax"], "dome_h": s["sub_div_height"], "horizon_size": s["zenith_height"], "horizon_blend": s["decal_glow"],
               "cirrus_mult": s["cirrus_multiplier"]}
        triple(sky, ("horizon_r", "horizon_g", "horizon_b"), s["horizon_color"])
        triple(sky, ("sky_r", "sky_g", "sky_b"), s["zenith_color"])
        triple(sky, ("cirrus_r", "cirrus_g", "cirrus_b"), s["cirrus_color"])
        for i, layer in enumerate(s["cirrus_layers"][:4]):
            sky["cirrus%d_fx" % (i + 1)], sky["cirrus%d_fz" % (i + 1)] = layer["frequency"]
            sky["cirrus%d_speed" % (i + 1)] = layer["speed"]
            sky["cirrus%d_dx" % (i + 1)], sky["cirrus%d_dz" % (i + 1)] = layer["direction"]
        sky = {k: clean(v) for k, v in sky.items()}
        sky["texts"] = {"sky_billboards": s["albedo"], "sky_glow": s["glow"], "sky_cumulus1": "", "sky_cumulus2": "", "sky_cumulus3": "", "sky_cirrus": s["cirrus_texture"]}
        flat = []
        for p in s["planets"]:
            flat += [clean(v) for v in p["position"]] + [clean(p["rotation"])] + [clean(v) for v in p["scale"]] + [clean(v) for v in p["uv"]]
        sky["billboards"] = flat
        t["sky"] = sky
    return t


def themes_of(m):
    layers = {}
    for i, (albedo, size) in enumerate(m.strata):
        if albedo:
            layers[i] = {"albedo": albedo, "size": clean(size)}
    for i, (normal, size) in enumerate(m.strata_normals):
        if normal and i in layers:
            layers[i]["normal"] = normal
            layers[i]["nsize"] = clean(size)
    return layers


TILESETS = [("evergreen", "Evergreen"), ("desert", "Desert"), ("tundra", "Tundra"), ("lava", "Lava"), ("red barrens", "Red barrens"), ("geothermal", "Geothermal"),
            ("crystalline", "Crystalline"), ("tropical", "Tropical"), ("paradise", "Tropical"), ("swamp", "Swamp")]


def tileset_of(layers):
    for i in sorted(layers):
        path = layers[i]["albedo"].lower()
        for key, name in TILESETS:
            if "/env/" + key in path:
                return name
    return "Mixed"


def pretty(name):
    return name.replace("_", " ")


# ---- sun and colours ------------------------------------------------------------------------------------------------------------------------

def set_sun(light, az, el):
    a, e = math.radians(az), math.radians(el)
    light["sun_x"], light["sun_y"], light["sun_z"] = math.cos(e) * math.cos(a), math.sin(e), math.cos(e) * math.sin(a)


def rgb(d, prefix, r, g, b):
    d[prefix + "_r"], d[prefix + "_g"], d[prefix + "_b"] = r, g, b


def look(base, name, light=None, water=None, sky=None, sun=None, group="Moods"):
    t = copy.deepcopy(base)
    if sun:
        set_sun(t["light"], *sun)
    t["light"].update(light or {})
    t["water"].update(water or {})
    if "sky" in t:
        t["sky"].update(sky or {})
    return {"name": name, "group": group, "t": t}


def moods(maps):
    eg, desert, snow, lava, tropic, crystal = maps["SCMP_001"], maps["SCMP_003"], maps["SCMP_013"], maps["SCMP_023"], maps["SCMP_035"], maps["X1CA_004"]
    out = []

    def L(**kw):
        d = {}
        for k, v in kw.items():
            if isinstance(v, tuple):
                rgb(d, k, *v)
            else:
                d[k] = v
        return d

    out.append(look(eg, "Dawn", sun=(95, 11), light=L(light_mult=1.35, sun=(1.45, 1.0, 0.75), ambient=(0.12, 0.13, 0.2), fill=(0.5, 0.52, 0.72), fog=(0.9, 0.74, 0.68), fog_start=0, fog_end=1400, bloom=0.14),
                    water=L(w_color=(0.05, 0.1, 0.18), w_suncol=(1.0, 0.7, 0.45)), sky=L(horizon=(0.98, 0.72, 0.52), sky=(0.28, 0.4, 0.68), cirrus=(1.4, 0.95, 0.75), horizon_blend=0.25)))
    out.append(look(eg, "Morning", sun=(118, 28), light=L(light_mult=1.45, sun=(1.55, 1.3, 1.05), ambient=(0.08, 0.1, 0.16), fill=(0.48, 0.5, 0.66), fog=(0.78, 0.76, 0.74), fog_end=1500, bloom=0.1),
                    sky=L(horizon=(0.88, 0.8, 0.7), sky=(0.22, 0.42, 0.72), cirrus=(1.25, 1.1, 0.95))))
    out.append(look(eg, "Clear noon", sun=(200, 68), light=L(light_mult=1.5, sun=(1.65, 1.6, 1.5), ambient=(0.1, 0.12, 0.18), fill=(0.5, 0.54, 0.68), fog=(0.62, 0.78, 0.88), fog_end=1800, bloom=0.07),
                    sky=L(horizon=(0.66, 0.82, 0.88), sky=(0.16, 0.38, 0.72), cirrus=(1.2, 1.2, 1.25))))
    out.append(look(eg, "Afternoon", sun=(255, 40), light=L(light_mult=1.45, sun=(1.7, 1.45, 1.15), ambient=(0.1, 0.11, 0.15), fill=(0.5, 0.5, 0.62), fog=(0.78, 0.76, 0.7), fog_end=1500, bloom=0.09),
                    sky=L(horizon=(0.9, 0.82, 0.66), sky=(0.2, 0.4, 0.68), cirrus=(1.3, 1.15, 0.95))))
    out.append(look(eg, "Sunset", sun=(285, 7), light=L(light_mult=1.3, sun=(2.0, 0.9, 0.45), ambient=(0.14, 0.1, 0.16), fill=(0.55, 0.45, 0.6), fog=(0.9, 0.5, 0.35), fog_start=0, fog_end=1100, bloom=0.2),
                    water=L(w_suncol=(1.0, 0.55, 0.3)), sky=L(horizon=(1.0, 0.5, 0.28), sky=(0.22, 0.2, 0.45), cirrus=(1.6, 0.8, 0.55), horizon_blend=0.3)))
    out.append(look(eg, "Overcast", sun=(180, 60), light=L(light_mult=1.15, sun=(0.95, 0.98, 1.02), ambient=(0.22, 0.24, 0.27), fill=(0.62, 0.65, 0.7), fog=(0.62, 0.66, 0.7), fog_start=0, fog_end=1100, bloom=0.04),
                    water=L(w_color=(0.05, 0.08, 0.1), w_sun_refl=1.0, w_glow=0.0, w_sky_refl=0.8),
                    sky=L(horizon=(0.66, 0.69, 0.72), sky=(0.42, 0.47, 0.54), cirrus=(1.5, 1.5, 1.55), cirrus_mult=3.0, horizon_blend=0.0)))
    out.append(look(eg, "Storm", sun=(180, 40), light=L(light_mult=0.95, sun=(0.7, 0.74, 0.8), ambient=(0.16, 0.18, 0.21), fill=(0.45, 0.48, 0.55), fog=(0.34, 0.38, 0.43), fog_start=0, fog_end=700, bloom=0.03),
                    water=L(w_color=(0.03, 0.05, 0.07), w_sun_refl=0.5, w_glow=0.0),
                    sky=L(horizon=(0.4, 0.43, 0.48), sky=(0.2, 0.23, 0.29), cirrus=(0.9, 0.95, 1.0), cirrus_mult=4.0, horizon_blend=0.0)))
    out.append(look(eg, "Night", sun=(60, 38), light=L(light_mult=0.7, sun=(0.35, 0.42, 0.75), ambient=(0.06, 0.08, 0.16), fill=(0.14, 0.2, 0.36), fog=(0.04, 0.06, 0.12), fog_start=0, fog_end=900, bloom=0.25),
                    water=L(w_color=(0.0, 0.02, 0.06), w_suncol=(0.4, 0.5, 0.9), w_sun_refl=2.0), sky=L(horizon=(0.07, 0.1, 0.2), sky=(0.01, 0.03, 0.1), cirrus=(0.25, 0.3, 0.5), horizon_blend=0.6)))
    out.append(look(eg, "Foggy morning", sun=(110, 20), light=L(light_mult=1.2, sun=(1.2, 1.15, 1.05), ambient=(0.2, 0.22, 0.25), fill=(0.6, 0.62, 0.68), fog=(0.74, 0.76, 0.78), fog_start=0, fog_end=380, bloom=0.12),
                    sky=L(horizon=(0.78, 0.8, 0.82), sky=(0.5, 0.58, 0.68), cirrus=(1.2, 1.2, 1.2))))
    out.append(look(desert, "Desert noon", sun=(210, 62), light=L(light_mult=1.6, sun=(2.0, 1.85, 1.55), fog=(0.78, 0.66, 0.52), fog_end=1300, bloom=0.1), sky=L(horizon=(0.85, 0.72, 0.55), sky=(0.3, 0.5, 0.72)), group="Biomes"))
    out.append(look(desert, "Desert dusk", sun=(280, 9), light=L(light_mult=1.45, sun=(2.0, 1.0, 0.5), fog=(0.85, 0.5, 0.35), fog_end=900, bloom=0.16), sky=L(horizon=(1.0, 0.55, 0.3), sky=(0.25, 0.22, 0.42)), group="Biomes"))
    out.append(look(tropic, "Tropical day", sun=(175, 72), light=L(light_mult=1.45, sun=(1.65, 1.6, 1.4), fog=(0.62, 0.78, 0.82), fog_end=1600, bloom=0.1),
                    water=L(w_color=(0.1, 0.55, 0.5), w_refraction=0.45), group="Biomes"))
    out.append(look(snow, "Arctic day", sun=(150, 24), light=L(light_mult=1.3, sun=(1.2, 1.25, 1.4), ambient=(0.16, 0.18, 0.24), fill=(0.62, 0.66, 0.85), fog=(0.76, 0.8, 0.9), fog_end=700, bloom=0.14),
                    sky=L(horizon=(0.84, 0.88, 0.96), sky=(0.3, 0.5, 0.78)), group="Biomes"))
    out.append(look(snow, "Polar night", sun=(40, 6), light=L(light_mult=0.9, sun=(0.5, 0.6, 1.0), ambient=(0.08, 0.12, 0.22), fill=(0.2, 0.3, 0.55), fog=(0.08, 0.12, 0.22), fog_end=500, bloom=0.22),
                    sky=L(horizon=(0.12, 0.22, 0.34), sky=(0.02, 0.06, 0.16), cirrus=(0.2, 0.55, 0.45), horizon_blend=0.5), group="Biomes"))
    out.append(look(lava, "Volcanic", sun=(250, 22), light=L(light_mult=1.5, sun=(1.9, 0.9, 0.55), ambient=(0.2, 0.08, 0.05), fog=(0.3, 0.12, 0.08), fog_end=600, bloom=0.2),
                    water=L(w_color=(0.4, 0.08, 0.02), w_suncol=(1.0, 0.4, 0.15)), sky=L(horizon=(0.7, 0.22, 0.12), sky=(0.12, 0.05, 0.06), cirrus=(1.4, 0.55, 0.35)), group="Biomes"))
    out.append(look(crystal, "Alien crystal", sun=(100, 40), light=L(light_mult=1.4, sun=(0.7, 0.95, 1.5), fog=(0.06, 0.1, 0.18), fog_end=800, bloom=0.3),
                    sky=L(horizon=(0.08, 0.2, 0.3), sky=(0.02, 0.05, 0.15)), group="Biomes"))
    out.append(look(eg, "Bright and saturated (SC2 style)", sun=(215, 55), light=L(light_mult=1.6, sun=(1.9, 1.7, 1.4), ambient=(0.2, 0.22, 0.3), fill=(0.55, 0.62, 0.9), fog=(0.55, 0.78, 1.0), fog_end=2000, bloom=0.4,
                    spec_r=0.7, spec_g=0.7, spec_b=0.7, spec_a=0.6), water=L(w_color=(0.0, 0.8, 1.1), w_refraction=0.5, w_glow=0.3, w_sun_refl=8.0),
                    sky=L(horizon=(0.7, 0.9, 1.0), sky=(0.08, 0.35, 0.9), cirrus=(1.4, 1.4, 1.5), horizon_blend=0.3)))
    out.append(look(eg, "Cold and moody (SC2 style)", sun=(160, 30), light=L(light_mult=1.35, sun=(1.3, 1.45, 1.8), ambient=(0.14, 0.18, 0.28), fill=(0.38, 0.5, 0.78), fog=(0.4, 0.52, 0.66), fog_end=1200, bloom=0.3,
                    spec_r=0.5, spec_g=0.55, spec_b=0.7, spec_a=0.5), water=L(w_color=(0.0, 0.35, 0.6), w_refraction=0.4),
                    sky=L(horizon=(0.45, 0.58, 0.72), sky=(0.1, 0.22, 0.45), cirrus=(1.0, 1.15, 1.4))))
    return out


# ---- curated themes --------------------------------------------------------------------------------------------------------------------------

def read_index():
    names = {}
    for f in glob.glob(os.path.join(INDEX, "env*.tsv")):
        for line in open(f, encoding="utf-8", errors="replace"):
            path = line.split("\t")[0]
            if path.lower().startswith("/env/") and "/layers/" in path.lower():
                names[path.lower()] = path
    return names


# (name, group, base size, [(folder, texture), ...]) base first, then the painted layers 1..
CURATED = [
    ("Grassland", "Curated", [("Evergreen2", "EvGrass005a"), ("Evergreen2", "EvGrass010a"), ("Evergreen2", "Eg_Dirt002"), ("Evergreen2", "Eg_Gravel005"), ("Evergreen2", "EvRock006"), ("Evergreen2", "EvRock007"), ("Evergreen2", "EvTrans01")]),
    ("Alpine", "Curated", [("Evergreen2", "EvGrass009"), ("Evergreen2", "EvRock003"), ("Evergreen2", "EvRock006"), ("Evergreen2", "EvSnow003"), ("Evergreen2", "EG_Snow"), ("Evergreen2", "EG_Gravel2"), ("Evergreen2", "Eg_Dirt003")]),
    ("Snow field", "Curated", [("Tundra", "Tund_Snow"), ("Tundra", "Tund_Ice001"), ("Tundra", "Tund_ice004a"), ("Tundra", "Tund_Rock03"), ("Tundra", "Tund_Rock"), ("Tundra", "Tund_melt001"), ("Tundra", "Tund_gravil")]),
    ("Desert dunes", "Curated", [("Desert", "Des_SandMed02"), ("Desert", "Des_SandDark02"), ("Desert", "Des_sandLight"), ("Desert", "Des_Gravel01"), ("Desert", "Des_Rock01"), ("Desert", "Des_Rock03"), ("Desert", "Des_Sandwet")]),
    ("Tropical beach", "Curated", [("Tropical", "DrySand001"), ("Tropical", "Trop_Sand01"), ("Tropical", "WetSand001"), ("Tropical", "TrGrass002"), ("Tropical", "Trop_Grass"), ("Tropical", "TrRock002"), ("Tropical", "Tr_Reef_Coral")]),
    ("Jungle", "Curated", [("Tropical", "Trop_GrassJung"), ("Tropical", "TrGrass004"), ("Tropical", "TrBushy001"), ("Tropical", "Trop_Dirt"), ("Tropical", "TrRock005"), ("Tropical", "Tr_ground001"), ("Tropical", "TrTrans002")]),
    ("Volcanic", "Curated", [("Lava", "LAV_Gravel"), ("Lava", "LAV_Rock09"), ("Lava", "Lav_Cracked02"), ("Lava", "LAV_Lava01"), ("Lava", "LAV_Ribbon01"), ("Lava", "LAV_Rock03"), ("Lava", "LAV_Rock05")]),
    ("Red barrens", "Curated", [("Red Barrens", "RB_Sand"), ("Red Barrens", "RB_RedMud"), ("Red Barrens", "RB_Cracked02"), ("Red Barrens", "RB_Rock08"), ("Red Barrens", "RB_gravel01"), ("Red Barrens", "RB_Rock"), ("Red Barrens", "RB_Sandwet")]),
    ("Swamp", "Curated", [("Swamp", "Sw_Grass_01"), ("Swamp", "Sw_Mudder_02"), ("Swamp", "Sw_Sphagnum_01"), ("Swamp", "Sw_Rocky_01"), ("Swamp", "Sw_Ferns_01"), ("Swamp", "Sw_Creeper_01"), ("Swamp", "Sw_Mossy_01")]),
    ("Crystal plains", "Curated", [("Crystalline", "crystalWerk01"), ("Crystalline", "Cr_Rock05"), ("Crystalline", "Cr_Sandwet"), ("Crystalline", "Cryst010"), ("Crystalline", "crystalWerk04"), ("Crystalline", "Cr_Rock001"), ("Crystalline", "Cryst012")]),
    ("Geothermal", "Curated", [("Geothermal", "Geo_Dirt_01"), ("Geothermal", "Geo_LavaMd_02"), ("Geothermal", "Geo_Ashley_01"), ("Geothermal", "Geo_Rock002"), ("Geothermal", "Geo_LavaDk_01"), ("Geothermal", "Geo_LavaLt_01")]),
    ("Industrial wasteland", "Curated", [("Lava", "macrotexture002b"), ("Lava", "LAV_TECH_WIERS"), ("Evergreen2", "EG_Gravel"), ("Evergreen2", "Eg_Dirt001"), ("Desert", "Des_Gravel"), ("Utility", "farms001")]),
    ("Farmland", "Curated", [("Evergreen2", "EvGrass007"), ("Utility", "farms001"), ("Evergreen2", "Eg_Dirt002"), ("Evergreen2", "EvGrass003"), ("Evergreen2", "Eg_Gravel01"), ("Evergreen2", "EvRock002")]),
]

SIZES = [6.0, 4.0, 4.0, 4.0, 8.0, 8.0, 4.0, 4.0, 4.0]


def curated_themes(index):
    out = []
    for name, group, picks in CURATED:
        layers = {}
        for i, (folder, tex) in enumerate(picks):
            key = ("/env/%s/layers/%s_albedo.dds" % (folder, tex)).lower()
            if key not in index:
                raise SystemExit("theme %s: no texture %s in the asset index" % (name, key))
            albedo = index[key]
            entry = {"albedo": albedo, "size": SIZES[i] if i < len(SIZES) else 4.0}
            for suffix in ("_normals.dds", "_normal.dds", "_normalmap.dds"):
                cand = albedo[:-len("_albedo.dds")] + suffix
                if cand.lower() in index or cand.lower() in NORMALS:
                    entry["normal"] = NORMALS.get(cand.lower(), index.get(cand.lower(), cand))
                    entry["nsize"] = entry["size"]
                    break
            layers[i] = entry
        out.append({"name": name, "group": group, "layers": layers})
    return out


NORMALS = {}


def read_normals():
    for f in glob.glob(os.path.join(INDEX, "env*.tsv")):
        for line in open(f, encoding="utf-8", errors="replace"):
            path = line.split("\t")[0]
            low = path.lower()
            if low.startswith("/env/") and "/layers/" in low and ("_normal" in low):
                NORMALS[low] = path


# ---- lua output ---------------------------------------------------------------------------------------------------------------------------------

def lua(v, indent=0):
    pad = "    " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        if isinstance(v, float) and v == int(v) and abs(v) < 1e9:
            return "%d" % int(v)
        return "%.7g" % v
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=True)
    if isinstance(v, (list, tuple)):
        if all(isinstance(x, (int, float)) for x in v):
            return "{ " + ", ".join(lua(x) for x in v) + " }"
        return "{\n" + "".join(pad + "    " + lua(x, indent + 1) + ",\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        items = sorted(v.items(), key=lambda kv: (str(kv[0])))
        lines = []
        for k, x in items:
            key = "[%d]" % k if isinstance(k, int) else (k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) else "[%s]" % json.dumps(k))
            lines.append(pad + "    " + key + " = " + lua(x, indent + 1) + ",")
        return "{\n" + "\n".join(lines) + "\n" + pad + "}"
    raise TypeError(type(v))


def key_of(t):
    L, W = t["light"], t["water"]
    parts = [round(L[k], 2) for k in sorted(L)] + [round(W.get(k, 0), 2) for k in ("w_color_r", "w_color_g", "w_color_b")]
    return tuple(parts)


def build():
    read_normals()
    index = read_index()
    maps = {}
    for f in sorted(glob.glob(MAPS + "/*/*.scmap")):
        name = os.path.basename(f)[:-6]
        try:
            maps[name] = ScMap.read(f)
        except Exception as e:  # noqa: BLE001
            print("skip", name, e)
    tables = {n: env_table(m) for n, m in maps.items()}
    layers = {n: themes_of(m) for n, m in maps.items()}

    looks = []
    seen = {}
    for name in sorted(tables):
        t = tables[name]
        if "sky" not in t:
            continue
        k = key_of(t)
        label = "%s (%s)" % (pretty(name), tileset_of(layers[name]))
        if k in seen:
            seen[k]["desc"] += ", " + pretty(name)
            continue
        entry = {"id": "map_" + name.lower(), "name": label, "group": "Campaign maps", "desc": "Look of " + pretty(name), "t": t}
        seen[k] = entry
        looks.append(entry)
    mood_list = moods(tables)
    for e in mood_list:
        e["id"] = "look_" + re.sub(r"[^a-z0-9]+", "_", e["name"].lower()).strip("_")
        e["desc"] = "Hand made: " + e["name"]
    # moods and biomes in the order they are written above, then the maps
    looks = [e for e in mood_list if e["group"] == "Moods"] + [e for e in mood_list if e["group"] == "Biomes"] + looks

    themes = []
    seen_t = set()
    for e in curated_themes(index):
        e["id"] = "theme_" + re.sub(r"[^a-z0-9]+", "_", e["name"].lower()).strip("_")
        e["desc"] = "Hand picked textures of the game's /env folders"
        themes.append(e)
    for name in sorted(layers):
        ly = layers[name]
        if not ly.get(1) and not ly.get(2):
            continue
        sig = tuple((i, ly[i]["albedo"].lower(), ly[i].get("normal", "").lower()) for i in sorted(ly))
        if sig in seen_t:
            continue
        seen_t.add(sig)
        themes.append({"id": "map_" + name.lower(), "name": "%s (%s)" % (pretty(name), tileset_of(ly)), "group": "Campaign maps", "desc": "Texture layers of " + pretty(name), "layers": ly})
    return looks, themes


def files():
    looks, themes = build()
    head = "-- GENERATED by editor/tools/gen_env_library.py: do not edit.\n"
    return {
        "envlib_looks.lua": head + "-- Looks (lighting, water, sky) of the retail campaign maps and hand made moods, read by lua/editor/envlib.lua.\nLooks = " + lua(looks) + "\n",
        "envlib_themes.lua": head + "-- Strata themes (texture layers: albedo, normal and tile sizes of Base .. Upper) of the retail campaign maps and hand picked sets.\nThemes = " + lua(themes) + "\n",
    }


def main(argv):
    out = files()
    if "--check" in argv:
        for name, text in out.items():
            path = os.path.join(OUT, name)
            if not os.path.exists(path) or open(path, encoding="utf-8").read().replace("\r\n", "\n") != text:
                print("stale:", name)
                return 1
        print("up to date")
        return 0
    os.makedirs(OUT, exist_ok=True)
    for name, text in out.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("wrote", name, len(text), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
