#!/usr/bin/env python
"""Turns the numbers of scripts/map_texture_stats.py (what the authors of the maps painted) into texture sets and recipe styles and writes
editor/runtime/lua/editor/mapsets.lua (texsets.lua and recipes.lua read it).

    python scripts/map_texture_stats.py                 # .runs/maptex/maps.json
    python scripts/map_texture_presets.py [--in FILE] [--themes-per-family N] [--report FILE]

1. every painted layer gets a ROLE (grass, dirt, wet, sand, rock, darkrock, highrock, snow) from the words in its texture name and from where it lies (slope, height, relief);
2. a map is a palette: role -> texture. Palettes whose textures are not in the game data are dropped; similar palettes are one cluster, the most common member represents it;
3. per family (the environment of the main ground texture) the most distinct clusters become texture sets ("Evergreen 2: <map>");
4. per family one recipe style: the knobs of recipes.lua (rock / cliff slope, snow share, dirt share, beach, wet strip, dark rock, crispness) are the median of what the maps of the family do
   (slope where the rock layers reach half / nine tenths of their weight, share of flat ground that is dirt, ...).
"""
import argparse
import collections
import json
import os
import re
import statistics
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_paths as SP  # noqa: E402

OUT = os.path.join(HERE, '..', 'editor', 'runtime', 'lua', 'editor', 'mapsets.lua')
ROLES = ('grass', 'rock', 'sand', 'dirt', 'wet', 'highrock', 'darkrock', 'snow')
SLOPE_CENTRES = (1.5, 4.5, 8.0, 12.5, 17.5, 25.0, 37.5, 55.0)
FAMILY_NAMES = {'evergreen': 'Evergreen', 'evergreen2': 'Evergreen 2', 'desert': 'Desert', 'tropical': 'Tropical', 'tundra': 'Tundra', 'red barrens': 'Red barrens',
                'paradise': 'Paradise', 'lava': 'Lava', 'swamp': 'Swamp', 'geothermal': 'Geothermal', 'ancient-earth': 'Ancient earth', 'crystalline': 'Crystalline',
                'redrock': 'Red rock', 'dark': 'Dark world'}

# words of a texture name, by kind; the first column is the role family
WORDS = [
    ('wet', ('wet', 'melt', 'swamp', 'bog', 'marsh', 'sphag', 'puddle', 'muddy')),
    ('snow', ('snow', 'ice', 'frost', 'glac')),
    ('darkrock', ('sandrock', 'darkrock', 'rockdark', 'cavern', 'basalt', 'obsid', 'volcan', 'lava', 'scorch', 'burnt', 'ash', 'char')),
    ('rock', ('rock', 'cliff', 'stone', 'boulder', 'rubble', 'slate', 'granite', 'mountain', 'crag')),
    ('sand', ('sand', 'beach', 'dune', 'reef', 'shore', 'coral')),
    ('grass', ('grass', 'moss', 'fern', 'bush', 'forest', 'leaf', 'meadow', 'field', 'trans', 'lawn', 'clover')),
    ('dirt', ('dirt', 'gravel', 'soil', 'mud', 'ground', 'clay', 'crack', 'dry', 'earth', 'road', 'path', 'pebble')),
]


def base_name(path):
    return os.path.basename(path.replace('\\', '/')).lower().replace('_albedo.dds', '').replace('.dds', '')


def keyword_kind(path):
    name = base_name(path)
    for kind, words in WORDS:
        for w in words:
            if w in name:
                return kind
    return None


def family_of(path):
    p = path.lower().replace('\\', '/')
    m = re.match(r'/env/([^/]+)/', p)
    return m.group(1) if m else 'maps'


def available_textures():
    names = set()
    roots = []
    r = SP.retail_install()
    if r:
        roots.append(os.path.join(r, 'gamedata'))
    pd = os.path.join(os.environ.get('ProgramData', r'C:\ProgramData'), 'FAForever', 'gamedata')
    roots.append(pd)
    for g in roots:
        if not os.path.isdir(g):
            continue
        for f in os.listdir(g):
            if f.lower().endswith(('.scd', '.nx2', '.zip')):
                try:
                    for x in zipfile.ZipFile(os.path.join(g, f)).namelist():
                        lx = x.lower()
                        if lx.startswith('env/') and lx.endswith('.dds'):
                            names.add('/' + lx)
                except Exception:
                    pass
    return names


# ---- roles of the layers of one map ---------------------------------------------------------------------------------------------------------------------------

def layer_features(rec):
    out = []
    for l in rec['layers'][:9]:
        if not l['albedo']:
            continue
        if l['layer'] > 0 and l.get('cover', 0) < 0.03:
            continue
        out.append(l)
    return out


