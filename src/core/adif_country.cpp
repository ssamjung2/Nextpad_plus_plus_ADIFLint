#include "adif_country.h"

#include "adif_spec.h"

#include <cstdlib>

namespace adif {
namespace {

std::string upper(std::string_view s) {
    std::string o;
    for (char c : s)
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') o.push_back((c >= 'a' && c <= 'z') ? (char)(c - 32) : c);
    return o;
}

// "AA0(4)[7]" -> prefix "AA0" with its overrides.
std::string parseAlias(std::string_view tok, int *cq, int *itu, std::string *cont, bool *hasLatLon, double *lat, double *lon) {
    size_t end = tok.find_first_of("([<{~");
    std::string prefix(tok.substr(0, end));
    while (end != std::string_view::npos && end < tok.size()) {
        char open = tok[end];
        char close = open == '(' ? ')' : open == '[' ? ']' : open == '<' ? '>' : open == '{' ? '}' : '~';
        size_t stop = tok.find(close, end + 1);
        if (stop == std::string_view::npos) break;
        std::string v(tok.substr(end + 1, stop - end - 1));
        if (open == '(') *cq = std::atoi(v.c_str());
        else if (open == '[') *itu = std::atoi(v.c_str());
        else if (open == '{') *cont = v;
        else if (open == '<') {
            size_t slash = v.find('/');
            if (slash != std::string::npos) {
                *hasLatLon = true;
                *lat = std::atof(v.substr(0, slash).c_str());
                *lon = -std::atof(v.substr(slash + 1).c_str());  // cty: + for west
            }
        }
        end = stop + 1;
        if (end < tok.size() && std::string_view("([<{~").find(tok[end]) == std::string_view::npos) break;
    }
    return prefix;
}

}  // namespace

bool CountryTable::load(std::string_view csv, std::string *error) {
    entities_.clear();
    exact_.clear();
    prefix_.clear();
    longest_ = 0;
    size_t start = 0;
    while (start < csv.size()) {
        size_t nl = csv.find('\n', start);
        std::string_view line = csv.substr(start, nl == std::string_view::npos ? std::string_view::npos : nl - start);
        start = nl == std::string_view::npos ? csv.size() : nl + 1;
        std::vector<std::string_view> f;
        size_t at = 0;
        for (int i = 0; i < 9; ++i) {
            size_t c = line.find(',', at);
            if (c == std::string_view::npos) break;
            f.push_back(line.substr(at, c - at));
            at = c + 1;
        }
        if (f.size() != 9) continue;
        CountryInfo e;
        e.dxcc = std::atoi(std::string(f[2]).c_str());
        e.name = std::string(f[1]);
        e.continent = upper(f[3]);
        e.cq = std::atoi(std::string(f[4]).c_str());
        e.itu = std::atoi(std::string(f[5]).c_str());
        e.lat = std::atof(std::string(f[6]).c_str());
        e.lon = -std::atof(std::string(f[7]).c_str());
        if (e.dxcc <= 0 || e.name.empty()) continue;
        size_t index = entities_.size();
        entities_.push_back(e);
        std::string_view aliases = line.substr(at);
        size_t semi = aliases.find(';');
        if (semi != std::string_view::npos) aliases = aliases.substr(0, semi);
        size_t p = 0;
        while (p < aliases.size()) {
            while (p < aliases.size() && (aliases[p] == ' ' || aliases[p] == '\t' || aliases[p] == '\r')) ++p;
            size_t q = p;
            while (q < aliases.size() && aliases[q] != ' ' && aliases[q] != '\t' && aliases[q] != '\r') ++q;
            if (q > p) {
                std::string_view tok = aliases.substr(p, q - p);
                bool exactCall = tok[0] == '=';
                if (exactCall) tok.remove_prefix(1);
                Alias a;
                a.entity = index;
                std::string pre = upper(parseAlias(tok, &a.cq, &a.itu, &a.continent, &a.hasLatLon, &a.lat, &a.lon));
                if (!pre.empty()) {
                    auto &map = exactCall ? exact_ : prefix_;
                    map.emplace(pre, a);  // the file's first entry wins
                    if (!exactCall && pre.size() > longest_) longest_ = pre.size();
                }
            }
            p = q;
        }
    }
    if (entities_.empty() && error) *error = "no entities found (is this AD1C's cty.csv?)";
    return !entities_.empty();
}

bool CountryTable::resolve(const Alias &a, CountryInfo *out) const {
    CountryInfo e = entities_[a.entity];
    if (a.cq > 0) e.cq = a.cq;
    if (a.itu > 0) e.itu = a.itu;
    if (!a.continent.empty()) e.continent = upper(a.continent);
    if (a.hasLatLon) e.lat = a.lat, e.lon = a.lon;
    if (out) *out = e;
    return true;
}

bool CountryTable::lookup(std::string_view callIn, CountryInfo *out) const {
    std::string call = upper(callIn);
    if (call.empty() || entities_.empty()) return false;
    auto ex = exact_.find(call);
    if (ex != exact_.end()) return resolve(ex->second, out);
    std::string base = call;
    if (call.find('/') != std::string::npos) {
        std::vector<std::string> parts;
        size_t s = 0;
        while (s <= call.size()) {
            size_t sl = call.find('/', s);
            parts.push_back(call.substr(s, sl == std::string::npos ? std::string::npos : sl - s));
            if (sl == std::string::npos) break;
            s = sl + 1;
        }
        std::vector<std::string> kept;
        for (const std::string &p : parts) {
            if (p == "MM" || p == "AM") return false;  // maritime or aeronautical mobile: no DXCC entity
            bool suffix = p.empty() || p == "P" || p == "M" || p == "QRP" || p == "A" || p == "B" || p == "LH" ||
                          p == "R" || p == "QRPP" || (p.size() == 1 && p[0] >= '0' && p[0] <= '9');
            if (!suffix) kept.push_back(p);
        }
        if (kept.empty()) return false;
        base = kept[0];
        // Two parts: the shorter one is where the station is (VE3/K1ABC, K1ABC/VE3, KH6/K1ABC).
        if (kept.size() >= 2) base = kept[0].size() <= kept[1].size() ? kept[0] : kept[1];
    }
    for (size_t n = std::min(base.size(), longest_); n > 0; --n) {
        auto it = prefix_.find(base.substr(0, n));
        if (it != prefix_.end()) return resolve(it->second, out);
    }
    return false;
}

FieldMap countryFields(const CountryTable &t, std::string_view call) {
    FieldMap out;
    CountryInfo e;
    if (!t.lookup(call, &e)) return out;
    std::string code = std::to_string(e.dxcc);
    out["DXCC"] = code;
    if (const char *name = dxccEntityName(code)) out["COUNTRY"] = name;
    if (e.cq > 0) out["CQZ"] = std::to_string(e.cq);
    if (e.itu > 0) out["ITUZ"] = std::to_string(e.itu);
    if (!e.continent.empty()) out["CONT"] = e.continent;
    return out;
}

}  // namespace adif
