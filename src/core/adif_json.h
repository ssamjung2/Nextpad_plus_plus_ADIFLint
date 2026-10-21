// A small JSON reader (RFC 8259) for the map's outline sources: Overpass answers, GeoJSON and
// ArcGIS query results. Numbers are doubles, strings UTF-8 (\u escapes and surrogate pairs
// decoded), object members kept in order. Bounded against hostile or broken input: at most
// 64 levels deep and `maxValues` values in all.
//
// Coordinates come in their hundreds of thousands, so arrays are packed where they can be: an
// array of numbers, of equal-length arrays of numbers ([[lon, lat], ...]), or of objects with
// just "lat" and "lon" (Overpass's geometry) keeps its numbers in one flat vector (`packed`,
// `stride` numbers an element; lat/lon objects become (lon, lat) pairs).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif::json {

struct Value {
    enum class Type : uint8_t { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string text;                                    // String
    std::vector<Value> items;                            // Array, unless packed
    std::vector<double> packed;                          // Array, packed: stride numbers an element
    uint8_t stride = 0;                                  // 0 items; 1 numbers; 2 or 3 number arrays (or lat/lon objects: 2)
    std::vector<std::pair<std::string, Value>> members;  // Object

    bool isArray() const { return type == Type::Array; }
    bool isObject() const { return type == Type::Object; }
    bool isString() const { return type == Type::String; }
    bool isNumber() const { return type == Type::Number; }
    // An array's length, packed or not.
    size_t size() const { return type != Type::Array ? 0 : stride ? packed.size() / stride : items.size(); }
    // An object's member, or nullptr.
    const Value *get(std::string_view key) const;
    // The member's text, or "" when it is missing or not a string.
    std::string str(std::string_view key) const;
};

bool parse(std::string_view text, Value *out, std::string *why, size_t maxValues = 50'000'000);

}  // namespace adif::json
