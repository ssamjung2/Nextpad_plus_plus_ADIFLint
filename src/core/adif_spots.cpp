#include "adif_spots.h"

#include "adif_edit.h"
#include "adif_enrich.h"
#include "adif_geo.h"
#include "adif_i18n.h"
#include "adif_palette.h"
#include "adif_programs.h"
#include "adif_tools.h"
#include "adif_spec.h"
#include "adif_worked.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <unordered_set>

namespace adif {
using i18n::tr;

namespace {

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o) c = (char)std::toupper((unsigned char)c);
    return o;
}

std::string trimmed(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b])) ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1])) --e;
    return std::string(s.substr(b, e - b));
}

}  // namespace

const char *spotSourceName(SpotSource s) {
    switch (s) {
        case SpotSource::Pota: return "POTA";
        case SpotSource::Wwff: return "WWFF";
        case SpotSource::Spothole: return "Spothole";
        case SpotSource::Cluster: return N_("DX cluster");
        case SpotSource::PskReporter: return "PSKReporter";
    }
    return "";
}

std::string spotterCall(std::string_view spotter) {
    std::string s = upper(trimmed(spotter));
    size_t dash = s.find('-');
    if (dash != std::string::npos) s.resize(dash);  // "W3LPL-#" (a skimmer), "K1TTT-2" (an SSID)
    return s;
}

SpotPlace stationPlace(std::string_view call, std::string_view grid, const CountryTable *countries) {
    SpotPlace p;
    std::string g = trimmed(grid);
    double lat = 0, lon = 0;
    if (g.size() >= 4 && !isPlaceholderGrid(g) && gridToLatLon(g, &lat, &lon)) {
        p.ok = true, p.exact = g.size() >= 6, p.lat = lat, p.lon = lon, p.from = "grid";
        return p;
    }
    CountryInfo info;
    if (countries && !countries->empty() && !call.empty() && countries->lookup(call, &info) && info.dxcc &&
        !(info.lat == 0 && info.lon == 0)) {
        p.ok = true, p.lat = info.lat, p.lon = info.lon, p.from = "country data";
    }
    return p;
}

namespace {
bool validPlace(double lat, double lon) {
    return std::isfinite(lat) && std::isfinite(lon) && std::fabs(lat) <= 90 && std::fabs(lon) <= 180 && !isPlaceholderPlace(lat, lon);
}
}  // namespace

SpotPlace spotPlace(const Spot &s, const CountryTable *countries) {
    if (s.placeGiven && validPlace(s.lat, s.lon)) {
        SpotPlace p;
        p.ok = true, p.exact = s.placeExact, p.lat = s.lat, p.lon = s.lon, p.from = "spot";
        return p;
    }
    return stationPlace(s.activator, s.grid, countries);
}

SpotPlace spotterPlace(const Spot &s, const CountryTable *countries) {
    if (s.spotterPlaceGiven && validPlace(s.spotterLat, s.spotterLon)) {
        SpotPlace p;
        p.ok = true, p.lat = s.spotterLat, p.lon = s.spotterLon, p.from = "spot";
        return p;
    }
    return stationPlace(spotterCall(s.spotter), s.spotterGrid, countries);
}

MapQso spotQso(const Spot &s, const CountryTable *countries) {
    MapQso q;
    q.call = upper(trimmed(s.activator));
    q.band = s.band;
    q.mode = s.mode;
    q.modeGroup = modeGroup(s.mode);
    q.grid = trimmed(s.grid);
    double lat = 0, lon = 0;
    if (s.placeGiven && s.placeExact && validPlace(s.lat, s.lon)) {
        q.located = true, q.lat = s.lat, q.lon = s.lon, q.locatedBy = "spot";
    } else if (q.grid.size() >= 6 && !isPlaceholderGrid(q.grid) && gridToLatLon(q.grid, &lat, &lon)) {
        q.located = true, q.lat = lat, q.lon = lon, q.locatedBy = q.grid;
    }
    if (equalsNoCase(s.program, "POTA") || s.source == SpotSource::Pota)
        for (const std::string &r : s.refs.empty() ? std::vector<std::string>{s.reference} : s.refs)
            if (!r.empty()) q.potaHunted.push_back(potaListRef(r));
    q.areas = resolveAreas(placeFacts(q, countries));
    return q;
}

