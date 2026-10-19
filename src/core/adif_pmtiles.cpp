#include "adif_pmtiles.h"
#include "adif_i18n.h"

#include <zlib.h>

#include <algorithm>
#include <cmath>
#include <fcntl.h>
#include <limits>
#include <set>
#include <unistd.h>

namespace adif::pmtiles {
using adif::i18n::tr;
using adif::i18n::trf;
namespace {

uint64_t u64(std::string_view b, size_t at) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | (uint8_t)b[at + (size_t)i];
    return v;
}
uint32_t u32(std::string_view b, size_t at) {
    uint32_t v = 0;
    for (int i = 3; i >= 0; --i) v = (v << 8) | (uint8_t)b[at + (size_t)i];
    return v;
}
void put64(std::string &s, uint64_t v) {
    for (int i = 0; i < 8; ++i) s += (char)((v >> (8 * i)) & 0xff);
}
void put32(std::string &s, uint32_t v) {
    for (int i = 0; i < 4; ++i) s += (char)((v >> (8 * i)) & 0xff);
}

bool varint(std::string_view b, size_t &at, uint64_t *v) {
    uint64_t r = 0;
    for (int shift = 0; shift < 64 && at < b.size(); shift += 7) {
        uint8_t c = (uint8_t)b[at++];
        if (shift == 63 && (c & 0x7e)) return false;  // more than 64 bits
        r |= (uint64_t)(c & 0x7f) << shift;
        if (!(c & 0x80)) {
            *v = r;
            return true;
        }
    }
    return false;
}
void putVarint(std::string &s, uint64_t v) {
    while (v >= 0x80) {
        s += (char)((v & 0x7f) | 0x80);
        v >>= 7;
    }
    s += (char)v;
}

bool fail(std::string *why, std::string text) {
    if (why) *why = std::move(text);
    return false;
}

uint64_t tilesBelow(int z) { return z >= 32 ? std::numeric_limits<uint64_t>::max() / 3 : ((1ull << (2 * z)) - 1) / 3; }

void rotate(uint64_t n, uint64_t *x, uint64_t *y, uint64_t rx, uint64_t ry) {
    if (ry == 0) {
        if (rx == 1) {
            *x = n - 1 - *x;
            *y = n - 1 - *y;
        }
        std::swap(*x, *y);
    }
}

constexpr double kMaxLat = 85.0511287798066;
constexpr size_t kTargetRoot = kFirstBytes - kHeaderBytes;
constexpr size_t kLeafLimit = 64u << 20;  // a directory inflated
constexpr size_t kTileLimit = 32u << 20;  // a tile inflated

std::string compress(uint8_t compression, std::string_view raw) { return compression == kGzip ? gzip(raw) : std::string(raw); }

// go-pmtiles' optimizeDirectories: everything in the root when it fits, else leaves of at
// least 4,096 entries, more per leaf until the root of leaves fits.
void buildDirectories(const std::vector<Entry> &entries, uint8_t compression, std::string *root, std::string *leaves) {
    leaves->clear();
    if (entries.size() < 16384) {
        *root = compress(compression, directoryBytes(entries));
        if (root->size() <= kTargetRoot) return;
    }
    double leafSize = std::max(4096.0, entries.size() / 3500.0);
    for (;;) {
        std::vector<Entry> rootEntries;
        leaves->clear();
        for (size_t i = 0; i < entries.size(); i += (size_t)leafSize) {
            size_t end = std::min(entries.size(), i + (size_t)leafSize);
            std::string leaf = compress(compression, directoryBytes(std::vector<Entry>(entries.begin() + (long)i, entries.begin() + (long)end)));
            rootEntries.push_back({entries[i].tileId, (uint64_t)leaves->size(), (uint32_t)leaf.size(), 0});
            *leaves += leaf;
        }
        *root = compress(compression, directoryBytes(rootEntries));
        if (root->size() <= kTargetRoot) return;
        leafSize *= 1.2;
    }
}

}  // namespace

