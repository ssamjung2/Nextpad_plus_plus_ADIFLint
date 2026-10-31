#include "adif_needs.h"

#include "adif_enrich.h"
#include "adif_i18n.h"
#include "adif_palette.h"
#include "adif_parks.h"

#include <algorithm>
#include <cstdlib>

namespace adif {
namespace {

std::string lower(std::string s) {
    for (char &c : s)
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return s;
}

std::string upper(std::string s) {
    for (char &c : s)
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    return s;
}

int entityOf(int dxcc, const std::string &call, const CountryTable *countries) {
    if (dxcc > 0) return dxcc;
    CountryInfo info;
    return countries && !countries->empty() && countries->lookup(call, &info) ? info.dxcc : 0;
}

}  // namespace

WorkedIndex workedIndex(const std::vector<MapQso> &qsos, const CountryTable *countries) {
    WorkedIndex w;
    for (const MapQso &q : qsos) {
        std::string band = lower(q.band);
        int dxcc = entityOf(q.dxcc, q.call, countries);
        if (dxcc > 0) {
            WorkedIndex::Entity &e = w.entities[dxcc];
            ++e.qsos;
            e.confirmed |= q.confirmed;
            if (!band.empty()) e.bands.insert(band), e.slots.insert({band, q.modeGroup});
            e.modes.insert(q.modeGroup);
            if (q.confirmed) {
                if (!band.empty()) e.confirmedBands.insert(band);
                e.confirmedModes.insert(q.modeGroup);
            }
        }
        if (std::string key = lookupCall(q.call); !key.empty()) {
            WorkedIndex::Call &c = w.calls[key];
            ++c.qsos;
            c.confirmed |= q.confirmed;
            if (!band.empty()) c.bands.insert(band);
            c.modes.insert(q.modeGroup);
            int year = q.date8.size() >= 4 ? std::atoi(q.date8.substr(0, 4).c_str()) : 0;
            if (year > 0 && (c.firstYear == 0 || year < c.firstYear)) c.firstYear = year;
        }
        for (const std::string &p : q.potaHunted) w.parks.insert(p);
        if (q.grid.size() >= 4) {
            std::string g = q.grid.substr(0, 4);
            for (char &ch : g) ch = (char)toupper((unsigned char)ch);
            w.grids.insert(g);
        }
    }
    return w;
}

SpotStatus spotStatus(const WorkedIndex &w, const Spot &s, const CountryTable *countries) {
    SpotStatus st;
    if (std::string key = lookupCall(s.activator); !key.empty())
        if (auto it = w.calls.find(key); it != w.calls.end()) {
            st.callQsos = it->second.qsos, st.callFirstYear = it->second.firstYear, st.callConfirmed = it->second.confirmed;
            st.callBands = it->second.bands;
        }
    if (s.program == "POTA")
        for (const std::string &r : s.refs)
            if (std::string ref = potaListRef(r); !ref.empty() && !w.parks.count(ref)) st.newPark = true;
    CountryInfo info;
    if (!countries || countries->empty() || !countries->lookup(s.activator, &info) || info.dxcc <= 0) return st;
    st.dxcc = info.dxcc, st.entity = info.name;
    auto it = w.entities.find(info.dxcc);
    std::string band = lower(s.band);
    int mode = modeGroup(s.mode);
    if (it == w.entities.end()) st.need = SpotNeed::NewDxcc;
    else if (!band.empty() && !it->second.bands.count(band)) st.need = SpotNeed::NewBand;
    else if (!s.mode.empty() && !band.empty() && !it->second.slots.count({band, mode})) st.need = SpotNeed::NewMode;
    else st.need = (band.empty() ? it->second.confirmed : it->second.confirmedBands.count(band) > 0) ? SpotNeed::Confirmed : SpotNeed::Worked;
    return st;
}

std::vector<Interest> contactInterest(const WorkedIndex &w, const std::vector<MapQso> &qsos, const ContactSubject &c,
                                      const CountryTable *countries, const std::vector<std::string> &watch) {
    std::vector<Interest> out;
    std::string key = lookupCall(c.call);
    if (key.empty()) return out;
    Spot as;  // the contact as a spot, for what it means to the log
    as.activator = c.call, as.band = c.band, as.mode = c.mode, as.program = c.program, as.refs = c.refs;
    SpotStatus st = spotStatus(w, as, countries);
    if (std::string on = watchedFor(watch, as, st.entity); !on.empty()) out.push_back({InterestKind::Watched, i18n::trf("On your watch list ({what})", {{"what", on}})});

    // Today's QSOs with the call on this band and mode group: a duplicate.
    std::string band = lower(c.band);
    int group = modeGroup(c.mode);
    bool dupe = false;
    for (const MapQso &q : qsos)
        if (!c.date8.empty() && q.date8 == c.date8 && lookupCall(q.call) == key && lower(q.band) == band && !band.empty() &&
            (c.mode.empty() || q.modeGroup == group))
            dupe = true;
    std::string where = c.band + (c.mode.empty() ? "" : " " + c.mode);
    if (dupe) out.push_back({InterestKind::Duplicate, i18n::trf("Duplicate: {call} worked on {where} today already", {{"call", key}, {"where", where}})});
    else if (c.activating) out.push_back({InterestKind::NewForActivation, i18n::tr("New for this activation")});

    if (!c.activating) switch (st.need) {
            case SpotNeed::NewDxcc: out.push_back({InterestKind::NewDxcc, i18n::trf("New DXCC entity ({entity})", {{"entity", st.entity}})}); break;
            case SpotNeed::NewBand:
                out.push_back({InterestKind::NewBand, i18n::trf("Needed on {band}: {entity} not worked there", {{"band", c.band}, {"entity", st.entity}})});
                break;
            case SpotNeed::NewMode:
                out.push_back({InterestKind::NewMode, i18n::trf("A new mode for {entity} on {band}", {{"band", c.band}, {"entity", st.entity}})});
                break;
            case SpotNeed::Worked:
                if (!dupe)
                    out.push_back({InterestKind::Worked, i18n::trf("{entity} worked on {band}, not confirmed", {{"band", c.band}, {"entity", st.entity}})});
                break;
            case SpotNeed::Confirmed:
                if (!dupe) out.push_back({InterestKind::Confirmed, i18n::trf("{entity} confirmed on {band}", {{"band", c.band}, {"entity", st.entity}})});
                break;
            default: break;
        }

    std::string refs;
    for (const std::string &r : c.refs) refs += (refs.empty() ? "" : ", ") + r;
    if (!refs.empty()) {
        out.push_back({InterestKind::ParkToPark, c.activating      ? i18n::trf("Park to park: they are at {refs}", {{"refs", refs}})
                                                 : c.program.empty() ? i18n::trf("They are at {refs}", {{"refs", refs}})
                                                                     : i18n::trf("{program} activator at {refs}", {{"program", c.program}, {"refs", refs}})});
        if (st.newPark) out.push_back({InterestKind::NewPark, i18n::tr("A park you haven't hunted")});
    }

    if (st.callQsos) {
        std::string bands;
        for (const std::string &b : st.callBands) bands += (bands.empty() ? "" : ", ") + b;
        std::string had = i18n::trp("{n} QSO with this call before", "{n} QSOs with this call before", (long long)st.callQsos);
        if (!bands.empty()) had += " (" + bands + ")";
        if (st.callFirstYear) had += ", " + i18n::trf("first in {year}", {{"year", std::to_string(st.callFirstYear)}});
        had += st.callConfirmed ? ", " + i18n::tr("confirmed") : ", " + i18n::tr("not confirmed");
        out.push_back({InterestKind::Before, had});
    } else {
        out.push_back({InterestKind::FirstQso, c.activating ? i18n::tr("No QSOs with this call in this log yet") : i18n::tr("No QSOs with this call yet")});
    }
    return out;
}

std::string spotNeedText(SpotNeed n) {
    switch (n) {
        case SpotNeed::NewDxcc: return i18n::tr("new DXCC");
        case SpotNeed::NewBand: return i18n::tr("new band");
        case SpotNeed::NewMode: return i18n::tr("new mode");
        case SpotNeed::Worked: return i18n::tr("worked");
        case SpotNeed::Confirmed: return i18n::tr("confirmed");
        default: return "";
    }
}

bool spotWanted(const SpotStatus &st) {
    return st.need == SpotNeed::NewDxcc || st.need == SpotNeed::NewBand || st.need == SpotNeed::NewMode || st.newPark;
}

int spotPriority(const SpotStatus &st) {
    switch (st.need) {
        case SpotNeed::NewDxcc: return 0;
        case SpotNeed::NewBand: return 1;
        case SpotNeed::NewMode: return 2;
        default: return st.newPark ? 3 : 4;
    }
}

std::vector<std::string> watchList(std::string_view text) {
    std::vector<std::string> list;
    size_t i = 0;
    while (i <= text.size()) {
        size_t end = text.find_first_of(",\n\r", i);
        if (end == std::string_view::npos) end = text.size();
        std::string_view t = text.substr(i, end - i);
        while (!t.empty() && (t.front() == ' ' || t.front() == '\t')) t.remove_prefix(1);
        while (!t.empty() && (t.back() == ' ' || t.back() == '\t')) t.remove_suffix(1);
        std::string w = upper(std::string(t));
        if (!w.empty() && std::find(list.begin(), list.end(), w) == list.end()) list.push_back(w);
        i = end + 1;
    }
    return list;
}

std::string watchListText(const std::vector<std::string> &list) {
    std::string text;
    for (const std::string &w : list) text += (text.empty() ? "" : ", ") + w;
    return text;
}

std::string watchedFor(const std::vector<std::string> &list, const Spot &s, const std::string &entity) {
    if (list.empty()) return "";
    auto on = [&](const std::string &w) { return !w.empty() && std::find(list.begin(), list.end(), w) != list.end(); };
    std::string call = upper(lookupCall(s.activator));
    if (on(call)) return call;
    if (on(upper(s.activator))) return upper(s.activator);
    for (const std::string &r : s.refs)
        if (on(upper(r))) return upper(r);
    return on(upper(entity)) ? upper(entity) : "";
}

std::vector<std::pair<std::string, SlotState>> bandSlots(const WorkedIndex &w, int dxcc) {
    static const char *const kBands[] = {"160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m"};
    std::vector<std::string> bands(std::begin(kBands), std::end(kBands));
    auto it = w.entities.find(dxcc);
    if (it != w.entities.end())
        for (const std::string &b : it->second.bands)
            if (std::find(bands.begin(), bands.end(), b) == bands.end()) bands.push_back(b);
    std::stable_sort(bands.begin(), bands.end(), [](const std::string &a, const std::string &b) { return bandOrder(a) < bandOrder(b); });
    std::vector<std::pair<std::string, SlotState>> out;
    for (const std::string &b : bands) {
        SlotState st = SlotState::None;
        if (it != w.entities.end()) st = it->second.confirmedBands.count(b) ? SlotState::Confirmed : it->second.bands.count(b) ? SlotState::Worked : SlotState::None;
        out.emplace_back(b, st);
    }
    return out;
}

LogGlance logGlance(const std::vector<MapQso> &qsos, const WorkedIndex &w, const std::string &today) {
    LogGlance g;
    g.qsos = qsos.size();
    g.dxcc = w.entities.size();
    for (const auto &kv : w.entities) g.dxccConfirmed += kv.second.confirmed;
    g.grids = w.grids.size();
    std::set<std::string> states, bands;
    std::string last;
    for (const MapQso &q : qsos) {
        if (!q.areas.state.empty()) states.insert(q.areas.state);
        if (q.date8 != today) continue;
        ++g.today;
        ++g.todayModes[std::clamp(q.modeGroup, 0, 2)];
        if (!q.band.empty()) bands.insert(lower(q.band));
        if (q.time >= last) last = q.time, g.lastCall = q.call, g.lastTime = q.time;
    }
    g.states = states.size();
    g.todayBands.assign(bands.begin(), bands.end());
    std::sort(g.todayBands.begin(), g.todayBands.end(), [](const std::string &a, const std::string &b) { return bandOrder(a) < bandOrder(b); });
    return g;
}

}  // namespace adif
