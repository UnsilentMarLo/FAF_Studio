// edcore: .scmap reader / writer. Field order follows map_editor/server/scmap.py (verified byte exact on 404 maps).
#include "edcore/scmap.h"

#include <cstdio>
#include <cstring>

namespace ed {

namespace {

struct Reader {
    const uint8_t* d;
    size_t n, o = 0;
    std::string err;

    bool need(size_t k) {
        if (o + k > n) {
            if (err.empty()) err = "file ends at " + std::to_string(o) + " (wanted " + std::to_string(k) + " bytes)";
            return false;
        }
        return true;
    }
    template <class T>
    T get() {
        T v{};
        if (!need(sizeof(T))) { o = n; return v; }
        memcpy(&v, d + o, sizeof(T));
        o += sizeof(T);
        return v;
    }
    void floats(float* out, int count) { for (int i = 0; i < count; ++i) out[i] = get<float>(); }
    std::string cstr() {
        size_t e = o;
        while (e < n && d[e]) ++e;
        if (e >= n) { if (err.empty()) err = "unterminated string at " + std::to_string(o); o = n; return {}; }
        std::string s(reinterpret_cast<const char*>(d + o), e - o);
        o = e + 1;
        return s;
    }
    std::string sized(int32_t len) {
        if (len < 0 || !need(static_cast<size_t>(len))) { o = n; return {}; }
        std::string s(reinterpret_cast<const char*>(d + o), static_cast<size_t>(len));
        o += static_cast<size_t>(len);
        return s;
    }
    std::vector<uint8_t> bytes(size_t k) {
        std::vector<uint8_t> v;
        if (!need(k)) { o = n; return v; }
        v.assign(d + o, d + o + k);
        o += k;
        return v;
    }
    std::vector<uint8_t> blob() {
        const int32_t len = get<int32_t>();
        if (len < 0) { if (err.empty()) err = "negative blob length"; o = n; return {}; }
        return bytes(static_cast<size_t>(len));
    }
    bool ok() const { return err.empty(); }
};

struct Writer {
    std::vector<uint8_t>& v;
    explicit Writer(std::vector<uint8_t>& out) : v(out) {}
    template <class T>
    void put(T x) {
        const size_t at = v.size();
        v.resize(at + sizeof(T));
        memcpy(&v[at], &x, sizeof(T));
    }
    void floats(const float* p, int count) { for (int i = 0; i < count; ++i) put<float>(p[i]); }
    void cstr(const std::string& s) { v.insert(v.end(), s.begin(), s.end()); v.push_back(0); }
    void raw(const void* p, size_t k) {
        const uint8_t* b = static_cast<const uint8_t*>(p);
        v.insert(v.end(), b, b + k);
    }
    void blob(const std::vector<uint8_t>& b) { put<int32_t>(static_cast<int32_t>(b.size())); raw(b.data(), b.size()); }
};

constexpr uint32_t kSignature = 0x1A70614D;   // 'Map\x1a'
constexpr int32_t kMagic2 = -1091567891;      // 0xBEEFFEED

}  // namespace

bool ScMap::parse(const uint8_t* data, size_t size, std::string& error) {
    *this = ScMap();
    if (size < 64) {
        error = "stub .scmap of " + std::to_string(size) + " bytes (the map data lives elsewhere)";
        return false;
    }
    Reader r{data, size};
    const uint32_t sig = r.get<uint32_t>();
    const int32_t major = r.get<int32_t>();
    r.get<int32_t>();           // 0xBEEFFEED
    r.get<int32_t>();           // 2
    headerWidth = r.get<float>();
    headerHeight = r.get<float>();
    r.get<int32_t>();           // 0
    r.get<int16_t>();           // 0
    if (sig != kSignature || major != 2) { error = "not a version 2 .scmap"; return false; }
    preview = r.blob();
    minor = r.get<int32_t>();
    width = r.get<int32_t>();
    height = r.get<int32_t>();
    heightScale = r.get<float>();
    if (!r.ok()) { error = r.err; return false; }
    if (minor < 53 || minor > 60) { error = "minor version " + std::to_string(minor) + " is not supported (53-60)"; return false; }
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) { error = "implausible map size"; return false; }
    {
        const size_t count = static_cast<size_t>(width + 1) * static_cast<size_t>(height + 1);
        if (!r.need(count * 2)) { error = r.err; return false; }
        heights.resize(count);
        memcpy(heights.data(), data + r.o, count * 2);
        r.o += count * 2;
    }
    if (minor >= 56) heightPad = r.get<uint8_t>();
    shader = r.cstr();
    background = r.cstr();
    skycube = r.cstr();
    if (minor >= 56) {
        const int32_t n = r.get<int32_t>();
        for (int32_t i = 0; i < n && r.ok(); ++i) {
            std::string name = r.cstr(), path = r.cstr();
            cubemaps.emplace_back(std::move(name), std::move(path));
        }
    } else {
        cubemaps.emplace_back("<default>", r.cstr());
    }
    lighting.multiplier = r.get<float>();
    r.floats(lighting.sunDirection, 3);
    r.floats(lighting.ambience, 3);
    r.floats(lighting.sunColor, 3);
    r.floats(lighting.shadowFill, 3);
    r.floats(lighting.specular, 4);
    lighting.bloom = r.get<float>();
    r.floats(lighting.fogColor, 3);
    lighting.fogStart = r.get<float>();
    lighting.fogEnd = r.get<float>();
    water.present = r.get<uint8_t>() != 0;
    water.elevation = r.get<float>();
    water.deep = r.get<float>();
    water.abyss = r.get<float>();
    r.floats(water.surfaceColor, 3);
    r.floats(water.colorLerp, 2);
    water.refractionScale = r.get<float>();
    water.fresnelBias = r.get<float>();
    water.fresnelPower = r.get<float>();
    water.unitReflection = r.get<float>();
    water.skyReflection = r.get<float>();
    water.sunShininess = r.get<float>();
    water.sunStrength = r.get<float>();
    r.floats(water.sunDirection, 3);
    r.floats(water.sunColor, 3);
    water.sunReflection = r.get<float>();
    water.sunGlow = r.get<float>();
    water.cubemap = r.cstr();
    water.ramp = r.cstr();
    for (auto& w : water.waves) w.repeat = r.get<float>();
    for (auto& w : water.waves) {
        r.floats(w.movement, 2);
        w.texture = r.cstr();
    }
    {
        const int32_t n = r.get<int32_t>();
        if (n < 0 || n > 100000) { error = "implausible wave generator count"; return false; }
        waveGenerators.resize(static_cast<size_t>(n));
        for (auto& g : waveGenerators) {
            g.texture = r.cstr();
            g.ramp = r.cstr();
            r.floats(g.position, 3);
            g.rotation = r.get<float>();
            r.floats(g.velocity, 3);
            r.floats(g.lifeTime, 2);
            r.floats(g.period, 2);
            r.floats(g.scale, 2);
            g.frameCount = r.get<float>();
            r.floats(g.frameRate, 2);
            g.stripCount = r.get<float>();
        }
    }
    if (minor >= 56) {
        carto.contourInterval = r.get<uint32_t>();
        carto.deepWater = r.get<uint32_t>();
        carto.contour = r.get<uint32_t>();
        carto.shore = r.get<uint32_t>();
        carto.landStart = r.get<uint32_t>();
        carto.landEnd = r.get<uint32_t>();
        if (minor > 56) carto.extra = r.get<float>();
        for (auto& s : strata) { s.path = r.cstr(); s.scale = r.get<float>(); }
        for (auto& s : strataNormals) { s.path = r.cstr(); s.scale = r.get<float>(); }
    } else {
        legacyTileset = r.cstr();
        legacyLayerCount = r.get<int32_t>();
        static const int slots[6] = {0, 1, 2, 3, 4, 9};
        for (int i = 0; i < legacyLayerCount && i < 6 && r.ok(); ++i) {
            const int slot = slots[i];
            std::string albedo = r.cstr(), normal = r.cstr();
            const float sa = r.get<float>(), sn = r.get<float>();
            strata[slot] = {albedo, sa};
            if (slot < 9) strataNormals[slot] = {normal, sn};
            else legacyLayer9Normal = {normal, sn};
        }
    }
    unknownAfterStrata[0] = r.get<int32_t>();
    unknownAfterStrata[1] = r.get<int32_t>();
    {
        const int32_t n = r.get<int32_t>();
        if (n < 0 || n > 10000000) { error = "implausible decal count"; return false; }
        decals.resize(static_cast<size_t>(n));
        for (auto& d : decals) {
            d.id = r.get<int32_t>();
            d.type = r.get<int32_t>();
            const int32_t nt = r.get<int32_t>();
            if (nt < 0 || nt > 64) { error = "implausible decal texture count"; return false; }
            for (int32_t t = 0; t < nt && r.ok(); ++t) d.textures.push_back(r.sized(r.get<int32_t>()));
            r.floats(d.scale, 3);
            r.floats(d.position, 3);
            r.floats(d.rotation, 3);
            d.cutoff = r.get<float>();
            d.nearCutoff = r.get<float>();
            d.owner = r.get<int32_t>();
            if (!r.ok()) break;
        }
    }
    {
        const int32_t n = r.get<int32_t>();
        if (n < 0 || n > 1000000) { error = "implausible decal group count"; return false; }
        decalGroups.resize(static_cast<size_t>(n));
        for (auto& g : decalGroups) {
            g.id = r.get<int32_t>();
            g.name = r.cstr();
            const int32_t c = r.get<int32_t>();
            if (c < 0 || !r.need(static_cast<size_t>(c) * 4)) { if (r.ok()) r.err = "bad decal group"; break; }
            g.ids.resize(static_cast<size_t>(c));
            if (c) memcpy(g.ids.data(), data + r.o, static_cast<size_t>(c) * 4);
            r.o += static_cast<size_t>(c) * 4;
        }
    }
    size2[0] = r.get<int32_t>();
    size2[1] = r.get<int32_t>();
    const int32_t nn = r.get<int32_t>();
    if (nn < 1 || nn > 64) { error = "bad normal map count"; return false; }
    normalMap = r.blob();
    for (int32_t i = 1; i < nn && r.ok(); ++i) extraNormalMaps.push_back(r.blob());
    if (minor >= 56) {
        maskLow = r.blob();
        maskHigh = r.blob();
    } else {
        r.get<int32_t>();       // always 1
        maskLow = r.blob();
    }
    r.get<int32_t>();           // water map count, always 1
    waterMap = r.blob();
    {
        const size_t half = static_cast<size_t>(width / 2) * static_cast<size_t>(height / 2);
        foam = r.bytes(half);
        flatness = r.bytes(half);
        depthBias = r.bytes(half);
        terrainType = r.bytes(static_cast<size_t>(width) * static_cast<size_t>(height));
    }
    if (minor >= 60) {
        hasSkyBox = true;
        SkyBox& s = skybox;
        r.floats(s.position, 3);
        s.horizonHeight = r.get<float>();
        s.scale = r.get<float>();
        s.subHeight = r.get<float>();
        s.subDivAx = r.get<int32_t>();
        s.subDivHeight = r.get<int32_t>();
        s.zenithHeight = r.get<float>();
        r.floats(s.horizonColor, 3);
        r.floats(s.zenithColor, 3);
        s.decalGlow = r.get<float>();
        s.albedo = r.cstr();
        s.glow = r.cstr();
        const int32_t np = r.get<int32_t>();
        if (np < 0 || np > 100000) { error = "implausible planet count"; return false; }
        s.planets.resize(static_cast<size_t>(np));
        for (auto& p : s.planets) {
            r.floats(p.position, 3);
            p.rotation = r.get<float>();
            r.floats(p.scale, 2);
            r.floats(p.uv, 4);
        }
        for (auto& c : s.midColor) c = r.get<uint8_t>();
        s.cirrusMultiplier = r.get<float>();
        r.floats(s.cirrusColor, 3);
        s.cirrusTexture = r.cstr();
        const int32_t nc = r.get<int32_t>();
        if (nc < 0 || nc > 100000) { error = "implausible cirrus count"; return false; }
        s.cirrusLayers.resize(static_cast<size_t>(nc));
        for (auto& c : s.cirrusLayers) {
            r.floats(c.frequency, 2);
            c.speed = r.get<float>();
            r.floats(c.direction, 2);
        }
        s.clouds7 = r.get<float>();
    }
    {
        const int32_t n = r.get<int32_t>();
        if (n < 0 || n > 50000000) { error = "implausible prop count"; return false; }
        props.resize(static_cast<size_t>(n));
        for (auto& p : props) {
            p.path = r.cstr();
            r.floats(p.position, 3);
            r.floats(p.rotX, 3);
            r.floats(p.rotY, 3);
            r.floats(p.rotZ, 3);
            r.floats(p.scale, 3);
            if (!r.ok()) break;
        }
    }
    if (!r.ok()) { error = r.err; return false; }
    trailing.assign(data + r.o, data + size);
    return true;
}

