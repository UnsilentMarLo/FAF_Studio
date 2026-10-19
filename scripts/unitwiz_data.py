#!/usr/bin/env python
"""Generates editor/runtime/lua/editor/unitwizdata.lua: the donor data of the unit wizard's templates.

For every template (bot, tank, hover, naval, air, defence, economy, engineer, factory) and faction one vanilla unit is the donor of
  * the skeleton (bone names, parents, bind pose) of its LOD0 mesh: read from units.scd (scm_dump.py),
  * the sound set (the blueprint's Audio block, as the Sound{} calls), animation paths, weapon bone names and the numbers that make a unit of that kind behave
    (motion, footprint, mesh extents, uniform scale, command caps ...): read from faf_repo/fa/units/<ID>/<ID>_unit.bp.
The wizard never copies a blueprint: it builds its own from the template defaults and takes these pieces by reference (sound cues, animation files, bone names).

  python scripts/unitwiz_data.py [--out PATH]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scm_dump  # noqa: E402

ROOT = os.path.dirname(HERE)
FAF_UNITS = None
import studio_paths as P  # noqa: E402
for cand in (os.path.join(P.FAF_REPO, 'units'),):
    if os.path.isdir(cand):
        FAF_UNITS = cand
        break

OUT = os.path.join(ROOT, 'editor', 'runtime', 'lua', 'editor', 'unitwizdata.lua')

DONORS = {
    'bot': {'UEF': 'uel0106', 'Cybran': 'url0106', 'Aeon': 'ual0106', 'Seraphim': 'xsl0101'},
    'tank': {'UEF': 'uel0201', 'Cybran': 'url0107', 'Aeon': 'ual0201', 'Seraphim': 'xsl0201'},
    'hover': {'UEF': 'uel0203', 'Cybran': 'url0203', 'Aeon': 'ual0201', 'Seraphim': 'xsl0203'},
    'naval': {'UEF': 'ues0103', 'Cybran': 'urs0103', 'Aeon': 'uas0103', 'Seraphim': 'xss0103'},
    'air': {'UEF': 'uea0102', 'Cybran': 'ura0102', 'Aeon': 'uaa0102', 'Seraphim': 'xsa0102'},
    'defence': {'UEF': 'ueb2101', 'Cybran': 'urb2101', 'Aeon': 'uab2101', 'Seraphim': 'xsb2101'},
    'economy': {'UEF': 'ueb1101', 'Cybran': 'urb1101', 'Aeon': 'uab1101', 'Seraphim': 'xsb1101'},
    'engineer': {'UEF': 'uel0105', 'Cybran': 'url0105', 'Aeon': 'ual0105', 'Seraphim': 'xsl0105'},
    'factory': {'UEF': 'ueb0101', 'Cybran': 'urb0101', 'Aeon': 'uab0101', 'Seraphim': 'xsb0101'},
}


# ---- a reader for the blueprint's table syntax ---------------------------------------------------------------------------------------------------------------

class Raw(str):
    """Source text of a value the reader does not interpret (kept for Sound{} calls)."""


class Reader:
    def __init__(self, text):
        self.t = text
        self.i = 0

    def ws(self):
        t = self.t
        while self.i < len(t):
            c = t[self.i]
            if c in ' \t\r\n﻿':
                self.i += 1
            elif t.startswith('--', self.i):
                if t.startswith('--[[', self.i):
                    self.i = t.index(']]', self.i) + 2
                else:
                    j = t.find('\n', self.i)
                    self.i = len(t) if j < 0 else j
            else:
                break

    def value(self):
        self.ws()
        t = self.t
        c = t[self.i]
        if c == '{':
            return self.table()
        if c in '"\'':
            return self.string()
        m = re.compile(r'-?\d+\.?\d*(?:[eE][-+]?\d+)?').match(t, self.i)
        if m:
            self.i = m.end()
            v = float(m.group()) if ('.' in m.group() or 'e' in m.group().lower()) else int(m.group())
            self.ws()
            if t.startswith('/', self.i):                      # 10/3
                self.i += 1
                d = self.value()
                v = v / d
            return v
        m = re.compile(r'[A-Za-z_][A-Za-z_0-9.]*').match(t, self.i)
        if not m:
            raise ValueError('cannot read at %d: %r' % (self.i, t[self.i:self.i + 40]))
        word = m.group()
        self.i = m.end()
        if word == 'true':
            return True
        if word == 'false':
            return False
        if word == 'nil':
            return None
        self.ws()
        if t[self.i] == '{':                                    # Sound { ... }, Vector3 { ... }
            start = self.i
            tbl = self.table()
            if word == 'Sound':
                return tbl                                  # a plain table here; the wizard writes it back as Sound { ... }
            return Raw(word + ' ' + t[start:self.i])
        if t[self.i] == '(':
            depth = 0
            start = self.i
            while True:
                if t[self.i] == '(':
                    depth += 1
                elif t[self.i] == ')':
                    depth -= 1
                    if depth == 0:
                        self.i += 1
                        break
                self.i += 1
            return Raw(word + t[start:self.i])
        return Raw(word)

    def string(self):
        q = self.t[self.i]
        j = self.i + 1
        out = []
        while self.t[j] != q:
            if self.t[j] == '\\':
                j += 1
            out.append(self.t[j])
            j += 1
        self.i = j + 1
        return ''.join(out)

    def table(self):
        self.i += 1
        d, arr = {}, []
        while True:
            self.ws()
            if self.t[self.i] == '}':
                self.i += 1
                break
            m = re.compile(r'([A-Za-z_][A-Za-z_0-9]*)\s*=(?!=)').match(self.t, self.i)
            if m:
                self.i = m.end()
                d[m.group(1)] = self.value()
            elif self.t[self.i] == '[':
                j = self.t.index(']', self.i)
                key = self.t[self.i + 1:j].strip().strip('"\'')
                self.i = j + 1
                self.ws()
                assert self.t[self.i] == '='
                self.i += 1
                d[key] = self.value()
            else:
                arr.append(self.value())
            self.ws()
            if self.t[self.i] in ',;':
                self.i += 1
        if arr and not d:
            return arr
        if arr:
            d['_array'] = arr
        return d


def read_bp(uid):
    path = os.path.join(FAF_UNITS, uid.upper(), uid.upper() + '_unit.bp')
    text = open(path, encoding='utf-8-sig', errors='replace').read()
    r = Reader(text)
    r.ws()
    m = re.compile(r'UnitBlueprint\s*').match(text, r.i)
    r.i = m.end()
    return r.value()


# ---- Lua output --------------------------------------------------------------------------------------------------------------------------------------------------

def lua(v, indent=''):
    if isinstance(v, Raw):
        return str(v)
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return ('%.7g' % v)
    if isinstance(v, str):
        return "'" + v.replace('\\', '\\\\').replace("'", "\\'") + "'"
    if isinstance(v, list):
        return '{ ' + ', '.join(lua(x, indent) for x in v) + ' }'
    if isinstance(v, dict):
        items = []
        for k in sorted(v):
            if v[k] is None:
                continue
            key =k if re.match(r'^[A-Za-z_][A-Za-z_0-9]*$', k) else "['%s']" % k
            items.append('%s = %s' % (key, lua(v[k], indent + '    ')))
        return '{ ' + ', '.join(items) + ' }'
    raise TypeError(type(v))


def pick(bp, *path):
    node = bp
    for p in path:
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node


def clean(v):
    """A copy of a parsed table without anything the reader kept as source text (calls, names)."""
    if isinstance(v, Raw):
        return None
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            c = clean(x)
            if c is not None:
                out[k] = c
        return out
    if isinstance(v, list):
        return [c for c in (clean(x) for x in v) if c is not None]
    return v


def donor_entry(template, faction, uid):
    bp = read_bp(uid)
    info = scm_dump.parse(scm_dump.read_scm(uid))
    e = {'template': template, 'faction': faction}
    e['vertices'] = info['vertices']
    e['triangles'] = info['indices'] // 3
    e['bounds'] = [round(x, 3) for x in info['bounds']]
    bones = []
    for b in info['bones']:
        rest = b['rest']
        # row 4 is the translation, column 4 is 0,0,0,1: 12 numbers carry everything
        bones.append([b['name'], b['parent']] + [float('%.7g' % x) for x in (rest[0], rest[1], rest[2], rest[4], rest[5], rest[6], rest[8], rest[9], rest[10], rest[12], rest[13], rest[14])]
                     + [float('%.7g' % x) for x in b['pos']] + [float('%.7g' % x) for x in b['rot']])
    e['bones'] = bones
    audio = pick(bp, 'Audio') or {}
    e['audio'] = {k: v for k, v in audio.items()}
    disp = pick(bp, 'Display') or {}
    for k in ('AnimationWalk', 'AnimationWalkRate', 'UniformScale'):
        if k in disp:
            e[k[0].lower() + k[1:]] = disp[k]
    death = disp.get('AnimationDeath')
    if isinstance(death, list):
        e['death'] = [d['Animation'] for d in death if isinstance(d, dict) and 'Animation' in d]
    for k in ('Animation', 'AnimationActivate', 'AnimationOpen', 'AnimationBuild', 'AnimationIdle', 'AnimationLand', 'AnimationTakeOff'):
        if k in disp and isinstance(disp[k], str):
            e[k[0].lower() + k[1:]] = disp[k]
    phys = pick(bp, 'Physics') or {}
    e['physics'] = clean(phys)
    e['air'] = clean(bp.get('Air') or {})
    e['general'] = {k: v for k, v in clean(bp.get('General') or {}).items() if k not in ('UnitName', 'FactionName', 'UpgradesFrom', 'UpgradesTo', 'UpgradesFromBase', 'CommandCaps', 'Icon')}
    e['transport'] = clean(bp.get('Transport') or {})
    e['footprint'] = clean(bp.get('Footprint') or {})
    lods = (disp.get('Mesh') or {}).get('LODs') or []
    e['shader'] = lods[0].get('ShaderName') if lods and isinstance(lods[0], dict) else None
    e['lodCutoffs'] = [l.get('LODCutoff') for l in lods if isinstance(l, dict)]
    e['iconFadeInZoom'] = (disp.get('Mesh') or {}).get('IconFadeInZoom')
    fp = phys.get('SkirtSizeX') is not None
    for k in ('SizeX', 'SizeY', 'SizeZ', 'SelectionSizeX', 'SelectionSizeZ', 'SelectionThickness', 'SelectionMeshScaleY', 'LifeBarHeight', 'LifeBarOffset', 'LifeBarSize', 'AverageDensity', 'StrategicIconName', 'StrategicIconSortPriority', 'BuildIconSortPriority'):
        if k in bp:
            e[k[0].lower() + k[1:]] = bp[k]
    gen = pick(bp, 'General') or {}
    e['icon'] = gen.get('Icon')
    e['commandCaps'] = sorted(k for k, v in (gen.get('CommandCaps') or {}).items() if v)
    e['categories'] = bp.get('Categories') or []
    e['intel'] = {k: v for k, v in (bp.get('Intel') or {}).items() if isinstance(v, (int, float))}
    e['defense'] = {k: v for k, v in (bp.get('Defense') or {}).items() if isinstance(v, (int, float, str))}
    e['veteran'] = bp.get('Veteran')
    e['wreckage'] = {k: v for k, v in (bp.get('Wreckage') or {}).items() if isinstance(v, (int, float, str))}
    e['wreckLayers'] = sorted((pick(bp, 'Wreckage', 'WreckageLayers') or {}).keys())
    weapons = [w for w in (bp.get('Weapon') or []) if isinstance(w, dict) and not w.get('DummyWeapon')]
    if weapons:
        w = weapons[0]
        racks = []
        for rack in w.get('RackBones') or []:
            if isinstance(rack, dict):
                racks.append({'RackBone': rack.get('RackBone'), 'MuzzleBones': rack.get('MuzzleBones')})
        e['weapon'] = {
            'yaw': w.get('TurretBoneYaw'), 'pitch': w.get('TurretBonePitch'), 'muzzle': w.get('TurretBoneMuzzle'),
            'turreted': w.get('Turreted'), 'racks': racks, 'class': w.get('Label'), 'rangeCategory': w.get('RangeCategory'),
            'weaponCategory': w.get('WeaponCategory'), 'projectile': w.get('ProjectileId'), 'damage': w.get('Damage'),
            'maxRadius': w.get('MaxRadius'), 'rateOfFire': w.get('RateOfFire'), 'muzzleVelocity': w.get('MuzzleVelocity'),
            'ballisticArc': w.get('BallisticArc'), 'turretYawRange': w.get('TurretYawRange'), 'turretYawSpeed': w.get('TurretYawSpeed'),
            'turretPitchRange': w.get('TurretPitchRange'), 'turretPitchSpeed': w.get('TurretPitchSpeed'), 'turretPitch': w.get('TurretPitch'),
            'fireAudio': pick(w, 'Audio', 'Fire'), 'fireTargetLayerCapsTable': w.get('FireTargetLayerCapsTable'),
        }
    econ = pick(bp, 'Economy') or {}
    e['economy'] = {k: v for k, v in econ.items() if isinstance(v, (int, float))}
    e['buildableCategory'] = econ.get('BuildableCategory')
    return e


WEAPON_DONORS = {
    # kind: (WeaponCategory to look for, {faction: donor unit})
    'direct': ('Direct Fire', DONORS['bot']),
    'cannon': ('Direct Fire', DONORS['tank']),
    'artillery': ('Artillery', {'UEF': 'uel0103', 'Cybran': 'url0103', 'Aeon': 'ual0103', 'Seraphim': 'xsl0103'}),
    'aa': ('Anti Air', {'UEF': 'uel0104', 'Cybran': 'url0104', 'Aeon': 'ual0104', 'Seraphim': 'xsl0104'}),
    'missile': ('Missile', {'UEF': 'uel0111', 'Cybran': 'url0111', 'Aeon': 'ual0111', 'Seraphim': 'xsl0111'}),
    'torpedo': ('Anti Navy', {'UEF': 'ues0203', 'Cybran': 'urs0203', 'Aeon': 'uas0203', 'Seraphim': 'xss0203'}),
    'bomb': ('Bomb', {'UEF': 'uea0103', 'Cybran': 'ura0103', 'Aeon': 'uaa0103', 'Seraphim': 'xsa0103'}),
}

UNIT_CLASSES = {
    # template: {faction: unit base class}; modules are <faction>units.lua
    'bot': {'UEF': 'TWalkingLandUnit', 'Cybran': 'CWalkingLandUnit', 'Aeon': 'AWalkingLandUnit', 'Seraphim': 'SWalkingLandUnit'},
    'tank': {'UEF': 'TLandUnit', 'Cybran': 'CLandUnit', 'Aeon': 'ALandUnit', 'Seraphim': 'SLandUnit'},
    'hover': {'UEF': 'THoverLandUnit', 'Cybran': 'CLandUnit', 'Aeon': 'AHoverLandUnit', 'Seraphim': 'SHoverLandUnit'},
    'naval': {'UEF': 'TSeaUnit', 'Cybran': 'CSeaUnit', 'Aeon': 'ASeaUnit', 'Seraphim': 'SSeaUnit'},
    'air': {'UEF': 'TAirUnit', 'Cybran': 'CAirUnit', 'Aeon': 'AAirUnit', 'Seraphim': 'SAirUnit'},
    'defence': {'UEF': 'TStructureUnit', 'Cybran': 'CStructureUnit', 'Aeon': 'AStructureUnit', 'Seraphim': 'SStructureUnit'},
    'economy': {'UEF': 'TEnergyCreationUnit', 'Cybran': 'CEnergyCreationUnit', 'Aeon': 'AEnergyCreationUnit', 'Seraphim': 'SEnergyCreationUnit'},
    'engineer': {'UEF': 'TConstructionUnit', 'Cybran': 'CConstructionUnit', 'Aeon': 'AConstructionUnit', 'Seraphim': 'SConstructionUnit'},
    'factory': {'UEF': 'TLandFactoryUnit', 'Cybran': 'CLandFactoryUnit', 'Aeon': 'ALandFactoryUnit', 'Seraphim': 'SLandFactoryUnit'},
}
MODULES = {'UEF': ('terranunits', 'terranweapons'), 'Cybran': ('cybranunits', 'cybranweapons'), 'Aeon': ('aeonunits', 'aeonweapons'), 'Seraphim': ('seraphimunits', 'seraphimweapons')}


def script_weapon_class(uid, label):
    """The class a donor's weapon script derives from: ClassWeapon(X) { ... } for the weapon with this label."""
    path = os.path.join(FAF_UNITS, uid.upper(), uid.upper() + '_Script.lua')
    text = open(path, encoding='utf-8-sig', errors='replace').read()
    m = re.search(r'(?<![A-Za-z_0-9])' + re.escape(label) + r'\s*=\s*ClassWeapon\(\s*([A-Za-z_0-9]+)', text)
    return m.group(1) if m else None


