// Operating Aids' scripts: what you might send or say at a step of a contact, written out with your
// station's facts and the QSO's fields ({MYCALL}, {CALL}, {RST_SENT}...), for the mode in use (phone,
// CW, RTTY, PSK and the other keyboard modes, or JS8Call) and the operating style (adif_aids.h's
// style bits). A script is text for the operator to read, copy or change: nothing is sent or keyed.
//
// Built in (adif_scripts.cpp names each group's source and when it was read), each one editable, or
// removed, or hidden from Operating Aids; and your own. The scripts file (ADIFLint-scripts.adi in the
// config folder, ADIF records like the profiles file) keeps only what differs from the built-ins,
// and yours.
#pragma once

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace adif::scripts {

enum class ModeGroup { Phone, Cw, Rtty, Psk, Js8 };
constexpr int kModeGroupCount = 5;
constexpr unsigned modeBit(ModeGroup g) { return 1u << (unsigned)g; }
constexpr unsigned kAllModes = (1u << kModeGroupCount) - 1;

std::string_view modeGroupId(ModeGroup g);  // "phone", "cw", "rtty", "psk", "js8" (in the scripts file and the settings)
std::optional<ModeGroup> parseModeGroup(std::string_view id);
const char *modeGroupTitle(ModeGroup g);  // English, for tr(): "Phone", "CW", "RTTY", "PSK", "JS8Call"
bool keyboard(ModeGroup g);               // RTTY, PSK and JS8Call: typed into a program, so a script can be copied there
// The group of a QSO's MODE and SUBMODE: SSB, AM, FM and DIGITALVOICE phone; CW; RTTY; MFSK's JS8
// JS8Call; PSK and the other keyboard modes fldigi has (Olivia, Contestia, MFSK, Hell, MT63, Thor,
// Domino...) PSK. nullopt for none, and for the WSJT-X modes (FT8, FT4, JT65, Q65...), whose
// programs make their own messages.
std::optional<ModeGroup> modeGroupOf(std::string_view mode, std::string_view submode);

struct Script {
    std::string id;       // built-in "social.cw.answer"; yours "mine.1"...
    std::string title;    // a built-in's in English (translated where shown) until you change it
    unsigned styles = 0;  // adif::aids::kSocial | kChasing | kContest | kPortable
    unsigned modes = 0;   // modeBit()s
    std::string text;     // with {VARIABLES}
    bool before = false;  // before a contact (calling CQ: no call yet), not during one
    bool shown = true;    // in Operating Aids
    bool builtIn = false;
    bool changed = false;  // a built-in whose title, text, styles or modes you changed
    bool words = false;    // a built-in's text in words (phone): translated where shown, until changed
};

// The built-in scripts, in the order of a contact for each style.
const std::vector<Script> &builtIns();
const Script *findBuiltIn(std::string_view id);

// The scripts as you have them, from the scripts file's text: the built-ins (as you changed or hid
// them; those you removed left out), then yours, in the order you made them.
std::vector<Script> load(std::string_view fileText);
// The scripts file: a record for each built-in you changed, hid or removed, and one for each of yours.
std::string fileText(const std::vector<Script> &scripts, std::string_view programVersion, std::string_view utcTimestamp);
// An id for a new script of your own ("mine.1", "mine.2"...): one no script has.
std::string newId(const std::vector<Script> &scripts);

// The scripts Operating Aids shows for a style (an aids style bit), a mode group, and before a
// contact (no call yet) or during one, in their order.
std::vector<const Script *> applicable(const std::vector<Script> &scripts, unsigned styleBit, ModeGroup group, bool before);

// The variables a script can use: {NAME}, and what it is (English, for tr()).
struct Variable {
    const char *name, *what;
};
const std::vector<Variable> &variables();
using Values = std::map<std::string, std::string>;
// The text with each {VARIABLE} that has a value written out. One without a value (or not a
// variable) stays as it is, and is listed in *missing, once, in the order met.
std::string fill(std::string_view text, const Values &values, std::vector<std::string> *missing = nullptr);

// A callsign in the ITU phonetic alphabet, letter by letter ("K1ABC": "Kilo 1 Alfa Bravo Charlie");
// digits and '/' as they are.
std::string phonetic(std::string_view call);

}  // namespace adif::scripts
