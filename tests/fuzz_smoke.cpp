// Mutation fuzz and worst-case timing for the ADI validator.
//
// Build with -fsanitize=address,undefined. Every input is untrusted text from
// the editor, so lint() must never crash, must return in-bounds ranges and
// non-overlapping fixes, and must stay near-linear on hostile inputs.
//
//   fuzz_smoke SEED_FILE [ITERATIONS]
#include "adif_capture.h"
#include "adif_qsl.h"
#include "adif_country.h"
#include "adif_edit.h"
#include "adif_formats.h"
#include "adif_geo.h"
#include "adif_import.h"
#include "adif_lint.h"
#include "adif_parks.h"
#include "adif_programs.h"
#include "adif_profiles.h"
#include "adif_tools.h"
#include "adif_upload.h"
#include "adif_world.h"
#include "adif_worked.h"
#include "adif_regions.h"
#include "adif_pmtiles.h"
#include "adif_mvt.h"
#include "adif_spots.h"
#include "adif_json.h"
#include "adif_outlines.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <string>

using namespace adif;

static int gFailures = 0;

static void checkInvariants(const std::string &text, const LintResult &r, const char *what) {
    for (const Diagnostic &d : r.diagnostics) {
        if (!(d.start < d.end && d.end <= text.size())) {
            std::printf("FAIL %s: diagnostic range [%zu,%zu) outside %zu bytes\n", what, d.start, d.end, text.size());
            ++gFailures;
            return;
        }
    }
    size_t prev = 0;
    for (const LengthFix &f : r.fixes) {
        if (f.start < prev || f.end > text.size() || f.end <= f.start) {
            std::printf("FAIL %s: bad fix [%zu,%zu)\n", what, f.start, f.end);
            ++gFailures;
            return;
        }
        prev = f.end;
    }
}

