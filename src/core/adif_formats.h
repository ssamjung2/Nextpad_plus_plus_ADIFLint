// Other formats: CSV import (spreadsheets, paper logs typed up, other loggers'
// exports) and Cabrillo export for contests.
//
//   CSV: RFC 4180; the first row names the columns. A column named after an
//     ADIF field is that field; common other names are recognised (Callsign,
//     Date, UTC, Frequency, RST Sent, Grid, Park...). Unknown columns are
//     left out and listed.
//   Cabrillo v3 (wwrof.org, header page updated 2025-06-05, QSO data page
//     updated 2021-03-15): START-OF-LOG: 3.0 first, END-OF-LOG: last, then
//     "QSO: freq mo date time call rst exch call rst exch". freq is kHz on HF
//     (or the band's 1800/3500/7000/14000/21000/28000) and the band (50, 144,
//     432, 1.2G...) from 50 MHz up; mo is CW, PH, FM, RY or DG; date yyyy-mm-dd;
//     time hhmm. The exchange is each contest's own.
#pragma once

#include "adif_tools.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

// RFC 4180 rows (the delimiter is the commonest of , ; and tab in the first line).
std::vector<std::vector<std::string>> parseCsv(std::string_view csv);

struct CsvImport {
    std::vector<std::vector<std::pair<std::string, std::string>>> records;  // ADIF fields per data row
    std::vector<std::pair<std::string, std::string>> columns;  // header -> ADIF field ("" when left out)
    std::vector<std::string> notes;  // values that could not be converted, by row
};
// Rows to records: CALL, MODE and STATION_CALLSIGN upper case, BAND lower case,
// dates (YYYYMMDD, YYYY-MM-DD, YYYY/MM/DD) to YYYYMMDD, times (HHMM, HH:MM[:SS])
// to HHMM[SS], frequencies in kHz (a kHz column, or values of 1000 and up) to MHz.
// Our CSV export's formula guard (a leading apostrophe) is undone.
CsvImport importCsv(std::string_view csv);

struct CabrilloOptions {
    std::string contest;       // CONTEST: (A-Z, 0-9, '-'; up to 32)
    std::string callsign;      // CALLSIGN:, and the sent call when a record has no STATION_CALLSIGN
    std::string categoryOperator, categoryPower, categoryStation;  // optional
    std::string operators, grid, location, createdBy;              // optional
};
struct CabrilloLog {
    std::string text;
    size_t qsos = 0;
    size_t incomplete = 0;  // QSO lines with "-" for a missing report or exchange
    size_t skipped = 0;     // records without CALL, QSO_DATE, TIME_ON or a band
};
CabrilloLog toCabrillo(const std::vector<Record> &recs, const CabrilloOptions &o);
// The Cabrillo freq and mo of a record ("14025", "144", "CW", "PH"...); "" when unknown.
std::string cabrilloFreq(const Record &r);
std::string cabrilloMode(const Record &r);

}  // namespace adif
