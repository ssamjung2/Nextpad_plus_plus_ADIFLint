#import "LogTools.h"

#import "Lookup.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Scintilla.h"
#include "adif_enrich.h"
#include "adif_spec.h"
#include "adif_tools.h"
#include "adif_upload.h"
#include "adif_programs.h"
#include "adif_formats.h"

#include <sys/stat.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <unordered_map>

using namespace adifhost;

namespace {

// ── Shared helpers ──────────────────────────────────────────────────────────

const std::vector<std::vector<std::string>> kNoRows;
const std::vector<int> kNoSev;
const std::vector<bool> kNoTicks;

NSString *logLine() { return [@"Log: " stringByAppendingString:ADIFString(documentName())]; }

std::string plural(size_t n, const char *word, const char *many = nullptr) {
    return std::to_string(n) + " " + (n == 1 ? std::string(word) : many ? std::string(many) : std::string(word) + "s");
}

bool hasRecords(const adif::LintResult &r) { return adif::recordCount(r.model) > 0; }

// Why the log's structure rules out an edit that moves or rebuilds records, or "".
std::string structureProblem(const adif::LintResult &r) {
    if (!adif::canReformat(r))
        return "The log has structural problems (wrong lengths or broken tags). Run Fix Lengths, then fix the errors "
               "marked in red.";
    for (const adif::ModelGroup &g : r.model.groups)
        if (!g.header && g.markerB == adif::kNoPos) return "A record has no <EOR>. Add it, then try again.";
    return "";
}

std::vector<int> allRecords(const adif::DocModel &m) {
    std::vector<int> out;
    for (size_t i = 0; i < m.groups.size(); ++i)
        if (!m.groups[i].header) out.push_back((int)i);
    return out;
}

// Records touching the editor selection; the record at the caret when nothing is selected.
std::vector<int> selectionRecords(NppHandle h, const adif::DocModel &m) {
    size_t b = (size_t)sci(h, SCI_GETSELECTIONSTART), e = (size_t)sci(h, SCI_GETSELECTIONEND);
    std::vector<int> out;
    for (size_t i = 0; i < m.groups.size(); ++i) {
        const adif::ModelGroup &g = m.groups[i];
        if (g.header) continue;
        size_t gb = adif::groupStart(m, g), ge = adif::groupEnd(m, g);
        bool touch = b == e ? (gb <= b && b <= ge) : (gb < e && ge > b);
        if (touch) out.push_back((int)i);
    }
    return out;
}

std::string fileName(const std::string &path) {
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string stem(const std::string &name) {
    size_t dot = name.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? name : name.substr(0, dot);
}

NSString *tilde(const std::string &path) { return [ADIFString(path) stringByAbbreviatingWithTildeInPath]; }

bool writeFile(const std::string &path, const std::string &data, std::string *error) {
    NSData *d = [NSData dataWithBytes:data.data() length:data.size()];
    NSError *err = nil;
    if ([d writeToFile:ADIFString(path) options:NSDataWritingAtomic error:&err]) return true;
    if (error) *error = ADIFStd(err.localizedDescription ?: @"could not write the file");
    return false;
}

bool readFile(const std::string &path, size_t limit, std::string *out, std::string *error) {
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) {
        if (error) *error = "cannot read " + fileName(path);
        return false;
    }
    if ((size_t)st.st_size > limit) {
        if (error) *error = fileName(path) + " is larger than " + std::to_string(limit >> 20) + " MB";
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        if (error) *error = "cannot read " + fileName(path);
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    *out = ss.str();
    return true;
}

adif::LintResult lintText(std::string_view text) {
    adif::LintOptions opt;
    opt.lengthUnit = lengthUnit();
    opt.buildModel = true;
    return adif::lint(text, opt);
}

// File dialogs. The test harness sets these variables to skip them.
std::string chooseSave(NSString *suggested, NSArray<NSString *> *extensions) {
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) return std::string(dir) + "/" + ADIFStd(suggested);
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = suggested;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *ext in extensions)
        if (UTType *t = [UTType typeWithFilenameExtension:ext]) [types addObject:t];
    p.allowedContentTypes = types;
    p.canCreateDirectories = YES;
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

std::string chooseOpen(NSString *message, bool folder, NSArray<NSString *> *extensions = nil) {
    if (const char *env = getenv(folder ? "ADIFLINT_TEST_FOLDER" : "ADIFLINT_TEST_OPEN_FILE")) return env;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = message;
    p.canChooseFiles = !folder;
    p.canChooseDirectories = folder;
    p.allowsMultipleSelection = NO;
    p.canCreateDirectories = folder;
    if (!folder) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *ext in extensions ?: @[ @"adi", @"adif" ])
            if (UTType *t = [UTType typeWithFilenameExtension:ext]) [types addObject:t];
        p.allowedContentTypes = types;
    }
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

NSArray<NSString *> *nsList(const std::vector<std::string> &v) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:v.size()];
    for (const std::string &s : v) [a addObject:ADIFString(s)];
    return a;
}

// Field names for a field chooser: the log's own fields first, then every QSO field.
std::vector<std::string> fieldChoices(std::string_view text, const adif::DocModel &m) {
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (const adif::Record &r : adif::records(text, m))
        for (const auto &f : r.fields)
            if (seen.insert(f.first).second) out.push_back(f.first);
    std::sort(out.begin(), out.end());
    for (const std::string &n : adif::fieldNameChoices(m, false))
        if (n != "EOR" && seen.insert(n).second) out.push_back(n);
    return out;
}

long parseLong(NSTextField *f) {
    std::string s = ADIFStd(f.stringValue);
    char *end = nullptr;
    long v = std::strtol(s.c_str(), &end, 10);
    return end && *end == 0 ? v : 0;
}

bool isInteger(NSTextField *f) {
    std::string s = ADIFStd(f.stringValue);
    if (s.empty()) return true;
    char *end = nullptr;
    std::strtol(s.c_str(), &end, 10);
    return end && *end == 0;
}

// ── Log Table ───────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSSearchField *search = nil;
    NSTextField *count = nil;
    intptr_t buffer = 0;
    std::vector<adif::Record> recs;   // per model row
    std::vector<std::string> columns; // shown, after "#"
    std::vector<std::string> all;     // every field the log uses
    std::vector<size_t> starts;       // record start per model row
    NSMenu *menu = nil;               // the headings' menu: show or hide columns
} table;

// Hidden columns and the sort, kept in ADIFLint.ini.
std::set<std::string> tableHidden() {
    std::set<std::string> out;
    std::string list = setting("tableHidden"), item;
    for (size_t i = 0; i <= list.size(); ++i) {
        if (i == list.size() || list[i] == ',') {
            if (!item.empty()) out.insert(item);
            item.clear();
        } else {
            item.push_back(list[i]);
        }
    }
    return out;
}

bool isDateField(const std::string &f) {
    const adif::FieldDef *d = adif::findField(f);
    return d && d->type == adif::DataType::Date;
}

bool isTimeField(const std::string &f) {
    const adif::FieldDef *d = adif::findField(f);
    return d && d->type == adif::DataType::Time;
}

void tableRefresh();
void tableEdit(NSInteger row, size_t column, NSString *text);

bool tableVisible() { return table.w && table.w.window.visible; }

void tableUpdateCount() {
    if (!table.w) return;
    size_t shown = [table.w shownRows].size();
    table.count.stringValue = shown == table.recs.size()
                                  ? ADIFString(plural(table.recs.size(), "record"))
                                  : [NSString stringWithFormat:@"%zu of %@", shown, ADIFString(plural(table.recs.size(), "record"))];
}

void tableRefresh() {
    if (!table.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        [table.w setTarget:logLine()];
        table.buffer = buffer();
        table.recs = adif::records(text, r.model);
        table.all = adif::tableColumns(table.recs);
        std::set<std::string> hidden = tableHidden();
        std::vector<std::string> cols;
        for (const std::string &c : table.all)
            if (!hidden.count(c)) cols.push_back(c);
        if (cols != table.columns || table.w.window.isVisible == NO) {
            table.columns = cols;
            std::vector<ADIFToolColumn> tc{{"#", "#", 44}};
            for (const std::string &c : cols) {
                CGFloat w = c == "QSO_DATE" ? 76 : c == "TIME_ON" || c == "TIME_OFF" ? 58 : c == "CALL" ? 84 : c == "BAND" ? 48
                          : c == "MODE" || c == "SUBMODE" ? 56 : c == "FREQ" ? 68 : c.rfind("RST_", 0) == 0 ? 52 : 96;
                tc.push_back({c, c, w});
            }
            [table.w setColumns:tc checkboxes:NO sortable:YES];
            std::vector<size_t> editable;
            for (size_t i = 1; i <= cols.size(); ++i) editable.push_back(i);
            [table.w setEditableColumns:editable];
            // The remembered sort: "FIELD:a" or "FIELD:d".
            std::string sort = setting("tableSort");
            size_t colon = sort.find(':');
            if (colon != std::string::npos) {
                std::string field = sort.substr(0, colon);
                auto it = std::find(cols.begin(), cols.end(), field);
                NSInteger col = field == "#" ? 0 : it == cols.end() ? -1 : (NSInteger)(it - cols.begin()) + 1;
                if (col >= 0) [table.w setSortColumn:col ascending:sort.substr(colon + 1) != "d"];
            }
        }
        // The headings' menu lists every field; ticked ones are shown.
        [table.menu removeAllItems];
        for (const std::string &c : table.all) {
            NSMenuItem *item = [table.menu addItemWithTitle:ADIFString(c) action:nil keyEquivalent:@""];
            item.state = hidden.count(c) ? NSControlStateValueOff : NSControlStateValueOn;
            ADIFBlockMenuItem(item, ^{
                std::set<std::string> hid = tableHidden();
                if (hid.count(c)) hid.erase(c);
                else if (hid.size() + 1 < table.all.size()) hid.insert(c);  // keep at least one column
                std::string list;
                for (const std::string &x : hid) list += (list.empty() ? "" : ",") + x;
                setSetting("tableHidden", list);
                tableRefresh();
            });
        }
        std::vector<std::vector<std::string>> rows;
        table.starts.clear();
        rows.reserve(table.recs.size());
        for (const adif::Record &rec : table.recs) {
            std::vector<std::string> row{std::to_string(rec.number)};
            for (const std::string &c : table.columns) {
                const std::string &v = rec.get(c);
                row.push_back(isDateField(c) ? adif::displayDate(v) : isTimeField(c) ? adif::displayTime(v) : v);
            }
            rows.push_back(std::move(row));
            table.starts.push_back(adif::groupStart(r.model, r.model.groups[(size_t)rec.group]));
        }
        // Keys keep the selection on the same record when others are added, removed or reordered.
        [table.w setRows:rows severities:kNoSev keys:adif::recordKeys(table.recs) ticks:kNoTicks keepTicks:NO];
        if (!hasRecords(r))
            [table.w setStatus:@"No records. Open an ADIF log (.adi), or add one with New QSO." severity:-1];
        else if (r.structuralErrors)
            [table.w setStatus:@"The log has structural errors, so some records may be shown wrongly. Fix Lengths may help."
                      severity:1];
        else
            [table.w setStatus:@"Click a row to show it in the editor; double-click # to go there, or a value to edit it. "
                               @"Click a heading to sort; right-click the headings to choose columns."
                      severity:-1];
        tableUpdateCount();
    } catch (...) {
    }
}

