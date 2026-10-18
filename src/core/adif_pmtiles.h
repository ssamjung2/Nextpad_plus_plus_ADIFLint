// PMTiles version 3: one file of map tiles that is read by byte ranges (github.com/protomaps/
// PMTiles, spec/v3/spec.md, and go-pmtiles' directory.go, tile_id.go and extract.go, read
// 2026-10-18). The Map keeps OpenStreetMap detail for the regions the user downloads in such
// files, cut from Protomaps' daily planet build the way `pmtiles extract` does it: the header
// and root directory, then the leaf directories the region needs, then its tiles' bytes.
//
// All integers are little-endian. A directory is a varint count, then the tile-id deltas, the
// run lengths, the lengths and the offsets (offset + 1, or 0 for "right after the previous
// entry"), compressed with the archive's internal compression. A run length of 0 marks a leaf
// directory, its offset counted from the leaf directories' start.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif::pmtiles {

enum Compression : uint8_t { kCompressionUnknown = 0, kNone = 1, kGzip = 2, kBrotli = 3, kZstd = 4 };
enum TileType : uint8_t { kTypeUnknown = 0, kMvt = 1, kPng = 2, kJpeg = 3, kWebp = 4, kAvif = 5, kMlt = 6 };

constexpr size_t kHeaderBytes = 127;
constexpr size_t kFirstBytes = 16384;  // the header and the root directory are within these
constexpr int kMaxZoom = 31;

struct Header {
    uint64_t rootOffset = 0, rootLength = 0;
    uint64_t metadataOffset = 0, metadataLength = 0;
    uint64_t leafOffset = 0, leafLength = 0;
    uint64_t dataOffset = 0, dataLength = 0;
    uint64_t addressedTiles = 0, tileEntries = 0, tileContents = 0;  // 0: unknown
    bool clustered = false;
    uint8_t internalCompression = kCompressionUnknown, tileCompression = kCompressionUnknown, tileType = kTypeUnknown;
    uint8_t minZoom = 0, maxZoom = 0;
    int32_t minLonE7 = 0, minLatE7 = 0, maxLonE7 = 0, maxLatE7 = 0;  // degrees × 10,000,000
    uint8_t centerZoom = 0;
    int32_t centerLonE7 = 0, centerLatE7 = 0;
};
// The header from the first 127 bytes (or more) of an archive; false, with why, when they are not one.
bool parseHeader(std::string_view bytes, Header *h, std::string *why);
std::string headerBytes(const Header &h);

struct Entry {
    uint64_t tileId = 0;
    uint64_t offset = 0;     // a tile: from the tile data's start; a leaf: from the leaf directories' start
    uint32_t length = 0;
    uint32_t runLength = 0;  // tiles tileId .. tileId + runLength - 1 share these bytes; 0: a leaf directory
};
// A directory, already decompressed. At most maxEntries; false, with why, when malformed.
bool parseDirectory(std::string_view raw, std::vector<Entry> *out, std::string *why, size_t maxEntries = 10'000'000);
std::string directoryBytes(const std::vector<Entry> &entries);  // not compressed
// The entry that holds a tile id in a directory sorted by tile id: a tile run containing it, or
// the leaf directory to look in; nullptr when neither.
const Entry *findEntry(const std::vector<Entry> &dir, uint64_t id);

// Tile ids: zoom by zoom, each zoom's tiles along a Hilbert curve, after all the tiles of the
// zooms below ((4^z - 1) / 3 of them). 0/0/0 is 0, 1/0/0 is 1, 12/3423/1763 is 19078479.
uint64_t tileId(int z, uint32_t x, uint32_t y);
bool tileZxy(uint64_t id, int *z, uint32_t *x, uint32_t *y);

// gzip (zlib), with a limit on the inflated size.
bool gunzip(std::string_view in, std::string *out, size_t limit, std::string *why);
std::string gzip(std::string_view in);
// By the archive's compression: none or gzip (others are refused).
bool decompress(uint8_t compression, std::string_view in, std::string *out, size_t limit, std::string *why);

