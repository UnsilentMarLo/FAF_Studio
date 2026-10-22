"""Writes the sample graphs of the terrain graph editor (stage T5) to editor/runtime/lua/editor/graphpresets/*.lua.

Each graph is defined here as a few lines (nodes with a column / row on the canvas, wires by key) and written as a plain data file `Graph = { ... }`
(the same format graph.lua saves), plus index.lua with the names. Run it after changing a graph:

    python scripts/make_graph_presets.py

Only values that differ from the node defaults need to be listed (graph.lua fills the rest in when it loads a file).
"""
import os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'editor', 'runtime', 'lua', 'editor', 'graphpresets')

# erosion presets of erosion.lua (the values that differ from the solver defaults; the shipped graph nodes use the same numbers, see TERRAIN_GEN_DESIGN.md)
DROPLET_MOUNTAIN = dict(density=3, lifetime=60, inertia=0.3, capacity=8, erode=0.45, deposit=0.15, gravity=5, thermal=0.4, thermal_steps=3, talus=0.9, vary=0.55, protect=0.7, drop_vary=0.6, max_change=25)
HYDRAULIC_HILLS = dict(deposition=0.08, thermal=0.3, talus=0.6)
HYDRAULIC_ISLAND = dict(erosion=0.06, deposition=0.08, thermal=0.3, talus=0.6, vary=0.3, rain_vary=0.4, protect=0.3)
HYDRAULIC_DESERT = dict(iterations=120, rain=0.002, evaporation=0.05, capacity=0.5, deposition=0.2, thermal=0.7, thermal_every=1, talus=0.35, vary=0.3, rain_vary=0.7, protect=0.3)
STREAM_CANYON = dict(iterations=14, k=1.5, max_cut=0.7, diffusion=0.05, widen=2, talus=1.2, area_min=40, jitter=0.3, protect=0.6, vary=0.5)
STREAM_BADLANDS = dict(iterations=20, k=0.8, diffusion=0.15, widen=2, area_min=60, talus=0.7, jitter=0.5, vary=0.6, vary_scale=40, protect=0.4)
DROPLET_CRATER = dict(lifetime=50, erode=0.2, thermal=0.5, thermal_steps=3, talus=0.8, protect=0.8, vary=0.3)


def lua(v, indent=0):
    pad = '    ' * (indent + 1)
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        if float(v) == int(v) and abs(v) < 1e9:
            return str(int(v))
        return repr(round(v, 6))
    if isinstance(v, str):
        return "'" + v.replace('\\', '\\\\').replace("'", "\\'") + "'"
    if isinstance(v, (list, tuple)):
        if not v:
            return '{}'
        if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v) or all(isinstance(x, (list, tuple)) and len(x) == 2 and all(isinstance(y, (int, float)) for y in x) for x in v):
            return '{ ' + ', '.join(lua(x, indent) for x in v) + ' }'
        return '{\n' + ',\n'.join(pad + lua(x, indent + 1) for x in v) + ',\n' + '    ' * indent + '}'
    if isinstance(v, dict):
        if not v:
            return '{}'
        items = ['[' + lua(k) + '] = ' + lua(x, indent + 1) for k, x in sorted(v.items())]
        if len(', '.join(items)) < 100 and '\n' not in ', '.join(items):
            return '{ ' + ', '.join(items) + ' }'
        return '{\n' + ',\n'.join(pad + i for i in items) + ',\n' + '    ' * indent + '}'
    raise ValueError(repr(v))


class G:
    def __init__(self, id, name, note, seed=1):
        self.id, self.name, self.note, self.seed = id, name, note, seed
        self.nodes = []
        self.keys = {}
        self.wires = []

    def n(self, key, type, col, row, **params):
        self.keys[key] = len(self.nodes) + 1
        self.nodes.append(dict(id=len(self.nodes) + 1, type=type, x=col * 224, y=row * 152, params=params))
        return key

    def w(self, a, b, port='a', out='out'):
        self.wires.append([self.keys[a], out, self.keys[b], port])

    def chain(self, *keys):
        for a, b in zip(keys[:-1], keys[1:]):
            self.w(a, b)

    def text(self):
        data = dict(version=1, name=self.name, seed=self.seed, nodes=self.nodes, wires=self.wires, nextId=len(self.nodes) + 1, view=dict(x=20, y=20, zoom=0.8))
        return '-- ' + self.note + '\nGraph = ' + lua(data) + '\n'