// A value edited in the Log Table: written with its length (an empty value removes the field), as
// one undo step; an uploaded QSO becomes M (modified since upload).
void tableEdit(NSInteger row, size_t column, NSString *text) {
    try {
        if (row < 0 || (size_t)row >= table.recs.size() || column == 0 || column > table.columns.size()) return;
        NppHandle h = scintilla();
        if (table.buffer != buffer() || readOnly(h)) {
            [table.w setStatus:@"Switch back to the log the table shows (and make sure it isn't read-only)." severity:2];
            tableRefresh();
            return;
        }
        std::string field = table.columns[column - 1], value = ADIFStd(text);
        while (!value.empty() && value.back() == ' ') value.pop_back();
        while (!value.empty() && value.front() == ' ') value.erase(0, 1);
        if (isDateField(field) || isTimeField(field)) {  // shown as 2026-10-06 and 22:30
            std::string v;
            for (char c : value)
                if (c != '-' && c != ':' && c != '/') v.push_back(c);
            value = v;
        }
        adif::LintResult r = lint(h);  // a copy: the edit changes the document
        std::string_view doc = adifhost::text(h);
        // Find the record again by its key: the log may have changed since the table was drawn.
        std::vector<adif::Record> recs = adif::records(doc, r.model);
        std::vector<std::string> keys = adif::recordKeys(recs), shownKeys = adif::recordKeys(table.recs);
        int group = -1;
        for (size_t i = 0; i < keys.size(); ++i)
            if (keys[i] == shownKeys[(size_t)row]) group = recs[i].group;
        if (group < 0 || r.structuralErrors) {
            [table.w setStatus:@"That record changed or the log has structural problems; nothing was edited." severity:2];
            tableRefresh();
            return;
        }
        const adif::ModelGroup &g = r.model.groups[(size_t)group];
        std::vector<adif::TextEdit> edits;
        int found = -1;
        for (size_t i = 0; i < g.fieldCount; ++i)
            if (adif::equalsNoCase(adif::fieldName(doc, r.model.fields[g.firstField + i]), field)) {
                found = (int)i;
                break;
            }
        if (value.empty() && found >= 0) edits.push_back(adif::removeField(doc, r.model, g, (size_t)found));
        else if (!value.empty() && found >= 0)
            edits.push_back(adif::setFieldValue(doc, r.model.fields[g.firstField + (size_t)found], value, lengthUnit(), utf8(h)));
        else if (!value.empty()) edits.push_back(adif::insertField(doc, r.model, g, field, value, lengthUnit(), utf8(h)));
        if (edits.empty()) return;
        if (!adif::isTrackingField(field))
            edits = adif::mergeEdits(edits, adif::markModified(doc, r.model, {group}, lengthUnit(), utf8(h)));
        int number = table.recs[(size_t)row].number;
        adifhost::apply(h, edits);
        [table.w setStatus:ADIFString("Record " + std::to_string(number) + ": " + field +
                                      (value.empty() ? " removed" : " set to " + value) + " (one undo step).")
                  severity:-1];
    } catch (...) {
    }
}

// Groups (DocModel indices) of the rows selected in the Log Table, when it shows the active log.
bool tableSelection(std::vector<int> *groups) {
    if (!tableVisible() || table.buffer != buffer()) return false;
    for (NSInteger row : [table.w selectedRows])
        if ((size_t)row < table.recs.size()) groups->push_back(table.recs[(size_t)row].group);
    return !groups->empty();
}

void exportCsv(const std::vector<adif::Record> &recs, const std::vector<std::string> &columns, ADIFToolWindow *w) {
    try {
        NppHandle h = scintilla();
        std::string name = documentName();
        std::string dest = chooseSave(ADIFString(stem(path().empty() ? std::string("log") : name) + ".csv"), @[ @"csv" ]);
        if (dest.empty()) return;
        std::string error;
        if (!writeFile(dest, adif::toCsv(recs, columns), &error)) {
            if (w) [w setStatus:ADIFString("Could not save: " + error) severity:2];
            else showTip(h, "ADIF Lint: could not save the CSV file: " + error);
            return;
        }
        std::string done = "Saved " + plural(recs.size(), "record") + " to " + fileName(dest) + ".";
        if (w) [w setStatus:ADIFString(done) severity:-1];
        else showTip(h, "ADIF Lint: " + done);
    } catch (...) {
    }
}

void openBulkEdit(bool shift, bool fromTable);

// ── Summary ─────────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
} summary;

void summaryRefresh() {
    if (!summary.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        [summary.w setTarget:logLine()];
        [summary.w setText:ADIFString(adif::summaryReport(adifhost::text(h), r.model, documentName()))];
        [summary.w setStatus:r.errors ? ADIFString("The log has " + plural(r.errors, "error") +
                                                    "; records with problems may be counted wrongly.")
                                      : @""
                    severity:r.errors ? 1 : -1];
    } catch (...) {
    }
}

// ── Activation Tracker ──────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *program = nil;
    std::vector<adif::Activation> acts;
    std::vector<size_t> starts;
} tracker;

adif::Program trackerProgram();

void trackerRefresh() {
    if (!tracker.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        [tracker.w setTarget:logLine()];
        adif::Program prog = trackerProgram();
        bool wwff = prog == adif::Program::WWFF, sota = prog == adif::Program::SOTA;
        tracker.acts = adif::programActivations(text, r.model, prog);
        tracker.starts.clear();
        std::string today = utcNow("%Y%m%d");
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        auto join = [](const std::map<std::string, size_t> &m) {
            std::vector<std::pair<std::string, size_t>> v(m.begin(), m.end());
            std::string s;
            for (const auto &kv : v) s += (s.empty() ? "" : " ") + kv.first + ":" + std::to_string(kv.second);
            return s;
        };
        for (const adif::Activation &a : tracker.acts) {
            std::string need = a.activated() ? "done" : std::to_string(a.needed - a.qsos) + " more";
            std::string when = adif::displayDate(a.date) + (a.lastDate != a.date ? " to " + adif::displayDate(a.lastDate) : "");
            rows.push_back({a.park, when, a.station, std::to_string(a.qsos), need, std::to_string(a.p2p),
                            std::to_string(a.duplicates), std::to_string(a.invalid), join(a.bands), join(a.modes),
                            adif::displayTime(a.first), adif::displayTime(a.last)});
            sev.push_back(a.activated() ? 3 : (a.date == today || a.lastDate == today) ? 1 : -1);
            const adif::ModelGroup &g = r.model.groups[(size_t)a.groups.front()];
            tracker.starts.push_back(adif::groupStart(r.model, g));
        }
        [tracker.w setRows:rows severities:sev];
        // Headline: today's activations, else the latest one.
        std::string head;
        int headSev = -1;
        std::vector<const adif::Activation *> focus;
        for (const adif::Activation &a : tracker.acts)
            if (a.date == today || a.lastDate == today) focus.push_back(&a);
        bool isToday = !focus.empty();
        if (!isToday && !tracker.acts.empty()) focus.push_back(&tracker.acts.back());
        bool allDone = true;
        for (const adif::Activation *a : focus) {
            std::string when = wwff ? "(all days)" : isToday ? "today" : "on " + adif::displayDate(a->date);
            std::string more = std::to_string(a->needed - a->qsos);
            std::string line = a->park + " " + when + ": " + plural(a->qsos, sota ? "station" : "QSO") +
                               (a->activated() ? (sota ? ", points scored" : ", activated")
                                               : ", " + more + (sota ? " more for the summit's points" : " more to activate"));
            head += (head.empty() ? "" : "\n") + line;
            allDone &= a->activated();
        }
        headSev = allDone ? 3 : 1;
        if (tracker.acts.empty()) {
            const char *name = adif::programName(prog);
            [tracker.w setHeadline:[NSString stringWithFormat:@"No %s activations in this log", name] severity:-1];
            [tracker.w setStatus:wwff   ? @"The tracker counts records with MY_WWFF_REF, or MY_SIG WWFF and MY_SIG_INFO."
                                 : sota ? @"The tracker counts records with MY_SOTA_REF, or MY_SIG SOTA and MY_SIG_INFO."
                                        : @"The tracker counts records with MY_SIG POTA and MY_SIG_INFO (or MY_POTA_REF) set to "
                                          @"your park. New QSO carries them from one contact to the next."
                        severity:-1];
            return;
        }
        [tracker.w setHeadline:ADIFString(head) severity:headSev];
        [tracker.w setStatus:wwff ? @"WWFF: 44 QSOs per reference, gathered over any number of days; the same call counts "
                                    @"again on another band, mode or date (WWFF Global Rules 5.10, 4.6-4.7). Double-click a "
                                    @"row to go to its first record."
                             : sota ? @"SOTA: one QSO activates a summit; four different stations score its points (from "
                                      @"SOTA guides: check sota.org.uk). The QSOs column counts stations. Double-click a "
                                      @"row to go to its first record."
                                    : @"An activation is 10 QSOs from one park in one UTC day. Each CALL counts once per "
                                      @"band, mode and park-to-park park; repeats and records missing CALL, TIME_ON, BAND or "
                                      @"MODE don't count (POTA rules, 2026-10-04). Double-click a row to go to its first record."
                    severity:-1];
    } catch (...) {
    }
}

void openPotaExport(adif::Program p);
adif::Program trackerProgram() {
    NSInteger i = tracker.program ? tracker.program.indexOfSelectedItem : 0;
    return i == 1 ? adif::Program::WWFF : i == 2 ? adif::Program::SOTA : adif::Program::POTA;
}

// ── Worked Before: the logs-folder index ────────────────────────────────────

struct IndexedLog {
    std::string path, name;
    long long mtime = 0, size = 0;
    std::vector<adif::Contact> contacts;
};

struct {
    std::string folder;  // indexed folder
    std::string buildingFolder;
    std::vector<std::shared_ptr<const IndexedLog>> logs;
    std::unordered_map<std::string, std::vector<std::pair<size_t, size_t>>> byBase;  // base call -> (log, contact)
    size_t qsos = 0, skipped = 0;
    bool building = false, again = false;
    double builtAt = 0;
    std::string error;
    void (^listener)(void) = nil;
} idx;

std::string logsFolder() { return setting("logsFolder"); }

const size_t kMaxLogBytes = 64u << 20;
const size_t kMaxLogFiles = 5000;

void indexRebuild();

void indexFinished(std::string folder, std::vector<std::shared_ptr<const IndexedLog>> logs, size_t skipped, std::string error) {
    idx.building = false;
    if (folder == logsFolder()) {
        idx.folder = folder;
        idx.logs = std::move(logs);
        idx.skipped = skipped;
        idx.error = error;
        idx.byBase.clear();
        idx.qsos = 0;
        for (size_t i = 0; i < idx.logs.size(); ++i)
            for (size_t k = 0; k < idx.logs[i]->contacts.size(); ++k) {
                idx.byBase[idx.logs[i]->contacts[k].baseCall].emplace_back(i, k);
                ++idx.qsos;
            }
        idx.builtAt = [NSDate date].timeIntervalSince1970;
    }
    if (idx.again || folder != logsFolder()) {
        idx.again = false;
        indexRebuild();
        return;
    }
    if (idx.listener) idx.listener();
}

// Re-read changed .adi/.adif files under the folder on a background queue.
void indexRebuild() {
    std::string folder = logsFolder();
    if (folder.empty()) return;
    if (idx.building) {
        idx.again |= folder != idx.buildingFolder;
        return;
    }
    idx.building = true;
    idx.buildingFolder = folder;
    std::map<std::string, std::shared_ptr<const IndexedLog>> previous;
    if (idx.folder == folder)
        for (const auto &l : idx.logs) previous[l->path] = l;
    adif::LengthUnit unit = lengthUnit();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::vector<std::shared_ptr<const IndexedLog>> logs;
        size_t skipped = 0;
        std::string error;
        @autoreleasepool {
            NSURL *root = [NSURL fileURLWithPath:ADIFString(folder) isDirectory:YES];
            NSDirectoryEnumerator *en = [NSFileManager.defaultManager
                           enumeratorAtURL:root
                includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                                   options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                              errorHandler:nil];
            if (!en) error = "cannot read the folder";
            for (NSURL *url in en) {
                NSString *ext = url.pathExtension.lowercaseString;
                if (![ext isEqualToString:@"adi"] && ![ext isEqualToString:@"adif"]) continue;
                if (logs.size() >= kMaxLogFiles) {
                    ++skipped;
                    continue;
                }
                std::string path = ADIFStd(url.path);
                struct stat st{};
                if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
                long long mtime = (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
                auto it = previous.find(path);
                if (it != previous.end() && it->second->mtime == mtime && it->second->size == st.st_size) {
                    logs.push_back(it->second);
                    continue;
                }
                std::string data;
                if (!readFile(path, kMaxLogBytes, &data, nullptr)) {
                    ++skipped;
                    continue;
                }
                adif::LintOptions opt;
                opt.lengthUnit = unit;
                opt.buildModel = true;
                opt.maxDiagnostics = 0;
                adif::LintResult r = adif::lint(data, opt);
                auto log = std::make_shared<IndexedLog>();
                log->path = path;
                log->name = fileName(path);
                log->mtime = mtime;
                log->size = st.st_size;
                log->contacts = adif::contacts(data, r.model);
                logs.push_back(log);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            indexFinished(folder, logs, skipped, error);
        });
    });
}

// Index hits for a call (by base call), outside the active file.
std::vector<adif::WorkedHit> indexLookup(const std::string &call) {
    std::vector<adif::WorkedHit> hits;
    std::string base = adif::lookupCall(call);
    if (base.empty()) return hits;
    auto it = idx.byBase.find(base);
    if (it == idx.byBase.end()) return hits;
    std::string active = path();
    for (const auto &p : it->second) {
        const IndexedLog &log = *idx.logs[p.first];
        if (log.path == active) continue;
        hits.push_back({log.name, log.contacts[p.second]});
    }
    return hits;
}

std::string indexStatus() {
    std::string folder = logsFolder();
    if (folder.empty()) return "Choose the folder that holds your logs. Its .adi and .adif files (and those in its subfolders) are searched.";
    if (idx.building && idx.folder != folder) return "Reading the logs in " + ADIFStd(tilde(folder)) + "...";
    if (!idx.error.empty()) return "Could not read " + ADIFStd(tilde(folder)) + ": " + idx.error + ".";
    std::string s = "Searched " + plural(idx.qsos, "QSO") + " in " + plural(idx.logs.size(), "log") + " under " +
                    ADIFStd(tilde(folder)) + ".";
    if (idx.skipped) s += " Skipped " + plural(idx.skipped, "file") + " (unreadable, over 64 MB, or past 5000 files).";
    if (idx.building) s += " Updating...";
    return s;
}

