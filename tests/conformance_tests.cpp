// Conformance tests: every rule in the catalogue (adif_rules.h), in each file format it
// applies to, against cases that break it and cases that keep it.
//
//   conformance_tests CASES [--doc RULES.md | --write-doc RULES.md]
//
// A case is one line of CASES:
//
//   CODE  FORMATS  VERSION  EXPECT  INPUT
//
//   CODE     the rule
//   FORMATS  adi, adx or both: the case is built in each and must hold in each
//   VERSION  the ADIF version the checks follow: "-" the newest, "3.1.3" that one,
//            "file" the version the file declares (LintOptions::fileVersion)
//   EXPECT   error, warning or note (exactly one finding of CODE with that severity;
//            error*2 for two), or clean (no finding of CODE)
//   INPUT    [HEADER ||] RECORD [| RECORD...], fields written <NAME>value or <NAME:T>value,
//            their lengths filled in; each record gets QSO_DATE, TIME_ON, CALL, BAND and MODE
//            unless it names them or starts with "bare". Without "||" the header is
//            <ADIF_VER> of the version checked. Or raw:TEXT, the whole file (one format).
//            Escapes: \n \r \t \s (space) \| \< \\ \xHH.
//
// In ADX, a header's USERDEFn becomes <USERDEF FIELDID="n" TYPE ENUM|RANGE>, APP_P_F an
// APP element, a field the header defines a record's USERDEF, and names are upper case.
// --doc compares docs/RULES.md with what the catalogue and the cases make; --write-doc writes it.
#include "adif_adx.h"
#include "adif_lint.h"
#include "adif_rules.h"
#include "adif_spec.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace adif;

static int gFailures = 0, gChecks = 0;

#define CHECK(cond, ...)                \
    do {                                \
        ++gChecks;                      \
        if (!(cond)) {                  \
            ++gFailures;                \
            std::printf("FAIL ");       \
            std::printf(__VA_ARGS__);   \
            std::printf("\n");          \
        }                               \
    } while (0)

struct Case {
    int line = 0;
    std::string code, formats, version, expect, input;
    bool breaks() const { return expect != "clean"; }
};

struct Field {
    std::string name, value;
    char type = 0;
};

static std::string trim(const std::string &s) {
    size_t b = s.find_first_not_of(" \t"), e = s.find_last_not_of(" \t");
    return b == std::string::npos ? std::string() : s.substr(b, e - b + 1);
}

static std::string upper(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

static std::string unescape(const std::string &s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '\\' || i + 1 >= s.size()) {
            o += s[i];
            continue;
        }
        char c = s[++i];
        if (c == 'n') o += '\n';
        else if (c == 'r') o += '\r';
        else if (c == 't') o += '\t';
        else if (c == 's') o += ' ';
        else if (c == 'x' && i + 2 < s.size()) {
            o += (char)std::stoi(s.substr(i + 1, 2), nullptr, 16);
            i += 2;
        } else o += c;  // \\ \| \<
    }
    return o;
}

// Split on an unescaped separator surrounded by spaces (" | " or " || ").
static std::vector<std::string> splitOn(const std::string &s, const std::string &sep) {
    std::vector<std::string> out;
    size_t from = 0;
    for (size_t at = s.find(sep); at != std::string::npos; at = s.find(sep, at + 1)) {
        if (at > 0 && s[at - 1] == '\\') continue;
        out.push_back(s.substr(from, at - from));
        from = at + sep.size();
    }
    out.push_back(s.substr(from));
    return out;
}

