// Tests for ADX validation (adif_adx.h).
//
// Expected results come from the ADIF 3.1.8 text (§IV.B and its subsections) and
// the published schemas (spec/adx/), not from the implementation. The official ADX
// test-QSO file must check clean, and values built from the spec tables go through
// both the schemas and lint() on ADI, whose verdicts must agree or differ only in
// the ways docs/ADIF_CONFORMANCE.md lists.
//
//   adx_tests OFFICIAL.adx
#include "adif_adx.h"
#include "adif_lint.h"
#include "adif_spec.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <random>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace adif;

static int gFailures = 0, gChecks = 0;

#define CHECK(cond, ...)                                    \
    do {                                                    \
        ++gChecks;                                          \
        if (!(cond)) {                                      \
            ++gFailures;                                    \
            std::printf("FAIL %s:%d: ", __FILE__, __LINE__); \
            std::printf(__VA_ARGS__);                       \
            std::printf("\n");                              \
        }                                                   \
    } while (0)

static std::string dump(const std::string &text, const LintResult &r) {
    std::string s;
    for (const Diagnostic &d : r.diagnostics)
        s += std::string("    ") + severityName(d.severity) + " [" + d.code + "] '" + text.substr(d.start, std::min<size_t>(d.end - d.start, 40)) +
             "': " + d.message + "\n";
    return s;
}

static std::string esc(const std::string &v) {
    std::string o;
    for (char c : v) o += c == '&' ? "&amp;" : c == '<' ? "&lt;" : c == '>' ? "&gt;" : std::string(1, c);
    return o;
}

static const char kDecl[] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
static const char kMinimum[] = "<QSO_DATE>20240115</QSO_DATE><TIME_ON>1830</TIME_ON><CALL>WF1B</CALL><BAND>20m</BAND><MODE>CW</MODE>";

// An ADX document: the header's content, then records holding the guideline minimum plus each extra.
static std::string adx(const std::string &header, const std::vector<std::string> &extras) {
    std::string s = std::string(kDecl) + "<ADX>\n<HEADER>" + header + "</HEADER>\n<RECORDS>\n";
    for (const std::string &e : extras) s += std::string("<RECORD>") + kMinimum + e + "</RECORD>\n";
    return s + "</RECORDS>\n</ADX>\n";
}
static std::string adx318(const std::string &extra) { return adx("<ADIF_VER>3.1.8</ADIF_VER>", {extra}); }

struct Found {
    const Diagnostic *d = nullptr;
    size_t n = 0;
};

// Diagnostics of `sev` and `code` whose message has `needle`.
static Found find(const LintResult &r, Severity sev, const char *code, const char *needle = "") {
    Found f;
    for (const Diagnostic &d : r.diagnostics)
        if (d.severity == sev && d.code == code && d.message.find(needle) != std::string::npos) {
            if (!f.d) f.d = &d;
            ++f.n;
        }
    return f;
}

// Exactly `n` such diagnostics, the first on the text `at` (when given).
static void expect(const char *name, const std::string &text, const LintResult &r, Severity sev, const char *code, const char *needle,
                   const char *at = nullptr, size_t n = 1) {
    Found f = find(r, sev, code, needle);
    CHECK(f.n == n, "%s: expected %zu %s [%s] with \"%s\", got %zu\n%s", name, n, severityName(sev), code, needle, f.n, dump(text, r).c_str());
    if (f.d && at) {
        std::string got = text.substr(f.d->start, f.d->end - f.d->start);
        CHECK(got == at, "%s: on '%s', expected '%s'", name, got.c_str(), at);
    }
}

static void expectClean(const char *name, const std::string &text, const LintResult &r) {
    CHECK(r.errors == 0 && r.warnings == 0, "%s: expected no errors or warnings\n%s", name, dump(text, r).c_str());
}

