// What New QSO's lookup says about the station being logged, a fact a row: its operator and
// place, country and zones, grid, distance and bearings from your grid, and its local time.
// (The plugin adds the facts it keeps itself: LoTW, worked before, parks.)
#pragma once

#include "adif_country.h"

#include <string>
#include <vector>

namespace adif {

struct LookupFact {
    std::string label, value;
    std::string tip;  // more about it, for its tooltip; "" none
};

struct LookupSubject {
    std::string call;
    std::string name, qth, state;  // the window's, else the callbook's
    std::string grid;              // the window's GRIDSQUARE, else the callbook's
    bool gridFromCallbook = false;
    bool away = false;             // a portable or park station: the callbook's place is its home
    std::string country;           // the ADIF COUNTRY name ("" none)
    const CountryInfo *entity = nullptr;  // its DXCC entity from the country file; null none
    std::string myGrid;            // your station's locator ("" none)
    bool miles = false;
    long long now = 0;             // Unix seconds, for their local time
};

// The facts that can be said, in order: Operator, Country, Grid, Distance (and the bearings),
// Local time. A fact missing its data is left out.
std::vector<LookupFact> lookupFacts(const LookupSubject &s);

// "14:05 (UTC+1)" at `now` for a UTC offset in hours ("" when `now` is 0); half and quarter hours too.
std::string localTimeText(long long now, double utcOffsetHours);

}  // namespace adif
