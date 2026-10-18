// Mapbox Vector Tiles, version 2.1 (github.com/mapbox/vector-tile-spec, 2.1/README.md and
// vector_tile.proto, read 2026-10-18): the tiles in the Map's PMTiles files. A tile is a
// protobuf message of layers (Tile.layers = 3); a layer has a name (1), features (2), keys (3),
// values (4), an extent (5, 4096 when absent) and a version (15); a feature an id (1), tags (2,
// pairs of key and value indexes), a type (3: point 1, line 2, polygon 3) and its geometry (4).
// Geometry is commands: (id & 7) | (count << 3), MoveTo 1 and LineTo 2 each followed by count
// pairs of zigzag deltas from a cursor that starts at 0,0 for each feature, ClosePath 7. A
// polygon ring with positive area (y down) is an exterior, and starts a new polygon; negative
// is a hole in it.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif::mvt {

enum class GeomType : uint8_t { Unknown = 0, Point = 1, Line = 2, Polygon = 3 };

struct Value {
    enum Kind : uint8_t { None, String, Number, Bool } kind = None;
    std::string text;   // String
    double number = 0;  // Number (float, double and the integer kinds)
    bool flag = false;  // Bool
};

struct Feature {
    uint64_t id = 0;
    GeomType type = GeomType::Unknown;
    std::vector<uint32_t> tags;      // key index, value index, ...
    std::vector<uint32_t> geometry;  // the commands, as stored
};

struct Layer {
    std::string name;
    uint32_t extent = 4096, version = 1;
    std::vector<std::string> keys;
    std::vector<Value> values;
    std::vector<Feature> features;
    // A feature's value for a key, or nullptr.
    const Value *get(const Feature &f, std::string_view key) const;
    std::string text(const Feature &f, std::string_view key) const;  // a string value, or ""
    double number(const Feature &f, std::string_view key, double fallback) const;
};

// The layers of a tile; false, with why, when it isn't one. Unknown fields are skipped.
bool decode(std::string_view tile, std::vector<Layer> *out, std::string *why);

// A feature's geometry in the layer's tile units (0 to extent, and a little past for the
// buffer). Points: one path of the points. Lines: a path each. Polygons: a ring each, closed
// implicitly, with exterior true for the outer rings (positive area by the surveyor's formula,
// y down) and false for holes. False when the commands are malformed.
struct Path {
    std::vector<std::pair<int32_t, int32_t>> points;
    bool exterior = true;
};
bool geometry(const Feature &f, std::vector<Path> *out);

}  // namespace adif::mvt