bool ScMap::serialize(std::vector<uint8_t>& out, std::string& error) const {
    if (heights.size() != static_cast<size_t>(width + 1) * static_cast<size_t>(height + 1)) {
        error = "height array does not match the map size";
        return false;
    }
    const size_t half = static_cast<size_t>(width / 2) * static_cast<size_t>(height / 2);
    if (foam.size() != half || flatness.size() != half || depthBias.size() != half) {
        error = "water data planes do not match the map size";
        return false;
    }
    if (terrainType.size() != static_cast<size_t>(width) * static_cast<size_t>(height)) {
        error = "terrain type plane does not match the map size";
        return false;
    }
    out.clear();
    out.reserve(heights.size() * 2 + terrainType.size() + maskLow.size() + maskHigh.size() + normalMap.size() + 65536);
    Writer w(out);
    w.put<uint32_t>(kSignature);
    w.put<int32_t>(2);
    w.put<int32_t>(kMagic2);
    w.put<int32_t>(2);
    w.put<float>(headerWidth);
    w.put<float>(headerHeight);
    w.put<int32_t>(0);
    w.put<int16_t>(0);
    w.blob(preview);
    w.put<int32_t>(minor);
    w.put<int32_t>(width);
    w.put<int32_t>(height);
    w.put<float>(heightScale);
    w.raw(heights.data(), heights.size() * 2);
    if (minor >= 56) w.put<uint8_t>(heightPad);
    w.cstr(shader);
    w.cstr(background);
    w.cstr(skycube);
    if (minor >= 56) {
        w.put<int32_t>(static_cast<int32_t>(cubemaps.size()));
        for (const auto& c : cubemaps) { w.cstr(c.first); w.cstr(c.second); }
    } else {
        w.cstr(cubemaps.empty() ? std::string() : cubemaps[0].second);
    }
    w.put<float>(lighting.multiplier);
    w.floats(lighting.sunDirection, 3);
    w.floats(lighting.ambience, 3);
    w.floats(lighting.sunColor, 3);
    w.floats(lighting.shadowFill, 3);
    w.floats(lighting.specular, 4);
    w.put<float>(lighting.bloom);
    w.floats(lighting.fogColor, 3);
    w.put<float>(lighting.fogStart);
    w.put<float>(lighting.fogEnd);
    w.put<uint8_t>(water.present ? 1 : 0);
    w.put<float>(water.elevation);
    w.put<float>(water.deep);
    w.put<float>(water.abyss);
    w.floats(water.surfaceColor, 3);
    w.floats(water.colorLerp, 2);
    w.put<float>(water.refractionScale);
    w.put<float>(water.fresnelBias);
    w.put<float>(water.fresnelPower);
    w.put<float>(water.unitReflection);
    w.put<float>(water.skyReflection);
    w.put<float>(water.sunShininess);
    w.put<float>(water.sunStrength);
    w.floats(water.sunDirection, 3);
    w.floats(water.sunColor, 3);
    w.put<float>(water.sunReflection);
    w.put<float>(water.sunGlow);
    w.cstr(water.cubemap);
    w.cstr(water.ramp);
    for (const auto& x : water.waves) w.put<float>(x.repeat);
    for (const auto& x : water.waves) { w.floats(x.movement, 2); w.cstr(x.texture); }
    w.put<int32_t>(static_cast<int32_t>(waveGenerators.size()));
    for (const auto& g : waveGenerators) {
        w.cstr(g.texture);
        w.cstr(g.ramp);
        w.floats(g.position, 3);
        w.put<float>(g.rotation);
        w.floats(g.velocity, 3);
        w.floats(g.lifeTime, 2);
        w.floats(g.period, 2);
        w.floats(g.scale, 2);
        w.put<float>(g.frameCount);
        w.floats(g.frameRate, 2);
        w.put<float>(g.stripCount);
    }
    if (minor >= 56) {
        w.put<uint32_t>(carto.contourInterval);
        w.put<uint32_t>(carto.deepWater);
        w.put<uint32_t>(carto.contour);
        w.put<uint32_t>(carto.shore);
        w.put<uint32_t>(carto.landStart);
        w.put<uint32_t>(carto.landEnd);
        if (minor > 56) w.put<float>(carto.extra);
        for (const auto& s : strata) { w.cstr(s.path); w.put<float>(s.scale); }
        for (const auto& s : strataNormals) { w.cstr(s.path); w.put<float>(s.scale); }
    } else {
        w.cstr(legacyTileset);
        w.put<int32_t>(legacyLayerCount);
        static const int slots[6] = {0, 1, 2, 3, 4, 9};
        for (int i = 0; i < legacyLayerCount && i < 6; ++i) {
            const int slot = slots[i];
            const Stratum& n = slot < 9 ? strataNormals[slot] : legacyLayer9Normal;
            w.cstr(strata[slot].path);
            w.cstr(n.path);
            w.put<float>(strata[slot].scale);
            w.put<float>(n.scale);
        }
    }
    w.put<int32_t>(unknownAfterStrata[0]);
    w.put<int32_t>(unknownAfterStrata[1]);
    w.put<int32_t>(static_cast<int32_t>(decals.size()));
    for (const auto& d : decals) {
        w.put<int32_t>(d.id);
        w.put<int32_t>(d.type);
        w.put<int32_t>(static_cast<int32_t>(d.textures.size()));
        for (const auto& t : d.textures) { w.put<int32_t>(static_cast<int32_t>(t.size())); w.raw(t.data(), t.size()); }
        w.floats(d.scale, 3);
        w.floats(d.position, 3);
        w.floats(d.rotation, 3);
        w.put<float>(d.cutoff);
        w.put<float>(d.nearCutoff);
        w.put<int32_t>(d.owner);
    }
    w.put<int32_t>(static_cast<int32_t>(decalGroups.size()));
    for (const auto& g : decalGroups) {
        w.put<int32_t>(g.id);
        w.cstr(g.name);
        w.put<int32_t>(static_cast<int32_t>(g.ids.size()));
        w.raw(g.ids.data(), g.ids.size() * 4);
    }
    w.put<int32_t>(size2[0] ? size2[0] : width);
    w.put<int32_t>(size2[1] ? size2[1] : height);
    w.put<int32_t>(1 + static_cast<int32_t>(extraNormalMaps.size()));
    w.blob(normalMap);
    for (const auto& n : extraNormalMaps) w.blob(n);
    if (minor >= 56) {
        w.blob(maskLow);
        w.blob(maskHigh);
    } else {
        w.put<int32_t>(1);
        w.blob(maskLow);
    }
    w.put<int32_t>(1);
    w.blob(waterMap);
    w.raw(foam.data(), foam.size());
    w.raw(flatness.data(), flatness.size());
    w.raw(depthBias.data(), depthBias.size());
    w.raw(terrainType.data(), terrainType.size());
    if (minor >= 60) {
        const SkyBox& s = skybox;
        w.floats(s.position, 3);
        w.put<float>(s.horizonHeight);
        w.put<float>(s.scale);
        w.put<float>(s.subHeight);
        w.put<int32_t>(s.subDivAx);
        w.put<int32_t>(s.subDivHeight);
        w.put<float>(s.zenithHeight);
        w.floats(s.horizonColor, 3);
        w.floats(s.zenithColor, 3);
        w.put<float>(s.decalGlow);
        w.cstr(s.albedo);
        w.cstr(s.glow);
        w.put<int32_t>(static_cast<int32_t>(s.planets.size()));
        for (const auto& p : s.planets) {
            w.floats(p.position, 3);
            w.put<float>(p.rotation);
            w.floats(p.scale, 2);
            w.floats(p.uv, 4);
        }
        for (uint8_t c : s.midColor) w.put<uint8_t>(c);
        w.put<float>(s.cirrusMultiplier);
        w.floats(s.cirrusColor, 3);
        w.cstr(s.cirrusTexture);
        w.put<int32_t>(static_cast<int32_t>(s.cirrusLayers.size()));
        for (const auto& c : s.cirrusLayers) {
            w.floats(c.frequency, 2);
            w.put<float>(c.speed);
            w.floats(c.direction, 2);
        }
        w.put<float>(s.clouds7);
    }
    w.put<int32_t>(static_cast<int32_t>(props.size()));
    for (const auto& p : props) {
        w.cstr(p.path);
        w.floats(p.position, 3);
        w.floats(p.rotX, 3);
        w.floats(p.rotY, 3);
        w.floats(p.rotZ, 3);
        w.floats(p.scale, 3);
    }
    w.raw(trailing.data(), trailing.size());
    return true;
}

bool loadFile(const std::string& path, std::vector<uint8_t>& out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    const long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(n > 0 ? static_cast<size_t>(n) : 0);
    const size_t got = out.empty() ? 0 : fread(out.data(), 1, out.size(), f);
    fclose(f);
    return got == out.size();
}

bool saveFile(const std::string& path, const std::vector<uint8_t>& data) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    const size_t put = data.empty() ? 0 : fwrite(data.data(), 1, data.size(), f);
    fclose(f);
    return put == data.size();
}

}  // namespace ed
