#include "adif_scripts.h"

#include "adif_aids.h"
#include "adif_edit.h"
#include "adif_i18n.h"
#include "adif_lint.h"
#include "adif_profiles.h"
#include "adif_spec.h"

#include <algorithm>
#include <cctype>

namespace adif::scripts {
namespace {

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o) c = (char)std::toupper((unsigned char)c);
    return o;
}

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

const char *const kStyleIds[] = {"social", "portable", "chasing", "contest"};  // aids::kSocial, kPortable, kChasing, kContest

std::string styleList(unsigned styles) {
    std::string out;
    for (unsigned i = 0; i < 4; ++i)
        if (styles & (1u << i)) out += (out.empty() ? "" : ",") + std::string(kStyleIds[i]);
    return out;
}

unsigned parseStyles(std::string_view s) {
    unsigned out = 0;
    std::string v(s);
    for (size_t start = 0; start <= v.size();) {
        size_t comma = v.find(',', start);
        std::string item = trimmed(v.substr(start, comma == std::string::npos ? std::string::npos : comma - start));
        for (unsigned i = 0; i < 4; ++i)
            if (item == kStyleIds[i]) out |= 1u << i;
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return out;
}

std::string modeList(unsigned modes) {
    std::string out;
    for (int i = 0; i < kModeGroupCount; ++i)
        if (modes & modeBit((ModeGroup)i)) out += (out.empty() ? "" : ",") + std::string(modeGroupId((ModeGroup)i));
    return out;
}

unsigned parseModes(std::string_view s) {
    unsigned out = 0;
    std::string v(s);
    for (size_t start = 0; start <= v.size();) {
        size_t comma = v.find(',', start);
        if (std::optional<ModeGroup> g = parseModeGroup(trimmed(v.substr(start, comma == std::string::npos ? std::string::npos : comma - start))))
            out |= modeBit(*g);
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return out;
}

bool sameAsBuiltIn(const Script &s, const Script &b) {
    return s.title == b.title && s.text == b.text && s.styles == b.styles && s.modes == b.modes && s.before == b.before;
}

}  // namespace

std::string_view modeGroupId(ModeGroup g) {
    switch (g) {
        case ModeGroup::Phone: return "phone";
        case ModeGroup::Cw: return "cw";
        case ModeGroup::Rtty: return "rtty";
        case ModeGroup::Psk: return "psk";
        case ModeGroup::Js8: break;
    }
    return "js8";
}

std::optional<ModeGroup> parseModeGroup(std::string_view id) {
    for (int i = 0; i < kModeGroupCount; ++i)
        if (id == modeGroupId((ModeGroup)i)) return (ModeGroup)i;
    return std::nullopt;
}

const char *modeGroupTitle(ModeGroup g) {
    switch (g) {
        case ModeGroup::Phone: return N_("Phone");
        case ModeGroup::Cw: return N_("CW");
        case ModeGroup::Rtty: return N_("RTTY");
        case ModeGroup::Psk: return N_("PSK");
        case ModeGroup::Js8: break;
    }
    return N_("JS8Call");
}

bool keyboard(ModeGroup g) { return g == ModeGroup::Rtty || g == ModeGroup::Psk || g == ModeGroup::Js8; }

std::optional<ModeGroup> modeGroupOf(std::string_view mode, std::string_view submode) {
    std::string m = upper(trimmed(mode)), sub = upper(trimmed(submode));
    if (m.empty()) return std::nullopt;
    if (m == "SSB" || m == "AM" || m == "FM" || m == "DIGITALVOICE" || sub == "USB" || sub == "LSB") return ModeGroup::Phone;
    if (m == "CW") return ModeGroup::Cw;
    if (m == "RTTY" || m == "RTTYM") return ModeGroup::Rtty;
    if (m == "JS8" || (m == "MFSK" && sub == "JS8")) return ModeGroup::Js8;
    if (m == "MFSK" && (sub == "FT4" || sub == "FST4" || sub == "FST4W" || sub == "FT2" || sub == "Q65")) return std::nullopt;  // WSJT-X's
    for (const char *k : {"PSK", "PSK2K", "QPSK31", "OLIVIA", "CONTESTI", "MFSK", "HELL", "MT63", "THOR", "THRB", "DOMINO", "CHIP", "CLO", "PAC", "PAX"})
        if (m == k) return ModeGroup::Psk;
    return std::nullopt;  // the WSJT-X modes (FT8, JT65, Q65, MSK144...), images (SSTV), data links...
}

// The built-in scripts. What each says follows these sources (all read 2026-11-03):
//  - CW and phone: IARU, Ethics and Operating Procedures for the Radio Amateur, 4th ed. rev. 4.2.0
//    (2026, CC BY-SA 4.0; www.iaru-r1.org/on-the-air/eop/): listen, then "QRL? DE" and your call, or
//    "Is this frequency in use?" (§12.5.2); "CQ CQ CQ DE" your call three times "K" (§13.2); the
//    report, then name, then QTH, and "HW CPY?" (§13.8); K to anyone, KN only the station worked
//    (§13.2.4); SK at a contact's end (§13.7); a phone close "73 and see you soon... now clear, and
//    standing by" (§13.8.1); the ITU phonetic alphabet, Alfa... Juliett... (§11.1, Table 11-A).
//  - RTTY and PSK: fldigi's own default macros (github.com/w1hkj/fldigi, src/misc/newinstall.cxx:
//    CQ "...pse k", the answer "...kn", "btu <NAME> <CALL> de <MYCALL> k", "tnx fer QSO <NAME>,
//    73... sk"), and its contest how-to (w1hkj.org/FldigiHelp, 4.2.00: "cq test de <MYCALL>
//    <MYCALL> cq k", the exchange "599 <CNTR> <CNTR> <X1> <X1>", the report once and the rest twice,
//    "qsl tu qrz test <MYCALL> k"); the IARU's chapter 14, the keyboard modes as CW. RTTY's in
//    capitals: its alphabet, ITA2, has 32 five-unit combinations, letters and figures, and no small
//    letters (ITU-T Rec. S.1, 03/93, §3.1, §4.4). PSK's in small letters: "the lower case letters
//    have the shortest patterns and so are the fastest to transmit" (PSK31 specification, §2).
//  - JS8Call: see the JS8Call group below.
//  - Chasing DX: the DX Code of Conduct (as IARU Region 1 publishes it, www.iaru-r1.org, "Updated
//    on January 2, 2020"): your full call, once, then listen; when called, your call again only if
//    it was copied wrong.
//  - POTA: docs.pota.app (rules v1.3, the activator, hunter and CW guides): no exchange is required,
//    though activators often give a real report and their location, and hunters their state; "CQ
//    POTA" and your call, the park reference if you like; park to park, your park after the report.
//  - Contests: IARU EOP 4th ed. §16.6 (only the required exchange; the running station's call in
//    every QSO; a short TU), and the contest's own exchange (adif_contest.h: {EXCH}).
const std::vector<Script> &builtIns() {
    using namespace adif::aids;
    const unsigned social = kSocial, portable = kPortable, chasing = kChasing, contest = kContest, home = kSocial | kPortable;
    const unsigned phone = modeBit(ModeGroup::Phone), cw = modeBit(ModeGroup::Cw), rtty = modeBit(ModeGroup::Rtty), psk = modeBit(ModeGroup::Psk);
    // id, title, styles, modes, text, before, shown, words (phone, translated)
    auto s = [](const char *id, const char *title, unsigned styles, unsigned modes, const char *text, bool before, bool shown, bool words) {
        Script x;
        x.id = id, x.title = title, x.styles = styles, x.modes = modes, x.text = text, x.before = before, x.shown = shown, x.words = words;
        x.builtIn = true;
        return x;
    };
    static const std::vector<Script> all = {
        // ── A conversation (Social), and the station topics Portable shares ──
        s("social.cw.qrl", N_("Is the frequency in use?"), social | contest | portable, cw, "QRL? DE {MYCALL}", true, true, false),
        s("social.rtty.qrl", N_("Is the frequency in use?"), social | contest | portable, rtty, "QRL? DE {MYCALL}", true, true, false),
        s("social.psk.qrl", N_("Is the frequency in use?"), social | contest | portable, psk, "qrl? de {MYCALL}", true, true, false),
        s("social.phone.qrl", N_("Is the frequency in use?"), social | contest | portable, phone, N_("Is this frequency in use? This is {MYCALL}."), true,
          true, true),
        s("social.cw.cq", N_("Call CQ"), social, cw, "CQ CQ CQ DE {MYCALL} {MYCALL} {MYCALL} K", true, true, false),
        s("social.rtty.cq", N_("Call CQ"), social, rtty, "CQ CQ CQ DE {MYCALL} {MYCALL} {MYCALL} PSE K", true, true, false),
        s("social.psk.cq", N_("Call CQ"), social, psk, "cq cq cq de {MYCALL} {MYCALL} {MYCALL} pse k", true, true, false),
        s("social.phone.cq", N_("Call CQ"), social, phone, N_("CQ CQ CQ, this is {MYCALL_PHONETIC}, {MYCALL_PHONETIC}, calling CQ and standing by."), true,
          true, true),
        s("social.cw.answer", N_("Answer a CQ"), social, cw, "{CALL} DE {MYCALL} {MYCALL} KN", false, true, false),
        s("social.rtty.answer", N_("Answer a CQ"), social, rtty, "{CALL} {CALL} DE {MYCALL} {MYCALL} {MYCALL} KN", false, true, false),
        s("social.psk.answer", N_("Answer a CQ"), social, psk, "{CALL} {CALL} de {MYCALL} {MYCALL} {MYCALL} kn", false, true, false),
        s("social.phone.answer", N_("Answer a CQ"), social, phone, N_("{CALL}, this is {MYCALL_PHONETIC}, {MYCALL_PHONETIC}."), false, true, true),
        s("social.cw.report", N_("Report, name and QTH"), social, cw,
          "{CALL} DE {MYCALL} R TNX FER CALL RST {RST_SENT} {RST_SENT} NAME {MYNAME} {MYNAME} QTH {MYQTH} {MYQTH} HW CPY? {CALL} DE {MYCALL} KN", false,
          true, false),
        s("social.rtty.report", N_("Report, name and QTH"), social, rtty,
          "{CALL} DE {MYCALL} TNX FER CALL. RST {RST_SENT} {RST_SENT}, NAME {MYNAME} {MYNAME}, QTH {MYQTH} {MYQTH}. HW CPY? BTU {CALL} DE {MYCALL} K",
          false, true, false),
        s("social.psk.report", N_("Report, name and QTH"), social, psk,
          "{CALL} de {MYCALL}: thanks for the call. rst {RST_SENT} {RST_SENT}, name {MYNAME} {MYNAME}, qth {MYQTH} {MYQTH}. how copy? btu {CALL} de "
          "{MYCALL} k",
          false, true, false),
        s("social.phone.report", N_("Report, name and QTH"), social, phone,
          N_("{CALL}, this is {MYCALL}. Thanks for the call. You're {RST_SENT} here. My name is {MYNAME}, and the QTH is {MYQTH}. How copy? {CALL}, "
             "this is {MYCALL}."),
          false, true, true),
        s("social.cw.station", N_("Your station"), home, cw, "RIG {MYRIG} {MYPWR} W ANTENNA {MYANT}", false, true, false),
        s("social.rtty.station", N_("Your station"), home, rtty, "MY STATION: {MYRIG} AT {MYPWR} W, ANTENNA {MYANT}.", false, true, false),
        s("social.psk.station", N_("Your station"), home, psk, "my station: a {MYRIG} at {MYPWR} w into a {MYANT}.", false, true, false),
        s("social.phone.station", N_("Your station"), home, phone, N_("The rig here is a {MYRIG}, running {MYPWR} watts into a {MYANT}."), false, true,
          true),
        s("social.cw.weather", N_("Your weather"), home, cw, "WEATHER {MYWX}", false, true, false),
        s("social.rtty.weather", N_("Your weather"), home, rtty, "WEATHER HERE: {MYWX}.", false, true, false),
        s("social.psk.weather", N_("Your weather"), home, psk, "the weather here: {MYWX}.", false, true, false),
        s("social.phone.weather", N_("Your weather"), home, phone, N_("The weather here is {MYWX}."), false, true, true),
        s("social.cw.licensed", N_("When you were licensed"), social, cw, "LICENSED {MYLICENSED}", false, false, false),
        s("social.rtty.licensed", N_("When you were licensed"), social, rtty, "LICENSED IN {MYLICENSED}.", false, false, false),
        s("social.psk.licensed", N_("When you were licensed"), social, psk, "i was licensed in {MYLICENSED}.", false, false, false),
        s("social.phone.licensed", N_("When you were licensed"), social, phone, N_("I was first licensed in {MYLICENSED}."), false, false, true),
        s("social.cw.age", N_("Your age"), social, cw, "AGE {MYAGE}", false, false, false),
        s("social.rtty.age", N_("Your age"), social, rtty, "AGE HERE: {MYAGE}.", false, false, false),
        s("social.psk.age", N_("Your age"), social, psk, "age here: {MYAGE}.", false, false, false),
        s("social.phone.age", N_("Your age"), social, phone, N_("I'm {MYAGE} years old."), false, false, true),
        s("social.cw.club", N_("Your club"), social, cw, "CLUB {MYCLUB}", false, false, false),
        s("social.rtty.club", N_("Your club"), social, rtty, "MEMBER OF {MYCLUB}.", false, false, false),
        s("social.psk.club", N_("Your club"), social, psk, "i'm a member of {MYCLUB}.", false, false, false),
        s("social.phone.club", N_("Your club"), social, phone, N_("I'm a member of {MYCLUB}."), false, false, true),
        s("social.cw.about", N_("About your station"), social, cw, "{MYABOUT}", false, false, false),
        s("social.rtty.about", N_("About your station"), social, rtty, "{MYABOUT}", false, false, false),
        s("social.psk.about", N_("About your station"), social, psk, "{MYABOUT}", false, false, false),
        s("social.phone.about", N_("About your station"), social, phone, "{MYABOUT}", false, false, false),
        s("social.cw.over", N_("Over to them"), social, cw, "{CALL} DE {MYCALL} KN", false, true, false),
        s("social.rtty.over", N_("Over to them"), social, rtty, "BTU {NAME} {CALL} DE {MYCALL} K", false, true, false),
        s("social.psk.over", N_("Over to them"), social, psk, "btu {NAME} {CALL} de {MYCALL} k", false, true, false),
        s("social.cw.close", N_("Close"), social, cw, "TNX FER QSO {NAME} 73 {CALL} DE {MYCALL} SK", false, true, false),
        s("social.rtty.close", N_("Close"), social, rtty, "TNX FER QSO {NAME}, 73. {CALL} DE {MYCALL} SK", false, true, false),
        s("social.psk.close", N_("Close"), social, psk, "tnx fer QSO {NAME}, 73. {CALL} de {MYCALL} sk", false, true, false),
        s("social.phone.close", N_("Close"), social, phone,
          N_("Thanks for the contact, {NAME}. 73, and see you soon. {CALL}, this is {MYCALL}, now clear and standing by."), false, true, true),

        // ── Chasing DX: your full call once, then listen; the report, and thanks ──
        s("chasing.cw.call", N_("Call the DX: your full call, once"), chasing, cw, "{MYCALL}", false, true, false),
        s("chasing.rtty.call", N_("Call the DX: your full call, once"), chasing, rtty, "{MYCALL} {MYCALL}", false, true, false),
        s("chasing.psk.call", N_("Call the DX: your full call, once"), chasing, psk, "{MYCALL} {MYCALL}", false, true, false),
        s("chasing.phone.call", N_("Call the DX: your full call, once"), chasing, phone, "{MYCALL_PHONETIC}", false, true, false),
        s("chasing.cw.report", N_("When they come back to you"), chasing, cw, "R {RST_SENT} TU", false, true, false),
        s("chasing.rtty.report", N_("When they come back to you"), chasing, rtty, "{CALL} R {RST_SENT} {RST_SENT} TU", false, true, false),
        s("chasing.psk.report", N_("When they come back to you"), chasing, psk, "{CALL} r {RST_SENT} {RST_SENT} tu", false, true, false),
        s("chasing.phone.report", N_("When they come back to you"), chasing, phone, N_("Roger, you're {RST_SENT}. Thank you, 73."), false, true, true),

        // ── POTA (Portable): no exchange is required; a real report and your state are usual ──
        s("portable.cw.cq", N_("Call CQ POTA"), portable, cw, "CQ POTA CQ POTA DE {MYCALL} {MYCALL} {MYPARK} K", true, true, false),
        s("portable.rtty.cq", N_("Call CQ POTA"), portable, rtty, "CQ POTA CQ POTA DE {MYCALL} {MYCALL} {MYPARK} PSE K", true, true, false),
        s("portable.psk.cq", N_("Call CQ POTA"), portable, psk, "cq pota cq pota de {MYCALL} {MYCALL} {MYPARK} pse k", true, true, false),
        s("portable.phone.cq", N_("Call CQ POTA"), portable, phone,
          N_("CQ Parks on the Air, CQ POTA, this is {MYCALL_PHONETIC} in {MYPARK}, standing by."), true, true, true),
        s("portable.cw.exchange", N_("Report and state"), portable, cw, "{CALL} {RST_SENT} {RST_SENT} {MYSTATE} {MYSTATE} K", false, true, false),
        s("portable.rtty.exchange", N_("Report and state"), portable, rtty, "{CALL} DE {MYCALL} {RST_SENT} {RST_SENT} {MYSTATE} {MYSTATE} K", false, true,
          false),
        s("portable.psk.exchange", N_("Report and state"), portable, psk, "{CALL} de {MYCALL} {RST_SENT} {RST_SENT} {MYSTATE} {MYSTATE} k", false, true,
          false),
        s("portable.phone.exchange", N_("Report and state"), portable, phone, N_("{CALL}, thanks for the call. You're {RST_SENT} in {MYSTATE}."), false,
          true, true),
        s("portable.cw.p2p", N_("Park to park: your park"), portable, cw, "{CALL} {RST_SENT} {RST_SENT} {MYPARK} {MYPARK} K", false, true, false),
        s("portable.rtty.p2p", N_("Park to park: your park"), portable, rtty, "{CALL} DE {MYCALL} {RST_SENT} {RST_SENT} PARK {MYPARK} {MYPARK} K", false,
          true, false),
        s("portable.psk.p2p", N_("Park to park: your park"), portable, psk, "{CALL} de {MYCALL} {RST_SENT} {RST_SENT} park {MYPARK} {MYPARK} k", false,
          true, false),
        s("portable.phone.p2p", N_("Park to park: your park"), portable, phone,
          N_("{CALL}, park to park! You're {RST_SENT}, and I'm in {MYPARK}. What's your park?"), false, true, true),
        s("portable.cw.thanks", N_("Thanks, and the next"), portable, cw, "TU 73 {MYCALL} POTA", false, true, false),
        s("portable.rtty.thanks", N_("Thanks, and the next"), portable, rtty, "TU 73 {CALL} DE {MYCALL} POTA K", false, true, false),
        s("portable.psk.thanks", N_("Thanks, and the next"), portable, psk, "tu 73 {CALL} de {MYCALL} pota k", false, true, false),
        s("portable.phone.thanks", N_("Thanks, and the next"), portable, phone, N_("Thanks, {CALL}, 73. This is {MYCALL}, Parks on the Air. QRZ?"), false,
          true, true),

        // ── Contests: only the exchange the contest asks for; your call in every QSO; a short TU ──
        s("contest.cw.cq", N_("Call CQ in the contest"), contest, cw, "CQ TEST {MYCALL} {MYCALL}", true, true, false),
        s("contest.rtty.cq", N_("Call CQ in the contest"), contest, rtty, "CQ TEST DE {MYCALL} {MYCALL} CQ K", true, true, false),
        s("contest.psk.cq", N_("Call CQ in the contest"), contest, psk, "cq test de {MYCALL} {MYCALL} cq k", true, true, false),
        s("contest.phone.cq", N_("Call CQ in the contest"), contest, phone, N_("CQ contest, CQ contest, this is {MYCALL_PHONETIC}, contest."), true, true,
          true),
        s("contest.cw.exchange", N_("The exchange"), contest, cw, "{CALL} {EXCH}", false, true, false),
        s("contest.rtty.exchange", N_("The exchange"), contest, rtty, "{CALL} {EXCH_TWICE} {CALL} K", false, true, false),
        s("contest.psk.exchange", N_("The exchange"), contest, psk, "{CALL} {EXCH_TWICE} {CALL} k", false, true, false),
        s("contest.phone.exchange", N_("The exchange"), contest, phone, N_("{CALL}, {EXCH}."), false, true, true),
        s("contest.cw.tu", N_("Thanks, and your call"), contest, cw, "TU {MYCALL}", false, true, false),
        s("contest.rtty.tu", N_("Thanks, and your call"), contest, rtty, "QSL TU QRZ TEST {MYCALL} K", false, true, false),
        s("contest.psk.tu", N_("Thanks, and your call"), contest, psk, "qsl tu qrz test {MYCALL} k", false, true, false),
        s("contest.phone.tu", N_("Thanks, and your call"), contest, phone, N_("Thank you. {MYCALL_PHONETIC}, contest."), false, true, true),

        // ── JS8Call ──
    };
    return all;
}

const Script *findBuiltIn(std::string_view id) {
    for (const Script &s : builtIns())
        if (s.id == id) return &s;
    return nullptr;
}

std::vector<Script> load(std::string_view fileText) {
    // The file's records by script id.
    struct Saved {
        std::map<std::string, std::string> fields;  // after APP_ADIFLINT_SCRIPT_
    };
    std::vector<std::pair<std::string, Saved>> saved;
    if (!trimmed(fileText).empty()) {
        LintOptions opt;
        opt.buildModel = true;
        opt.maxDiagnostics = 0;
        LintResult r = lint(fileText, opt);
        for (const Record &rec : records(fileText, r.model)) {
            Saved s;
            std::string id;
            for (const auto &[name, value] : rec.fields) {
                std::string n = upper(name);
                if (n == "APP_ADIFLINT_SCRIPT") id = trimmed(value);
                else if (n.rfind("APP_ADIFLINT_SCRIPT_", 0) == 0) s.fields[n.substr(20)] = value;
            }
            if (!id.empty()) saved.emplace_back(id, std::move(s));
        }
    }
    auto find = [&](const std::string &id) -> const Saved * {
        for (const auto &[i, s] : saved)
            if (i == id) return &s;
        return nullptr;
    };
    auto apply = [](Script &s, const Saved &f) {
        auto has = [&](const char *k) { return f.fields.count(k) > 0; };
        if (has("TITLE")) s.title = trimmed(f.fields.at("TITLE"));
        if (has("TEXT")) s.text = f.fields.at("TEXT");
        if (has("STYLES")) s.styles = parseStyles(f.fields.at("STYLES"));
        if (has("MODES")) s.modes = parseModes(f.fields.at("MODES"));
        if (has("WHEN")) s.before = trimmed(f.fields.at("WHEN")) == "before";
        if (has("SHOWN")) s.shown = upper(trimmed(f.fields.at("SHOWN"))) != "N";
    };
    std::vector<Script> out;
    for (const Script &b : builtIns()) {
        const Saved *f = find(b.id);
        if (f && f->fields.count("REMOVED") && upper(trimmed(f->fields.at("REMOVED"))) == "Y") continue;
        Script s = b;
        if (f) apply(s, *f);
        s.changed = !sameAsBuiltIn(s, b);
        out.push_back(std::move(s));
    }
    for (const auto &[id, f] : saved) {
        if (findBuiltIn(id)) continue;
        Script s;
        s.id = id;
        apply(s, f);
        if (s.title.empty()) s.title = id;
        out.push_back(std::move(s));
    }
    return out;
}

std::string fileText(const std::vector<Script> &scripts, std::string_view programVersion, std::string_view utcTimestamp) {
    std::string out = "ADIF Lint's Operating Aids scripts: a record for each built-in script changed, hidden or removed, and for each of "
                      "your own, named by APP_ADIFLINT_SCRIPT.\n";
    out += makeSpecifier("ADIF_VER", specVersion(), LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + "\n";
    out += "<EOH>\n";
    auto record = [&](const FieldList &fields) { out += buildRecord(fields, Layout::RecordPerLine, "\n", LengthUnit::Characters, true).text; };
    for (const Script &b : builtIns()) {
        auto it = std::find_if(scripts.begin(), scripts.end(), [&](const Script &s) { return s.id == b.id; });
        if (it == scripts.end()) {
            record({{"APP_ADIFLINT_SCRIPT", b.id}, {"APP_ADIFLINT_SCRIPT_REMOVED", "Y"}});
            continue;
        }
        bool changed = !sameAsBuiltIn(*it, b);
        if (!changed && it->shown == b.shown) continue;
        FieldList f{{"APP_ADIFLINT_SCRIPT", b.id}};
        if (changed) {
            f.emplace_back("APP_ADIFLINT_SCRIPT_TITLE", it->title);
            f.emplace_back("APP_ADIFLINT_SCRIPT_STYLES", styleList(it->styles));
            f.emplace_back("APP_ADIFLINT_SCRIPT_MODES", modeList(it->modes));
            f.emplace_back("APP_ADIFLINT_SCRIPT_WHEN", it->before ? "before" : "during");
            f.emplace_back("APP_ADIFLINT_SCRIPT_TEXT", it->text);
        }
        f.emplace_back("APP_ADIFLINT_SCRIPT_SHOWN", it->shown ? "Y" : "N");
        record(f);
    }
    for (const Script &s : scripts) {
        if (findBuiltIn(s.id)) continue;
        record({{"APP_ADIFLINT_SCRIPT", s.id},
                {"APP_ADIFLINT_SCRIPT_TITLE", s.title},
                {"APP_ADIFLINT_SCRIPT_STYLES", styleList(s.styles)},
                {"APP_ADIFLINT_SCRIPT_MODES", modeList(s.modes)},
                {"APP_ADIFLINT_SCRIPT_WHEN", s.before ? "before" : "during"},
                {"APP_ADIFLINT_SCRIPT_TEXT", s.text},
                {"APP_ADIFLINT_SCRIPT_SHOWN", s.shown ? "Y" : "N"}});
    }
    return out;
}

std::string newId(const std::vector<Script> &scripts) {
    for (int n = 1;; ++n) {
        std::string id = "mine." + std::to_string(n);
        if (std::none_of(scripts.begin(), scripts.end(), [&](const Script &s) { return s.id == id; })) return id;
    }
}

std::vector<const Script *> applicable(const std::vector<Script> &scripts, unsigned styleBit, ModeGroup group, bool before) {
    std::vector<const Script *> out;
    for (const Script &s : scripts)
        if (s.shown && (s.styles & styleBit) && (s.modes & modeBit(group)) && s.before == before) out.push_back(&s);
    return out;
}

const std::vector<Variable> &variables() {
    static const std::vector<Variable> all = {
        {"CALL", N_("their callsign")},
        {"CALL_PHONETIC", N_("their callsign in the ITU phonetic alphabet")},
        {"NAME", N_("their name (NAME, else from your last QSO with them)")},
        {"QTH", N_("their QTH (QTH, else from your last QSO with them)")},
        {"RST_SENT", N_("the report you give (RST_SENT)")},
        {"RST_RCVD", N_("the report they gave you (RST_RCVD)")},
        {"BAND", N_("the band")},
        {"MODE", N_("the mode")},
        {"FREQ", N_("the frequency, in MHz")},
        {"MYCALL", N_("your callsign (STATION_CALLSIGN, else OPERATOR)")},
        {"MYCALL_PHONETIC", N_("your callsign in the ITU phonetic alphabet")},
        {"MYNAME", N_("your name (Station Facts, else MY_NAME)")},
        {"MYQTH", N_("your QTH (Station Facts, else MY_CITY)")},
        {"MYGRID", N_("your grid square (MY_GRIDSQUARE)")},
        {"MYGRID4", N_("your grid square's first four characters")},
        {"MYSTATE", N_("your state or province (MY_STATE)")},
        {"MYRIG", N_("your rig (MY_RIG)")},
        {"MYANT", N_("your antenna (MY_ANTENNA)")},
        {"MYPWR", N_("your power, in watts (TX_PWR)")},
        {"MYLICENSED", N_("the year you were licensed (Station Facts)")},
        {"MYAGE", N_("your age (Station Facts)")},
        {"MYWX", N_("your weather (Station Facts)")},
        {"MYCLUB", N_("your club (Station Facts)")},
        {"MYABOUT", N_("a line about your station (Station Facts)")},
        {"MYPARK", N_("the park or summit you are activating (MY_POTA_REF, MY_SIG_INFO, MY_WWFF_REF or MY_SOTA_REF)")},
        {"EXCH", N_("the contest exchange you send: the report when the contest has one, your serial number, then the rest")},
        {"EXCH_TWICE", N_("the contest exchange as keyboard contests send it: the report once, the serial number and the rest twice")},
        {"SERIAL", N_("your next contest serial number")},
        {"CONTEST", N_("the contest's name")},
    };
    return all;
}

std::string fill(std::string_view text, const Values &values, std::vector<std::string> *missing) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size();) {
        if (text[i] == '{') {
            size_t close = text.find('}', i + 1);
            std::string_view name = close == std::string_view::npos ? std::string_view() : text.substr(i + 1, close - i - 1);
            bool word = !name.empty() && std::all_of(name.begin(), name.end(), [](char c) { return std::isupper((unsigned char)c) || std::isdigit((unsigned char)c) || c == '_'; });
            if (word) {
                auto it = values.find(std::string(name));
                if (it != values.end() && !it->second.empty()) {
                    out += it->second;
                } else {
                    out.append(text.substr(i, close - i + 1));
                    if (missing && std::find(missing->begin(), missing->end(), std::string(name)) == missing->end()) missing->emplace_back(name);
                }
                i = close + 1;
                continue;
            }
        }
        out += text[i++];
    }
    return out;
}

std::string phonetic(std::string_view call) {
    static const char *const kLetters[26] = {"Alfa",  "Bravo",  "Charlie", "Delta",   "Echo",   "Foxtrot", "Golf",   "Hotel",   "India",
                                             "Juliett", "Kilo", "Lima",    "Mike",    "November", "Oscar", "Papa",    "Quebec", "Romeo",
                                             "Sierra", "Tango", "Uniform", "Victor",  "Whiskey", "X-ray",  "Yankee",  "Zulu"};
    std::string out;
    for (char c : call) {
        if (c == ' ' || c == '\t') continue;
        unsigned char u = (unsigned char)std::toupper((unsigned char)c);
        std::string word = u >= 'A' && u <= 'Z' ? kLetters[u - 'A'] : std::string(1, (char)u);
        out += (out.empty() ? "" : " ") + word;
    }
    return out;
}

}  // namespace adif::scripts
