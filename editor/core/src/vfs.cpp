// edcore: inflate, zip central directory reader, folder source, VFS.
#include "edcore/vfs.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>

#include "edcore/scmap.h"   // loadFile

namespace fs = std::filesystem;

namespace ed {

// ---- inflate -------------------------------------------------------------------------------------------------------
namespace {

struct BitReader {
    const uint8_t* p;
    size_t n, pos = 0;
    uint32_t bitBuf = 0;
    int bitCnt = 0;
    bool err = false;
    int bit() {
        if (bitCnt == 0) {
            if (pos >= n) { err = true; return 0; }
            bitBuf = p[pos++];
            bitCnt = 8;
        }
        const int b = bitBuf & 1;
        bitBuf >>= 1;
        --bitCnt;
        return b;
    }
    uint32_t bits(int k) {
        uint32_t v = 0;
        for (int i = 0; i < k; ++i) v |= static_cast<uint32_t>(bit()) << i;
        return v;
    }
};

struct Huffman {
    uint16_t count[16];
    uint16_t symbol[288];
    void build(const uint8_t* lengths, int n) {
        memset(count, 0, sizeof(count));
        for (int i = 0; i < n; ++i) ++count[lengths[i]];
        count[0] = 0;
        uint16_t offs[16];
        offs[1] = 0;
        for (int i = 1; i < 15; ++i) offs[i + 1] = static_cast<uint16_t>(offs[i] + count[i]);
        for (int i = 0; i < n; ++i)
            if (lengths[i]) symbol[offs[lengths[i]]++] = static_cast<uint16_t>(i);
    }
    int decode(BitReader& br) const {
        int code = 0, first = 0, index = 0;
        for (int len = 1; len <= 15; ++len) {
            code |= br.bit();
            const int c = count[len];
            if (code - c < first) return symbol[index + (code - first)];
            index += c;
            first += c;
            first <<= 1;
            code <<= 1;
            if (br.err) return -1;
        }
        return -1;
    }
};

const uint16_t kLenBase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const uint16_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const uint16_t kDistBase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const uint16_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

bool codes(BitReader& br, uint8_t* dst, size_t cap, size_t& o, const Huffman& lit, const Huffman& dist) {
    for (;;) {
        const int s = lit.decode(br);
        if (s < 0) return false;
        if (s < 256) {
            if (o >= cap) return false;
            dst[o++] = static_cast<uint8_t>(s);
        } else if (s == 256) {
            return true;
        } else {
            const int li = s - 257;
            if (li >= 29) return false;
            const int len = kLenBase[li] + static_cast<int>(br.bits(kLenExtra[li]));
            const int ds = dist.decode(br);
            if (ds < 0 || ds >= 30) return false;
            const size_t d = kDistBase[ds] + br.bits(kDistExtra[ds]);
            if (d > o || o + static_cast<size_t>(len) > cap) return false;
            for (int i = 0; i < len; ++i, ++o) dst[o] = dst[o - d];
        }
        if (br.err) return false;
    }
}

}  // namespace

bool inflateRaw(const uint8_t* src, size_t srcSize, uint8_t* dst, size_t expected) {
    BitReader br{src, srcSize};
    size_t o = 0;
    int last;
    do {
        last = br.bit();
        const int type = static_cast<int>(br.bits(2));
        if (br.err) return false;
        if (type == 0) {
            br.bitCnt = 0;
            if (br.pos + 4 > br.n) return false;
            const unsigned len = src[br.pos] | (src[br.pos + 1] << 8);
            br.pos += 4;
            if (br.pos + len > br.n || o + len > expected) return false;
            memcpy(dst + o, src + br.pos, len);
            br.pos += len;
            o += len;
        } else if (type == 1) {
            static Huffman lit, dist;
            static bool init = false;
            if (!init) {
                uint8_t l[288];
                for (int i = 0; i < 144; ++i) l[i] = 8;
                for (int i = 144; i < 256; ++i) l[i] = 9;
                for (int i = 256; i < 280; ++i) l[i] = 7;
                for (int i = 280; i < 288; ++i) l[i] = 8;
                lit.build(l, 288);
                uint8_t d[30];
                for (auto& x : d) x = 5;
                dist.build(d, 30);
                init = true;
            }
            if (!codes(br, dst, expected, o, lit, dist)) return false;
        } else if (type == 2) {
            const int nlen = static_cast<int>(br.bits(5)) + 257, ndist = static_cast<int>(br.bits(5)) + 1,
                      ncode = static_cast<int>(br.bits(4)) + 4;
            static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
            uint8_t lengths[320] = {};
            for (int i = 0; i < ncode; ++i) lengths[order[i]] = static_cast<uint8_t>(br.bits(3));
            Huffman lencode;
            lencode.build(lengths, 19);
            int idx = 0;
            uint8_t ll[320] = {};
            while (idx < nlen + ndist) {
                const int sym = lencode.decode(br);
                if (sym < 0) return false;
                if (sym < 16) {
                    ll[idx++] = static_cast<uint8_t>(sym);
                } else {
                    int rep = 0;
                    uint8_t val = 0;
                    if (sym == 16) {
                        if (idx == 0) return false;
                        val = ll[idx - 1];
                        rep = 3 + static_cast<int>(br.bits(2));
                    } else if (sym == 17) {
                        rep = 3 + static_cast<int>(br.bits(3));
                    } else {
                        rep = 11 + static_cast<int>(br.bits(7));
                    }
                    if (idx + rep > nlen + ndist) return false;
                    while (rep--) ll[idx++] = val;
                }
            }
            Huffman lit, dist;
            lit.build(ll, nlen);
            dist.build(ll + nlen, ndist);
            if (!codes(br, dst, expected, o, lit, dist)) return false;
        } else {
            return false;
        }
    } while (!last);
    return o == expected;
}

// ---- zip archive source --------------------------------------------------------------------------------------------
namespace {

uint32_t le32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }
uint16_t le16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }

