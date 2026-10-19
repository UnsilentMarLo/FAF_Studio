// edtool: command line front end of edcore (also the headless test driver).
//   edtool scmap-rt <file.scmap | directory>...       parse and re-serialise every .scmap, compare bytes
//   edtool scmap-info <file.scmap>
//   edtool [--game DIR]... vfs-stat                    mount the game's archives and count what is visible
//   edtool [--game DIR]... scm-rt [/prefix]            every .scm: read, write, read again, compare
//   edtool [--game DIR]... dds-rt [/prefix]            every .dds: decode, re-encode (DXT5), decode, report error
//   edtool dds-info <file.dds>
// --game DIR: a folder with gamedata/*.nx2 and/or *.scd; default is FAF's data then the Steam copy of FA.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "edcore/dds.h"
#include "edcore/scm.h"
#include "edcore/scmap.h"
#include "edcore/vfs.h"

namespace fs = std::filesystem;

static void collect(const fs::path& p, std::vector<fs::path>& out) {
    std::error_code ec;
    if (fs::is_directory(p, ec)) {
        for (auto it = fs::recursive_directory_iterator(p, fs::directory_options::skip_permission_denied, ec);
             it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            if (it->is_regular_file(ec)) {
                std::string ext = it->path().extension().string();
                for (auto& c : ext) c = static_cast<char>(tolower(c));
                if (ext == ".scmap") out.push_back(it->path());
            }
        }
    } else {
        out.push_back(p);
    }
}

static int scmapRoundTrip(const std::vector<std::string>& args) {
    std::vector<fs::path> files;
    for (const auto& a : args) collect(a, files);
    int ok = 0, bad = 0, stubs = 0;
    const auto t0 = std::chrono::steady_clock::now();
    for (const auto& f : files) {
        std::vector<uint8_t> raw, out;
        if (!ed::loadFile(f.string(), raw)) { ++bad; printf("FAIL %s: cannot read\n", f.string().c_str()); continue; }
        ed::ScMap m;
        std::string err;
        if (!m.parse(raw.data(), raw.size(), err)) {
            if (err.find("stub") != std::string::npos) { ++stubs; continue; }
            ++bad;
            printf("FAIL %s: %s\n", f.string().c_str(), err.c_str());
            continue;
        }
        if (!m.serialize(out, err)) { ++bad; printf("FAIL %s: %s\n", f.string().c_str(), err.c_str()); continue; }
        if (out == raw) {
            ++ok;
        } else {
            ++bad;
            size_t i = 0;
            while (i < out.size() && i < raw.size() && out[i] == raw[i]) ++i;
            printf("MISMATCH %s: minor %d, %zu -> %zu bytes, first difference at %zu\n", f.string().c_str(), m.minor,
                   raw.size(), out.size(), i);
        }
    }
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("%d round-tripped, %d failed, %d stub files skipped, %zu maps, %.1fs\n", ok, bad, stubs, files.size(), s);
    return bad == 0 && !files.empty() ? 0 : 1;
}

static int scmapInfo(const std::string& path) {
    std::vector<uint8_t> raw;
    if (!ed::loadFile(path, raw)) { fprintf(stderr, "cannot read %s\n", path.c_str()); return 2; }
    ed::ScMap m;
    std::string err;
    if (!m.parse(raw.data(), raw.size(), err)) { fprintf(stderr, "%s: %s\n", path.c_str(), err.c_str()); return 1; }
    printf("%s\n  minor %d, %d x %d, height scale %g, shader '%s'\n  water %s (%.2f / %.2f / %.2f), %zu wave generators\n"
           "  %zu decals in %zu groups, %zu props, skybox %s\n  strata 0: '%s' %g\n",
           path.c_str(), m.minor, m.width, m.height, static_cast<double>(m.heightScale), m.shader.c_str(),
           m.water.present ? "on" : "off", static_cast<double>(m.water.elevation), static_cast<double>(m.water.deep),
           static_cast<double>(m.water.abyss), m.waveGenerators.size(), m.decals.size(), m.decalGroups.size(),
           m.props.size(), m.hasSkyBox ? "yes" : "no", m.strata[0].path.c_str(), static_cast<double>(m.strata[0].scale));
    return 0;
}

// ---- game data -------------------------------------------------------------------------------------------------
static const char* kNx2[] = {"effects", "env", "etc", "loc", "lua", "meshes", "mods", "projectiles", "textures", "units"};
static const char* kScd[] = {"units", "textures", "skins", "props", "projectiles", "objects", "mods", "meshes", "loc_us", "env", "effects"};

static int mountGame(ed::Vfs& vfs, std::vector<std::string> dirs) {
    if (dirs.empty()) {
        dirs = {"C:/ProgramData/FAForever", "D:/SteamLibrary/steamapps/common/Supreme Commander Forged Alliance"};
    }
    int n = 0;
    for (const auto& d : dirs)
        for (const char* name : kNx2) {
            const std::string p = d + "/gamedata/" + name + ".nx2";
            if (fs::exists(p) && vfs.addArchive(p)) ++n;
        }
    for (const auto& d : dirs)
        for (const char* name : kScd) {
            const std::string p = d + "/gamedata/" + name + ".scd";
            if (fs::exists(p) && vfs.addArchive(p)) ++n;
        }
    return n;
}