bool parseHeader(std::string_view b, Header *h, std::string *why) {
    if (b.size() < kHeaderBytes) return fail(why, tr("too short for a PMTiles header"));
    if (b.substr(0, 7) != "PMTiles") return fail(why, tr("not a PMTiles file"));
    if ((uint8_t)b[7] != 3) return fail(why, trf("PMTiles version {n}, not 3", {{"n", std::to_string((uint8_t)b[7])}}));
    Header r;
    r.rootOffset = u64(b, 8), r.rootLength = u64(b, 16);
    r.metadataOffset = u64(b, 24), r.metadataLength = u64(b, 32);
    r.leafOffset = u64(b, 40), r.leafLength = u64(b, 48);
    r.dataOffset = u64(b, 56), r.dataLength = u64(b, 64);
    r.addressedTiles = u64(b, 72), r.tileEntries = u64(b, 80), r.tileContents = u64(b, 88);
    r.clustered = (uint8_t)b[96] == 1;
    r.internalCompression = (uint8_t)b[97], r.tileCompression = (uint8_t)b[98], r.tileType = (uint8_t)b[99];
    r.minZoom = (uint8_t)b[100], r.maxZoom = (uint8_t)b[101];
    r.minLonE7 = (int32_t)u32(b, 102), r.minLatE7 = (int32_t)u32(b, 106), r.maxLonE7 = (int32_t)u32(b, 110), r.maxLatE7 = (int32_t)u32(b, 114);
    r.centerZoom = (uint8_t)b[118];
    r.centerLonE7 = (int32_t)u32(b, 119), r.centerLatE7 = (int32_t)u32(b, 123);
    if (r.minZoom > r.maxZoom || r.maxZoom > kMaxZoom) return fail(why, tr("zooms out of range"));
    const uint64_t kMax = std::numeric_limits<uint64_t>::max();
    for (auto [o, l] : {std::pair{r.rootOffset, r.rootLength}, {r.metadataOffset, r.metadataLength}, {r.leafOffset, r.leafLength},
                        {r.dataOffset, r.dataLength}})
        if (o > kMax - l) return fail(why, tr("a section runs past the end of any file"));
    if (r.rootLength == 0) return fail(why, tr("no root directory"));
    *h = r;
    return true;
}

std::string headerBytes(const Header &h) {
    std::string s = "PMTiles";
    s += (char)3;
    for (uint64_t v : {h.rootOffset, h.rootLength, h.metadataOffset, h.metadataLength, h.leafOffset, h.leafLength, h.dataOffset, h.dataLength,
                       h.addressedTiles, h.tileEntries, h.tileContents})
        put64(s, v);
    s += (char)(h.clustered ? 1 : 0);
    s += (char)h.internalCompression, s += (char)h.tileCompression, s += (char)h.tileType;
    s += (char)h.minZoom, s += (char)h.maxZoom;
    for (int32_t v : {h.minLonE7, h.minLatE7, h.maxLonE7, h.maxLatE7}) put32(s, (uint32_t)v);
    s += (char)h.centerZoom;
    put32(s, (uint32_t)h.centerLonE7), put32(s, (uint32_t)h.centerLatE7);
    return s;
}

