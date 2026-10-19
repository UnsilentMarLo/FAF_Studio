"""Full-fidelity reader and writer for Forged Alliance `.scmap` files (version 2, minor 53-60).

Every section is parsed into fields so an edited map loses nothing (decals, decal groups, wave generators, sky box,
cartographic colours...). `write(read(x))` reproduces the input byte for byte; tests/test_scmap_roundtrip.py checks it.

Layout after Neroxis-Map-Generator's SCMapImporter / SCMapExporter (faf_repo/Neroxis-Map-Generator), little endian:
    header     i32 'Map\\x1a', i32 2, i32 0xBEEFFEED, i32 2, f32 width, f32 height, i32 0, i16 0
    preview    i32 byte count + DDS file (128-byte header + ARGB pixels)
    heights    i32 minor, i32 width, i32 height, f32 scale (1/128), (w+1)*(h+1) u16, u8 0
    strings    shader, background, sky cube (zero terminated), i32 n + n * (name, path) cube maps
    lighting   f32 multiplier, sun dir(3), ambience(3), sun colour(3), shadow fill(3), specular(4), bloom, fog(3), start, end
    water      u8 present, 23 f32, cube map, ramp, 4 f32 repeats, 4 * (f32 x2 movement, texture)
    waves      i32 n + n * (texture, ramp, pos(3), rot, vel(3), 10 f32)
    carto      6 i32 (minor > 56: + f32)
    strata     10 * (albedo path, f32 scale), 9 * (normal path, f32 scale); then 2 unknown i32
    decals     i32 n + n * (id, type, nTex, nTex * (i32 len + chars), scale(3), pos(3), rot(3), cutoff, near, owner)
               i32 n + n groups (id, name, i32 n, n ids)
    normals    i32 width, i32 height, i32 1 (count), i32 bytes + DDS (DXT5)
    masks      2 * (i32 bytes + DDS ARGB): strata 1-4 (R,G,B,A) and 5-8
    water maps i32 1, i32 bytes + DDS (DXT5), 3 * (w/2 * h/2 bytes): foam, flatness, depth bias
    terrain    w * h bytes terrain type
    sky box    only minor >= 60
    props      i32 n + n * (path, pos(3), rotX(3), rotY(3), rotZ(3), scale(3))
"""
import array
import struct
import sys

SIGNATURE = 0x1A70614D  # 'Map\x1a'
MAGIC2 = -1091567891    # 0xBEEFFEED
DDS_MAGIC = b"DDS "

LIGHTING_FIELDS = ("multiplier", "sun_direction", "ambience", "sun_color", "shadow_fill", "specular", "bloom",
                   "fog_color", "fog_start", "fog_end")
WATER_SCALARS = ("elevation", "elevation_deep", "elevation_abyss", "surface_color", "color_lerp", "refraction_scale",
                 "fresnel_bias", "fresnel_power", "unit_reflection", "sky_reflection", "sun_shininess", "sun_strength",
                 "sun_direction", "sun_color", "sun_reflection", "sun_glow")
SCALE_STEP = 1.0 / 128.0


class Reader:
    def __init__(self, data):
        self.d, self.o = data, 0

    def take(self, n):
        b = self.d[self.o:self.o + n]
        if len(b) != n:
            raise ValueError(f"file ends at {self.o} (wanted {n} bytes)")
        self.o += n
        return bytes(b)

    def unpack(self, fmt):
        v = struct.unpack_from("<" + fmt, self.d, self.o)
        self.o += struct.calcsize("<" + fmt)
        return v[0] if len(fmt) == 1 else v

    def floats(self, n):
        return list(self.unpack(f"{n}f"))

    def cstring(self):
        end = self.d.index(b"\0", self.o)
        s = self.d[self.o:end].decode("latin-1")
        self.o = end + 1
        return s

    def blob(self):
        return self.take(self.unpack("i"))

    def at_end(self):
        return self.o >= len(self.d)


class Writer:
    def __init__(self):
        self.parts = []

    def pack(self, fmt, *v):
        self.parts.append(struct.pack("<" + fmt, *v))

    def floats(self, v):
        self.parts.append(struct.pack(f"<{len(v)}f", *v))

    def cstring(self, s):
        self.parts.append(s.encode("latin-1") + b"\0")

    def blob(self, b):
        self.parts.append(struct.pack("<i", len(b)))
        self.parts.append(b)

    def raw(self, b):
        self.parts.append(bytes(b))

    def getvalue(self):
        return b"".join(self.parts)


