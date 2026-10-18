// A developer's tool for the Map's PMTiles code (not installed with the plugin):
//   pmtiles_dev show FILE
//   pmtiles_dev extract URL OUT WEST SOUTH EAST NORTH MAXZOOM [--dry-run]
// extract cuts a box out of a remote archive with adif::pmtiles::Extract, the way the plugin's
// Settings → Map Detail does, fetching each range with macOS's curl (the ETag pinned, so two
// builds are never mixed).
#include "adif_mvt.h"
#include "adif_pmtiles.h"

#include <algorithm>
#include <cmath>
#include <map>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

using namespace adif::pmtiles;

static std::string gEtag, gUrl, gTmp;
static uint64_t gRequests = 0, gBytes = 0;

static std::string quote(const std::string &s) {
    std::string q = "'";
    for (char c : s) q += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return q + "'";
}

static bool fetch(uint64_t offset, uint64_t length, std::string *out) {
    std::string headers = gTmp + ".h", body = gTmp + ".b";
    std::string cmd = "curl -sS -A " + quote("ADIF Lint dev tool (github.com/ssamjung2/Nextpad_plus_plus_ADIFLint)") + " -r " +
                      std::to_string(offset) + "-" + std::to_string(offset + length - 1) + " -D " + quote(headers) + " -o " + quote(body);
    if (!gEtag.empty()) cmd += " -H " + quote("If-Match: " + gEtag);
    cmd += " " + quote(gUrl);
    if (std::system(cmd.c_str()) != 0) return false;
    std::ifstream h(headers), b(body, std::ios::binary);
    std::string line, status;
    bool first = true;
    while (std::getline(h, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (first) status = line, first = false;
        if (line.rfind("etag:", 0) == 0 || line.rfind("ETag:", 0) == 0) {
            std::string e = line.substr(5);
            while (!e.empty() && e[0] == ' ') e.erase(0, 1);
            if (gEtag.empty()) gEtag = e;
            else if (e != gEtag) return std::fprintf(stderr, "the build changed (ETag %s, was %s)\n", e.c_str(), gEtag.c_str()), false;
        }
    }
    if (status.find(" 206") == std::string::npos) return std::fprintf(stderr, "expected 206, got: %s\n", status.c_str()), false;
    std::stringstream ss;
    ss << b.rdbuf();
    *out = ss.str();
    ++gRequests, gBytes += out->size();
    return out->size() == length;
}

static int show(const char *path) {
    Archive a;
    std::string why;
    if (!a.open(path, &why)) return std::fprintf(stderr, "%s\n", why.c_str()), 1;
    const Header &h = a.header();
    std::printf("zooms %d-%d, %llu tiles addressed, %llu entries, %llu contents, clustered %d, compression %d/%d, type %d\n", h.minZoom,
                h.maxZoom, (unsigned long long)h.addressedTiles, (unsigned long long)h.tileEntries, (unsigned long long)h.tileContents,
                h.clustered, h.internalCompression, h.tileCompression, h.tileType);
    std::printf("bounds %.5f %.5f %.5f %.5f; root %llu bytes, leaves %llu, data %llu\n", h.minLonE7 / 1e7, h.minLatE7 / 1e7, h.maxLonE7 / 1e7,
                h.maxLatE7 / 1e7, (unsigned long long)h.rootLength, (unsigned long long)h.leafLength, (unsigned long long)h.dataLength);
    double cx = (h.minLonE7 + h.maxLonE7) / 2e7, cy = (h.minLatE7 + h.maxLatE7) / 2e7;
    for (int z = h.minZoom; z <= h.maxZoom; ++z) {
        std::string t;
        bool ok = a.tile(z, (uint32_t)tileX(cx, z), (uint32_t)tileY(cy, z), &t);
        std::printf("  z%-2d centre tile: %s %zu bytes\n", z, ok ? "found," : "missing", t.size());
    }
    return 0;
}

static int extract(int argc, char **argv) {
    gUrl = argv[2];
    std::string outPath = argv[3];
    double w = std::atof(argv[4]), s = std::atof(argv[5]), e = std::atof(argv[6]), n = std::atof(argv[7]);
    int maxZoom = std::atoi(argv[8]);
    bool dry = argc > 9 && std::string(argv[9]) == "--dry-run";
    char tmpl[] = "/tmp/pmtiles_dev.XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return 1;
    close(fd);
    gTmp = tmpl;
    std::vector<uint64_t> tiles = coveringTiles({{{w, s}, {e, s}, {e, n}, {w, n}}}, 0, maxZoom);
    std::printf("%zu tiles in the box at zooms 0-%d\n", tiles.size(), maxZoom);
    Extract x(tiles, {w, s, e, n});
    std::string bytes, why;
    if (!fetch(0, kFirstBytes, &bytes) || !x.start(bytes, &why)) return std::fprintf(stderr, "start: %s\n", why.c_str()), 1;
    std::printf("ETag %s\n", gEtag.c_str());
    if (!fetch(x.metadataRange().offset, x.metadataRange().length, &bytes) || !x.metadata(bytes, &why))
        return std::fprintf(stderr, "metadata: %s\n", why.c_str()), 1;
    for (int round = 0; !x.planned() && round < 5; ++round) {
        std::vector<Range> ranges = x.directoryRanges();
        std::printf("round %d: %zu directory requests\n", round + 1, ranges.size());
        for (const Range &r : ranges)
            if (!fetch(r.offset, r.length, &bytes) || !x.addDirectories(r, bytes, &why)) return std::fprintf(stderr, "leaves: %s\n", why.c_str()), 1;
    }
    if (!x.planned()) return std::fprintf(stderr, "not planned\n"), 1;
    std::vector<Range> data = x.dataRanges();
    uint64_t asked = 0;
    for (const Range &r : data) asked += r.length;
    std::printf("%zu tiles, %.2f MB of tile data; %zu data requests, %.2f MB read; so far %llu requests, %.2f MB\n", x.tileCount(),
                x.tileBytes() / 1e6, data.size(), asked / 1e6, (unsigned long long)gRequests, gBytes / 1e6);
    if (dry) return 0;
    std::ofstream out(outPath, std::ios::binary | std::ios::trunc);
    out << x.head();
    for (size_t i = 0; i < data.size(); ++i) {
        if (!fetch(data[i].offset, data[i].length, &bytes)) return std::fprintf(stderr, "data request %zu failed\n", i), 1;
        out << x.copyFrom(i, bytes);
    }
    out.close();
    std::printf("wrote %s; %llu requests, %.2f MB in all\n", outPath.c_str(), (unsigned long long)gRequests, gBytes / 1e6);
    unlink((gTmp + ".h").c_str()), unlink((gTmp + ".b").c_str()), unlink(gTmp.c_str());
    return show(outPath.c_str());
}

// The layers of the tile at a place: each one's features, by geometry type and by kind.
static int layers(const char *path, int z, double lon, double lat) {
    Archive a;
    std::string why, tile;
    if (!a.open(path, &why)) return std::fprintf(stderr, "%s\n", why.c_str()), 1;
    uint32_t x = (uint32_t)tileX(lon, z), y = (uint32_t)tileY(lat, z);
    if (!a.tile(z, x, y, &tile)) return std::fprintf(stderr, "no tile %d/%u/%u\n", z, x, y), 1;
    std::vector<adif::mvt::Layer> ls;
    if (!adif::mvt::decode(tile, &ls, &why)) return std::fprintf(stderr, "%s\n", why.c_str()), 1;
    std::printf("tile %d/%u/%u, %zu bytes\n", z, x, y, tile.size());
    for (const auto &l : ls) {
        std::map<std::string, int> kinds;
        size_t points = 0, bad = 0;
        for (const auto &f : l.features) {
            std::vector<adif::mvt::Path> g;
            if (!adif::mvt::geometry(f, &g)) ++bad;
            for (const auto &p : g) points += p.points.size();
            ++kinds[std::to_string((int)f.type) + ":" + l.text(f, "kind") + (l.text(f, "kind_detail").empty() ? "" : "/" + l.text(f, "kind_detail"))];
        }
        std::printf("%s (extent %u, v%u): %zu features, %zu points, %zu bad; keys:", l.name.c_str(), l.extent, l.version, l.features.size(), points, bad);
        for (const auto &k : l.keys) std::printf(" %s", k.c_str());
        std::printf("\n");
        for (const auto &[k, n] : kinds) std::printf("    %-40s %d\n", k.c_str(), n);
    }
    return 0;
}

// The tests' stand-in for Protomaps' build (tests/fixtures/lookup/mapdetail): made-up
// features near Madison, Wisconsin (a lake, a park, buildings, two named streets, a place
// name) in vector tiles at zooms 0-15, so no OpenStreetMap data is copied into the tests.
namespace mvtw {
void pv(std::string &s, uint64_t v) {
    while (v >= 0x80) s += (char)((v & 0x7f) | 0x80), v >>= 7;
    s += (char)v;
}
void len(std::string &s, int n, const std::string &b) { pv(s, (uint64_t)(n << 3 | 2)), pv(s, b.size()), s += b; }
void var(std::string &s, int n, uint64_t v) { pv(s, (uint64_t)(n << 3)), pv(s, v); }
uint32_t zz(int32_t v) { return ((uint32_t)v << 1) ^ (uint32_t)(v >> 31); }
struct Layer {
    std::string name;
    std::vector<std::string> keys, values;  // string values only
    std::string features;
    uint32_t index(std::vector<std::string> &list, const std::string &v) {
        for (size_t i = 0; i < list.size(); ++i)
            if (list[i] == v) return (uint32_t)i;
        list.push_back(v);
        return (uint32_t)list.size() - 1;
    }
    // type 1 point, 2 line, 3 polygon; points in tile units.
    void add(int type, const std::vector<std::pair<std::string, std::string>> &tags, const std::vector<std::pair<int32_t, int32_t>> &pts) {
        std::string f, t, g;
        for (const auto &[k, v] : tags) pv(t, index(keys, k)), pv(t, index(values, v));
        int32_t cx = 0, cy = 0;
        auto delta = [&](const std::pair<int32_t, int32_t> &p) {
            pv(g, zz(p.first - cx)), pv(g, zz(p.second - cy));
            cx = p.first, cy = p.second;
        };
        pv(g, 1 | (1 << 3)), delta(pts[0]);
        if (type != 1) {
            size_t n = type == 3 ? pts.size() - 2 : pts.size() - 1;  // a ring's last point isn't its first again
            pv(g, 2 | ((uint32_t)n << 3));
            for (size_t i = 1; i <= n; ++i) delta(pts[i]);
            if (type == 3) pv(g, 7 | (1 << 3));
        }
        var(f, 3, (uint64_t)type), len(f, 2, t), len(f, 4, g);
        len(features, 2, f);
    }
    std::string bytes() const {
        std::string l;
        len(l, 1, name), l += features;
        for (const auto &k : keys) len(l, 3, k);
        for (const auto &v : values) {
            std::string val;
            len(val, 1, v);
            len(l, 4, val);
        }
        var(l, 5, 4096), var(l, 15, 2);
        return l;
    }
};
}  // namespace mvtw

static int fixture(const char *out) {
    using P = std::pair<double, double>;  // lon, lat
    auto box = [](double w, double s, double e, double n) { return std::vector<P>{{w, n}, {e, n}, {e, s}, {w, s}}; };  // clockwise, y down
    std::vector<std::pair<uint64_t, std::string>> tiles;
    for (int z = 0; z <= 15; ++z) {
        double w = -89.40, s = 43.065, e = -89.37, n = 43.08;
        for (uint32_t ty = (uint32_t)tileY(n, z); ty <= (uint32_t)tileY(s, z); ++ty)
            for (uint32_t tx = (uint32_t)tileX(w, z); tx <= (uint32_t)tileX(e, z); ++tx) {
                auto at = [&](const P &p) {
                    return std::pair<int32_t, int32_t>{(int32_t)std::lround((tileX(p.first, z) - tx) * 4096),
                                                       (int32_t)std::lround((tileY(p.second, z) - ty) * 4096)};
                };
                auto ring = [&](const std::vector<P> &pts) {
                    std::vector<std::pair<int32_t, int32_t>> r;
                    for (const P &p : pts) r.push_back(at(p));
                    r.push_back(r.front());
                    return r;
                };
                mvtw::Layer earth, water, landuse, buildings, roads, places;
                earth.name = "earth", water.name = "water", landuse.name = "landuse", buildings.name = "buildings", roads.name = "roads";
                places.name = "places";
                earth.add(3, {{"kind", "earth"}}, ring(box(-89.45, 43.04, -89.33, 43.12)));
                water.add(3, {{"kind", "water"}, {"kind_detail", "lake"}}, ring(box(-89.40, 43.074, -89.39, 43.08)));
                landuse.add(3, {{"kind", "park"}}, ring(box(-89.385, 43.066, -89.38, 43.07)));
                for (int i = 0; i < 4; ++i)
                    buildings.add(3, {{"kind", "building"}}, ring(box(-89.379 + i * 0.002, 43.0715, -89.3785 + i * 0.002, 43.072)));
                roads.add(2, {{"kind", "major_road"}, {"kind_detail", "primary"}, {"name", "Test Avenue"}},
                          {at({-89.40, 43.0705}), at({-89.37, 43.0705})});
                roads.add(2, {{"kind", "minor_road"}, {"kind_detail", "residential"}, {"name", "Elm Street"}},
                          {at({-89.376, 43.065}), at({-89.376, 43.08})});
                places.add(1, {{"kind", "locality"}, {"name", "Testville"}}, {at({-89.383, 43.0735})});
                std::string tile;
                for (const mvtw::Layer *l : {&earth, &water, &landuse, &buildings, &roads, &places}) mvtw::len(tile, 3, l->bytes());
                tiles.push_back({tileId(z, tx, ty), gzip(tile)});
            }
    }
    std::sort(tiles.begin(), tiles.end());
    std::string data;
    std::vector<Entry> entries;
    for (const auto &[id, t] : tiles) entries.push_back({id, data.size(), (uint32_t)t.size(), 1}), data += t;
    std::string root = gzip(directoryBytes(entries)), meta = gzip("{\"name\":\"ADIF Lint test build (made up)\",\"version\":\"4.15.2\"}");
    Header h;
    h.rootOffset = kHeaderBytes, h.rootLength = root.size(), h.metadataOffset = kHeaderBytes + root.size(), h.metadataLength = meta.size();
    h.leafOffset = h.metadataOffset + meta.size(), h.leafLength = 0, h.dataOffset = h.leafOffset, h.dataLength = data.size();
    h.addressedTiles = h.tileEntries = h.tileContents = tiles.size(), h.clustered = true;
    h.internalCompression = h.tileCompression = kGzip, h.tileType = kMvt, h.minZoom = 0, h.maxZoom = 15;
    h.minLonE7 = -1800000000, h.minLatE7 = -850511287, h.maxLonE7 = 1800000000, h.maxLatE7 = 850511287;
    std::ofstream f(out, std::ios::binary | std::ios::trunc);
    f << headerBytes(h) << root << meta << data;
    std::printf("%zu tiles, %zu bytes\n", tiles.size(), (size_t)f.tellp());
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && std::string(argv[1]) == "fixture") return fixture(argv[2]);
    if (argc == 3 && std::string(argv[1]) == "show") return show(argv[2]);
    if (argc == 6 && std::string(argv[1]) == "layers") return layers(argv[2], std::atoi(argv[3]), std::atof(argv[4]), std::atof(argv[5]));
    if (argc >= 9 && std::string(argv[1]) == "extract") return extract(argc, argv);
    std::fprintf(stderr, "usage: pmtiles_dev show FILE | extract URL OUT WEST SOUTH EAST NORTH MAXZOOM [--dry-run]\n");
    return 2;
}
