#!/usr/bin/env python3
"""Writes the blank editor world: a flat 256x256 (5 km) map with one army, no props, no AI.

    python scripts/ed_make_blank_map.py [out_folder]

Without an argument it writes the templates of File > New map and Map > Resize (128, 256, 512, 1024, 2048) into editor/runtime/maps (mounted at /maps/<name> by
init_editor.lua); `--size N [maps_folder]` writes one of them; a folder argument writes the 256 map there.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "pylib"))
from luadata import LuaCall, LuaTable  # noqa: E402
from project import MapProject  # noqa: E402


def optimal_tile(px):
    """Tile size in world units for a texture px pixels wide: the same formula as editor/runtime/lua/editor/texscale.lua (texel density: px / (screen pixels per world unit
    at 1080 px, 45 degrees field of view, 27 units eye distance), rounded to 0.5, 4 .. 64)."""
    density = 1080 / (2 * 27 * math.tan(math.radians(45) / 2))
    return min(64.0, max(4.0, 20.0, math.floor(px / density / 0.5 + 0.5) * 0.5))      # 20 = texscale.lua REPEAT_MIN (a smaller tile repeats visibly)


# grass001_albedo.dds / _normals.dds of Evergreen are 512 x 512 (174904 bytes: DXT1 with mip maps, _asset_index/scd/env.scd.tsv)
GRASS_PX = 512


def vec(x, y, z):
    return LuaCall("VECTOR3", [x, y, z])


def build(folder, stem="editor_blank", size=256):
    proj = MapProject.new(folder, stem, size, size)
    sc = proj.scmap
    # flat ground at 25 world units (above any water plane), grass texture on the base layer
    ground = int(round(25.0 / sc.height_scale))
    for i in range(len(sc.heights)):
        sc.heights[i] = ground
    # tile sizes from texel density (optimal_tile); the editor gives a new map a full texture set anyway (texsets.ApplyIfNew), this is what a template shows before that
    tile = optimal_tile(GRASS_PX)
    sc.strata[0] = ("/env/Evergreen/layers/grass001_albedo.dds", tile)
    sc.strata_normals[0] = ("/env/Evergreen/layers/grass001_normals.dds", tile)
    # the opaque Upper layer is recognised by this exact size (40) and made transparent by strata.lua Normalize: do not change it without changing that test
    sc.strata[9] = ("/env/Evergreen/layers/Dirt001_albedo.dds", 40.0)
    # one army, one start marker in the middle
    info = dict((tuple(t), v) for t, v in proj.scenario_assign)[("ScenarioInfo",)]
    teams = info.get("Configurations").get("standard").get("teams")
    first = teams.array()[0] if hasattr(teams, "array") else None
    ffa = first
    ffa.set("armies", LuaTable([[None, "ARMY_1"]]))
    info.set("name", "Editor blank world")
    info.set("description", "Empty flat world the editor opens when no map is given.")

    save = dict((tuple(t), v) for t, v in proj.save_assign)[("Scenario",)]
    center = size // 2
    save.set("Armies", LuaTable([["ARMY_1", LuaTable([
        ["personality", ""], ["plans", ""], ["color", 0], ["faction", 0],
        ["Economy", LuaTable([["mass", 0], ["energy", 0]])],
        ["Alliances", LuaTable()], ["ArmyIndex", 1],
        ["Units", LuaTable([["type", "GROUP"], ["orders", ""], ["platoon", ""], ["Units", LuaTable([
            ["INITIAL", LuaTable([["type", "GROUP"], ["orders", ""], ["platoon", ""], ["Units", LuaTable()]])]])]])],
        ["PreBuiltUnits", LuaTable()],
    ])]]))
    chain = save.get("MasterChain").get("_MASTERCHAIN_")
    chain.set("Markers", LuaTable([["ARMY_1", LuaTable([
        ["color", "ff800080"], ["type", "Blank Marker"], ["prop", "/env/common/props/markers/M_Blank_prop.bp"],
        ["orientation", vec(0, 0, 0)], ["position", vec(center, 25.0, center)],
    ])]]))
    proj.save()
    return proj


# the templates of File > New map and of Map > Resize (editor/runtime/lua/editor/maps.lua Sizes, resize.lua Sizes): 2.5, 5, 10, 20, 40 and 80 km
TEMPLATES = ((128, "editor_blank_128"), (256, "editor_blank"), (512, "editor_blank_512"), (1024, "editor_blank_1024"), (2048, "editor_blank_2048"), (4096, "editor_blank_4096"))


if __name__ == "__main__":
    maps = os.path.join(HERE, "..", "editor", "runtime", "maps")
    args = sys.argv[1:]
    if args and args[0] == "--size":
        # python scripts/ed_make_blank_map.py --size 2048 [maps_folder]: one template into a maps folder
        size = int(args[1])
        name = dict((s, n) for s, n in TEMPLATES)[size]
        if len(args) > 2:
            maps = args[2]
        out = os.path.join(maps, name)
        os.makedirs(out, exist_ok=True)
        print("wrote", build(out, name, size).scmap_path)
    elif args:
        out = args[0]
        os.makedirs(out, exist_ok=True)
        print("wrote", build(out).scmap_path)
    else:
        for size, name in TEMPLATES:
            out = os.path.join(maps, name)
            os.makedirs(out, exist_ok=True)
            print("wrote", build(out, name, size).scmap_path)