// Model offsets go straight into Scintilla calls in the plugin: they must be in
// bounds and ordered, and the editing helpers must keep data intact.
static void checkModel(const std::string &text, const LintResult &r, std::mt19937 &rng) {
    const DocModel &m = r.model;
    size_t n = text.size();
    for (const ModelField &f : m.fields) {
        bool ok = f.tagB < f.nameE && f.nameE < f.lenB && f.lenB < f.lenE && f.lenE <= f.gt && f.gt < n && f.gt < f.valueE + 1 &&
                  f.valueE <= n && (f.typePos == kNoPos || (f.typePos > f.lenE && f.typePos < f.gt));
        if (!ok) {
            std::printf("FAIL model field out of order: tag %zu name %zu len %zu-%zu gt %zu value %zu (n %zu)\n", f.tagB, f.nameE,
                        f.lenB, f.lenE, f.gt, f.valueE, n);
            ++gFailures;
            return;
        }
    }
    for (const ModelGroup &g : m.groups) {
        if (g.firstField + g.fieldCount > m.fields.size() || (g.markerB != kNoPos && !(g.markerB < g.markerE && g.markerE <= n))) {
            std::printf("FAIL model group out of range\n");
            ++gFailures;
            return;
        }
    }
    if (canReformat(r)) {
        std::string out = reformat(text, m, Layout::FieldPerLine, "\n");
        LintOptions o;
        o.buildModel = true;
        LintResult ro = lint(out, o);
        if (ro.model.fields.size() != m.fields.size()) {
            std::printf("FAIL reformat changed the number of fields: %zu -> %zu\n", m.fields.size(), ro.model.fields.size());
            ++gFailures;
            return;
        }
    }
    // Log tools: reports on any model; edits only where the plugin allows them.
    std::vector<Record> recs = records(text, m);
    toCsv(recs, tableColumns(recs));
    summaryReport(text, m, "fuzz");
    potaExport(text, m, "K1AB", "0", "20260101 000000", "\n", LengthUnit::Bytes, true, "20260101");
    for (Program p : {Program::WWFF, Program::SOTA}) {
        programActivations(text, m, p, "K1AB");
        programExport(p, text, m, "K1AB", "0", "20260101 000000", "\n", LengthUnit::Bytes, true, "20260101");
    }
    toCabrillo(recs, CabrilloOptions());
    // Any document read as a site's download, and planned against itself.
    for (ImportSite site : {ImportSite::LoTW, ImportSite::QRZLogbook, ImportSite::EQSL}) {
        std::vector<SiteQso> qsos = siteQsos(site, text, m, "20260101");
        std::vector<ImportItem> items = planImport(text, m, qsos, site);
        std::vector<size_t> all;
        for (size_t i = 0; i < qsos.size(); ++i) all.push_back(i);
        if (items.size() != qsos.size()) {
            std::printf("FAIL import: %zu items for %zu QSOs\n", items.size(), qsos.size());
            ++gFailures;
        }
        importedRecords(qsos, all, Layout::RecordPerLine, "\n", LengthUnit::Bytes, true);
    }
    // Rows without a QSO field (a header read as a record) are dropped; nothing is invented.
    CsvImport back = importCsv(toCsv(recs, tableColumns(recs)));
    if (back.records.size() > recs.size()) {
        std::printf("FAIL CSV round trip: %zu records became %zu\n", recs.size(), back.records.size());
        ++gFailures;
    }
    contacts(text, m);
    auto editsOk = [&](const std::vector<TextEdit> &edits) {
        size_t prev = 0;
        for (const TextEdit &e : edits) {
            if (e.start < prev || e.end < e.start || e.end > n) return false;
            prev = e.end;
        }
        return true;
    };
    if (canReformat(r)) {
        std::vector<int> groups;
        for (const Record &rec : recs) groups.push_back(rec.group);
        BulkEdit op;
        op.field = "MODE";
        op.value = "CW";
        bool ok = editsOk(planEdits(text, m, planBulkEdit(text, m, groups, op).changes, LengthUnit::Bytes, true)) &&
                  editsOk(planEdits(text, m, planTimeShift(text, m, groups, -1441).changes, LengthUnit::Bytes, true)) &&
                  editsOk(duplicateEdits(text, m, findDuplicates(text, m, DupeOptions()), true, LengthUnit::Bytes, true));
        if (!ok) {
            std::printf("FAIL tool edits out of order or bounds\n");
            ++gFailures;
        }
        if (!editsOk(planEdits(text, m, planDistance(text, m, groups).changes, LengthUnit::Bytes, true))) {
            std::printf("FAIL distance edits out of order or bounds\n");
            ++gFailures;
        }
        std::vector<TextEdit> mm = markModified(text, m, groups, LengthUnit::Bytes, true);
        if (!editsOk(mm) || !editsOk(mergeEdits(planEdits(text, m, planBulkEdit(text, m, groups, op).changes, LengthUnit::Bytes, true), mm))) {
            std::printf("FAIL modified-status edits out of order or bounds\n");
            ++gFailures;
        }
        recordKeys(recs);
        if (!recs.empty()) sameContactAs(text, m, recs.front());
        size_t edited = 0, skipped = 0;
        std::vector<TextEdit> fo = fieldOrderEdits(text, m, {"CALL", "QSO_DATE", "TIME_ON", "BAND"}, &edited, &skipped);
        if (!editsOk(fo)) {
            std::printf("FAIL field-order edits out of order or bounds\n");
            ++gFailures;
        } else if (lint(applyTextEdits(text, fo)).records != r.records) {
            std::printf("FAIL reordering fields changed the number of records\n");
            ++gFailures;
        }
        // Quick fixes (Check Log, --fix-all): in bounds, ordered, and never losing or splitting
        // records (adding a missing final <EOR> makes that record count).
        size_t repaired = 0;
        bool addsEor = false;
        for (const Diagnostic &d : r.diagnostics) addsEor |= d.code == "no-eor" && !d.fixes.empty();
        std::vector<TextEdit> qf = quickFixEdits(text, m, r.diagnostics, LengthUnit::Bytes, true, &repaired);
        size_t afterRecords = editsOk(qf) ? lint(applyTextEdits(text, qf)).records : 0;
        if (!editsOk(qf)) {
            std::printf("FAIL quick-fix edits out of order or bounds\n");
            ++gFailures;
        } else if (afterRecords != r.records && !(addsEor && afterRecords == r.records + 1)) {
            std::printf("FAIL quick fixes changed the number of records: %zu -> %zu\n", r.records, afterRecords);
            ++gFailures;
        }
        bool sortedAgain = false;
        std::string byBand = sortedBy(text, m, {{"BAND", false}, {"CALL", true}, {"FREQ", false}}, "\n", &sortedAgain);
        if (lint(byBand).records != r.records) {
            std::printf("FAIL sorting by fields changed the number of records\n");
            ++gFailures;
        }
        bool changed = false;
        std::string sorted = sortedByTime(text, m, "\n", &changed);
        LintResult rs = lint(sorted);
        if (rs.records != r.records) {
            std::printf("FAIL sorting changed the number of records: %zu -> %zu\n", r.records, rs.records);
            ++gFailures;
        }
    }
    if (!m.groups.empty()) {
        const ModelGroup &g = m.groups[rng() % m.groups.size()];
        auto inBounds = [&](const TextEdit &e) { return e.start <= e.end && e.end <= n; };
        bool ok = inBounds(insertField(text, m, g, "CALL", "W1AW", LengthUnit::Bytes, true));
        if (g.fieldCount) {
            size_t i = rng() % g.fieldCount;
            ok = ok && inBounds(removeField(text, m, g, i)) &&
                 inBounds(setFieldValue(text, m.fields[g.firstField + i], "x", LengthUnit::Characters, true));
            valueChoices(text, m, &g, fieldName(text, m.fields[g.firstField + i]));
        }
        fieldNameChoices(m, g.header);
        if (!ok) {
            std::printf("FAIL edit out of bounds\n");
            ++gFailures;
        }
    }
}