bool parseDirectory(std::string_view raw, std::vector<Entry> *out, std::string *why, size_t maxEntries) {
    size_t at = 0;
    uint64_t n = 0;
    if (!varint(raw, at, &n) || n == 0) return fail(why, tr("a directory with no entries"));
    if (n > maxEntries || n > raw.size()) return fail(why, tr("a directory with too many entries"));  // each takes 4 bytes or more
    std::vector<Entry> e((size_t)n);
    uint64_t last = 0, v = 0;
    for (size_t i = 0; i < e.size(); ++i) {
        if (!varint(raw, at, &v) || (i > 0 && v == 0) || last > std::numeric_limits<uint64_t>::max() - v)
            return fail(why, tr("a directory's tile ids are damaged"));
        e[i].tileId = last += v;
    }
    for (Entry &x : e) {
        if (!varint(raw, at, &v) || v > std::numeric_limits<uint32_t>::max()) return fail(why, tr("a directory's run lengths are damaged"));
        x.runLength = (uint32_t)v;
    }
    for (Entry &x : e) {
        if (!varint(raw, at, &v) || v == 0 || v > std::numeric_limits<uint32_t>::max()) return fail(why, tr("a directory's lengths are damaged"));
        x.length = (uint32_t)v;
    }
    for (size_t i = 0; i < e.size(); ++i) {
        if (!varint(raw, at, &v)) return fail(why, tr("a directory's offsets are damaged"));
        if (v == 0) {
            if (i == 0) return fail(why, tr("a directory's first offset is missing"));
            e[i].offset = e[i - 1].offset + e[i - 1].length;
        } else {
            e[i].offset = v - 1;
        }
    }
    *out = std::move(e);
    return true;
}

std::string directoryBytes(const std::vector<Entry> &entries) {
    std::string s;
    putVarint(s, entries.size());
    uint64_t last = 0;
    for (const Entry &e : entries) putVarint(s, e.tileId - last), last = e.tileId;
    for (const Entry &e : entries) putVarint(s, e.runLength);
    for (const Entry &e : entries) putVarint(s, e.length);
    for (size_t i = 0; i < entries.size(); ++i)
        putVarint(s, i > 0 && entries[i].offset == entries[i - 1].offset + entries[i - 1].length ? 0 : entries[i].offset + 1);
    return s;
}

const Entry *findEntry(const std::vector<Entry> &dir, uint64_t id) {
    auto it = std::upper_bound(dir.begin(), dir.end(), id, [](uint64_t v, const Entry &e) { return v < e.tileId; });
    if (it == dir.begin()) return nullptr;
    const Entry &e = *(it - 1);
    if (e.runLength == 0 || id - e.tileId < e.runLength) return &e;
    return nullptr;
}

uint64_t tileId(int z, uint32_t x, uint32_t y) {
    if (z < 0 || z > kMaxZoom) return 0;
    uint64_t n = 1ull << z, tx = x, ty = y, d = 0;
    if (tx >= n || ty >= n) return 0;
    for (uint64_t s = n / 2; s > 0; s /= 2) {
        uint64_t rx = (tx & s) ? 1 : 0, ry = (ty & s) ? 1 : 0;
        d += s * s * ((3 * rx) ^ ry);
        rotate(n, &tx, &ty, rx, ry);
    }
    return tilesBelow(z) + d;
}

bool tileZxy(uint64_t id, int *z, uint32_t *x, uint32_t *y) {
    int zoom = 0;
    while (zoom < kMaxZoom && id >= tilesBelow(zoom + 1)) ++zoom;
    if (id >= tilesBelow(zoom + 1)) return false;
    uint64_t n = 1ull << zoom, t = id - tilesBelow(zoom), tx = 0, ty = 0;
    for (uint64_t s = 1; s < n; s *= 2) {
        uint64_t rx = 1 & (t / 2), ry = 1 & (t ^ rx);
        rotate(s, &tx, &ty, rx, ry);
        tx += s * rx, ty += s * ry;
        t /= 4;
    }
    *z = zoom, *x = (uint32_t)tx, *y = (uint32_t)ty;
    return true;
}