graphs = []


def mountains():
    g = G('mountains', 'Mountains (ridges, droplet erosion, cliffs and snow)', 'Ridged noise bent by a warp, scaled to heights, eroded by droplets; cliffs on the steep ground, snow on the high ground.', seed=3)
    g.n('r', 'ridged', 0, 0, scale=220, octaves=6)
    g.n('w', 'warp', 1, 0, strength=45, size=140)
    g.n('h', 'range', 2, 0, lo=14, hi=115)
    g.n('e', 'erode_droplet', 3, 0, **DROPLET_MOUNTAIN)
    g.n('o', 'out_height', 4, 0)
    g.n('s', 'slope', 4, 1)
    g.n('c', 'range_mask', 5, 1, lo=32, hi=90, soft=8)
    g.n('lc', 'out_layer', 6, 1, layer=3)
    g.n('sn', 'range_mask', 4, 2, lo=78, hi=200, soft=10)
    g.n('ls', 'out_layer', 5, 2, layer=4)
    g.chain('r', 'w', 'h', 'e', 'o')
    g.w('e', 's')
    g.chain('s', 'c', 'lc')
    g.w('e', 'sn')
    g.w('sn', 'ls')
    return g


def island():
    g = G('island', 'Island (radial falloff, hills, beach)', 'A noisy island: noise times a radial falloff, hydraulic erosion, a sand beach on the shore band.', seed=2)
    g.n('p', 'perlin', 0, 0, scale=150, octaves=5)
    g.n('rad', 'radial', 0, 1, invert=True)
    g.n('ss', 'smoothstep', 1, 1, edge0=0.12, edge1=0.7)
    g.n('m', 'mul', 2, 0)
    g.n('h', 'range', 3, 0, lo=8, hi=78)
    g.n('e', 'erode_hydraulic', 4, 0, **HYDRAULIC_ISLAND)
    g.n('o', 'out_height', 5, 0)
    g.n('sh', 'shore', 5, 1, width=4, soft=3)
    g.n('l', 'out_layer', 6, 1, layer=2)
    g.w('p', 'm')
    g.chain('rad', 'ss')
    g.w('ss', 'm', port='b')
    g.chain('m', 'h', 'e', 'o')
    g.w('e', 'sh')
    g.w('sh', 'l')
    return g


def canyon():
    g = G('canyon', 'Canyon (stream power river gorges)', 'A plateau cut by a drainage network of deep river valleys; rock on the walls.', seed=5)
    g.n('p', 'perlin', 0, 0, scale=260, octaves=4)
    g.n('t', 'terrace', 1, 0, steps=3, sharpness=0.4)
    g.n('h', 'range', 2, 0, lo=36, hi=96)
    g.n('e', 'erode_stream', 3, 0, **STREAM_CANYON)
    g.n('o', 'out_height', 4, 0)
    g.n('s', 'slope', 4, 1)
    g.n('c', 'range_mask', 5, 1, lo=28, hi=90, soft=8)
    g.n('l', 'out_layer', 6, 1, layer=3)
    g.chain('p', 't', 'h', 'e', 'o')
    g.w('e', 's')
    g.chain('s', 'c', 'l')
    return g


