// What a log has worked, and what a spot means for it: the Map colours spots by it and its
// status bar counts the spots you need. Each QSO's DXCC entity is the record's DXCC, else the
// country data's for its call; bands are compared in lower case, modes by group (CW, phone,
// data: modeGroup in adif_enrich.h), calls without their portable parts (lookupCall).
#pragma once

#include "adif_country.h"
#include "adif_spots.h"
#include "adif_world.h"

#include <cstddef>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace adif {

struct WorkedIndex {
    struct Entity {
        std::set<std::string> bands, confirmedBands;
        std::set<int> modes, confirmedModes;
        std::set<std::pair<std::string, int>> slots;  // band and mode group
        size_t qsos = 0;
        bool confirmed = false;
    };
    struct Call {
        size_t qsos = 0;
        int firstYear = 0;
        bool confirmed = false;
        std::set<std::string> bands;
        std::set<int> modes;
    };
    std::map<int, Entity> entities;
    std::map<std::string, Call> calls;  // by lookupCall()
    std::set<std::string> parks;        // POTA parks hunted, as POTA's list writes them
    std::set<std::string> grids;        // 4-character squares, upper case
};
WorkedIndex workedIndex(const std::vector<MapQso> &qsos, const CountryTable *countries);

// For a spot's DXCC entity, on its band and in its mode group: never worked (a new one), not on
// this band, not in this mode on this band, worked, confirmed (on this band); Unknown when the
// country data can't place the call.
enum class SpotNeed { NewDxcc, NewBand, NewMode, Worked, Confirmed, Unknown };
struct SpotStatus {
    SpotNeed need = SpotNeed::Unknown;
    int dxcc = 0;
    std::string entity;  // the entity's name
    bool newPark = false;  // a POTA spot of a park you haven't hunted
    size_t callQsos = 0;   // your QSOs with the call
    int callFirstYear = 0;
    bool callConfirmed = false;
    std::set<std::string> callBands;
};
SpotStatus spotStatus(const WorkedIndex &w, const Spot &s, const CountryTable *countries);
// "new DXCC", "new band", "new mode", "worked", "confirmed" (translated); "" when Unknown.
std::string spotNeedText(SpotNeed n);
// Wanted: a new DXCC, band or mode, or a new park.
bool spotWanted(const SpotStatus &st);

}  // namespace adif