struct {
    ADIFToolWindow *w = nil;
    NSTextField *folder = nil;
    NSSearchField *call = nil;
    std::vector<adif::WorkedHit> hits;
} worked;

void workedRefresh() {
    if (!worked.w) return;
    worked.folder.stringValue = logsFolder().empty() ? @"(none)" : tilde(logsFolder());
    std::string call = ADIFStd(worked.call.stringValue);
    while (!call.empty() && call.back() == ' ') call.pop_back();
    worked.hits = call.empty() ? std::vector<adif::WorkedHit>() : indexLookup(call);
    std::sort(worked.hits.begin(), worked.hits.end(), [](const adif::WorkedHit &a, const adif::WorkedHit &b) {
        return a.contact.date + a.contact.time > b.contact.date + b.contact.time;
    });
    std::vector<std::vector<std::string>> rows;
    for (const adif::WorkedHit &hit : worked.hits)
        rows.push_back({hit.log, adif::displayDate(hit.contact.date), adif::displayTime(hit.contact.time), hit.contact.call,
                        hit.contact.band, hit.contact.mode, hit.contact.myPark, hit.contact.theirPark});
    [worked.w setRows:rows severities:kNoSev];
    std::string status = indexStatus();
    if (!call.empty() && !idx.building)
        status = (worked.hits.empty() ? adif::lookupCall(call) + ": not in the other logs."
                                      : adif::workedSummary(adif::lookupCall(call), worked.hits)) +
                 "\n" + status;
    [worked.w setStatus:ADIFString(status) severity:-1];
}

// ── Bulk Edit and Time Shift ────────────────────────────────────────────────

enum { kActSet, kActReplace, kActRemove, kActRename, kActShift, kActDistance };
enum { kScopeAll, kScopeSelection, kScopeTable };
enum { kShiftToUtc, kShiftFromUtc, kShiftFixed };

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *action = nil, *scope = nil, *filterKind = nil, *shiftMode = nil;
    NSComboBox *field = nil, *newName = nil, *filterField = nil, *zone = nil;
    NSTextField *zoneInfo = nil;
    NSStackView *rowShiftMode = nil, *rowZone = nil;
    NSTextField *value = nil, *find = nil, *replace = nil, *days = nil, *hours = nil, *minutes = nil, *filterValue = nil;
    NSButton *onlyMissing = nil, *useFilter = nil, *apply = nil, *preview = nil;
    NSStackView *rowField = nil, *rowSet = nil, *rowReplace = nil, *rowRename = nil, *rowShift = nil;
    size_t previewCount = 0;
    intptr_t buffer = 0;
} bulk;

void bulkClear(NSString *why) {
    if (!bulk.w) return;
    bool had = bulk.previewCount > 0;
    bulk.previewCount = 0;
    [bulk.w setRows:kNoRows severities:kNoSev];
    bulk.apply.enabled = NO;
    bulk.apply.title = @"Apply Changes";
    [bulk.w setDefaultButton:bulk.preview];
    if (why && had) [bulk.w setStatus:why severity:-1];
}

// A zone by IANA name ("America/Chicago"), else by abbreviation ("CST"); nil if unknown.
NSTimeZone *zoneNamed(NSString *text) {
    NSString *n = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!n.length) return nil;
    return [NSTimeZone timeZoneWithName:n] ?: [NSTimeZone timeZoneWithAbbreviation:n.uppercaseString];
}

// "UTC-5:00 now (CDT)" for the zone typed, or a hint.
void bulkZoneInfo() {
    NSTimeZone *z = zoneNamed(bulk.zone.stringValue);
    if (!z) {
        bulk.zoneInfo.stringValue = @"Unknown zone: type a name like America/Chicago";
        bulk.zoneInfo.textColor = NSColor.systemRedColor;
        return;
    }
    NSInteger off = z.secondsFromGMT;
    NSString *abbr = [z abbreviation] ?: @"";
    bulk.zoneInfo.stringValue = [NSString stringWithFormat:@"UTC%c%ld:%02ld now%@; each QSO uses the offset on its own date",
                                                           off < 0 ? '-' : '+', (long)labs(off) / 3600, (long)labs(off) % 3600 / 60,
                                                           abbr.length ? [NSString stringWithFormat:@" (%@)", abbr] : @""];
    bulk.zoneInfo.textColor = NSColor.secondaryLabelColor;
}

void bulkLayout() {
    NSInteger a = bulk.action.indexOfSelectedItem;
    bool fixed = bulk.shiftMode.indexOfSelectedItem == kShiftFixed;
    bulk.rowField.hidden = a == kActShift || a == kActDistance;
    bulk.rowSet.hidden = a != kActSet;
    bulk.rowReplace.hidden = a != kActReplace;
    bulk.rowRename.hidden = a != kActRename;
    bulk.rowShiftMode.hidden = a != kActShift;
    bulk.rowZone.hidden = a != kActShift || fixed;
    bulk.rowShift.hidden = a != kActShift || !fixed;
    bulkZoneInfo();
    bulk.filterValue.enabled = bulk.useFilter.state == NSControlStateValueOn &&
                               bulk.filterKind.indexOfSelectedItem <= 1;  // is / contains
    bulk.filterField.enabled = bulk.filterKind.enabled = bulk.useFilter.state == NSControlStateValueOn;
    bulk.w.window.title = a == kActShift ? @"Time Shift" : @"Bulk Edit";
}

// The plan for the window's settings against the document now.
bool bulkPlan(NppHandle h, const adif::LintResult &r, adif::ChangePlan *plan, std::string *error) {
    std::string_view text = adifhost::text(h);
    if (!hasRecords(r)) {
        *error = "This document has no ADIF records.";
        return false;
    }
    if (r.structuralErrors) {
        *error = "The log has structural problems. Run Fix Lengths and fix the errors marked in red first.";
        return false;
    }
    std::vector<int> groups;
    switch (bulk.scope.indexOfSelectedItem) {
        case kScopeSelection: groups = selectionRecords(h, r.model); break;
        case kScopeTable:
            if (!tableSelection(&groups)) {
                *error = "Select records in the Log Table first (it must show this log).";
                return false;
            }
            break;
        default: groups = allRecords(r.model); break;
    }
    if (bulk.useFilter.state == NSControlStateValueOn) {
        adif::RecordFilter f;
        static const adif::RecordFilter::Kind kinds[] = {adif::RecordFilter::Equals, adif::RecordFilter::Contains,
                                                         adif::RecordFilter::Missing, adif::RecordFilter::Present};
        f.kind = kinds[std::clamp<NSInteger>(bulk.filterKind.indexOfSelectedItem, 0, 3)];
        f.field = ADIFStd(bulk.filterField.stringValue);
        f.value = ADIFStd(bulk.filterValue.stringValue);
        if (f.field.empty()) {
            *error = "Choose the field for \"Only where\".";
            return false;
        }
        std::vector<adif::Record> recs = adif::records(text, r.model);
        std::map<int, const adif::Record *> byGroup;
        for (const adif::Record &rec : recs) byGroup[rec.group] = &rec;
        std::vector<int> kept;
        for (int gi : groups)
            if (byGroup.count(gi) && adif::matchesFilter(*byGroup[gi], f)) kept.push_back(gi);
        groups = kept;
    }
    if (groups.empty()) {
        *error = "No records match.";
        return false;
    }
    if (bulk.action.indexOfSelectedItem == kActDistance) {
        *plan = adif::planDistance(text, r.model, groups);
    } else if (bulk.action.indexOfSelectedItem == kActShift && bulk.shiftMode.indexOfSelectedItem == kShiftFixed) {
        if (!isInteger(bulk.days) || !isInteger(bulk.hours) || !isInteger(bulk.minutes)) {
            *error = "Days, hours and minutes must be whole numbers (negative moves earlier).";
            return false;
        }
        long long minutes = parseLong(bulk.days) * 1440LL + parseLong(bulk.hours) * 60LL + parseLong(bulk.minutes);
        *plan = adif::planTimeShift(text, r.model, groups, minutes);
    } else if (bulk.action.indexOfSelectedItem == kActShift) {
        // Between UTC and a time zone, with that zone's offset (daylight saving included) on each QSO's date.
        NSTimeZone *tz = zoneNamed(bulk.zone.stringValue);
        if (!tz) {
            *error = "Unknown time zone. Type a name such as America/Chicago or Europe/London.";
            return false;
        }
        setSetting("timeShiftZone", ADIFStd(tz.name));
        std::string zname = ADIFStd(tz.name);
        auto offsetAt = [tz](long long utc) -> long long {
            return [tz secondsFromGMTForDate:[NSDate dateWithTimeIntervalSince1970:(double)utc]];
        };
        auto when = [](long long t) {
            long long days = t >= 0 ? t / 86400 : (t - 86399) / 86400;
            return adif::displayDate(adif::formatAdifDate((long)days)) + " " +
                   adif::displayTime(adif::formatAdifTime((int)(t - days * 86400), false));
        };
        adif::ShiftFor shiftFor;
        if (bulk.shiftMode.indexOfSelectedItem == kShiftToUtc) {
            shiftFor = [=](long long start, long long *sec, std::string *why) {
                long long utc = 0;
                adif::LocalTime k = adif::localToUtc(start, offsetAt, &utc);
                if (k == adif::LocalTime::Unique) {
                    *sec = utc - start;
                    return true;
                }
                *why = when(start) + (k == adif::LocalTime::Skipped
                                          ? " didn't happen in " + zname + " (the clocks went forward)"
                                          : " happened twice in " + zname + " (the clocks went back); shift it by a fixed amount");
                return false;
            };
        } else {
            shiftFor = [=](long long start, long long *sec, std::string *) {
                *sec = offsetAt(start);
                return true;
            };
        }
        *plan = adif::planTimeShiftWith(text, r.model, groups, shiftFor);
    } else {
        adif::BulkEdit op;
        static const adif::BulkAction actions[] = {adif::BulkAction::Set, adif::BulkAction::Replace, adif::BulkAction::Remove,
                                                   adif::BulkAction::Rename};
        op.action = actions[std::clamp<NSInteger>(bulk.action.indexOfSelectedItem, 0, 3)];
        op.field = ADIFStd(bulk.field.stringValue);
        if (op.action == adif::BulkAction::Replace) {
            op.find = ADIFStd(bulk.find.stringValue);
            op.value = ADIFStd(bulk.replace.stringValue);
        } else {
            op.value = ADIFStd(bulk.value.stringValue);
        }
        op.newName = ADIFStd(bulk.newName.stringValue);
        op.onlyMissing = bulk.onlyMissing.state == NSControlStateValueOn;
        *plan = adif::planBulkEdit(text, r.model, groups, op);
    }
    if (plan->changes.empty()) {
        *error = plan->skipReason.empty() || plan->skipped == 0
                     ? (plan->skipReason.empty() ? "Nothing to change in " + plural(groups.size(), "record") + "."
                                                 : plan->skipReason)
                     : "Nothing to change: " + plural(plan->skipped, "record") + " skipped because " + plan->skipReason + ".";
        return false;
    }
    return true;
}

void bulkPreview() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        adif::ChangePlan plan;
        std::string error;
        bulkClear(nil);
        bulk.buffer = buffer();
        [bulk.w setTarget:logLine()];
        if (!bulkPlan(h, r, &plan, &error)) {
            [bulk.w setStatus:ADIFString(error) severity:2];
            return;
        }
        std::vector<std::vector<std::string>> rows;
        for (const adif::PlannedChange &c : plan.changes) {
            std::string now, next, field = c.field;
            switch (c.kind) {
                case adif::PlannedChange::Add: now = "(none)", next = c.after; break;
                case adif::PlannedChange::Change: now = c.before, next = c.after; break;
                case adif::PlannedChange::Remove: now = c.before, next = "(removed)"; break;
                case adif::PlannedChange::Rename: field = c.before, now = c.before, next = c.after; break;
            }
            rows.push_back({std::to_string(c.record), c.call, field, now, next});
        }
        [bulk.w setRows:rows severities:kNoSev];
        bulk.previewCount = plan.changes.size();
        // What the validator would say afterwards.
        std::string_view text = adifhost::text(h);
        std::string after = adif::applyTextEdits(text, adif::planEdits(text, r.model, plan.changes, lengthUnit(), utf8(h)));
        adif::LintOptions opt;
        opt.lengthUnit = lengthUnit();
        opt.utf8 = utf8(h);
        adif::LintResult ra = adif::lint(after, opt);
        std::string status = plural(plan.changes.size(), "change") + " in " + plural(plan.records, "record") + ".";
        if (plan.skipped) status += " " + plural(plan.skipped, "record") + " skipped: " + plan.skipReason + ".";
        int sev = -1;
        if (ra.errors > r.errors || ra.warnings > r.warnings) {
            status += " Afterwards the log would have " + plural(ra.errors, "error") + " and " + plural(ra.warnings, "warning") +
                      " (now " + std::to_string(r.errors) + " and " + std::to_string(r.warnings) + "): check the values.";
            sev = 1;
        } else {
            status += " No new problems. Untick any you don't want, then Apply.";
        }
        [bulk.w setStatus:ADIFString(status) severity:sev];
        bulk.apply.enabled = YES;
        bulk.apply.title = [NSString stringWithFormat:@"Apply %zu Change%@", plan.changes.size(), plan.changes.size() == 1 ? @"" : @"s"];
        [bulk.w setDefaultButton:bulk.apply];
    } catch (...) {
        [bulk.w setStatus:@"Something went wrong preparing the changes." severity:2];
    }
}

