#include "adif_mvt.h"

#include <cstring>
#include <limits>

namespace adif::mvt {
namespace {

// Protocol buffers' wire format (protobuf.dev, encoding): each field a varint key, number << 3
// | wire type; 0 varint, 1 eight bytes, 2 a varint length then the bytes, 5 four bytes.
struct Reader {
    std::string_view b;
    size_t at = 0;
    bool done() const { return at >= b.size(); }
    bool varint(uint64_t *v) {
        uint64_t r = 0;
        for (int shift = 0; shift < 64 && at < b.size(); shift += 7) {
            uint8_t c = (uint8_t)b[at++];
            r |= (uint64_t)(c & 0x7f) << shift;
            if (!(c & 0x80)) {
                *v = r;
                return true;
            }
        }
        return false;
    }
    bool key(uint32_t *number, uint32_t *wire) {
        uint64_t k = 0;
        if (!varint(&k) || (k >> 3) == 0 || (k >> 3) > std::numeric_limits<uint32_t>::max()) return false;
        *number = (uint32_t)(k >> 3), *wire = (uint32_t)(k & 7);
        return true;
    }
    bool bytes(std::string_view *out) {
        uint64_t n = 0;
        if (!varint(&n) || n > b.size() - at) return false;
        *out = b.substr(at, (size_t)n);
        at += (size_t)n;
        return true;
    }
    bool fixed(size_t n, uint64_t *v) {
        if (n > b.size() - at) return false;
        uint64_t r = 0;
        for (size_t i = 0; i < n; ++i) r |= (uint64_t)(uint8_t)b[at + i] << (8 * i);
        at += n;
        *v = r;
        return true;
    }
    bool skip(uint32_t wire) {
        uint64_t v = 0;
        std::string_view s;
        switch (wire) {
            case 0: return varint(&v);
            case 1: return fixed(8, &v);
            case 2: return bytes(&s);
            case 5: return fixed(4, &v);
            default: return false;  // groups (3, 4) aren't used by vector tiles
        }
    }
};

// A repeated uint32: packed (wire type 2), or one value (wire type 0).
bool repeated(Reader &r, uint32_t wire, std::vector<uint32_t> *out) {
    uint64_t v = 0;
    if (wire == 0) {
        if (!r.varint(&v) || v > std::numeric_limits<uint32_t>::max()) return false;
        out->push_back((uint32_t)v);
        return true;
    }
    std::string_view p;
    if (wire != 2 || !r.bytes(&p)) return false;
    Reader q{p};
    while (!q.done()) {
        if (!q.varint(&v) || v > std::numeric_limits<uint32_t>::max()) return false;
        out->push_back((uint32_t)v);
    }
    return true;
}

bool decodeValue(std::string_view b, Value *v) {
    Reader r{b};
    uint32_t n = 0, wire = 0;
    uint64_t x = 0;
    while (!r.done()) {
        if (!r.key(&n, &wire)) return false;
        if (n == 1 && wire == 2) {
            std::string_view s;
            if (!r.bytes(&s)) return false;
            v->kind = Value::String, v->text = std::string(s);
        } else if (n == 2 && wire == 5) {
            if (!r.fixed(4, &x)) return false;
            uint32_t bits = (uint32_t)x;
            float f;
            std::memcpy(&f, &bits, 4);
            v->kind = Value::Number, v->number = f;
        } else if (n == 3 && wire == 1) {
            if (!r.fixed(8, &x)) return false;
            double d;
            std::memcpy(&d, &x, 8);
            v->kind = Value::Number, v->number = d;
        } else if ((n == 4 || n == 5 || n == 6 || n == 7) && wire == 0) {
            if (!r.varint(&x)) return false;
            if (n == 4) v->kind = Value::Number, v->number = (double)(int64_t)x;
            else if (n == 5) v->kind = Value::Number, v->number = (double)x;
            else if (n == 6) v->kind = Value::Number, v->number = (double)(int64_t)((x >> 1) ^ (~(x & 1) + 1));
            else v->kind = Value::Bool, v->flag = x != 0;
        } else if (!r.skip(wire)) {
            return false;
        }
    }
    return true;
}

bool decodeFeature(std::string_view b, Feature *f) {
    Reader r{b};
    uint32_t n = 0, wire = 0;
    uint64_t x = 0;
    while (!r.done()) {
        if (!r.key(&n, &wire)) return false;
        if (n == 1 && wire == 0) {
            if (!r.varint(&f->id)) return false;
        } else if (n == 2) {
            if (!repeated(r, wire, &f->tags)) return false;
        } else if (n == 3 && wire == 0) {
            if (!r.varint(&x)) return false;
            f->type = x <= 3 ? (GeomType)x : GeomType::Unknown;
        } else if (n == 4) {
            if (!repeated(r, wire, &f->geometry)) return false;
        } else if (!r.skip(wire)) {
            return false;
        }
    }
    return f->tags.size() % 2 == 0;
}

bool decodeLayer(std::string_view b, Layer *l) {
    Reader r{b};
    uint32_t n = 0, wire = 0;
    uint64_t x = 0;
    std::string_view s;
    bool named = false;
    while (!r.done()) {
        if (!r.key(&n, &wire)) return false;
        if (n == 1 && wire == 2) {
            if (!r.bytes(&s)) return false;
            l->name = std::string(s), named = true;
        } else if (n == 2 && wire == 2) {
            Feature f;
            if (!r.bytes(&s) || !decodeFeature(s, &f)) return false;
            l->features.push_back(std::move(f));
        } else if (n == 3 && wire == 2) {
            if (!r.bytes(&s)) return false;
            l->keys.emplace_back(s);
        } else if (n == 4 && wire == 2) {
            Value v;
            if (!r.bytes(&s) || !decodeValue(s, &v)) return false;
            l->values.push_back(std::move(v));
        } else if (n == 5 && wire == 0) {
            if (!r.varint(&x) || x == 0 || x > (1u << 24)) return false;
            l->extent = (uint32_t)x;
        } else if (n == 15 && wire == 0) {
            if (!r.varint(&x)) return false;
            l->version = (uint32_t)x;
        } else if (!r.skip(wire)) {
            return false;
        }
    }
    return named;
}

int32_t zigzag(uint32_t p) { return (int32_t)((p >> 1) ^ (~(p & 1) + 1)); }

}  // namespace

const Value *Layer::get(const Feature &f, std::string_view key) const {
    for (size_t i = 0; i + 1 < f.tags.size(); i += 2)
        if (f.tags[i] < keys.size() && keys[f.tags[i]] == key) return f.tags[i + 1] < values.size() ? &values[f.tags[i + 1]] : nullptr;
    return nullptr;
}

std::string Layer::text(const Feature &f, std::string_view key) const {
    const Value *v = get(f, key);
    return v && v->kind == Value::String ? v->text : std::string();
}

double Layer::number(const Feature &f, std::string_view key, double fallback) const {
    const Value *v = get(f, key);
    return v && v->kind == Value::Number ? v->number : fallback;
}

bool decode(std::string_view tile, std::vector<Layer> *out, std::string *why) {
    out->clear();
    Reader r{tile};
    uint32_t n = 0, wire = 0;
    while (!r.done()) {
        if (!r.key(&n, &wire)) {
            if (why) *why = "not a vector tile";
            return false;
        }
        if (n == 3 && wire == 2) {
            std::string_view s;
            Layer l;
            if (!r.bytes(&s) || !decodeLayer(s, &l)) {
                if (why) *why = "a damaged layer";
                return false;
            }
            out->push_back(std::move(l));
        } else if (!r.skip(wire)) {
            if (why) *why = "a damaged field";
            return false;
        }
    }
    return true;
}

bool geometry(const Feature &f, std::vector<Path> *out) {
    out->clear();
    const std::vector<uint32_t> &g = f.geometry;
    int64_t x = 0, y = 0;
    size_t i = 0;
    auto point = [&]() {
        if (i + 2 > g.size()) return false;
        x += zigzag(g[i]), y += zigzag(g[i + 1]);
        i += 2;
        if (x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX) return false;
        return true;
    };
    Path *open = nullptr;
    while (i < g.size()) {
        uint32_t cmd = g[i++], id = cmd & 7, count = cmd >> 3;
        if (id == 1) {
            if (f.type == GeomType::Point) {
                if (out->empty()) out->push_back({});
                for (uint32_t k = 0; k < count; ++k) {
                    if (!point()) return false;
                    out->back().points.push_back({(int32_t)x, (int32_t)y});
                }
                continue;
            }
            for (uint32_t k = 0; k < count; ++k) {
                if (!point()) return false;
                out->push_back({});
                out->back().points.push_back({(int32_t)x, (int32_t)y});
            }
            open = out->empty() ? nullptr : &out->back();
        } else if (id == 2) {
            if (!open || count == 0) return false;
            for (uint32_t k = 0; k < count; ++k) {
                if (!point()) return false;
                open->points.push_back({(int32_t)x, (int32_t)y});
            }
        } else if (id == 7) {
            if (!open) return false;
            open = nullptr;
        } else {
            return false;
        }
    }
    if (f.type == GeomType::Polygon) {
        std::vector<Path> rings;
        for (Path &p : *out) {
            if (p.points.size() < 3) continue;
            double a = 0;
            for (size_t k = 0; k < p.points.size(); ++k) {
                const auto &[x0, y0] = p.points[k];
                const auto &[x1, y1] = p.points[(k + 1) % p.points.size()];
                a += (double)x0 * y1 - (double)x1 * y0;
            }
            if (a == 0) continue;  // no area: nothing to fill
            p.exterior = a > 0;
            rings.push_back(std::move(p));
        }
        *out = std::move(rings);
    }
    return true;
}

}  // namespace adif::mvt
