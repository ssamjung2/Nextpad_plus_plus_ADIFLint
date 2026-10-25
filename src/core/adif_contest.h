// Contests and Field Days in New QSO: the exchange each asks for, the fields
// written with every QSO, the next serial number and the duplicate rule.
//
// ARRL Field Day (www.arrl.org/field-day-rules, revised 2026-03-01, read
// 2026-10-10): the exchange is the operating class and the ARRL/RAC section (DX
// stations send their class and "DX"); a station can be worked once per band per
// mode, the modes being Phone, CW and Digital (rule 6.3); the bands are 160, 80,
// 40, 20, 15 and 10 m and all from 50 MHz up (rule 2); no repeater contacts (6.10).
// Winter Field Day (winterfieldday.org/sop.php, 2027 rules, read 2026-10-10;
// January 23-24, 2027): the exchange is a class (the number of transmitters), a
// category letter (H home, I indoor, O outdoor, M mobile) and a location (the
// ARRL/RAC section, MX for Mexico, DX elsewhere), such as 2O IL; a station can be
// worked once per band per mode (CW, Phone, Digital); every band but 12, 17, 30
// and 60 m; no WSJT modes (FT2, FST4, FT4, FT8, JT4, JT9, JT65, Q65, MSK144, WSPR,
// FST4W, Echo); only direct simplex contacts (no cross-band, repeated, relayed or
// internet-linked ones).
// ADIF 3.1.7: CONTEST_ID ARRL-FIELD-DAY and WFD; CLASS "contest class (e.g. for
// ARRL Field Day)"; ARRL_SECT and MY_ARRL_SECT from the ARRL_Section
// enumeration; STX/SRX serial numbers; STX_STRING/SRX_STRING the exchange sent
// and received.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class ContestPreset { None, FieldDay, WinterFieldDay, Serial, Defined };

struct ContestSetup {
    ContestPreset preset = ContestPreset::None;
    std::string sent;       // Field Days and Defined: your exchange ("1D IL", "2O IL", "4", "A 72 IL")
    std::string contestId;  // Serial: the CONTEST_ID to write (may be empty); Defined: the contest's
    std::string partyId;    // Defined QSO-PARTY: the party's own CONTEST_ID ("IL QSO Party", "CA-QSO-PARTY")
};

// The contests New QSO knows by their rules, a row each (adif_contest.cpp gives each one's source
// and the date it was read). What you send and what you are sent are written as ADIF has fields
// for them, and the exchange's words, in their Cabrillo order, in STX_STRING and SRX_STRING (after
// the report and the serial number, which have fields of their own).
enum class DupeRule { PerBand, PerBandMode, PerContest, PerMode };
enum class SentKind {
    None,           // nothing beyond the report or serial
    CqZone,         // your CQ zone: MY_CQ_ZONE
    ItuZone,        // your ITU zone (MY_ITU_ZONE), or an IARU society's or official's abbreviation
    State,          // your state or province: MY_STATE
    StateOrPower,   // ARRL DX: your state or province (W/VE), or your power (DX)
    Sweepstakes,    // precedence, check and section ("A 72 IL")
    NameQth,        // name and state, province or prefix ("ANDY IL"): MY_NAME, MY_STATE
    StateOrSerial,  // ARRL 10 m: your state or province; empty: serial numbers (DX)
    SectionOrNone,  // ARRL 160 m: your section; empty: none (DX)
    Location,       // a QSO party: your county or state, as the sponsor lists them
    CqZoneQth,      // CQ WW RTTY: your CQ zone, and your state or province (US, Canada) or DX ("4 IL")
};
struct ContestDef {
    const char *id;                 // CONTEST_ID, and the Cabrillo CONTEST tag
    const char *name;               // "CQ World Wide DX, SSB"
    const char *modes;              // the mode categories it counts ("PH", "CW", "CW PH"; "RTTY": MODE RTTY only)
    const char *bands;              // its bands, space separated
    DupeRule dupe;
    bool rst, serial;               // the exchange starts with the report; you send a serial number (STX, counting up)
    SentKind sent;
    const char *sentExample;        // "4", "A 72 IL"... ("" none)
    std::vector<const char *> rows; // what New QSO asks of the other station, in exchange order
    const char *source;             // the rules read: where, which version, when
    const char *notes;              // what to keep in mind, for the Contest window
};
const std::vector<ContestDef> &contestDefs();
const ContestDef *findContestDef(std::string_view contestId);  // by CONTEST_ID, any case; null when not one

