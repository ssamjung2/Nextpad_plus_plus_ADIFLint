#import "Contest.h"
#import "L10n.h"

#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <map>

using namespace adifhost;

namespace contest {
namespace {

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *preset = nil;
    NSTextField *sent = nil, *contestId = nil, *idLabel = nil;
    NSTextField *rules = nil;  // a contest's bands, what to keep in mind, and where its rules were read
    NSStackView *sentRow = nil, *idRow = nil;
    NSButton *start = nil;
} cw;

// Settings: contestPreset FD, WFD, SERIAL or DEF; contestDef the defined contest's CONTEST_ID;
// contestId Serial's CONTEST_ID; contestParty a QSO party's; contestSent your exchange.
adif::ContestPreset presetFrom(const std::string &s) {
    return s == "FD" ? adif::ContestPreset::FieldDay : s == "WFD" ? adif::ContestPreset::WinterFieldDay
                     : s == "SERIAL"                 ? adif::ContestPreset::Serial
                     : s == "DEF"                    ? adif::ContestPreset::Defined
                                                     : adif::ContestPreset::None;
}
const char *presetKey(adif::ContestPreset p) {
    return p == adif::ContestPreset::FieldDay ? "FD" : p == adif::ContestPreset::WinterFieldDay ? "WFD" : p == adif::ContestPreset::Serial ? "SERIAL"
           : p == adif::ContestPreset::Defined ? "DEF" : "";
}

bool isParty(const adif::ContestSetup &s) { return s.preset == adif::ContestPreset::Defined && s.contestId == "QSO-PARTY"; }

// What the window shows now (not necessarily running).
adif::ContestSetup chosen() {
    adif::ContestSetup s;
    NSString *key = cw.preset.selectedItem.representedObject ?: @"FD";
    s.preset = presetFrom(ADIFStd(key));
    if (s.preset == adif::ContestPreset::None) s.preset = adif::ContestPreset::Defined, s.contestId = ADIFStd(key);
    s.sent = ADIFStd(cw.sent.stringValue);
    if (s.preset == adif::ContestPreset::Serial) s.contestId = ADIFStd(cw.contestId.stringValue);
    if (isParty(s)) s.partyId = ADIFStd(cw.contestId.stringValue);
    return s;
}

void refresh() {
    if (!cw.w) return;
    adif::ContestSetup s = chosen();
    const adif::ContestDef *def = s.preset == adif::ContestPreset::Defined ? adif::findContestDef(s.contestId) : nullptr;
    bool fieldDay = s.preset == adif::ContestPreset::FieldDay || s.preset == adif::ContestPreset::WinterFieldDay;
    cw.sentRow.hidden = !fieldDay && !(def && def->sent != adif::SentKind::None);
    cw.idRow.hidden = s.preset != adif::ContestPreset::Serial && !isParty(s);
    cw.sent.placeholderString = s.preset == adif::ContestPreset::WinterFieldDay ? T(@"e.g. 2O IL")
                                : def                                          ? TF(@"e.g. {example}", @{@"example" : ADIFString(def->sentExample)})
                                                                               : T(@"e.g. 1D IL");
    cw.contestId.placeholderString = isParty(s) ? T(@"e.g. IL QSO Party, CA-QSO-PARTY") : T(@"e.g. CQ-WPX-SSB (optional)");
    bool running = setting("contestActive") == "1";
    cw.start.title = running ? T(@"Stop") : T(@"Start");
    [cw.w setTarget:TF(@"Log: {name}", @{@"name" : ADIFString(documentName())})];
    // This log's contest QSOs per band and mode.
    std::string id = adif::contestIdFor(s);
    std::map<std::string, std::map<std::string, size_t>> count;
    size_t total = 0;
    int next = 1;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        for (const adif::Record &rec : adif::records(text, r.model)) {
            if (!id.empty() && !adif::equalsNoCase(rec.get("CONTEST_ID"), id)) continue;
            if (id.empty() && rec.get("STX").empty()) continue;
            ++count[adif::effectiveBand(rec)][adif::modeCategory(rec.get("MODE"))];
            ++total;
        }
        next = adif::nextSerial(text, r.model, id);
    } catch (...) {
    }
    std::vector<std::vector<std::string>> rows;
    for (const auto &entry : count) {
        const std::map<std::string, size_t> &modes = entry.second;
        auto n = [&modes](const char *m) {
            auto it = modes.find(m);
            return it == modes.end() ? std::string() : std::to_string(it->second);
        };
        size_t sum = 0;
        for (const auto &kv : modes) sum += kv.second;
        rows.push_back({entry.first.empty() ? "?" : entry.first, n("CW"), n("PH"), n("DG"), std::to_string(sum)});
    }
    [cw.w setRows:rows severities:std::vector<int>()];
    std::string problem = adif::sentProblem(s);
    if (s.preset == adif::ContestPreset::Serial && running)
        problem.clear();
    std::string st;
    int severity = -1;
    if (!problem.empty()) st = problem, severity = 2;
    else if (s.preset == adif::ContestPreset::Serial)
        st = trf(id.empty() ? "New QSO asks for SRX and writes STX {n} next, counting up. {qsos} so far."
                            : "New QSO asks for SRX and writes STX {n} next, counting up, with CONTEST_ID {id}. {qsos} so far.",
                 {{"n", std::to_string(next)}, {"id", id}, {"qsos", plural(total, "QSO")}});
    else if (def) {
        std::string asks;
        for (const std::string &row : adif::contestRows(s)) asks += (asks.empty() ? "" : ", ") + row;
        std::string bands = def->bands;
        st = trf("New QSO asks for {rows} and writes CONTEST_ID {id}{serial}; {rule}.",
                 {{"rows", asks.empty() ? tr("the report") : asks},
                  {"id", id},
                  {"serial", adif::contestSerial(s) ? trf(", and STX {n} next, counting up", {{"n", std::to_string(next)}}) : std::string()},
                  {"rule", adif::dupeRuleText(s)}}) +
             " " + trf("{qsos} in this log.", {{"qsos", plural(total, "QSO")}});
    } else
        st = trf("New QSO asks for their CLASS and ARRL_SECT and writes CONTEST_ID {id}, your exchange in STX_STRING and theirs in SRX_STRING. "
                 "A station counts once per band and mode (CW, Phone, Digital).",
                 {{"id", id}}) +
             " " +
             (s.preset == adif::ContestPreset::WinterFieldDay ? tr("Not on 12, 17, 30 or 60 m, and no WSJT modes such as FT8 (2027 rules).")
                                                               : tr("Bands 160, 80, 40, 20, 15 and 10 m and 6 m up (2026 rules).")) +
             " " + trf("{qsos} in this log.", {{"qsos", plural(total, "QSO")}});
    if (running) st = trf("Running: {status}", {{"status", st}});
    std::string rules;
    if (def) {
        std::string bands = def->bands;
        rules = (bands.empty() ? "" : trf("Bands: {bands}.", {{"bands", bands}}) + " ") + tr(def->notes) + " " +
                trf("Rules: {source}.", {{"source", def->source}});
    }
    cw.rules.stringValue = ADIFString(rules);
    cw.rules.superview.hidden = rules.empty();
    [cw.w setStatus:ADIFString(st) severity:severity];
    cw.start.enabled = running || problem.empty();
}