def weapon_kind(kind, faction, uid, category):
    bp = read_bp(uid)
    weapons = [w for w in (bp.get('Weapon') or []) if isinstance(w, dict) and not w.get('DummyWeapon')]
    pick_w = None
    for w in weapons:
        if w.get('WeaponCategory') == category:
            pick_w = w
            break
    if pick_w is None and weapons:
        pick_w = weapons[0]
    if pick_w is None:
        return None
    out = {}
    for k, v in pick_w.items():
        if k in ('Label', 'DisplayName', 'RackBones', 'TurretBoneYaw', 'TurretBonePitch', 'TurretBoneMuzzle', 'TurretBoneDualMuzzle', 'TurretBoneDualPitch', 'MuzzleSpecial', 'RackBones', 'DummyWeapon', 'FxMuzzleFlash', 'FxRackChargeMuzzleFlash', 'TurretDualManipulators'):
            continue
        if isinstance(v, Raw):
            continue
        out[k] = v
    out['_from'] = '%s:%s' % (uid, pick_w.get('Label'))
    cls = script_weapon_class(uid, pick_w.get('Label') or '')
    if cls:
        out['_class'] = cls
    return out


def main(argv):
    out = OUT
    if '--out' in argv:
        out = argv[argv.index('--out') + 1]
    lines = [
        '-- GENERATED by scripts/unitwiz_data.py from the vanilla units named below: skeletons (bone name, parent, 12 numbers of the inverse bind pose, position, rotation w x y z), sound sets, animation paths,',
        '-- weapon bones and template numbers. The unit wizard (unitwiz.lua) takes pieces of these by reference; it never copies a blueprint. Do not edit by hand.',
        '',
        'Donors = {',
    ]
    for template, byFaction in DONORS.items():
        for faction, uid in byFaction.items():
            e = donor_entry(template, faction, uid)
            lines.append('    %s = %s,' % (uid, lua(e)))
    lines.append('}')
    lines.append('')
    lines.append('Map = {')
    for template, byFaction in DONORS.items():
        lines.append('    %s = { %s },' % (template, ', '.join("%s = '%s'" % (f, u) for f, u in byFaction.items())))
    lines.append('}')
    lines.append('')
    lines.append("-- weapon fields by kind and faction (what a weapon needs; bones, label and display name are the unit's own); _class = the weapon script class, _from = the vanilla weapon it was read from")
    lines.append('Weapons = {')
    for kind, (category, byFaction) in WEAPON_DONORS.items():
        lines.append('    %s = {' % kind)
        for faction, uid in byFaction.items():
            w = weapon_kind(kind, faction, uid, category)
            if w:
                lines.append('        %s = %s,' % (faction, lua(w)))
        lines.append('    },')
    lines.append('}')
    lines.append('')
    lines.append('-- unit script base classes: template -> faction -> class; the module is Modules[faction][1], weapon classes come from Modules[faction][2]')
    lines.append('Classes = %s' % lua(UNIT_CLASSES))
    lines.append('Modules = %s' % lua({k: list(v) for k, v in MODULES.items()}))
    text = '\n'.join(lines) + '\n'
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('wrote %s (%d bytes, %d donors)' % (out, len(text), sum(len(v) for v in DONORS.values())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
