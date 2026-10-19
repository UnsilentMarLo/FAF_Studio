// edcore: SCM mesh reader / writer / splitter. See scm.h.
#include "edcore/scm.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <tuple>

namespace ed {

namespace {

uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }

constexpr size_t kBoneSize = 108, kVertexSize = 68;
static_assert(sizeof(ScmVertex) == 68, "SCM vertex is 68 bytes");

void put32(std::vector<uint8_t>& o, uint32_t v) {
    for (int i = 0; i < 4; ++i) o.push_back(static_cast<uint8_t>((v >> (8 * i)) & 255));
}
void putf(std::vector<uint8_t>& o, float f) {
    uint32_t v;
    memcpy(&v, &f, 4);
    put32(o, v);
}
void setf(std::vector<uint8_t>& o, size_t at, uint32_t v) {
    for (int i = 0; i < 4; ++i) o[at + static_cast<size_t>(i)] = static_cast<uint8_t>((v >> (8 * i)) & 255);
}

// pads so that the byte after `tag` is 32-aligned
void block(std::vector<uint8_t>& o, const char* tag) {
    const size_t pad = (32 - (o.size() + 4) % 32) % 32;
    o.insert(o.end(), pad, 0xC5);
    o.insert(o.end(), tag, tag + 4);
}

}  // namespace

void ScmMesh::bounds(float out[6]) const {
    for (int i = 0; i < 3; ++i) { out[i] = 1e30f; out[3 + i] = -1e30f; }
    for (const auto& v : vertices)
        for (int i = 0; i < 3; ++i) {
            out[i] = std::min(out[i], v.position[i]);
            out[3 + i] = std::max(out[3 + i], v.position[i]);
        }
}

bool scmRead(const uint8_t* d, size_t n, ScmMesh& m, std::string& err) {
    m = ScmMesh();
    if (n < 48 || memcmp(d, "MODL", 4) != 0) { err = "not an SCM file"; return false; }
    m.version = rd32(d + 4);
    if (m.version < 5 || m.version > 7) { err = "SCM version " + std::to_string(m.version) + " is not supported"; return false; }
    const uint32_t boneOff = rd32(d + 8), skinned = rd32(d + 12), vertOff = rd32(d + 16), vertCount = rd32(d + 24),
                   idxOff = rd32(d + 28), idxCount = rd32(d + 32), infoOff = rd32(d + 36), infoSize = rd32(d + 40),
                   boneCount = rd32(d + 44);
    m.skinnedBones = skinned;
    if (static_cast<size_t>(boneOff) + static_cast<size_t>(boneCount) * kBoneSize > n ||
        static_cast<size_t>(vertOff) + static_cast<size_t>(vertCount) * kVertexSize > n ||
        static_cast<size_t>(idxOff) + static_cast<size_t>(idxCount) * 2 > n || static_cast<size_t>(infoOff) + infoSize > n) {
        err = "offsets outside the file";
        return false;
    }
    m.bones.resize(boneCount);
    for (uint32_t i = 0; i < boneCount; ++i) {
        const uint8_t* b = d + boneOff + static_cast<size_t>(i) * kBoneSize;
        ScmBone& bone = m.bones[i];
        memcpy(bone.inverseRest, b, 64);
        memcpy(bone.position, b + 64, 12);
        memcpy(bone.rotation, b + 76, 16);
        const uint32_t nameOff = rd32(b + 92);
        bone.parent = rd32(b + 96);
        bone.unknown[0] = rd32(b + 100);
        bone.unknown[1] = rd32(b + 104);
        if (nameOff < n) {
            size_t e = nameOff;
            while (e < n && d[e]) ++e;
            bone.name.assign(reinterpret_cast<const char*>(d + nameOff), e - nameOff);
        }
    }
    m.vertices.resize(vertCount);
    if (vertCount) memcpy(m.vertices.data(), d + vertOff, static_cast<size_t>(vertCount) * kVertexSize);
    m.indices.resize(idxCount);
    if (idxCount) memcpy(m.indices.data(), d + idxOff, static_cast<size_t>(idxCount) * 2);
    for (size_t o = infoOff; o < static_cast<size_t>(infoOff) + infoSize;) {
        size_t e = o;
        while (e < static_cast<size_t>(infoOff) + infoSize && d[e]) ++e;
        m.info.emplace_back(reinterpret_cast<const char*>(d + o), e - o);
        o = e + 1;
    }
    return true;
}