// Web Mercator tiles (the ones PMTiles and OpenStreetMap use): x from the west at 180° W, y
// from the north at 85.0511° N.
double tileX(double lon, int z);
double tileY(double lat, int z);
double tileLon(double x, int z);
double tileLat(double y, int z);

// The tile ids, from minZoom to maxZoom, of the tiles an area touches: rings of (lon, lat), a
// point inside an odd number of them being inside (as the Map's overlays). Sorted, each once.
std::vector<uint64_t> coveringTiles(const std::vector<std::vector<std::pair<double, double>>> &rings, int minZoom, int maxZoom);

// Cutting a region out of a big archive read by ranges, as go-pmtiles' extract does, in steps
// a caller drives (each fetch may happen anywhere, in any order):
//   1. start() with the archive's first 16 KB;
//   2. while directoryRanges() isn't empty, fetch each and give it to addDirectories();
//      metadataRange() as well, to metadata();
//   3. then tileCount() and tileBytes() say what the tiles will take, and dataRanges() are the
//      ranges of the archive to fetch (nearby tiles merged into one, with a little more read);
//   4. head() is the new archive up to its tile data; then, in dataRanges() order, the bytes
//      copyFrom(i, fetched) gives for each range follow it.
struct Range {
    uint64_t offset = 0, length = 0;
};
class Extract {
public:
    // tiles: sorted, as coveringTiles gives them. bounds: west, south, east, north for the new header.
    Extract(std::vector<uint64_t> tiles, std::array<double, 4> bounds);
    bool start(std::string_view first, std::string *why);
    const Header &source() const { return src_; }
    std::vector<Range> directoryRanges() const;  // what is still to fetch: leaf directories
    bool addDirectories(const Range &r, std::string_view bytes, std::string *why);
    Range metadataRange() const { return {src_.metadataOffset, src_.metadataLength}; }
    bool metadata(std::string_view compressed, std::string *why);
    bool planned() const { return planned_; }
    size_t tileCount() const { return tiles_.size(); }  // the tiles the archive has, of those asked for
    uint64_t tileBytes() const { return tileBytes_; }    // their bytes, each shared tile once
    std::vector<Range> dataRanges(double overfetch = 0.05) const;
    std::string head();
    // The part of a fetched data range that goes into the new archive.
    std::string copyFrom(size_t rangeIndex, std::string_view fetched) const;

private:
    bool plan(std::string *why);
    void findLeaves();
    std::vector<uint64_t> wanted_;
    std::array<double, 4> bounds_;
    Header src_;
    std::vector<Entry> root_;
    std::map<uint64_t, std::vector<Entry>> leaves_;  // by absolute offset in the archive
    std::vector<Range> pendingLeaves_;
    std::string metadata_;  // as the source compressed it
    bool haveMetadata_ = false, planned_ = false;
    struct Tile {
        uint64_t id, srcOffset;  // absolute
        uint32_t length;
    };
    std::vector<Tile> tiles_;
    struct Content {
        uint64_t srcOffset;
        uint32_t length;
    };
    std::vector<Content> contents_;  // each shared tile once, by source offset
    uint64_t tileBytes_ = 0;
    mutable std::vector<Range> ranges_;
    mutable std::vector<std::pair<size_t, size_t>> rangeContents_;  // per range: contents_[first, last)
    mutable double rangesOverfetch_ = -1;
};

// A tile archive on disk, for drawing: the header, the root directory, and the leaves read as
// needed (the last few kept). Tiles come back decompressed.
class Archive {
public:
    bool open(const std::string &path, std::string *why);
    const Header &header() const { return h_; }
    // A tile's bytes (an MVT, decompressed), or false (none there, or the file is damaged).
    bool tile(int z, uint32_t x, uint32_t y, std::string *out);
    ~Archive();

private:
    bool read(uint64_t offset, uint64_t length, std::string *out);
    bool directory(uint64_t offset, uint64_t length, std::vector<Entry> *out);
    int fd_ = -1;
    Header h_;
    std::vector<Entry> root_;
    std::vector<std::pair<uint64_t, std::vector<Entry>>> leafCache_;  // most recent last
};

}  // namespace adif::pmtiles
