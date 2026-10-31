# ADIF conformance

What ADIF Lint checks, the source of each rule, and how conformance is verified. ADI and
ADX are different serializations and use different validation sources: the ADI checks below
are based on the ADIF specification and its exported tables; ADX documents are defined by
the version-specific ADX XML Schema (XSD). Section numbers below are those of ADIF 3.1.7,
which 3.1.8 keeps; "Resources" means the ADIF 3.1.7 Resources document.

ADIF 3.1.8 (2026-10-12) changed only enumeration values: submode JTTY (of MFSK), contest IDs
SKCC-SKS, SKCC-SKSA, SKCC-SKSE and SKCC-WES, and WAE for European Turkey's region (its section
1.F). The tables are now generated from 3.1.8's export, so the rules below hold as verified,
with 3.1.8's values. Checks against an older version (Settings, `--adif`) use what that
version's specification holds, read as `spec/adif-history.md` describes.

## Sources

| Source | Where | Checked |
|---|---|---|
| ADIF 3.1.7 specification (released 2026-03-22), the rules' text | <https://www.adif.org/317/ADIF_317.htm> (SHA-256 `b7667032…c5c97`) | 2026-10-10 |
| ADIF 3.1.8 specification (released 2026-10-12) | `spec/adif-3.1.8/ADIF_318.htm`, from <https://adif.org.uk/318/ADIF_318.htm> | 2026-10-26: SHA-256 `9d130f55…7fe6`; adif.org lists 3.1.8 as current |
| ADX 3.1.8 XML Schema (schema version 3.1.8.0) | <https://www.adif.org/318/adx318.xsd> | 2026-10-30: SHA-256 `306f9bc6…1d812c`; schema annotation dated 2026-09-26 |
| Exported tables (`all.json`) | `spec/adif-3.1.8/all.json`, from <https://adif.org.uk/318/ADIF_318_resources_2026_10_12.zip> | 2026-10-26: `tools/gen_spec_tables.py` regenerates `src/core/adif_spec_tables.cpp` byte for byte |
| ADIF 3.0.2 to 3.1.8, what each holds | `spec/adif-history.json`, from each version's specification (`spec/adif-history.md`) | 2026-10-26: the reader matches the 3.1.5 to 3.1.8 exports |
| ADIF 3.1.7 Resources (implementation notes) | <https://adif.org.uk/317/ADIF_317_resources.htm> (the spec's relative link 404s on adif.org) | 2026-10-10 |
| Official test QSOs | `tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adi` (6,202 QSOs, every field and value) | lints with 0 errors and 0 warnings |

For ADX, use the XSD published for the document's ADIF specification version. The schema
version may have an extra component: ADIF 3.1.8 uses schema version 3.1.8.0. Do not infer
that a schema version label is itself the ADIF `ADIF_VER` value. Since `ADIF_VER` is
optional in the 3.1.8 schema, a validator that selects a schema automatically must require
an explicit version choice when the document does not identify one; it should not silently
validate against the newest version.

The 3.1.8 XSD describes the ADX structure and the field types, patterns, ranges, and
enumerations that can be represented in XML Schema 1.0. It is specifically an export
schema and disallows deprecated features. For importing an ADX document when its ADIF
version is not known in advance, the schema documentation points to the corresponding
generic schema, which permits deprecated features. Follow the schema published for each
specification version rather than applying the newest XSD to every ADX document.

The schema is not a complete substitute for every ADIF rule. Its own annotation documents
XML Schema 1.0 limitations and omitted checks. For 3.1.8, examples include not checking
duplicate fields across data specifiers; not validating some long administrative-subdivision
enumerations and user-defined field relationships; and treating CONTEST_ID, SUBMODE, and
some externally maintained county codes as advisory or out of scope. Any ADX validator
should report its XSD result separately from additional semantic or service-specific checks.

ADX schema reference in this document does not mean ADIF Lint currently parses or validates
ADX files. The plugin and CLI currently validate ADI; schema-based ADX support would be a
separate implementation change.