# ---------------------------------------------------------------------------------------------------------------------
# DDS helpers (only what maps use: ARGB8 and DXT5)

def dds_info(blob):
    """(width, height, fourcc or None, header size) of a DDS file."""
    if blob[:4] != DDS_MAGIC:
        raise ValueError("not a DDS file")
    height, width = struct.unpack_from("<II", blob, 12)
    fourcc = blob[84:88]
    return width, height, (fourcc.decode("latin-1") if fourcc != b"\0\0\0\0" else None), 128


def dds_header(width, height, fourcc=None):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | (0x80000 if fourcc else 0x8)
    pitch = max(1, (width + 3) // 4) * max(1, (height + 3) // 4) * 16 if fourcc else width * 4
    head = struct.pack("<4s7I44x", DDS_MAGIC, 124, flags, height, width, pitch, 0, 0)
    if fourcc:
        pf = struct.pack("<2I4s5I", 32, 0x4, fourcc.encode(), 0, 0, 0, 0, 0)
    else:
        pf = struct.pack("<2I4s5I", 32, 0x41, b"\0\0\0\0", 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    return head + pf + struct.pack("<5I", 0x1000, 0, 0, 0, 0)


def argb_image(width, height, pixels=None, fill=0):
    """Uncompressed DDS; pixels is width*height*4 bytes in B,G,R,A order, or one fill value 0xAARRGGBB."""
    if pixels is None:
        pixels = struct.pack("<I", fill & 0xFFFFFFFF) * (width * height)
    return dds_header(width, height) + bytes(pixels)


def dxt5_flat(width, height, r, g, b, a):
    c565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    block = struct.pack("<BB6xHH4x", a, a, c565, c565)
    return dds_header(width, height, "DXT5") + block * (max(1, (width + 3) // 4) * max(1, (height + 3) // 4))


# ---------------------------------------------------------------------------------------------------------------------

class Decal:
    __slots__ = ("id", "type", "textures", "scale", "position", "rotation", "cutoff", "near_cutoff", "owner")

    def to_json(self):
        return {k: getattr(self, k) for k in self.__slots__}


class ScMap:
    def __init__(self, width=256, height=256):
        self.minor = 56
        self.width, self.height = width, height
        self.preview = argb_image(256, 256, fill=0xFF404040)
        self.height_scale = SCALE_STEP
        self.heights = array.array("H", [0]) * ((width + 1) * (height + 1))   # (w+1)*(h+1), row major
        self.shader = "TTerrain"
        self.background = "/textures/environment/defaultbackground.dds"
        self.skycube = "/textures/environment/defaultskycube.dds"
        self.cubemaps = []                         # [(name, path)]
        self.lighting = {"multiplier": 1.5, "sun_direction": [0.4, 0.8, -0.4], "ambience": [0.3, 0.3, 0.3],
                         "sun_color": [1.0, 1.0, 1.0], "shadow_fill": [0.7, 0.7, 0.7], "specular": [0, 0, 0, 0],
                         "bloom": 0.1, "fog_color": [0.8, 0.8, 0.8], "fog_start": 1000.0, "fog_end": 2000.0}
        self.water = {"present": False, "elevation": 25.0, "elevation_deep": 20.0, "elevation_abyss": 10.0,
                      "surface_color": [0.0, 0.7, 1.5], "color_lerp": [0.64, 0.8], "refraction_scale": 0.375,
                      "fresnel_bias": 0.15, "fresnel_power": 1.5, "unit_reflection": 0.5, "sky_reflection": 1.5,
                      "sun_shininess": 50.0, "sun_strength": 10.0, "sun_direction": [0.0, -1.0, 0.0],
                      "sun_color": [1.0, 0.96, 0.7], "sun_reflection": 5.0, "sun_glow": 0.1,
                      "cubemap": "/textures/environment/FullCubeMap.dds",
                      "ramp": "/textures/engine/waterramp.dds",
                      "waves": [{"repeat": r, "movement": m, "texture": t} for r, m, t in (
                          (0.009, [0.5, -0.95], "/textures/engine/waves.dds"),
                          (0.009, [0.5, 0.95], "/textures/engine/waves.dds"),
                          (0.05, [0.0, 0.0], "/textures/engine/waves.dds"),
                          (0.01, [0.0, 0.0], "/textures/engine/waves.dds"))]}
        self.wave_generators = []                  # dicts
        self.carto = {"contour_interval": 24, "deep_water": 0xFF000000, "contour": 0xFF000000, "shore": 0xFF000000,
                      "land_start": 0xFF000000, "land_end": 0xFF000000, "extra": 0.0}
        self.strata = [("", 4.0)] * 10             # albedo path, scale
        self.strata_normals = [("", 4.0)] * 9      # normal path, scale
        self.unknown_after_strata = (0, 0)
        self.legacy = None                         # minor < 56 extras: tileset, count, layer 9 normal
        self.extra_normal_maps = []                # huge maps may carry more than one normal map
        self.size2 = None                          # the second width/height pair: normal map size on big maps
        self.decals = []
        self.decal_groups = []                     # dicts {id, name, ids}
        self.normal_map = dxt5_flat(width, height, 0, 128, 0, 128)
        self.mask_low = argb_image(width // 2, height // 2, fill=0)
        self.mask_high = argb_image(width // 2, height // 2, fill=0)
        self.water_map = dxt5_flat(width // 2, height // 2, 0, 0, 0, 0)
        half = (width // 2) * (height // 2)
        self.foam = bytearray(half)
        self.flatness = bytearray(b"\xff" * half)
        self.depth_bias = bytearray(b"\x7f" * half)
        self.terrain_type = bytearray(width * height)
        self.skybox = None                         # dict, only written for minor >= 60
        self.props = []                            # dicts {path, position, rot_x, rot_y, rot_z, scale}
        self.trailing = b""
        self.header_width = float(width)
        self.header_height = float(height)

    # -- reading -------------------------------------------------------------------------------------------------------
    @classmethod
    def read(cls, path):
        with open(path, "rb") as fh:
            return cls.parse(fh.read())

    @classmethod
    def parse(cls, data):
        if len(data) < 64:
            raise ValueError(f"stub .scmap of {len(data)} bytes (the map data lives elsewhere, e.g. a campaign base map)")
        r = Reader(data)
        m = cls(0, 0)
        sig, major, magic2, two, m.header_width, m.header_height, zero, zero2 = r.unpack("iiiiffih")
        if sig != SIGNATURE or major != 2:
            raise ValueError("not a version 2 .scmap")
        m.preview = r.blob()
        m.minor, m.width, m.height, m.height_scale = r.unpack("iiif")
        if not 53 <= m.minor <= 60:
            raise ValueError(f"minor version {m.minor} is not supported (53-60)")
        n = (m.width + 1) * (m.height + 1)
        m.heights = array.array("H")
        m.heights.frombytes(r.take(n * 2))
        if m.minor >= 56:
            r.take(1)
        m.shader, m.background, m.skycube = r.cstring(), r.cstring(), r.cstring()
        if m.minor >= 56:
            m.cubemaps = [(r.cstring(), r.cstring()) for _ in range(r.unpack("i"))]
        else:
            m.cubemaps = [("<default>", r.cstring())]
        v = r.floats(23)
        m.lighting = {"multiplier": v[0], "sun_direction": v[1:4], "ambience": v[4:7], "sun_color": v[7:10],
                      "shadow_fill": v[10:13], "specular": v[13:17], "bloom": v[17], "fog_color": v[18:21],
                      "fog_start": v[21], "fog_end": v[22]}
        present = r.unpack("B")
        v = r.floats(23)
        w = {"present": bool(present), "elevation": v[0], "elevation_deep": v[1], "elevation_abyss": v[2],
             "surface_color": v[3:6], "color_lerp": v[6:8], "refraction_scale": v[8], "fresnel_bias": v[9],
             "fresnel_power": v[10], "unit_reflection": v[11], "sky_reflection": v[12], "sun_shininess": v[13],
             "sun_strength": v[14], "sun_direction": v[15:18], "sun_color": v[18:21], "sun_reflection": v[21],
             "sun_glow": v[22]}
        w["cubemap"], w["ramp"] = r.cstring(), r.cstring()
        repeats = r.floats(4)
        w["waves"] = []
        for i in range(4):
            mv = r.floats(2)
            w["waves"].append({"repeat": repeats[i], "movement": mv, "texture": r.cstring()})
        m.water = w
        m.wave_generators = []
        for _ in range(r.unpack("i")):
            g = {"texture": r.cstring(), "ramp": r.cstring()}
            v = r.floats(17)
            g.update(position=v[0:3], rotation=v[3], velocity=v[4:7], life_time=v[7:9], period=v[9:11],
                     scale=v[11:13], frame_count=v[13], frame_rate=v[14:16], strip_count=v[16])
            m.wave_generators.append(g)
        if m.minor >= 56:
            ci = r.unpack("6I")
            m.carto = {"contour_interval": ci[0], "deep_water": ci[1], "contour": ci[2], "shore": ci[3],
                       "land_start": ci[4], "land_end": ci[5], "extra": r.unpack("f") if m.minor > 56 else None}
            m.strata = [(r.cstring(), r.unpack("f")) for _ in range(10)]
            m.strata_normals = [(r.cstring(), r.unpack("f")) for _ in range(9)]
        else:
            # original game maps: tileset name, layer count, then 6 layers (0-4 and the upper one) with both textures
            tileset, count = r.cstring(), r.unpack("i")
            m.strata = [("", 4.0)] * 10
            m.strata_normals = [("", 4.0)] * 9
            slots = (0, 1, 2, 3, 4, 9)
            extra_normal = ("", 4.0)
            for slot in slots[:count]:
                albedo, normal = r.cstring(), r.cstring()
                sa, sn = r.unpack("ff")
                m.strata[slot] = (albedo, sa)
                if slot < 9:
                    m.strata_normals[slot] = (normal, sn)
                else:
                    extra_normal = (normal, sn)
            m.legacy = {"tileset": tileset, "count": count, "layer9_normal": extra_normal}
            m.carto = {"contour_interval": 24, "deep_water": 0xFF000000, "contour": 0xFF000000, "shore": 0xFF000000,
                       "land_start": 0xFF000000, "land_end": 0xFF000000, "extra": None}
        m.unknown_after_strata = tuple(r.unpack("ii"))
        m.decals = []
        for _ in range(r.unpack("i")):
            d = Decal()
            d.id, d.type, nt = r.unpack("iii")
            d.textures = []
            for _ in range(nt):
                d.textures.append(r.take(r.unpack("i")).decode("latin-1"))
            v = r.floats(9)
            d.scale, d.position, d.rotation = v[0:3], v[3:6], v[6:9]
            d.cutoff, d.near_cutoff, d.owner = r.unpack("ffi")
            m.decals.append(d)
        m.decal_groups = []
        for _ in range(r.unpack("i")):
            gid = r.unpack("i")
            name = r.cstring()
            cnt = r.unpack("i")
            m.decal_groups.append({"id": gid, "name": name, "ids": list(r.unpack(f"{cnt}i")) if cnt else []})
        m.size2 = tuple(r.unpack("ii"))
        nn = r.unpack("i")
        if nn < 1:
            raise ValueError("no normal map")
        m.normal_map = r.blob()
        m.extra_normal_maps = [r.blob() for _ in range(nn - 1)]
        if m.minor >= 56:
            m.mask_low, m.mask_high = r.blob(), r.blob()
        else:
            r.unpack("i")                           # always 1
            m.mask_low = r.blob()
            m.mask_high = None
        r.unpack("i")                               # water map count, always 1
        m.water_map = r.blob()
        half = (m.width // 2) * (m.height // 2)
        m.foam, m.flatness, m.depth_bias = bytearray(r.take(half)), bytearray(r.take(half)), bytearray(r.take(half))
        m.terrain_type = bytearray(r.take(m.width * m.height))
        if m.minor >= 60:
            m.skybox = cls._read_skybox(r)
        m.props = []
        for _ in range(r.unpack("i")):
            p = {"path": r.cstring()}
            v = r.floats(15)
            p.update(position=v[0:3], rot_x=v[3:6], rot_y=v[6:9], rot_z=v[9:12], scale=v[12:15])
            m.props.append(p)
        m.trailing = r.d[r.o:]
        return m

    @staticmethod
    def _read_skybox(r):
        v = r.floats(3)
        s = {"position": v}
        s["horizon_height"], s["scale"], s["sub_height"] = r.floats(3)
        s["sub_div_ax"], s["sub_div_height"] = r.unpack("ii")
        s["zenith_height"] = r.unpack("f")
        s["horizon_color"], s["zenith_color"] = r.floats(3), r.floats(3)
        s["decal_glow"] = r.unpack("f")
        s["albedo"], s["glow"] = r.cstring(), r.cstring()
        s["planets"] = []
        for _ in range(r.unpack("i")):
            v = r.floats(10)
            s["planets"].append({"position": v[0:3], "rotation": v[3], "scale": v[4:6], "uv": v[6:10]})
        s["mid_color"] = list(r.unpack("3B"))
        s["cirrus_multiplier"] = r.unpack("f")
        s["cirrus_color"] = r.floats(3)
        s["cirrus_texture"] = r.cstring()
        s["cirrus_layers"] = []
        for _ in range(r.unpack("i")):
            v = r.floats(5)
            s["cirrus_layers"].append({"frequency": v[0:2], "speed": v[2], "direction": v[3:5]})
        s["clouds7"] = r.unpack("f")
        return s

    # -- writing -------------------------------------------------------------------------------------------------------
    def to_bytes(self):
        w = Writer()
        w.pack("iiiiffih", SIGNATURE, 2, MAGIC2, 2, self.header_width, self.header_height, 0, 0)
        w.blob(self.preview)
        w.pack("iiif", self.minor, self.width, self.height, self.height_scale)
        if len(self.heights) != (self.width + 1) * (self.height + 1):
            raise ValueError("height array does not match the map size")
        w.raw(self.heights.tobytes())
        if self.minor >= 56:
            w.raw(b"\0")
        for s in (self.shader, self.background, self.skycube):
            w.cstring(s)
        if self.minor >= 56:
            w.pack("i", len(self.cubemaps))
            for name, p in self.cubemaps:
                w.cstring(name)
                w.cstring(p)
        else:
            w.cstring(self.cubemaps[0][1] if self.cubemaps else "")
        L = self.lighting
        w.floats([L["multiplier"], *L["sun_direction"], *L["ambience"], *L["sun_color"], *L["shadow_fill"],
                  *L["specular"], L["bloom"], *L["fog_color"], L["fog_start"], L["fog_end"]])
        W = self.water
        w.pack("B", 1 if W["present"] else 0)
        w.floats([W["elevation"], W["elevation_deep"], W["elevation_abyss"], *W["surface_color"], *W["color_lerp"],
                  W["refraction_scale"], W["fresnel_bias"], W["fresnel_power"], W["unit_reflection"],
                  W["sky_reflection"], W["sun_shininess"], W["sun_strength"], *W["sun_direction"], *W["sun_color"],
                  W["sun_reflection"], W["sun_glow"]])
        w.cstring(W["cubemap"])
        w.cstring(W["ramp"])
        w.floats([x["repeat"] for x in W["waves"]])
        for x in W["waves"]:
            w.floats(x["movement"])
            w.cstring(x["texture"])
        w.pack("i", len(self.wave_generators))
        for g in self.wave_generators:
            w.cstring(g["texture"])
            w.cstring(g["ramp"])
            w.floats([*g["position"], g["rotation"], *g["velocity"], *g["life_time"], *g["period"], *g["scale"],
                      g["frame_count"], *g["frame_rate"], g["strip_count"]])
        c = self.carto
        if self.minor >= 56:
            w.pack("6I", c["contour_interval"], c["deep_water"], c["contour"], c["shore"], c["land_start"],
                   c["land_end"])
            if self.minor > 56:
                w.pack("f", c["extra"] if c.get("extra") is not None else 0.0)
            for path, scale in self.strata:
                w.cstring(path)
                w.pack("f", scale)
            for path, scale in self.strata_normals:
                w.cstring(path)
                w.pack("f", scale)
        else:
            lg = self.legacy or {"tileset": "No Tileset", "count": 6, "layer9_normal": ("", 4.0)}
            w.cstring(lg["tileset"])
            w.pack("i", lg["count"])
            for slot in (0, 1, 2, 3, 4, 9)[:lg["count"]]:
                w.cstring(self.strata[slot][0])
                normal = self.strata_normals[slot] if slot < 9 else lg["layer9_normal"]
                w.cstring(normal[0])
                w.pack("ff", self.strata[slot][1], normal[1])
        w.pack("ii", *self.unknown_after_strata)
        w.pack("i", len(self.decals))
        for d in self.decals:
            w.pack("iii", d.id, d.type, len(d.textures))
            for t in d.textures:
                tb = t.encode("latin-1")
                w.pack("i", len(tb))
                w.raw(tb)
            w.floats([*d.scale, *d.position, *d.rotation])
            w.pack("ffi", d.cutoff, d.near_cutoff, d.owner)
        w.pack("i", len(self.decal_groups))
        for g in self.decal_groups:
            w.pack("i", g["id"])
            w.cstring(g["name"])
            w.pack("i", len(g["ids"]))
            if g["ids"]:
                w.pack(f"{len(g['ids'])}i", *g["ids"])
        w.pack("iii", *(self.size2 or (self.width, self.height)), 1 + len(self.extra_normal_maps))
        w.blob(self.normal_map)
        for nm in self.extra_normal_maps:
            w.blob(nm)
        if self.minor >= 56:
            w.blob(self.mask_low)
            w.blob(self.mask_high if self.mask_high is not None else argb_image(self.width // 2, self.height // 2))
        else:
            w.pack("i", 1)
            w.blob(self.mask_low)
        w.pack("i", 1)
        w.blob(self.water_map)
        half = (self.width // 2) * (self.height // 2)
        for name in ("foam", "flatness", "depth_bias"):
            arr = getattr(self, name)
            if len(arr) != half:
                raise ValueError(f"{name} has {len(arr)} bytes, expected {half}")
            w.raw(arr)
        if len(self.terrain_type) != self.width * self.height:
            raise ValueError("terrain type size mismatch")
        w.raw(self.terrain_type)
        if self.minor >= 60:
            self._write_skybox(w, self.skybox or self.default_skybox())
        w.pack("i", len(self.props))
        for p in self.props:
            w.cstring(p["path"])
            w.floats([*p["position"], *p["rot_x"], *p["rot_y"], *p["rot_z"], *p["scale"]])
        w.raw(self.trailing)
        return w.getvalue()

    @staticmethod
    def default_skybox():
        return {"position": [0, 0, 0], "horizon_height": -100.0, "scale": 100.0, "sub_height": 20.0,
                "sub_div_ax": 16, "sub_div_height": 6, "zenith_height": 150.0, "horizon_color": [0.6, 0.7, 0.8],
                "zenith_color": [0.2, 0.4, 0.8], "decal_glow": 0.0, "albedo": "", "glow": "", "planets": [],
                "mid_color": [0, 0, 0], "cirrus_multiplier": 1.0, "cirrus_color": [1, 1, 1], "cirrus_texture": "",
                "cirrus_layers": [], "clouds7": 0.0}

    @staticmethod
    def _write_skybox(w, s):
        w.floats(s["position"])
        w.floats([s["horizon_height"], s["scale"], s["sub_height"]])
        w.pack("ii", s["sub_div_ax"], s["sub_div_height"])
        w.pack("f", s["zenith_height"])
        w.floats(s["horizon_color"])
        w.floats(s["zenith_color"])
        w.pack("f", s["decal_glow"])
        w.cstring(s["albedo"])
        w.cstring(s["glow"])
        w.pack("i", len(s["planets"]))
        for p in s["planets"]:
            w.floats([*p["position"], p["rotation"], *p["scale"], *p["uv"]])
        w.pack("3B", *s["mid_color"])
        w.pack("f", s["cirrus_multiplier"])
        w.floats(s["cirrus_color"])
        w.cstring(s["cirrus_texture"])
        w.pack("i", len(s["cirrus_layers"]))
        for c in s["cirrus_layers"]:
            w.floats([*c["frequency"], c["speed"], *c["direction"]])
        w.pack("f", s["clouds7"])

    def write(self, path):
        with open(path, "wb") as fh:
            fh.write(self.to_bytes())

    # -- convenience ---------------------------------------------------------------------------------------------------
    def height_at(self, x, z):
        """World height at grid position (x, z) in map units, nearest sample."""
        ix = min(max(int(round(x)), 0), self.width)
        iz = min(max(int(round(z)), 0), self.height)
        return self.heights[iz * (self.width + 1) + ix] * self.height_scale

    def summary(self):
        hs = self.heights
        return {"minor": self.minor, "size": [self.width, self.height],
                "heights": [min(hs) * self.height_scale, max(hs) * self.height_scale],
                "shader": self.shader, "water": self.water["present"], "waves": len(self.wave_generators),
                "decals": len(self.decals), "props": len(self.props), "skybox": self.skybox is not None,
                "trailing": len(self.trailing)}


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    m = ScMap.read(argv[1])
    print(argv[1], m.summary())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
