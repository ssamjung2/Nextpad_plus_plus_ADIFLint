// US regions for the Map's filters, each a set of states (postal codes), read 2026-10-17:
//  - Call areas 1-0: the FCC's call sign regions 1-10 (fcc.gov "Amateur Call Sign Systems", read
//    through a search summary because the page refused the fetch, and checked state by state
//    against ARRL's sections by call area, arrl.org/section-abbreviations), plus Alaska (KL7)
//    and Hawaii (KH6).
//  - Census regions and divisions (census.gov, Economic Census "Levels" page, revised
//    2021-10-08).
//  - ARRL divisions (arrl.org/divisions and arrl.org/section-abbreviations). California, New
//    York and New Jersey are split between divisions by section, so a QSO there counts for a
//    division only by its ARRL_SECT.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct UsRegion {
    std::string id;    // "W9", "Census-Midwest", "ARRL-Central"
    std::string name;  // "Call area 9 (IL, IN, WI)", "Midwest", "Central Division"
    std::string kind;  // "Call areas", "Census regions", "Census divisions", "ARRL divisions"
    std::vector<std::string> states;    // wholly in the region
    std::vector<std::string> sections;  // ARRL divisions: their sections
};

const std::vector<UsRegion> &usRegions();
const UsRegion *usRegion(std::string_view id);
// Whether a QSO in `state` with ARRL section `arrlSect` (either may be empty) is in the region:
// for an ARRL division by its section when it has one, else by a state wholly in the region.
bool inUsRegion(const UsRegion &r, std::string_view state, std::string_view arrlSect);

}  // namespace adif
