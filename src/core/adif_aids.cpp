#include "adif_aids.h"

#include "adif_i18n.h"

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
    return s == styles::OperatingStyle::Portable && n > 1 ? n - 1 : n;
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
    if (c.call.empty() || !n) return out;
    unsigned style = c.style == styles::OperatingStyle::Portable ? kPortable : c.style == styles::OperatingStyle::Social ? kSocial : 0;
    std::vector<Suggestion> eligible;
    const std::vector<Prompt> &all = library();
    for (size_t i = 0; i < all.size(); ++i) {
        const Prompt &p = all[i];
        if (!(p.styles & style) || c.dismissed.count(p.id) || c.off.count(std::string(categoryId(p.category)))) continue;
        std::string why;
        if (p.category == Category::NameQth) {
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
