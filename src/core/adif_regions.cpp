#include "adif_regions.h"

#include <algorithm>

namespace adif {
namespace {

std::vector<UsRegion> build() {
    std::vector<UsRegion> r;
    auto add = [&](const char *id, const char *name, const char *kind, std::vector<std::string> states, std::vector<std::string> sections = {}) {
        r.push_back({id, name, kind, std::move(states), std::move(sections)});
    };
    const char *calls = "Call areas";
    add("W1", "Call area 1 (CT, ME, MA, NH, RI, VT)", calls, {"CT", "ME", "MA", "NH", "RI", "VT"});
    add("W2", "Call area 2 (NJ, NY)", calls, {"NJ", "NY"});
    add("W3", "Call area 3 (DE, DC, MD, PA)", calls, {"DE", "DC", "MD", "PA"});
    add("W4", "Call area 4 (AL, FL, GA, KY, NC, SC, TN, VA)", calls, {"AL", "FL", "GA", "KY", "NC", "SC", "TN", "VA"});
    add("W5", "Call area 5 (AR, LA, MS, NM, OK, TX)", calls, {"AR", "LA", "MS", "NM", "OK", "TX"});
    add("W6", "Call area 6 (CA)", calls, {"CA"});
    add("W7", "Call area 7 (AZ, ID, MT, NV, OR, UT, WA, WY)", calls, {"AZ", "ID", "MT", "NV", "OR", "UT", "WA", "WY"});
    add("W8", "Call area 8 (MI, OH, WV)", calls, {"MI", "OH", "WV"});
    add("W9", "Call area 9 (IL, IN, WI)", calls, {"IL", "IN", "WI"});
    add("W0", "Call area 0 (CO, IA, KS, MN, MO, NE, ND, SD)", calls, {"CO", "IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("KL7", "Alaska (KL7)", calls, {"AK"});
    add("KH6", "Hawaii (KH6)", calls, {"HI"});

    const char *regions = "Census regions", *divisions = "Census divisions";
    add("Census-Northeast", "Northeast", regions, {"CT", "ME", "MA", "NH", "RI", "VT", "NJ", "NY", "PA"});
    add("Census-Midwest", "Midwest", regions, {"IL", "IN", "MI", "OH", "WI", "IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("Census-South", "South", regions,
        {"DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV", "AL", "KY", "MS", "TN", "AR", "LA", "OK", "TX"});
    add("Census-West", "West", regions, {"AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY", "AK", "CA", "HI", "OR", "WA"});
    add("Census-NewEngland", "New England", divisions, {"CT", "ME", "MA", "NH", "RI", "VT"});
    add("Census-MiddleAtlantic", "Middle Atlantic", divisions, {"NJ", "NY", "PA"});
    add("Census-EastNorthCentral", "East North Central", divisions, {"IL", "IN", "MI", "OH", "WI"});
    add("Census-WestNorthCentral", "West North Central", divisions, {"IA", "KS", "MN", "MO", "NE", "ND", "SD"});
    add("Census-SouthAtlantic", "South Atlantic", divisions, {"DE", "DC", "FL", "GA", "MD", "NC", "SC", "VA", "WV"});
    add("Census-EastSouthCentral", "East South Central", divisions, {"AL", "KY", "MS", "TN"});
    add("Census-WestSouthCentral", "West South Central", divisions, {"AR", "LA", "OK", "TX"});
    add("Census-Mountain", "Mountain", divisions, {"AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY"});
    add("Census-Pacific", "Pacific", divisions, {"AK", "CA", "HI", "OR", "WA"});

    // States wholly in one division, and every division's sections (split states: CA, NY, NJ).
    const char *arrl = "ARRL divisions";
    add("ARRL-Atlantic", "Atlantic Division", arrl, {"DE", "PA", "MD", "DC"}, {"DE", "EPA", "MDC", "NNY", "SNJ", "WNY", "WPA"});
    add("ARRL-Central", "Central Division", arrl, {"IL", "IN", "WI"}, {"IL", "IN", "WI"});
    add("ARRL-Dakota", "Dakota Division", arrl, {"MN", "ND", "SD"}, {"MN", "ND", "SD"});
    add("ARRL-Delta", "Delta Division", arrl, {"AR", "LA", "MS", "TN"}, {"AR", "LA", "MS", "TN"});
    add("ARRL-GreatLakes", "Great Lakes Division", arrl, {"KY", "MI", "OH"}, {"KY", "MI", "OH"});
    add("ARRL-Hudson", "Hudson Division", arrl, {}, {"ENY", "NLI", "NNJ"});
    add("ARRL-Midwest", "Midwest Division", arrl, {"IA", "KS", "MO", "NE"}, {"IA", "KS", "MO", "NE"});
    add("ARRL-NewEngland", "New England Division", arrl, {"CT", "MA", "ME", "NH", "RI", "VT"}, {"CT", "EMA", "ME", "NH", "RI", "VT", "WMA"});
    add("ARRL-Northwestern", "Northwestern Division", arrl, {"AK", "WA", "ID", "MT", "OR"}, {"AK", "EWA", "ID", "MT", "OR", "WWA"});
    add("ARRL-Pacific", "Pacific Division", arrl, {"NV", "HI"}, {"EB", "NV", "PAC", "SF", "SJV", "SCV", "SV"});
    add("ARRL-Roanoke", "Roanoke Division", arrl, {"NC", "SC", "VA", "WV"}, {"NC", "SC", "VA", "WV"});
    add("ARRL-RockyMountain", "Rocky Mountain Division", arrl, {"CO", "NM", "UT", "WY"}, {"CO", "NM", "UT", "WY"});
    add("ARRL-Southeastern", "Southeastern Division", arrl, {"AL", "GA", "FL"}, {"AL", "GA", "NFL", "PR", "SFL", "VI", "WCF"});
    add("ARRL-Southwestern", "Southwestern Division", arrl, {"AZ"}, {"AZ", "LAX", "ORG", "SB", "SDG"});
    add("ARRL-WestGulf", "West Gulf Division", arrl, {"TX", "OK"}, {"NTX", "OK", "STX", "WTX"});
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
