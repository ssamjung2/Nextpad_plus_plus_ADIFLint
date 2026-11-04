// Operating Aids (docs/OPERATING_STYLES_PLAN.md, "Human guidance and operating aids"): optional
// cues for the QSO in hand, in the Social and Portable styles. A curated, deterministic library of
// the traditional amateur exchange (name and QTH, report, station, conditions, weather, how they
// started, interests, clubs and nets, QSL, a courteous close), chosen from what is known locally:
// the fields filled, the notes of this QSO and of earlier ones with the call, the prompts the
// operator dismissed and the topics turned off. Nothing is fetched and nothing is learned.
//
// A suggestion is never a fact or a requirement: each can be skipped or dismissed, and its Note is
// only a few words put in NOTES for the operator to finish. Age and career are off until turned on.
// Portable's cues are facts about the station (activation progress, saved, waiting to upload,
// offline, duplicate check, ready to log), kept apart from the suggestions.
#pragma once

#include "adif_styles.h"

#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace adif::aids {

enum class Category { NameQth, Report, Station, Conditions, Weather, Start, Interests, Clubs, Local, Qsl, Career, Age, Closing, Practice };
constexpr int kCategoryCount = 14;

std::string_view categoryId(Category c);  // "station", "weather"... (kept in ADIFLint.ini)
const char *categoryTitle(Category c);    // English, for tr()
bool onAtFirst(Category c);               // every topic but age and career

// How many suggestions show at once: Off none (the card only says it is off), Minimal 1,
// Standard 2, More 3. Portable's, Chasing's and Contest's are brief: at most one less, never fewer than one.
enum class Level { Off, Minimal, Standard, More };
Level parseLevel(std::string_view s);  // "off", "minimal", "standard", "more"; else Standard
std::string_view levelId(Level l);
size_t shown(Level l, styles::OperatingStyle s);

// When the suggestions change: at natural pauses (a new call, a QSO logged), only after each QSO,
// or only when asked (Next).
enum class Timing { Pauses, AfterQso, Manual };
Timing parseTiming(std::string_view s);  // "pauses", "after", "manual"; else Pauses
std::string_view timingId(Timing t);

constexpr unsigned kSocial = 1, kPortable = 2, kChasing = 4, kContest = 8;  // Prompt::styles, scripts::Script::styles
unsigned styleBit(styles::OperatingStyle s);

struct Prompt {
    const char *id;     // stable, for Dismiss
    Category category;
    unsigned styles;    // kSocial, kPortable, kChasing, kContest
    const char *text;   // English, for tr(): a suggestion, never a requirement
    const char *note;   // English, for tr(): the words Note puts in NOTES to finish ("Antenna: "); "" none
    bool before = false;     // before a contact (no call yet), not during one
    unsigned modes = 0;      // the mode groups it is for (scripts::modeBit); 0 any
    const char *source = ""; // English, for tr(): where the practice comes from, said as why it shows; "" none
};
const std::vector<Prompt> &library();  // in the order of a QSO

struct Context {
    styles::OperatingStyle style = styles::OperatingStyle::Social;
    std::string call;
    bool name = false, qth = false, report = false;  // NAME, QTH and both reports filled
    std::string notes;                               // this QSO's NOTES and COMMENT
    std::string earlierNotes;                        // the notes of earlier QSOs with the call
    size_t earlier = 0;                              // how many earlier QSOs with the call
    std::set<std::string> dismissed;                 // prompt ids
    std::set<std::string> off;                       // category ids turned off
    std::vector<std::string> noteWords;              // each prompt's Note words as shown (translated), by library index
    size_t skip = 0;                                 // Skip pressed so many times since the call changed
    Level level = Level::Standard;
    unsigned modes = 0;                              // the QSO's mode group (scripts::modeBit); 0 not known: any
};

struct Suggestion {
    const Prompt *prompt = nullptr;
    std::string why;  // when the reason isn't plain (translated); "" none
};
// The suggestions for now, in the order of a QSO, from the skip'th one eligible, wrapping round:
// without a call, only those for before a contact (listening first); with one, name and QTH while
// either is empty, the report while one is, no topic the notes (this QSO's or earlier ones')
// already mention; only those for the style, and for the mode when it is known.
std::vector<Suggestion> suggest(const Context &c);

// Whether `notes` already mention the category (its words, in English, or the prompt's Note words).
bool mentioned(Category c, std::string_view notes, std::string_view noteWords = {});

// Portable: the station's state, as cues (facts), in the order they matter in the field.
struct PortableState {
    std::string activation;  // the activation's progress ("US-1234 today: 7 of 10"); "" none
    bool callEntered = false;
    bool duplicate = false;
    std::vector<std::string> missing;  // required fields still empty
    bool saved = true;                 // the log saved on this computer
    bool offline = false;
    std::vector<std::string> services;  // the upload services this log uses
    size_t waiting = 0;                 // QSOs not yet uploaded to them
    bool spots = false;                 // the Map's spots on (Portable fetches them less often)
};
struct Cue {
    enum Kind { Activation, Ready, Duplicate, Saved, Sync, Offline, Spots } kind;
    std::string text;  // translated
    int severity = 0;  // 0 fine, 1 note, 2 warning
};
std::vector<Cue> portableCues(const PortableState &s);

}  // namespace adif::aids
