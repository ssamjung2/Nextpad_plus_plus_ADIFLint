// ADX file validation (ADIF 3.1.8, section IV.B).
//
// An ADX document gets two checks, reported side by side in one LintResult:
//
//  - The schema check: the XML must be well formed and UTF-8, follow §IV.B.1 (no
//    DOCTYPE, no entities but XML's predefined ones, no CDATA in fields), and be
//    valid against the XML Schemas published with its ADIF version (spec/adx/),
//    which libxml2 runs with network access and entity expansion off.
//  - ADIF Lint's own checks: each record is restated in ADI form and lint()
//    (adif_lint.h) runs on it, so ADI and ADX files follow the same verified rules,
//    and each finding is mapped back to the ADX element it is about.
//
// Kept out of adif_core so that the core stays free of platform libraries.
#pragma once

#include "adif_lint.h"

#include <cstddef>
#include <string_view>

namespace adif {

// A published schema, as built in by tools/gen_adx_schemas.py.
struct AdxSchema {
    const char *version;  // "3.1.8"
    bool generic;         // adxNNNgeneric.xsd: for reading, allows what the version deprecates; else adxNNN.xsd, for writing
    const char *file;     // "adx318generic.xsd"
    const char *text;
    size_t size;
};
// Oldest version first, each version's export schema before its generic one.
const AdxSchema *adxSchemas(size_t *count);

// Whether `text` is an ADX document rather than ADI: after an optional byte order
// mark and white space, it starts with an XML declaration, a comment or <ADX.
bool isAdx(std::string_view text);

// The version whose schemas check a document checked against ADIF `version`: that
// version when it published schemas, else the nearest older one that did (the oldest,
// 3.0.3, for 3.0.2). When `version` is not X.Y.Z, the same for `fallback`.
const char *adxSchemaVersion(std::string_view version, std::string_view fallback);

// Check an ADX document. Diagnostics are byte ranges into `text`, as from lint(), and
// each names its rule (adif_rules.h). The schema check's codes are xml, adx-... and
// schema...; the rest are ADIF Lint's own, as lint() makes them on each record restated
// in ADI. The version checked (LintOptions::specVersion or fileVersion) is the rules'
// and the schemas' both. ADX has no length fixes and no DocModel; `options.lengthUnit`
// and `options.buildModel` do not apply.
LintResult lintAdx(std::string_view text, const LintOptions &options = {});

// Compile a built-in schema, for the tests: empty when it compiles, else why not.
std::string adxSchemaProblem(const AdxSchema &schema);

}  // namespace adif