void startStop() {
    if (setting("contestActive") == "1") {
        setSetting("contestActive", "0");
        setSetting("contestStopped", "1");  // New QSO empties the contest's rows once
    } else {
        adif::ContestSetup s = chosen();
        if (!adif::sentProblem(s).empty()) return refresh();
        setSetting("contestPreset", presetKey(s.preset));
        setSetting("contestSent", s.sent);
        if (s.preset == adif::ContestPreset::Defined) setSetting("contestDef", s.contestId), setSetting("contestParty", s.partyId);
        else setSetting("contestId", s.contestId);
        setSetting("contestActive", "1");
        openNewQso();
    }
    stationChanged();  // New QSO's rows follow
    refresh();
}

}  // namespace

adif::ContestSetup setup() {
    adif::ContestSetup s;
    if (setting("contestActive") != "1") return s;
    s.preset = presetFrom(setting("contestPreset"));
    s.sent = setting("contestSent");
    s.contestId = setting(s.preset == adif::ContestPreset::Defined ? "contestDef" : "contestId");
    if (s.preset == adif::ContestPreset::Defined) s.partyId = setting("contestParty");
    return s;
}

std::string label() {
    adif::ContestSetup s = setup();
    if (s.preset == adif::ContestPreset::None) return "";
    std::string out = adif::contestName(s);
    if (s.preset == adif::ContestPreset::Serial) return out + (s.contestId.empty() ? "" : " (" + s.contestId + ")");
    if (isParty(s)) out += " (" + s.partyId + ")";
    return s.sent.find_first_not_of(" ") == std::string::npos ? out : out + ", " + trf("sending {exchange}", {{"exchange", s.sent}});
}