void bulkApply() {
    try {
        if (!bulk.previewCount) return;
        NppHandle h = scintilla();
        if (bulk.buffer != buffer()) {
            [bulk.w setStatus:@"Switch back to the log you previewed, then Apply." severity:2];
            return;
        }
        if (readOnly(h)) {
            [bulk.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);  // a copy: the edit below changes the document
        adif::ChangePlan plan;
        std::string error;
        if (!bulkPlan(h, r, &plan, &error) || plan.changes.size() != bulk.previewCount) {
            bulkClear(nil);
            [bulk.w setStatus:@"The log changed since the preview. Preview again." severity:1];
            return;
        }
        std::vector<bool> ticked = [bulk.w ticked];
        std::vector<adif::PlannedChange> chosen;
        std::set<int> records;
        for (size_t i = 0; i < plan.changes.size(); ++i)
            if (i < ticked.size() && ticked[i]) {
                chosen.push_back(plan.changes[i]);
                records.insert(plan.changes[i].group);
            }
        if (chosen.empty()) {
            [bulk.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        std::string_view text = adifhost::text(h);
        std::vector<adif::TextEdit> edits = adif::planEdits(text, r.model, chosen, lengthUnit(), utf8(h));
        // A changed QSO that was already uploaded must be sent again: its status Y becomes M.
        std::vector<int> changedData;
        for (const adif::PlannedChange &c : chosen) {
            bool data = c.kind == adif::PlannedChange::Rename ? !adif::isTrackingField(c.before) || !adif::isTrackingField(c.after)
                                                              : !adif::isTrackingField(c.field);
            if (data) changedData.push_back(c.group);
        }
        edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
        bulkClear(nil);
        adifhost::apply(h, edits);
        [bulk.w setStatus:ADIFString("Applied " + plural(chosen.size(), "change") + " to " + plural(records.size(), "record") +
                                     " (one undo step).")
                 severity:-1];
    } catch (...) {
        [bulk.w setStatus:@"Something went wrong applying the changes." severity:2];
    }
}

void openBulkEdit(bool shift, bool fromTable) {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        if (!bulk.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Bulk Edit" size:NSMakeSize(760, 620) headline:NO];
            bulk.w = w;
            bulk.action = ADIFPopup(@[ @"Set a field", @"Replace text in a field", @"Remove a field", @"Rename a field",
                                       @"Shift date and time", @"Fill DISTANCE from grid squares" ]);
            [w addOptionRow:@[ ADIFLabel(@"Action:"), bulk.action ]];
            bulk.field = ADIFComboBox(@[], 200);
            bulk.field.placeholderString = @"e.g. MY_GRIDSQUARE";
            bulk.rowField = [w addOptionRow:@[ ADIFLabel(@"Field:"), bulk.field ]];
            bulk.value = ADIFTextField(@"new value", 220);
            bulk.onlyMissing = ADIFCheckbox(@"Only where it is missing or empty", NO);
            bulk.rowSet = [w addOptionRow:@[ ADIFLabel(@"Value:"), bulk.value, bulk.onlyMissing ]];
            bulk.find = ADIFTextField(@"text to find", 160);
            bulk.replace = ADIFTextField(@"replacement", 160);
            bulk.rowReplace = [w addOptionRow:@[ ADIFLabel(@"Find:"), bulk.find, ADIFLabel(@"Replace with:"), bulk.replace,
                                                  ADIFLabel(@"(any case)") ]];
            bulk.newName = ADIFComboBox(@[], 200);
            bulk.rowRename = [w addOptionRow:@[ ADIFLabel(@"New name:"), bulk.newName ]];
            bulk.shiftMode = ADIFPopup(@[ @"From local time to UTC", @"From UTC to local time", @"By a fixed amount" ]);
            bulk.shiftMode.toolTip = @"ADIF times are UTC. Use local time to UTC for a log written in local time; UTC to local "
                                     @"time undoes that.";
            bulk.rowShiftMode = [w addOptionRow:@[ ADIFLabel(@"Convert:"), bulk.shiftMode ]];
            NSMutableArray *zones = [NSTimeZone.knownTimeZoneNames mutableCopy];
            [zones sortUsingSelector:@selector(compare:)];
            bulk.zone = ADIFComboBox(zones, 200);
            bulk.zone.placeholderString = @"e.g. America/Chicago";
            bulk.zoneInfo = ADIFLabel(@"");
            bulk.zoneInfo.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            bulk.zoneInfo.lineBreakMode = NSLineBreakByTruncatingTail;
            [bulk.zoneInfo setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
            bulk.rowZone = [w addOptionRow:@[ ADIFLabel(@"Time zone:"), bulk.zone, bulk.zoneInfo ]];
            bulk.days = ADIFTextField(@"0", 50);
            bulk.hours = ADIFTextField(@"0", 50);
            bulk.minutes = ADIFTextField(@"0", 50);
            bulk.rowShift = [w addOptionRow:@[ ADIFLabel(@"Shift by:"), bulk.days, ADIFLabel(@"days"), bulk.hours,
                                                ADIFLabel(@"hours"), bulk.minutes, ADIFLabel(@"minutes (negative: earlier)") ]];
            bulk.rowShift.toolTip = @"Moves QSO_DATE and TIME_ON, and QSO_DATE_OFF and TIME_OFF, across midnight as needed. "
                                    @"Times keep their HHMM or HHMMSS form.";
            bulk.scope = ADIFPopup(@[ @"All records", @"Records in the editor selection", @"Records selected in the Log Table" ]);
            [w addOptionRow:@[ ADIFLabel(@"Records:"), bulk.scope ]];
            bulk.useFilter = ADIFCheckbox(@"Only where", NO);
            bulk.filterField = ADIFComboBox(@[], 150);
            bulk.filterKind = ADIFPopup(@[ @"is", @"contains", @"is missing", @"is present" ]);
            bulk.filterValue = ADIFTextField(@"value", 140);
            [w addOptionRow:@[ bulk.useFilter, bulk.filterField, bulk.filterKind, bulk.filterValue ]];
            [w setColumns:std::vector<ADIFToolColumn>{{"record", "Record", 56}, {"call", "Call", 90}, {"field", "Field", 130}, {"now", "Now", 150},
                           {"new", "New", 200}}
                checkboxes:YES
                  sortable:NO];
            bulk.preview = [w addButton:@"Preview" trailing:NO action:^{ bulkPreview(); }];
            [w addButton:@"Tick All" trailing:NO action:^{ [bulk.w setAllTicked:YES]; }];
            [w addButton:@"Untick All" trailing:NO action:^{ [bulk.w setAllTicked:NO]; }];
            bulk.apply = [w addButton:@"Apply Changes" trailing:YES action:^{ bulkApply(); }];
            for (NSControl *c in @[ bulk.action, bulk.scope, bulk.filterKind, bulk.onlyMissing, bulk.useFilter, bulk.shiftMode, bulk.zone ])
                ADIFOnAction(c, ^{
                    bulkLayout();
                    bulkClear(@"Settings changed. Preview again.");
                });
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == bulk.w.window) {
                                                                  if (v == bulk.zone) dispatch_async(dispatch_get_main_queue(), ^{ bulkZoneInfo(); });
                                                                  bulkClear(@"Settings changed. Preview again.");
                                                              }
                                                          }];
            [[NSNotificationCenter defaultCenter] addObserverForName:NSComboBoxSelectionDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == bulk.w.window) {
                                                                  if (v == bulk.zone) dispatch_async(dispatch_get_main_queue(), ^{ bulkZoneInfo(); });
                                                                  bulkClear(@"Settings changed. Preview again.");
                                                              }
                                                          }];
        }
        NSArray<NSString *> *names = nsList(fieldChoices(adifhost::text(h), r.model));
        for (NSComboBox *c in @[ bulk.field, bulk.newName, bulk.filterField ]) {
            [c removeAllItems];
            [c addItemsWithObjectValues:names];
        }
        if (!bulk.zone.stringValue.length) {
            std::string saved = setting("timeShiftZone");
            bulk.zone.stringValue = saved.empty() ? NSTimeZone.localTimeZone.name : ADIFString(saved);
        }
        if (shift) [bulk.action selectItemAtIndex:kActShift];
        else if (bulk.action.indexOfSelectedItem == kActShift) [bulk.action selectItemAtIndex:kActSet];
        if (fromTable) [bulk.scope selectItemAtIndex:kScopeTable];
        bulkLayout();
        bulkClear(nil);
        bulk.buffer = buffer();
        [bulk.w setTarget:logLine()];
        [bulk.w setStatus:shift ? @"ADIF dates and times are UTC. Convert a log written in local time to UTC (or back), "
                                  @"with daylight saving taken from each QSO's date, or move times by a fixed amount. "
                                  @"Preview shows each change before anything is written."
                                : @"Preview shows each change before anything is written. Apply is one undo step."
                 severity:-1];
        [bulk.w show];
    } catch (...) {
    }
}

// ── Remove Duplicates ───────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSTextField *window = nil;
    NSButton *fill = nil, *remove = nil, *find = nil;
    size_t found = 0;
    intptr_t buffer = 0;
} dupes;

adif::DupeOptions dupeOptions(NSTextField *f) {
    adif::DupeOptions o;
    long v = parseLong(f);
    o.windowMinutes = (int)std::clamp<long>(v, 0, 1440);
    return o;
}

void dupesClear(NSString *why) {
    if (!dupes.w) return;
    bool had = dupes.found > 0;
    dupes.found = 0;
    [dupes.w setRows:kNoRows severities:kNoSev];
    dupes.remove.enabled = NO;
    dupes.remove.title = @"Remove Duplicates";
    [dupes.w setDefaultButton:dupes.find];
    if (why && had) [dupes.w setStatus:why severity:-1];
}

void dupesFind() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        dupesClear(nil);
        dupes.buffer = buffer();
        [dupes.w setTarget:logLine()];
        std::string problem = structureProblem(r);
        if (!hasRecords(r) || !problem.empty()) {
            [dupes.w setStatus:ADIFString(hasRecords(r) ? problem : "This document has no ADIF records.") severity:2];
            return;
        }
        std::vector<adif::DupeSet> sets = adif::findDuplicates(text, r.model, dupeOptions(dupes.window));
        std::vector<adif::Record> recs = adif::records(text, r.model);
        std::map<int, const adif::Record *> byGroup;
        for (const adif::Record &rec : recs) byGroup[rec.group] = &rec;
        std::vector<std::vector<std::string>> rows;
        size_t records = 0;
        for (const adif::DupeSet &d : sets) {
            const adif::Record &k = *byGroup[d.keep];
            std::string removed, adds;
            for (int gi : d.remove) removed += (removed.empty() ? "" : ", ") + std::to_string(byGroup[gi]->number);
            for (const auto &f : d.fill) adds += (adds.empty() ? "" : ", ") + f.first;
            rows.push_back({std::to_string(k.number), removed, k.get("CALL"), adif::displayDate(k.get("QSO_DATE")),
                            adif::displayTime(k.get("TIME_ON")), adif::effectiveBand(k), adif::effectiveMode(k), adds});
            records += d.remove.size();
        }
        [dupes.w setRows:rows severities:kNoSev];
        dupes.found = sets.size();
        if (sets.empty()) {
            [dupes.w setStatus:@"No duplicates found. Lines repeated for each park of a park-to-park contact (different "
                               @"SIG_INFO), or with a different STATION_CALLSIGN or MY_SIG_INFO, are not duplicates."
                      severity:-1];
            return;
        }
        dupes.remove.enabled = YES;
        dupes.remove.title = [NSString stringWithFormat:@"Remove %zu Record%@", records, records == 1 ? @"" : @"s"];
        [dupes.w setDefaultButton:dupes.remove];
        [dupes.w setStatus:ADIFString(plural(sets.size(), "QSO") + " logged more than once: " + plural(records, "record") +
                                      " to remove. Each keeps the record with the most fields. Untick any to leave alone.")
                  severity:1];
    } catch (...) {
        [dupes.w setStatus:@"Something went wrong looking for duplicates." severity:2];
    }
}