std::vector<BandActivity> bandActivity(const std::vector<Spot> &spots, bool hasHome, double homeLat, double homeLon, double nearKm,
                                       const CountryTable *countries) {
    struct Tally {
        std::set<std::string> stations, spotters, nearSpotters, nearStations;
        std::map<std::string, std::set<std::string>> continents;
        bool snr = false;
        int best = 0;
        long long newest = 0;
    };
    std::map<std::string, Tally> byBand;
    for (const Spot &s : spots) {
        if (s.heardMe || s.band.empty() || trimmed(s.activator).empty()) continue;
        std::string band = s.band;
        for (char &c : band) c = (char)std::tolower((unsigned char)c);
        Tally &t = byBand[band];
        std::string station = upper(trimmed(s.activator));
        t.stations.insert(station);
        t.newest = std::max(t.newest, s.epoch);
        CountryInfo info;
        if (countries && !countries->empty() && countries->lookup(station, &info) && !info.continent.empty()) t.continents[info.continent].insert(station);
        if (s.spotter.empty()) continue;
        std::string by = spotterCall(s.spotter);
        t.spotters.insert(by);
        if (!hasHome) continue;
        SpotPlace at = spotterPlace(s, countries);
        if (!at.ok || greatCircleKm(homeLat, homeLon, at.lat, at.lon) > nearKm) continue;
        t.nearSpotters.insert(by);
        t.nearStations.insert(station);
        if (s.hasSnr && (!t.snr || s.snr > t.best)) t.snr = true, t.best = s.snr;
    }
    std::vector<BandActivity> out;
    for (const auto &[band, t] : byBand) {
        BandActivity a;
        a.band = band, a.stations = t.stations.size(), a.spotters = t.spotters.size(), a.nearSpotters = t.nearSpotters.size();
        a.nearStations = t.nearStations.size(), a.nearSnr = t.snr, a.bestNearSnr = t.best, a.newest = t.newest;
        for (const auto &[cont, calls] : t.continents) a.continents.emplace_back(cont, calls.size());
        std::stable_sort(a.continents.begin(), a.continents.end(), [](const auto &x, const auto &y) { return x.second > y.second; });
        out.push_back(std::move(a));
    }
    std::stable_sort(out.begin(), out.end(), [](const BandActivity &x, const BandActivity &y) { return bandOrder(x.band) < bandOrder(y.band); });
    return out;
}

bool spotMatches(const SpotFilter &f, const Spot &s, long long now, const CountryTable *countries, const PotaParks *parks) {
    if (f.maxAge > 0 && s.epoch > 0 && now - s.epoch > f.maxAge) return false;
    if (!f.onlyCall.empty() && !sameStation(s.activator, f.onlyCall)) return false;
    if (!f.sources.empty() && !f.sources.count(s.source)) return false;
    if (!f.programs.empty() && !f.programs.count(s.program)) return false;
    if (!f.map.band.empty() && !equalsNoCase(s.band, f.map.band)) return false;
    if (!f.map.mode.empty() && !equalsNoCase(s.mode, f.map.mode)) return false;
    if (!f.map.any()) return true;
    return placeMatches(f.map, spotQso(s, countries), parks);
}

void SpotList::add(Spot s) {
    auto it = std::find_if(spots_.begin(), spots_.end(), [&](const Spot &x) { return x.source == s.source && x.key == s.key; });
    if (it != spots_.end()) spots_.erase(it);
    auto at = std::find_if(spots_.begin(), spots_.end(), [&](const Spot &x) { return x.epoch <= s.epoch; });
    spots_.insert(at, std::move(s));
    trim();
}

void SpotList::replace(SpotSource source, std::vector<Spot> spots) {
    clear(source);
    for (Spot &s : spots) {
        s.source = source;
        spots_.push_back(std::move(s));
    }
    std::stable_sort(spots_.begin(), spots_.end(), [](const Spot &a, const Spot &b) { return a.epoch > b.epoch; });
    trim();
}