void documentChanged() {
    if (cw.w && cw.w.window.visible) refresh();
}

void cmdContest() {
    if (!cw.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Contest" size:NSMakeSize(660, 480) headline:NO];
        cw.w = w;
        // The Field Days and serial numbers, then the contests known by their rules.
        cw.preset = ADIFPopup(@[ @"ARRL Field Day", @"Winter Field Day", @"Serial numbers" ]);
        cw.preset.identifier = @"contest.preset";
        cw.preset.itemArray[0].representedObject = @"FD", cw.preset.itemArray[1].representedObject = @"WFD";
        cw.preset.itemArray[2].representedObject = @"SERIAL";
        [cw.preset.menu addItem:[NSMenuItem separatorItem]];
        for (const adif::ContestDef &d : adif::contestDefs())
            [cw.preset.menu addItemWithTitle:ADIFString(adif::i18n::tr(d.name)) action:nil keyEquivalent:@""].representedObject = @(d.id);
        adif::ContestPreset p = presetFrom(setting("contestPreset"));
        NSString *want = p == adif::ContestPreset::Defined ? ADIFString(setting("contestDef")) : @(presetKey(p));
        NSInteger at = [cw.preset indexOfItemWithRepresentedObject:want];
        [cw.preset selectItemAtIndex:at >= 0 ? at : 0];
        [w addOptionRow:@[ ADIFLabel(@"Contest:"), cw.preset ]];
        cw.sent = ADIFTextField(@"e.g. 1D IL", 120);
        cw.sent.stringValue = ADIFString(setting("contestSent"));
        cw.sentRow = [w addOptionRow:@[ ADIFLabel(@"Your exchange:"), cw.sent ]];
        cw.sent.identifier = @"contest.sent";
        cw.contestId = ADIFTextField(@"e.g. CQ-WPX-SSB (optional)", 220);
        cw.contestId.identifier = @"contest.id";
        cw.contestId.stringValue = ADIFString(setting(p == adif::ContestPreset::Defined ? "contestParty" : "contestId"));
        cw.idRow = [w addOptionRow:@[ ADIFLabel(@"CONTEST_ID:"), cw.contestId ]];
        cw.rules = [NSTextField wrappingLabelWithString:@""];
        cw.rules.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        cw.rules.textColor = NSColor.secondaryLabelColor;
        cw.rules.preferredMaxLayoutWidth = 580;
        [cw.rules.widthAnchor constraintEqualToConstant:580].active = YES;
        cw.rules.identifier = @"contest.rules";
        [w addOptionRow:@[ cw.rules ]];
        ADIFOnAction(cw.preset, ^{
            if (setting("contestActive") == "1") setSetting("contestActive", "0"), setSetting("contestStopped", "1"), stationChanged();
            refresh();
        });
        for (NSTextField *f in @[ cw.sent, cw.contestId ])
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:f
                                                               queue:nil
                                                          usingBlock:^(NSNotification *) { refresh(); }];
        [w setColumns:std::vector<ADIFToolColumn>{{"band", "Band", 70}, {"cw", "CW", 60}, {"ph", "Phone", 60}, {"dg", "Digital", 60},
                                                  {"total", "Total", 60}}
            checkboxes:NO
              sortable:NO];
        cw.start = [w addButton:@"Start" trailing:YES action:^{ startStop(); }];
        [w setDefaultButton:cw.start];
    }
    refresh();
    [cw.w show];
}

}  // namespace contest