void dupesRemove() {
    try {
        if (!dupes.found) return;
        NppHandle h = scintilla();
        if (dupes.buffer != buffer()) {
            [dupes.w setStatus:@"Switch back to the log you checked, then try again." severity:2];
            return;
        }
        if (readOnly(h)) {
            [dupes.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        std::vector<adif::DupeSet> sets = adif::findDuplicates(text, r.model, dupeOptions(dupes.window));
        if (sets.size() != dupes.found || !structureProblem(r).empty()) {
            dupesClear(nil);
            [dupes.w setStatus:@"The log changed. Find Duplicates again." severity:1];
            return;
        }
        std::vector<bool> ticked = [dupes.w ticked];
        std::vector<adif::DupeSet> chosen;
        size_t removed = 0;
        for (size_t i = 0; i < sets.size(); ++i)
            if (i < ticked.size() && ticked[i]) {
                chosen.push_back(sets[i]);
                removed += sets[i].remove.size();
            }
        if (chosen.empty()) {
            [dupes.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        bool fill = dupes.fill.state == NSControlStateValueOn;
        std::vector<adif::TextEdit> edits = adif::duplicateEdits(text, r.model, chosen, fill, lengthUnit(), utf8(h));
        if (fill) {  // a kept record that gains fields has changed since any upload
            std::vector<int> changedData;
            for (const adif::DupeSet &d : chosen)
                for (const auto &f : d.fill)
                    if (!adif::isTrackingField(f.first)) changedData.push_back(d.keep);
            edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
        }
        dupesClear(nil);
        adifhost::apply(h, edits);
        [dupes.w setStatus:ADIFString("Removed " + plural(removed, "duplicate record") + " (one undo step).") severity:-1];
    } catch (...) {
        [dupes.w setStatus:@"Something went wrong removing the duplicates." severity:2];
    }
}

// ── Merge Another Log ───────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSTextField *from = nil;
    NSButton *skip = nil, *sort = nil, *add = nil;
    std::string path, text;
    adif::LintResult source;
    adif::MergePlan plan;
    bool ready = false;
    intptr_t buffer = 0;
} merge;

void mergePlanNow() {
    merge.ready = false;
    merge.add.enabled = NO;
    merge.add.title = @"Add QSOs";
    [merge.w setRows:kNoRows severities:kNoSev];
    [merge.w setTarget:logLine()];
    merge.from.stringValue = merge.path.empty() ? @"(choose a log)" : tilde(merge.path);
    if (merge.path.empty()) {
        [merge.w setStatus:@"Choose the log to add from. Its records are added at the end of this one, in this log's "
                           @"layout, with lengths counted the way this log counts them."
                  severity:-1];
        return;
    }
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        merge.buffer = buffer();
        std::string error;
        if (!readFile(merge.path, kMaxLogBytes, &merge.text, &error)) {
            [merge.w setStatus:ADIFString("Could not read it: " + error + ".") severity:2];
            return;
        }
        if (merge.path == path()) {
            [merge.w setStatus:@"That is this log. Choose another one." severity:2];
            return;
        }
        merge.source = lintText(merge.text);
        if (!hasRecords(merge.source)) {
            [merge.w setStatus:@"That file has no ADIF records." severity:2];
            return;
        }
        if (!adif::canReformat(merge.source)) {
            [merge.w setStatus:@"That log has structural problems (wrong lengths or broken tags). Open it, run Fix Lengths, "
                               @"save it, then choose it again."
                      severity:2];
            return;
        }
        bool skip = merge.skip.state == NSControlStateValueOn;
        merge.plan = adif::planMerge(adifhost::text(h), r.model, merge.text, merge.source.model, adif::DupeOptions(), skip);
        std::map<int, int> dupOf;
        for (const auto &d : merge.plan.duplicates) dupOf[d.first] = d.second;
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        for (const adif::Record &rec : adif::records(merge.text, merge.source.model)) {
            if (rec.fields.empty()) continue;
            std::string what = "add";
            int s = -1;
            auto it = dupOf.find(rec.group);
            if (it != dupOf.end()) {
                what = it->second >= 0 ? "already here (record " + std::to_string(adif::recordNumber(r.model, it->second)) + ")"
                                       : "repeated in that log";
                s = 1;
            }
            rows.push_back({std::to_string(rec.number), rec.get("CALL"), adif::displayDate(rec.get("QSO_DATE")),
                            adif::displayTime(rec.get("TIME_ON")), adif::effectiveBand(rec), adif::effectiveMode(rec), what});
            sev.push_back(s);
        }
        [merge.w setRows:rows severities:sev];
        std::string status = plural(merge.plan.add.size(), "QSO") + " to add";
        if (!merge.plan.duplicates.empty()) status += ", " + std::to_string(merge.plan.duplicates.size()) + " skipped as duplicates";
        status += ".";
        int s = -1;
        if (!merge.plan.undefinedFields.empty()) {
            std::string list;
            for (const std::string &f : merge.plan.undefinedFields) list += (list.empty() ? "" : ", ") + f;
            status += " That log defines user fields this one doesn't (" + list + "): add their USERDEF lines to this "
                      "log's header, or the validator will flag them.";
            s = 1;
        }
        std::string problem = structureProblem(r);
        if (!problem.empty() && hasRecords(r)) {
            status = "This log: " + problem;
            s = 2;
        } else if (!merge.plan.add.empty()) {
            merge.ready = true;
            merge.add.enabled = YES;
            merge.add.title = [NSString stringWithFormat:@"Add %zu QSO%@", merge.plan.add.size(), merge.plan.add.size() == 1 ? @"" : @"s"];
            [merge.w setDefaultButton:merge.add];
        }
        [merge.w setStatus:ADIFString(status) severity:s];
    } catch (...) {
        [merge.w setStatus:@"Something went wrong reading that log." severity:2];
    }
}

void mergeApply() {
    try {
        if (!merge.ready) return;
        NppHandle h = scintilla();
        if (merge.buffer != buffer()) {
            [merge.w setStatus:@"Switch back to the log you were merging into." severity:2];
            return;
        }
        if (readOnly(h)) {
            [merge.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        std::string eolText = eol(h);
        std::string records = adif::mergedRecords(merge.text, merge.source.model, merge.plan.add,
                                                  adif::recordLayout(text, r.model), eolText, lengthUnit(), utf8(h));
        size_t start = 0;
        std::string merged;
        bool blank = text.find_first_not_of(" \t\r\n") == std::string_view::npos;
        if (blank) merged = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records;
        else merged = adif::applyTextEdits(text, {adif::appendRecord(text, r.model, records, eolText, &start)});
        std::string note;
        if (merge.sort.state == NSControlStateValueOn) {
            adif::LintResult rm = lintText(merged);
            if (structureProblem(rm).empty()) {
                bool changed = false;
                merged = adif::sortedByTime(merged, rm.model, eolText, &changed);
                if (changed) note = " and sorted by date and time";
            }
        }
        size_t added = merge.plan.add.size();
        adifhost::apply(h, {adif::TextEdit{0, text.size(), merged}});
        merge.ready = false;
        merge.add.enabled = NO;
        [merge.w setRows:kNoRows severities:kNoSev];
        [merge.w setStatus:ADIFString("Added " + plural(added, "QSO") + " from " + fileName(merge.path) + note +
                                      " (one undo step).")
                  severity:-1];
    } catch (...) {
        [merge.w setStatus:@"Something went wrong merging." severity:2];
    }
}

// ── POTA export ─────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *program = nil;
    adif::Program shown = adif::Program::POTA;
    NSTextField *station = nil, *folder = nil;
    NSButton *save = nil;
    std::vector<adif::PotaFile> files;
    std::string confirmReplace;  // the file list a second Save press replaces
    intptr_t buffer = 0;
} pota;

void potaPlan() {
    if (!pota.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        pota.buffer = buffer();
        pota.confirmReplace.clear();
        [pota.w setTarget:logLine()];
        std::string dir = setting("potaFolder");
        pota.folder.stringValue = dir.empty() ? @"(choose a folder)" : tilde(dir);
        NSInteger pi = pota.program.indexOfSelectedItem;
        adif::Program prog = pi == 1 ? adif::Program::WWFF : pi == 2 ? adif::Program::SOTA : adif::Program::POTA;
        pota.shown = prog;
        pota.files = adif::programExport(prog, adifhost::text(h), r.model, ADIFStd(pota.station.stringValue), ADIFLINT_VERSION,
                                         utcNow("%Y%m%d %H%M%S"), "\n", adif::LengthUnit::Bytes, true, utcNow("%Y%m%d"));
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        bool noStation = false;
        for (const adif::PotaFile &f : pota.files) {
            std::string notes;
            for (const std::string &n : f.notes) notes += (notes.empty() ? "" : "; ") + n;
            rows.push_back({f.name, f.park, adif::displayDate(f.date), std::to_string(f.records), std::to_string(f.qsos), notes});
            size_t needed = prog == adif::Program::POTA ? 10 : prog == adif::Program::SOTA ? 4 : 0;
            sev.push_back(f.station.empty() ? 2 : f.qsos < needed ? 1 : -1);
            noStation |= f.station.empty();
        }
        [pota.w setRows:rows severities:sev];
        pota.save.enabled = !pota.files.empty();
        pota.save.title = [NSString stringWithFormat:@"Save %zu File%@", pota.files.size(), pota.files.size() == 1 ? @"" : @"s"];
        if (pota.files.empty()) {
            [pota.w setStatus:prog == adif::Program::WWFF   ? @"No WWFF activations in this log: records need MY_WWFF_REF, or MY_SIG WWFF and MY_SIG_INFO."
                              : prog == adif::Program::SOTA ? @"No SOTA activations in this log: records need MY_SOTA_REF, or MY_SIG SOTA and MY_SIG_INFO."
                                                            : @"No POTA activations in this log: records need MY_SIG POTA and MY_SIG_INFO, or MY_POTA_REF."
                      severity:2];
        } else if (r.structuralErrors) {
            [pota.w setStatus:@"The log has structural problems, so records may be read wrongly. Run Fix Lengths first."
                      severity:2];
        } else {
            std::string what = prog == adif::Program::WWFF
                                   ? "One file per reference and UTC day, named callsign@reference date as WWFF asks. "
                                   : prog == adif::Program::SOTA ? "One file per summit and UTC day. "
                                                                 : "One file per park and UTC day, named callsign@park-date as POTA asks. ";
            std::string where = prog == adif::Program::WWFF ? "Send them to your national WWFF log manager."
                                : prog == adif::Program::SOTA ? "Upload them at sotadata.org.uk."
                                                              : "Upload them at pota.app, My Log Uploads.";
            [pota.w setStatus:ADIFString(what +
                                         (noStation ? "Some records have no STATION_CALLSIGN or OPERATOR: enter your "
                                                      "callsign above. "
                                                    : "") +
                                         where)
                      severity:noStation ? 1 : -1];
        }
    } catch (...) {
    }
}

void potaSave() {
    try {
        if (pota.buffer != buffer()) {
            potaPlan();
            [pota.w setStatus:@"The log changed; check the list, then Save again." severity:1];
            return;
        }
        std::string dir = setting("potaFolder");
        if (dir.empty()) {
            dir = chooseOpen(@"Choose the folder for the activation logs", true);
            if (dir.empty()) return;
            setSetting("potaFolder", dir);
            pota.folder.stringValue = tilde(dir);
        }
        std::string station = ADIFStd(pota.station.stringValue);
        setSetting("potaStation", station);
        std::vector<bool> ticked = [pota.w ticked];
        std::vector<const adif::PotaFile *> chosen;
        for (size_t i = 0; i < pota.files.size(); ++i)
            if (i < ticked.size() && ticked[i]) chosen.push_back(&pota.files[i]);
        if (chosen.empty()) {
            [pota.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        for (const adif::PotaFile *f : chosen)
            if (f->station.empty()) {
                [pota.w setStatus:@"Enter your callsign for the records without STATION_CALLSIGN or OPERATOR." severity:2];
                return;
            }
        std::string existing;
        for (const adif::PotaFile *f : chosen) {
            struct stat st{};
            if (stat((dir + "/" + f->name).c_str(), &st) == 0) existing += (existing.empty() ? "" : ", ") + f->name;
        }
        if (!existing.empty() && existing != pota.confirmReplace) {
            pota.confirmReplace = existing;
            [pota.w setStatus:ADIFString("Already in the folder: " + existing + ". Press Save again to replace them.")
                      severity:1];
            return;
        }
        size_t saved = 0;
        for (const adif::PotaFile *f : chosen) {
            std::string error;
            if (!writeFile(dir + "/" + f->name, f->text, &error)) {
                [pota.w setStatus:ADIFString("Could not save " + f->name + ": " + error) severity:2];
                return;
            }
            ++saved;
        }
        pota.confirmReplace.clear();
        [pota.w setStatus:ADIFString("Saved " + plural(saved, "file") + " to " + ADIFStd(tilde(dir)) +
                                     (pota.shown == adif::Program::WWFF   ? ". Send them to your national WWFF log manager."
                                      : pota.shown == adif::Program::SOTA ? ". Upload them at sotadata.org.uk."
                                                                          : ". Upload them at pota.app, My Log Uploads."))
                  severity:3];
    } catch (...) {
        [pota.w setStatus:@"Something went wrong saving the files." severity:2];
    }
}

// The station callsign most of the log's records use.
std::string usualStation(std::string_view text, const adif::DocModel &m) {
    std::map<std::string, size_t> n;
    for (const adif::Record &r : adif::records(text, m)) {
        std::string s = adif::stationCall(r);
        if (!s.empty()) ++n[s];
    }
    std::string best;
    size_t most = 0;
    for (const auto &kv : n)
        if (kv.second > most) most = kv.second, best = kv.first;
    return best;
}

// ── Spots: POTA and WWFF (hunting) ──────────────────────────────────────────

// References worked in this log or the Worked Before folder (without @location), upper case.
std::set<std::string> workedReferences() {
    std::set<std::string> out;
    auto add = [&](const adif::Contact &c) {
        for (const std::string &r : c.theirRefs) out.insert(r.substr(0, r.find('@')));
    };
    try {
        NppHandle h = scintilla();
        for (const adif::Contact &c : adif::contacts(adifhost::text(h), lint(h).model)) add(c);
    } catch (...) {
    }
    for (const auto &log : idx.logs)
        for (const adif::Contact &c : log->contacts) add(c);
    return out;
}

struct Spot {
    std::string time, activator, khz, mode, reference, park, location, spotter, comments, band;
    std::string key;  // spotId, so a refresh keeps the selection on the same spot
};

struct {
    ADIFToolWindow *w = nil;
    NSSearchField *search = nil;
    NSPopUpButton *band = nil, *mode = nil, *program = nil;
    NSButton *use = nil;
    adif::Program shown = adif::Program::POTA;  // the program of `all`
    std::vector<Spot> all;
    std::vector<size_t> rowSpot;  // model row -> index into all
    NSTimer *timer = nil;
    bool loading = false;
    std::string fetched;  // UTC time of the last good fetch
    void (^handler)(const std::vector<std::pair<std::string, std::string>> &) = nil;
} spots;

std::string jsonString(NSDictionary *d, NSString *key, size_t limit = 120) {
    id v = d[key];
    NSString *s = [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil;
    std::string out = s ? ADIFStd(s) : std::string();
    std::string clean;
    for (char c : out)
        if (c >= 32 && c < 127) clean.push_back(c);  // printable ASCII only, as ADI needs
    if (clean.size() > limit) clean.resize(limit);
    return clean;
}

const char *const kSpotBands[] = {"160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "2m", "70cm"};

void spotsShow() {
    if (!spots.w) return;
    std::string band = spots.band.indexOfSelectedItem > 0 ? ADIFStd(spots.band.titleOfSelectedItem) : "";
    NSInteger modeIdx = spots.mode.indexOfSelectedItem;
    // What this log already has today (UTC): CALL on a band.
    std::set<std::string> today;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string date = utcNow("%Y%m%d");
        for (const adif::Record &rec : adif::records(adifhost::text(h), r.model))
            if (rec.get("QSO_DATE") == date) today.insert(adif::lookupCall(rec.get("CALL")) + "|" + adif::effectiveBand(rec));
    } catch (...) {
    }
    std::set<std::string> refs = workedReferences();
    std::vector<std::vector<std::string>> rows;
    std::vector<int> sev;
    std::vector<std::string> keys;
    spots.rowSpot.clear();
    for (size_t i = 0; i < spots.all.size(); ++i) {
        const Spot &sp = spots.all[i];
        if (!band.empty() && sp.band != band) continue;
        std::string m = sp.mode;
        bool other = m != "SSB" && m != "CW" && m != "FT8" && m != "FT4";
        if ((modeIdx == 1 && m != "SSB") || (modeIdx == 2 && m != "CW") || (modeIdx == 3 && m != "FT8") ||
            (modeIdx == 4 && m != "FT4") || (modeIdx == 5 && !other))
            continue;
        bool workedToday = today.count(adif::lookupCall(sp.activator) + "|" + sp.band) > 0;
        bool workedRef = refs.count(sp.reference) > 0;
        rows.push_back({sp.time, sp.activator, sp.khz, sp.mode, sp.reference, sp.park, sp.location,
                        workedToday ? "today" : workedRef ? "worked" : "NEW", sp.comments});
        sev.push_back(workedToday ? 0 : workedRef ? -1 : 3);
        keys.push_back(sp.key);
        spots.rowSpot.push_back(i);
    }
    [spots.w setRows:rows severities:sev keys:keys ticks:kNoTicks keepTicks:NO];
    spots.use.enabled = [spots.w selectedRows].size() == 1;
    bool wwff = spots.shown == adif::Program::WWFF;
    std::string status = spots.loading ? std::string("Fetching spots from ") + (wwff ? "spots.wwff.co..." : "pota.app...")
                         : spots.fetched.empty()
                             ? ""
                             : plural(rows.size(), "spot") + (rows.size() == spots.all.size() ? "" : " of " + std::to_string(spots.all.size())) +
                                   " at " + spots.fetched +
                                   " UTC (refreshed every minute). Double-click one, or select it and Use in New QSO. "
                                   "Green NEW: a " + (wwff ? "reference" : "park") +
                                   " not in your logs; blue: that station worked today on that band.";
    if (!status.empty()) [spots.w setStatus:ADIFString(status) severity:-1];
}

void spotsFetch() {
    if (spots.loading) return;
    spots.loading = true;
    if (spots.all.empty()) spotsShow();
    NSString *agent = [NSString stringWithFormat:@"ADIF Lint/%s (Nextpad++ plugin)", ADIFLINT_VERSION];
    adif::Program program = spots.program.indexOfSelectedItem == 1 ? adif::Program::WWFF : adif::Program::POTA;
    auto received = ^(NSArray<NSDictionary *> *list, NSString *error) {
        spots.loading = false;
        if (error) {
            [spots.w setStatus:[@"Could not fetch spots: " stringByAppendingString:error] severity:2];
            return;
        }
        if (program == adif::Program::WWFF) {
            // spots.wwff.co/static/spots.json: activator, frequency_khz, mode, reference, reference_name, remarks,
            // spotter, spot_time_formatted ("2026-10-08 00:30:18", UTC), id.
            std::vector<Spot> all;
            for (NSDictionary *d in list) {
                Spot sp;
                sp.activator = jsonString(d, @"activator", 20);
                sp.key = jsonString(d, @"id", 20);
                sp.khz = jsonString(d, @"frequency_khz", 12);
                if (sp.activator.empty() || adif::khzToMHz(sp.khz).empty()) continue;
                std::string t = jsonString(d, @"spot_time_formatted", 30);
                sp.time = t.size() >= 16 ? t.substr(11, 5) : t;
                sp.mode = jsonString(d, @"mode", 12);
                for (char &c : sp.mode) c = (char)std::toupper((unsigned char)c);
                sp.reference = jsonString(d, @"reference", 20);
                for (char &c : sp.reference) c = (char)std::toupper((unsigned char)c);
                sp.park = jsonString(d, @"reference_name");
                sp.spotter = jsonString(d, @"spotter", 20);
                sp.comments = jsonString(d, @"remarks");
                sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
                if (sp.key.empty()) sp.key = sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode;
                for (char &c : sp.activator) c = (char)std::toupper((unsigned char)c);
                all.push_back(std::move(sp));
            }
            std::stable_sort(all.begin(), all.end(), [](const Spot &a, const Spot &b) { return a.time > b.time; });
            spots.all = std::move(all);
            spots.shown = program;
            spots.fetched = utcNow("%H:%M");
            spotsShow();
            return;
        }
        std::vector<Spot> all;
        for (NSDictionary *d in list) {
            Spot sp;
            sp.activator = jsonString(d, @"activator", 20);
            sp.key = jsonString(d, @"spotId", 20);
            sp.khz = jsonString(d, @"frequency", 12);
            if (sp.activator.empty() || adif::khzToMHz(sp.khz).empty()) continue;
            std::string t = jsonString(d, @"spotTime", 30);  // "2026-10-07T21:11:57" (UTC)
            sp.time = t.size() >= 16 ? t.substr(11, 5) : t;
            sp.mode = jsonString(d, @"mode", 12);
            for (char &c : sp.mode) c = (char)std::toupper((unsigned char)c);
            sp.reference = jsonString(d, @"reference", 20);
            sp.park = jsonString(d, @"name");
            sp.location = jsonString(d, @"locationDesc", 40);
            sp.spotter = jsonString(d, @"spotter", 20);
            sp.comments = jsonString(d, @"comments");
            sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
            if (sp.key.empty()) sp.key = sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode;
            for (char &c : sp.activator) c = (char)std::toupper((unsigned char)c);
            all.push_back(std::move(sp));
        }
        std::stable_sort(all.begin(), all.end(), [](const Spot &a, const Spot &b) { return a.time > b.time; });
        spots.all = std::move(all);
        spots.shown = program;
        spots.fetched = utcNow("%H:%M");
        spotsShow();
    };
    if (program == adif::Program::WWFF) ADIFFetchWwffSpots(agent, received);
    else ADIFFetchPotaSpots(agent, received);
}

void spotsUse(NSInteger row) {
    if (row < 0 || (size_t)row >= spots.rowSpot.size() || !spots.handler) return;
    const Spot &sp = spots.all[spots.rowSpot[(size_t)row]];
    spots.handler(adif::programSpotFields(spots.shown, sp.activator, sp.khz, sp.mode, sp.reference));
    [spots.w setStatus:ADIFString("Copied " + sp.activator + " at " + sp.reference + " (" + sp.khz + " kHz " + sp.mode +
                                  ") to New QSO.")
              severity:-1];
}

// ── Import CSV ──────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSTextField *from = nil;
    NSButton *sort = nil, *add = nil;
    std::string path;
    adif::CsvImport data;
    intptr_t buffer = 0;
} csvIn;

void csvPlan() {
    if (!csvIn.w) return;
    csvIn.add.enabled = NO;
    csvIn.add.title = @"Add QSOs";
    [csvIn.w setTarget:logLine()];
    csvIn.from.stringValue = csvIn.path.empty() ? @"(choose a CSV file)" : tilde(csvIn.path);
    [csvIn.w setRows:kNoRows severities:kNoSev];
    if (csvIn.path.empty()) {
        [csvIn.w setStatus:@"Choose a CSV file whose first row names the columns: ADIF field names, or names such as "
                           @"Callsign, Date, UTC, Frequency, Mode, RST Sent, RST Rcvd, Grid, Park, Notes."
                  severity:-1];
        return;
    }
    std::string text, error;
    if (!readFile(csvIn.path, kMaxLogBytes, &text, &error)) {
        [csvIn.w setStatus:ADIFString("Could not read it: " + error + ".") severity:2];
        return;
    }
    csvIn.data = adif::importCsv(text);
    csvIn.buffer = buffer();
    std::vector<std::vector<std::string>> rows;
    std::vector<int> sev;
    for (const auto &rec : csvIn.data.records) {
        adif::Record r;
        r.fields = rec;
        bool ok = !r.get("CALL").empty() && adif::parseAdifDate(r.get("QSO_DATE"), nullptr) &&
                  adif::parseAdifTime(r.get("TIME_ON"), nullptr) && !adif::effectiveBand(r).empty() && !adif::effectiveMode(r).empty();
        rows.push_back({r.get("CALL"), adif::displayDate(r.get("QSO_DATE")), adif::displayTime(r.get("TIME_ON")),
                        adif::effectiveBand(r), adif::effectiveMode(r), std::to_string(r.fields.size())});
        sev.push_back(ok ? -1 : 1);
    }
    [csvIn.w setRows:rows severities:sev];
    std::string used, left;
    for (const auto &c : csvIn.data.columns)
        if (c.second.empty()) left += (left.empty() ? "" : ", ") + c.first;
        else used += (used.empty() ? "" : ", ") + c.first + " \u2192 " + c.second;
    std::string st = plural(csvIn.data.records.size(), "row") + ". Columns: " + (used.empty() ? "none recognised" : used) + "." +
                     (left.empty() ? "" : " Left out: " + left + ".");
    for (size_t i = 0; i < csvIn.data.notes.size() && i < 3; ++i) st += " " + csvIn.data.notes[i] + ".";
    if (csvIn.data.notes.size() > 3) st += " And " + std::to_string(csvIn.data.notes.size() - 3) + " more.";
    st += " Orange rows lack CALL, a valid date and time, BAND or FREQ, or MODE: the validator will mark them.";
    [csvIn.w setStatus:ADIFString(st) severity:csvIn.data.notes.empty() ? -1 : 1];
    if (!csvIn.data.records.empty()) {
        csvIn.add.enabled = YES;
        csvIn.add.title = [NSString stringWithFormat:@"Add %zu QSO%@", csvIn.data.records.size(), csvIn.data.records.size() == 1 ? @"" : @"s"];
        [csvIn.w setDefaultButton:csvIn.add];
    }
}

void csvAdd() {
    try {
        NppHandle h = scintilla();
        if (csvIn.buffer != buffer() || readOnly(h)) {
            [csvIn.w setStatus:@"Switch back to the log you were adding to (and make sure it isn't read-only)." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        bool blank = text.find_first_not_of(" \t\r\n") == std::string_view::npos;
        std::string problem = structureProblem(r);
        if (!blank && !problem.empty()) {
            [csvIn.w setStatus:ADIFString("This log: " + problem) severity:2];
            return;
        }
        std::string eolText = eol(h);
        adif::Layout layout = blank ? adif::Layout::RecordPerLine : adif::recordLayout(text, r.model);
        std::string records;
        for (const auto &rec : csvIn.data.records) {
            if (!records.empty() && layout == adif::Layout::FieldPerLine) records += eolText;
            records += adif::buildRecord(rec, layout, eolText, lengthUnit(), utf8(h)).text;
        }
        std::string merged;
        size_t start = 0;
        if (blank) merged = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records;
        else merged = adif::applyTextEdits(text, {adif::appendRecord(text, r.model, records, eolText, &start)});
        std::string note;
        if (csvIn.sort.state == NSControlStateValueOn) {
            adif::LintResult rm = lintText(merged);
            if (structureProblem(rm).empty()) {
                bool changed = false;
                merged = adif::sortedByTime(merged, rm.model, eolText, &changed);
                if (changed) note = " and sorted by date and time";
            }
        }
        size_t n = csvIn.data.records.size();
        adifhost::apply(h, {adif::TextEdit{0, text.size(), merged}});
        csvIn.add.enabled = NO;
        [csvIn.w setRows:kNoRows severities:kNoSev];
        [csvIn.w setStatus:ADIFString("Added " + plural(n, "QSO") + " from " + fileName(csvIn.path) + note + " (one undo step).")
                  severity:-1];
    } catch (...) {
        [csvIn.w setStatus:@"Something went wrong adding the QSOs." severity:2];
    }
}

// ── Export Cabrillo ─────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSComboBox *contest = nil;
    NSTextField *callsign = nil, *grid = nil, *location = nil;
    NSPopUpButton *op = nil, *power = nil;
    adif::CabrilloLog log;
} cab;

void cabPlan() {
    if (!cab.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        [cab.w setTarget:logLine()];
        adif::CabrilloOptions o;
        o.contest = ADIFStd(cab.contest.stringValue);
        o.callsign = ADIFStd(cab.callsign.stringValue);
        o.grid = ADIFStd(cab.grid.stringValue);
        o.location = ADIFStd(cab.location.stringValue);
        o.categoryOperator = cab.op.indexOfSelectedItem > 0 ? ADIFStd(cab.op.titleOfSelectedItem) : "";
        o.categoryPower = cab.power.indexOfSelectedItem > 0 ? ADIFStd(cab.power.titleOfSelectedItem) : "";
        o.createdBy = std::string("ADIF Lint ") + ADIFLINT_VERSION;
        std::set<std::string> ops;
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        for (const adif::Record &rec : recs)
            if (!rec.get("OPERATOR").empty()) ops.insert(rec.get("OPERATOR"));
        for (const std::string &x : ops) o.operators += (o.operators.empty() ? "" : " ") + x;
        cab.log = adif::toCabrillo(recs, o);
        [cab.w setText:ADIFString(cab.log.text)];
        std::string st = plural(cab.log.qsos, "QSO line");
        if (cab.log.incomplete) st += "; " + plural(cab.log.incomplete, "line") + " show - for a missing report or exchange";
        if (cab.log.skipped) st += "; " + plural(cab.log.skipped, "record") + " left out (no CALL, date, time, band or mode)";
        st += ". The sent and received exchange come from STX_STRING or STX and SRX_STRING or SRX: check the contest's "
              "own Cabrillo template before you submit.";
        [cab.w setStatus:ADIFString(st) severity:cab.log.incomplete || cab.log.skipped ? 1 : -1];
    } catch (...) {
    }
}

}  // namespace

namespace logtools {

void cmdPotaSpots() {
    if (!spots.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Spots" size:NSMakeSize(980, 520) headline:NO];
        spots.w = w;
        spots.program = ADIFPopup(@[ @"POTA", @"WWFF" ]);
        spots.program.toolTip = @"Parks on the Air spots from pota.app, or World Wide Flora & Fauna spots from spots.wwff.co";
        if (setting("spotsProgram") == "WWFF") [spots.program selectItemAtIndex:1];
        ADIFOnAction(spots.program, ^{
            setSetting("spotsProgram", spots.program.indexOfSelectedItem == 1 ? "WWFF" : "POTA");
            spots.all.clear();
            spots.fetched.clear();
            spotsShow();
            spotsFetch();
        });
        spots.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        spots.search.placeholderString = @"Filter: call, park, state...";
        spots.search.sendsSearchStringImmediately = YES;
        [spots.search.widthAnchor constraintEqualToConstant:220].active = YES;
        ADIFOnAction(spots.search, ^{ [spots.w setFilter:spots.search.stringValue]; });
        NSMutableArray *bands = [NSMutableArray arrayWithObject:@"All bands"];
        for (const char *b : kSpotBands) [bands addObject:@(b)];
        spots.band = ADIFPopup(bands);
        spots.mode = ADIFPopup(@[ @"All modes", @"SSB", @"CW", @"FT8", @"FT4", @"Other" ]);
        ADIFOnAction(spots.band, ^{ spotsShow(); });
        ADIFOnAction(spots.mode, ^{ spotsShow(); });
        [w addOptionRow:@[ spots.program, spots.search, spots.band, spots.mode ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"time", "UTC", 50}, {"call", "Activator", 90}, {"khz", "kHz", 70},
                                                  {"mode", "Mode", 50}, {"park", "Reference", 84}, {"name", "Name", 230},
                                                  {"loc", "Location", 70}, {"worked", "Worked", 56}, {"comments", "Comments", 200}}
            checkboxes:NO
              sortable:YES];
        w.onActivateRow = ^(NSInteger row) { spotsUse(row); };
        w.onSelectionChanged = ^{ spots.use.enabled = [spots.w selectedRows].size() == 1; };
        [w addButton:@"Refresh" trailing:NO action:^{ spotsFetch(); }];
        spots.use = [w addButton:@"Use in New QSO" trailing:YES action:^{
            std::vector<NSInteger> sel = [spots.w selectedRows];
            if (sel.size() == 1) spotsUse(sel[0]);
        }];
        spots.use.enabled = NO;
        [w setDefaultButton:spots.use];
        spots.timer = [NSTimer timerWithTimeInterval:60
                                             repeats:YES
                                               block:^(NSTimer *t) {
                                                   if (spots.w.window.visible) spotsFetch();
                                               }];
        [[NSRunLoop mainRunLoop] addTimer:spots.timer forMode:NSRunLoopCommonModes];
    }
    [spots.w setTarget:logLine()];
    [spots.w show];
    spotsFetch();
}

void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields)) {
    spots.handler = handler;
}



void cmdLogTable() {
    if (!table.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Log Table" size:NSMakeSize(980, 560) headline:NO];
        table.w = w;
        table.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        table.search.placeholderString = @"Filter: call, park, mode...";
        table.search.sendsSearchStringImmediately = YES;
        [table.search.widthAnchor constraintEqualToConstant:260].active = YES;
        table.count = ADIFLabel(@"");
        table.count.textColor = NSColor.secondaryLabelColor;
        [w addOptionRow:@[ table.search, table.count ]];
        ADIFOnAction(table.search, ^{
            [table.w setFilter:table.search.stringValue];
            tableUpdateCount();
        });
        w.onSelectionChanged = ^{
            std::vector<NSInteger> sel = [table.w selectedRows];
            if (sel.size() != 1 || table.buffer != buffer() || (size_t)sel[0] >= table.starts.size()) return;
            goTo(scintilla(), table.starts[(size_t)sel[0]], false);
        };
        w.onActivateRow = ^(NSInteger row) {
            if (table.buffer == buffer() && (size_t)row < table.starts.size()) goTo(scintilla(), table.starts[(size_t)row], true);
        };
        w.onEditCell = ^(NSInteger row, size_t column, NSString *text) { tableEdit(row, column, text); };
        w.onSortChanged = ^(NSInteger column, BOOL ascending) {
            std::string field = column == 0 ? "#" : column > 0 && (size_t)column <= table.columns.size() ? table.columns[(size_t)column - 1] : "";
            setSetting("tableSort", field.empty() ? "" : field + (ascending ? ":a" : ":d"));
        };
        table.menu = [[NSMenu alloc] initWithTitle:@"Columns"];
        [w setHeaderMenu:table.menu];
        [w addButton:@"Bulk Edit Selected..." trailing:NO action:^{ openBulkEdit(false, true); }];
        [w addButton:@"Export CSV..." trailing:NO action:^{
            std::vector<adif::Record> shown;
            for (NSInteger row : [table.w shownRows])
                if ((size_t)row < table.recs.size()) shown.push_back(table.recs[(size_t)row]);
            exportCsv(shown, table.columns, table.w);
        }];
    }
    table.columns.clear();
    tableRefresh();
    [table.w show];
}

void cmdSummary() {
    if (!summary.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Log Summary" size:NSMakeSize(640, 640) headline:NO];
        summary.w = w;
        [w addButton:@"Copy" trailing:NO action:^{
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:summary.w.text forType:NSPasteboardTypeString];
            [summary.w setStatus:@"Copied." severity:-1];
        }];
    }
    summaryRefresh();
    [summary.w show];
}

void cmdActivationTracker() {
    if (!tracker.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Activation Tracker" size:NSMakeSize(940, 480) headline:YES];
        tracker.w = w;
        tracker.program = ADIFPopup(@[ @"POTA", @"WWFF", @"SOTA" ]);
        std::string saved = setting("trackerProgram");
        [tracker.program selectItemAtIndex:saved == "WWFF" ? 1 : saved == "SOTA" ? 2 : 0];
        ADIFOnAction(tracker.program, ^{
            setSetting("trackerProgram", adif::programName(trackerProgram()));
            trackerRefresh();
        });
        [w addOptionRow:@[ ADIFLabel(@"Program:"), tracker.program ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"park", "Reference", 96}, {"date", "UTC Date", 84}, {"station", "Station", 72}, {"qsos", "QSOs", 44},
                       {"need", "Needed", 60}, {"p2p", "P2P", 36}, {"dupes", "Dupes", 46}, {"rejected", "Rejected", 62},
                       {"bands", "Bands", 104}, {"modes", "Modes", 92}, {"first", "First", 56}, {"last", "Last", 56}}
            checkboxes:NO
              sortable:YES];
        w.onActivateRow = ^(NSInteger row) {
            if ((size_t)row < tracker.starts.size()) goTo(scintilla(), tracker.starts[(size_t)row], true);
        };
        [w addButton:@"Export Logs..." trailing:NO action:^{ openPotaExport(trackerProgram()); }];
    }
    trackerRefresh();
    [tracker.w show];
}

void cmdWorkedBefore() {
    if (!worked.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Worked Before" size:NSMakeSize(880, 480) headline:NO];
        worked.w = w;
        worked.folder = ADIFLabel(@"");
        worked.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [worked.folder.widthAnchor constraintLessThanOrEqualToConstant:460].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string dir = chooseOpen(@"Choose the folder that holds your ADIF logs", true);
            if (dir.empty()) return;
            setSetting("logsFolder", dir);
            indexRebuild();
            workedRefresh();
        });
        NSButton *rescan = [NSButton buttonWithTitle:@"Rescan" target:nil action:nil];
        ADIFOnAction(rescan, ^{
            indexRebuild();
            workedRefresh();
        });
        [w addOptionRow:@[ ADIFLabel(@"Logs folder:"), worked.folder, choose, rescan ]];
        worked.call = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        worked.call.placeholderString = @"Callsign";
        worked.call.sendsSearchStringImmediately = NO;
        [worked.call.widthAnchor constraintEqualToConstant:200].active = YES;
        ADIFOnAction(worked.call, ^{ workedRefresh(); });
        [w addOptionRow:@[ ADIFLabel(@"Call:"), worked.call, ADIFLabel(@"(portable forms match: VE3/K1ABC/P finds K1ABC)") ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"log", "Log", 200}, {"date", "Date", 84}, {"time", "Time", 64}, {"call", "Call", 100}, {"band", "Band", 50},
                       {"mode", "Mode", 60}, {"mypark", "My Park", 90}, {"park", "Their Park", 90}}
            checkboxes:NO
              sortable:YES];
    }
    [worked.w setTarget:logLine()];
    indexRebuild();
    workedRefresh();
    [worked.w show];
    [worked.w.window makeFirstResponder:worked.call];
}