// <NAME>value <NAME:T>value...; a '<' in a value is written \<.
static std::vector<Field> parseFields(const std::string &s, bool *bare, int line) {
    std::vector<Field> out;
    std::string t = trim(s);
    *bare = t.compare(0, 4, "bare") == 0;
    if (*bare) t = trim(t.substr(4));
    size_t i = 0;
    while (i < t.size()) {
        size_t lt = t.find('<', i);
        while (lt != std::string::npos && lt > 0 && t[lt - 1] == '\\') lt = t.find('<', lt + 1);
        if (lt == std::string::npos) break;
        size_t gt = t.find('>', lt);
        CHECK(gt != std::string::npos, "line %d: a field's '<' without '>'", line);
        if (gt == std::string::npos) break;
        Field f;
        std::string tag = t.substr(lt + 1, gt - lt - 1);
        size_t colon = tag.find(':');
        f.name = tag.substr(0, colon);
        if (colon != std::string::npos) f.type = tag[colon + 1];
        size_t next = gt + 1;
        for (;;) {
            next = t.find('<', next);
            if (next == std::string::npos || t[next - 1] != '\\') break;
            ++next;
        }
        std::string raw = t.substr(gt + 1, (next == std::string::npos ? t.size() : next) - gt - 1);
        while (!raw.empty() && (raw.back() == ' ' || raw.back() == '\t')) raw.pop_back();
        f.value = unescape(raw);
        out.push_back(f);
        i = next == std::string::npos ? t.size() : next;
    }
    return out;
}

struct Doc {
    std::vector<Field> header;
    bool hasHeader = true;
    std::vector<std::vector<Field>> records;
};

static const char *const kMinimum[][2] = {{"QSO_DATE", "20240115"}, {"TIME_ON", "1830"}, {"CALL", "WF1B"}, {"BAND", "20m"}, {"MODE", "CW"}};

static Doc parseDoc(const Case &c, const std::string &versionName) {
    Doc d;
    std::vector<std::string> parts = splitOn(c.input, " || ");
    std::string recordsText = parts.back();
    bool bare = false;
    if (parts.size() > 1) d.header = parseFields(parts[0], &bare, c.line);
    else d.header.push_back({"ADIF_VER", versionName, 0});
    for (const std::string &r : splitOn(recordsText, " | ")) {
        std::vector<Field> fields = parseFields(r, &bare, c.line);
        if (!bare) {
            std::vector<Field> all;
            for (auto &m : kMinimum) {
                bool named = false;
                for (const Field &f : fields) named |= upper(f.name) == m[0];
                if (!named) all.push_back({m[0], m[1], 0});
            }
            all.insert(all.end(), fields.begin(), fields.end());
            fields = all;
        }
        if (!fields.empty() || bare) d.records.push_back(fields);
    }
    return d;
}

static std::string adiSpec(const Field &f) {
    std::string s = "<" + f.name + ":" + std::to_string(f.value.size());
    if (f.type) s += std::string(":") + f.type;
    return s + ">" + f.value;
}

static std::string toAdi(const Doc &d) {
    std::string s = "ADIF Lint conformance case\n";
    for (const Field &f : d.header) s += adiSpec(f) + "\n";
    s += "<EOH>\n";
    for (const auto &r : d.records) {
        for (const Field &f : r) s += adiSpec(f) + " ";
        s += "<EOR>\n";
    }
    return s;
}

static std::string xmlEscape(const std::string &v) {
    std::string o;
    for (char c : v) o += c == '&' ? "&amp;" : c == '<' ? "&lt;" : c == '>' ? "&gt;" : c == '"' ? "&quot;" : std::string(1, c);
    return o;
}