bool gunzip(std::string_view in, std::string *out, size_t limit, std::string *why) {
    z_stream z{};
    if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return fail(why, tr("zlib would not start"));
    z.next_in = (Bytef *)in.data();
    z.avail_in = (uInt)std::min(in.size(), (size_t)std::numeric_limits<uInt>::max());
    std::string r;
    char buf[1 << 16];
    for (;;) {
        z.next_out = (Bytef *)buf;
        z.avail_out = sizeof buf;
        int st = inflate(&z, Z_NO_FLUSH);
        r.append(buf, sizeof buf - z.avail_out);
        if (r.size() > limit) {
            inflateEnd(&z);
            return fail(why, tr("inflates to more than expected"));
        }
        if (st == Z_STREAM_END) break;
        if (st != Z_OK || (z.avail_in == 0 && z.avail_out != 0)) {
            inflateEnd(&z);
            return fail(why, tr("damaged or cut-off gzip data"));
        }
    }
    inflateEnd(&z);
    *out = std::move(r);
    return true;
}

std::string gzip(std::string_view in) {
    z_stream z{};
    if (deflateInit2(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return std::string();
    std::string out(deflateBound(&z, (uLong)in.size()) + 32, '\0');
    z.next_in = (Bytef *)in.data();
    z.avail_in = (uInt)in.size();
    z.next_out = (Bytef *)out.data();
    z.avail_out = (uInt)out.size();
    deflate(&z, Z_FINISH);
    out.resize(z.total_out);
    deflateEnd(&z);
    return out;
}

bool decompress(uint8_t compression, std::string_view in, std::string *out, size_t limit, std::string *why) {
    if (compression == kNone) {
        if (in.size() > limit) return fail(why, tr("larger than expected"));
        *out = std::string(in);
        return true;
    }
    if (compression == kGzip) return gunzip(in, out, limit, why);
    return fail(why, tr("compressed in a way ADIF Lint can't read (only gzip)"));
}

double tileX(double lon, int z) { return (lon + 180) / 360 * std::ldexp(1.0, z); }
double tileY(double lat, int z) {
    double r = std::clamp(lat, -kMaxLat, kMaxLat) * M_PI / 180;
    return (1 - std::asinh(std::tan(r)) / M_PI) / 2 * std::ldexp(1.0, z);
}
double tileLon(double x, int z) { return x / std::ldexp(1.0, z) * 360 - 180; }
double tileLat(double y, int z) { return std::atan(std::sinh(M_PI * (1 - 2 * y / std::ldexp(1.0, z)))) * 180 / M_PI; }

std::vector<uint64_t> coveringTiles(const std::vector<std::vector<std::pair<double, double>>> &rings, int minZoom, int maxZoom) {
    std::vector<uint64_t> out;
    if (minZoom < 0 || maxZoom > 20 || minZoom > maxZoom) return out;
    const int z = maxZoom;
    const long n = 1L << z;
    struct P {
        double x, y;
    };
    std::vector<std::pair<P, P>> edges;
    long top = n, bottom = -1;
    for (const auto &ring : rings) {
        if (ring.size() < 2) continue;
        for (size_t i = 0; i < ring.size(); ++i) {
            const auto &a = ring[i], &b = ring[(i + 1) % ring.size()];
            P pa{tileX(a.first, z), tileY(a.second, z)}, pb{tileX(b.first, z), tileY(b.second, z)};
            edges.push_back({pa, pb});
            for (const P &p : {pa, pb}) {
                long row = std::clamp((long)std::floor(p.y), 0L, n - 1);
                top = std::min(top, row), bottom = std::max(bottom, row);
            }
        }
    }
    if (edges.empty()) return out;
    std::map<long, std::vector<std::pair<long, long>>> spans;  // row -> [x0, x1] spans, inclusive
    auto mark = [&](long x, long y) {
        if (x >= 0 && x < n && y >= 0 && y < n) spans[y].push_back({x, x});
    };
    // The tiles each edge passes through (a grid walk along the segment).
    for (const auto &[a, b] : edges) {
        long cx = (long)std::floor(a.x), cy = (long)std::floor(a.y), ex = (long)std::floor(b.x), ey = (long)std::floor(b.y);
        double dx = b.x - a.x, dy = b.y - a.y;
        long stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1;
        const double inf = std::numeric_limits<double>::infinity();
        double tMaxX = dx != 0 ? (stepX > 0 ? cx + 1 - a.x : a.x - cx) / std::fabs(dx) : inf;
        double tMaxY = dy != 0 ? (stepY > 0 ? cy + 1 - a.y : a.y - cy) / std::fabs(dy) : inf;
        double tDeltaX = dx != 0 ? 1 / std::fabs(dx) : inf, tDeltaY = dy != 0 ? 1 / std::fabs(dy) : inf;
        mark(cx, cy);
        for (long steps = std::labs(ex - cx) + std::labs(ey - cy) + 2; (cx != ex || cy != ey) && steps > 0; --steps) {
            if (tMaxX < tMaxY) tMaxX += tDeltaX, cx += stepX;
            else tMaxY += tDeltaY, cy += stepY;
            mark(cx, cy);
        }
        mark(ex, ey);
    }
    // Inside: along each row's middle, between pairs of crossings (even-odd).
    std::vector<double> xs;
    for (long row = top; row <= bottom; ++row) {
        double yc = row + 0.5;
        xs.clear();
        for (const auto &[a, b] : edges)
            if ((a.y <= yc) != (b.y <= yc)) xs.push_back(a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y));
        std::sort(xs.begin(), xs.end());
        for (size_t i = 0; i + 1 < xs.size(); i += 2) {
            long x0 = std::clamp((long)std::floor(xs[i]), 0L, n - 1), x1 = std::clamp((long)std::floor(xs[i + 1]), 0L, n - 1);
            if (x0 <= x1) spans[row].push_back({x0, x1});
        }
    }
    std::set<uint64_t> lower;
    for (auto &rowSpans : spans) {
        const long row = rowSpans.first;
        std::vector<std::pair<long, long>> &list = rowSpans.second;
        std::sort(list.begin(), list.end());
        long cur0 = -2, cur1 = -2;
        auto flush = [&]() {
            for (long x = cur0; cur0 >= 0 && x <= cur1; ++x) {
                out.push_back(tileId(z, (uint32_t)x, (uint32_t)row));
                for (int k = 1; z - k >= minZoom; ++k) lower.insert(tileId(z - k, (uint32_t)(x >> k), (uint32_t)(row >> k)));
            }
        };
        for (const auto &[x0, x1] : list) {
            if (x0 <= cur1 + 1) cur1 = std::max(cur1, x1);
            else flush(), cur0 = x0, cur1 = x1;
        }
        flush();
    }
    out.insert(out.end(), lower.begin(), lower.end());
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

// ── Extract ──────────────────────────────────────────────────────────────────

Extract::Extract(std::vector<uint64_t> tiles, std::array<double, 4> bounds) : wanted_(std::move(tiles)), bounds_(bounds) {
    std::sort(wanted_.begin(), wanted_.end());
    wanted_.erase(std::unique(wanted_.begin(), wanted_.end()), wanted_.end());
}

bool Extract::start(std::string_view first, std::string *why) {
    if (!parseHeader(first, &src_, why)) return false;
    if (!src_.clustered) return fail(why, tr("the archive isn't clustered, so it can't be cut by ranges"));
    if (src_.internalCompression != kGzip && src_.internalCompression != kNone) return fail(why, tr("its directories aren't gzip"));
    if (src_.rootOffset + src_.rootLength > first.size()) return fail(why, tr("its root directory isn't in the bytes given"));
    std::string raw;
    if (!decompress(src_.internalCompression, first.substr(src_.rootOffset, src_.rootLength), &raw, kLeafLimit, why) ||
        !parseDirectory(raw, &root_, why))
        return false;
    findLeaves();
    if (pendingLeaves_.empty() && haveMetadata_) return plan(why);
    return true;
}

std::vector<Range> Extract::directoryRanges() const {
    // Leaves next to each other in one request, up to 8 MB each.
    std::vector<Range> out;
    for (const Range &r : pendingLeaves_) {
        if (!out.empty() && r.offset >= out.back().offset + out.back().length && r.offset - (out.back().offset + out.back().length) <= 65536 &&
            r.offset + r.length - out.back().offset <= (8u << 20))
            out.back().length = r.offset + r.length - out.back().offset;
        else
            out.push_back(r);
    }
    return out;
}

// The leaf directories still to read for the wanted tiles (directoryRanges asks for them).
void Extract::findLeaves() {
    pendingLeaves_.clear();
    std::set<std::pair<uint64_t, uint64_t>> pending;
    for (uint64_t id : wanted_) {
        const std::vector<Entry> *dir = &root_;
        for (int depth = 0; depth < 4; ++depth) {
            const Entry *e = findEntry(*dir, id);
            if (!e || e->runLength > 0) break;
            uint64_t at = src_.leafOffset + e->offset;
            auto it = leaves_.find(at);
            if (it == leaves_.end()) {
                pending.insert({at, e->length});
                break;
            }
            dir = &it->second;
        }
    }
    for (const auto &[o, l] : pending) pendingLeaves_.push_back({o, l});
}

bool Extract::addDirectories(const Range &r, std::string_view bytes, std::string *why) {
    if (bytes.size() != r.length) return fail(why, tr("the server sent a different length than asked for"));
    std::vector<Range> still;
    for (const Range &leaf : pendingLeaves_) {
        if (leaf.offset < r.offset || leaf.offset + leaf.length > r.offset + r.length) {
            still.push_back(leaf);
            continue;
        }
        std::string raw;
        std::vector<Entry> entries;
        if (!decompress(src_.internalCompression, bytes.substr(leaf.offset - r.offset, leaf.length), &raw, kLeafLimit, why) ||
            !parseDirectory(raw, &entries, why))
            return false;
        leaves_[leaf.offset] = std::move(entries);
    }
    pendingLeaves_ = std::move(still);
    if (!pendingLeaves_.empty()) return true;
    findLeaves();  // leaves of leaves, if any
    if (pendingLeaves_.empty() && haveMetadata_) return plan(why);
    return true;
}

bool Extract::metadata(std::string_view compressed, std::string *why) {
    if (compressed.size() != src_.metadataLength) return fail(why, tr("the metadata came back the wrong length"));
    std::string raw;
    if (!decompress(src_.internalCompression, compressed, &raw, kLeafLimit, why)) return false;
    metadata_ = std::string(compressed);
    haveMetadata_ = true;
    if (!root_.empty() && pendingLeaves_.empty()) return plan(why);
    return true;
}

bool Extract::plan(std::string *why) {
    tiles_.clear();
    contents_.clear();
    std::map<uint64_t, uint32_t> contentOf;
    for (uint64_t id : wanted_) {
        const std::vector<Entry> *dir = &root_;
        for (int depth = 0; depth < 4; ++depth) {
            const Entry *e = findEntry(*dir, id);
            if (!e) break;
            if (e->runLength > 0) {
                uint64_t at = src_.dataOffset + e->offset;
                if (e->offset + e->length > src_.dataLength) return fail(why, tr("a tile lies outside the tile data"));
                tiles_.push_back({id, at, e->length});
                contentOf.emplace(at, e->length);
                break;
            }
            auto it = leaves_.find(src_.leafOffset + e->offset);
            if (it == leaves_.end()) return fail(why, tr("a leaf directory wasn't read"));
            dir = &it->second;
        }
    }
    tileBytes_ = 0;
    for (const auto &[o, l] : contentOf) contents_.push_back({o, l}), tileBytes_ += l;
    rangesOverfetch_ = -1;
    planned_ = true;
    return true;
}

std::vector<Range> Extract::dataRanges(double overfetch) const {
    if (rangesOverfetch_ == overfetch) return ranges_;
    ranges_.clear();
    rangeContents_.clear();
    rangesOverfetch_ = overfetch;
    if (contents_.empty()) return ranges_;
    // go-pmtiles' mergeRanges: join across the smallest gaps first, until the extra bytes read
    // reach overfetch × the tiles' bytes. Each request stays under 16 MB.
    size_t n = contents_.size();
    std::vector<uint64_t> gap(n, 0);
    std::vector<size_t> order;
    for (size_t i = 1; i < n; ++i) {
        gap[i] = contents_[i].srcOffset - (contents_[i - 1].srcOffset + contents_[i - 1].length);
        order.push_back(i);
    }
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return gap[a] < gap[b]; });
    std::vector<bool> joined(n, false);  // joined[i]: content i goes in the same request as i - 1
    double budget = overfetch * (double)tileBytes_;
    for (size_t i : order) {
        if (gap[i] == 0) joined[i] = true;
        else if ((double)gap[i] <= budget) joined[i] = true, budget -= (double)gap[i];
        else break;
    }
    const uint64_t kMaxRequest = 16u << 20;
    for (size_t i = 0; i < n; ++i) {
        const Content &c = contents_[i];
        if (i > 0 && joined[i] && c.srcOffset + c.length - ranges_.back().offset <= kMaxRequest) {
            ranges_.back().length = c.srcOffset + c.length - ranges_.back().offset;
            rangeContents_.back().second = i + 1;
        } else {
            ranges_.push_back({c.srcOffset, c.length});
            rangeContents_.push_back({i, i + 1});
        }
    }
    return ranges_;
}