void cmdBulkEdit() { openBulkEdit(false, false); }
void cmdTimeShift() { openBulkEdit(true, false); }

void cmdSortByTime() {
    try {
        NppHandle h = scintilla();
        adif::LintResult r = lint(h);
        if (!hasRecords(r)) {
            showTip(h, "ADIF Lint: this document has no ADIF records to sort.");
            return;
        }
        std::string problem = structureProblem(r);
        if (!problem.empty()) {
            showTip(h, "ADIF Lint: " + problem);
            return;
        }
        if (readOnly(h)) {
            showTip(h, "ADIF Lint: this document is read-only.");
            return;
        }
        std::string_view text = adifhost::text(h);
        bool changed = false;
        std::string sorted = adif::sortedByTime(text, r.model, eol(h), &changed);
        if (!changed) {
            showTip(h, "ADIF Lint: the records are already in date and time order.");
            return;
        }
        adifhost::apply(h, {adif::TextEdit{0, text.size(), sorted}});
        goTo(h, 0, true);
        showTip(h, "ADIF Lint: sorted " + plural(adif::recordCount(r.model), "record") +
                       " by QSO_DATE and TIME_ON (one undo step). Records without a valid date and time are at the end.");
    } catch (...) {
    }
}

void cmdRemoveDuplicates() {
    if (!dupes.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Remove Duplicates" size:NSMakeSize(860, 480) headline:NO];
        dupes.w = w;
        dupes.window = ADIFTextField(@"2", 44);
        dupes.window.stringValue = @"2";
        [w addOptionRow:@[ ADIFLabel(@"Same CALL, band and mode, starting within"), dupes.window, ADIFLabel(@"minutes") ]];
        dupes.fill = ADIFCheckbox(@"Copy fields only the removed record has (e.g. GRIDSQUARE) to the one kept", YES);
        [w addOptionRow:@[ dupes.fill ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"keep", "Keep", 50}, {"remove", "Remove", 80}, {"call", "Call", 90}, {"date", "Date", 84},
                       {"time", "Time", 64}, {"band", "Band", 50}, {"mode", "Mode", 60}, {"adds", "Adds", 200}}
            checkboxes:YES
              sortable:NO];
        dupes.find = [w addButton:@"Find Duplicates" trailing:NO action:^{ dupesFind(); }];
        dupes.remove = [w addButton:@"Remove Duplicates" trailing:YES action:^{ dupesRemove(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                          object:dupes.window
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) { dupesClear(@"Settings changed. Find again."); }];
    }
    dupesFind();
    [dupes.w show];
}