static std::string toAdx(const Doc &d) {
    std::set<std::string> userFields;
    std::string s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ADX>\n<HEADER>\n";
    for (const Field &f : d.header) {
        std::string name = upper(f.name);
        if (name.compare(0, 7, "USERDEF") == 0 && name.size() > 7) {
            std::string fieldName = f.value, values;
            size_t comma = f.value.find(",{");
            if (comma != std::string::npos) fieldName = f.value.substr(0, comma), values = f.value.substr(comma + 1);
            userFields.insert(upper(fieldName));
            s += "<USERDEF FIELDID=\"" + name.substr(7) + "\"";
            if (f.type) s += std::string(" TYPE=\"") + f.type + "\"";
            if (!values.empty())
                s += std::string(values.find(':') != std::string::npos && values.find(',') == std::string::npos ? " RANGE=\"" : " ENUM=\"") + xmlEscape(values) + "\"";
            s += ">" + xmlEscape(fieldName) + "</USERDEF>\n";
        } else {
            s += "<" + name + ">" + xmlEscape(f.value) + "</" + name + ">\n";
        }
    }
    s += "</HEADER>\n<RECORDS>\n";
    for (const auto &r : d.records) {
        s += "<RECORD>";
        for (const Field &f : r) {
            std::string name = upper(f.name);
            size_t us = name.find('_', 4);
            if (name.compare(0, 4, "APP_") == 0 && us != std::string::npos) {
                s += "<APP PROGRAMID=\"" + xmlEscape(f.name.substr(4, us - 4)) + "\" FIELDNAME=\"" + xmlEscape(f.name.substr(us + 1)) + "\"";
                if (f.type) s += std::string(" TYPE=\"") + f.type + "\"";
                s += ">" + xmlEscape(f.value) + "</APP>";
            } else if (userFields.count(name)) {
                s += "<USERDEF FIELDNAME=\"" + xmlEscape(f.name) + "\">" + xmlEscape(f.value) + "</USERDEF>";
            } else {
                s += "<" + name + ">" + xmlEscape(f.value) + "</" + name + ">";
            }
        }
        s += "</RECORD>\n";
    }
    return s + "</RECORDS>\n</ADX>\n";
}

static std::vector<Case> readCases(const char *path) {
    std::vector<Case> cases;
    std::ifstream in(path);
    CHECK(in.good(), "cannot read %s", path);
    std::string line;
    int n = 0;
    while (std::getline(in, line)) {
        ++n;
        if (trim(line).empty() || trim(line)[0] == '#') continue;
        std::istringstream ss(line);
        Case c;
        c.line = n;
        ss >> c.code >> c.formats >> c.version >> c.expect;
        std::getline(ss, c.input);
        c.input = trim(c.input);
        bool ok = !c.input.empty() && (c.formats == "adi" || c.formats == "adx" || c.formats == "both");
        CHECK(ok, "line %d: expected CODE FORMATS VERSION EXPECT INPUT", n);
        if (ok) cases.push_back(c);
    }
    return cases;
}

// What a severity is called in the cases.
static const char *severityWord(Severity s) { return s == Severity::Error ? "error" : s == Severity::Warning ? "warning" : "note"; }

static std::map<std::string, std::map<std::string, std::pair<int, int>>> gCoverage;  // code -> format -> breaking, keeping
static std::map<std::string, std::string> gExample;                                  // code -> an input that breaks it

