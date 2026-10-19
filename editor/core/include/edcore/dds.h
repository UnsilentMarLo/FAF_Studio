// edcore: DDS images as the game uses them: DXT1 / DXT3 / DXT5 and uncompressed ARGB8, with mip chains.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ed {

struct Image {
    int width = 0, height = 0;
    std::vector<uint8_t> rgba;          // width * height * 4, R G B A
};

struct DdsInfo {
    int width = 0, height = 0, mips = 1;
    std::string format;                 // "DXT1" "DXT3" "DXT5" "ARGB8" "RGB8" "L8" "RGB16" or the fourcc
    bool cube = false;
};

bool ddsInfo(const uint8_t* data, size_t size, DdsInfo& info);
// top mip level -> RGBA8
bool ddsDecode(const uint8_t* data, size_t size, Image& out, std::string* error = nullptr);

enum class DdsFormat { DXT1, DXT5, ARGB8 };
// Encodes (and, with `mips`, builds the full mip chain with a box filter). DXT endpoints come from a range fit.
bool ddsEncode(const Image& img, DdsFormat format, bool mips, std::vector<uint8_t>& out);

// Box filter resample to an exact size (for atlases, previews, mips).
Image resize(const Image& src, int w, int h);

}  // namespace ed
