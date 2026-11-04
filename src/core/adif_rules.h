// The rules ADIF Lint checks: one per diagnostic code, with where in the ADIF
// specification it comes from, the file formats it applies to, and what it asks.
//
// Every diagnostic lint() and lintAdx() make carries one of these codes; the
// conformance tests (tests/conformance/) hold, for each rule and format, a case that
// breaks it and a case that keeps it, and docs/RULES.md is generated from this table
// and those cases. What the specification asks that ADIF Lint does not check is listed
// too, with the reason.
#pragma once

#include <cstddef>
#include <string_view>

namespace adif {

enum RuleFormats : unsigned char { kRuleAdi = 1, kRuleAdx = 2, kRuleBoth = 3 };

struct Rule {
    const char *code;      // the diagnostic code: stable, as scripts and Check Log use it
    const char *group;     // its place in docs/RULES.md (ruleGroups())
    const char *section;   // where the rule comes from: "IV.A.1", "Resources III.C", "POTA"...
    unsigned char formats; // RuleFormats
    const char *severity;  // "error", "warning", "note", or several, "error, warning"
    const char *requires;  // what a conforming file does, in a sentence
    const char *notes;     // how ADIF Lint applies it (exceptions, severity choices), or ""
    const char *untested;  // why no file can break it, so no case can, or nullptr
};

// A statement of the specification that ADIF Lint does not check, and why.
struct Unchecked {
    const char *section;
    const char *statement;
    const char *why;
};

const Rule *ruleTable(size_t *count);
const Rule *findRule(std::string_view code);
// The groups, in the order docs/RULES.md lists them.
const char *const *ruleGroups(size_t *count);
const Unchecked *uncheckedTable(size_t *count);

}  // namespace adif