static void runCase(const Case &c) {
    const Rule *rule = findRule(c.code);
    CHECK(rule, "line %d: %s is not in the rule catalogue", c.line, c.code.c_str());
    if (!rule) return;
    size_t nv = 0;
    const SpecVersion *versions = specVersions(&nv);
    LintOptions opt;
    opt.today = "20261101";
    if (c.version == "file") opt.fileVersion = true;
    else if (c.version != "-") opt.specVersion = findSpecVersion(c.version);
    CHECK(c.version == "-" || c.version == "file" || opt.specVersion != kNoPos, "line %d: no ADIF version %s", c.line, c.version.c_str());
    const char *versionName = versions[opt.specVersion != kNoPos ? opt.specVersion : nv - 1].name;

    std::string sev = c.expect;
    size_t want = c.breaks() ? 1 : 0;
    size_t star = sev.find('*');
    if (star != std::string::npos) want = (size_t)std::stoul(sev.substr(star + 1)), sev = sev.substr(0, star);
    CHECK(sev == "clean" || sev == "error" || sev == "warning" || sev == "note", "line %d: EXPECT %s", c.line, c.expect.c_str());

    bool raw = c.input.compare(0, 4, "raw:") == 0;
    CHECK(!raw || c.formats != "both", "line %d: a raw case is one format", c.line);
    for (const char *format : {"adi", "adx"}) {
        if (c.formats != "both" && c.formats != format) continue;
        bool adx = format[2] == 'x';
        CHECK(rule->formats & (adx ? kRuleAdx : kRuleAdi), "line %d: %s does not apply to %s", c.line, c.code.c_str(), adx ? "ADX" : "ADI");
        std::string text = raw ? unescape(c.input.substr(4)) : adx ? toAdx(parseDoc(c, versionName)) : toAdi(parseDoc(c, versionName));
        LintResult r = adx ? lintAdx(text, opt) : lint(text, opt);
        size_t got = 0;
        std::string all;
        for (const Diagnostic &d : r.diagnostics) {
            CHECK(!d.code.empty() && findRule(d.code), "line %d (%s): a finding without a catalogued code [%s]: %s", c.line, format, d.code.c_str(),
                  d.message.c_str());
            CHECK(d.start < d.end && d.end <= text.size(), "line %d (%s): range [%zu,%zu) outside %zu bytes", c.line, format, d.start, d.end, text.size());
            all += std::string("    ") + severityWord(d.severity) + " [" + d.code + "] " + d.message + "\n";
            if (d.code == c.code && (sev == "clean" || sev == severityWord(d.severity))) ++got;
        }
        CHECK(got == want, "line %d (%s, ADIF %s): %s expects %zu %s, got %zu\n%s%s", c.line, format, r.checkedVersion.c_str(), c.code.c_str(), want,
              sev.c_str(), got, all.c_str(), got != want && std::getenv("CONFORMANCE_SHOW") ? text.c_str() : "");
        auto &cov = gCoverage[c.code][format];
        (c.breaks() ? cov.first : cov.second)++;
        if (c.breaks() && !gExample.count(c.code)) gExample[c.code] = c.input;
    }
}

static std::string formatsName(unsigned char f) { return f == kRuleBoth ? "ADI, ADX" : f == kRuleAdi ? "ADI" : "ADX"; }

// A table cell: '|' escaped, and in text (not code) what Markdown would read as HTML.
static std::string cell(const std::string &s, bool code = false) {
    std::string o;
    for (char c : s) {
        if (c == '|') o += "\\|";
        else if (!code && c == '&') o += "&amp;";
        else if (!code && c == '<') o += "&lt;";
        else if (!code && c == '>') o += "&gt;";
        else o += c;
    }
    return o;
}