The 3.1.8 XSD source and its documented scope were checked on 2026-10-30 (SHA-256 recorded
above). This verifies the reference used here, not an ADIF Lint ADX validator or a corpus of
ADX files.

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

| Rule | Section | Severity |
|---|---|---|
| `<F:L:T>` syntax: name, unsigned decimal length, one-letter type indicator, all case-insensitive | IV.A.1 | error |
| Data length matches the data (too short, too long, past the end) | IV.A.1 | error, Fix Lengths |
| Leading zeros in a length are import-only | IV.A.1, Resources III.B | warning, Fix Lengths |
| A header starts with any character but `<` and ends with `<EOH>`; one header, before the records | IV.A.2, IV.A.3 | error / warning |
| Every record ends with `<EOR>`; an empty record | IV.A.6 | error / warning |
| A file has one or more records (*added 2026-10-10*) | IV.A.2 | note |
| No field twice in a header or a record | III.C.1.a, III.C.1.b | error |
| An empty value takes the field's default | III.C.1.b | (not reported) |
| Unknown field; header field in a record and the reverse; import-only fields (GUEST_OP, VE_PROV) | III.C, II.B | warning |
| `_INTL` fields (IntlString, IntlMultilineString) cannot be used in ADI | IV.A.1 | error |
| Type indicator: one of B N D T S I M G E L; one that contradicts the field | III.A | error / warning |
| Date: 8 digits, year 1930 or later, real month and day | III.A | error |
| Time: HHMM or HHMMSS, in range | III.A | error |
| Number: optional `-`, digits, at most one `.` (no `+`, `,`, exponent) | III.A, Resources III.A | error |
| Integer, PositiveInteger (> 0, leading zeros allowed) | III.A | error |
| Minimum and maximum values from the field table (CQZ 1-40, AGE 0-120, K_INDEX 0-9…) | III.C.1.b | error |
| ANT_AZ, ANT_EL outside their ranges are import-only, normalized on export (*corrected 2026-10-10*) | ANT_AZ, ANT_EL definitions | warning, repair |
| Boolean: Y, y, N, n | III.A | error |
| String: ASCII 32-126; MultilineString: plus CR LF line breaks | III.A | error (controls) |
| GridSquare: 2, 4, 6 or 8 characters (A-R, 0-9, A-X, 0-9) | III.A, III.A.1 | error |
| GridSquareExt: 2 or 4 characters (A-X, 0-9) | III.A | error |
| GRIDSQUARE_EXT longer than 4: importers ignore the rest (*added*) | GRIDSQUARE_EXT definition | warning, repair |
| GRIDSQUARE_EXT needs an 8-character GRIDSQUARE (*added*) | GRIDSQUARE_EXT definition | warning |
| GridSquareList; VUCC_GRIDS two or four adjacent locators of 4 or 6 characters (*added*) | III.A, III.A.1, VUCC_GRIDS definition | error (length) / warning |
| GRIDSQUARE should agree with VUCC_GRIDS (*added*) | III.A.1 | warning |
| Location: `XDDD MM.MMM`, DDD 0-180, minutes below 60 | III.A | error |
| LAT, MY_LAT north or south; LON, MY_LON east or west; at most 90 and 180 degrees (*added*) | field meaning (inference) | error |
| IOTARefNo `CC-XXX`, CC a continent, 001-999 | III.A | error |
| POTARef `xxxx-nnnnn[@yyyyyy]`, 6-17 characters; POTARefList | III.A | error |
| WWFFRef `xxFF-nnnn`, 8-11 characters | III.A | error |
| SOTARef `prefix[/subdivision]/number` (loosely worded in the spec) | III.A | warning |
| CreditList `CREDIT[:MEDIUM&MEDIUM]`; Award values are import-only | III.A, III.B.7 | error / warning |
| SponsoredAwardList: `SPONSOR_PROGRAM_AWARD` with a listed sponsor | III.B.24 | warning |
| SecondarySubdivisionList: two or more `state,county` separated by `:` (*added*) | III.A, III.B.22 | error / warning |
| SecondaryAdministrativeSubdivisionListAlt: `name:code` items, each name once, codes from ADIF's table (*added*) | III.A, III.B.23 | error / warning |
| Enumeration values, case-insensitive; import-only values with the spec's advice | III.B, II.B | error / warning |
| Deleted codes valid only for QSOs in their dates: ARRL sections, REGION KO, Russian and Austrian districts (*added*) | II.C, III.B.2, III.B.12, III.B.21 | warning, repair when one replacement is named |
| REGION belongs to the record's DXCC entity (*added*) | III.B.21 | warning |
| STATE and CNTY codes of the record's DXCC entity (66 entities have lists) | III.B.12, III.B.22 | warning |
| SUBMODE belongs to MODE | III.B.25 | error |
| FREQ inside BAND, FREQ_RX inside BAND_RX (edges included) | III.B.4 | warning |
| QSL dates only with a status that allows them; statuses default to N (*added*) | QSLRDATE, QSLSDATE… definitions | warning |
| STATE, CNTY, MY_STATE, MY_CNTY without their DXCC: one note per file (*added*) | I.E | note |
| Guideline minimum fields (QSO_DATE, TIME_ON, CALL, BAND or FREQ, MODE) | I.E, Resources III.C | note |
| CONTEST_ID, SUBMODE values not in ADIF's lists (the fields are Strings) | III.C.1.b | note |
| Header fields ADIF_VER (`X.Y.Z`, Y and Z 0-9) and CREATED_TIMESTAMP (`YYYYMMDD HHMMSS`) | III.C.1.a | warning / error |
| USERDEFn: n a positive integer; name not an ADIF field, no `, : < > { }`, no outer spaces; `{A,B}` or `{low:high}` with low < high; values checked in records | IV.A.5 | error / warning |
| APP_PROGRAMID_FIELDNAME; untyped means MultilineString; later occurrences keep the first type (*untyped case added*) | IV.A.4 | warning / error |

