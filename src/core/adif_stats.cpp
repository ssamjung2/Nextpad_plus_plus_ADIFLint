#include "adif_stats.h"

#include "adif_geo.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <set>

namespace adif {

namespace {

std::string upperTrimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    std::string o = b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
    for (char &c : o) c = (char)std::toupper((unsigned char)c);
    return o;
}

// A grid square's first 4 characters when it is one ("FN31"), else "".
std::string square4(std::string_view grid) {
    std::string g = upperTrimmed(grid);
    if (g.size() < 4) return "";
    g = g.substr(0, 4);
    return gridToLatLon(g, nullptr, nullptr) ? g : "";
}

}  // namespace

SummaryStats summaryStats(std::string_view text, const DocModel &m, const CountryTable *countries) {
    SummaryStats s;
    std::map<std::string, size_t> bands, modes, days, continents;
    struct Dated {
        long long when;
        int dxcc;
        std::string state;
        std::vector<std::string> grids;
        std::string day;
    };
    std::vector<Dated> dated;
    for (const Record &r : records(text, m)) {
        std::string call = upperTrimmed(r.get("CALL"));
        if (call.empty()) continue;
        ++s.qsos;
        if (std::string band = effectiveBand(r); !band.empty()) ++bands[band];
        if (std::string mode = effectiveMode(r); !mode.empty()) ++modes[mode];
        int dxcc = std::atoi(upperTrimmed(r.get("DXCC")).c_str());
        std::string cont = upperTrimmed(r.get("CONT"));
        CountryInfo info;
        if ((dxcc <= 0 || cont.empty()) && countries && !countries->empty() && countries->lookup(call, &info)) {
            if (dxcc <= 0) dxcc = info.dxcc;
            if (cont.empty()) cont = info.continent;
        }
        if (!cont.empty()) ++continents[cont];
        long long when = qsoStart(r);
        std::string date = upperTrimmed(r.get("QSO_DATE"));
        if (parseAdifDate(date, nullptr)) ++days[date];
        if (when >= 0) {
            long long day = when / 86400, seconds = when % 86400;
            ++s.hourWeekday[(size_t)((day + 3) % 7)][(size_t)(seconds / 3600)];  // 1970-01-01 was a Thursday
        }
        Dated d{when, dxcc, "", {}, date};
        if (dxcc == 291 || dxcc == 6 || dxcc == 110) d.state = upperTrimmed(r.get("STATE"));
        if (std::string g = square4(r.get("GRIDSQUARE")); !g.empty()) d.grids.push_back(g);
        std::string vucc = r.get("VUCC_GRIDS");
        for (size_t at = 0; at < vucc.size();) {
            size_t comma = vucc.find(',', at);
            if (std::string g = square4(vucc.substr(at, comma == std::string::npos ? std::string::npos : comma - at)); !g.empty()) d.grids.push_back(g);
            at = comma == std::string::npos ? vucc.size() : comma + 1;
        }
        if (when >= 0) dated.push_back(std::move(d));
    }
    // Bands by frequency (those the spec doesn't know last, by name); modes most first.
    for (const auto &kv : bands) s.bands.push_back(kv);
    std::stable_sort(s.bands.begin(), s.bands.end(), [](const auto &a, const auto &b) {
        const BandDef *x = findBand(a.first), *y = findBand(b.first);
        if (x && y) return x->lowerMHz < y->lowerMHz;
        return x != nullptr && y == nullptr;
    });
    for (const auto &kv : modes) s.modes.push_back(kv);
    std::stable_sort(s.modes.begin(), s.modes.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
    for (const auto &kv : days) s.days.push_back(kv);
    for (const char *c : {"AF", "AN", "AS", "EU", "NA", "OC", "SA"})
        if (continents.count(c)) s.continents.emplace_back(c, continents[c]);
    // What was reached by the end of each day.
    std::stable_sort(dated.begin(), dated.end(), [](const Dated &a, const Dated &b) { return a.when < b.when; });
    std::set<int> entities;
    std::set<std::string> states, grids;
    for (const Dated &d : dated) {
        if (d.dxcc > 0) entities.insert(d.dxcc);
        if (!d.state.empty() && d.state.size() == 2) states.insert(d.state);
        for (const std::string &g : d.grids) grids.insert(g);
        std::string day = formatAdifDate((long)(d.when / 86400));
        if (s.growth.empty() || s.growth.back().day != day) s.growth.push_back({day});
        s.growth.back().dxcc = entities.size(), s.growth.back().states = states.size(), s.growth.back().grids = grids.size();
    }
    return s;
}

}  // namespace adif
