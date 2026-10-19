#include "adif_regions.h"

#include "adif_i18n.h"

#include <algorithm>

namespace adif {
namespace {

std::vector<UsRegion> build() {
    std::vector<UsRegion> r;
    auto add = [&](const char *id, const char *name, const char *kind, std::vector<std::string> states, std::vector<std::string> sections = {}) {
        r.push_back({id, name, kind, std::move(states), std::move(sections)});
    };
    const char *calls = N_("Call areas");
    add("W1", N_("Call area 1 (CT, ME, MA, NH, RI, VT)"), calls, {"CT", "ME", "MA", "NH", "RI", "VT"});
    add("W2", N_("Call area 2 (NJ, NY)"), calls, {"NJ", "NY"});
    add("W3", N_("Call area 3 (DE, DC, MD, PA)"), calls, {"DE", "DC", "MD", "PA"});
    add("W4", N_("Call area 4 (AL, FL, GA, KY, NC, SC, TN, VA)"), calls, {"AL", "FL", "GA", "KY", "NC", "SC", "TN", "VA"});
    add("W5", N_("Call area 5 (AR, LA, MS, NM, OK, TX)"), calls, {"AR", "LA", "MS", "NM", "OK", "TX"});
    add("W6", N_("Call area 6 (CA)"), calls, {"CA"});
    add("W7", N_("Call area 7 (AZ, ID, MT, NV, OR, UT, WA, WY)"), calls, {"AZ", "ID", "MT", "NV", "OR", "UT", "WA", "WY"});
    add("W8", N_("Call area 8 (MI, OH, WV)"), calls, {"MI", "OH", "WV"});
    add("W9", N_("Call area 9 (IL, IN, WI)"), calls, {"IL", "IN", "WI"});
    add("W0", N_("Call area 0 (CO, IA, KS, MN, MO, NE, ND, SD)"), calls, {"CO", "IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("KL7", N_("Alaska (KL7)"), calls, {"AK"});
    add("KH6", N_("Hawaii (KH6)"), calls, {"HI"});

    const char *regions = N_("Census regions"), *divisions = N_("Census divisions");
    add("Census-Northeast", N_("Northeast"), regions, {"CT", "ME", "MA", "NH", "RI", "VT", "NJ", "NY", "PA"});
    add("Census-Midwest", N_("Midwest"), regions, {"IL", "IN", "MI", "OH", "WI", "IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("Census-South", N_("South"), regions,
        {"DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV", "AL", "KY", "MS", "TN", "AR", "LA", "OK", "TX"});
    add("Census-West", N_("West"), regions, {"AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY", "AK", "CA", "HI", "OR", "WA"});
    add("Census-NewEngland", N_("New England"), divisions, {"CT", "ME", "MA", "NH", "RI", "VT"});
    add("Census-MiddleAtlantic", N_("Middle Atlantic"), divisions, {"NJ", "NY", "PA"});
    add("Census-EastNorthCentral", N_("East North Central"), divisions, {"IL", "IN", "MI", "OH", "WI"});
    add("Census-WestNorthCentral", N_("West North Central"), divisions, {"IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("Census-SouthAtlantic", N_("South Atlantic"), divisions, {"DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV"});
    add("Census-EastSouthCentral", N_("East South Central"), divisions, {"AL", "KY", "MS", "TN"});
    add("Census-WestSouthCentral", N_("West South Central"), divisions, {"AR", "LA", "OK", "TX"});
    add("Census-Mountain", N_("Mountain"), divisions, {"AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY"});
    add("Census-Pacific", N_("Pacific"), divisions, {"AK", "CA", "HI", "OR", "WA"});

    // States wholly in one division, and every division's sections (split states: CA, NY, NJ).
    const char *arrl = N_("ARRL divisions");
    add("ARRL-Atlantic", N_("Atlantic Division"), arrl, {"DE", "PA", "MD", "DC"}, {"DE", "EPA", "MDC", "NNY", "SNJ", "WNY", "WPA"});
    add("ARRL-Central", N_("Central Division"), arrl, {"IL", "IN", "WI"}, {"IL", "IN", "WI"});
    add("ARRL-Dakota", N_("Dakota Division"), arrl, {"MN", "ND", "SD"}, {"MN", "ND", "SD"});
    add("ARRL-Delta", N_("Delta Division"), arrl, {"AR", "LA", "MS", "TN"}, {"AR", "LA", "MS", "TN"});
    add("ARRL-GreatLakes", N_("Great Lakes Division"), arrl, {"KY", "MI", "OH"}, {"KY", "MI", "OH"});
    add("ARRL-Hudson", N_("Hudson Division"), arrl, {}, {"ENY", "NLI", "NNJ"});
    add("ARRL-Midwest", N_("Midwest Division"), arrl, {"IA", "KS", "MO", "NE"}, {"IA", "KS", "MO", "NE"});
    add("ARRL-NewEngland", N_("New England Division"), arrl, {"CT", "MA", "ME", "NH", "RI", "VT"}, {"CT", "EMA", "ME", "NH", "RI", "VT", "WMA"});
    add("ARRL-Northwestern", N_("Northwestern Division"), arrl, {"AK", "WA", "ID", "MT", "OR"}, {"AK", "EWA", "ID", "MT", "OR", "WWA"});
    add("ARRL-Pacific", N_("Pacific Division"), arrl, {"NV", "HI"}, {"EB", "NV", "PAC", "SF", "SJV", "SCV", "SV"});
    add("ARRL-Roanoke", N_("Roanoke Division"), arrl, {"NC", "SC", "VA", "WV"}, {"NC", "SC", "VA", "WV"});
    add("ARRL-RockyMountain", N_("Rocky Mountain Division"), arrl, {"CO", "NM", "UT", "WY"}, {"CO", "NM", "UT", "WY"});
    add("ARRL-Southeastern", N_("Southeastern Division"), arrl, {"AL", "GA", "FL"}, {"AL", "GA", "NFL", "PR", "SFL", "VI", "WCF"});
    add("ARRL-Southwestern", N_("Southwestern Division"), arrl, {"AZ"}, {"AZ", "LAX", "ORG", "SB", "SDG"});
    add("ARRL-WestGulf", N_("West Gulf Division"), arrl, {"TX", "OK"}, {"NTX", "OK", "STX", "WTX"});
    return r;
}

std::string upper(std::string_view s) {
    std::string out;
    for (char c : s)
        if (c != ' ' && c != '\t') out += (char)(c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c);
    return out;
}

}  // namespace

const std::vector<UsRegion> &usRegions() {
    static const std::vector<UsRegion> regions = build();
    return regions;
}

const UsRegion *usRegion(std::string_view id) {
    for (const UsRegion &r : usRegions())
        if (r.id == id) return &r;
    return nullptr;
}

bool inUsRegion(const UsRegion &r, std::string_view state, std::string_view arrlSect) {
    std::string sect = upper(arrlSect), st = upper(state);
    if (!r.sections.empty() && !sect.empty()) return std::find(r.sections.begin(), r.sections.end(), sect) != r.sections.end();
    return !st.empty() && std::find(r.states.begin(), r.states.end(), st) != r.states.end();
}

}  // namespace adif