## Where ADIF Lint is gentler than the specification

These are deliberate, so that common real-world logs stay readable:

- **Non-ASCII text** in a String field is a warning, not an error. ADI is ASCII only, but
  many programs write UTF-8; the length unit is a setting.
- **A bare CR or LF** in a MultilineString is a warning; the specification asks for CR LF.
- **A STATE or CNTY not on its entity's list** is a warning: callbooks fill these from
  profiles (QRZ.com writes `H` for Hungary).
- **A header with no records** is a note: Start Activation and New QSO create such a log
  before its first QSO.
- **A type indicator that contradicts the field** is a warning.
- **A USERDEFn without a type indicator** is a warning. The specification's grammar
  (§IV.A.5) includes it, while its sample header (§IV.A.3) leaves one out.
- **A DXCC code with leading zeros** (`0291`) is read as the number.

## What the current ADI validator cannot check

- Values from lists the specification refers to but does not include: DARC_DOK, CNTY
  for most entities (US counties, Japanese cities…), Country names.
- Deleted DXCC entities and deleted Alaska boroughs: the specification marks them deleted
  but gives no dates.
- Contest IDs' end dates, which are only in their descriptions.
- ADX (XML) files: ADIF Lint reads ADI. For ADX, use the version-specific XSD described
  above; ADIF Lint does not currently perform that schema validation.

## Checks beyond the specification

Notes and warnings for what services expect, labelled as such in their messages: BAND
when FREQ is present (POTA reads BAND), upper-case callsigns and states, no QSO dates in
the future, STATION_CALLSIGN or OPERATOR in POTA activation records, PROP_MODE SAT with
SAT_NAME, placeholders such as IOTA `none`, and a Field Day class written in ARRL_SECT.

## Repeating the verification

```sh
cmake --build build && ctest --test-dir build
build/adiflint tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adi
python3 tools/gen_spec_tables.py spec/adif-3.1.8/all.json /tmp/regen.cpp && cmp /tmp/regen.cpp src/core/adif_spec_tables.cpp
```

A pass is all tests passing, `0 error(s), 0 warning(s)` for the official file, and no
output from `cmp`.