void SpotList::prune(long long now, long long maxAge) {
    if (maxAge <= 0) return;
    spots_.erase(std::remove_if(spots_.begin(), spots_.end(), [&](const Spot &s) { return s.epoch > 0 && now - s.epoch > maxAge; }),
                 spots_.end());
}

void SpotList::clear(SpotSource source) {
    spots_.erase(std::remove_if(spots_.begin(), spots_.end(), [&](const Spot &s) { return s.source == source; }), spots_.end());
}

void SpotList::trim() {
    if (spots_.size() > limit_) spots_.resize(limit_);
}

std::vector<std::pair<std::string, std::string>> spotQsoFields(const Spot &s) {
    switch (s.source) {
        case SpotSource::Pota: return spotFields(s.activator, s.khz, s.mode, s.reference);
        case SpotSource::Wwff: return programSpotFields(Program::WWFF, s.activator, s.khz, s.mode, s.reference);
        case SpotSource::Spothole:
            if (!s.program.empty()) return spotholeSpotFields(s.program, s.activator, s.khz, s.mode, s.refs, s.grid);
            break;
        case SpotSource::Cluster:
        case SpotSource::PskReporter: break;
    }
    std::vector<std::pair<std::string, std::string>> out = spotFields(s.activator, s.khz, s.mode, "");
    std::string g = trimmed(s.grid);
    double lat, lon;
    if (g.size() >= 4 && !isPlaceholderGrid(g) && gridToLatLon(g, &lat, &lon)) {
        if (g.size() >= 6) g = upper(g.substr(0, 4)) + std::string(1, (char)std::tolower((unsigned char)g[4])) +
                               std::string(1, (char)std::tolower((unsigned char)g[5])) + g.substr(6);
        else g = upper(g);
        out.emplace_back("GRIDSQUARE", g);
    }
    return out;
}

std::vector<Spot> latestPerStation(const std::vector<Spot> &spots) {
    std::vector<Spot> out;
    std::unordered_set<std::string> seen;
    std::vector<const Spot *> order;
    for (const Spot &s : spots) order.push_back(&s);
    std::stable_sort(order.begin(), order.end(), [](const Spot *a, const Spot *b) { return a->epoch > b->epoch; });
    for (const Spot *s : order)
        if (seen.insert(upper(trimmed(s->activator)) + "|" + s->band).second) out.push_back(*s);
    return out;
}

std::string spotKhz(double hz) {
    if (!(hz > 0) || !std::isfinite(hz)) return "";
    char khz[32];
    std::snprintf(khz, sizeof khz, "%.3f", hz / 1000);
    std::string s = khz;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    return s;
}

std::string spotTime(long long epoch) {
    if (epoch <= 0) return "";
    std::time_t t = (std::time_t)epoch;
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[8];
    std::snprintf(buf, sizeof buf, "%02d:%02d", tm.tm_hour, tm.tm_min);
    return buf;
}

void TelnetLines::feed(std::string_view bytes, std::vector<std::string> *lines, std::string *reply) {
    // RFC 854: IAC 255; WILL 251, WONT 252, DO 253, DONT 254 take an option byte; SB 250 starts a
    // subnegotiation that IAC SE (240) ends; IAC IAC is a data byte 255.
    constexpr unsigned char IAC = 255, WILL = 251, WONT = 252, DO = 253, DONT = 254, SB = 250, SE = 240;
    for (unsigned char c : bytes) {
        switch (state_) {
            case State::Iac:
                if (c >= WILL && c <= DONT) verb_ = c, state_ = State::Option;
                else if (c == SB) state_ = State::Sub;
                else state_ = State::Text;  // IAC IAC (a data byte, dropped here) or a command without an option
                continue;
            case State::Option:
                state_ = State::Text;
                if ((verb_ == WILL || verb_ == DO) && refused_.insert((verb_ << 8) | c).second && reply) {
                    reply->push_back((char)IAC);
                    reply->push_back((char)(verb_ == WILL ? DONT : WONT));
                    reply->push_back((char)c);
                }
                continue;
            case State::Sub:
                if (c == IAC) state_ = State::SubIac;
                continue;
            case State::SubIac:
                state_ = c == SE ? State::Text : State::Sub;
                continue;
            case State::Text: break;
        }
        if (c == IAC) {
            state_ = State::Iac;
            continue;
        }
        if (c == '\n' && cr_) {  // the LF of CR LF
            cr_ = false;
            continue;
        }
        cr_ = c == '\r';
        if (c == '\r' || c == '\n') {
            if (lines) lines->push_back(line_);
            line_.clear();
        } else if (c >= 32 && c < 127 && line_.size() < limit_) {
            line_.push_back((char)c);
        }
    }
}

