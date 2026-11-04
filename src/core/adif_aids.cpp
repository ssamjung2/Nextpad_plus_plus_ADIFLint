#include "adif_aids.h"

#include "adif_i18n.h"
#include "adif_scripts.h"

#include <algorithm>
#include <array>
#include <cctype>

namespace adif::aids {
namespace {

using i18n::tr;
using i18n::trf;
using i18n::trp;

struct CategoryInfo {
    const char *id, *title;
    bool on;
    std::vector<const char *> words;  // the starts of words that show the notes have it (English, lower case)
};
const std::array<CategoryInfo, kCategoryCount> kCategories = {{
    {"name", N_("Name and QTH"), true, {}},
    {"report", N_("Signal report"), true, {}},
    {"station", N_("Station and antenna"), true,
     {"antenna", "rig", "radio", "yagi", "dipole", "vertical", "beam", "watt", "amplifier", "station", "setup", "transceiver", "loop", "efhw"}},
    {"conditions", N_("Conditions"), true, {"condition", "propagation", "qsb", "fading", "noise", "opening"}},
    {"weather", N_("Weather"), true, {"weather", "rain", "snow", "sunny", "cloud", "wind", "storm", "cold", "hot", "warm", "temperature"}},
    {"start", N_("Getting started"), true, {"licen", "started", "elmer", "novice", "first qso"}},
    {"interests", N_("Interests"), true, {"interest", "hobby", "hobbies", "dxing", "contest", "satellite", "morse", "ft8", "homebrew"}},
    {"clubs", N_("Clubs and nets"), true, {"club", "net", "repeater", "hamfest", "field day", "ares"}},
    {"local", N_("Local area"), true, {"area", "town", "city", "lives", "moved", "travel", "visiting"}},
    {"qsl", N_("QSL"), true, {"qsl", "lotw", "eqsl", "card", "bureau", "buro"}},
    {"career", N_("Work and projects"), false, {"work", "job", "career", "retired", "engineer", "teacher", "student", "project"}},
    {"age", N_("Stage of life"), false, {"retired", "student", "years old", "birthday"}},
    {"closing", N_("Closing"), true, {}},
    {"practice", N_("Good practice"), true, {}},
}};

const CategoryInfo &info(Category c) { return kCategories[(size_t)c]; }

std::string lower(std::string_view s) {
    std::string out(s);
    for (char &ch : out) ch = (char)std::tolower((unsigned char)ch);
    return out;
}

// Whether `text` (lower case) has a word starting with `start`.
bool hasWordStart(const std::string &text, std::string_view start) {
    for (size_t at = text.find(start); at != std::string::npos; at = text.find(start, at + 1))
        if (at == 0 || !std::isalnum((unsigned char)text[at - 1])) return true;
    return false;
}

}  // namespace

std::string_view categoryId(Category c) { return info(c).id; }
const char *categoryTitle(Category c) { return info(c).title; }
bool onAtFirst(Category c) { return info(c).on; }

Level parseLevel(std::string_view s) {
    return s == "off" ? Level::Off : s == "minimal" ? Level::Minimal : s == "more" ? Level::More : Level::Standard;
}
std::string_view levelId(Level l) {
    switch (l) {
        case Level::Off: return "off";
        case Level::Minimal: return "minimal";
        case Level::Standard: return "standard";
        case Level::More: break;
    }
    return "more";
}
size_t shown(Level l, styles::OperatingStyle s) {
    size_t n = l == Level::Off ? 0 : l == Level::Minimal ? 1 : l == Level::Standard ? 2 : 3;
    return s != styles::OperatingStyle::Social && n > 1 ? n - 1 : n;
}

unsigned styleBit(styles::OperatingStyle s) {
    switch (s) {
        case styles::OperatingStyle::Social: return kSocial;
        case styles::OperatingStyle::Portable: return kPortable;
        case styles::OperatingStyle::Chasing: return kChasing;
        case styles::OperatingStyle::Contest: break;
    }
    return kContest;
}

Timing parseTiming(std::string_view s) { return s == "after" ? Timing::AfterQso : s == "manual" ? Timing::Manual : Timing::Pauses; }
std::string_view timingId(Timing t) { return t == Timing::AfterQso ? "after" : t == Timing::Manual ? "manual" : "pauses"; }

const std::vector<Prompt> &library() {
    static const std::vector<Prompt> all = {
        {"name-qth", Category::NameQth, kSocial, N_("Exchange names and QTH: give yours, and ask theirs"), ""},
        {"portable-quick", Category::NameQth, kPortable, N_("Quick exchange: report, name and QTH, then the park or summit"), ""},
        {"report", Category::Report, kSocial | kPortable, N_("Give your signal report, and ask how you are getting out"), ""},
        {"station", Category::Station, kSocial, N_("Want to ask about their rig and antenna?"), N_("Station: ")},
        {"portable-setup", Category::Station, kPortable, N_("Quick topic: share your setup, or ask about theirs"), N_("Station: ")},
        {"conditions", Category::Conditions, kSocial, N_("How are conditions on their side of the path?"), N_("Conditions: ")},
        {"weather", Category::Weather, kSocial | kPortable, N_("You could share what the weather is like at your station"), N_("Weather: ")},
        {"start", Category::Start, kSocial, N_("What brought them into amateur radio, and when?"), N_("Licensed: ")},
        {"interests", Category::Interests, kSocial, N_("Do they enjoy any particular bands or modes?"), N_("Interests: ")},
        {"other-interests", Category::Interests, kSocial, N_("Ask about other radio interests: DX, contests, satellites, CW, portable"),
         N_("Interests: ")},
        {"clubs", Category::Clubs, kSocial, N_("Ask whether they take part in a local club or net"), N_("Club or net: ")},
        {"local", Category::Local, kSocial, N_("Ask about their area, or share something about yours"), N_("Area: ")},
        {"qsl", Category::Qsl, kSocial, N_("Ask how they like to QSL: LoTW, eQSL, a card, or not at all"), N_("QSL: ")},
        {"career", Category::Career, kSocial, N_("If it comes up: what they do, or what they are working on"), N_("Work: ")},
        {"age", Category::Age, kSocial, N_("Only if they bring it up: their stage of life (studying, working, retired)"), ""},
        {"closing", Category::Closing, kSocial | kPortable, N_("Close courteously: thank them, confirm their call, and 73"), ""},
        // Good practice, each from the source it names (read 2026-11-03): IARU, Ethics and Operating
        // Procedures for the Radio Amateur, 4th ed. rev. 4.2.0 (2026, www.iaru-r1.org/on-the-air/eop/);
        // 47 CFR §97.119 (eCFR, as amended to 2010); the DX Code of Conduct (as IARU Region 1 publishes
        // it); ARRL's HF Contesting Guidelines and The Amateur's Code (arrl.org); docs.pota.app (rules
        // v1.3, the activator, hunter and CW guides).
        {"listen-first", Category::Practice, kSocial | kPortable | kContest,
         N_("Listen first, then ask if the frequency is in use: QRL? on CW and keyboard modes, \"Is this frequency in use?\" on phone"), "", true,
         scripts::modeBit(scripts::ModeGroup::Phone) | scripts::modeBit(scripts::ModeGroup::Cw) | scripts::modeBit(scripts::ModeGroup::Digital),
         N_("IARU Ethics and Operating Procedures, 4th edition, §9.4 and §12.5.2")},
        {"pota-spot", Category::Practice, kPortable, N_("Spot yourself, or ask your first contact to spot you"), "", true, 0,
         N_("POTA's activator guide (docs.pota.app)")},
        {"pota-ten", Category::Practice, kPortable, N_("Ten contacts from the park in one UTC day make a successful activation"), "", true, 0,
         N_("POTA's rules, version 1.3 (docs.pota.app)")},
        {"identify", Category::Practice, kSocial | kPortable,
         N_("Identify: your call at the end of the contact, and every ten minutes in a long one (in the US; elsewhere, as your licence says)"), "",
         false, 0, N_("47 CFR §97.119(a); IARU Ethics and Operating Procedures, 4th edition, §12.4")},
        {"phonetics", Category::Practice, kSocial | kPortable | kChasing | kContest,
         N_("Give your call in the ITU phonetic alphabet (Alfa, Bravo, Charlie...), above all when signals are weak"), "", false,
         scripts::modeBit(scripts::ModeGroup::Phone), N_("IARU Ethics and Operating Procedures, 4th edition, §11.1; encouraged in the US by 47 CFR §97.119(b)(2)")},
        {"friendly", Category::Practice, kSocial, N_("Operate slowly and patiently when asked, and help newcomers along"), "", false, 0,
         N_("The Amateur's Code (ARRL): Friendly")},
        {"pota-brief", Category::Practice, kPortable, N_("Busy? Keep exchanges short: calls, a real report and your state"), "", false, 0,
         N_("POTA's activator and hunter guides (docs.pota.app): no exchange is required")},
        {"pota-p2p", Category::Practice, kPortable, N_("Park to park: give your park after the report, and log theirs in SIG_INFO"), "", false, 0,
         N_("POTA's CW guide and Park to Park page (docs.pota.app)")},
        {"dx-listen", Category::Practice, kChasing,
         N_("Listen, and listen again, before calling: call only if you copy the DX well, and be sure of its call, not only the cluster's word"), "",
         false, 0, N_("The DX Code of Conduct, points 1 to 3")},
        {"dx-wait", Category::Practice, kChasing, N_("Wait for the DX to end a contact before you call; never tune up on its frequency or where it listens"),
         "", false, 0, N_("The DX Code of Conduct, points 4 and 5")},
        {"dx-full-call", Category::Practice, kChasing, N_("Send your full call, then listen a while: don't call continuously"), "", false, 0,
         N_("The DX Code of Conduct, points 6 and 7")},
        {"dx-not-you", Category::Practice, kChasing, N_("Don't call when the DX calls or asks for another call, or another area than yours"), "", false, 0,
         N_("The DX Code of Conduct, points 8 to 10")},
        {"dx-once", Category::Practice, kChasing, N_("When the DX comes back to you, don't repeat your call unless it was copied wrong"), "", false, 0,
         N_("The DX Code of Conduct, point 11")},
        {"contest-exchange", Category::Practice, kContest, N_("Send only the exchange the contest asks for"), "", false, 0,
         N_("IARU Ethics and Operating Procedures, 4th edition, §16.6; ARRL's HF Contesting Guidelines")},
        {"contest-call", Category::Practice, kContest, N_("Running? Give your call in every contact, and close with a short TU"), "", false, 0,
         N_("IARU Ethics and Operating Procedures, 4th edition, §16.6.1 and §16.6.2")},
        {"contest-log", Category::Practice, kContest,
         N_("Log what you copy, and keep every completed contact: one deleted is a not-in-log for the other station"), "", false, 0,
         N_("ARRL's HF Contesting Guidelines")},
        {"no-overcall", Category::Practice, kContest | kChasing, N_("Never call on top of a contact in progress"), "", false, 0,
         N_("ARRL's HF Contesting Guidelines; IARU Ethics and Operating Procedures, 4th edition, chapter 15")},
        {"rtty-serial", Category::Practice, kContest, N_("On RTTY, send the serial number twice: the mode doesn't correct errors"), "", false,
         scripts::modeBit(scripts::ModeGroup::Digital), N_("IARU Ethics and Operating Procedures, 4th edition, §16.6.3")},
    };
    return all;
}

bool mentioned(Category c, std::string_view notes, std::string_view noteWords) {
    std::string text = lower(notes);
    if (text.empty()) return false;
    for (const char *w : info(c).words)
        if (hasWordStart(text, w)) return true;
    std::string mine = lower(noteWords);
    while (!mine.empty() && (mine.back() == ' ' || mine.back() == ':')) mine.pop_back();  // "Station: " is "station"
    return !mine.empty() && text.find(mine) != std::string::npos;
}

std::vector<Suggestion> suggest(const Context &c) {
    std::vector<Suggestion> out;
    size_t n = shown(c.level, c.style);
    if (!n) return out;
    unsigned style = styleBit(c.style);
    bool before = c.call.empty();  // no contact yet
    std::vector<Suggestion> eligible;
    const std::vector<Prompt> &all = library();
    for (size_t i = 0; i < all.size(); ++i) {
        const Prompt &p = all[i];
        if (!(p.styles & style) || p.before != before || c.dismissed.count(p.id) || c.off.count(std::string(categoryId(p.category)))) continue;
        if (p.modes && c.modes && !(p.modes & c.modes)) continue;
        std::string why;
        if (p.category == Category::Practice) {
            if (*p.source) why = tr(p.source);
        } else if (p.category == Category::NameQth) {
            if (c.name && c.qth) continue;
            why = tr("NAME or QTH is still empty");
        } else if (p.category == Category::Report) {
            if (c.report) continue;
            why = tr("RST_SENT or RST_RCVD is still empty");
        } else if (p.category != Category::Closing) {
            std::string_view words = i < c.noteWords.size() ? std::string_view(c.noteWords[i]) : std::string_view();
            if (mentioned(p.category, c.notes, words) || mentioned(p.category, c.earlierNotes, words)) continue;
            if (c.earlier)
                why = trp("Not in your notes from {n} earlier QSO with {call}", "Not in your notes from {n} earlier QSOs with {call}",
                          (long long)c.earlier, {{"call", c.call}});
        }
        eligible.push_back({&p, why});
    }
    for (size_t k = 0; k < std::min(n, eligible.size()); ++k) out.push_back(eligible[(c.skip + k) % eligible.size()]);
    return out;
}

std::vector<Cue> portableCues(const PortableState &s) {
    std::vector<Cue> out;
    if (!s.activation.empty()) out.push_back({Cue::Activation, s.activation, 0});
    if (s.callEntered) {
        if (s.missing.empty()) out.push_back({Cue::Ready, tr("Ready to log"), 0});
        else {
            std::string fields;
            for (const std::string &f : s.missing) fields += (fields.empty() ? "" : ", ") + f;
            out.push_back({Cue::Ready, trf("Before logging: {fields}", {{"fields", fields}}), 1});
        }
        out.push_back(s.duplicate ? Cue{Cue::Duplicate, tr("Duplicate: already in this log on this band and mode today"), 2}
                                  : Cue{Cue::Duplicate, tr("Duplicate check: not in this log on this band and mode today"), 0});
    }
    out.push_back(s.saved ? Cue{Cue::Saved, tr("Saved locally"), 0}
                          : Cue{Cue::Saved, tr("Not saved yet: save the log (Command-S) before you move or close it"), 1});
    if (!s.services.empty()) {
        std::string names;
        for (const std::string &n : s.services) names += (names.empty() ? "" : ", ") + n;
        i18n::Args args = {{"services", names}};
        if (s.waiting == 0) out.push_back({Cue::Sync, trf("Synced: every QSO is uploaded to {services}", args), 0});
        else if (s.offline)
            out.push_back({Cue::Sync,
                           trp("Offline: {n} QSO waits to upload to {services}; you can keep operating",
                               "Offline: {n} QSOs wait to upload to {services}; you can keep operating", (long long)s.waiting, args),
                           1});
        else
            out.push_back({Cue::Sync,
                           trp("Waiting to sync: {n} QSO not yet uploaded to {services}", "Waiting to sync: {n} QSOs not yet uploaded to {services}",
                               (long long)s.waiting, args),
                           1});
    }
    if (s.offline) out.push_back({Cue::Offline, tr("Offline Mode: nothing is fetched or sent; you can keep operating"), 0});
    if (s.spots) out.push_back({Cue::Spots, tr("Spots every 5 minutes; the DX cluster and live feeds stay off to save power and data"), 0});
    return out;
}

}  // namespace adif::aids
