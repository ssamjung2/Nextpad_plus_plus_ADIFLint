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