void cmdMergeLog() {
    if (!merge.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Merge Another Log" size:NSMakeSize(820, 500) headline:NO];
        merge.w = w;
        merge.from = ADIFLabel(@"");
        merge.from.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [merge.from.widthAnchor constraintLessThanOrEqualToConstant:480].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string p = chooseOpen(@"Choose the ADIF log to add from", false);
            if (p.empty()) return;
            merge.path = p;
            mergePlanNow();
        });
        [w addOptionRow:@[ ADIFLabel(@"From:"), merge.from, choose ]];
        merge.skip = ADIFCheckbox(@"Skip QSOs this log already has (same CALL, band and mode within 2 minutes)", YES);
        merge.sort = ADIFCheckbox(@"Sort by date and time afterwards", YES);
        [w addOptionRow:@[ merge.skip ]];
        [w addOptionRow:@[ merge.sort ]];
        ADIFOnAction(merge.skip, ^{ mergePlanNow(); });
        [w setColumns:std::vector<ADIFToolColumn>{{"record", "Record", 56}, {"call", "Call", 90}, {"date", "Date", 84}, {"time", "Time", 64},
                       {"band", "Band", 50}, {"mode", "Mode", 60}, {"what", "", 220}}
            checkboxes:NO
              sortable:NO];
        merge.add = [w addButton:@"Add QSOs" trailing:YES action:^{ mergeApply(); }];
    }
    mergePlanNow();
    [merge.w show];
}

