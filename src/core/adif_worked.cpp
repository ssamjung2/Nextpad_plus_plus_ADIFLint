#include "adif_worked.h"

#include "adif_geo.h"

#include <algorithm>
#include <cmath>

namespace adif {
namespace {

std::string upperAscii(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x80) {
            out += (char)(c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c);
            continue;
        }
        // Accented Latin letters as their plain letter (Doña Ana, Añasco): UTF-8 C3 xx.
        if (c == 0xC3 && i + 1 < s.size()) {
            static const char kLatin1[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTSAAAAAAACEEEEIIIIDNOOOOO/OUUUUYTY";
            unsigned char d = (unsigned char)s[i + 1];
            if (d >= 0x80 && d <= 0xBF) out += kLatin1[d - 0x80];
            ++i;
        }
    }
    return out;
}

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

// A word-wise replacement: "SAINT" as a whole word.
void replaceWord(std::string &s, const std::string &from, const std::string &to) {
    for (size_t at = 0; (at = s.find(from, at)) != std::string::npos;) {
        bool startOk = at == 0 || s[at - 1] == ' ', endOk = at + from.size() == s.size() || s[at + from.size()] == ' ';
        if (startOk && endOk) {
            s.replace(at, from.size(), to);
            at += to.size();
        } else {
            at += from.size();
        }
    }
}

std::string grid4Of(std::string_view grid) {
    std::string g = upperAscii(trimmed(grid));
    if (g.size() < 4) return "";
    g.resize(4);
    double w, s, e, n;
    if (isPlaceholderGrid(g) || !squareBounds(g, &w, &s, &e, &n)) return "";
    return g;
}

int zoneNumber(const std::string &name) {
    if (name.empty() || name.size() > 2 || !std::all_of(name.begin(), name.end(), [](char c) { return c >= '0' && c <= '9'; })) return 0;
    return std::stoi(name);
}

}  // namespace

bool pointInRings(const std::vector<std::vector<std::pair<double, double>>> &rings, double lon, double lat) {
    bool in = false;
    for (const auto &r : rings)
        for (size_t k = 0, j = r.size() ? r.size() - 1 : 0; k < r.size(); j = k++)
            if ((r[k].second > lat) != (r[j].second > lat) &&
                lon < (r[j].first - r[k].first) * (lat - r[k].second) / (r[j].second - r[k].second) + r[k].first)
                in = !in;
    return in;
}

AreaIndex::AreaIndex(Overlay o) {
    for (size_t i = 0; i < overlayCount(o); ++i) {
        areas_.push_back(overlayArea(o, i));
        std::array<double, 4> b{999, 999, -999, -999};
        for (const auto &ring : areas_.back().rings)
            for (const auto &p : ring) b = {std::min(b[0], p.first), std::min(b[1], p.second), std::max(b[2], p.first), std::max(b[3], p.second)};
        boxes_.push_back(b);
        names_.emplace(areas_.back().name, i);
        if (o == Overlay::UsCounties) counties_.emplace(countyKey(areas_.back().name), i);
    }
}

size_t AreaIndex::at(double lon, double lat, std::string_view prefix) const {
    for (size_t i = 0; i < areas_.size(); ++i) {
        const auto &b = boxes_[i];
        if (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) continue;
        if (!prefix.empty() && areas_[i].name.compare(0, prefix.size(), prefix) != 0) continue;
        if (pointInRings(areas_[i].rings, lon, lat)) return i;
    }
    return npos;
}

size_t AreaIndex::byName(std::string_view name) const {
    auto it = names_.find(std::string(name));
    return it == names_.end() ? npos : it->second;
}

size_t AreaIndex::byCounty(std::string_view cnty) const {
    std::string k = countyKey(cnty);
    if (k.empty()) return npos;
    auto it = counties_.find(k);
    return it == counties_.end() ? npos : it->second;
}

const AreaIndex &areaIndex(Overlay o) {
    static std::unordered_map<int, AreaIndex> all;
    auto it = all.find((int)o);
    if (it == all.end()) it = all.emplace((int)o, AreaIndex(o)).first;
    return it->second;
}