static int scmRoundTrip(ed::Vfs& vfs, const std::string& prefix) {
    const auto files = vfs.find(prefix, ".scm");
    int ok = 0, bad = 0, bytesEqual = 0;
    size_t verts = 0;
    const auto t0 = std::chrono::steady_clock::now();
    for (const auto& f : files) {
        std::vector<uint8_t> raw, out, again;
        if (!vfs.read(f, raw)) { ++bad; printf("FAIL %s: unreadable\n", f.c_str()); continue; }
        ed::ScmMesh m, m2;
        std::string err;
        if (!ed::scmRead(raw.data(), raw.size(), m, err)) { ++bad; printf("FAIL %s: %s\n", f.c_str(), err.c_str()); continue; }
        verts += m.vertices.size();
        if (m.version != 5) { ++ok; continue; }
        if (!ed::scmWrite(m, out, err) || !ed::scmRead(out.data(), out.size(), m2, err)) {
            ++bad;
            printf("FAIL %s: rewrite: %s\n", f.c_str(), err.c_str());
            continue;
        }
        const bool same = m2.vertices.size() == m.vertices.size() && m2.indices == m.indices && m2.bones.size() == m.bones.size() &&
                          (m.vertices.empty() || memcmp(m.vertices.data(), m2.vertices.data(), m.vertices.size() * sizeof(ed::ScmVertex)) == 0);
        if (!same) { ++bad; printf("MISMATCH %s\n", f.c_str()); continue; }
        ++ok;
        if (out == raw) ++bytesEqual;
    }
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("%zu meshes, %d ok (%d byte-identical files), %d failed, %zu vertices, %.1fs\n", files.size(), ok, bytesEqual, bad, verts, s);
    return bad == 0 ? 0 : 1;
}

static int ddsRoundTrip(ed::Vfs& vfs, const std::string& prefix) {
    const auto files = vfs.find(prefix, ".dds");
    std::map<std::string, int> formats;
    int bad = 0, tested = 0;
    double worst = 0, sum = 0;
    std::string worstName;
    const auto t0 = std::chrono::steady_clock::now();
    for (const auto& f : files) {
        std::vector<uint8_t> raw;
        if (!vfs.read(f, raw)) continue;
        ed::DdsInfo info;
        if (!ed::ddsInfo(raw.data(), raw.size(), info)) { ++bad; continue; }
        ++formats[info.format];
        ed::Image img;
        std::string err;
        if (!ed::ddsDecode(raw.data(), raw.size(), img, &err)) {
            if (!info.cube) { ++bad; printf("FAIL %s (%s %dx%d): %s\n", f.c_str(), info.format.c_str(), info.width, info.height, err.c_str()); }
            continue;
        }
        if (img.width > 1024 || img.height > 1024 || tested >= 400) continue;   // keep the self test quick
        std::vector<uint8_t> enc;
        ed::Image back;
        if (!ed::ddsEncode(img, ed::DdsFormat::DXT5, false, enc) || !ed::ddsDecode(enc.data(), enc.size(), back)) { ++bad; continue; }
        double se = 0;
        for (size_t i = 0; i < img.rgba.size(); ++i) {
            const double d = static_cast<double>(img.rgba[i]) - back.rgba[i];
            se += d * d;
        }
        const double rmse = std::sqrt(se / static_cast<double>(img.rgba.size()));
        sum += rmse;
        ++tested;
        if (rmse > worst) { worst = rmse; worstName = f; }
    }
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("%zu dds files:", files.size());
    for (auto& kv : formats) printf(" %s %d", kv.first.c_str(), kv.second);
    printf("\n  %d re-encoded with DXT5: mean RMSE %.2f, worst %.2f (%s); %d failed; %.1fs\n", tested, tested ? sum / tested : 0.0,
           worst, worstName.c_str(), bad, s);
    return bad == 0 ? 0 : 1;
}

static int ddsInfoCmd(const std::string& path) {
    std::vector<uint8_t> raw;
    if (!ed::loadFile(path, raw)) { fprintf(stderr, "cannot read %s\n", path.c_str()); return 2; }
    ed::DdsInfo i;
    if (!ed::ddsInfo(raw.data(), raw.size(), i)) { fprintf(stderr, "not a DDS file\n"); return 1; }
    printf("%s: %d x %d, %s, %d mips%s\n", path.c_str(), i.width, i.height, i.format.c_str(), i.mips, i.cube ? ", cube map" : "");
    return 0;
}

int main(int argc, char** argv) {
    std::vector<std::string> games, rest;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--game") && i + 1 < argc) games.push_back(argv[++i]);
        else rest.push_back(argv[i]);
    }
    if (rest.size() >= 2 && rest[0] == "scmap-rt") return scmapRoundTrip(std::vector<std::string>(rest.begin() + 1, rest.end()));
    if (rest.size() == 2 && rest[0] == "scmap-info") return scmapInfo(rest[1]);
    if (rest.size() == 2 && rest[0] == "dds-info") return ddsInfoCmd(rest[1]);
    if (!rest.empty() && (rest[0] == "vfs-stat" || rest[0] == "scm-rt" || rest[0] == "dds-rt")) {
        ed::Vfs vfs;
        const auto t0 = std::chrono::steady_clock::now();
        const int n = mountGame(vfs, games);
        const std::string prefix = rest.size() > 1 ? rest[1] : "/";
        if (rest[0] == "vfs-stat") {
            const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            printf("%d archives mounted, %zu files visible, index in %.2fs\n", n, vfs.find("/").size(), s);
            printf("  %zu .bp, %zu .scm, %zu .dds, %zu .sca\n", vfs.find("/", ".bp").size(), vfs.find("/", ".scm").size(),
                   vfs.find("/", ".dds").size(), vfs.find("/", ".sca").size());
            return 0;
        }
        return rest[0] == "scm-rt" ? scmRoundTrip(vfs, prefix) : ddsRoundTrip(vfs, prefix);
    }
    fprintf(stderr,
            "usage: edtool scmap-rt <file|dir>...\n       edtool scmap-info <file.scmap>\n       edtool dds-info <file.dds>\n"
            "       edtool [--game DIR]... vfs-stat | scm-rt [/prefix] | dds-rt [/prefix]\n");
    return 2;
}
