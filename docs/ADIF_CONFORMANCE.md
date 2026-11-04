# ADIF conformance

How ADIF Lint's rules were drawn from the ADIF specification, and how conformance is
verified. The rules themselves, each with its section, the file formats it applies to and a
case that breaks it, are in [RULES.md](RULES.md), generated from the rule catalogue. ADI and
ADX are different serializations with different validation sources: the rules are based on
the ADIF specification and its exported tables; ADX files are also checked against the XML
Schemas published with each ADIF version (see [ADX](#adx)). Section numbers are those of
ADIF 3.1.7, which 3.1.8 keeps; "Resources" means the ADIF 3.1.7 Resources document.

ADIF 3.1.8 (2026-10-12) changed only enumeration values: submode JTTY (of MFSK), contest IDs
SKCC-SKS, SKCC-SKSA, SKCC-SKSE and SKCC-WES, and WAE for European Turkey's region (its section
1.F). The tables are now generated from 3.1.8's export, so the rules below hold as verified,
with 3.1.8's values. Checks against an older version (Settings, Check Log, `--adif`) use
what that version's specification holds, read as `spec/adif-history.md` describes; so do
checks against the version each file declares (`--adif file`).

## The rule catalogue and the conformance tests (2026-11-02)

The specification's normative text (sections I to IV, and the tables of III.A, III.B and
III.C) was read for statements a file can break, and each became a rule in
`src/core/adif_rules.cpp`: a code, the section, the formats (ADI, ADX or both), the
severity, and what a conforming file does. What the specification says that no file can be
checked for is listed there too, with the reason (RULES.md, "What ADIF Lint does not check").

- **Every finding names its rule.** The checks cannot report without a code: it is a
  required argument of every diagnostic in `adif_lint.cpp`, so the compiler rejects one
  without, and `conformance_tests` fails on a code the catalogue lacks.
- **Every rule is broken and kept.** `tests/conformance/rules.cases` holds, for each rule
  and each format it applies to, a case that breaks it and one that keeps it (233 cases for
  97 rules). A case is written once, as fields with their lengths left out, and built as an
  ADI file, an ADX file or both, so ADI and ADX are held to the same rules; it can name the
  ADIF version to check against, or the file's own.
- **The documentation is made from them.** `docs/RULES.md` is generated from the
  catalogue and the cases, and the `conformance` test fails when it is out of date.

Three rules have no case, as no file can break them: the Character and Digit data types
(no field or type indicator has them) and ADIF Lint's own failure to read the XML.

## Sources