std::string countyKey(std::string_view cnty) {
    std::string v = upperAscii(trimmed(cnty));
    size_t comma = v.find(',');
    if (comma == std::string::npos || comma == 0) return "";
    std::string state = trimmed(v.substr(0, comma)), county = v.substr(comma + 1);
    if (state.size() != 2) return "";
    for (char &c : county)
        if (c == '.' || c == '\'' || c == '-') c = ' ';
    county = " " + trimmed(county) + " ";
    for (const char *suffix : {" COUNTY ", " PARISH ", " BOROUGH ", " CENSUS AREA "}) {
        std::string sfx = suffix;
        if (county.size() > sfx.size() && county.compare(county.size() - sfx.size(), sfx.size(), sfx) == 0)
            county = county.substr(0, county.size() - sfx.size() + 1);
    }
    county = trimmed(county);
    replaceWord(county, "SAINTE", "STE");
    replaceWord(county, "SAINT", "ST");
    std::string out;
    for (char c : county)
        if (c != ' ') out += c;
    if (out.empty()) return "";
    return state + "," + out;
}

bool isUsEntity(int dxcc) { return dxcc == 291 || dxcc == 6 || dxcc == 110; }

QsoPlaceFacts placeFacts(const MapQso &m, const CountryTable *countries) {
    QsoPlaceFacts f;
    f.dxcc = m.dxcc, f.cont = m.cont;
    f.state = m.state, f.cnty = m.cnty;
    f.cqz = m.cqz, f.ituz = m.ituz;
    CountryInfo info;
    if (countries && !countries->empty() && countries->lookup(m.call, &info)) {
        if (!f.dxcc) f.dxcc = info.dxcc;
        if (f.cont.empty()) f.cont = info.continent;
        f.ctyCq = info.cq, f.ctyItu = info.itu;
        f.ctyPlaced = true, f.ctyLat = info.lat, f.ctyLon = info.lon;
    }
    f.exact = m.located, f.lat = m.lat, f.lon = m.lon;
    f.grid4 = grid4Of(m.grid);
    return f;
}

