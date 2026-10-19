// edcore: Supreme Commander SCM meshes (version 5 as units and props use them; version 7 read-only).
// Layout (checked against retail unit meshes; every block starts on a 32-byte boundary, the 4 bytes before it are its
// tag, the gap is 0xC5): header 'MODL' + 11 u32, 'NAME' bone names, 'SKEL' 108-byte bones, 'VTXL' 68-byte vertices,
// 'TRIS' u16 indices, 'INFO' strings. At most 65,535 vertices per file (16-bit indices).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ed {

struct ScmVertex {
    float position[3], normal[3], tangent[3], binormal[3], uv1[2], uv2[2];
    uint8_t bone[4];
};

struct ScmBone {
    float inverseRest[16];
    float position[3];
    float rotation[4];                  // w x y z
    std::string name;
    uint32_t parent = 0xFFFFFFFFu;
    uint32_t unknown[2] = {0, 0};
};

struct ScmMesh {
    uint32_t version = 5;
    uint32_t skinnedBones = 1;
    std::vector<ScmBone> bones;
    std::vector<ScmVertex> vertices;
    std::vector<uint16_t> indices;      // triangle list
    std::vector<std::string> info;

    // bounding box of the vertices: min xyz, max xyz
    void bounds(float out[6]) const;
};

bool scmRead(const uint8_t* data, size_t size, ScmMesh& mesh, std::string& error);
bool scmWrite(const ScmMesh& mesh, std::vector<uint8_t>& out, std::string& error);   // always version 5

// Cuts a mesh into patches of at most `limit` vertices. A mesh that fits is returned as is; a larger one is cut by
// triangle position into `tile` sized cells (good for culling) and then packed.
std::vector<ScmMesh> scmSplit(const ScmMesh& mesh, size_t limit = 65535, float tile = 256.0f);

}  // namespace ed
