#include "adif_outlines.h"

#include "adif_json.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>

namespace adif {

namespace {

constexpr double kJoin = 1e-7;       // degrees: ends this close are the same node
constexpr double kNearKm = 5;        // a PAD-US unit this close to POTA's place may be the park
constexpr double kParcelsKm = 25;    // the chosen name's parcels this close make the outline
constexpr size_t kMaxRingPoints = 200000;

bool same(const OutlinePoint &a, const OutlinePoint &b) { return std::fabs(a.first - b.first) < kJoin && std::fabs(a.second - b.second) < kJoin; }

bool closed(const OutlineRing &r) { return r.size() >= 4 && same(r.front(), r.back()); }

bool finitePoint(double lon, double lat) { return std::isfinite(lon) && std::isfinite(lat) && std::fabs(lon) <= 180 && std::fabs(lat) <= 90; }

// A packed JSON array of (lon, lat) pairs as a ring.
OutlineRing ringOf(const json::Value &v) {
    OutlineRing r;
    if (!v.isArray() || v.stride < 2) return r;
    for (size_t i = 0; i + v.stride <= v.packed.size() && r.size() < kMaxRingPoints; i += v.stride)
        if (finitePoint(v.packed[i], v.packed[i + 1])) r.emplace_back(v.packed[i], v.packed[i + 1]);
    return r;
}

void boundRings(const std::vector<OutlineRing> &rings, double *w, double *s, double *e, double *n) {
    for (const OutlineRing &r : rings)
        for (const OutlinePoint &p : r) *w = std::min(*w, p.first), *e = std::max(*e, p.first), *s = std::min(*s, p.second), *n = std::max(*n, p.second);
}

std::string upper(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

// The references in a tag value: "US-1234", "US-1234;CA-0001", "US-7977, CA-0448".
std::vector<std::string> refsOf(std::string_view v) {
    std::vector<std::string> out;
    std::string cur;
    auto flush = [&] {
        while (!cur.empty() && cur.back() == ' ') cur.pop_back();
        size_t b = cur.find_first_not_of(' ');
        std::string ref = b == std::string::npos ? "" : upper(cur.substr(b));
        if (potaRefShaped(ref) && std::find(out.begin(), out.end(), ref) == out.end()) out.push_back(ref);
        cur.clear();
    };
    for (char c : v) {
        if (c == ';' || c == ',') flush();
        else cur.push_back(c);
    }
    flush();
    return out;
}

bool inRings(const std::vector<OutlineRing> &rings, double lon, double lat) {
    bool in = false;
    for (const OutlineRing &r : rings)
        for (size_t i = 0, j = r.size() ? r.size() - 1 : 0; i < r.size(); j = i++) {
            double xi = r[i].first, yi = r[i].second, xj = r[j].first, yj = r[j].second;
            if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) in = !in;
        }
    return in;
}

}  // namespace

void ParkOutline::bound() {
    west = 180, south = 90, east = -180, north = -90;
    boundRings(rings, &west, &south, &east, &north);
}

bool potaRefShaped(std::string_view ref) {
    size_t dash = ref.find('-');
    if (dash == std::string_view::npos || dash == 0 || dash > 4) return false;
    for (size_t i = 0; i < dash; ++i)
        if (!std::isupper((unsigned char)ref[i]) && !std::isdigit((unsigned char)ref[i])) return false;
    size_t digits = ref.size() - dash - 1;
    if (digits < 4 || digits > 5) return false;
    for (size_t i = dash + 1; i < ref.size(); ++i)
        if (!std::isdigit((unsigned char)ref[i])) return false;
    return true;
}

std::vector<OutlineRing> joinRings(std::vector<OutlineRing> segments) {
    std::vector<OutlineRing> rings;
    std::vector<OutlineRing> open;
    for (OutlineRing &s : segments) {
        if (s.size() < 2) continue;
        if (closed(s)) rings.push_back(std::move(s));
        else open.push_back(std::move(s));
    }
    while (!open.empty()) {
        OutlineRing ring = std::move(open.back());
        open.pop_back();
        bool grew = true;
        while (!closed(ring) && grew && ring.size() < kMaxRingPoints) {
            grew = false;
            for (size_t i = 0; i < open.size(); ++i) {
                OutlineRing &s = open[i];
                if (same(ring.back(), s.front())) ring.insert(ring.end(), s.begin() + 1, s.end());
                else if (same(ring.back(), s.back())) ring.insert(ring.end(), s.rbegin() + 1, s.rend());
                else if (same(ring.front(), s.back())) ring.insert(ring.begin(), s.begin(), s.end() - 1);
                else if (same(ring.front(), s.front())) ring.insert(ring.begin(), s.rbegin(), s.rend() - 1);
                else continue;
                open.erase(open.begin() + (long)i);
                grew = true;
                break;
            }
        }
        if (closed(ring)) rings.push_back(std::move(ring));
    }
    return rings;
}

OutlineRing simplifyRing(const OutlineRing &ring, double tolerance) {
    if (ring.size() < 4) return {};
    std::vector<char> keep(ring.size(), 0);
    keep.front() = keep.back() = 1;
    // The farthest point from the first splits the closed ring into two open runs.
    size_t far = 0;
    double best = -1;
    for (size_t i = 1; i + 1 < ring.size(); ++i) {
        double dx = ring[i].first - ring[0].first, dy = ring[i].second - ring[0].second, d = dx * dx + dy * dy;
        if (d > best) best = d, far = i;
    }
    keep[far] = 1;
    std::vector<std::pair<size_t, size_t>> stack = {{0, far}, {far, ring.size() - 1}};
    while (!stack.empty()) {
        auto [a, b] = stack.back();
        stack.pop_back();
        if (b <= a + 1) continue;
        double ax = ring[a].first, ay = ring[a].second, bx = ring[b].first, by = ring[b].second;
        double dx = bx - ax, dy = by - ay, len = std::sqrt(dx * dx + dy * dy);
        size_t at = 0;
        double worst = -1;
        for (size_t i = a + 1; i < b; ++i) {
            double px = ring[i].first - ax, py = ring[i].second - ay;
            double d = len > 0 ? std::fabs(px * dy - py * dx) / len : std::sqrt(px * px + py * py);
            if (d > worst) worst = d, at = i;
        }
        if (worst > tolerance) keep[at] = 1, stack.push_back({a, at}), stack.push_back({at, b});
    }
    OutlineRing out;
    for (size_t i = 0; i < ring.size(); ++i)
        if (keep[i]) out.push_back(ring[i]);
    return out.size() >= 4 ? out : OutlineRing();
}

bool overpassOutlines(std::string_view text, std::vector<ParkOutline> *out, std::string *why) {
    json::Value root;
    if (!json::parse(text, &root, why)) return false;
    const json::Value *elements = root.get("elements");
    if (!root.isObject() || !elements || !elements->isArray()) {
        if (why) *why = "not Overpass's JSON (no elements)";
        return false;
    }
    std::map<std::string, ParkOutline> byRef;  // one outline per reference, however many ways and relations
    for (const json::Value &e : elements->items) {
        const json::Value *tags = e.get("tags");
        if (!tags) continue;
        std::vector<std::string> refs = refsOf(tags->str("communication:amateur_radio:pota"));
        if (refs.empty()) continue;
        std::vector<OutlineRing> rings;
        std::string type = e.str("type");
        if (type == "way") {
            if (const json::Value *g = e.get("geometry")) {
                OutlineRing r = ringOf(*g);
                if (closed(r)) rings.push_back(std::move(r));
            }
        } else if (type == "relation") {
            std::vector<OutlineRing> segments;
            if (const json::Value *members = e.get("members"); members && members->isArray())
                for (const json::Value &m : members->items)
                    if (m.str("type") == "way")
                        if (const json::Value *g = m.get("geometry")) segments.push_back(ringOf(*g));
            rings = joinRings(std::move(segments));
        }
        if (rings.empty()) continue;
        for (const std::string &ref : refs) {
            ParkOutline &o = byRef[ref];
            o.ref = ref, o.source = "OSM";
            if (o.name.empty()) o.name = tags->str("name");
            o.rings.insert(o.rings.end(), rings.begin(), rings.end());
        }
    }
    out->clear();
    for (auto &kv : byRef) {
        kv.second.bound();
        out->push_back(std::move(kv.second));
    }
    return true;
}

bool geojsonOutlines(std::string_view text, std::string_view source, std::vector<ParkOutline> *out, std::string *why) {
    json::Value root;
    if (!json::parse(text, &root, why)) return false;
    const json::Value *features = root.get("features");
    if (root.str("type") != "FeatureCollection" || !features || !features->isArray()) {
        if (why) *why = "not a GeoJSON FeatureCollection";
        return false;
    }
    std::map<std::string, ParkOutline> byRef;
    for (const json::Value &f : features->items) {
        const json::Value *props = f.get("properties"), *geometry = f.get("geometry");
        if (!props || !geometry) continue;
        std::string ref = upper(props->str("id"));
        if (!potaRefShaped(ref)) ref = upper(props->str("reference"));
        if (!potaRefShaped(ref)) continue;
        std::string type = geometry->str("type");
        const json::Value *c = geometry->get("coordinates");
        if (!c || !c->isArray()) continue;
        std::vector<OutlineRing> rings;
        if (type == "Polygon") {
            for (const json::Value &r : c->items)
                if (OutlineRing ring = ringOf(r); closed(ring)) rings.push_back(std::move(ring));
        } else if (type == "MultiPolygon") {
            for (const json::Value &poly : c->items)
                for (const json::Value &r : poly.items)
                    if (OutlineRing ring = ringOf(r); closed(ring)) rings.push_back(std::move(ring));
        } else {
            continue;  // trails and points
        }
        if (rings.empty()) continue;
        ParkOutline &o = byRef[ref];
        o.ref = ref, o.source = std::string(source);
        if (o.name.empty()) o.name = props->str("name");
        o.rings.insert(o.rings.end(), rings.begin(), rings.end());
    }
    out->clear();
    for (auto &kv : byRef) {
        kv.second.bound();
        out->push_back(std::move(kv.second));
    }
    return true;
}

bool arcgisUnits(std::string_view text, std::vector<PadUnit> *out, bool *more, std::string *why) {
    json::Value root;
    if (!json::parse(text, &root, why)) return false;
    if (const json::Value *error = root.get("error")) {
        if (why) *why = "PAD-US: " + error->str("message");
        return false;
    }
    const json::Value *features = root.get("features");
    if (!features || !features->isArray()) {
        if (why) *why = "not an ArcGIS query answer (no features)";
        return false;
    }
    if (more) {
        const json::Value *e = root.get("exceededTransferLimit");
        *more = e && e->type == json::Value::Type::Bool && e->boolean;
    }
    out->clear();
    for (const json::Value &f : features->items) {
        const json::Value *a = f.get("attributes"), *g = f.get("geometry");
        if (!a || !g) continue;
        PadUnit u;
        u.name = a->str("Unit_Nm"), u.designation = a->str("Des_Tp");
        if (const json::Value *rings = g->get("rings"); rings && rings->isArray())
            for (const json::Value &r : rings->items)
                if (OutlineRing ring = ringOf(r); closed(ring)) u.rings.push_back(std::move(ring));
        if (u.name.empty() || u.rings.empty()) continue;
        boundRings(u.rings, &u.west, &u.south, &u.east, &u.north);
        out->push_back(std::move(u));
    }
    return true;
}

std::vector<std::string> parkNameWords(std::string_view name) {
    static const std::set<std::string> kDesignation = {
        "state",    "national", "park",     "parks",      "forest",   "forests",  "recreation", "recreational", "area",      "areas",
        "natural",  "nature",   "preserve", "reserve",    "wildlife", "fish",     "and",        "conservation", "historic",  "historical",
        "site",     "memorial", "monument", "refuge",     "wilderness", "county", "management", "land",         "water",     "habitat",
        "landmark", "heritage", "sanctuary", "the",       "of",       "unit",     "sp",         "sna",          "swa",       "nwr",
        "wma",      "sra",      "sf",       "nf",         "nm",       "np",       "nhs",        "nhp",          "trail",     "scenic",
        "game",     "lands",    "seashore", "lakeshore", "battlefield", "corridor", "greenway", "commission",   "department"};
    std::string flat;
    for (size_t i = 0; i < name.size(); ++i) {
        unsigned char c = (unsigned char)name[i];
        if (c == '&') flat += " and ";
        else if (c == '\'' || (c == 0xE2 && i + 2 < name.size() && (unsigned char)name[i + 1] == 0x80 && (unsigned char)name[i + 2] == 0x99))
            i += c == 0xE2 ? 2 : 0;  // apostrophes go: "Campbell's" is "campbells"
        else if (std::isalnum(c)) flat.push_back((char)std::tolower(c));
        else flat.push_back(' ');
    }
    std::vector<std::string> words;
    size_t b = 0;
    while (b < flat.size()) {
        size_t e = flat.find(' ', b);
        if (e == std::string::npos) e = flat.size();
        std::string w = flat.substr(b, e - b);
        b = e + 1;
        if (w.empty() || kDesignation.count(w)) continue;
        if (w.size() > 4 && w.back() == 's' && w[w.size() - 2] != 's') w.pop_back();  // "woods" and "wood", "campbells" and "campbell"
        words.push_back(w);
    }
    return words;
}

std::string padUsWhere(std::string_view state, const std::vector<std::vector<std::string>> &names) {
    auto sql = [](std::string s) {
        std::string o;
        for (char c : s) {
            if (c == '\'') o += "''";
            else if (std::isalnum((unsigned char)c) || c == ' ') o.push_back(c);
        }
        return o;
    };
    std::string where = "State_Nm='" + sql(upper(std::string(state))) + "'";
    std::string any;
    for (const std::vector<std::string> &words : names) {
        if (words.empty()) continue;
        std::string pattern = "%";
        for (const std::string &w : words) pattern += upper(sql(w.substr(0, 6))) + "%";
        any += (any.empty() ? "" : " OR ") + std::string("UPPER(Unit_Nm) LIKE '") + pattern + "'";
    }
    return any.empty() ? where : where + " AND (" + any + ")";
}

bool inOutline(const ParkOutline &o, double lon, double lat) {
    if (lon < o.west || lon > o.east || lat < o.south || lat > o.north) return false;
    return inRings(o.rings, lon, lat);
}

double outlineDistanceKm(const std::vector<OutlineRing> &rings, double lat, double lon) {
    if (inRings(rings, lon, lat)) return 0;
    double best = 1e9;
    for (const OutlineRing &r : rings)
        for (size_t i = 1; i < r.size(); ++i) {
            // The nearest point of each edge, in a local flat frame.
            double c = std::cos(lat * M_PI / 180);
            double ax = (r[i - 1].first - lon) * c, ay = r[i - 1].second - lat, bx = (r[i].first - lon) * c, by = r[i].second - lat;
            double dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
            double t = len2 > 0 ? std::clamp(-(ax * dx + ay * dy) / len2, 0.0, 1.0) : 0;
            double x = ax + t * dx, y = ay + t * dy;
            best = std::min(best, std::sqrt(x * x + y * y) * 111.195);
        }
    return best;
}

namespace {
// The PAD-US designation types (Des_Tp, the layer's coded values, read 2026-10-20) a park's name
// says it is: "State Park" is SP, "National Wildlife Refuge" NWR...; none when it doesn't say.
std::set<std::string> designationsFor(const std::string &lowerName) {
    static const std::pair<const char *, std::vector<const char *>> kSays[] = {
        {"national park", {"NP"}},
        {"national monument", {"NM"}},
        {"national forest", {"NF"}},
        {"national grassland", {"NG"}},
        {"national wildlife refuge", {"NWR"}},
        {"wild and scenic river", {"WSR"}},
        {"national recreation area", {"NRA"}},
        {"national lakeshore", {"NLS"}},
        {"national seashore", {"NLS"}},
        {"national scenic trail", {"NT"}},
        {"national historic trail", {"NT"}},
        {"wilderness", {"WA", "SW", "WSA"}},
        {"state park", {"SP"}},
        {"state recreation area", {"SREC"}},
        {"state forest", {"SRMA", "SOTH"}},
        {"state historic site", {"SHCA"}},
        {"wildlife area", {"SCA", "SRMA"}},
        {"wildlife management area", {"SCA", "SRMA"}},
        {"conservation area", {"SCA", "NCA", "LCA"}},
        {"natural area", {"SCA"}},
        {"nature preserve", {"SCA", "PCON"}},
        {"county park", {"LP"}},
        {"city park", {"LP"}},
    };
    std::set<std::string> out;
    for (const auto &[phrase, codes] : kSays)
        if (lowerName.find(phrase) != std::string::npos) out.insert(codes.begin(), codes.end());
    return out;
}
}  // namespace

std::vector<ParkOutline> matchPadUnits(const std::vector<ParkSite> &parks, const std::vector<PadUnit> &units) {
    std::vector<std::vector<std::string>> unitWords;
    for (const PadUnit &u : units) unitWords.push_back(parkNameWords(u.name));
    auto contains = [](const std::vector<std::string> &big, const std::vector<std::string> &small) {
        for (const std::string &w : small)
            if (std::find(big.begin(), big.end(), w) == big.end()) return false;
        return !small.empty();
    };
    auto distinctive = [](const std::vector<std::string> &words) {
        for (const std::string &w : words)
            if (w.size() >= 4) return true;
        return false;
    };
    std::vector<ParkOutline> out;
    for (const ParkSite &p : parks) {
        std::vector<std::string> words = parkNameWords(p.name);
        if (!distinctive(words)) continue;
        std::string lower;
        for (char c : p.name) lower.push_back((char)std::tolower((unsigned char)c));
        std::set<std::string> says = designationsFor(lower);
        struct Candidate {
            size_t unit;
            int nameScore;  // 0 the same words, 1 one holds the other
            int fit;        // 0 its designation fits the park's name
            double km;
        };
        std::vector<Candidate> found;
        bool official = false;  // the name says state or national: not a local or private unit
        for (const std::string &c : says) official |= c[0] != 'L' && c[0] != 'P';
        for (size_t i = 0; i < units.size(); ++i) {
            const std::vector<std::string> &uw = unitWords[i];
            // The park's name may hold the unit's words only when there are two or more of them
            // ("Lincoln Tomb" doesn't make "Lincoln Park" the park).
            bool equal = uw == words, holds = contains(uw, words) || (uw.size() >= 2 && contains(words, uw));
            if (!equal && !holds) continue;
            const PadUnit &u = units[i];
            // Land next to the park: "Disconnected land ... south of Moraine Hills State Park".
            std::string unitLower;
            for (char c : u.name) unitLower.push_back((char)std::tolower((unsigned char)c));
            size_t of = unitLower.find(" of "), first = unitLower.find(words.front());
            if (of != std::string::npos && first != std::string::npos && of < first) continue;
            if (official && !u.designation.empty() && (u.designation[0] == 'L' || u.designation[0] == 'P')) continue;
            // Far boxes first: most units are nowhere near.
            double padKm = 0.05 + kNearKm / 111.0;
            if (p.lat < u.south - padKm || p.lat > u.north + padKm || p.lon < u.west - padKm * 3 || p.lon > u.east + padKm * 3) continue;
            double d = outlineDistanceKm(u.rings, p.lat, p.lon);
            if (d > kNearKm) continue;
            found.push_back({i, equal ? 0 : 1, says.count(u.designation) ? 0 : 1, d});
        }
        if (found.empty()) continue;
        // A fitting designation first ("State Park" and SP beat a nature preserve inside it), then the
        // closer name, then the nearer.
        std::sort(found.begin(), found.end(), [](const Candidate &a, const Candidate &b) {
            if (a.fit != b.fit) return a.fit < b.fit;
            if (a.nameScore != b.nameScore) return a.nameScore < b.nameScore;
            return a.km < b.km;
        });
        const std::string &chosen = units[found.front().unit].name;
        ParkOutline o;
        o.ref = p.ref, o.source = "PAD-US", o.name = chosen, o.matched = true;
        for (const PadUnit &u : units)  // every parcel of that name nearby
            if (u.name == chosen && outlineDistanceKm(u.rings, p.lat, p.lon) <= kParcelsKm) o.rings.insert(o.rings.end(), u.rings.begin(), u.rings.end());
        o.bound();
        out.push_back(std::move(o));
    }
    return out;
}

std::string writeOutlines(const std::vector<ParkOutline> &outlines) {
    std::string s = "# ADIF Lint park outlines 1\n";
    char buf[64];
    for (const ParkOutline &o : outlines) {
        std::string name;
        for (char c : o.name) name.push_back(c == '\t' || c == '\n' || c == '\r' ? ' ' : c);
        s += "P\t" + o.ref + "\t" + o.source + "\t" + (o.matched ? "1" : "0") + "\t" + name + "\n";
        for (const OutlineRing &r : o.rings) {
            s += "R";
            for (const OutlinePoint &p : r) {  // whole units of 1e-5 degree: no decimal point for a locale to change
                std::snprintf(buf, sizeof buf, " %ld,%ld", std::lround(p.first * 1e5), std::lround(p.second * 1e5));
                s += buf;
            }
            s += "\n";
        }
    }
    return s;
}

bool readOutlines(std::string_view text, std::vector<ParkOutline> *out, std::string *why) {
    out->clear();
    if (text.rfind("# ADIF Lint park outlines 1", 0) != 0) {
        if (why) *why = "not an ADIF Lint outline file";
        return false;
    }
    size_t at = 0;
    while (at < text.size()) {
        size_t e = text.find('\n', at);
        if (e == std::string_view::npos) e = text.size();
        std::string_view line = text.substr(at, e - at);
        at = e + 1;
        if (line.rfind("P\t", 0) == 0) {
            std::vector<std::string> f;
            size_t b = 2;
            while (f.size() < 3) {
                size_t t = line.find('\t', b);
                if (t == std::string_view::npos) break;
                f.emplace_back(line.substr(b, t - b));
                b = t + 1;
            }
            if (f.size() < 3 || !potaRefShaped(f[0])) continue;
            ParkOutline o;
            o.ref = f[0], o.source = f[1], o.matched = f[2] == "1", o.name = std::string(line.substr(b));
            out->push_back(std::move(o));
        } else if (line.rfind("R", 0) == 0 && !out->empty()) {
            OutlineRing r;
            std::string rest(line.substr(1));
            const char *p = rest.c_str();
            while (*p && r.size() < kMaxRingPoints) {
                char *end;
                long lon = std::strtol(p, &end, 10);
                if (end == p || *end != ',') break;
                long lat = std::strtol(end + 1, &end, 10);
                if (finitePoint(lon / 1e5, lat / 1e5)) r.emplace_back(lon / 1e5, lat / 1e5);
                p = end;
            }
            if (closed(r)) out->back().rings.push_back(std::move(r));
        }
    }
    out->erase(std::remove_if(out->begin(), out->end(), [](const ParkOutline &o) { return o.rings.empty(); }), out->end());
    for (ParkOutline &o : *out) o.bound();
    return true;
}

}  // namespace adif