// A setup's name ("CQ World Wide DX, SSB", "ARRL Field Day"), and whether it counts up a serial.
std::string contestName(const ContestSetup &s);
bool contestSerial(const ContestSetup &s);
// "once per band", "once per band and mode", "once in the contest", "once per mode".
std::string dupeRuleText(const ContestSetup &s);
// What New QSO asks of the other station for this setup.
std::vector<std::string> contestRows(const ContestSetup &s);
// What's wrong with a received value for this setup ("" when fine or not checked).
std::string contestRowProblem(const ContestSetup &s, std::string_view field, std::string_view value);
// Fields whose received value isn't one ADIF's field takes (DX for an ARRL_SECT or STATE, KW for
// RX_PWR, an IARU society for ITUZ): left out of the record, kept in SRX_STRING.
std::vector<std::string> contestDrops(const ContestSetup &s, const std::vector<std::pair<std::string, std::string>> &qso);

const char *contestPresetName(ContestPreset p);  // "ARRL Field Day", "Winter Field Day", "Serial numbers", ""

// The rows New QSO asks for the other station's exchange: CLASS and ARRL_SECT for
// the Field Days, SRX for serial numbers.
std::vector<std::string> contestRows(ContestPreset p);

// The CONTEST_ID written: ARRL-FIELD-DAY, WFD, or the one set for serials.
std::string contestIdFor(const ContestSetup &s);

// What's wrong with your exchange for this preset ("" when fine).
std::string sentProblem(const ContestSetup &s);
// What's wrong with a received class or section ("" when fine; either may be empty).
std::string classProblem(ContestPreset p, std::string_view cls);
std::string sectionProblem(ContestPreset p, std::string_view section);

// The fields written with each QSO besides the ones New QSO shows: CONTEST_ID,
// STX_STRING and MY_ARRL_SECT from your exchange, SRX_STRING from the received
// CLASS and ARRL_SECT, STX (`serial`, when > 0). `qso` holds the shown fields;
// ARRL_SECT that isn't an ARRL section (DX, MX) is left out of the record and kept
// in SRX_STRING.
std::vector<std::pair<std::string, std::string>> contestFields(const ContestSetup &s,
                                                               const std::vector<std::pair<std::string, std::string>> &qso,
                                                               int serial);

// 1 + the highest STX among records with this CONTEST_ID (any, when empty).
int nextSerial(std::string_view text, const DocModel &m, std::string_view contestId);

// The mode as the Field Days count it: "CW", "PH" (SSB, AM, FM, DIGITALVOICE) or "DG".
std::string modeCategory(std::string_view mode);

// Why a QSO doesn't count under a Field Day's rules ("" when it does): its band,
// a WSJT mode (MODE or SUBMODE) for Winter Field Day, or PROP_MODE (RPT for both;
// SAT, ECH, INTERNET and IRL as well for Winter Field Day). The rules above.
std::string contestRuleProblem(ContestPreset p, const Record &qso);
// The same for any setup: a Field Day's as above; a defined contest's band, mode (and ARRL 10 m's
// CW below 28.3 MHz).
std::string contestRuleProblem(const ContestSetup &s, const Record &qso);

// Records (numbers) that are the same contact under a Field Day's rule: the same
// call, band and mode category, with the same CONTEST_ID.
std::vector<int> contestDupes(std::string_view text, const DocModel &m, std::string_view contestId, const Record &qso);
// The same under the setup's own rule (a defined contest's DupeRule; once per band and mode else).
std::vector<int> contestDupes(std::string_view text, const DocModel &m, const ContestSetup &s, const Record &qso);

}  // namespace adif
