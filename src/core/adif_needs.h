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
#include <string_view>
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
    std::set<std::string> iota;         // IOTA groups worked ("EU-005")
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
// How wanted, for ordering: 0 a new DXCC, 1 a new band, 2 a new mode, 3 a new park, 4 not.
int spotPriority(const SpotStatus &st);

// A watch list: calls (matched without their portable parts), program references (a POTA park,
// an IOTA group...) and DXCC entities by name. Read from text split at commas and new lines,
// each trimmed and in upper case, in order, without repeats.
std::vector<std::string> watchList(std::string_view text);
std::string watchListText(const std::vector<std::string> &list);  // comma-separated
// What on the list a spot is for: its call, one of its references, else its entity (`entity`,
// spotStatus's name); "" when nothing.
std::string watchedFor(const std::vector<std::string> &list, const Spot &s, const std::string &entity);

// A DXCC entity's band slots, for the bands most worked (160m to 6m, and any other band worked):
// each band, and whether it is confirmed, worked or not yet.
enum class SlotState { None, Worked, Confirmed };
std::vector<std::pair<std::string, SlotState>> bandSlots(const WorkedIndex &w, int dxcc);

// Why a contact is worth having, for the QSO being logged (the Operating Console's QSO details), as
// the Map's selected panel says it for a spot: on your watch list; in the middle of an activation,
// a duplicate (this call on this band and mode group already today, UTC, which a program counts
// once) or new for it, otherwise what it means for the log (a new DXCC entity, band or mode, or
// worked or confirmed there already); park to park (the other station's references) and a park
// you haven't hunted; and your QSOs with the call before. An activation's log starts empty, so
// what it means for the log is left out then: everything in it would be new.
enum class InterestKind { Watched, Duplicate, NewForActivation, NewDxcc, NewBand, NewMode, Worked, Confirmed, ParkToPark, NewPark, Before, FirstQso };
struct Interest {
    InterestKind kind;
    std::string text;  // translated
};
struct ContactSubject {
    std::string call, band, mode;
    std::string date8;              // the QSO's UTC day, YYYYMMDD
    std::vector<std::string> refs;  // the other station's references (POTA_REF, else SIG_INFO)
    std::string program;            // theirs: "POTA" when those are POTA parks, "WWFF", "SOTA"...; ""
    bool activating = false;
};
std::vector<Interest> contactInterest(const WorkedIndex &w, const std::vector<MapQso> &qsos, const ContactSubject &c,
                                      const CountryTable *countries, const std::vector<std::string> &watch);

// The log at a glance, for the Map's status bar: its QSOs, DXCC entities (and how many
// confirmed), US states and 4-character squares; and today's (UTC day "YYYYMMDD") QSOs, by mode
// group and band, and the last of them.
struct LogGlance {
    size_t qsos = 0, dxcc = 0, dxccConfirmed = 0, states = 0, grids = 0;
    size_t today = 0;
    size_t todayModes[3] = {0, 0, 0};  // CW, phone, data
    std::vector<std::string> todayBands;  // in band order
    std::string lastCall, lastTime;       // the last QSO today (latest TIME_ON)
};
LogGlance logGlance(const std::vector<MapQso> &qsos, const WorkedIndex &w, const std::string &today);

}  // namespace adif