std::string Extract::head() {
    // The new archive's offsets: each shared tile once, in the order of the source (clustered).
    std::map<uint64_t, uint64_t> newOffset;
    uint64_t at = 0;
    for (const Content &c : contents_) newOffset[c.srcOffset] = at, at += c.length;
    std::vector<Entry> entries;
    int minZ = kMaxZoom, maxZ = 0;
    for (const Tile &t : tiles_) {
        uint64_t o = newOffset[t.srcOffset];
        int z = 0;
        uint32_t x = 0, y = 0;
        if (tileZxy(t.id, &z, &x, &y)) minZ = std::min(minZ, z), maxZ = std::max(maxZ, z);
        if (!entries.empty()) {
            Entry &b = entries.back();
            if (b.offset == o && b.length == t.length && b.tileId + b.runLength == t.id) {
                ++b.runLength;
                continue;
            }
        }
        entries.push_back({t.id, o, t.length, 1});
    }
    Header h = src_;
    std::string root, leaves;
    if (entries.empty()) entries.push_back({0, 0, 1, 0});  // never written: an archive needs a root entry
    buildDirectories(entries, src_.internalCompression, &root, &leaves);
    h.rootOffset = kHeaderBytes, h.rootLength = root.size();
    h.metadataOffset = h.rootOffset + h.rootLength, h.metadataLength = metadata_.size();
    h.leafOffset = h.metadataOffset + h.metadataLength, h.leafLength = leaves.size();
    h.dataOffset = h.leafOffset + h.leafLength, h.dataLength = tileBytes_;
    h.addressedTiles = tiles_.size(), h.tileEntries = entries.size(), h.tileContents = contents_.size();
    h.clustered = true;
    h.minZoom = (uint8_t)(tiles_.empty() ? 0 : minZ), h.maxZoom = (uint8_t)(tiles_.empty() ? 0 : maxZ);
    auto e7 = [](double d) { return (int32_t)std::lround(d * 1e7); };
    h.minLonE7 = e7(bounds_[0]), h.minLatE7 = e7(bounds_[1]), h.maxLonE7 = e7(bounds_[2]), h.maxLatE7 = e7(bounds_[3]);
    h.centerZoom = (uint8_t)std::max<int>(h.minZoom, std::min<int>(h.maxZoom, 10));
    h.centerLonE7 = e7((bounds_[0] + bounds_[2]) / 2), h.centerLatE7 = e7((bounds_[1] + bounds_[3]) / 2);
    return headerBytes(h) + root + metadata_ + leaves;
}