| Source | Where | Checked |
|---|---|---|
| ADIF 3.1.7 specification (released 2026-03-22), the rules' text | <https://www.adif.org/317/ADIF_317.htm> (SHA-256 `b7667032…c5c97`) | 2026-10-10 |
| ADIF 3.1.8 specification (released 2026-10-12) | `spec/adif-3.1.8/ADIF_318.htm`, from <https://adif.org.uk/318/ADIF_318.htm> | 2026-10-26: SHA-256 `9d130f55…7fe6`; adif.org lists 3.1.8 as current |
| ADX XML Schemas, 3.0.3 to 3.1.8, export and generic (32 files; 3.1.8's are schema version 3.1.8.0, dated 2026-09-26) | `spec/adx/`, from `https://www.adif.org/NNN/adxNNN.xsd` and `adxNNNgeneric.xsd` (each URL and SHA-256 in `spec/adx/SOURCE.md`) | 2026-11-01: `tools/gen_adx_schemas.py` checks every hash; 3.0.2 and earlier publish none (404) |
| Exported tables (`all.json`) | `spec/adif-3.1.8/all.json`, from <https://adif.org.uk/318/ADIF_318_resources_2026_10_12.zip> | 2026-10-26: `tools/gen_spec_tables.py` regenerates `src/core/adif_spec_tables.cpp` byte for byte |
| ADIF 3.0.2 to 3.1.8, what each holds | `spec/adif-history.json`, from each version's specification (`spec/adif-history.md`) | 2026-10-26: the reader matches the 3.1.5 to 3.1.8 exports |
| ADIF 3.1.7 Resources (implementation notes) | <https://adif.org.uk/317/ADIF_317_resources.htm> (the spec's relative link 404s on adif.org) | 2026-10-10 |
| Official test QSOs | `tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adi` (6,202 QSOs, every field and value) | lints with 0 errors and 0 warnings |
| Official test QSOs, ADX | `tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adx`, from the same archive (SHA-256 in `spec/adx/SOURCE.md`) | 0 errors and 0 warnings, from the schemas and from ADIF Lint's rules |

## How ADI rules were verified (2026-10-10)

1. Every rule in `src/core/adif_lint.cpp` was read against the specification text.
2. The official test file, which uses every field and value correctly, must lint with no
   errors or warnings (`adif_tests` checks this).
3. 246 probes, each a small file whose expected result was taken from the specification
   rather than the code, were run through `adiflint`. Before this review 22 failed: the
   rules marked *added 2026-10-10* below were missing. Now all pass except one deliberate
   choice (a header without records is a note, not a warning).
4. Every rule has unit tests in `tests/adif_tests.cpp` that cite their section, and
   each repair is applied and re-checked there.

## Rules

[RULES.md](RULES.md) lists them, grouped as ADI structure, ADX structure, header, fields,
data types, enumerations, field definitions, rules between fields, user-defined and
application-defined fields, the ADX schemas, versions, and practice beyond the
specification. Rules added on 2026-10-10 were missing before the review above; on
2026-11-01 the comparison with the ADX schemas tightened SponsoredAwardList, SOTARef and
VUCC_GRIDS (see [the schemas and the ADI rules](#the-schemas-and-the-adi-rules-2026-11-01)).

## Where ADIF Lint is gentler than the specification

These are deliberate, so that common real-world logs stay readable:

- **Non-ASCII text** in a String field is a warning, not an error. ADI is ASCII only, but
  many programs write UTF-8; the length unit is a setting.
- **A bare CR or LF** in a MultilineString is a warning; the specification asks for CR LF.
- **A STATE or CNTY not on its entity's list** is a warning: callbooks fill these from
  profiles (QRZ.com writes `H` for Hungary).
- **A header with no records** is a note: Start Activation and the QSO panel create such a log
  before its first QSO.
- **A type indicator that contradicts the field** is a warning.
- **A USERDEFn without a type indicator** is a warning. The specification's grammar
  (§IV.A.5) includes it, while its sample header (§IV.A.3) leaves one out.
- **A DXCC code with leading zeros** (`0291`) is read as the number.

## What ADIF Lint cannot check

RULES.md lists each such statement of the specification with the reason; in short:

- Values from lists the specification refers to but does not include: DARC_DOK, CNTY
  for most entities (US counties, Japanese cities…), Country names.
- Deleted DXCC entities and deleted Alaska boroughs: the specification marks them deleted
  but gives no dates.
- Contest IDs' end dates, which are only in their descriptions.

## ADX

ADIF Lint checks ADX files (§IV.B) in two parts and reports them apart: each finding's code
says which part found it, and the CLI, the Record Panel and Check Log count them apart.

### The schema check

`src/core/adif_adx.cpp`, with libxml2 (2.9.13, as macOS ships it):

| Rule | Section | Code, severity |
|---|---|---|
| Well-formed XML. Only the first error is reported; what follows mostly follows from it | XML 1.0 | `xml`, error |
| UTF-8: a declared encoding other than UTF-8 | IV.B | `adx-encoding`, error |
| No `<!DOCTYPE ...>`; no entities but XML's predefined ones; no CDATA section in a field | IV.B.1 | `adx-doctype`, `adx-entity`, `adx-cdata`, error |
| Namespaces and processing instructions are ignored: namespaces are taken off before validation | IV.B.1 | (not reported) |
| What the version's generic schema rejects | IV.B.5, V.A | `schema`, error |
| What only the export schema rejects: an error, unless the spec makes it import-only (a deprecated field or value, ANT_AZ or ANT_EL outside their range) | IV.B.5, II.B | `schema` error / `schema-export` warning |
| TYPE on a record's USERDEF: the schemas reject it; §IV.B.3 says it is ignored | IV.B.3 | `schema-strict`, warning |
| A record's USERDEF FIELDNAME in mixed case: the schemas want upper case; field names are case-insensitive (§III.C.1) and §IV.B.3's own example writes `SweaterSize` | IV.B.3 | `schema-strict`, warning |

The generic schema is looser than the export schema for two reasons: it allows deprecated
features, and, covering every version from 3.0.2, it leaves out what changed between
versions (ranges; CQZ was a Number before 3.0.6). Only the first is fine to read, so only
that is a warning; ADIF Lint tells the two apart by the spec tables (its own `import-only`,
`normalize` and deprecated `mode-is-submode` findings on the same element).

The schemas are those of the version checked against, the same one the rules follow: the
version chosen in Settings or Check Log (`--adif` on the command line), the newest unless
another is chosen, or with "the version each log declares" (`--adif file`) the file's own
`ADIF_VER`, with a note when it names none ADIF Lint knows. ADIF 3.0.2 published no ADX
schemas, so it and older use 3.0.3's, with a note (`schema-version`).

libxml2 never uses the network, never loads a DTD or an external entity, and is never asked
to expand an entity; ADIF Lint reads field data from text nodes only. libxml2 refuses an
entity bomb by itself ("Detected an entity reference loop"); `fuzz_smoke` checks that it
takes no time, along with 3,000 mutated ADX files.

### ADIF Lint's own checks on ADX

Each record is restated in ADI and `lint()` runs on it: `APP` becomes
`APP_PROGRAMID_FIELDNAME` with its TYPE as indicator, a header's `USERDEF` becomes
`USERDEFn` with its ENUM or RANGE, a record's `USERDEF` its FIELDNAME. Each finding goes back
to the ADX element: its value, its tag or attribute, or the record's end tag. So ADI and ADX
follow the same verified rules. Of `lint()`'s findings:

- Left out, as they are about ADI's syntax: lengths, `_INTL` fields and Intl types, bare LF
  (XML reads CR LF as LF), a header without records, a byte order mark, a missing `<EOR>`,
  and a header USERDEF without a type indicator (the schemas require TYPE).
- Worded for ADX: FIELDID 0 (`xs:unsignedInt` allows it, §IV.B.3 does not), unknown
  fields, user fields not defined in the header, and non-ASCII text, which is an error in
  ADX and reported where the schemas do not look (a record's USERDEF).
- Added: ENUM together with RANGE (§IV.B.3), an IntlString user field with a line break
  (§III.A), and an APP name that ADI cannot carry (§IV.A.4).

There are no length fixes or repairs, and the editing tools (Reformat, Check Log repairs,
the QSO panel, Enrich, the log tools) refuse an ADX file: they work on ADI records.

### What the schemas leave out

Their annotation lists it: duplicate fields; a record's USERDEF against its definition;
ENUM with RANGE; APP values against their TYPE; STATE and MY_STATE codes; CNTY_ALT beyond its
format; CNTY, SUBMODE and CONTEST_ID values (advisory). ADIF Lint's own checks cover each.
Also, once an element is not where the content model allows it, libxml2 skips the rest of
that record, so ADIF Lint alone checks the fields after it.

### The built-in schemas

`spec/adx/` holds the 32 published schemas, unmodified. `tools/gen_adx_schemas.py` checks
each against its SHA-256 in `spec/adx/SOURCE.md` and builds them into
`src/core/adif_adx_schemas.cpp`, restating the one pattern XML Schema 1.0 cannot read: in
3.1.5 to 3.1.8, CNTY_ALT's pattern uses a look-ahead, `(?=[a-zA-Z])`, which .NET's regular
expressions have and XML Schema 1.0's do not (Part 2, Appendix F), so libxml2 refuses the
whole schema. The restatement, two restriction steps whose patterns must both match, was
compared with the original on every region and district shape up to past both length
limits (17,825,799 values, no difference; `spec/adx/SOURCE.md`), and `adx_tests` compares
them again on 3,000 values, with the published pattern run by `std::regex` as the judge.
The generator stops if the pattern is not exactly where it expects.

### The schemas and the ADI rules (2026-11-01)

`adx_tests` builds every ADIF 3.1.8 record field with values from its data type and
enumeration: every enumeration value in upper and lower case, and boundary and malformed
values (9,347 in all, Intl fields aside). Each is judged twice, by the 3.1.8 schemas as ADX
and by `lint()` as ADI. 8,644 agree; each of the other 703 must have one of these reasons,
or the test fails:

| Reason | Values | Which is right |
|---|---|---|
| SUBMODE of another MODE | 374 | ADIF Lint: the schemas do not relate fields |
| An empty element of a typed field | 115 | Both: ADX's `<AGE/>` is a value, and no Number; ADI's `<AGE:0>` is no value (§III.C.1.b) |
| ADIF Lint warns where the schema reports an error: non-ASCII in ADI, GRIDSQUARE_EXT over 4, VUCC_GRIDS count or sizes, SOTARef, SponsoredAwardList, CNTY_ALT codes, placeholders such as `-` | 121 | Both, by design (see "gentler" above); in ADX the schema's error stands |
| A real day of the month | 32 | ADIF Lint: a pattern cannot count days |
| Spaces around a number (` 1`) | 30 | ADIF Lint: ADIF's Number has none; `xs:decimal` drops them |
| LAT north or south, LON east or west, at most 90 and 180 degrees | 20 | ADIF Lint: the schemas have one Location type |
| SUBMODE under 3 characters; DARC_DOK not letters and digits | 7 | ADIF Lint: SUBMODE is a String with an advisory list (the schemas' own annotation), and DOKs are DARC's |
| USACA_COUNTIES with one county | 4 | ADIF Lint: the field is two counties |

It found three ADI rules weaker than the specification, now fixed: SponsoredAwardList
checked only the sponsor, not the rest of `SPONSOR_PROGRAM_AWARD` (`ARRL_DXCC` passed);
SOTARef took any number of digits; and VUCC_GRIDS mixing 4- and 6-character locators passed.

## Checks beyond the specification

Notes and warnings for what services expect, labelled as such in their messages: BAND
when FREQ is present (POTA reads BAND), upper-case callsigns and states, no QSO dates in
the future, STATION_CALLSIGN or OPERATOR in POTA activation records, PROP_MODE SAT with
SAT_NAME, placeholders such as IOTA `none`, and a Field Day class written in ARRL_SECT.

## Repeating the verification

```sh
cmake --build build && ctest --test-dir build
build/adiflint tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adi
build/adiflint tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adx
python3 tools/gen_spec_tables.py spec/adif-3.1.8/all.json /tmp/regen.cpp && cmp /tmp/regen.cpp src/core/adif_spec_tables.cpp
python3 -I tools/gen_adx_schemas.py spec/adx /tmp/adx.cpp && cmp /tmp/adx.cpp src/core/adif_adx_schemas.cpp
build/conformance_tests tests/conformance/rules.cases --doc docs/RULES.md
```

A pass is all tests passing, `0 error(s), 0 warning(s)` for the official ADI file, 0 errors
and 0 warnings from both checks for the ADX one, no output from either `cmp`, and
`conformance_tests` reporting every check passed (RULES.md up to date included).
