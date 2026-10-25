// The numbers behind Log Summary's charts: QSOs by band (in band order), by mode (most first),
// per day, by UTC hour and weekday, by continent, and how the DXCC entities, US states and grid
// squares reached grew, day by day.
#pragma once

#include "adif_country.h"
#include "adif_lint.h"

#include <array>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

struct SummaryStats {
    size_t qsos = 0;                                         // records with a CALL
    std::vector<std::pair<std::string, size_t>> bands;       // by frequency, low first ("" none: left out)
    std::vector<std::pair<std::string, size_t>> modes;       // SUBMODE else MODE, most first (ties by name)
    std::vector<std::pair<std::string, size_t>> days;        // "YYYYMMDD", the days with QSOs, in order
    std::array<std::array<size_t, 24>, 7> hourWeekday = {};  // [Monday 0 .. Sunday 6][UTC hour], dated and timed QSOs
    std::vector<std::pair<std::string, size_t>> continents;  // AF AN AS EU NA OC SA, those with QSOs
    struct Growth {
        std::string day;                                     // "YYYYMMDD"
        size_t dxcc = 0, states = 0, grids = 0;              // reached by the end of that day
    };
    std::vector<Growth> growth;                              // a point per day with QSOs
};

// From the records with a CALL. A QSO's DXCC entity and continent are its DXCC and CONT, else the
// country file's for its call (when given); its US state is STATE for DXCC 291, 6 or 110 (the
// 50 states WAS counts); its grid squares the first 4 characters of GRIDSQUARE and VUCC_GRIDS.
SummaryStats summaryStats(std::string_view text, const DocModel &m, const CountryTable *countries = nullptr);

}  // namespace adif
