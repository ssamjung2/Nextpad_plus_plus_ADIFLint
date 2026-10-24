#include "adif_solar.h"

#include "adif_json.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace adif {

namespace {

constexpr size_t kMaxValues = 2'000'000;  // the aurora file's 65,160 triples, with room to spare

// The file's JSON, without the NUL bytes SWPC's files have been seen to end with.
bool load(std::string_view text, json::Value *v) {
    while (!text.empty() && (text.back() == '\0' || text.back() == '\n' || text.back() == '\r' || text.back() == ' ')) text.remove_suffix(1);
    std::string why;
    return json::parse(text, v, &why, kMaxValues);
}

// A member's number, written as a number or as text ("1.010000000000000e+002"); NaN without one.
double number(const json::Value &o, std::string_view key) {
    const json::Value *m = o.get(key);
    if (!m) return NAN;
    if (m->isNumber()) return m->number;
    if (m->isString() && !m->text.empty()) {
        char *end = nullptr;
        double d = std::strtod(m->text.c_str(), &end);
        if (end && *end == '\0') return d;
    }
    return NAN;
}

}  // namespace

bool parseSolarFlux(std::string_view text, SpaceWeather &w) {
    json::Value v;
    if (!load(text, &v) || !v.isArray() || v.items.empty()) return false;
    const json::Value &last = v.items.back();
    double flux = number(last, "flux");
    if (!last.isObject() || !std::isfinite(flux) || flux <= 0 || flux > 1000) return false;
    w.sfi = flux, w.sfiTime = last.str("time_tag");
    return true;
}

bool parsePlanetaryK(std::string_view text, SpaceWeather &w) {
    json::Value v;
    if (!load(text, &v) || !v.isArray()) return false;
    std::vector<std::pair<std::string, double>> all;
    for (const json::Value &e : v.items) {
        double kp = number(e, "Kp");
        if (e.isObject() && std::isfinite(kp) && kp >= 0 && kp <= 9) all.emplace_back(e.str("time_tag"), kp);
    }
    if (all.empty()) return false;
    w.kp = all.back().second, w.kpTime = all.back().first;
    w.kpRecent.assign(all.size() > 8 ? all.end() - 8 : all.begin(), all.end());
    return true;
}

bool parseXrays(std::string_view text, SpaceWeather &w) {
    json::Value v;
    if (!load(text, &v) || !v.isArray()) return false;
    for (auto it = v.items.rbegin(); it != v.items.rend(); ++it) {
        if (!it->isObject() || it->str("energy") != "0.1-0.8nm") continue;
        double flux = number(*it, "flux");
        if (!std::isfinite(flux) || flux <= 0 || flux > 1) continue;  // a gap in the data
        w.xray = flux, w.xrayTime = it->str("time_tag");
        return true;
    }
    return false;
}

bool parseNoaaScales(std::string_view text, SpaceWeather &w) {
    json::Value v;
    if (!load(text, &v) || !v.isObject()) return false;
    const json::Value *now = v.get("0");
    if (!now || !now->isObject()) return false;
    auto scale = [&](const char *key, int *level, std::string *word) {
        const json::Value *s = now->get(key);
        if (!s || !s->isObject()) return;
        double n = number(*s, "Scale");
        if (std::isfinite(n) && n >= 0 && n <= 5) *level = (int)n;
        *word = s->str("Text");
    };
    scale("R", &w.r, &w.rText);
    scale("S", &w.s, &w.sText);
    scale("G", &w.g, &w.gText);
    return w.r >= 0 || w.s >= 0 || w.g >= 0;
}

std::string flareClass(double flux) {
    if (!(flux > 0) || !std::isfinite(flux)) return "";
    static const char kClasses[] = "ABCMX";
    int k = (int)std::floor(std::log10(flux)) + 8;  // 1e-8 is A
    k = std::clamp(k, 0, 4);
    double multiple = flux / std::pow(10.0, k - 8);
    char out[16];
    std::snprintf(out, sizeof out, "%c%.1f", kClasses[k], std::floor(multiple * 10 + 1e-9) / 10);
    return out;
}

std::string kpText(double kp) {
    if (!(kp >= 0) || kp > 9) return "";
    long thirds = std::lround(kp * 3);  // 1.67 is 5 thirds: 2-
    long whole = (thirds + 1) / 3;
    int part = (int)(thirds - whole * 3);  // -1, 0 or +1
    return std::to_string(whole) + (part < 0 ? "-" : part > 0 ? "+" : "");
}