void cmdExportCsv() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        if (!hasRecords(r)) {
            showTip(h, "ADIF Lint: this document has no ADIF records to export.");
            return;
        }
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        exportCsv(recs, adif::tableColumns(recs), nil);
    } catch (...) {
    }
}

void cmdImportCsv() {
    if (!csvIn.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Import CSV" size:NSMakeSize(860, 520) headline:NO];
        csvIn.w = w;
        csvIn.from = ADIFLabel(@"");
        csvIn.from.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [csvIn.from.widthAnchor constraintLessThanOrEqualToConstant:480].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string p = chooseOpen(@"Choose the CSV file to add from", false, @[ @"csv", @"txt", @"tsv" ]);
            if (p.empty()) return;
            csvIn.path = p;
            csvPlan();
        });
        [w addOptionRow:@[ ADIFLabel(@"From:"), csvIn.from, choose ]];
        csvIn.sort = ADIFCheckbox(@"Sort by date and time afterwards", YES);
        [w addOptionRow:@[ csvIn.sort ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"call", "Call", 90}, {"date", "Date", 84}, {"time", "Time", 64},
                                                  {"band", "Band", 50}, {"mode", "Mode", 60}, {"fields", "Fields", 50}}
            checkboxes:NO
              sortable:NO];
        csvIn.add = [w addButton:@"Add QSOs" trailing:YES action:^{ csvAdd(); }];
    }
    csvPlan();
    [csvIn.w show];
}

void cmdExportCabrillo() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        if (!cab.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Export Cabrillo" size:NSMakeSize(900, 600) headline:NO];
            cab.w = w;
            cab.contest = ADIFComboBox(@[], 220);
            cab.contest.placeholderString = @"e.g. ARRL-SS-CW";
            cab.callsign = ADIFTextField(@"your call", 110);
            [w addOptionRow:@[ ADIFLabel(@"Contest:"), cab.contest, ADIFLabel(@"Callsign:"), cab.callsign ]];
            cab.op = ADIFPopup(@[ @"(operator)", @"SINGLE-OP", @"MULTI-OP", @"CHECKLOG" ]);
            cab.power = ADIFPopup(@[ @"(power)", @"HIGH", @"LOW", @"QRP" ]);
            cab.grid = ADIFTextField(@"grid", 80);
            cab.location = ADIFTextField(@"ARRL section or DX", 130);
            [w addOptionRow:@[ ADIFLabel(@"Category:"), cab.op, cab.power, ADIFLabel(@"Grid:"), cab.grid, ADIFLabel(@"Location:"), cab.location ]];
            for (NSControl *c in @[ cab.op, cab.power, cab.contest ]) ADIFOnAction(c, ^{ cabPlan(); });
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == cab.w.window) cabPlan();
                                                          }];
            [w addButton:@"Save..." trailing:YES action:^{
                std::string name = stem(path().empty() ? std::string("log") : documentName()) + ".log";
                std::string dest = chooseSave(ADIFString(name), @[ @"log", @"cbr" ]);
                if (dest.empty()) return;
                std::string error;
                if (!writeFile(dest, cab.log.text, &error)) [cab.w setStatus:ADIFString("Could not save: " + error) severity:2];
                else [cab.w setStatus:ADIFString("Saved " + plural(cab.log.qsos, "QSO") + " to " + fileName(dest) + ".") severity:-1];
            }];
        }
        std::set<std::string> contests;
        std::string grid;
        for (const adif::Record &rec : recs) {
            if (!rec.get("CONTEST_ID").empty()) contests.insert(rec.get("CONTEST_ID"));
            if (grid.empty()) grid = rec.get("MY_GRIDSQUARE");
        }
        [cab.contest removeAllItems];
        for (const std::string &c : contests) [cab.contest addItemWithObjectValue:ADIFString(c)];
        if (!cab.contest.stringValue.length && !contests.empty()) cab.contest.stringValue = ADIFString(*contests.begin());
        if (!cab.callsign.stringValue.length) cab.callsign.stringValue = ADIFString(usualStation(adifhost::text(h), r.model));
        if (!cab.grid.stringValue.length) cab.grid.stringValue = ADIFString(grid.substr(0, std::min<size_t>(grid.size(), 6)));
        cabPlan();
        [cab.w show];
    } catch (...) {
    }
}

void cmdExportPota() { openPotaExport(tracker.program ? trackerProgram() : adif::Program::POTA); }

void documentChanged() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != token) return;
        if (tableVisible()) tableRefresh();
        if (summary.w && summary.w.window.visible) summaryRefresh();
        if (tracker.w && tracker.w.window.visible) trackerRefresh();
        bulkClear(@"The log changed. Preview again.");
        dupesClear(@"The log changed. Find Duplicates again.");
        if (merge.w && merge.w.window.visible && merge.ready) mergePlanNow();
        if (pota.w && pota.w.window.visible) potaPlan();
        if (spots.w && spots.w.window.visible && !spots.all.empty()) spotsShow();
    });
}

void bufferActivated() { documentChanged(); }

std::string workedBefore(const std::string &call) {
    if (logsFolder().empty()) return "";
    if (idx.folder != logsFolder() || [NSDate date].timeIntervalSince1970 - idx.builtAt > 120) indexRebuild();
    if (idx.folder != logsFolder()) return "";
    std::vector<adif::WorkedHit> hits = indexLookup(call);
    return adif::workedSummary(adif::lookupCall(call), hits);
}

// Contacts naming `ref`: this log (unsaved changes included) and the indexed folder (the active file left out).
static std::vector<adif::WorkedHit> referenceHits(const std::string &ref) {
    std::vector<adif::WorkedHit> hits;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        for (adif::Contact &c : adif::contacts(adifhost::text(h), r.model)) hits.push_back({documentName(), std::move(c)});
    } catch (...) {
    }
    std::string active = path();
    for (const auto &log : idx.logs)
        if (log->path != active)
            for (const adif::Contact &c : log->contacts)
                if (!c.theirRefs.empty()) hits.push_back({log->name, c});
    return hits;
}

std::string referenceLine(const std::string &ref) {
    if (ref.empty()) return "";
    if (!logsFolder().empty() && idx.folder != logsFolder()) indexRebuild();
    return adif::referenceSummary(ref, adif::referenceHistory(ref, referenceHits(ref)));
}

bool referenceWorked(const std::string &ref) { return adif::referenceHistory(ref, referenceHits(ref)).qsos > 0; }

void setIndexListener(void (^listener)(void)) {
    idx.listener = listener;
}

}  // namespace logtools

namespace {

void openPotaExport(adif::Program program) {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        if (!pota.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Export Activation Logs" size:NSMakeSize(900, 500) headline:NO];
            pota.w = w;
            pota.program = ADIFPopup(@[ @"POTA", @"WWFF", @"SOTA" ]);
            ADIFOnAction(pota.program, ^{ potaPlan(); });
            [w addOptionRow:@[ ADIFLabel(@"Program:"), pota.program ]];
            pota.station = ADIFTextField(@"e.g. K1ABC", 120);
            [w addOptionRow:@[ ADIFLabel(@"Callsign for records without STATION_CALLSIGN or OPERATOR:"), pota.station ]];
            pota.folder = ADIFLabel(@"");
            pota.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [pota.folder.widthAnchor constraintLessThanOrEqualToConstant:460].active = YES;
            NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
            ADIFOnAction(choose, ^{
                std::string dir = chooseOpen(@"Choose the folder for the activation logs", true);
                if (dir.empty()) return;
                setSetting("potaFolder", dir);
                potaPlan();
            });
            [w addOptionRow:@[ ADIFLabel(@"Save to:"), pota.folder, choose ]];
            [w setColumns:std::vector<ADIFToolColumn>{{"file", "File", 250}, {"park", "Reference", 100}, {"date", "UTC Date", 84}, {"records", "Records", 60},
                           {"qsos", "QSOs", 48}, {"notes", "Notes", 300}}
                checkboxes:YES
                  sortable:NO];
            pota.save = [w addButton:@"Save Files" trailing:YES action:^{ potaSave(); }];
            [w setDefaultButton:pota.save];
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:pota.station
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) { potaPlan(); }];
        }
        [pota.program selectItemAtIndex:program == adif::Program::WWFF ? 1 : program == adif::Program::SOTA ? 2 : 0];
        std::string station = setting("potaStation");
        std::string usual = usualStation(adifhost::text(h), r.model);
        pota.station.stringValue = ADIFString(usual.empty() ? station : usual);
        potaPlan();
        [pota.w show];
    } catch (...) {
    }
}

}  // namespace