namespace {

std::vector<std::string_view> words(std::string_view s) {
    std::vector<std::string_view> out;
    for (size_t i = 0; i < s.size();) {
        while (i < s.size() && s[i] == ' ') ++i;
        size_t b = i;
        while (i < s.size() && s[i] != ' ') ++i;
        if (i > b) out.push_back(s.substr(b, i - b));
    }
    return out;
}

bool callShaped(std::string_view c, bool spotter) {
    if (c.size() < 3 || c.size() > (spotter ? 20 : 16)) return false;
    bool letter = false, digit = false;
    for (char ch : c) {
        unsigned char u = (unsigned char)ch;
        if (std::isalpha(u)) letter = true;
        else if (std::isdigit(u)) digit = true;
        else if (ch != '/' && !(spotter && (ch == '-' || ch == '#'))) return false;
    }
    return letter && digit;
}

bool gridShaped(std::string_view g) {
    return g.size() == 4 && std::isalpha((unsigned char)g[0]) && std::isalpha((unsigned char)g[1]) && std::isdigit((unsigned char)g[2]) &&
           std::isdigit((unsigned char)g[3]) && std::toupper((unsigned char)g[0]) <= 'R' && std::toupper((unsigned char)g[1]) <= 'R';
}

bool smallNumber(std::string_view w) {
    return !w.empty() && w.size() <= 2 && std::all_of(w.begin(), w.end(), [](char c) { return std::isdigit((unsigned char)c); });
}

bool stateShaped(std::string_view w) { return w.size() == 2 && std::isupper((unsigned char)w[0]) && std::isupper((unsigned char)w[1]); }

// A report such as "-9" or "+1" before "dB": up to three characters, digits with an optional
// leading sign (a live DXSpider node relayed "FT8 +1 dB 1383 Hz", 2026-10-19).
bool reportShaped(std::string_view n) {
    if (n.size() > 3) return false;
    if (!n.empty() && (n[0] == '-' || n[0] == '+')) n.remove_prefix(1);
    return !n.empty() && n.find_first_not_of("0123456789") == std::string_view::npos;
}

// The modes a spot's comment names, as ADIF or the spot sites write them.
const char *const kSpotModes[] = {"CW", "SSB", "USB", "LSB", "AM", "FM", "FT8", "FT4", "RTTY", "PSK31", "PSK63", "BPSK31", "JS8",
                                  "JT65", "JT9", "Q65", "MSK144", "FST4", "OLIVIA", "SSTV", "MFSK", "DIGITALVOICE"};

}  // namespace