double AuroraGrid::at(double lon, double lat) const {
    if (value.size() != 360u * 181u) return 0;
    double x = std::fmod(lon + 360.0, 360.0), y = std::clamp(lat, -90.0, 90.0) + 90;
    int x0 = (int)std::floor(x), y0 = (int)std::floor(y);
    double tx = x - x0, ty = y - y0;
    auto v = [&](int xx, int yy) { return (double)value[(size_t)std::min(yy, 180) * 360 + (size_t)(xx % 360)]; };
    return (v(x0, y0) * (1 - tx) + v(x0 + 1, y0) * tx) * (1 - ty) + (v(x0, y0 + 1) * (1 - tx) + v(x0 + 1, y0 + 1) * tx) * ty;
}

bool parseOvation(std::string_view text, AuroraGrid &g) {
    json::Value v;
    if (!load(text, &v) || !v.isObject()) return false;
    const json::Value *c = v.get("coordinates");
    if (!c || !c->isArray()) return false;
    std::vector<unsigned char> grid(360u * 181u, 0);
    size_t set = 0;
    auto put = [&](double lon, double lat, double a) {
        if (!std::isfinite(lon) || !std::isfinite(lat) || !std::isfinite(a) || lon < 0 || lon > 359 || lat < -90 || lat > 90) return;
        if (lon != std::floor(lon) || lat != std::floor(lat)) return;
        grid[(size_t)(lat + 90) * 360 + (size_t)lon] = (unsigned char)std::clamp(std::lround(a), 0L, 100L);
        ++set;
    };
    if (c->stride == 3)
        for (size_t i = 0; i + 2 < c->packed.size(); i += 3) put(c->packed[i], c->packed[i + 1], c->packed[i + 2]);
    else
        for (const json::Value &t : c->items)
            if (t.isArray() && t.size() == 3 && !t.stride && t.items[0].isNumber() && t.items[1].isNumber() && t.items[2].isNumber())
                put(t.items[0].number, t.items[1].number, t.items[2].number);
    if (set < 1000) return false;  // a few points: not the file we know
    g.value = std::move(grid);
    g.observed = v.str("Observation Time"), g.forecast = v.str("Forecast Time");
    return true;
}

bool parseDailyIndices(std::string_view text, SpaceWeather &w) {
    // A day a line: its date ("2026 10 23"), Fredericksburg's A and 8 K, College's, then the
    // Estimated Planetary A and its 8 Kp in decimals ("2.33", "-1.00" missing). The stations' K
    // fields run together when one is missing ("1-1-1"), so the planetary A is found as the number
    // before the first decimal. The last day with all 8 Kp counts (today's is partial).
    if (text.size() > 200'000) return false;
    bool found = false;
    size_t at = 0;
    while (at < text.size()) {
        size_t end = text.find('\n', at);
        if (end == std::string_view::npos) end = text.size();
        std::string_view line = text.substr(at, end - at);
        at = end + 1;
        if (line.size() < 10 || line[0] < '0' || line[0] > '9') continue;  // headers start with ':' or '#'
        std::vector<std::string_view> tokens;
        for (size_t i = 0; i < line.size();) {
            while (i < line.size() && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r')) ++i;
            size_t j = i;
            while (j < line.size() && line[j] != ' ' && line[j] != '\t' && line[j] != '\r') ++j;
            if (j > i) tokens.push_back(line.substr(i, j - i));
            i = j;
        }
        size_t firstDecimal = 0;
        for (size_t k = 3; k < tokens.size() && !firstDecimal; ++k)
            if (tokens[k].find('.') != std::string_view::npos) firstDecimal = k;
        if (firstDecimal < 4 || tokens.size() < firstDecimal + 8) continue;
        bool complete = true;
        for (size_t k = firstDecimal; k < firstDecimal + 8; ++k) complete = complete && tokens[k].front() != '-';
        std::string a(tokens[firstDecimal - 1]);
        char *stop = nullptr;
        long ap = std::strtol(a.c_str(), &stop, 10);
        if (!complete || !stop || *stop || ap < 0 || ap > 400) continue;
        w.ap = (int)ap;
        w.apDate = std::string(tokens[0]) + " " + std::string(tokens[1]) + " " + std::string(tokens[2]);
        found = true;
    }
    return found;
}

}  // namespace adif