QsoAreas resolveAreas(const QsoPlaceFacts &q) {
    QsoAreas a;
    a.dxcc = q.dxcc, a.cont = upperAscii(trimmed(q.cont));
    double w, s, e, n;
    if (q.exact) a.placed = true, a.lat = q.lat, a.lon = q.lon;
    else if (!q.grid4.empty() && squareBounds(q.grid4, &w, &s, &e, &n)) a.placed = true, a.lat = (s + n) / 2, a.lon = (w + e) / 2;
    else if (q.ctyPlaced) a.placed = true, a.lat = q.ctyLat, a.lon = q.ctyLon;
    const AreaIndex &states = areaIndex(Overlay::UsStates);
    bool us = isUsEntity(q.dxcc) || q.dxcc == 0;
    // State: STATE, else where it was (exactly, or a square wholly inside one state).
    std::string state = upperAscii(trimmed(q.state));
    if (us && !state.empty() && states.byName(state) != AreaIndex::npos) {
        a.state = state, a.stateFrom = AreaFrom::Field;
    } else if (us && q.exact) {
        size_t i = states.at(q.lon, q.lat);
        if (i != AreaIndex::npos) a.state = states.area(i).name, a.stateFrom = AreaFrom::Location;
    } else if (us && !q.grid4.empty()) {
        double w, s, e, n;
        if (squareBounds(q.grid4, &w, &s, &e, &n)) {
            size_t i = states.at((w + e) / 2, (s + n) / 2);
            bool whole = i != AreaIndex::npos;
            for (auto [x, y] : {std::pair{w + 0.01, s + 0.01}, {e - 0.01, s + 0.01}, {w + 0.01, n - 0.01}, {e - 0.01, n - 0.01}})
                whole = whole && states.at(x, y) == i;
            if (whole) a.state = states.area(i).name, a.stateFrom = AreaFrom::Location;
        }
    }
    // County: CNTY (in the state, when that is known), else where it was, within its state.
    const AreaIndex &counties = areaIndex(Overlay::UsCounties);
    if (us && !trimmed(q.cnty).empty()) {
        size_t i = counties.byCounty(q.cnty);
        if (i != AreaIndex::npos && (a.state.empty() || counties.area(i).name.compare(0, 3, a.state + ",") == 0))
            a.county = counties.area(i).name, a.countyFrom = AreaFrom::Field;
        else
            a.countyUnmatched = true;
    }
    if (us && a.county.empty() && q.exact && !a.state.empty()) {
        size_t i = counties.at(q.lon, q.lat, a.state + ",");
        if (i != AreaIndex::npos) a.county = counties.area(i).name, a.countyFrom = AreaFrom::Location;
    }
    // Zones: the record's, else where it was (exactly, else its square's middle), else the country data.
    double zlon = q.lon, zlat = q.lat;
    bool zplace = q.exact;
    if (!zplace && !q.grid4.empty()) {
        double w, s, e, n;
        if (squareBounds(q.grid4, &w, &s, &e, &n)) zlon = (w + e) / 2, zlat = (s + n) / 2, zplace = true;
    }
    auto zone = [&](int field, int cty, Overlay o, int maxZone, int *out, AreaFrom *from) {
        if (field >= 1 && field <= maxZone) {
            *out = field, *from = AreaFrom::Field;
            return;
        }
        if (zplace) {
            const AreaIndex &zones = areaIndex(o);
            size_t i = zones.at(zlon, zlat);
            if (i != AreaIndex::npos && zoneNumber(zones.area(i).name)) {
                *out = zoneNumber(zones.area(i).name), *from = AreaFrom::Location;
                return;
            }
        }
        if (cty >= 1 && cty <= maxZone) *out = cty, *from = AreaFrom::CountryFile;
    };
    zone(q.cqz, q.ctyCq, Overlay::CqZones, 40, &a.cq, &a.cqFrom);
    zone(q.ituz, q.ctyItu, Overlay::ItuZones, 90, &a.itu, &a.ituFrom);
    return a;
}

std::string parkCounty(const PotaPark &p) {
    if (!p.placed || p.location.find("US-") == std::string::npos) return "";
    const AreaIndex &counties = areaIndex(Overlay::UsCounties);
    size_t at = counties.at(p.lon, p.lat);
    return at == AreaIndex::npos ? "" : counties.area(at).name;
}

bool parkInPlaces(const PotaPark &p, const ParkPlaces &places, std::string_view county) {
    if (!places.any()) return true;
    std::string key = countyKey(county);
    for (size_t b = 0; b <= p.location.size();) {  // "US-DC,US-MD,US-WV": any of them will do
        size_t e = p.location.find(',', b);
        if (e == std::string::npos) e = p.location.size();
        std::string loc = p.location.substr(b, e - b);
        b = e + 1;
        if (loc.empty() || (!places.locations.empty() && !places.locations.count(loc))) continue;
        if (loc.size() == 5 && loc.compare(0, 3, "US-") == 0) {  // a state with counties chosen: one of them
            std::string state = loc.substr(3) + ",";
            auto it = places.counties.lower_bound(state);
            bool narrowed = it != places.counties.end() && it->compare(0, state.size(), state) == 0;
            if (narrowed && !places.counties.count(key)) continue;
        }
        return true;
    }
    return false;
}

std::string parkLocationAt(const PotaParks &parks, double lat, double lon) {
    const AreaIndex &states = areaIndex(Overlay::UsStates);
    if (size_t at = states.at(lon, lat); at != AreaIndex::npos) return "US-" + states.area(at).name;
    double best = 300;
    std::string out;
    for (const PotaPark &p : parks.parks()) {
        if (!p.active || !p.placed) continue;
        if (std::fabs(p.lat - lat) > 3) continue;  // over 300 km north or south
        double km = greatCircleKm(lat, lon, p.lat, p.lon);
        if (km < best) best = km, out = p.location.substr(0, p.location.find(','));
    }
    return out;
}

}  // namespace adif
