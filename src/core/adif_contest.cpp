#include "adif_contest.h"
#include "adif_i18n.h"

#include "adif_enrich.h"
#include "adif_spec.h"

#include <algorithm>
#include <cstdlib>
#include <iterator>

namespace adif {
using i18n::tr;
using i18n::trf;
using i18n::trp;
namespace {

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

bool isSection(std::string_view s) {
    const EnumDef *e = findEnum("ARRL_Section");
    return e && findEnumValue(*e, s);
}

// "1D IL" -> ("1D", "IL"); extra spaces allowed.
std::pair<std::string, std::string> splitExchange(std::string_view sent) {
    std::string s = upper(trimmed(sent));
    size_t sp = s.find_first_of(" \t");
    if (sp == std::string::npos) return {s, ""};
    return {s.substr(0, sp), trimmed(s.substr(sp))};
}

std::string get(const std::vector<std::pair<std::string, std::string>> &f, const char *name) {
    for (const auto &kv : f)
        if (kv.first == name) return trimmed(kv.second);
    return {};
}

}  // namespace

// ── Contests defined by their rules ──
// Each row's rules were read on 2026-10-25 from the organiser's page or PDF named in `source` (the
// ARRL and NCJ PDFs through a text reader): the exchange, the duplicate rule, the bands and modes.
// CONTEST_ID values are ADIF 3.1.7's Contest_ID enumeration (adif.org/317, 2026-03-22); the
// Cabrillo CONTEST tags the same strings (wwrof.org/cabrillo/cabrillo-v3-header, 2025-06-05, and
// the organisers' templates). The QSO line follows Cabrillo's "call rst exch call rst exch"
// (wwrof.org/cabrillo/cabrillo-qso-data, 2021-03-15); the ARRL DX, 10 m, 160 m and IARU rules
// publish no template of their own.
const std::vector<ContestDef> &contestDefs() {
    static const std::vector<ContestDef> defs = {
        {"CQ-WW-SSB", N_("CQ World Wide DX, SSB"), "PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, false, SentKind::CqZone, "4",
         {"CQZ"}, "cqww.com/rules, 2026 rules, read 2026-10-25",
         N_("A station counts once per band; zones and DXCC entities count once per band. QSOs in your own country score no points but "
            "count as multipliers. One mode a weekend; no 60, 30, 17 or 12 m.")},
        {"CQ-WW-CW", N_("CQ World Wide DX, CW"), "CW", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, false, SentKind::CqZone, "4",
         {"CQZ"}, "cqww.com/rules, 2026 rules, read 2026-10-25",
         N_("A station counts once per band; zones and DXCC entities count once per band. QSOs in your own country score no points but "
            "count as multipliers. One mode a weekend; no 60, 30, 17 or 12 m.")},
        {"CQ-WW-RTTY", N_("CQ World Wide DX, RTTY"), "RTTY", "80m 40m 20m 15m 10m", DupeRule::PerBand, true, false, SentKind::CqZoneQth, "4 IL",
         {"CQZ", "STATE"}, "cqwwrtty.com/rules.htm, 2026 rules, read 2026-10-25",
         N_("Send your CQ zone, and your state or province in the US and Canada (others send DX). RTTY only, 80 to 10 m without the WARC "
            "bands; multipliers count once per band.")},
        {"CQ-WPX-SSB", N_("CQ WPX, SSB"), "PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, true, SentKind::None, "", {"SRX"},
         "cqwpx.com/rules, 2026 rules, read 2026-10-25",
         N_("Each prefix counts once in the contest; QSOs on 40, 80 and 160 m count double. Single operators may operate 36 of the 48 "
            "hours, with off-times of at least 60 minutes.")},
        {"CQ-WPX-CW", N_("CQ WPX, CW"), "CW", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, true, SentKind::None, "", {"SRX"},
         "cqwpx.com/rules, 2026 rules, read 2026-10-25",
         N_("Each prefix counts once in the contest; QSOs on 40, 80 and 160 m count double. Single operators may operate 36 of the 48 "
            "hours, with off-times of at least 60 minutes.")},
        {"CQ-WPX-RTTY", N_("CQ WPX, RTTY"), "RTTY", "80m 40m 20m 15m 10m", DupeRule::PerBand, true, true, SentKind::None, "", {"SRX"},
         "cqwpxrtty.com/rules.htm, 2026 rules, read 2026-10-25",
         N_("Each prefix counts once in the contest. RTTY only, 80 to 10 m. Single operators may operate 30 of the 48 hours.")},
        {"ARRL-DX-CW", N_("ARRL International DX, CW"), "CW", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, false, SentKind::StateOrPower,
         "IL", {}, "ARRL International DX Contest rules v2.0, 2025-03-03 (contests.arrl.org), read 2026-10-25",
         N_("Only QSOs between W/VE and DX stations count. W/VE stations send their state or province and log the DX station's power; DX "
            "stations send their power and log states and provinces. KH6, KL7, CY9 and CY0 count as DX.")},
        {"ARRL-DX-SSB", N_("ARRL International DX, SSB"), "PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, true, false, SentKind::StateOrPower,
         "IL", {}, "ARRL International DX Contest rules v2.0, 2025-03-03 (contests.arrl.org), read 2026-10-25",
         N_("Only QSOs between W/VE and DX stations count. W/VE stations send their state or province and log the DX station's power; DX "
            "stations send their power and log states and provinces. KH6, KL7, CY9 and CY0 count as DX.")},
        {"IARU-HF", N_("IARU HF World Championship"), "CW PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerBandMode, true, false, SentKind::ItuZone,
         "8", {"ITUZ"}, "IARU HF Championship rules v1.21, 2025-07-10 (contests.arrl.org), read 2026-10-25",
         N_("A station counts once per band and mode; zones and HQ stations count once per band. HQ stations send their society (W1AW "
            "sends ARRL), officials AC, R1, R2 or R3.")},
        {"ARRL-SS-CW", N_("ARRL November Sweepstakes, CW"), "CW", "160m 80m 40m 20m 15m 10m", DupeRule::PerContest, false, true,
         SentKind::Sweepstakes, "A 72 IL", {"SRX", "PRECEDENCE", "CHECK", "ARRL_SECT"},
         "ARRL Sweepstakes rules v2.1, 2024-08-22 (contests.arrl.org), read 2026-10-25",
         N_("A station counts once in the contest, and W/VE stations work only W/VE. Send the same check all contest; W1AW/7 is W1AW. "
            "Single operators may operate 24 of the 30 hours.")},
        {"ARRL-SS-SSB", N_("ARRL November Sweepstakes, SSB"), "PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerContest, false, true,
         SentKind::Sweepstakes, "A 72 IL", {"SRX", "PRECEDENCE", "CHECK", "ARRL_SECT"},
         "ARRL Sweepstakes rules v2.1, 2024-08-22 (contests.arrl.org), read 2026-10-25",
         N_("A station counts once in the contest, and W/VE stations work only W/VE. Send the same check all contest; W1AW/7 is W1AW. "
            "Single operators may operate 24 of the 30 hours.")},
        {"NAQP-CW", N_("North American QSO Party, CW"), "CW", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, false, false, SentKind::NameQth,
         "ANDY IL", {"NAME", "STATE"}, "NAQP rules, NCJ Oct/Nov 2025 (ncjweb.com), read 2026-10-25",
         N_("One name all contest; a North American station on one end of every QSO; 100 W at most. Stations outside North America send "
            "only their name: log their QTH as DX.")},
        {"NAQP-SSB", N_("North American QSO Party, SSB"), "PH", "160m 80m 40m 20m 15m 10m", DupeRule::PerBand, false, false, SentKind::NameQth,
         "ANDY IL", {"NAME", "STATE"}, "NAQP rules, NCJ Oct/Nov 2025 (ncjweb.com), read 2026-10-25",
         N_("One name all contest; a North American station on one end of every QSO; 100 W at most. Stations outside North America send "
            "only their name: log their QTH as DX.")},
        {"NAQP-RTTY", N_("North American QSO Party, RTTY"), "RTTY", "80m 40m 20m 15m 10m", DupeRule::PerBand, false, false, SentKind::NameQth,
         "ANDY IL", {"NAME", "STATE"}, "NAQP rules, NCJ Oct/Nov 2025 (ncjweb.com), read 2026-10-25",
         N_("One name all contest; a North American station on one end of every QSO; 100 W at most; no 160 m.")},
        {"NA-SPRINT-CW", N_("North American Sprint, CW"), "CW", "80m 40m 20m", DupeRule::PerBand, false, true, SentKind::NameQth, "ANDY IL",
         {"SRX", "NAME", "STATE"}, "NA Sprint rules, 2026 (ncjweb.com), read 2026-10-25",
         N_("The QSY rule: after you call CQ and work a station, move at least 1 kHz to call another, or 5 kHz to call CQ again.")},
        {"NA-SPRINT-SSB", N_("North American Sprint, SSB"), "PH", "80m 40m 20m", DupeRule::PerBand, false, true, SentKind::NameQth, "ANDY IL",
         {"SRX", "NAME", "STATE"}, "ssbsprint.com/rules, read 2026-10-25",
         N_("The QSY rule: after you call CQ and work a station, move at least 1 kHz to call another, or 5 kHz to call CQ again.")},
        {"NA-SPRINT-RTTY", N_("North American Sprint, RTTY"), "RTTY", "80m 40m 20m", DupeRule::PerBand, false, true, SentKind::NameQth,
         "ANDY IL", {"SRX", "NAME", "STATE"}, "NA Sprint rules, 2026 (ncjweb.com), read 2026-10-25",
         N_("The QSY rule: after you call CQ and work a station, move at least 1 kHz to call another, or 5 kHz to call CQ again.")},
        {"ARRL-10", N_("ARRL 10-Meter Contest"), "CW PH", "10m", DupeRule::PerMode, true, false, SentKind::StateOrSerial, "IL", {"STATE"},
         "ARRL 10-Meter Contest rules v2.0, 2026 (arrl.org), read 2026-10-25",
         N_("A station counts once per mode, CW and phone; CW below 28.3 MHz. DX stations send serial numbers: leave your exchange empty "
            "for them, and log a DX station's serial in STATE (it goes to SRX).")},
        {"ARRL-160", N_("ARRL 160-Meter Contest"), "CW", "160m", DupeRule::PerBand, true, false, SentKind::SectionOrNone, "IL", {"ARRL_SECT"},
         "ARRL 160-Meter Contest rules v1.2b, 2024-08-22 (contests.arrl.org), read 2026-10-25",
         N_("CW only; DX-to-DX QSOs don't count. DX stations send only a report: leave your exchange empty.")},
        {"QSO-PARTY", N_("A state QSO party"), "CW PH DG", "", DupeRule::PerBandMode, true, false, SentKind::Location, "COOK", {"SRX_STRING"},
         "NEQP, CQP and FQP 2026 rules (neqp.org, cqp.org, floridaqsoparty.org), read 2026-10-25",
         N_("QSO parties differ: check the sponsor's rules. Give the party's CONTEST_ID (such as IL QSO Party or CA-QSO-PARTY); send your "
            "county in the state, or your state from outside it, as the sponsor lists them. Mobiles count again in each new county. "
            "A party that sends serial numbers: use Serial numbers.")},
    };
    return defs;
}

const ContestDef *findContestDef(std::string_view contestId) {
    for (const ContestDef &d : contestDefs())
        if (equalsNoCase(contestId, d.id)) return &d;
    return nullptr;
}

namespace {

const ContestDef *defOf(const ContestSetup &s) { return s.preset == ContestPreset::Defined ? findContestDef(s.contestId) : nullptr; }

std::vector<std::string> wordsOf(std::string_view text) {
    std::vector<std::string> out;
    std::string w;
    for (char c : upper(trimmed(text)) + " ")
        if (c == ' ' || c == '\t') {
            if (!w.empty()) out.push_back(w);
            w.clear();
        } else {
            w.push_back(c);
        }
    return out;
}

bool allDigits(std::string_view v) { return !v.empty() && std::all_of(v.begin(), v.end(), [](char c) { return c >= '0' && c <= '9'; }); }
bool allLetters(std::string_view v) { return !v.empty() && std::all_of(v.begin(), v.end(), [](char c) { return c >= 'A' && c <= 'Z'; }); }
bool inRange(std::string_view v, int lo, int hi) { return allDigits(v) && v.size() <= 3 && std::atoi(std::string(v).c_str()) >= lo && std::atoi(std::string(v).c_str()) <= hi; }
// A power as ARRL DX sends it: a number of watts, or an abbreviation (KW, 1K...).
bool isPower(std::string_view v) { return allDigits(v) || v == "KW" || (v.size() >= 2 && v.back() == 'K' && allDigits(v.substr(0, v.size() - 1))); }
// A US state or Canadian province abbreviation as contests send it (two or three letters, not DX).
bool isStateWord(std::string_view v) { return allLetters(v) && v.size() >= 2 && v.size() <= 3 && v != "DX"; }

// ARRL DX: are you a W/VE station (you send a state or province)?
bool sendsState(const ContestSetup &s) {
    std::vector<std::string> w = wordsOf(s.sent);
    return !w.empty() && !isPower(w[0]);
}

}  // namespace

std::string contestName(const ContestSetup &s) {
    if (const ContestDef *d = defOf(s)) return tr(d->name);
    return tr(contestPresetName(s.preset));
}

bool contestSerial(const ContestSetup &s) {
    if (s.preset == ContestPreset::Serial) return true;
    const ContestDef *d = defOf(s);
    if (!d) return false;
    if (d->sent == SentKind::StateOrSerial) return trimmed(s.sent).empty();  // ARRL 10 m: DX stations send serials
    return d->serial;
}

std::string dupeRuleText(const ContestSetup &s) {
    const ContestDef *d = defOf(s);
    switch (d ? d->dupe : DupeRule::PerBandMode) {
        case DupeRule::PerBand: return tr("a station counts once per band");
        case DupeRule::PerBandMode: return tr("a station counts once per band and mode");
        case DupeRule::PerContest: return tr("a station counts once in the contest");
        case DupeRule::PerMode: return tr("a station counts once per mode");
    }
    return "";
}

std::vector<std::string> contestRows(const ContestSetup &s) {
    const ContestDef *d = defOf(s);
    if (!d) return contestRows(s.preset);
    if (d->sent == SentKind::StateOrPower) return {sendsState(s) ? "RX_PWR" : "STATE"};  // W/VE log the DX station's power, DX the state
    std::vector<std::string> rows(d->rows.begin(), d->rows.end());
    return rows;
}

std::string contestRowProblem(const ContestSetup &s, std::string_view field, std::string_view value) {
    const ContestDef *d = defOf(s);
    std::string v = upper(trimmed(value)), f(field);
    if (!d || v.empty()) return "";
    if (f == "CQZ" && !inRange(v, 1, 40)) return tr("A CQ zone is a number from 1 to 40.");
    if (f == "ITUZ" && !inRange(v, 1, 90) && !(allLetters(v) && v.size() <= 6)) return tr("An ITU zone is a number from 1 to 90, or an HQ station's society.");
    if (f == "PRECEDENCE" && (v.size() != 1 || std::string("QABUMS").find(v[0]) == std::string::npos))
        return tr("The precedence is one of Q, A, B, U, M or S.");
    if (f == "CHECK" && !(allDigits(v) && v.size() == 2)) return tr("The check is the year first licensed, two digits.");
    if (f == "ARRL_SECT" && !isSection(v) && !(d->sent == SentKind::SectionOrNone && v == "DX"))
        return trf("Not an ARRL or RAC section: {section}", {{"section", v}});
    if (f == "RX_PWR" && !isPower(v)) return tr("The power is a number of watts, or an abbreviation such as KW.");
    return "";
}

std::vector<std::string> contestDrops(const ContestSetup &s, const std::vector<std::pair<std::string, std::string>> &qso) {
    std::vector<std::string> out;
    if (s.preset == ContestPreset::FieldDay || s.preset == ContestPreset::WinterFieldDay) {
        if (std::string sect = upper(get(qso, "ARRL_SECT")); !sect.empty() && !isSection(sect)) out.push_back("ARRL_SECT");
        return out;
    }
    if (!defOf(s)) return out;
    if (std::string v = upper(get(qso, "STATE")); !v.empty() && !isStateWord(v)) out.push_back("STATE");
    if (std::string v = upper(get(qso, "ARRL_SECT")); !v.empty() && !isSection(v)) out.push_back("ARRL_SECT");
    if (std::string v = upper(get(qso, "ITUZ")); !v.empty() && !inRange(v, 1, 90)) out.push_back("ITUZ");
    if (std::string v = upper(get(qso, "RX_PWR")); !v.empty() && !allDigits(v)) out.push_back("RX_PWR");
    return out;
}

namespace {

std::string definedSentProblem(const ContestSetup &s, const ContestDef &d) {
    std::vector<std::string> w = wordsOf(s.sent);
    std::string example = trf("such as {example}", {{"example", d.sentExample}});
    switch (d.sent) {
        case SentKind::None: return "";
        case SentKind::CqZone: return w.size() == 1 && inRange(w[0], 1, 40) ? "" : tr("Type your CQ zone, a number from 1 to 40.");
        case SentKind::CqZoneQth:
            return w.size() == 2 && inRange(w[0], 1, 40) && allLetters(w[1]) ? ""
                                                                            : tr("Type your CQ zone and your state or province, or DX, such as 4 IL.");
        case SentKind::ItuZone:
            return w.size() == 1 && (inRange(w[0], 1, 90) || (allLetters(w[0]) && w[0].size() <= 6)) ? ""
                                                                                                     : tr("Type your ITU zone, or your society's abbreviation.");
        case SentKind::State: return w.size() == 1 && allLetters(w[0]) ? "" : tr("Type your state or province.") + " " + example;
        case SentKind::StateOrPower:
            return w.size() == 1 && (isStateWord(w[0]) || isPower(w[0])) ? ""
                                                                         : tr("Type your state or province (W/VE), or your power (DX), such as IL or 100.");
        case SentKind::Sweepstakes: {
            bool ok = w.size() == 3 && w[0].size() == 1 && std::string("QABUMS").find(w[0][0]) != std::string::npos && allDigits(w[1]) &&
                      w[1].size() == 2 && isSection(w[2]);
            return ok ? "" : tr("Type your precedence (Q, A, B, U, M or S), check and section, such as A 72 IL.");
        }
        case SentKind::NameQth: return w.size() >= 2 ? "" : tr("Type your name and your state, province or country prefix, such as ANDY IL.");
        case SentKind::StateOrSerial: return w.empty() || (w.size() == 1 && allLetters(w[0])) ? "" : tr("Type your state or province, or nothing (DX).");
        case SentKind::SectionOrNone:
            return w.empty() || (w.size() == 1 && isSection(w[0])) ? "" : tr("Type your ARRL or RAC section, or nothing (DX).");
        case SentKind::Location:
            if (trimmed(s.partyId).empty()) return tr("Type the party's CONTEST_ID, such as IL QSO Party.");
            return w.empty() ? tr("Type your county or state, as the sponsor lists them.") : "";
    }
    return "";
}

// Your exchange's fields for a defined contest: the ADIF fields it fills (MY_CQ_ZONE...) and its
// words, after the report and serial, in STX_STRING.
void definedSentFields(const ContestSetup &s, const ContestDef &d, std::vector<std::pair<std::string, std::string>> &out) {
    std::vector<std::string> w = wordsOf(s.sent);
    if (w.empty()) return;
    std::string words;
    for (const std::string &x : w) words += (words.empty() ? "" : " ") + x;
    out.emplace_back("STX_STRING", words);
    switch (d.sent) {
        case SentKind::CqZone: out.emplace_back("MY_CQ_ZONE", std::to_string(std::atoi(w[0].c_str()))); break;
        case SentKind::CqZoneQth:
            out.emplace_back("MY_CQ_ZONE", std::to_string(std::atoi(w[0].c_str())));
            if (w.size() > 1 && isStateWord(w[1])) out.emplace_back("MY_STATE", w[1]);
            break;
        case SentKind::ItuZone:
            if (allDigits(w[0])) out.emplace_back("MY_ITU_ZONE", std::to_string(std::atoi(w[0].c_str())));
            break;
        case SentKind::State:
        case SentKind::StateOrSerial:
            if (isStateWord(w[0])) out.emplace_back("MY_STATE", w[0]);
            break;
        case SentKind::StateOrPower:
            if (isStateWord(w[0]) && !isPower(w[0])) out.emplace_back("MY_STATE", w[0]);
            else if (allDigits(w[0])) out.emplace_back("TX_PWR", w[0]);
            break;
        case SentKind::Sweepstakes:
            if (w.size() == 3 && isSection(w[2])) out.emplace_back("MY_ARRL_SECT", w[2]);
            break;
        case SentKind::NameQth:
            out.emplace_back("MY_NAME", w[0]);
            if (w.size() > 1 && isStateWord(w[1])) out.emplace_back("MY_STATE", w[1]);
            break;
        case SentKind::SectionOrNone:
            if (isSection(w[0])) out.emplace_back("MY_ARRL_SECT", w[0]);
            break;
        case SentKind::None:
        case SentKind::Location: break;
    }
}

}  // namespace

const char *contestPresetName(ContestPreset p) {
    switch (p) {
        case ContestPreset::FieldDay: return N_("ARRL Field Day");
        case ContestPreset::WinterFieldDay: return N_("Winter Field Day");
        case ContestPreset::Serial: return N_("Serial numbers");
        case ContestPreset::Defined:
        case ContestPreset::None: break;
    }
    return "";
}

std::vector<std::string> contestRows(ContestPreset p) {
    switch (p) {
        case ContestPreset::FieldDay:
        case ContestPreset::WinterFieldDay: return {"CLASS", "ARRL_SECT"};
        case ContestPreset::Serial: return {"SRX"};
        case ContestPreset::Defined:
        case ContestPreset::None: break;
    }
    return {};
}

std::string contestIdFor(const ContestSetup &s) {
    switch (s.preset) {
        case ContestPreset::FieldDay: return "ARRL-FIELD-DAY";
        case ContestPreset::WinterFieldDay: return "WFD";
        case ContestPreset::Serial: return upper(trimmed(s.contestId));
        case ContestPreset::Defined: {
            const ContestDef *d = findContestDef(s.contestId);
            if (!d) return "";
            if (std::string_view(d->id) == "QSO-PARTY") return trimmed(s.partyId);  // the party's own, as ADIF writes it
            return d->id;
        }
        case ContestPreset::None: break;
    }
    return "";
}

std::string classProblem(ContestPreset p, std::string_view cls) {
    std::string c = upper(trimmed(cls));
    if (c.empty() || (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay)) return "";
    size_t digits = 0;
    while (digits < c.size() && c[digits] >= '0' && c[digits] <= '9') ++digits;
    std::string letters = c.substr(digits);
    bool ok = digits >= 1 && digits <= 2 && c[0] != '0';
    if (p == ContestPreset::WinterFieldDay) {
        ok = ok && letters.size() == 1 && std::string("HIOM").find(letters[0]) != std::string::npos;
        return ok ? "" : tr("Winter Field Day sends the number of transmitters and a category, H, I, O or M, such as 2O.");
    }
    ok = ok && !letters.empty() && letters.size() <= 2 && std::all_of(letters.begin(), letters.end(), [](char ch) { return ch >= 'A' && ch <= 'F'; });
    return ok ? "" : tr("A Field Day class is the number of transmitters and a letter A to F, such as 3A.");
}

std::string sectionProblem(ContestPreset p, std::string_view section) {
    std::string s = upper(trimmed(section));
    if (s.empty() || (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay)) return "";
    if (isSection(s) || s == "DX" || (p == ContestPreset::WinterFieldDay && s == "MX")) return "";
    return p == ContestPreset::WinterFieldDay ? trf("Not an ARRL or RAC section (or MX, DX): {section}", {{"section", s}})
                                              : trf("Not an ARRL or RAC section (or DX): {section}", {{"section", s}});
}

std::string sentProblem(const ContestSetup &s) {
    if (s.preset == ContestPreset::Defined) {
        const ContestDef *d = defOf(s);
        return d ? definedSentProblem(s, *d) : tr("Choose a contest.");
    }
    if (s.preset != ContestPreset::FieldDay && s.preset != ContestPreset::WinterFieldDay) return "";
    auto [cls, sect] = splitExchange(s.sent);
    if (cls.empty() || sect.empty())
        return s.preset == ContestPreset::FieldDay ? tr("Type your class and section, such as 1D IL.")
                                                   : tr("Type your class, category and section, such as 2O IL.");
    std::string p = classProblem(s.preset, cls);
    if (p.empty()) p = sectionProblem(s.preset, sect);
    return p;
}

std::vector<std::pair<std::string, std::string>> contestFields(const ContestSetup &s,
                                                               const std::vector<std::pair<std::string, std::string>> &qso,
                                                               int serial) {
    std::vector<std::pair<std::string, std::string>> out;
    if (s.preset == ContestPreset::None) return out;
    std::string id = contestIdFor(s);
    if (!id.empty()) out.emplace_back("CONTEST_ID", id);
    if (s.preset == ContestPreset::Serial) {
        if (serial > 0) out.emplace_back("STX", std::to_string(serial));
        return out;
    }
    if (const ContestDef *d = defOf(s)) {
        if (serial > 0 && contestSerial(s)) out.emplace_back("STX", std::to_string(serial));
        definedSentFields(s, *d, out);
        // What they sent, in exchange order, after their report and serial (SRX has its own field;
        // an ARRL 10 m DX station's serial, typed where a state goes, becomes SRX).
        std::string rcvd;
        for (const std::string &row : contestRows(s)) {
            if (row == "SRX") continue;
            std::string v = upper(get(qso, row.c_str()));
            if (d->sent == SentKind::StateOrSerial && row == "STATE" && allDigits(v)) {
                out.emplace_back("SRX", std::to_string(std::atoi(v.c_str())));
                v = std::to_string(std::atoi(v.c_str()));
            }
            if (!v.empty()) rcvd += (rcvd.empty() ? "" : " ") + v;
        }
        if (!rcvd.empty() && std::find(d->rows.begin(), d->rows.end(), std::string_view("SRX_STRING")) == d->rows.end())
            out.emplace_back("SRX_STRING", rcvd);
        return out;
    }
    auto [cls, sect] = splitExchange(s.sent);
    if (!cls.empty()) out.emplace_back("STX_STRING", cls + (sect.empty() ? "" : " " + sect));
    if (isSection(sect)) out.emplace_back("MY_ARRL_SECT", sect);
    std::string theirClass = upper(get(qso, "CLASS")), theirSect = upper(get(qso, "ARRL_SECT"));
    if (!theirClass.empty() || !theirSect.empty())
        out.emplace_back("SRX_STRING", theirClass + (theirClass.empty() || theirSect.empty() ? "" : " ") + theirSect);
    return out;
}

int nextSerial(std::string_view text, const DocModel &m, std::string_view contestId) {
    long most = 0;
    for (const Record &r : records(text, m)) {
        if (!contestId.empty() && !equalsNoCase(trimmed(r.get("CONTEST_ID")), contestId)) continue;
        std::string stx = trimmed(r.get("STX"));
        char *end = nullptr;
        long n = std::strtol(stx.c_str(), &end, 10);
        if (!stx.empty() && end && *end == '\0' && n > most) most = n;
    }
    return (int)most + 1;
}

std::string modeCategory(std::string_view mode) {
    std::string m = upper(trimmed(mode));
    if (m == "CW") return "CW";
    if (m == "SSB" || m == "AM" || m == "FM" || m == "DIGITALVOICE" || m == "USB" || m == "LSB") return "PH";
    return "DG";
}

std::string contestRuleProblem(ContestPreset p, const Record &qso) {
    if (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay) return "";
    std::string band = effectiveBand(qso), prop = upper(trimmed(qso.get("PROP_MODE")));
    if (p == ContestPreset::FieldDay) {
        static const char *const hf[] = {"160m", "80m", "40m", "20m", "15m", "10m"};
        const BandDef *b = findBand(band);
        bool counted = !b || b->lowerMHz >= 50 || std::find(std::begin(hf), std::end(hf), band) != std::end(hf);
        if (!counted) return trf("ARRL Field Day counts 160, 80, 40, 20, 15 and 10 m and 6 m and up, not {band}.", {{"band", band}});
        if (prop == "RPT") return tr("ARRL Field Day doesn't count repeater contacts.");
        return "";
    }
    if (band == "12m" || band == "17m" || band == "30m" || band == "60m")
        return tr("Winter Field Day doesn't use 12, 17, 30 or 60 m.");
    static const char *const wsjt[] = {"FT2", "FST4", "FT4", "FT8", "JT4", "JT9", "JT65", "Q65", "MSK144", "WSPR", "FST4W", "ECHO"};
    for (const char *m : {"MODE", "SUBMODE"}) {
        std::string v = upper(trimmed(qso.get(m)));
        if (std::find(std::begin(wsjt), std::end(wsjt), v) != std::end(wsjt))
            return trf("Winter Field Day doesn't count WSJT modes such as {mode}.", {{"mode", v}});
    }
    if (prop == "RPT" || prop == "SAT" || prop == "ECH" || prop == "INTERNET" || prop == "IRL")
        return tr("Winter Field Day counts only direct simplex contacts, not through a repeater, satellite or the internet.");
    return "";
}

std::vector<int> contestDupes(std::string_view text, const DocModel &m, std::string_view contestId, const Record &qso) {
    std::vector<int> out;
    std::string call = lookupCall(upper(trimmed(qso.get("CALL"))));
    std::string band = upper(effectiveBand(qso)), cat = modeCategory(qso.get("MODE"));
    if (call.empty() || band.empty()) return out;
    for (const Record &r : records(text, m)) {
        if (!contestId.empty() && !equalsNoCase(trimmed(r.get("CONTEST_ID")), contestId)) continue;
        if (lookupCall(upper(trimmed(r.get("CALL")))) != call || upper(effectiveBand(r)) != band) continue;
        if (modeCategory(r.get("MODE")) != cat) continue;
        out.push_back(r.number);
    }
    return out;
}

std::string contestRuleProblem(const ContestSetup &s, const Record &qso) {
    const ContestDef *d = defOf(s);
    if (!d) return contestRuleProblem(s.preset, qso);
    std::string name = tr(d->name);
    std::string band = effectiveBand(qso);
    std::vector<std::string> bands = wordsOf(d->bands);
    for (std::string &b : bands)
        for (char &c : b) c = (char)std::tolower((unsigned char)c);
    if (!bands.empty() && !band.empty() && std::find(bands.begin(), bands.end(), band) == bands.end())
        return trf("{contest} doesn't count {band}.", {{"contest", name}, {"band", band}});
    std::string mode = upper(trimmed(qso.get("MODE"))), cat = modeCategory(mode);
    std::string modes = d->modes;
    if (modes == "RTTY" ? !mode.empty() && mode != "RTTY" : !mode.empty() && modes.find(cat) == std::string::npos)
        return trf("{contest} doesn't count {mode} QSOs.", {{"contest", name}, {"mode", mode}});
    if (std::string_view(d->id) == "ARRL-10" && cat == "CW") {
        double mhz = std::atof(trimmed(qso.get("FREQ")).c_str());
        if (mhz > 28.3) return tr("ARRL 10-Meter Contest CW QSOs are below 28.3 MHz.");
    }
    return "";
}

std::vector<int> contestDupes(std::string_view text, const DocModel &m, const ContestSetup &s, const Record &qso) {
    const ContestDef *d = defOf(s);
    if (!d) return contestDupes(text, m, contestIdFor(s), qso);
    std::vector<int> out;
    std::string id = contestIdFor(s);
    std::string call = lookupCall(upper(trimmed(qso.get("CALL"))));
    std::string band = upper(effectiveBand(qso)), cat = modeCategory(qso.get("MODE"));
    if (call.empty()) return out;
    for (const Record &r : records(text, m)) {
        if (!id.empty() && !equalsNoCase(trimmed(r.get("CONTEST_ID")), id)) continue;
        if (lookupCall(upper(trimmed(r.get("CALL")))) != call) continue;
        bool sameBand = upper(effectiveBand(r)) == band, sameMode = modeCategory(r.get("MODE")) == cat;
        bool dupe = d->dupe == DupeRule::PerContest || (d->dupe == DupeRule::PerBand && sameBand) ||
                    (d->dupe == DupeRule::PerBandMode && sameBand && sameMode) || (d->dupe == DupeRule::PerMode && sameMode);
        if (dupe) out.push_back(r.number);
    }
    return out;
}

}  // namespace adif