def classify(rec):
    """-> { role: layer record } for one map (each layer at most one role, each role at most one layer), or {}."""
    ls = layer_features(rec)
    kind = {}
    for l in ls:
        k = keyword_kind(l['albedo'])
        sl = l.get('slope', 5.0)
        if k is None:
            if sl > 18:
                k = 'rock'
            elif l.get('h', 0.5) > 0.75 and l.get('rel', 0) > 0:
                k = 'grass'
            else:
                k = 'dirt'
        if k in ('grass', 'dirt', 'sand') and sl > 22 and 'trans' not in base_name(l['albedo']):
            k = 'rock'                       # steep, not rock by name: it is used as rock
        if k == 'darkrock' and sl < 10 and l.get('cover', 0) > 0.15:
            k = 'dirt'                       # dark ground that covers the flats (Des_SandDark): a ground colour
        kind[l['layer']] = k
    roles = {}
    # rock family: rock / highrock / darkrock by height and relief
    rockish = [l for l in ls if kind[l['layer']] in ('rock', 'darkrock')]
    if rockish:
        rockish.sort(key=lambda l: -l.get('cover', 0) * (1.0 + l.get('slope', 0) / 20.0))
        rock = rockish[0]
        roles['rock'] = rock
        rest = rockish[1:]
        if rest:
            hi = max(rest, key=lambda l: l.get('h', 0.5))
            if hi.get('h', 0.5) >= rock.get('h', 0.5) - 0.02:
                roles['highrock'] = hi
                rest = [x for x in rest if x is not hi]
        if rest:
            dk = min(rest, key=lambda l: l.get('rel', 0))
            roles['darkrock'] = dk
    flat_pref = {'grass': ('grass', 'dirt'), 'dirt': ('dirt', 'grass'), 'sand': ('sand', 'dirt'), 'wet': ('wet', 'dirt'), 'snow': ('snow',)}
    for l in sorted([x for x in ls if kind[x['layer']] in flat_pref], key=lambda x: (x['layer'] != 0, -x.get('cover', 0))):
        for r in flat_pref[kind[l['layer']]]:
            if r not in roles:
                roles[r] = l
                break
    # a layer must not carry two roles
    seen = {}
    for r, l in list(roles.items()):
        if l['layer'] in seen:
            del roles[r]
        else:
            seen[l['layer']] = r
    return roles


# ---- knobs of a map ------------------------------------------------------------------------------------------------------------------------------------------

def clamp(v, a, b):
    return max(a, min(b, v))


def curve_cross(curve, frac):
    """slope (degrees) where the curve first reaches frac of its plateau."""
    pts = [(SLOPE_CENTRES[i], v) for i, v in enumerate(curve) if v is not None]
    if not pts:
        return None
    top = max(v for _, v in pts)
    if top < 0.12:
        return None
    target = top * frac
    prev = None
    for x, v in pts:
        if v >= target:
            if prev is None:
                return x
            (x0, v0) = prev
            return x0 + (x - x0) * (target - v0) / max(1e-6, v - v0)
        prev = (x, v)
    return pts[-1][0]


def knobs_of(rec, roles):
    k = {}
    cover = lambda r: roles[r].get('cover', 0) if r in roles else 0.0
    steep = [roles[r] for r in ('rock', 'highrock', 'darkrock') if r in roles]
    if steep:
        curve = [None] * 8
        for i in range(8):
            vals = [l['bys'][i] for l in steep if l.get('bys') and l['bys'][i] is not None]
            curve[i] = min(1.0, sum(vals)) if vals else None
        r50, r90 = curve_cross(curve, 0.5), curve_cross(curve, 0.9)
        if r50 is not None:
            k['rock'] = clamp(round(r50), 12, 50)
            k['cliff'] = clamp(round(max(r90 or r50 + 8, r50 + 6)), max(20, k['rock'] + 6), 75)
    if 'snow' in roles:
        k['snow'] = clamp(round(cover('snow'), 2), 0.0, 0.45)
    else:
        k['snow'] = 0.0
    if 'highrock' in roles and roles['highrock'].get('byh'):
        k['high'] = clamp(round(roles['highrock'].get('h', 0.6) - 0.12, 2), 0.2, 0.95)
    if 'dirt' in roles and roles['dirt'].get('bys'):
        flat = [roles['dirt']['bys'][i] for i in (0, 1) if roles['dirt']['bys'][i] is not None]
        if flat:
            k['dirt'] = clamp(round(sum(flat) / len(flat), 2), 0.0, 0.8)
    else:
        k['dirt'] = 0.0
    if rec.get('water') is not None:
        k['beach'] = clamp(round(cover('sand') * 40, 1), 1.0, 12.0) if 'sand' in roles else 2.0
    k['wet'] = clamp(round(cover('wet') * 20, 1), 0.5, 8.0) if 'wet' in roles else 0.0
    k['dark'] = clamp(round(cover('darkrock') * 5, 2), 0.0, 1.0) if 'darkrock' in roles else 0.0
    cr = [(l.get('crisp', 0.5), l.get('cover', 0.1)) for l in roles.values() if 'crisp' in l]
    if cr:
        wsum = sum(c for _, c in cr) or 1.0
        k['crisp'] = clamp(round(0.15 + 0.8 * sum(x * c for x, c in cr) / wsum, 2), 0.2, 0.9)
    return k