bool parseClusterSpot(std::string_view line, long long now, Spot *out) {
    std::string_view l = line;
    size_t start = l.find("DX de ");
    if (start == std::string_view::npos || start > 200) return false;
    l.remove_prefix(start);  // after a prompt with no line end ("K9TST de NODE 0724Z dxspider >")
    while (!l.empty() && (l.back() == ' ' || l.back() == '\a')) l.remove_suffix(1);
    if (l.size() < 20) return false;
    l.remove_prefix(6);
    size_t colon = l.find(':');
    if (colon == std::string_view::npos || colon == 0) return false;
    std::string_view spotter = l.substr(0, colon);
    while (!spotter.empty() && spotter.back() == ' ') spotter.remove_suffix(1);
    if (!callShaped(spotter, true)) return false;
    std::vector<std::string_view> w = words(l.substr(colon + 1));
    if (w.size() < 3) return false;
    // The frequency and call, then the time: the last word shaped HHMMZ.
    std::string f(w[0]);
    if (f.find_first_not_of("0123456789.") != std::string::npos) return false;
    char *end = nullptr;
    double khz = std::strtod(f.c_str(), &end);
    if (!end || *end || !(khz > 0) || khz > 300e6) return false;
    std::string_view call = w[1];
    if (!callShaped(call, false)) return false;
    size_t t = std::string::npos;
    for (size_t i = w.size(); i-- > 2;)
        if (w[i].size() == 5 && w[i][4] == 'Z' && std::all_of(w[i].begin(), w[i].end() - 1, [](char c) { return std::isdigit((unsigned char)c); })) {
            t = i;
            break;
        }
    if (t == std::string::npos || w.size() - t > 2) return false;
    int hh = (w[t][0] - '0') * 10 + (w[t][1] - '0'), mm = (w[t][2] - '0') * 10 + (w[t][3] - '0');
    if (hh > 23 || mm > 59) return false;
    std::vector<std::string_view> comment(w.begin() + 2, w.begin() + (long)t);
    Spot sp;
    sp.source = SpotSource::Cluster;
    // The slot after the time: the spotter's grid (and the station's at the comment's end), or
    // zones or states, whose station half ends the comment.
    if (t + 1 < w.size()) {
        std::string_view slot = w[t + 1];
        bool grid = gridShaped(slot);
        if (grid) sp.spotterGrid = upper(slot);
        if (!comment.empty()) {
            std::string_view last = comment.back();
            if ((grid && gridShaped(last)) || (smallNumber(slot) && smallNumber(last)) || (stateShaped(slot) && stateShaped(last))) {
                if (grid) sp.grid = upper(last);
                comment.pop_back();
            }
        }
    }
    for (size_t i = 0; i < comment.size(); ++i) {
        sp.comments += (i ? " " : "") + std::string(comment[i]);
        std::string u = upper(comment[i]);
        if (sp.mode.empty())
            for (const char *m : kSpotModes)
                if (u == m) sp.mode = m;
    }
    sp.hasSnr = commentReport(sp.comments, &sp.snr);
    sp.spotter = upper(spotter);
    sp.activator = upper(call);
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.1f", khz);
    sp.khz = buf;
    if (sp.khz.size() > 2 && sp.khz.compare(sp.khz.size() - 2, 2, ".0") == 0) sp.khz.resize(sp.khz.size() - 2);
    sp.band = bandForFrequency(khzToMHz(sp.khz));
    long long day = now - ((now % 86400) + 86400) % 86400;
    long long at = day + hh * 3600 + mm * 60;
    if (at > now + 600) at -= 86400;  // a time ahead of now was yesterday's
    sp.epoch = at;
    sp.time = spotTime(at);
    sp.key = sp.spotter + "|" + sp.activator + "|" + sp.khz + "|" + std::string(w[t]);
    if (out) *out = std::move(sp);
    return true;
}

ClusterPrompt clusterPrompt(std::string_view text) {
    std::string t = trimmed(text);
    for (char &c : t) c = (char)std::tolower((unsigned char)c);
    auto ends = [&](const char *x) {
        size_t n = std::strlen(x);
        return t.size() >= n && t.compare(t.size() - n, n, x) == 0;
    };
    if (t.find("invalid callsign") != std::string::npos || t.rfind("sorry ", 0) == 0) return ClusterPrompt::Refused;
    if (ends("password:")) return ClusterPrompt::Password;
    if (ends("login:") || ends("call:") || ends("callsign:")) return ClusterPrompt::Login;
    return ClusterPrompt::None;
}

