// edcore: virtual file system over the game's archives (.scd / .nx2 / .zip) and folders, with the game's rules:
// case-insensitive '/'-separated paths, first mounted source that has the file wins, mount points.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace ed {

// Raw DEFLATE (RFC 1951). Returns false on corrupt input or when the output size differs from `expected`.
bool inflateRaw(const uint8_t* src, size_t srcSize, uint8_t* dst, size_t expected);

class Source {
public:
    virtual ~Source() = default;
    virtual bool read(const std::string& relPath, std::vector<uint8_t>& out) = 0;   // relPath: lowercase, leading '/'
    virtual void list(std::vector<std::string>& out) = 0;                           // all relative paths
    virtual std::string label() const = 0;
    std::string mount;                                                             // lowercase, no trailing '/', "" = root
};

class Vfs {
public:
    bool addArchive(const std::string& zipPath, const std::string& mount = "");
    bool addDirectory(const std::string& dir, const std::string& mount = "");
    bool read(const std::string& gamePath, std::vector<uint8_t>& out) const;
    bool exists(const std::string& gamePath) const;
    // all visible game paths below `prefix` ending in `ext` (empty = any), sorted
    std::vector<std::string> find(const std::string& prefix, const std::string& ext = "") const;
    size_t sourceCount() const { return sources_.size(); }

    static std::string normalize(const std::string& p);

private:
    void buildIndex() const;
    std::vector<std::unique_ptr<Source>> sources_;
    mutable std::map<std::string, int> index_;      // game path -> source number (first wins)
    mutable bool indexed_ = false;
};

}  // namespace ed