def hills():
    g = G('hills', 'Rolling hills (two noises, hydraulic erosion)', 'Soft hills from simplex and billow noise blended together, then eroded by water. Dirt patches on the flat ground.', seed=4)
    g.n('a', 'simplex', 0, 0, scale=140, octaves=5)
    g.n('b', 'billow', 0, 1, scale=90, octaves=4)
    g.n('bl', 'blend', 1, 0, mode='normal', opacity=0.35)
    g.n('h', 'range', 2, 0, lo=28, hi=62)
    g.n('e', 'erode_hydraulic', 3, 0, **HYDRAULIC_HILLS)
    g.n('o', 'out_height', 4, 0)
    g.n('mp', 'mask_preset', 4, 1, preset='patches')
    g.n('l', 'out_layer', 5, 1, layer=2)
    g.w('a', 'bl')
    g.w('b', 'bl', port='b')
    g.chain('bl', 'h', 'e', 'o')
    g.w('e', 'mp')
    g.w('mp', 'l')
    return g


def desert():
    g = G('desert', 'Desert (mesas, dunes, sand)', 'Terraced mesas with wind-worn edges; sand on the flat ground, rock on the steep.', seed=6)
    g.n('p', 'perlin', 0, 0, scale=170, octaves=4)
    g.n('t', 'terrace', 1, 0, steps=5, sharpness=0.8)
    g.n('bl', 'blur', 2, 0, radius=3)
    g.n('d', 'simplex', 0, 1, scale=45, octaves=3)
    g.n('ad', 'blend', 3, 0, mode='add', opacity=0.08)
    g.n('h', 'range', 4, 0, lo=26, hi=70)
    g.n('e', 'erode_hydraulic', 5, 0, **HYDRAULIC_DESERT)
    g.n('o', 'out_height', 6, 0)
    g.n('mp', 'mask_preset', 6, 1, preset='cliffs')
    g.n('l', 'out_layer', 7, 1, layer=3)
    g.chain('p', 't', 'bl', 'ad', 'h', 'e', 'o')
    g.w('d', 'ad', port='b')
    g.w('e', 'mp')
    g.w('mp', 'l')
    return g


def river_valley():
    g = G('river_valley', 'River valley (a river path through hills)', 'Gentle hills with a river carved along a wobbling path: a flat bed under the water level, banks, sand along the river.', seed=7)
    g.n('p', 'simplex', 0, 0, scale=170, octaves=4)
    g.n('h', 'range', 1, 0, lo=34, hi=58)
    g.n('r', 'path_line', 0, 1, x0=0.05, z0=0.3, x1=0.95, z1=0.7, wobble=0.12, width=9, falloff=14, height=3)
    g.n('sh', 'path_shape', 2, 0, mode='river', profile='u')
    g.n('o', 'out_height', 3, 0)
    g.n('m', 'path_mask', 2, 1, kind='reach')
    g.n('l', 'out_layer', 3, 1, layer=2)
    g.chain('p', 'h', 'sh')
    g.w('r', 'sh', port='pts')
    g.w('sh', 'o')
    g.w('r', 'm', port='pts')
    g.w('m', 'l')
    return g


def symmetric():
    g = G('symmetric', 'Symmetric hills (four-fold mirror)', 'Hills mirrored across both axes, exact copies: a fair, symmetric map by construction. Change the mode to rotate for a two-player map.', seed=8)
    g.n('p', 'simplex', 0, 0, scale=110, octaves=5)
    g.n('h', 'range', 1, 0, lo=30, hi=54)
    g.n('m', 'mirror', 2, 0, mode='xz')
    g.n('e', 'thermal', 3, 0, iterations=25, talus=0.5)
    g.n('o', 'out_height', 4, 0)
    g.n('b', 'mask_preset', 4, 1, preset='blocked')
    g.chain('p', 'h', 'm', 'e', 'o')
    g.w('e', 'b')
    return g