static double lintMs(const std::string &text, LintOptions opt = {}) {
    auto t0 = std::chrono::steady_clock::now();
    LintResult r = lint(text, opt);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    checkInvariants(text, r, "timing input");
    return ms;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: fuzz_smoke SEED_FILE [ITERATIONS]\n");
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    std::string seed = ss.str().substr(0, 20000);  // a header plus ~100 records
    int iterations = argc > 2 ? std::atoi(argv[2]) : 3000;

    std::mt19937 rng(7);
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
    const double limitMsCapture = 10000;
#else
    const double limitMsCapture = 2000;
#endif
#else
    const double limitMsCapture = 2000;
#endif
    static const char kAlphabet[] = "<>:0123456789EORHABCDLMNSTxyz \r\n\t\x80\xC3\xBF-_.,{}";
    LintOptions chars;
    chars.lengthUnit = LengthUnit::Characters;
    for (int i = 0; i < iterations; ++i) {
        std::string t = seed;
        int edits = 1 + (int)(rng() % 20);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = kAlphabet[rng() % (sizeof kAlphabet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;  // truncation
            }
        }
        LintOptions o = (i & 1) ? chars : LintOptions{};
        o.buildModel = true;
        LintResult r = lint(t, o);
        checkInvariants(t, r, "mutation");
        checkModel(t, r, rng);
        std::string repaired = applyFixes(t, r.fixes);
        LintResult r2 = lint(repaired, (i & 1) ? chars : LintOptions{});
        checkInvariants(repaired, r2, "repaired");
        if (gFailures) break;
    }

    // Network replies (QRZ, eQSL, POTA spots), CSV and country files are untrusted too.
    const std::vector<std::string> replies = {
        "RESULT=FAIL&REASON=Unable%20to%20add%20QSO:%20duplicate&COUNT=0",
        "Result: 1 out of 2 records added<BR>Warning: Y=2026 M=10 D=06 Bad record: Duplicate<BR>Error: down<BR>",
        "RESULT=OK&COUNT=1&ADIF=&lt;call:4&gt;K1AE &lt;qso_date:8&gt;20261006 &#60;eor&#x3e; &amp;&#;&#99999999;",
        "<HTML>Your ADIF log file has been built<BR><A HREF=\"downloadedfiles/x.adi\">.ADI file</A>Error: No such Username</HTML>",
        "Call,Date,UTC,Freq (kHz),Mode\r\n\xEF\xBB\xBF\"W1AW\",2026-10-06,23:10,\"14,250\",SSB\r\n'K1AB;\"\"x\",,\n",
        "DL,Fed. Rep. of Germany,230,EU,14,28,51.00,-10.00,-1.0,DA DB =DL0ABC(14)[28]<51/-10>{EU}~-1~ DL/P;\n"
        "K,United States,291,NA,5,8,37.60,91.87,5.0,AA K N W =W1AW/7(3)[6];\n",
        "<StationDataFile>\n  <StationData name=\"Home &amp; QTH\">\n    <CALL>KW9D</CALL><DXCC>291</DXCC><GRIDSQUARE/>"
        "<US_STATE>IL</US_STATE><US_COUNTY>Cook &#233;&#x1F600;</US_COUNTY>\n  </StationData>\n</StationDataFile>\n"};
    static const char kNet[] = "<>/:&=%+ \r\n0123456789RPRTFrequency.-ABCDEFabcdef;\"";
    for (int i = 0; i < iterations * 4; ++i) {
        std::string t = replies[(size_t)i % replies.size()];
        int edits = 1 + (int)(rng() % 12);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = kNet[rng() % (sizeof kNet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;
            }
        }
        parseQrzReply(t);
        parseEqslReply(t);
        formDecode(t);
        hzToMHz(t.substr(0, 20));
        khzToMHz(t.substr(0, 20));
        spotFields(t.substr(0, 12), t.substr(0, 10), t.substr(0, 6), t.substr(0, 12));
        QrzReply qr;
        std::string page;
        parseQrzFetch(t, &qr, &page);
        htmlDecode(t);
        std::string error;
        eqslInboxLink(t, &error);
        importCsv(t);
        CountryTable table;
        table.load(t);
        CountryInfo ci;
        table.lookup(t.substr(0, 12), &ci);
        countryFields(table, t.substr(t.size() / 2, 10));
        gridDistanceText(t.substr(0, 6), t.substr(t.size() / 3, 8));
        for (Program p : {Program::WWFF, Program::SOTA}) programSpotFields(p, t.substr(0, 10), t.substr(0, 8), "CW", t.substr(0, 12));
        referenceSummary(t.substr(0, 14), ReferenceHistory());
        parseProfiles(t);
        {
            LotwUsers users;
            users.load(t);
            users.lastUpload(t.substr(0, 12));
        }
        for (const TqslLocation &loc : parseStationData(t)) {
            Record r;
            r.fields = {{"STATION_CALLSIGN", t.substr(0, 6)}, {"MY_GRIDSQUARE", t.substr(t.size() / 2, 6)}, {"MY_STATE", t.substr(0, 2)},
                        {"MY_CNTY", t.substr(0, 9)}, {"MY_CQ_ZONE", t.substr(0, 3)}};
            lotwLocationProblem(r, loc);
        }
        std::vector<std::string> bad;
        std::string why;
        for (Program p : {Program::POTA, Program::WWFF, Program::SOTA}) parseReferences(p, t.substr(0, 40), &bad, &why);
    }

    // Datagrams and TCP messages from other programs (Monitor): any bytes at all.
    const FieldList qso = {{"CALL", "K1AB"}, {"QSO_DATE", "20261009"}, {"TIME_ON", "235930"}, {"FREQ", "14.07415"},
                           {"MODE", "FT4"},  {"RST_SENT", "-10"},      {"NAME", "Ann"},       {"STATION_CALLSIGN", "KW9D"}};
    const std::string rec = "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:6>120000 <FREQ:9>14.074000 <MODE:3>FT8 <EOR>";
    const std::vector<std::string> captures = {
        wsjtxQsoLogged("WSJT-X", qso),
        wsjtxLoggedAdif("JTDX", "\n<adif_ver:5>3.1.0\n<programid:6>WSJT-X\n<EOH>\n" + rec),
        "<?xml version=\"1.0\"?><contactinfo><contestname>CQ-WW-CW</contestname><timestamp>2026-10-09 16:43:38</timestamp>"
        "<txfreq>352519</txfreq><mode>USB</mode><call>W1AW</call><power>100</power><ID>f9ff</ID></contactinfo>",
        "<?xml version=\"1.0\"?><contactdelete><call>W1AW</call><ID>f9ff</ID></contactdelete>",
        "<command:3>log<parameters:" + std::to_string(rec.size()) + ">" + rec + "\r\n",
        "ver\rdb add {CALL=\"K1AB\" QSO_DATE=\"20261009\" TIME_ON=\"120000\" FREQ=\"14074000\" MODE=\"FT8\" }\rexit\r",
        "ADD " + rec + rec,
        "{\"params\":{\"CALL\":\"K1AB\"},\"type\":\"LOG.QSO\",\"value\":\"" + rec + "\\u00e9\\ud83d\\ude00\\\"\"}"};
    for (int i = 0; i < iterations * 4; ++i) {
        std::string t = captures[(size_t)i % captures.size()];
        int edits = 1 + (int)(rng() % 12);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = (i & 1) ? (char)(rng() & 0xff) : kNet[rng() % (sizeof kNet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;
            }
        }
        for (const CapturedQso &q : parseCapture(t, "fuzz")) {
            bool named = true;
            for (const auto &f : q.fields)
                for (char c : f.first) named &= !(c >= 'a' && c <= 'z');
            bool complete = true;
            if (q.kind != CapturedQso::Kind::Delete && q.problem.empty())
                for (const char *n : {"CALL", "QSO_DATE", "TIME_ON", "MODE"}) {
                    bool has = false;
                    for (const auto &f : q.fields) has |= f.first == n && !f.second.empty();
                    complete &= has;
                }
            if (!named || !complete) {
                std::printf("FAIL capture: %s fields from %zu bytes\n", named ? "missing" : "lower-case", t.size());
                ++gFailures;
                break;
            }
        }
        parseLoggerCommand(t);
        parseN1mmXml(t);
        if (gFailures) break;
    }
    // IOTA's group list is downloaded text: whatever its strings, a group read from them has a
    // sane box, and its boxes stay within -180..180.
    {
        const std::vector<std::string> values = {"EU-005", "eu-5", "OC016", "AN-016", "-10.75", "178.25", "-175.25", "-180", "180", "90",
                                                 "-90", "0", "179.92", "-179.92", "", "1.5"};
        static const char kIota[] = "-.0123456789EUANOCSAF eu9";
        for (int i = 0; i < iterations * 4; ++i) {
            std::string f[7];
            for (std::string &v : f) {
                v = values[rng() % values.size()];
                if (rng() % 3 == 0 && !v.empty()) v[rng() % v.size()] = kIota[rng() % (sizeof kIota - 1)];
                if (rng() % 7 == 0) v.insert(rng() % (v.size() + 1), 1, kIota[rng() % (sizeof kIota - 1)]);
            }
            std::string ref = iotaRef(f[0]);
            bool refOk = ref.empty() || (ref.size() == 6 && ref[2] == '-');
            IotaGroup g;
            bool boxOk = true;
            if (iotaGroup(f[0], "x", f[1], f[2], f[3], f[4], f[5], &g)) {
                boxOk = g.south <= g.north && g.south >= -90 && g.north <= 90 && g.west >= -180 && g.west <= 180 && g.west <= g.east &&
                        g.east - g.west <= 360 && g.east <= 360;
                for (const auto &b : iotaBoxes(g)) boxOk &= b[0] >= -180 && b[2] <= 180 && b[0] <= b[2] && b[1] <= b[3];
            }
            if (!refOk || !boxOk) {
                std::printf("FAIL iota: %s %s %s %s %s %s\n", f[0].c_str(), f[2].c_str(), f[3].c_str(), f[4].c_str(), f[5].c_str(),
                            refOk ? "box" : "ref");
                ++gFailures;
                break;
            }
        }
    }
    // POTA's park list is downloaded text: whatever it holds, the parks read from it are in
    // order, each once, and placed only within the map.
    {
        const std::string parks = "\"reference\",\"name\",\"active\",\"entityId\",\"locationDesc\",\"latitude\",\"longitude\",\"grid\"\r\n"
                                  "\"US-0001\",\"Acadia, \"\"East\"\"\",\"1\",\"291\",\"US-ME\",\"44.31\",\"-68.2034\",\"FN54vh\"\r\n"
                                  "\"GB-0001\",\"Park\",\"0\",\"223\",\"GB-ENG\",\"54.7\",\"-1.47\",\"IO94\"\r\n"
                                  "\"US-4566\",\"Trail\",\"1\",\"291\",\"US-WY,US-ID\",\"0\",\"0\",\"\"\r\n";
        static const char kCsv[] = "\",\r\n-.0123456789USGB@ ";
        for (int i = 0; i < iterations * 4; ++i) {
            std::string t = parks;
            int edits = 1 + (int)(rng() % 10);
            for (int k = 0; k < edits && !t.empty(); ++k) {
                size_t at = rng() % t.size();
                char c = kCsv[rng() % (sizeof kCsv - 1)];
                switch (rng() % 3) {
                    case 0: t[at] = c; break;
                    case 1: t.insert(at, 1, c); break;
                    case 2: t.erase(at, 1 + rng() % 6); break;
                }
            }
            PotaParks pp;
            pp.load(t);
            bool ok = pp.active() <= pp.size();
            for (size_t k = 0; k < pp.size(); ++k) {
                const PotaPark &p = pp.parks()[k];
                ok &= (k == 0 || pp.parks()[k - 1].ref < p.ref) && pp.find(p.ref) == &p;
                if (p.placed) ok &= std::fabs(p.lat) <= 90 && std::fabs(p.lon) <= 180;
            }
            if (!ok) {
                std::printf("FAIL park list: %zu parks from %zu bytes\n", pp.size(), t.size());
                ++gFailures;
                break;
            }
        }
    }
    std::uniform_real_distribution<double> lon(-200, 200), lat(-100, 100);
    // Map detail files come from the network: PMTiles headers and directories, and vector
    // tiles, mutated, must be refused or read without crashing; geometry stays in bounds.
    {
        namespace pm = adif::pmtiles;
        std::vector<pm::Entry> dir;
        for (uint64_t k = 0; k < 40; ++k) dir.push_back({k * 3 + 1, k * 100, (uint32_t)(50 + k), (uint32_t)(k % 4)});
        const std::string goodDir = pm::directoryBytes(dir), goodHeader = pm::headerBytes(pm::Header{127, 60, 187, 10, 197, 0, 197, 4000});
        auto pv = [](std::string &s, uint64_t v) {
            while (v >= 0x80) s += (char)((v & 0x7f) | 0x80), v >>= 7;
            s += (char)v;
        };
        std::string feature, layer, tile, geom;
        for (uint32_t v : {9u, 0u, 0u, 26u, 20u, 0u, 0u, 20u, 19u, 0u, 15u}) pv(geom, v);
        pv(feature, 3 << 3), pv(feature, 3), pv(feature, 4 << 3 | 2), pv(feature, geom.size()), feature += geom;
        pv(layer, 1 << 3 | 2), pv(layer, 5), layer += "water", pv(layer, 2 << 3 | 2), pv(layer, feature.size()), layer += feature;
        pv(tile, 3 << 3 | 2), pv(tile, layer.size()), tile += layer;
        size_t decoded = 0;
        for (int k = 0; k < iterations * 4; ++k) {
            std::string d = goodDir, h = goodHeader, t = tile;
            for (std::string *x : {&d, &h, &t})
                for (int e = 1 + (int)(rng() % 4); e > 0; --e) {
                    size_t at = rng() % x->size();
                    switch (rng() % 3) {
                        case 0: (*x)[at] = (char)(rng() & 0xff); break;
                        case 1: x->erase(at, 1 + rng() % 4); break;
                        default: x->insert(at, 1, (char)(rng() & 0xff)); break;
                    }
                    if (x->empty()) *x = "x";
                }
            std::vector<pm::Entry> got;
            std::string why;
            pm::Header hh;
            pm::parseDirectory(d, &got, &why);
            for (size_t i = 1; i < got.size(); ++i)
                if (got[i].tileId <= got[i - 1].tileId) {
                    std::printf("FAIL pmtiles directory: tile ids out of order\n");
                    ++gFailures;
                    break;
                }
            pm::parseHeader(h, &hh, &why);
            std::vector<adif::mvt::Layer> ls;
            if (adif::mvt::decode(t, &ls, &why)) {
                ++decoded;
                for (const auto &l : ls)
                    for (const auto &f : l.features) {
                        std::vector<adif::mvt::Path> g;
                        adif::mvt::geometry(f, &g);
                        l.text(f, "kind");
                    }
            }
            std::string gz = pm::gzip(t), back;
            if (!pm::gunzip(gz, &back, 1 << 20, &why) || back != t) {
                std::printf("FAIL gzip round trip\n");
                ++gFailures;
                break;
            }
            std::vector<std::vector<std::pair<double, double>>> rings(1);
            for (int v = 0; v < 3 + (int)(rng() % 8); ++v) rings[0].push_back({lon(rng) * 0.9, lat(rng) * 0.85});
            std::vector<uint64_t> cover = pm::coveringTiles(rings, 0, 6);
            if (!std::is_sorted(cover.begin(), cover.end()) || cover.size() > 5461) {
                std::printf("FAIL covering tiles: %zu\n", cover.size());
                ++gFailures;
                break;
            }
        }
        std::printf("map detail files: %d mutations, %zu tiles still decoded\n", iterations * 4, decoded);
    }

    // A DX cluster's stream: telnet bytes in any chunks, spot lines mutated. Lines stay bounded and
    // printable, every refusal is a 3-byte IAC DONT/WONT, and a parsed spot is well formed.
    {
        const std::string good[] = {"DX de G4XYZ:     14285.0  M0TRT/P      SSB POTA GB-0001 tnx 73         1234Z\r\n",
                                    "DX de DJ9IE-#:    14034.9 UN7BBD       CW   4dB Q:5*+              17 1444Z 14\r\n",
                                    "DX de K1TTT:      7012.0  JA1XYZ       up 1 FN42                       0712Z FN32\r\n",
                                    "\xFF\xFB\x01\xFF\xFD\x18\xFF\xFA\x18\x01\xFF\xF0login: "};
        size_t spots = 0;
        for (int k = 0; k < iterations * 4; ++k) {
            std::string stream;
            for (int n = 0; n < 4; ++n) stream += good[rng() % 4];
            for (int e = 1 + (int)(rng() % 6); e > 0; --e) {
                size_t at = rng() % stream.size();
                switch (rng() % 3) {
                    case 0: stream[at] = (char)(rng() & 0xff); break;
                    case 1: stream.erase(at, 1 + rng() % 4); break;
                    default: stream.insert(at, 1, (char)(rng() & 0xff)); break;
                }
                if (stream.empty()) stream = "x";
            }
            adif::TelnetLines tl(200);
            std::vector<std::string> lines;
            std::string reply;
            for (size_t at = 0; at < stream.size();) {
                size_t n = 1 + rng() % 16;
                tl.feed(std::string_view(stream).substr(at, n), &lines, &reply);
                at += n;
            }
            bool ok = reply.size() % 3 == 0 && tl.pending().size() <= 200;
            for (size_t i = 0; i < reply.size(); i += 3) ok &= (unsigned char)reply[i] == 255 && ((unsigned char)reply[i + 1] == 254 || (unsigned char)reply[i + 1] == 252);
            for (const std::string &l : lines) {
                ok &= l.size() <= 200;
                for (unsigned char c : l) ok &= c >= 32 && c < 127;
                adif::Spot sp;
                if (adif::parseClusterSpot(l, 1791407517, &sp)) {
                    ++spots;
                    ok &= !sp.activator.empty() && !sp.spotter.empty() && !sp.khz.empty() && sp.epoch <= 1791407517 + 600 &&
                          sp.epoch > 1791407517 - 2 * 86400 && sp.time.size() == 5;
                }
                adif::clusterPrompt(l);
            }
            if (!ok) {
                std::printf("FAIL cluster stream: %s\n", stream.c_str());
                ++gFailures;
                break;
            }
        }
        std::printf("cluster streams: %d mutated, %zu spots still read\n", iterations * 4, spots);
        // PSKReporter's answer, mutated: reports stay bounded and well formed.
        const std::string xml = "<receptionReports currentSeconds=\"1791407517\"><receptionReport receiverCallsign='JA1XYZ' "
                                "receiverLocator='PM95vq' senderCallsign='K9ABC' frequency='7074123' flowStartSeconds='1791407400' "
                                "mode='FT8' sNR='-12' /><receptionReport receiverCallsign=\"KB1MBX\" frequency=14070987 "
                                "flowStartSeconds=1791407000 /></receptionReports>";
        size_t reports = 0;
        for (int k = 0; k < iterations * 4; ++k) {
            std::string x = xml;
            for (int e = 1 + (int)(rng() % 6); e > 0; --e) {
                size_t at = rng() % x.size();
                switch (rng() % 3) {
                    case 0: x[at] = (char)(rng() & 0xff); break;
                    case 1: x.erase(at, 1 + rng() % 4); break;
                    default: x.insert(at, 1, (char)(rng() & 0xff)); break;
                }
                if (x.empty()) x = "x";
            }
            std::vector<adif::Spot> got;
            std::string why;
            adif::parsePskReports(x, &got, &why, 5, (k & 1) ? "K9TST" : "");  // as a spot site gives it, or asked by a callsign
            bool ok = got.size() <= 5;
            for (const adif::Spot &sp : got) {
                ok &= !sp.activator.empty() && sp.activator.size() <= 20 && !sp.khz.empty() && sp.epoch > 0;
                for (unsigned char c : sp.activator + sp.spotter + sp.grid + sp.mode) ok &= c >= 32 && c < 127;
            }
            reports += got.size();
            if (!ok) {
                std::printf("FAIL PSKReporter reports: %s\n", x.c_str());
                ++gFailures;
                break;
            }
        }
        std::printf("PSKReporter answers: %d mutated, %zu reports still read\n", iterations * 4, reports);
    }

    // Park outlines' sources, mutated (Overpass, GeoJSON, ArcGIS JSON, and the cache file): no
    // crash, every outline a shaped reference with closed rings of real coordinates; deep or
    // huge JSON refused quickly.
    {
        const std::string seeds[] = {
            "{\"elements\":[{\"type\":\"way\",\"geometry\":[{\"lat\":0,\"lon\":0},{\"lat\":0,\"lon\":1},{\"lat\":1,\"lon\":1},{\"lat\":0,\"lon\":0}],"
            "\"tags\":{\"communication:amateur_radio:pota\":\"US-0001;US-0002\"}},{\"type\":\"relation\",\"members\":[{\"type\":\"way\",\"geometry\":"
            "[{\"lat\":5,\"lon\":5},{\"lat\":5,\"lon\":6}]},{\"type\":\"way\",\"geometry\":[{\"lat\":5,\"lon\":6},{\"lat\":6,\"lon\":6},{\"lat\":5,\"lon\":5}]}],"
            "\"tags\":{\"communication:amateur_radio:pota\":\"DE-0003\"}}]}",
            "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"id\":\"LI-0001\"},\"geometry\":{\"type\":\"MultiPolygon\",\"coordinates\":"
            "[[[[9,47],[9.1,47],[9.1,47.1],[9,47]]]]}},{\"properties\":{\"id\":\"LI-0002\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":"
            "[[[8,46],[8.1,46],[8.1,46.1],[8,46]]]}}]}",
            "{\"features\":[{\"attributes\":{\"Unit_Nm\":\"Beall Woods\",\"Des_Tp\":\"SP\"},\"geometry\":{\"rings\":[[[-87.8,38.3],[-87.7,38.3],"
            "[-87.7,38.4],[-87.8,38.3]]]}}],\"exceededTransferLimit\":true}",
            "# ADIF Lint park outlines 1\nP\tUS-0001\tOSM\t0\tA Park\nR 0,0 100000,0 100000,100000 0,0\n"};
        size_t outlines = 0;
        auto check = [&](const std::vector<adif::ParkOutline> &got, const std::string &x) {
            for (const adif::ParkOutline &o : got) {
                bool ok = adif::potaRefShaped(o.ref) && !o.rings.empty();
                for (const adif::OutlineRing &r : o.rings) {
                    ok &= r.size() >= 4 && r.front() == r.back();
                    for (const adif::OutlinePoint &p : r) ok &= std::fabs(p.first) <= 180 && std::fabs(p.second) <= 90;
                }
                if (!ok) {
                    std::printf("FAIL park outline from: %s\n", x.c_str());
                    ++gFailures;
                    return false;
                }
                adif::inOutline(o, 0.5, 0.5);
                adif::outlineDistanceKm(o.rings, 0.5, 0.5);
            }
            outlines += got.size();
            return true;
        };
        for (int k = 0; k < iterations * 8; ++k) {
            std::string x = seeds[k % 4];
            for (int e = 1 + (int)(rng() % 6); e > 0; --e) {
                size_t at = rng() % x.size();
                switch (rng() % 3) {
                    case 0: x[at] = (char)(rng() & 0xff); break;
                    case 1: x.erase(at, 1 + rng() % 4); break;
                    default: x.insert(at, 1, (char)(rng() & 0xff)); break;
                }
                if (x.empty()) x = "x";
            }
            std::vector<adif::ParkOutline> got;
            std::vector<adif::PadUnit> units;
            std::string why;
            bool more = false;
            bool ok = true;
            switch (k % 4) {
                case 0: adif::overpassOutlines(x, &got, &why), ok = check(got, x); break;
                case 1: adif::geojsonOutlines(x, "pota-map.info", &got, &why), ok = check(got, x); break;
                case 2:
                    adif::arcgisUnits(x, &units, &more, &why);
                    ok = check(adif::matchPadUnits({{"US-0001", "Beall Woods State Park", 38.35, -87.75}}, units), x);
                    break;
                default: adif::readOutlines(x, &got, &why), ok = check(got, x); break;
            }
            if (!ok) break;
        }
        // Hostile JSON: very deep, very long; refused or read quickly.
        auto start = std::chrono::steady_clock::now();
        adif::json::Value v;
        std::string why;
        bool deep = adif::json::parse(std::string(200000, '[') + std::string(200000, ']'), &v, &why);
        std::string longArray = "[";
        for (int i = 0; i < 400000; ++i) longArray += i ? ",[1.5,2.5]" : "[1.5,2.5]";
        longArray += "]";
        bool wide = adif::json::parse(longArray, &v, &why) && v.stride == 2 && v.size() == 400000;
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        if (deep || !wide || secs > 5) {
            std::printf("FAIL hostile JSON: deep %d, wide %d, %.1f s\n", deep, wide, secs);
            ++gFailures;
        }
        std::printf("park outline sources: %d mutated, %zu outlines still read; hostile JSON in %.2f s\n", iterations * 8, outlines, secs);
    }

    // The Map's worked areas: the area at any point (also off the Earth and across the 180th
    // meridian) is one whose box holds it, and the place filters on random records and
    // random filters never keep a QSO outside them.
    {
        for (Overlay o : {Overlay::UsStates, Overlay::UsCounties, Overlay::CqZones, Overlay::ItuZones}) {
            const AreaIndex &index = areaIndex(o);
            for (int k = 0; k < iterations * 4; ++k) {
                double x = lon(rng), y = lat(rng);
                size_t at = index.at(x, y);
                if (at != AreaIndex::npos && (at >= index.size() || !pointInRings(index.area(at).rings, x, y))) {
                    std::printf("FAIL area index: overlay %d at %.4f, %.4f gave %zu\n", (int)o, x, y, at);
                    ++gFailures;
                    break;
                }
            }
        }
        static const char *const kStates[] = {"WI", "IL", "CA", "NY", "TX", "AK", "HI", "ZZ", "wi", ""};
        static const char *const kCounties[] = {"WI,Dane", "IL,LaSalle", "MO,St. Louis", "CA,Nowhere", "", ",", "WI,"};
        static const char *const kGrids[] = {"EN53", "EN53dc", "FN31pr", "DM79", "AA00", "JJ00aa", "RR99xx", "", "EN5"};
        static const char *const kConts[] = {"NA", "EU", "AS", "XX", ""};
        auto field = [](const char *name, const std::string &v) { return "<" + std::string(name) + ":" + std::to_string(v.size()) + ">" + v + " "; };
        const std::vector<UsRegion> &regions = usRegions();
        int runs = 0, narrowed = 0;  // filters that kept some QSOs but not all
        for (int k = 0; k < iterations / 4 + 1; ++k) {
            std::string log = "fuzz\n<EOH>\n";
            for (int r = 0; r < 20; ++r) {
                log += field("CALL", "K" + std::to_string(rng() % 10) + "AB") + field("QSO_DATE", "20260101") + field("BAND", "20m") +
                       field("MODE", "CW");
                if (rng() % 2) log += field("GRIDSQUARE", kGrids[rng() % (sizeof kGrids / sizeof *kGrids)]);
                if (rng() % 2) log += field("STATE", kStates[rng() % (sizeof kStates / sizeof *kStates)]);
                if (rng() % 2) log += field("CNTY", kCounties[rng() % (sizeof kCounties / sizeof *kCounties)]);
                if (rng() % 5) log += field("DXCC", std::to_string(rng() % 4 ? 291 : rng() % 600));
                if (rng() % 3 == 0) log += field("CQZ", std::to_string(rng() % 45));
                if (rng() % 3 == 0) log += field("ITUZ", std::to_string(rng() % 95));
                if (rng() % 3 == 0) log += field("CONT", kConts[rng() % (sizeof kConts / sizeof *kConts)]);
                if (rng() % 4 == 0) log += field("LAT", "N043 04.200") + field("LON", "W089 24.000");
                if (rng() % 4 == 0) log += field("ARRL_SECT", rng() % 2 ? "ENY" : "SV");
                log += "<EOR>\n";
            }
            MapFilter f;  // about two kinds of place each
            if (rng() % 4 == 0) f.continents.insert(kConts[rng() % (sizeof kConts / sizeof *kConts)]);
            if (rng() % 4 == 0) f.dxcc.insert(rng() % 2 ? 291 : (int)(rng() % 600));
            if (rng() % 4 == 0) f.cq.insert((int)(rng() % 45));
            if (rng() % 4 == 0) f.itu.insert((int)(rng() % 95));
            if (rng() % 4 == 0) f.states.insert(kStates[rng() % (sizeof kStates / sizeof *kStates)]);
            if (rng() % 4 == 0) f.counties.insert(kCounties[rng() % (sizeof kCounties / sizeof *kCounties)]);
            if (rng() % 4 == 0) f.regions.insert(rng() % 5 ? regions[rng() % regions.size()].id : std::string("nonsense"));
            if (rng() % 4 == 0) f.potaLocations.insert("US-WI");
            LintOptions withModel;
            withModel.buildModel = true;
            LintResult r = lint(log, withModel);
            MapData all = mapData(log, r.model, MapFilter{}), kept = mapData(log, r.model, f);
            size_t matching = 0;  // the filter keeps exactly the QSOs whose places match it
            for (const MapQso &q : all.qsos) matching += placeMatches(f, q, nullptr);
            bool ok = kept.qsos.size() == matching;
            ++runs, narrowed += !kept.qsos.empty() && kept.qsos.size() < all.qsos.size();
            for (const MapQso &q : kept.qsos) ok &= placeMatches(f, q, nullptr);
            if (!ok) {
                std::printf("FAIL place filters: %zu of %zu kept\n", kept.qsos.size(), all.qsos.size());
                ++gFailures;
                break;
            }
        }
        std::printf("place filters: %d logs, %d narrowed\n", runs, narrowed);
    }
    {
        auto t0 = std::chrono::steady_clock::now();
        for (const std::string &s : {std::string(1 << 16, '<'), std::string(1 << 16, '&'), [] {
                 std::string x = "<contactinfo>";
                 while (x.size() < (1u << 16)) x += "<call>";
                 return x;
             }()})
            for (int k = 0; k < 4; ++k) parseCapture(s, "fuzz");
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("%-26s %6.1f ms\n", "hostile datagrams", ms);
        if (ms > limitMsCapture) {
            std::printf("FAIL hostile datagrams: %.0f ms is too slow\n", ms);
            ++gFailures;
        }
    }

    // Hostile shapes, ~2 MB each: these must stay well under a second in a release build.
    // The unoptimised ASan+UBSan build runs about 25 times slower, so it gets more time;
    // a quadratic slowdown would still blow far past either limit.
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ADIF_FUZZ_SANITIZED 1
#endif
#endif
#ifdef ADIF_FUZZ_SANITIZED
    const double limitMs = 10000;
#else
    const double limitMs = 3000;
#endif
    const size_t big = 2u << 20;
    struct Case { const char *name; std::string text; LintOptions opt; };
    Case cases[] = {
        {"all '<'", std::string(big, '<'), {}},
        {"unclosed tags", [&] { std::string s; while (s.size() < big) s += "<CALL:4 "; return s; }(), {}},
        {"tiny fields", [&] { std::string s; while (s.size() < big) s += "<A:1>x"; return s; }(), {}},
        {"lengths too long (bytes)", [&] { std::string s; while (s.size() < big) s += "<NOTES:99999>x\n"; return s; }(), {}},
        {"lengths too long (chars)", [&] { std::string s; while (s.size() < big) s += "<NOTES:99999>\xC3\xBC\n"; return s; }(), chars},
        {"one huge value", "x<EOH><NOTES:" + std::to_string(big) + ">" + std::string(big, 'a') + "<EOR>", {}},
        {"diagnostic flood", [&] { std::string s = "x<EOH>"; while (s.size() < big) s += "<BAND:3>99m<EOR>"; return s; }(), {}},
    };
    for (Case &c : cases) {
        double ms = lintMs(c.text, c.opt);
        std::printf("%-26s %6.1f ms\n", c.name, ms);
        if (ms > limitMs) {
            std::printf("FAIL %s: %.0f ms is too slow\n", c.name, ms);
            ++gFailures;
        }
    }

    std::printf("%d mutation iterations, %s\n", iterations, gFailures ? "FAILED" : "ok");
    return gFailures ? 1 : 0;
}