namespace {

// The attributes of one tag's text (after its name, before ">"): name="value", name='value' or
// name=value; &amp; &lt; &gt; &quot; &apos; decoded.
std::map<std::string, std::string> tagAttributes(std::string_view t) {
    std::map<std::string, std::string> out;
    size_t i = 0;
    while (i < t.size()) {
        while (i < t.size() && (std::isspace((unsigned char)t[i]) || t[i] == '/')) ++i;
        size_t nb = i;
        while (i < t.size() && (std::isalnum((unsigned char)t[i]) || t[i] == '_' || t[i] == '-' || t[i] == ':')) ++i;
        std::string name(t.substr(nb, i - nb));
        if (name.empty()) {
            if (i < t.size()) ++i;
            continue;
        }
        while (i < t.size() && std::isspace((unsigned char)t[i])) ++i;
        if (i >= t.size() || t[i] != '=') continue;
        ++i;
        while (i < t.size() && std::isspace((unsigned char)t[i])) ++i;
        std::string value;
        if (i < t.size() && (t[i] == '"' || t[i] == '\'')) {
            char q = t[i++];
            size_t e = t.find(q, i);
            if (e == std::string_view::npos) e = t.size();
            value = std::string(t.substr(i, e - i));
            i = e + 1;
        } else {
            size_t vb = i;
            while (i < t.size() && !std::isspace((unsigned char)t[i]) && t[i] != '/') ++i;
            value = std::string(t.substr(vb, i - vb));
        }
        std::string decoded;
        for (size_t k = 0; k < value.size(); ++k) {
            if (value[k] == '&') {
                static const std::pair<const char *, char> kEnts[] = {{"&amp;", '&'}, {"&lt;", '<'}, {"&gt;", '>'}, {"&quot;", '"'}, {"&apos;", '\''}};
                bool done = false;
                for (const auto &[ent, ch] : kEnts)
                    if (value.compare(k, std::strlen(ent), ent) == 0) {
                        decoded.push_back(ch), k += std::strlen(ent) - 1, done = true;
                        break;
                    }
                if (done) continue;
            }
            decoded.push_back(value[k]);
        }
        if (out.size() < 64) out[name] = decoded;
    }
    return out;
}

std::string printable(std::string_view s, size_t limit) {
    std::string o;
    for (char c : s)
        if (c >= 32 && c < 127 && o.size() < limit) o.push_back(c);
    return o;
}

}  // namespace

bool parsePskReports(std::string_view xml, std::vector<Spot> *out, std::string *why, size_t limit, std::string_view me) {
    std::string mine = upper(trimmed(me));
    if (out) out->clear();
    if (xml.find("<receptionReports") == std::string_view::npos) {
        if (why) *why = tr("PSKReporter sent something other than its reception reports");
        return false;
    }
    for (size_t at = xml.find("<receptionReport"); at != std::string_view::npos; at = xml.find("<receptionReport", at + 1)) {
        size_t nameEnd = at + std::strlen("<receptionReport");
        if (nameEnd < xml.size() && xml[nameEnd] == 's') continue;  // the root
        size_t end = xml.find('>', nameEnd);
        if (end == std::string_view::npos || end - nameEnd > 4096) break;
        std::map<std::string, std::string> a = tagAttributes(xml.substr(nameEnd, end - nameEnd));
        auto get = [&](const char *k) {
            auto it = a.find(k);
            return it == a.end() ? std::string() : it->second;
        };
        Spot sp;
        sp.source = SpotSource::PskReporter;
        std::string sender = upper(printable(trimmed(get("senderCallsign")), 20));
        std::string receiver = upper(printable(trimmed(get("receiverCallsign")), 20));
        std::string senderGrid = printable(trimmed(get("senderLocator")), 10), receiverGrid = printable(trimmed(get("receiverLocator")), 10);
        sp.heardMe = !mine.empty() && spotterCall(sender) == spotterCall(mine);  // your own signal
        sp.activator = sender, sp.spotter = receiver;
        sp.grid = senderGrid, sp.spotterGrid = receiverGrid;
        sp.khz = spotKhz(std::atof(get("frequency").c_str()));
        sp.mode = upper(printable(trimmed(get("mode")), 12));
        long long t = std::atoll(get("flowStartSeconds").c_str());
        if (sp.activator.empty() || sp.khz.empty() || t <= 0) continue;
        sp.epoch = t, sp.time = spotTime(t);
        std::string snr = trimmed(get("sNR"));
        if (reportShaped(snr)) sp.snr = std::atoi(snr.c_str()), sp.hasSnr = true;
        sp.band = bandForFrequency(khzToMHz(sp.khz));
        sp.key = sp.activator + "|" + sp.spotter + "|" + sp.khz + "|" + std::to_string(t);
        if (out) out->push_back(std::move(sp));
        if (out && out->size() >= limit) break;
    }
    return true;
}