class ZipSource : public Source {
public:
    struct Entry { uint32_t offset, csize, usize; uint16_t method; };
    bool open(const std::string& path) {
        path_ = path;
        fp_ = fopen(path.c_str(), "rb");
        if (!fp_) return false;
        fseek(fp_, 0, SEEK_END);
        const long size = ftell(fp_);
        const long tail = std::min<long>(size, 70000);
        std::vector<uint8_t> t(static_cast<size_t>(tail));
        fseek(fp_, size - tail, SEEK_SET);
        if (fread(t.data(), 1, t.size(), fp_) != t.size()) return false;
        long e = -1;
        for (long i = tail - 22; i >= 0; --i)
            if (le32(&t[static_cast<size_t>(i)]) == 0x06054b50) { e = i; break; }
        if (e < 0) return false;
        const uint32_t count = le16(&t[static_cast<size_t>(e) + 10]), cdSize = le32(&t[static_cast<size_t>(e) + 12]),
                       cdOff = le32(&t[static_cast<size_t>(e) + 16]);
        std::vector<uint8_t> cd(cdSize);
        fseek(fp_, static_cast<long>(cdOff), SEEK_SET);
        if (fread(cd.data(), 1, cd.size(), fp_) != cd.size()) return false;
        size_t o = 0;
        for (uint32_t i = 0; i < count && o + 46 <= cd.size(); ++i) {
            if (le32(&cd[o]) != 0x02014b50) break;
            Entry en;
            en.method = le16(&cd[o + 10]);
            en.csize = le32(&cd[o + 20]);
            en.usize = le32(&cd[o + 24]);
            const uint16_t nl = le16(&cd[o + 28]), xl = le16(&cd[o + 30]), cl = le16(&cd[o + 32]);
            en.offset = le32(&cd[o + 42]);
            std::string name(reinterpret_cast<const char*>(&cd[o + 46]), nl);
            o += 46u + nl + xl + cl;
            if (!name.empty() && name.back() == '/') continue;
            entries_[Vfs::normalize(name)] = en;
        }
        return true;
    }
    ~ZipSource() override { if (fp_) fclose(fp_); }
    bool read(const std::string& rel, std::vector<uint8_t>& out) override {
        auto it = entries_.find(rel);
        if (it == entries_.end()) return false;
        const Entry& en = it->second;
        uint8_t lh[30];
        fseek(fp_, static_cast<long>(en.offset), SEEK_SET);
        if (fread(lh, 1, 30, fp_) != 30 || le32(lh) != 0x04034b50) return false;
        fseek(fp_, static_cast<long>(en.offset) + 30 + le16(lh + 26) + le16(lh + 28), SEEK_SET);
        std::vector<uint8_t> comp(en.csize);
        if (en.csize && fread(comp.data(), 1, comp.size(), fp_) != comp.size()) return false;
        out.resize(en.usize);
        if (en.method == 0) { out = comp; return out.size() == en.usize; }
        if (en.method == 8) return inflateRaw(comp.data(), comp.size(), out.data(), en.usize);
        return false;
    }
    void list(std::vector<std::string>& out) override { for (auto& e : entries_) out.push_back(e.first); }
    std::string label() const override { return path_; }

private:
    std::string path_;
    FILE* fp_ = nullptr;
    std::map<std::string, Entry> entries_;
};