std::string Extract::copyFrom(size_t rangeIndex, std::string_view fetched) const {
    std::string out;
    if (rangeIndex >= ranges_.size() || fetched.size() != ranges_[rangeIndex].length) return out;
    const Range &r = ranges_[rangeIndex];
    for (size_t i = rangeContents_[rangeIndex].first; i < rangeContents_[rangeIndex].second; ++i)
        out.append(fetched.substr(contents_[i].srcOffset - r.offset, contents_[i].length));
    return out;
}

// ── Archive ──────────────────────────────────────────────────────────────────

Archive::~Archive() {
    if (fd_ >= 0) ::close(fd_);
}

bool Archive::read(uint64_t offset, uint64_t length, std::string *out) {
    out->resize((size_t)length);
    uint64_t done = 0;
    while (done < length) {
        ssize_t n = ::pread(fd_, out->data() + done, (size_t)(length - done), (off_t)(offset + done));
        if (n <= 0) return false;
        done += (uint64_t)n;
    }
    return true;
}

bool Archive::open(const std::string &path, std::string *why) {
    if (fd_ >= 0) ::close(fd_);
    root_.clear();
    leafCache_.clear();
    fd_ = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd_ < 0) return fail(why, trf("can't open {path}", {{"path", path}}));
    off_t size = ::lseek(fd_, 0, SEEK_END);
    std::string first;
    if (size < (off_t)kHeaderBytes || !read(0, std::min<uint64_t>((uint64_t)size, kFirstBytes), &first) || !parseHeader(first, &h_, why))
        return fail(why, why && !why->empty() ? *why : tr("not a PMTiles file"));
    for (auto [o, l] : {std::pair{h_.rootOffset, h_.rootLength}, {h_.leafOffset, h_.leafLength}, {h_.dataOffset, h_.dataLength}})
        if (o + l > (uint64_t)size) return fail(why, tr("the file is cut short"));
    if (!directory(h_.rootOffset, h_.rootLength, &root_)) return fail(why, tr("its root directory is damaged"));
    return true;
}