std::string pskQueryUrl(std::string_view callOrGrid, PskQuery query, long long seconds, std::string_view appcontact) {
    auto encode = [](std::string_view v) {
        std::string o;
        for (unsigned char c : v) {
            if (std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~') o.push_back((char)c);
            else {
                char b[4];
                std::snprintf(b, sizeof b, "%%%02X", c);
                o += b;
            }
        }
        return o;
    };
    seconds = std::clamp<long long>(seconds, 60, 86400);
    std::string what = upper(trimmed(callOrGrid));
    if (query == PskQuery::Grid) what = what.substr(0, 4);
    std::string url = "https://retrieve.pskreporter.info/query?callsign=" + encode(what) + (query == PskQuery::Grid ? "&modify=grid" : "") +
                      "&flowStartSeconds=-" + std::to_string(seconds) + "&rronly=1&rptlimit=1000";
    std::string contact = trimmed(appcontact);
    if (!contact.empty()) url += "&appcontact=" + encode(contact);
    return url;
}

long long spotEpoch(std::string_view utc) {
    std::string t = trimmed(utc);
    int y, mo, d, h, mi, se = 0;
    char sep = 0;
    if (t.size() < 16 || std::sscanf(t.c_str(), "%4d-%2d-%2d%c%2d:%2d", &y, &mo, &d, &sep, &h, &mi) != 6 || (sep != 'T' && sep != ' '))
        return 0;
    if (t.size() >= 19 && t[16] == ':') std::sscanf(t.c_str() + 17, "%2d", &se);
    if (t.size() > 19) {  // only UTC: "Z" or a zero offset, after optional fractions of a second
        size_t z = t[19] == '.' ? t.find_first_not_of("0123456789", 20) : 19;
        std::string zone = z == std::string::npos ? "" : t.substr(z);
        if (!zone.empty() && zone != "Z" && zone != "+00:00" && zone != "+0000" && zone != "-00:00") return 0;
    }
    if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60) return 0;
    // Days from the civil date (Howard Hinnant's days_from_civil).
    int yy = y - (mo <= 2);
    long era = (yy >= 0 ? yy : yy - 399) / 400;
    long yoe = yy - era * 400;
    long doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long long days = era * 146097LL + doe - 719468;
    return days * 86400 + h * 3600 + mi * 60 + se;
}

bool commentReport(std::string_view comment, int *snr) {
    std::vector<std::string> words;
    for (size_t i = 0; i < comment.size();) {
        size_t j = comment.find(' ', i);
        if (j == std::string_view::npos) j = comment.size();
        if (j > i) words.push_back(upper(comment.substr(i, j - i)));
        i = j + 1;
    }
    for (size_t i = 0; i < words.size(); ++i) {
        const std::string &u = words[i];
        if (u.size() > 2 && u.compare(u.size() - 2, 2, "DB") == 0 && reportShaped(std::string_view(u).substr(0, u.size() - 2)))
            return *snr = std::atoi(u.c_str()), true;  // "4dB", "-9dB"
        if (u == "DB" && i > 0 && reportShaped(words[i - 1])) return *snr = std::atoi(words[i - 1].c_str()), true;  // "15 dB"
    }
    return false;
}