def archipelago():
    g = G('archipelago', 'Archipelago (many islands)', 'Cell noise cut into islands, rough coasts from fine noise, sand on the shores.', seed=9)
    g.n('v', 'voronoi', 0, 0, scale=170, jitter=0.9)
    g.n('inv', 'invert', 1, 0)
    g.n('p', 'perlin', 0, 1, scale=60, octaves=4)
    g.n('bl', 'blend', 2, 0, mode='add', opacity=0.22)
    g.n('ss', 'smoothstep', 3, 0, edge0=0.45, edge1=0.9)
    g.n('h', 'range', 4, 0, lo=8, hi=64)
    g.n('t', 'thermal', 5, 0, iterations=20)
    g.n('o', 'out_height', 6, 0)
    g.n('sh', 'shore', 6, 1, width=3.5)
    g.n('l', 'out_layer', 7, 1, layer=2)
    g.chain('v', 'inv', 'bl', 'ss', 'h', 't', 'o')
    g.w('p', 'bl', port='b')
    g.w('t', 'sh')
    g.w('sh', 'l')
    return g


def crater():
    g = G('crater', 'Crater lake (rim and bowl)', 'A radial profile drawn as a curve: bowl, high rim, outer slope; noise breaks it up. The bowl fills with the map\'s water.', seed=10)
    g.n('rad', 'radial', 0, 0, radius=150)
    g.n('cv', 'remap', 1, 0, points=[[0, 0.08], [0.35, 0.12], [0.62, 1], [0.85, 0.35], [1, 0.12]])
    g.n('p', 'perlin', 0, 1, scale=70, octaves=4)
    g.n('bl', 'blend', 2, 0, mode='add', opacity=0.14)
    g.n('h', 'range', 3, 0, lo=14, hi=92)
    g.n('e', 'erode_droplet', 4, 0, **DROPLET_CRATER)
    g.n('o', 'out_height', 5, 0)
    g.chain('rad', 'cv', 'bl', 'h', 'e', 'o')
    g.w('p', 'bl', port='b')
    return g


def badlands():
    g = G('badlands', 'Badlands (terraced ridges and gullies)', 'Sharp ridged terrain stepped into layers, slumped by thermal erosion, cut by river gullies.', seed=11)
    g.n('r', 'ridged', 0, 0, scale=100, octaves=5)
    g.n('t', 'terrace', 1, 0, steps=7, sharpness=0.55)
    g.n('h', 'range', 2, 0, lo=22, hi=74)
    g.n('th', 'thermal', 3, 0, iterations=40, talus=0.7)
    g.n('e', 'erode_stream', 4, 0, **STREAM_BADLANDS)
    g.n('o', 'out_height', 5, 0)
    g.n('mp', 'mask_preset', 5, 1, preset='gullies')
    g.n('l', 'out_layer', 6, 1, layer=2)
    g.chain('r', 't', 'h', 'th', 'e', 'o')
    g.w('e', 'mp')
    g.w('mp', 'l')
    return g


def plains():
    g = G('plains', 'Plains with a ridge line (path raise)', 'Nearly flat country with a low ridge raised along a path, forest density from noise (add props to the scatter node).', seed=12)
    g.n('p', 'simplex', 0, 0, scale=260, octaves=3)
    g.n('h', 'range', 1, 0, lo=32, hi=40)
    g.n('r', 'path_line', 0, 1, x0=0.1, z0=0.8, x1=0.9, z1=0.2, wobble=0.1, width=14, falloff=30, height=9)
    g.n('sh', 'path_shape', 2, 0, mode='raise', profile='ridge')
    g.n('o', 'out_height', 3, 0)
    g.n('n', 'simplex', 1, 2, scale=40, octaves=3, seed=21)
    g.n('ss', 'smoothstep', 2, 2, edge0=0.5, edge1=0.7)
    g.n('sc', 'out_scatter', 3, 2, count=600, minDist=7)
    g.chain('p', 'h', 'sh')
    g.w('r', 'sh', port='pts')
    g.w('sh', 'o')
    g.chain('n', 'ss', 'sc')
    return g


def texture_only():
    g = G('texturing', 'Texture the existing terrain (no height change)', 'Reads the heights of the map and paints texture layers by rules: cliffs, beach and snow. Layers 2, 3 and 4.', seed=1)
    g.n('t', 'terrain', 0, 0)
    g.n('b', 'mask_preset', 1, 0, preset='beach')
    g.n('c', 'mask_preset', 1, 1, preset='cliffs')
    g.n('s', 'mask_preset', 1, 2, preset='snow')
    g.n('lb', 'out_layer', 2, 0, layer=2)
    g.n('lc', 'out_layer', 2, 1, layer=3)
    g.n('ls', 'out_layer', 2, 2, layer=4)
    g.w('t', 'b')
    g.w('t', 'c')
    g.w('t', 's')
    g.w('b', 'lb')
    g.w('c', 'lc')
    g.w('s', 'ls')
    return g


