// edcore: Forged Alliance .scmap (version 2, minor 53-60), complete and lossless.
// Layout: see map_editor/server/scmap.py and faf_repo/Neroxis-Map-Generator SCMapImporter. Round trip is byte exact.
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace ed {

struct Decal {
    int32_t id = 0, type = 0;
    std::vector<std::string> textures;
    float scale[3] = {}, position[3] = {}, rotation[3] = {};
    float cutoff = 0, nearCutoff = 0;
    int32_t owner = 0;
};

struct DecalGroup {
    int32_t id = 0;
    std::string name;
    std::vector<int32_t> ids;
};

struct WaveTexture {
    float repeat = 0, movement[2] = {};
    std::string texture;
};

struct Lighting {
    float multiplier = 1.5f, sunDirection[3] = {0.4f, 0.8f, -0.4f}, ambience[3] = {0.3f, 0.3f, 0.3f},
          sunColor[3] = {1, 1, 1}, shadowFill[3] = {0.7f, 0.7f, 0.7f}, specular[4] = {}, bloom = 0.1f,
          fogColor[3] = {0.8f, 0.8f, 0.8f}, fogStart = 1000, fogEnd = 2000;
};

struct Water {
    bool present = false;
    float elevation = 25, deep = 20, abyss = 10, surfaceColor[3] = {0, 0.7f, 1.5f}, colorLerp[2] = {0.64f, 0.8f},
          refractionScale = 0.375f, fresnelBias = 0.15f, fresnelPower = 1.5f, unitReflection = 0.5f,
          skyReflection = 1.5f, sunShininess = 50, sunStrength = 10, sunDirection[3] = {0, -1, 0},
          sunColor[3] = {1, 0.96f, 0.7f}, sunReflection = 5, sunGlow = 0.1f;
    std::string cubemap, ramp;
    WaveTexture waves[4];
};

struct WaveGenerator {
    std::string texture, ramp;
    float position[3] = {}, rotation = 0, velocity[3] = {}, lifeTime[2] = {}, period[2] = {}, scale[2] = {},
          frameCount = 0, frameRate[2] = {}, stripCount = 0;
};

struct Cartographic {
    uint32_t contourInterval = 24, deepWater = 0xFF000000, contour = 0xFF000000, shore = 0xFF000000,
             landStart = 0xFF000000, landEnd = 0xFF000000;
    float extra = 0;                      // minor > 56 only
};

struct SkyPlanet { float position[3] = {}, rotation = 0, scale[2] = {}, uv[4] = {}; };
struct SkyCirrus { float frequency[2] = {}, speed = 0, direction[2] = {}; };
struct SkyBox {                           // minor >= 60
    float position[3] = {}, horizonHeight = 0, scale = 0, subHeight = 0;
    int32_t subDivAx = 0, subDivHeight = 0;
    float zenithHeight = 0, horizonColor[3] = {}, zenithColor[3] = {}, decalGlow = 0;
    std::string albedo, glow;
    std::vector<SkyPlanet> planets;
    uint8_t midColor[3] = {};
    float cirrusMultiplier = 0, cirrusColor[3] = {};
    std::string cirrusTexture;
    std::vector<SkyCirrus> cirrusLayers;
    float clouds7 = 0;
};

struct Prop {
    std::string path;
    float position[3] = {}, rotX[3] = {}, rotY[3] = {}, rotZ[3] = {}, scale[3] = {};
};

struct Stratum { std::string path; float scale = 4; };

struct ScMap {
    int32_t minor = 56;
    int32_t width = 0, height = 0;                 // height samples are (width + 1) * (height + 1)
    float headerWidth = 0, headerHeight = 0;
    std::vector<uint8_t> preview;                  // DDS file
    float heightScale = 1.0f / 128.0f;
    std::vector<uint16_t> heights;
    uint8_t heightPad = 0;                         // the byte after the heights (minor >= 56)
    std::string shader, background, skycube;
    std::vector<std::pair<std::string, std::string>> cubemaps;
    Lighting lighting;
    Water water;
    std::vector<WaveGenerator> waveGenerators;
    Cartographic carto;
    Stratum strata[10], strataNormals[9];
    // minor < 56 extras (original game maps)
    std::string legacyTileset = "No Tileset";
    int32_t legacyLayerCount = 6;
    Stratum legacyLayer9Normal;
    int32_t unknownAfterStrata[2] = {};
    std::vector<Decal> decals;
    std::vector<DecalGroup> decalGroups;
    int32_t size2[2] = {};                         // second width / height pair (normal map size on big maps)
    std::vector<uint8_t> normalMap;                // DDS
    std::vector<std::vector<uint8_t>> extraNormalMaps;
    std::vector<uint8_t> maskLow, maskHigh;        // DDS; maskHigh empty when minor < 56
    std::vector<uint8_t> waterMap;                 // DDS
    std::vector<uint8_t> foam, flatness, depthBias, terrainType;
    bool hasSkyBox = false;
    SkyBox skybox;
    std::vector<Prop> props;
    std::vector<uint8_t> trailing;

    // Parse a whole file. Returns false and fills `error` on failure (stub files, unsupported minor, truncation).
    bool parse(const uint8_t* data, size_t size, std::string& error);
    // Serialise. Throws nothing; returns false and `error` when the arrays do not match the map size.
    bool serialize(std::vector<uint8_t>& out, std::string& error) const;
};

bool loadFile(const std::string& path, std::vector<uint8_t>& out);
bool saveFile(const std::string& path, const std::vector<uint8_t>& data);

}  // namespace ed