namespace {
// A callsign's shape: letters, digits and "/", 3 to 20 of them, with a letter and a digit.
bool callShaped(std::string_view c) {
    if (c.size() < 3 || c.size() > 20 || c.front() == '/' || c.back() == '/') return false;
    bool letter = false, digit = false;
    for (char ch : c) {
        if (std::isalpha((unsigned char)ch)) letter = true;
        else if (std::isdigit((unsigned char)ch)) digit = true;
        else if (ch != '/') return false;
    }
    return letter && digit;
}
std::string longestPart(std::string_view call) {
    std::string best, part;
    for (char ch : upper(trimmed(call)) + "/") {
        if (ch != '/') {
            part.push_back(ch);
            continue;
        }
        if (part.size() > best.size()) best = part;
        part.clear();
    }
    return best;
}
}  // namespace

bool sameStation(std::string_view a, std::string_view b) {
    std::string x = longestPart(spotterCall(a)), y = longestPart(spotterCall(b));
    return !x.empty() && x == y;
}

std::string clusterSpotCommand(std::string_view call, double khz, std::string_view remarks, std::string_view myCall) {
    std::string c = upper(trimmed(call));
    if (!callShaped(c) || sameStation(c, myCall) || !(khz >= 100 && khz < 300000000) || !std::isfinite(khz)) return "";
    char f[32];
    std::snprintf(f, sizeof f, "%.1f", khz);
    std::string text;
    for (char ch : trimmed(remarks))
        if (ch >= 32 && ch < 127 && text.size() < 30) text.push_back(ch);
    while (!text.empty() && text.back() == ' ') text.pop_back();
    return std::string("dx ") + f + " " + c + (text.empty() ? "" : " " + text);
}

ClusterPostAnswer clusterPostAnswer(std::string_view line, std::string_view myCall, std::string_view call, long long now) {
    Spot sp;
    if (parseClusterSpot(line, now, &sp))
        return sameStation(sp.spotter, myCall) && sameStation(sp.activator, call) ? ClusterPostAnswer::Accepted : ClusterPostAnswer::None;
    std::string l = upper(line);
    for (const char *no : {"SORRY", "NOT ALLOWED", "NOT REGISTERED", "MUST BE REGISTERED", "REQUIRES REGISTRATION", "INVALID", "ERROR"})
        if (l.find(no) != std::string::npos) return ClusterPostAnswer::Refused;
    return ClusterPostAnswer::None;
}

std::string qsoSpotComment(const FieldList &fields) {
    auto get = [&](const char *k) {
        for (const auto &f : fields)
            if (f.first == k) return trimmed(f.second);
        return std::string();
    };
    std::string program = upper(get("SIG")), ref = get("SIG_INFO");
    if (std::string pota = get("POTA_REF"); !pota.empty()) program = "POTA", ref = pota;
    else if (std::string wwff = get("WWFF_REF"); !wwff.empty()) program = "WWFF", ref = wwff;
    else if (std::string sota = get("SOTA_REF"); !sota.empty()) program = "SOTA", ref = sota;
    std::string mode = get("SUBMODE").empty() ? get("MODE") : get("SUBMODE");
    std::string out = ref.empty() ? "" : (program.empty() ? ref : program + " " + ref);
    if (!mode.empty()) out += (out.empty() ? "" : " ") + upper(mode);
    return out;
}

std::string spotAge(long long epoch, long long now) {
    if (epoch <= 0 || now <= 0) return "";
    long long minutes = std::max<long long>(0, now - epoch) / 60;
    return minutes == 0 ? tr("just now") : i18n::trf("{n} min", {{"n", std::to_string(minutes)}});
}

std::string spotSnr(const Spot &s) {
    if (!s.hasSnr) return "";
    char db[16];
    std::snprintf(db, sizeof db, "%+d dB", s.snr);
    return db;
}

std::string spotLabelDetails(const Spot &s, const SpotLabel &show, long long now) {
    std::vector<std::string> parts;
    if (show.mode && !s.mode.empty()) parts.push_back(s.mode);
    if (show.khz && !s.khz.empty()) parts.push_back(s.khz + " kHz");
    if (show.age)
        if (std::string age = spotAge(s.epoch, now); !age.empty()) parts.push_back(age);
    if (show.snr && s.hasSnr) parts.push_back(spotSnr(s));
    std::string out;
    for (const std::string &p : parts) out += (out.empty() ? "" : " \u00B7 ") + p;
    return out;
}

}  // namespace adif