bool Archive::directory(uint64_t offset, uint64_t length, std::vector<Entry> *out) {
    std::string bytes, raw;
    return length <= kLeafLimit && read(offset, length, &bytes) && decompress(h_.internalCompression, bytes, &raw, kLeafLimit, nullptr) &&
           parseDirectory(raw, out, nullptr);
}

bool Archive::tile(int z, uint32_t x, uint32_t y, std::string *out) {
    if (fd_ < 0 || z < h_.minZoom || z > h_.maxZoom) return false;
    uint64_t id = tileId(z, x, y);
    const std::vector<Entry> *dir = &root_;
    for (int depth = 0; depth < 4; ++depth) {
        const Entry *e = findEntry(*dir, id);
        if (!e) return false;
        if (e->runLength > 0) {
            std::string bytes;
            return e->offset + e->length <= h_.dataLength && read(h_.dataOffset + e->offset, e->length, &bytes) &&
                   decompress(h_.tileCompression, bytes, out, kTileLimit, nullptr);
        }
        uint64_t at = h_.leafOffset + e->offset;
        auto it = std::find_if(leafCache_.begin(), leafCache_.end(), [&](const auto &p) { return p.first == at; });
        if (it == leafCache_.end()) {
            std::vector<Entry> leaf;
            if (e->offset + e->length > h_.leafLength || !directory(at, e->length, &leaf)) return false;
            if (leafCache_.size() >= 64) leafCache_.erase(leafCache_.begin());
            leafCache_.push_back({at, std::move(leaf)});
            it = leafCache_.end() - 1;
        } else if (it != leafCache_.end() - 1) {  // most recent last
            auto keep = std::move(*it);
            leafCache_.erase(it);
            leafCache_.push_back(std::move(keep));
            it = leafCache_.end() - 1;
        }
        dir = &it->second;
    }
    return false;
}

}  // namespace adif::pmtiles