bool scmWrite(const ScmMesh& m, std::vector<uint8_t>& o, std::string& err) {
    if (m.vertices.size() > 65535) { err = std::to_string(m.vertices.size()) + " vertices: an SCM file holds at most 65535"; return false; }
    for (uint16_t i : m.indices)
        if (i >= m.vertices.size()) { err = "index outside the vertex array"; return false; }
    o.assign(48, 0);
    block(o, "NAME");
    std::vector<uint32_t> nameOff;
    for (const auto& b : m.bones) {
        nameOff.push_back(static_cast<uint32_t>(o.size()));
        o.insert(o.end(), b.name.begin(), b.name.end());
        o.push_back(0);
    }
    block(o, "SKEL");
    const uint32_t boneOff = static_cast<uint32_t>(o.size());
    for (size_t i = 0; i < m.bones.size(); ++i) {
        const ScmBone& b = m.bones[i];
        const size_t at = o.size();
        o.resize(at + kBoneSize);
        memcpy(&o[at], b.inverseRest, 64);
        memcpy(&o[at + 64], b.position, 12);
        memcpy(&o[at + 76], b.rotation, 16);
        setf(o, at + 92, nameOff[i]);
        setf(o, at + 96, b.parent);
        setf(o, at + 100, b.unknown[0]);
        setf(o, at + 104, b.unknown[1]);
    }
    block(o, "VTXL");
    const uint32_t vertOff = static_cast<uint32_t>(o.size());
    {
        const size_t at = o.size();
        o.resize(at + m.vertices.size() * kVertexSize);
        if (!m.vertices.empty()) memcpy(&o[at], m.vertices.data(), m.vertices.size() * kVertexSize);
    }
    block(o, "TRIS");
    const uint32_t idxOff = static_cast<uint32_t>(o.size());
    for (uint16_t i : m.indices) {
        o.push_back(static_cast<uint8_t>(i & 255));
        o.push_back(static_cast<uint8_t>(i >> 8));
    }
    block(o, "INFO");
    const uint32_t infoOff = static_cast<uint32_t>(o.size());
    for (const auto& s : m.info) {
        o.insert(o.end(), s.begin(), s.end());
        o.push_back(0);
    }
    const uint32_t infoSize = static_cast<uint32_t>(o.size()) - infoOff;
    memcpy(o.data(), "MODL", 4);
    setf(o, 4, 5);
    setf(o, 8, boneOff);
    setf(o, 12, m.skinnedBones);
    setf(o, 16, vertOff);
    setf(o, 20, 0);
    setf(o, 24, static_cast<uint32_t>(m.vertices.size()));
    setf(o, 28, idxOff);
    setf(o, 32, static_cast<uint32_t>(m.indices.size()));
    setf(o, 36, infoOff);
    setf(o, 40, infoSize);
    setf(o, 44, static_cast<uint32_t>(m.bones.size()));
    return true;
}

std::vector<ScmMesh> scmSplit(const ScmMesh& m, size_t limit, float tile) {
    std::vector<ScmMesh> out;
    if (m.vertices.size() <= limit) {
        out.push_back(m);
        return out;
    }
    struct Tri { int tz, tx; uint32_t a, b, c; };
    std::vector<Tri> tris;
    for (size_t t = 0; t + 2 < m.indices.size(); t += 3) {
        const uint32_t a = m.indices[t], b = m.indices[t + 1], c = m.indices[t + 2];
        const float cx = (m.vertices[a].position[0] + m.vertices[b].position[0] + m.vertices[c].position[0]) / 3.0f;
        const float cz = (m.vertices[a].position[2] + m.vertices[b].position[2] + m.vertices[c].position[2]) / 3.0f;
        tris.push_back({static_cast<int>(std::floor(cz / tile)), static_cast<int>(std::floor(cx / tile)), a, b, c});
    }
    std::stable_sort(tris.begin(), tris.end(), [](const Tri& x, const Tri& y) { return std::tie(x.tz, x.tx) < std::tie(y.tz, y.tx); });
    ScmMesh cur;
    cur.bones = m.bones;
    cur.skinnedBones = m.skinnedBones;
    cur.info = m.info;
    std::map<uint32_t, uint16_t> remap;
    auto flush = [&]() {
        if (!cur.indices.empty()) out.push_back(cur);
        cur.vertices.clear();
        cur.indices.clear();
        remap.clear();
    };
    for (const Tri& t : tris) {
        size_t fresh = 0;
        for (uint32_t v : {t.a, t.b, t.c})
            if (!remap.count(v)) ++fresh;
        if (cur.vertices.size() + fresh > limit) flush();
        for (uint32_t v : {t.a, t.b, t.c}) {
            auto it = remap.find(v);
            if (it == remap.end()) {
                it = remap.emplace(v, static_cast<uint16_t>(cur.vertices.size())).first;
                cur.vertices.push_back(m.vertices[v]);
            }
            cur.indices.push_back(it->second);
        }
    }
    flush();
    return out;
}

}  // namespace ed