static std::string markdown(const std::vector<Case> &cases) {
    size_t nr = 0, ng = 0, nu = 0;
    const Rule *rules = ruleTable(&nr);
    const char *const *groups = ruleGroups(&ng);
    const Unchecked *unchecked = uncheckedTable(&nu);
    std::map<std::string, int> breaking, keeping;
    for (const Case &c : cases) (c.breaks() ? breaking : keeping)[c.code]++;
    std::string s;
    s += "# ADIF Lint rules\n\n";
    s += "<!-- Generated by tests/conformance_tests from src/core/adif_rules.cpp and tests/conformance/rules.cases. Do not edit:\n"
         "     build/conformance_tests tests/conformance/rules.cases --write-doc docs/RULES.md -->\n\n";
    s += "Every finding ADIF Lint reports names one of these rules by its code, as the command line prints it (`[length]`) and Check Log "
         "groups it. Each rule says where in the ADIF specification it comes from (section numbers are ADIF 3.1.8's), which file formats "
         "it applies to, and what a conforming file does. [ADIF conformance](ADIF_CONFORMANCE.md) says how the rules were drawn up and "
         "verified.\n\n";
    s += "The conformance tests (`tests/conformance/rules.cases`) hold, for every rule and each format it applies to, at least one case "
         "that breaks the rule and one that keeps it; each case is written once and built as an ADI file, an ADX file or both, and checked "
         "against any ADIF version. The example column shows a case that breaks the rule, in the cases' notation: fields with their lengths "
         "left out, a record's QSO_DATE, TIME_ON, CALL, BAND and MODE filled in (`bare`: not), `||` after header fields, `|` between "
         "records, and `raw:` before a whole file.\n\n";
    s += std::to_string(nr) + " rules, " + std::to_string(cases.size()) + " cases.\n\n";
    for (size_t g = 0; g < ng; ++g) {
        s += "## " + std::string(groups[g]) + "\n\n";
        s += "| Code | Section | Formats | Severity | A conforming file | Breaks it |\n|---|---|---|---|---|---|\n";
        for (size_t i = 0; i < nr; ++i) {
            const Rule &r = rules[i];
            if (std::strcmp(r.group, groups[g]) != 0) continue;
            std::string what = r.requires;
            if (*r.notes) what += " *" + std::string(r.notes) + "*";
            std::string example;
            if (r.untested) {
                example = cell(std::string("(none: ") + r.untested + ")");
            } else if (gExample.count(r.code)) {
                std::string e = gExample[r.code];
                if (e.size() > 150) e = e.substr(0, 147) + "…";
                example = "`" + cell(e, true) + "`";
            }
            s += "| `" + std::string(r.code) + "` | " + r.section + " | " + formatsName(r.formats) + " | " + r.severity + " | " + cell(what) + " | " +
                 example + " |\n";
        }
        s += "\n";
    }
    s += "## What ADIF Lint does not check\n\n| Section | The specification says | Why it is not checked |\n|---|---|---|\n";
    for (size_t i = 0; i < nu; ++i) s += "| " + std::string(unchecked[i].section) + " | " + cell(unchecked[i].statement) + " | " + cell(unchecked[i].why) + " |\n";
    return s;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: conformance_tests CASES [--doc RULES.md | --write-doc RULES.md]\n");
        return 2;
    }
    std::vector<Case> cases = readCases(argv[1]);
    for (const Case &c : cases) runCase(c);

    // Every rule, in every format it applies to, has a case that breaks it and one that keeps it.
    size_t nr = 0;
    const Rule *rules = ruleTable(&nr);
    std::set<std::string> codes;
    for (size_t i = 0; i < nr; ++i) {
        const Rule &r = rules[i];
        CHECK(codes.insert(r.code).second, "%s is in the catalogue twice", r.code);
        if (r.untested) continue;
        for (const char *format : {"adi", "adx"}) {
            if (!(r.formats & (format[2] == 'x' ? kRuleAdx : kRuleAdi))) continue;
            auto cov = gCoverage[r.code][format];
            CHECK(cov.first > 0, "%s: no %s case breaks it", r.code, format);
            CHECK(cov.second > 0, "%s: no %s case keeps it", r.code, format);
        }
    }

    std::string doc = markdown(cases);
    for (int i = 2; i + 1 < argc; ++i) {
        if (!std::strcmp(argv[i], "--write-doc")) {
            std::ofstream(argv[i + 1], std::ios::binary) << doc;
            std::printf("wrote %s\n", argv[i + 1]);
        } else if (!std::strcmp(argv[i], "--doc")) {
            std::ifstream in(argv[i + 1], std::ios::binary);
            std::ostringstream have;
            have << in.rdbuf();
            CHECK(have.str() == doc, "%s is not what the catalogue and the cases make: run conformance_tests %s --write-doc %s", argv[i + 1], argv[1],
                  argv[i + 1]);
        }
    }
    std::printf("%zu rules, %zu cases; %d/%d checks passed\n", nr, cases.size(), gChecks - gFailures, gChecks);
    return gFailures ? 1 : 0;
}