# ---- palettes and clusters -----------------------------------------------------------------------------------------------------------------------------------

def jaccard(a, b):
    sa, sb = set(a.values()), set(b.values())
    return len(sa & sb) / float(len(sa | sb) or 1)


def pretty(name):
    n = re.sub(r'\.v\d+$', '', name)
    n = n.replace('_', ' ').strip()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='inp', default=os.path.join(SP.RUNS, 'maptex', 'maps.json'))
    ap.add_argument('--themes-per-family', type=int, default=3)
    ap.add_argument('--report', default=os.path.join(SP.RUNS, 'maptex', 'report.txt'))
    a = ap.parse_args()
    maps = json.load(open(a.inp, encoding='utf-8'))
    avail = available_textures()
    pal = []
    for rec in maps:
        if rec['size'] < 256:
            continue
        roles = classify(rec)
        if len(roles) < 4 or 'rock' not in roles:
            continue
        tex = {}
        for r, l in roles.items():
            p = l['albedo'].lower().replace('\\', '/')
            if p in avail:
                tex[r] = p
        if len(tex) < 4:
            continue
        base = rec['layers'][0]['albedo'].lower().replace('\\', '/')
        main = max((roles[r] for r in ('grass', 'dirt', 'sand') if r in tex), key=lambda l: l.get('cover', 0), default=None)
        fam = family_of(main['albedo']) if main else family_of(next(iter(tex.values())))
        upper = rec['layers'][9]['albedo'].lower().replace('\\', '/') if rec['layers'][9]['albedo'] else ''
        pal.append({'rec': rec, 'roles': roles, 'tex': tex, 'family': fam, 'base': base if base in avail else tex.get('grass') or tex.get('dirt'),
                    'upper': upper if upper in avail else '', 'knobs': knobs_of(rec, roles)})
    print('%d of %d maps give a palette' % (len(pal), len(maps)))
    # clusters
    pal.sort(key=lambda p: -sum(l.get('cover', 0) for l in p['roles'].values()))
    clusters = []
    for p in pal:
        for c in clusters:
            if c['family'] == p['family'] and jaccard(c['tex'], p['tex']) >= 0.55:
                c['members'].append(p)
                break
        else:
            clusters.append({'family': p['family'], 'tex': p['tex'], 'members': [p], 'rep': p})
    for c in clusters:
        # the representative: the member with the most roles, then the most maps share its textures
        c['rep'] = max(c['members'], key=lambda p: (len(p['tex']), p['rec']['size']))
        c['tex'] = c['rep']['tex']
    by_family = collections.defaultdict(list)
    for c in clusters:
        by_family[c['family']].append(c)
    themes, order, styles = {}, [], {}
    report = []
    for fam, cl in sorted(by_family.items(), key=lambda kv: -sum(len(c['members']) for c in kv[1])):
        total = sum(len(c['members']) for c in cl)
        if total < 3 and fam not in FAMILY_NAMES:
            continue
        cl.sort(key=lambda c: -len(c['members']))
        fname = FAMILY_NAMES.get(fam, fam.title())
        # role defaults of the family: the most used texture per role
        use = {r: collections.Counter() for r in ROLES}
        for c in cl:
            for m in c['members']:
                for r, t in m['tex'].items():
                    use[r][t] += 1
        chosen = []
        for c in cl:
            if len(chosen) >= a.themes_per_family:
                break
            if all(jaccard(c['tex'], o['tex']) < 0.5 for o in chosen):
                chosen.append(c)
        fam_ids = []
        for i, c in enumerate(chosen):
            rep = c['rep']
            tid = 'm_' + re.sub(r'[^a-z0-9]+', '_', fam.lower()).strip('_') + '_' + str(i + 1)
            th = {'label': '%s: %s' % (fname, pretty(rep['rec']['name'])), 'family': fam, 'map': rep['rec']['name'], 'maps': len(c['members']),
                  'size': 12, 'base': [rep['base']] if rep['base'] else [], 'upper': [rep['upper']] if rep['upper'] else []}
            for r in ROLES:
                lst = []
                if r in rep['tex']:
                    lst.append(rep['tex'][r])
                else:
                    for t, _ in use[r].most_common(1):         # a role the map does not paint: what the other maps of the family use
                        lst.append(t)
                th[r] = lst
            th['style'] = 'm_' + re.sub(r'[^a-z0-9]+', '_', fam.lower()).strip('_')
            themes[tid] = th
            fam_ids.append(tid)
            report.append('%-34s %3d maps  %s' % (th['label'], len(c['members']), ', '.join('%s=%s' % (r, base_name(th[r][0])) for r in ROLES if th[r])))
        order.append({'family': fam, 'label': fname, 'ids': fam_ids})
        # the recipe style of the family
        members = [m for c in cl for m in c['members']]
        kn = {}
        for key in ('rock', 'cliff', 'snow', 'high', 'dirt', 'beach', 'wet', 'dark', 'crisp'):
            vals = [m['knobs'][key] for m in members if key in m['knobs']]
            if len(vals) >= max(2, len(members) // 4):
                kn[key] = round(statistics.median(vals), 2)
        if 'rock' in kn and 'cliff' in kn:
            kn['cliff'] = clamp(max(kn['cliff'], kn['rock'] + 6), 20, 85)
        has = lambda r: sum(1 for m in members if r in m['roles']) / float(len(members))
        off = {}
        if has('snow') < 0.25:
            off['snow'] = True
            kn['snow'] = 0
        dry = sum(1 for m in members if m['rec'].get('water') is None and 'sand' in m['roles'] and m['roles']['sand'].get('cover', 0) > 0.05) / float(len(members)) > 0.4
        gr = [m['roles']['grass'].get('rel', 0) - m['roles']['dirt'].get('rel', 0) for m in members if 'grass' in m['roles'] and 'dirt' in m['roles']]
        relief = bool(gr) and statistics.median(gr) > 0.8
        styles[th['style']] = {'id': th['style'], 'name': '%s (from %d maps)' % (fname, len(members)), 'knobs': kn, 'off': off, 'drySand': dry, 'relief': relief,
                               'altForce': has('snow') >= 0.5}
        report.append('   style %-18s %s off=%s dry=%s relief=%s' % (th['style'], json.dumps(kn), list(off), dry, relief))
    write_lua(themes, order, styles)
    os.makedirs(os.path.dirname(a.report), exist_ok=True)
    open(a.report, 'w', encoding='utf-8').write('\n'.join(report) + '\n')
    print('\n'.join(report))
    print('%d texture sets in %d families, %d styles -> %s' % (len(themes), len(order), len(styles), os.path.normpath(OUT)))


def q(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def lua_list(l):
    return '{ ' + ', '.join(q(x) for x in l) + ' }'


def write_lua(themes, order, styles):
    L = ['-- GENERATED by scripts/map_texture_presets.py from scripts/map_texture_stats.py (the strata of the maps in the user\'s Maps folder); do not edit by hand.',
         '-- Themes: texture sets like texsets.lua Themes (+ family, map, maps = how many maps use a similar palette, style = id of the recipe style below).',
         '-- Order:  { { family, label, ids = { theme ids } }, ... } for the texture set menu.   Styles: entries for recipes.lua Presets (knobs measured on the maps of the family; recipes.lua adds `uses`).',
         '-- Lua 5.0 dialect.', '', 'Themes = {']
    for tid, th in sorted(themes.items()):
        L.append('    %s = { label = %s, family = %s, map = %s, maps = %d, size = %d, style = %s,' % (tid, q(th['label']), q(th['family']), q(th['map']), th['maps'], th['size'], q(th['style'])))
        L.append('        base = %s, upper = %s,' % (lua_list(th['base']), lua_list(th['upper'])))
        L.append('        ' + ', '.join('%s = %s' % (r, lua_list(th[r])) for r in ROLES) + ' },')
    L.append('}')
    L.append('Order = {')
    for o in order:
        L.append('    { family = %s, label = %s, ids = { %s } },' % (q(o['family']), q(o['label']), ', '.join(q(i) for i in o['ids'])))
    L.append('}')
    L.append('Styles = {')
    for sid, s in sorted(styles.items()):
        kn = ', '.join('%s = %s' % (k, ('%g' % v)) for k, v in sorted(s['knobs'].items()))
        off = ', '.join('%s = true' % r for r in s['off'])
        extra = ''.join(', %s = true' % f for f in ('drySand', 'relief', 'altForce') if s.get(f))
        L.append('    { id = %s, name = %s, knobs = { %s }, off = { %s }%s },' % (q(sid), q(s['name']), kn, off, extra))
    L.append('}')
    with open(OUT, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