class DirSource : public Source {
public:
    explicit DirSource(std::string root) : root_(std::move(root)) {}
    void scan() {
        std::error_code ec;
        const fs::path base(root_);
        for (auto it = fs::recursive_directory_iterator(base, fs::directory_options::skip_permission_denied, ec);
             it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            if (!it->is_regular_file(ec)) continue;
            index_[Vfs::normalize(fs::relative(it->path(), base, ec).generic_string())] = it->path().string();
        }
    }
    bool read(const std::string& rel, std::vector<uint8_t>& out) override {
        auto it = index_.find(rel);
        return it != index_.end() && loadFile(it->second, out);
    }
    void list(std::vector<std::string>& out) override { for (auto& e : index_) out.push_back(e.first); }
    std::string label() const override { return root_; }

private:
    std::string root_;
    std::map<std::string, std::string> index_;
};

}  // namespace

std::string Vfs::normalize(const std::string& p) {
    std::string s;
    s.reserve(p.size() + 1);
    for (char c : p) s.push_back(c == '\\' ? '/' : static_cast<char>(tolower(static_cast<unsigned char>(c))));
    if (s.empty() || s[0] != '/') s.insert(s.begin(), '/');
    size_t pos;
    while ((pos = s.find("//")) != std::string::npos) s.erase(pos, 1);
    return s;
}

static std::string normMount(const std::string& m) {
    std::string s = Vfs::normalize(m);
    while (s.size() > 1 && s.back() == '/') s.pop_back();
    return s == "/" ? "" : s;
}

bool Vfs::addArchive(const std::string& zipPath, const std::string& mount) {
    auto z = std::make_unique<ZipSource>();
    if (!z->open(zipPath)) return false;
    z->mount = normMount(mount);
    sources_.push_back(std::move(z));
    indexed_ = false;
    return true;
}

bool Vfs::addDirectory(const std::string& dir, const std::string& mount) {
    std::error_code ec;
    if (!fs::is_directory(dir, ec)) return false;
    auto d = std::make_unique<DirSource>(dir);
    d->scan();
    d->mount = normMount(mount);
    sources_.push_back(std::move(d));
    indexed_ = false;
    return true;
}

void Vfs::buildIndex() const {
    index_.clear();
    std::vector<std::string> names;
    for (size_t i = 0; i < sources_.size(); ++i) {
        names.clear();
        sources_[i]->list(names);
        for (const auto& n : names) index_.emplace(sources_[i]->mount + n, static_cast<int>(i));
    }
    indexed_ = true;
}

bool Vfs::read(const std::string& gamePath, std::vector<uint8_t>& out) const {
    if (!indexed_) buildIndex();
    const std::string p = normalize(gamePath);
    auto it = index_.find(p);
    if (it == index_.end()) return false;
    Source& s = *sources_[static_cast<size_t>(it->second)];
    return s.read(p.substr(s.mount.size()), out);
}

bool Vfs::exists(const std::string& gamePath) const {
    if (!indexed_) buildIndex();
    return index_.count(normalize(gamePath)) != 0;
}

std::vector<std::string> Vfs::find(const std::string& prefix, const std::string& ext) const {
    if (!indexed_) buildIndex();
    std::string pre = normalize(prefix);
    if (pre.back() != '/') pre.push_back('/');
    std::string e = ext;
    for (auto& c : e) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    std::vector<std::string> out;
    for (auto it = index_.lower_bound(pre); it != index_.end() && it->first.compare(0, pre.size(), pre) == 0; ++it)
        if (e.empty() || (it->first.size() >= e.size() && it->first.compare(it->first.size() - e.size(), e.size(), e) == 0))
            out.push_back(it->first);
    return out;
}

}  // namespace ed