def pathable_check():
    g = G('pathable', 'Gentle hills made pathable (slope check)', 'Hills whose steep parts are smoothed away, plus a view of the ground land units cannot cross (Mask view on the last node).', seed=13)
    g.n('p', 'simplex', 0, 0, scale=120, octaves=5)
    g.n('h', 'range', 1, 0, lo=30, hi=70)
    g.n('m', 'mask_preset', 3, 1, preset='blocked')
    g.n('sm', 'blur', 2, 0, radius=2)
    g.n('o', 'out_height', 3, 0)
    g.chain('p', 'h', 'sm', 'o')
    g.w('sm', 'm')
    return g


def two_players():
    g = G('two_players', 'Two player map (symmetric, flat bases, pathable)', 'Hills with a base pad, turned by 180 degrees so both bases and all terrain are exact copies, then the slope limited to what units can cross. For a real map set the pad node to markers mode (pads under the start positions and resource markers).', seed=14)
    g.n('p', 'simplex', 0, 0, scale=110, octaves=5)
    g.n('h', 'range', 1, 0, lo=30, hi=60)
    g.n('pad', 'pad_flatten', 2, 0, source='one', x=0.2, z=0.2, half=10, skirt=16)
    g.n('sym', 'symmetrize', 3, 0, mode='rot2')
    g.n('sl', 'slope_limit', 4, 0, limit=0.7, mode='both')
    g.n('o', 'out_height', 5, 0)
    g.n('core', 'unit_slope', 5, 1, which='blocked')
    g.chain('p', 'h', 'pad', 'sym', 'sl', 'o')
    g.w('sl', 'core')
    return g


def pathing():
    g = G('pathing', 'Pathing check (slope limit, passable regions)', 'Rough hills made pathable by the slope limit; the passable ground is labelled into connected regions and measured (select the Regions node and press Mask view or look at its numbers).', seed=15)
    g.n('p', 'ridged', 0, 0, scale=90, octaves=5)
    g.n('h', 'range', 1, 0, lo=25, hi=95)
    g.n('sl', 'slope_limit', 2, 0, limit=0.75, mode='lower')
    g.n('o', 'out_height', 3, 0)
    g.n('ok', 'unit_slope', 3, 1, which='passable')
    g.n('rg', 'regions', 4, 1, mode='size')
    g.chain('p', 'h', 'sl', 'o')
    g.w('sl', 'ok')
    g.w('ok', 'rg')
    return g


for make in (mountains, island, canyon, hills, desert, river_valley, symmetric, archipelago, crater, badlands, plains, texture_only, pathable_check, two_players, pathing):
    graphs.append(make())

# the library of stage T7 (scripts/make_graph_library.py): 20 graphs built from the SC specific nodes
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_graph_library
LIBRARY_IDS = []
for make in make_graph_library.LIB:
    lg = make(G)
    LIBRARY_IDS.append(lg.id)
    graphs.append(lg)

os.makedirs(OUT, exist_ok=True)
for g in graphs:
    with open(os.path.join(OUT, g.id + '.lua'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(g.text())
with open(os.path.join(OUT, 'index.lua'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('-- Sample graphs of the terrain graph editor (written by scripts/make_graph_presets.py).\nList = {\n')
    for g in graphs:
        f.write("    { id = '%s', name = '%s', note = '%s'%s },\n" % (g.id, g.name.replace("'", "\\'"), g.note.replace("'", "\\'"), ', library = true' if g.id in LIBRARY_IDS else ''))
    f.write('}\n')
print('wrote', len(graphs), 'graphs to', OUT)