static std::string readFile(const char *path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// ── The built-in schemas ────────────────────────────────────────────────────

static void testSchemas() {
    size_t n = 0;
    const AdxSchema *s = adxSchemas(&n);
    // Every version from 3.0.3 publishes an export and a generic schema; 3.0.2 and earlier none (spec/adx/SOURCE.md).
    CHECK(n == 32, "built-in schemas: %zu", n);
    std::set<std::string> versions;
    for (size_t i = 0; i < n; ++i) {
        versions.insert(s[i].version);
        std::string problem = adxSchemaProblem(s[i]);
        CHECK(problem.empty(), "%s does not compile: %s", s[i].file, problem.c_str());
        CHECK(std::string(s[i].file) == std::string("adx") + s[i].version[0] + s[i].version[2] + s[i].version[4] + (s[i].generic ? "generic" : "") + ".xsd",
              "schema name %s for %s", s[i].file, s[i].version);
        // XML Schema 1.0 has no (?...) groups (Part 2, Appendix F); the generator restates the one that had.
        bool lookahead = false;
        for (const char *p = std::strstr(s[i].text, "<xs:pattern value=\""); p; p = std::strstr(p + 1, "<xs:pattern value=\"")) {
            const char *v = p + 19, *e = std::strchr(v, '"');
            lookahead |= e && std::string(v, e).find("(?") != std::string::npos;
        }
        CHECK(!lookahead, "%s has a pattern with (?...)", s[i].file);
    }
    CHECK(versions.size() == 16 && *versions.begin() == "3.0.3" && *versions.rbegin() == "3.1.8", "versions: %zu", versions.size());
}

static void testDetection() {
    CHECK(isAdx("<?xml version=\"1.0\"?><ADX/>"), "XML declaration");
    CHECK(isAdx("\xEF\xBB\xBF \r\n<ADX>"), "BOM, white space, root");
    CHECK(isAdx("<!-- exported -->\n<ADX>"), "comment first");
    CHECK(isAdx("<adx>"), "root in lower case is still ADX, to be reported");
    CHECK(!isAdx("Exported by X\n<ADIF_VER:5>3.1.8<EOH>"), "ADI with a header");
    CHECK(!isAdx("<CALL:4>W1AW<EOR>"), "ADI without a header");
    CHECK(!isAdx("<ADXX:1>a"), "a field named like ADX");
    CHECK(!isAdx(""), "empty");

    CHECK(std::string(adxSchemaVersion("3.1.8", "3.1.4")) == "3.1.8", "the declared version");
    CHECK(std::string(adxSchemaVersion(" 3.0.7 ", "")) == "3.0.7", "trimmed");
    CHECK(std::string(adxSchemaVersion("3.0.2", "3.1.8")) == "3.0.3", "3.0.2 has none: the oldest");
    CHECK(std::string(adxSchemaVersion("3.1.9", "3.1.4")) == "3.1.8", "a newer version: the newest");
    CHECK(std::string(adxSchemaVersion("", "3.1.4")) == "3.1.4", "none: Settings");
    CHECK(std::string(adxSchemaVersion("3.1", "3.0.2")) == "3.0.3", "not X.Y.Z: Settings, or the nearest");
    CHECK(std::string(adxSchemaVersion("", "")) == "3.1.8", "nothing to go on: the newest");
}

// ── The official file ───────────────────────────────────────────────────────

static void testOfficialFile(const char *path) {
    std::string text = readFile(path);
    CHECK(text.size() > 1000000, "official ADX file missing or short: %s", path);
    LintResult r = lintAdx(text);
    CHECK(r.errors == 0 && r.warnings == 0, "official ADX file: %zu errors, %zu warnings\n%s", r.errors, r.warnings, dump(text, r).substr(0, 4000).c_str());
    CHECK(r.records == 6202 && r.hasHeader, "official ADX records: %zu", r.records);
    CHECK(r.schemaVersion == "3.1.8" && r.schemaErrors == 0 && r.schemaWarnings == 0 && r.schemaInfos == 0, "official ADX schema: %s %zu/%zu/%zu",
          r.schemaVersion.c_str(), r.schemaErrors, r.schemaWarnings, r.schemaInfos);
    CHECK(r.fixes.empty() && r.model.fields.empty(), "ADX has no length fixes and no model");

    // One wrong band among 6,202 records: the schema and ADIF Lint both find it, on the value.
    std::string bad = text;
    size_t at = bad.find("<BAND>20m</BAND>", bad.size() / 2);
    CHECK(at != std::string::npos, "a 20m band in the official file");
    bad.replace(at + 6, 3, "21m");
    r = lintAdx(bad);
    expect("official, bad band", bad, r, Severity::Error, "schema", "BAND '21m'", "21m");
    CHECK(r.errors == 2 && r.warnings == 0, "official, bad band: %zu errors, %zu warnings\n%s", r.errors, r.warnings, dump(bad, r).c_str());
}

// ── XML: well-formedness and §IV.B.1 ────────────────────────────────────────

static void testXml() {
    {
        std::string t = std::string(kDecl) + "<ADX><HEADER/><RECORDS><RECORD><CALL>W1AW</CALL>\n<BAND>20m</RECORD></RECORDS></ADX>\n";
        LintResult r = lintAdx(t);
        // Only the first error: the rest follow from it.
        expect("mismatched tags", t, r, Severity::Error, "xml", "Opening and ending tag mismatch", "</RECORD>");
        CHECK(r.diagnostics.size() == 1 && r.structuralErrors == 1 && r.schemaVersion.empty(), "mismatched tags: one structural error\n%s",
              dump(t, r).c_str());
    }
    {
        std::string t = std::string(kDecl) + "<ADX><HEADER/><RECORDS><RECORD><BAND>&topband;</BAND></RECORD></RECORDS></ADX>\n";
        expect("undeclared entity", t, lintAdx(t), Severity::Error, "xml", "only the entities XML predefines", "&topband;");
    }
    {
        std::string t = std::string(kDecl) + "<ADX><HEADER/><RECORDS><RECORD><NAME>Jos\xE9</NAME></RECORD></RECORDS></ADX>\n";
        expect("Latin-1 byte", t, lintAdx(t), Severity::Error, "xml", "UTF-8");
    }
    {
        LintResult r = lintAdx("");
        CHECK(r.diagnostics.empty() && r.schemaVersion.empty(), "empty text: nothing to point at\n%s", dump("", r).c_str());
        std::string t = " \n";
        r = lintAdx(t);
        CHECK(r.errors == 1 && r.diagnostics.size() == 1 && r.diagnostics[0].code == "xml" && r.diagnostics[0].end <= t.size(),
              "white space only: not XML\n%s", dump(t, r).c_str());
    }
    {
        std::string t = std::string(kDecl) + "<!DOCTYPE ADX [<!ENTITY topband \"160m\">]>\n" + adx318("<COMMENT>on &topband;</COMMENT>").substr(sizeof kDecl - 1);
        LintResult r = lintAdx(t);
        expect("DOCTYPE", t, r, Severity::Error, "adx-doctype", "document type declaration", "<!DOCTYPE ADX [<!ENTITY topband \"160m\">]>");
        expect("declared entity", t, r, Severity::Error, "adx-entity", "&topband; is not allowed", "&topband;");
        // The rest is still validated: libxml2 cannot validate entity references, so they are kept as written.
        CHECK(find(r, Severity::Error, "schema", "could not be applied").n == 0, "entities do not stop the schema\n%s", dump(t, r).c_str());
    }
    {
        // An entity bomb: libxml2 refuses it before any expansion, and the finding is on the declarations.
        std::string t = std::string(kDecl) + "<!DOCTYPE ADX [<!ENTITY a \"aaaaaaaaaa\">";
        for (char c = 'b'; c <= 'j'; ++c) {
            t += std::string("<!ENTITY ") + c + " \"";
            for (int k = 0; k < 10; ++k) t += std::string("&") + char(c - 1) + ";";
            t += "\">";
        }
        t += "]>\n" + adx318("<COMMENT>&j;</COMMENT>").substr(sizeof kDecl - 1);
        LintResult r = lintAdx(t);
        expect("entity bomb", t, r, Severity::Error, "xml", "entity reference loop");
        CHECK(r.diagnostics.size() == 1 && t.compare(r.diagnostics[0].start, 9, "<!DOCTYPE") == 0, "entity bomb: on the DOCTYPE\n%s", dump(t, r).c_str());
    }
    {
        std::string t = adx318("<COMMENT><![CDATA[a < b]]></COMMENT>");
        expect("CDATA in a field", t, lintAdx(t), Severity::Error, "adx-cdata", "CDATA section", "<![CDATA[");
        std::string m = adx318("<![CDATA[ notes between fields ]]>");
        expectClean("CDATA between fields (RECORD is mixed content)", m, lintAdx(m));
    }
    {
        // §IV.B.1: processing instructions and namespaces are ignored; comments are XML's own.
        std::string t = std::string(kDecl) + "<?xml-stylesheet type=\"text/xsl\" href=\"log.xsl\"?>\n<!-- exported -->\n"
                        "<ADX xmlns=\"http://example.org/adx\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                        "xsi:noNamespaceSchemaLocation=\"adx318.xsd\"><HEADER><ADIF_VER>3.1.8</ADIF_VER></HEADER><RECORDS><RECORD>" +
                        kMinimum + "<!-- a note --><?app hint?></RECORD></RECORDS></ADX>\n";
        expectClean("namespaces, PIs and comments", t, lintAdx(t));
    }
    {
        std::string t = std::string("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n") + adx318("").substr(sizeof kDecl - 1);
        expect("declared encoding", t, lintAdx(t), Severity::Error, "adx-encoding", "this one declares ISO-8859-1", "encoding=\"ISO-8859-1\"");
    }
    {
        std::string t = adx318("<call>K1ABC</call>");
        expect("lower-case element", t, lintAdx(t), Severity::Error, "schema", "names are upper case in ADX", "call");
    }
}

// ── The schemas' findings ───────────────────────────────────────────────────

static void testSchemaFindings() {
    std::string t = adx318("");
    t.replace(t.find("<BAND>20m</BAND>"), 16, "<BAND>21m</BAND>");
    LintResult r = lintAdx(t);
    expect("bad band: schema", t, r, Severity::Error, "schema", "BAND '21m' is not allowed", "21m");
    CHECK(find(r, Severity::Error, "enumeration", "not a valid BAND").n == 1, "bad band: ADIF Lint too, reported apart\n%s", dump(t, r).c_str());
    CHECK(r.schemaErrors == 1 && r.errors == 2, "bad band: the counts keep the checks apart: %zu of %zu", r.schemaErrors, r.errors);

    t = adx318("<FOO>bar</FOO>");
    r = lintAdx(t);
    expect("unknown element: schema", t, r, Severity::Error, "schema", "FOO is not allowed here", "FOO");
    expect("unknown element: lint", t, r, Severity::Warning, "unknown-field", "Fields of your own are APP or USERDEF elements", "FOO");

    // Import-only (deprecated): fine to read, so a warning, from adx318.xsd and the spec tables alike.
    t = adx318("<VE_PROV>ON</VE_PROV>");
    r = lintAdx(t);
    expect("deprecated field", t, r, Severity::Warning, "schema-export", "Import only in ADIF 3.1.8", "VE_PROV");
    CHECK(r.schemaErrors == 0, "deprecated field is no error\n%s", dump(t, r).c_str());
    t = adx318("<ANT_AZ>370</ANT_AZ>");
    expect("ANT_AZ outside 0-360", t, lintAdx(t), Severity::Warning, "schema-export", "greater than 360", "370");

    // Only adx318.xsd has AGE's range (the generic schema covers 3.0.2 on): an error all the same.
    t = adx318("<AGE>121</AGE>");
    r = lintAdx(t);
    expect("AGE 121", t, r, Severity::Error, "schema", "AGE 121 is greater than 120", "121");
    CHECK(std::strstr(find(r, Severity::Error, "schema", "AGE").d ? find(r, Severity::Error, "schema", "AGE").d->message.c_str() : "", "adx318.xsd"),
          "AGE 121 is adx318.xsd's finding\n%s", dump(t, r).c_str());

    t = adx318("<AGE/>");
    expect("empty Number", t, lintAdx(t), Severity::Error, "schema", "AGE is empty", "<AGE/>");
    t = adx("<ADIF_VER>3.1.8</ADIF_VER>stray", {""});
    expect("text in HEADER", t, lintAdx(t), Severity::Error, "schema", "HEADER may hold elements but not text", "HEADER");
    t = std::string(kDecl) + "<ADX><RECORDS/></ADX>";
    expect("no HEADER", t, lintAdx(t), Severity::Error, "schema", "Expected: HEADER", "RECORDS");
    t = std::string(kDecl) + "<adx><HEADER/><RECORDS/></adx>";
    expect("root", t, lintAdx(t), Severity::Error, "schema", "root element must be ADX", "adx");
    t = adx318("<NAME>Bob<B>x</B></NAME>");
    expect("element in a field", t, lintAdx(t), Severity::Error, "schema", "NAME may hold text but not elements");
}

// ── User-defined and application-defined fields (§IV.B.2, §IV.B.3) ──────────

static void testUserAndAppFields() {
    const std::string defs = "<ADIF_VER>3.1.8</ADIF_VER>"
                             "<USERDEF FIELDID=\"1\" TYPE=\"E\" ENUM=\"{S,M,L}\">SWEATERSIZE</USERDEF>"
                             "<USERDEF FIELDID=\"2\" TYPE=\"N\" RANGE=\"{5:20}\">SHOESIZE</USERDEF>"
                             "<USERDEF FIELDID=\"3\" TYPE=\"S\">NOTE</USERDEF>"
                             "<USERDEF FIELDID=\"4\" TYPE=\"I\">NOTE_INTL</USERDEF>";
    std::string t = adx(defs, {"<USERDEF FIELDNAME=\"SWEATERSIZE\">M</USERDEF><USERDEF FIELDNAME=\"SHOESIZE\">11</USERDEF>"
                               "<USERDEF FIELDNAME=\"NOTE_INTL\">Alen\xC3\xA7on</USERDEF>"
                               "<APP PROGRAMID=\"MONOLOG\" FIELDNAME=\"COMPRESSION\" TYPE=\"s\">off</APP><NAME_INTL>Jos\xC3\xA9</NAME_INTL>"});
    expectClean("the spec's own user and app fields", t, lintAdx(t));

    t = adx(defs, {"<USERDEF FIELDNAME=\"SHOESIZE\">25</USERDEF><USERDEF FIELDNAME=\"SWEATERSIZE\">XL</USERDEF>"});
    LintResult r = lintAdx(t);
    // The schemas do not check a record's USERDEF against its definition; ADIF Lint does.
    CHECK(find(r, Severity::Error, "range", "SHOESIZE").n == 1 && find(r, Severity::Error, "userdef-value", "S, M, L").n == 1 && r.schemaErrors == 0,
          "user fields against their definitions\n%s", dump(t, r).c_str());

    // §IV.B.3's example writes FIELDNAME="SweaterSize": field names are case-insensitive, though the schemas want upper case.
    t = adx(defs, {"<USERDEF FIELDNAME=\"SweaterSize\">XL</USERDEF>"});
    r = lintAdx(t);
    expect("mixed-case FIELDNAME", t, r, Severity::Warning, "schema-strict", "wants a record's USERDEF FIELDNAME in upper case, SWEATERSIZE",
           "FIELDNAME=\"SweaterSize\"");
    CHECK(find(r, Severity::Error, "userdef-value", "S, M, L").n == 1 && r.schemaErrors == 0, "mixed-case FIELDNAME still checked\n%s", dump(t, r).c_str());

    // §IV.B.3: "If a Data Type Indicator is included in a user defined field in a Record, [it] is ignored."
    t = adx(defs, {"<USERDEF FIELDNAME=\"NOTE\" TYPE=\"N\">x</USERDEF>"});
    r = lintAdx(t);
    expect("TYPE on a record's USERDEF", t, r, Severity::Warning, "schema-strict", "says it is ignored there", "TYPE=\"N\"");
    CHECK(r.errors == 0, "the ignored TYPE is no error\n%s", dump(t, r).c_str());

    t = adx("<USERDEF FIELDID=\"1\" TYPE=\"E\" ENUM=\"{S,M,L}\" RANGE=\"{1:5}\">SIZE</USERDEF>", {""});
    expect("ENUM and RANGE", t, lintAdx(t), Severity::Error, "userdef-enum-range", "both ENUM and RANGE", "RANGE=\"{1:5}\"");
    t = adx("<USERDEF FIELDID=\"0\" TYPE=\"N\">ZERO</USERDEF>", {""});
    expect("FIELDID 0 (unsignedInt allows it, §IV.B.3 does not)", t, lintAdx(t), Severity::Warning, "userdef-id", "positive integer", "FIELDID=\"0\"");
    t = adx("<ADIF_VER>3.1.8</ADIF_VER>", {"<USERDEF FIELDNAME=\"UNDEFINED\">1</USERDEF>"});
    expect("undefined user field", t, lintAdx(t), Severity::Warning, "unknown-field", "not defined in the header");
    t = adx(defs, {"<USERDEF FIELDNAME=\"NOTE_INTL\">two\nlines</USERDEF>"});
    expect("IntlString user field", t, lintAdx(t), Severity::Error, "intl-line-break", "may not contain line breaks", "two\nlines");
    t = adx(defs, {"<USERDEF FIELDNAME=\"NOTE\">caf\xC3\xA9</USERDEF>"});
    expect("String user field", t, lintAdx(t), Severity::Error, "non-ascii", "only _INTL fields and the Intl types", "caf\xC3\xA9");

    t = adx318("<APP PROGRAMID=\"MONOLOG\" FIELDNAME=\"SPEED\" TYPE=\"N\">fast</APP>");
    CHECK(find(lintAdx(t), Severity::Error, "type-number", "APP_MONOLOG_SPEED").n == 1, "APP value against its TYPE\n%s", dump(t, lintAdx(t)).c_str());
    t = adx318("<APP PROGRAMID=\"MONOLOG\" FIELDNAME=\"X\" TYPE=\"Q\">1</APP>");
    r = lintAdx(t);
    expect("APP TYPE: lint", t, r, Severity::Error, "indicator", "Unknown data type indicator 'Q'", "TYPE=\"Q\"");
    expect("APP TYPE: schema", t, r, Severity::Error, "schema", "TYPE 'Q' is not allowed", "TYPE=\"Q\"");
    t = adx318("<APP PROGRAMID=\"My:Log\" FIELDNAME=\"X\">1</APP>");
    expect("APP name ADI cannot carry", t, lintAdx(t), Severity::Warning, "app-name", "cannot be written in ADI");
    t = adx318("<CALL>W1AW</CALL>");
    expect("a field twice", t, lintAdx(t), Severity::Error, "dup-field", "more than once", "CALL", 1);
}

// ── Versions ────────────────────────────────────────────────────────────────

static void testVersions() {
    // The version checked (Settings, Check Log, --adif) picks the schemas too: the newest by default.
    std::string t = adx("<ADIF_VER>3.1.0</ADIF_VER>", {"<POTA_REF>K-0001</POTA_REF>"});
    LintResult r = lintAdx(t);
    CHECK(r.checkedVersion == specVersion() && r.schemaVersion == specVersion() && r.declaredVersion == "3.1.0" && r.schemaErrors == 0,
          "the newest by default: %s, schemas %s\n%s", r.checkedVersion.c_str(), r.schemaVersion.c_str(), dump(t, r).c_str());
    LintOptions own;
    own.fileVersion = true;
    // POTA_REF is from 3.1.4: a file that says 3.1.0, checked as one, cannot have it.
    r = lintAdx(t, own);
    expect("POTA_REF in 3.1.0", t, r, Severity::Error, "schema", "POTA_REF is not allowed here. (adx310generic.xsd)", "POTA_REF");
    expect("POTA_REF in 3.1.0: lint", t, r, Severity::Warning, "field-version", "It was added in ADIF 3.1.4", "POTA_REF");
    CHECK(r.schemaVersion == "3.1.0" && r.checkedVersion == "3.1.0", "3.1.0: %s", r.schemaVersion.c_str());
    LintOptions v314;
    v314.specVersion = findSpecVersion("3.1.4");
    r = lintAdx(t, v314);
    CHECK(r.checkedVersion == "3.1.4" && r.schemaVersion == "3.1.4" && r.schemaErrors == 0, "chosen 3.1.4\n%s", dump(t, r).c_str());

    t = adx("<PROGRAMID>x</PROGRAMID>", {""});
    r = lintAdx(t, own);
    expect("the file's own version, but none", t, r, Severity::Info, "version-missing", "declares no ADIF version this build knows", "HEADER");
    CHECK(r.checkedVersion == specVersion(), "no ADIF_VER: the version in use, %s", r.checkedVersion.c_str());
    CHECK(find(lintAdx(t), Severity::Info, "version-missing").n == 0, "no note unless the file's own version was asked for");

    t = adx("<ADIF_VER>3.0.2</ADIF_VER>", {""});
    r = lintAdx(t, own);
    expect("3.0.2", t, r, Severity::Info, "schema-version", "ADIF 3.0.2 has no ADX schemas of its own", "3.0.2");
    CHECK(r.schemaVersion == "3.0.3" && r.checkedVersion == "3.0.2", "3.0.2: %s, rules %s", r.schemaVersion.c_str(), r.checkedVersion.c_str());

    // Every version's schemas run (export and generic), on that version's own minimal file.
    size_t n = 0;
    const AdxSchema *s = adxSchemas(&n);
    for (size_t i = 0; i < n; i += 2) {
        t = adx(std::string("<ADIF_VER>") + s[i].version + "</ADIF_VER>", {""});
        r = lintAdx(t, own);
        CHECK(r.schemaVersion == s[i].version && r.schemaErrors == 0 && r.schemaWarnings == 0, "ADIF %s minimal file\n%s", s[i].version,
              dump(t, r).c_str());
    }
}

// ── The CNTY_ALT rewrite (spec/adx/SOURCE.md) ───────────────────────────────

// The published pattern, look-ahead and all, is the oracle: ECMAScript has look-ahead.
static void testRewrite() {
    const std::regex published("[nN][zZ]_[rR][eE][gG][iI][oO][nN][sS]:[a-zA-Z]([ \\-](?=[a-zA-Z])|[a-zA-Z]){4,16}/[a-zA-Z]([ \\-](?=[a-zA-Z])|[a-zA-Z]){3,20}");
    std::mt19937 rng(318);
    static const char kAlphabet[] = "aZk -/1";
    std::vector<std::string> values = {"NZ_Regions:Auckland/Rodney", "NZ_Regions:Bay of Plenty/Opotiki", "nz_regions:Hawkes Bay/Wairoa",
                                       "NZ_Regions:West-Coast/Grey", "NZ_Regions:Auckland /Rodney", "NZ_Regions:Auck  land/Rodney",
                                       "NZ_Regions:Auckland/Rodney-", "NZ_Regions:Abcd/Efgh", "NZ_Regions:Abcde/Efg",
                                       "NZ_Regions:Abcdefghijklmnopq/Abcdefghijklmnopqrstu", "NZ_Regions:Abcdefghijklmnopqr/Abcd",
                                       "NZ_Regions:Abcde/Abcdefghijklmnopqrstuv", "NZ_Regions:Ab-cd/Ef gh", "NZ_Region:Auckland/Rodney"};
    for (int i = 0; i < 3000; ++i) {
        std::string region, district;
        size_t rl = rng() % 21, dl = rng() % 25;
        for (size_t k = 0; k < rl; ++k) region += kAlphabet[rng() % (sizeof kAlphabet - 1)];
        for (size_t k = 0; k < dl; ++k) district += kAlphabet[rng() % (sizeof kAlphabet - 1)];
        values.push_back("NZ_Regions:" + region + "/" + district);
    }
    std::vector<std::string> extras;
    for (const std::string &v : values) extras.push_back("<CNTY_ALT>" + esc(v) + "</CNTY_ALT>");
    std::string t = adx("<ADIF_VER>3.1.8</ADIF_VER>", extras);
    LintResult r = lintAdx(t);
    // Which records the schemas rejected the value in.
    std::vector<size_t> starts;
    for (size_t p = t.find("<CNTY_ALT>"); p != std::string::npos; p = t.find("<CNTY_ALT>", p + 1)) starts.push_back(p);
    std::vector<bool> rejected(values.size(), false);
    for (const Diagnostic &d : r.diagnostics) {
        if (d.code != "schema" || d.severity != Severity::Error) continue;
        size_t i = std::upper_bound(starts.begin(), starts.end(), d.start) - starts.begin();
        if (i > 0) rejected[i - 1] = true;
    }
    size_t mismatches = 0, accepted = 0;
    for (size_t i = 0; i < values.size(); ++i) {
        bool want = !std::regex_match(values[i], published);
        accepted += !want;
        if (want != rejected[i] && mismatches++ < 5)
            std::printf("  CNTY_ALT '%s': published pattern %s, built-in schema %s\n", values[i].c_str(), want ? "rejects" : "accepts",
                        rejected[i] ? "rejects" : "accepts");
    }
    CHECK(mismatches == 0, "CNTY_ALT rewrite: %zu of %zu values judged differently from the published pattern", mismatches, values.size());
    CHECK(accepted >= 6, "CNTY_ALT rewrite: the corpus has valid values too (%zu)", accepted);
}

// ── The schemas against ADIF Lint's ADI rules ───────────────────────────────

static std::vector<std::string> candidates(const FieldDef &f) {
    std::vector<std::string> v = {"", " ", "x", "\xC3\xA9", "a\nb"};
    auto add = [&](std::initializer_list<const char *> l) {
        for (const char *s : l) v.push_back(s);
    };
    switch (fieldType(f)) {
        case DataType::Boolean: add({"Y", "N", "y", "n", "T", "F", "1", "0", "YES", "Y "}); break;
        case DataType::Integer: add({"0", "1", "-1", "+1", "1.0", "1a", "007", "99999999999999999999", "-0", " 1"}); break;
        case DataType::PositiveInteger: add({"0", "1", "-1", "+1", "01", "1.5", "40", "99", "100"}); break;
        case DataType::Number:
            add({"1", "-1", "1.5", ".5", "1.", "-.5", "+1", "1e3", "1,5", "1.2.3", "-", ".", "abc", "007", " 1", "1 ", "0", "120", "121", "-91", "360",
                 "361", "400", "-1.5", "50", "14.025"});
            break;
        case DataType::Date: add({"20240101", "19300101", "19291231", "20241301", "20240230", "20240229", "20230229", "2024010", "202401011", "2024-01-01", "00000000", "20240100"}); break;
        case DataType::Time: add({"1200", "120000", "0000", "2359", "235959", "2400", "1260", "120060", "12000", "1", "12:00", "240000", "000060"}); break;
        case DataType::GridSquare: add({"FN31", "FN31pr", "FN31PR", "FN31pr45", "FN31pr45ab", "FN", "fn31", "ZZ99", "FN3", "FN31p", "RR99xx99", "SS00", "FN31pr4"}); break;
        case DataType::GridSquareExt: add({"ab", "AB", "ab12", "AB12", "a", "ab1", "ab12cd", "zz", "99"}); break;
        case DataType::GridSquareList: add({"FN31,FN32", "FN31,FN32pr", "FN31, FN32", "FN31,", "FN31", "FN31pr", "fn31,fn32", "FN31pr45,FN32"}); break;
        case DataType::Location:
            add({"N040 42.000", "W074 00.000", "S090 00.000", "N090 00.000", "N091 00.000", "N040 60.000", "X040 00.000", "N40 42.000", "N040 42.00",
                 "E180 00.000", "E181 00.000", "n040 42.000", "N040 42.0000", "E180 00.001"});
            break;
        case DataType::IOTARefNo: add({"NA-001", "na-001", "NA-1", "XX-001", "NA-0001", "NA001", "AN-016", "OC-999", "NA-000"}); break;
        case DataType::SOTARef: add({"W2/WE-003", "G/LD-001", "W2/WE003", "w2/we-003", "VK3/VE-001", "W2-003", "W2/WE-0003", "W2/WE-03", "W2/WE-000"}); break;
        case DataType::WWFFRef: add({"KFF-0001", "KFF-12345", "KFF-001", "K-0001", "kff-0001", "KFF-ABCD", "DLFF-0001", "KFFF-0001"}); break;
        case DataType::POTARef:
        case DataType::POTARefList:
            add({"K-0001", "K-0001,K-0002", "US-0001@US-NY", "K-001", "K-0001@", "k-0001", "K-12345", "K-123456", "US-0001", "K-0001, K-0002", "VE-0001@CA-ON"});
            break;
        case DataType::CreditList:
        case DataType::AwardList: add({"IOTA", "IOTA,WAS:LOTW&CARD", "DXCC_MODE", "XXX", "WAS:LOTW", "WAS:XXX", "iota", "WAS:LOTW&", "IOTA,", "AJA"}); break;
        case DataType::SponsoredAwardList:
            add({"ADIF_CENTURY_BASIC", "ARRL_DXCC", "ADIF_X", "XYZ_AWARD", "adif_century_basic", "ADIF_", "ARRL_DXCC,ADIF_CENTURY_BASIC", "CQ_WAZ_MIXED"});
            break;
        case DataType::SecondarySubdivisionList: add({"MA,Middlesex", "MA,Middlesex:MA,Norfolk", "Middlesex", "MA,", "ma,middlesex", "XX,Foo"}); break;
        case DataType::SecondaryAdministrativeSubdivisionListAlt:
            add({"NZ_Regions:Auckland/Rodney", "NZ_Regions:Bay of Plenty/Opotiki", "NZ_Regions:Auckland/Rodney;NZ_Regions:Waikato/Hamilton",
                 "NZ_Regions:auckland/rodney", "Auckland/Rodney", "NZ_Regions:Ab/Rodney", "NZ_Regions:Auckland/", "NZ_Regions:Auck--land/Rodney"});
            break;
        case DataType::MultilineString: add({"a\r\nb", "line\n", "\xC3\xA9\nx", "a\tb"}); break;
        case DataType::String: add({"abc", "<", "&", "a\tb", "~", "\x7F"}); break;
        default: break;
    }
    if (const EnumDef *e = f.enumeration ? findEnum(f.enumeration) : nullptr) {
        std::set<std::string> seen;
        for (size_t i = 0; i < e->count; ++i) {
            const EnumValue &ev = e->values[i];
            if (!inSpecVersion(ev.versions) || !seen.insert(ev.value).second) continue;
            v.push_back(ev.value);
            std::string low = ev.value;
            for (char &c : low) c = (char)std::tolower((unsigned char)c);
            if (low != ev.value) v.push_back(low);
        }
        v.push_back("ZZZQ");
    }
    return v;
}

// Why the schemas and lint() may judge a value differently (docs/ADIF_CONFORMANCE.md,
// "The schemas and the ADI rules"). schema: R rejects, I import-only, - accepts;
// adi: lint()'s worst on the field, E W N or -. Null: not explained.
static const char *explained(const FieldDef &f, const std::string &v, char schema, char adi, const std::string &code) {
    DataType t = fieldType(f);
    bool numeric = t == DataType::Integer || t == DataType::Number || t == DataType::PositiveInteger;
    bool padded = !v.empty() && (v.front() == ' ' || v.back() == ' ');
    std::string name = f.name;
    if (schema == 'R' && v.empty() && adi == '-') return "empty element";  // ADI's zero length is no value; ADX's empty element is a value
    if (schema == '-' && adi == 'E') {
        if (numeric && padded) return "white space";  // xs:decimal collapses it; ADIF's Number has none
        if (t == DataType::Date && code == "date-format") return "calendar";
        if (t == DataType::Location) return "latitude or longitude";
        if (t == DataType::SecondarySubdivisionList) return "two counties";
        if (code == "submode-mode") return "SUBMODE and MODE";
    }
    if (schema == 'R' && adi == 'W') {
        if (code == "non-ascii" || code == "line-break" || code == "grid-ext-length" || code == "placeholder" || code == "import-only") return "severity";
        if (t == DataType::GridSquareList || t == DataType::SOTARef || t == DataType::SponsoredAwardList ||
            t == DataType::SecondaryAdministrativeSubdivisionListAlt)
            return "severity";
    }
    if (schema == 'R' && (adi == 'N' || adi == '-') && (name == "SUBMODE" || name == "DARC_DOK" || name == "MY_DARC_DOK")) return "schema pattern";
    return nullptr;
}

static void testAgainstLint() {
    size_t nf = 0;
    const FieldDef *fields = fieldTable(&nf);
    const char *base[][2] = {{"CALL", "W1AW"}, {"QSO_DATE", "20240101"}, {"TIME_ON", "1200"}, {"BAND", "20m"}, {"MODE", "CW"}};
    size_t compared = 0, agreed = 0, unexplained = 0;
    std::map<std::string, size_t> why;
    for (size_t fi = 0; fi < nf; ++fi) {
        const FieldDef &f = fields[fi];
        DataType t = fieldType(f);
        if (f.header || !inSpecVersion(f.versions) || t == DataType::IntlString || t == DataType::IntlMultilineString) continue;  // ADI cannot carry Intl
        std::vector<std::string> values = candidates(f);
        std::string doc = std::string(kDecl) + "<ADX><HEADER><ADIF_VER>3.1.8</ADIF_VER></HEADER><RECORDS>\n";
        std::vector<std::pair<size_t, size_t>> at;
        for (const std::string &v : values) {
            doc += "<RECORD>";
            for (auto &b : base)
                if (f.name != std::string(b[0])) doc += std::string("<") + b[0] + ">" + b[1] + "</" + b[0] + ">";
            size_t b = doc.size();
            doc += std::string("<") + f.name + ">" + esc(v) + "</" + f.name + ">";
            at.push_back({b, doc.size()});
            doc += "</RECORD>\n";
        }
        doc += "</RECORDS></ADX>\n";
        LintResult r = lintAdx(doc);
        for (size_t i = 0; i < values.size(); ++i) {
            char schema = '-';
            for (const Diagnostic &d : r.diagnostics) {
                if (d.start < at[i].first || d.start >= at[i].second) continue;
                if (d.code == "schema" && d.severity == Severity::Error) schema = 'R';
                else if (d.code == "schema-export" && schema == '-') schema = 'I';
            }
            // The same value in ADI, through lint() itself.
            std::string adi = "ADI\n<ADIF_VER:5>3.1.8<EOH>\n";
            for (auto &b : base)
                if (f.name != std::string(b[0])) adi += std::string("<") + b[0] + ":" + std::to_string(std::strlen(b[1])) + ">" + b[1];
            size_t fb = adi.size();
            adi += std::string("<") + f.name + ":" + std::to_string(values[i].size()) + ">" + values[i];
            size_t fe = adi.size();
            adi += "<EOR>\n";
            LintResult a = lint(adi);
            char worst = '-';
            std::string code;
            for (const Diagnostic &d : a.diagnostics) {
                if (d.start < fb || d.start >= fe) continue;
                char s = d.severity == Severity::Error ? 'E' : d.severity == Severity::Warning ? 'W' : 'N';
                if (worst == '-' || s == 'E' || (s == 'W' && worst == 'N')) {
                    if (s != worst || code.empty()) code = d.code;
                    worst = s;
                }
            }
            ++compared;
            bool same = schema == 'R' ? worst == 'E' : schema == 'I' ? worst == 'W' : worst != 'E';
            if (same) {
                ++agreed;
                continue;
            }
            const char *reason = explained(f, values[i], schema, worst, code);
            if (reason) {
                ++why[reason];
            } else if (unexplained++ < 20) {
                std::string v = values[i];
                for (char &c : v)
                    if (c == '\n') c = '|';
                std::printf("  %s '%s': schema %c, lint() %c [%s]\n", f.name, v.c_str(), schema, worst, code.c_str());
            }
        }
    }
    CHECK(unexplained == 0, "schemas against the ADI rules: %zu of %zu values judged differently for no listed reason", unexplained, compared);
    CHECK(compared > 9000 && agreed > compared * 9 / 10, "the comparison is broad: %zu values, %zu agreed", compared, agreed);
    std::printf("schemas against the ADI rules: %zu values, %zu agreed;", compared, agreed);
    for (auto &[k, n] : why) std::printf(" %s %zu,", k.c_str(), n);
    std::printf("\n");
}

int main(int argc, char **argv) {
    testSchemas();
    testDetection();
    testXml();
    testSchemaFindings();
    testUserAndAppFields();
    testVersions();
    testRewrite();
    testAgainstLint();
    if (argc > 1) testOfficialFile(argv[1]);
    else std::printf("note: official ADX test file not given; skipping\n");
    std::printf("%d/%d checks passed\n", gChecks - gFailures, gChecks);
    return gFailures ? 1 : 0;
}
