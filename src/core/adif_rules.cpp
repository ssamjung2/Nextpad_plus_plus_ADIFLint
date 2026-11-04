// The rule catalogue (adif_rules.h). Sections are ADIF 3.1.8's, which keep 3.1.7's
// numbering; "Resources" is the ADIF Resources document. Each entry was written from the
// specification's text, read for this table on 2026-11-02 (spec/adif-3.1.8/ADIF_318.htm).
#include "adif_rules.h"

#include <algorithm>
#include <cstring>

namespace adif {
namespace {

const char *const kGroups[] = {
    "ADI structure",      "ADX structure", "Header",       "Fields", "Data types",   "Enumerations",       "Field definitions",
    "Between fields",     "User-defined fields", "Application-defined fields", "ADX schemas", "Versions", "Practice",
    "ADIF Lint itself",
};

constexpr unsigned char A = kRuleAdi, X = kRuleAdx, B = kRuleBoth;

const Rule kRules[] = {
    // ── ADI structure (§IV.A) ──
    {"tag-syntax", "ADI structure", "IV.A.1", A, "error, warning",
     "A data specifier is <F:L> or <F:L:T>: a field name, a colon, an unsigned decimal length, and optionally a colon and a one-letter "
     "type indicator, in angle brackets.",
     "An error when the text was meant as a specifier (it has a colon or names a field), else a warning for a stray '<'.", nullptr},
    {"length", "ADI structure", "IV.A.1", A, "error",
     "L is the length of the data D that follows the specifier: importers read exactly L bytes (or characters, a setting).",
     "Also reported when the data ends with a line break that L counts. Fix Lengths repairs it.", nullptr},
    {"length-zeros", "ADI structure", "IV.A.1, Resources III.B", A, "warning", "A data length has no leading zeros: they are import-only.",
     "Fix Lengths removes them.", nullptr},
    {"length-swallows", "ADI structure", "IV.A.1", A, "warning",
     "The data holds no well-formed data specifier: if it does, a length that is too long has swallowed the next field.", "A heuristic.",
     nullptr},
    {"missing-lt", "ADI structure", "IV.A.6", A, "warning",
     "Text outside data specifiers is ignored, so what looks like a specifier missing its '<' (CALL:4>W1AW) is lost with its data.", "",
     nullptr},
    {"bom", "ADI structure", "III.A, IV.A", A, "warning", "An ADI file is ASCII, so it has no UTF-8 byte order mark.",
     "Some importers reject the mark; the repair removes it.", nullptr},
    {"eoh-missing", "ADI structure", "IV.A.3", A, "error, warning, note",
     "A file that does not start with '<' starts with a header, which <EOH> ends.",
     "An error when the file holds only header fields, a warning when text begins a header that records follow, a note when only "
     "white space comes before the first '<'.",
     nullptr},
    {"eoh-no-header", "ADI structure", "IV.A.3", A, "warning", "A file that starts with '<' has no header, so it has no <EOH>.", "", nullptr},
    {"eoh-twice", "ADI structure", "IV.A.2", A, "error", "A file has at most one header, so one <EOH>.", "", nullptr},
    {"eoh-late", "ADI structure", "IV.A.2", A, "error", "The header comes before the records.", "", nullptr},
    {"no-eor", "ADI structure", "IV.A.6", A, "error", "Every record ends with <EOR>.", "The repair adds it.", nullptr},
    {"empty-record", "ADI structure", "IV.A.6", B, "warning", "A record is one or more fields, then <EOR> (in ADX, a RECORD element).",
     "The ADX schemas allow an empty RECORD, which carries no QSO all the same.", nullptr},
    {"no-records", "ADI structure", "IV.A.2", A, "note", "An ADI file has one or more records.",
     "A note: Start Activation and New QSO create a log before its first QSO. ADX allows zero records (IV.B).", nullptr},

    // ── ADX structure (§IV.B) ──
    {"xml", "ADX structure", "IV.B; XML 1.0", X, "error, warning", "An ADX file is well-formed XML.",
     "Only the first error is reported: what follows mostly follows from it, and nothing else is checked.", nullptr},
    {"adx-encoding", "ADX structure", "IV.B", X, "error", "An ADX file is UTF-8; an XML declaration names no other encoding.", "", nullptr},
    {"adx-doctype", "ADX structure", "IV.B.1", X, "error", "An ADX file has no document type declaration (<!DOCTYPE ...>).", "", nullptr},
    {"adx-entity", "ADX structure", "IV.B.1", X, "error", "An ADX file uses no entities but those XML predefines (&amp; &lt; &gt; &apos; &quot;).",
     "Character references (&#233;) are not entities and are fine. An entity that is not declared at all is an xml error.", nullptr},
    {"adx-cdata", "ADX structure", "IV.B.1", X, "error", "A field's element holds no CDATA section.",
     "CDATA between fields, in a RECORD's mixed content, is allowed. XML namespaces and processing instructions are ignored, as IV.B.1 "
     "says.",
     nullptr},

    // ── Header (§III.C.1.a) ──
    {"adif-ver", "Header", "III.C.1.a", B, "warning", "ADIF_VER is X.Y.Z, X an integer and Y and Z digits.", "", nullptr},
    {"created-timestamp", "Header", "III.C.1.a", B, "error", "CREATED_TIMESTAMP is 'YYYYMMDD HHMMSS': a Date, a space and a 6-digit Time, UTC.",
     "", nullptr},

    // ── Fields (§III.C) ──
    {"unknown-field", "Fields", "III.C, IV.A.4, IV.A.5, IV.B.2, IV.B.3", B, "warning",
     "A field is an ADIF field of the version checked, an application-defined field (APP_...) or a user-defined field the header defines.",
     "In ADX, a record's USERDEF must name a field the header defines.", nullptr},
    {"field-version", "Fields", "II.A, III.C", B, "warning", "A field belongs to the ADIF version the file is checked against.",
     "The message names the version that brought the field.", nullptr},
    {"field-place", "Fields", "III.C.1.a, III.C.1.b, IV.A.5", B, "warning",
     "Header fields (and USERDEFn) are in the header, QSO fields in records.", "", nullptr},
    {"dup-field", "Fields", "III.C.1.a, III.C.1.b", B, "error", "No field name appears twice in the header, nor twice in one record.",
     "A repair is offered when both copies agree or one is empty.", nullptr},
    {"import-only", "Fields", "II.B", B, "warning",
     "Deprecated (import-only) fields, enumeration values and data types are read on import but not written on export.",
     "The repair applies the replacement the specification names.", nullptr},
    {"intl-adi", "Fields", "IV.A.1, III.A", A, "error, note", "Fields of the Intl types (IntlString, IntlMultilineString) are not used in ADI files.",
     "A note for a USERDEF of an Intl type: it is fine, but can carry data only in ADX.", nullptr},
    {"indicator", "Fields", "III.A, IV.A.1", B, "error, warning",
     "A data type indicator is one of the letters III.A lists (B N D T S I M G E L), and agrees with the field's type.",
     "An unknown letter is an error, one that contradicts the field a warning. In ADX, APP's and USERDEF's TYPE.", nullptr},

    // ── Data types (§III.A) ──
    {"type-boolean", "Data types", "III.A", B, "error", "A Boolean is Y, y, N or n.", "", nullptr},
    {"type-integer", "Data types", "III.A", B, "error", "An Integer is one or more digits, optionally after a minus sign.", "", nullptr},
    {"type-positive-integer", "Data types", "III.A", B, "error", "A PositiveInteger is one or more digits, with a value greater than 0.", "",
     nullptr},
    {"type-number", "Data types", "III.A, Resources III.A", B, "error",
     "A Number is one or more digits, optionally after a minus sign and with at most one decimal point: no '+', ',', exponent or spaces.",
     "", nullptr},
    {"power-unit", "Data types", "III.A, TX_PWR, RX_PWR", B, "error", "TX_PWR and RX_PWR are Numbers of watts, without a unit (30, not 30W).",
     "The repair converts the value to watts.", nullptr},
    {"date-format", "Data types", "III.A", B, "error", "A Date is YYYYMMDD: a year from 1930, a month 01-12 and a day that month has.",
     "The repair rewrites 2024-01-15 as 20240115.", nullptr},
    {"time-format", "Data types", "III.A", B, "error", "A Time is HHMM or HHMMSS: hours 00-23, minutes and seconds 00-59.",
     "The repair rewrites 18:30 as 1830.", nullptr},
    {"type-grid", "Data types", "III.A, III.A.1", B, "error",
     "A GridSquare is a 2, 4, 6 or 8 character Maidenhead locator: A-R, A-R, 0-9, 0-9, A-X, A-X, 0-9, 0-9.", "", nullptr},
    {"type-grid-ext", "Data types", "III.A", B, "error", "A GridSquareExt is a locator's characters 9 and 10 (A-X), and optionally 11 and 12 (0-9).",
     "", nullptr},
    {"type-grid-list", "Data types", "III.A", B, "error", "A GridSquareList is a comma-separated list of GridSquares.", "", nullptr},
    {"type-location", "Data types", "III.A", B, "error",
     "A Location is XDDD MM.MMM: N, S, E or W, three-digit degrees up to 180, a space, and minutes 00.000-59.999.", "", nullptr},
    {"type-iota", "Data types", "III.A", B, "error", "An IOTARefNo is CC-XXX: a continent, a dash and an island group from 001 to 999.", "",
     nullptr},
    {"type-pota", "Data types", "III.A", B, "error",
     "A POTARef is xxxx-nnnnn[@yyyyyy], 6 to 17 characters (program, 4 or 5 digits, optionally an ISO 3166-2 location); a POTARefList, "
     "comma-separated POTARefs.",
     "", nullptr},
    {"type-sota", "Data types", "III.A; adx318.xsd", B, "warning",
     "A SOTARef is association/region-number: 1 to 8 letters or digits, '/', two letters, '-', three digits but not 000.",
     "The specification's wording is loose; the parts' sizes are the published schemas'. Hence only a warning.", nullptr},
    {"type-wwff", "Data types", "III.A", B, "error", "A WWFFRef is xxFF-nnnn, 8 to 11 characters: a 1-4 character program, FF-, four digits.", "",
     nullptr},
    {"type-credit", "Data types", "III.A, III.B.7, III.B.14", B, "error",
     "A CreditList is comma-separated Credit values, each optionally followed by ':' and QSL_Medium values joined by '&'.",
     "Award values (the import-only AwardList) are import-only warnings instead.", nullptr},
    {"type-sponsored-award", "Data types", "III.A, III.B.24", B, "warning",
     "A SponsoredAwardList is comma-separated SPONSOR_PROGRAM_AWARD values, SPONSOR_ one of the listed sponsors.",
     "A warning: the program and award parts are the sponsor's to define.", nullptr},
    {"type-county-list", "Data types", "III.A, III.B.22", B, "error, warning",
     "A SecondarySubdivisionList is two or more state,county items separated by ':' (MA,Franklin:MA,Hampshire).",
     "An error for fewer than two items, a warning for an item that is not a US state and county.", nullptr},
    {"type-subdivision-alt", "Data types", "III.A", B, "error",
     "A SecondaryAdministrativeSubdivisionListAlt is ';'-separated enumeration-name:code items, each enumeration-name once.", "", nullptr},
    {"type-character", "Data types", "III.A", B, "error", "A Character is one ASCII character, 32 to 126.", "",
     "No ADIF field has this type, and no type indicator names it."},
    {"type-digit", "Data types", "III.A", B, "error", "A Digit is one character 0 to 9.", "", "No ADIF field has this type, and no type indicator names it."},
    {"type-value", "Data types", "III.A", B, "error", "A value is of its field's data type.", "", "The fallback for a type the checks above do not name: none is left."},
    {"control-char", "Data types", "III.A", B, "error",
     "Strings hold ASCII 32 to 126; MultilineStrings also CR LF line breaks; no other control characters.", "", nullptr},
    {"line-break", "Data types", "III.A", A, "warning", "A line break in a MultilineString is CR followed by LF.",
     "A warning, as many programs write LF alone. Not for ADX, where XML reads CR LF as LF.", nullptr},
    {"non-ascii", "Data types", "III.A", B, "warning, error",
     "Characters outside ASCII are only in the Intl types (and so only in ADX).",
     "A warning in ADI, as programs write UTF-8 there and the length unit is a setting; an error in ADX, reported where the schemas do not "
     "look (a record's USERDEF).",
     nullptr},
    {"intl-line-break", "Data types", "III.A", X, "error", "An IntlString holds no line breaks (an IntlMultilineString may).",
     "For user-defined and application-defined fields of type I; the schemas check the _INTL fields.", nullptr},

    // ── Enumerations (§III.B, §II.B, §II.C) ──
    {"enumeration", "Enumerations", "III.B", B, "error",
     "An Enumeration field's value is one of its enumeration's values (case-insensitive) in the version checked.", "", nullptr},
    {"advisory-list", "Enumerations", "III.C.1.b, III.B.5, III.B.25", B, "note",
     "CONTEST_ID and SUBMODE are Strings whose enumerations are advisory: other values are allowed.",
     "A note for a value not on the list, in case it is a misspelling.", nullptr},
    {"deleted-code", "Enumerations", "II.C", B, "warning",
     "A deleted enumeration value is only used for QSOs within the dates it was valid (ARRL sections, regions, Russian and Austrian districts).",
     "The repair applies the replacement when the specification names one valid on the QSO's date.", nullptr},
    {"mode-is-submode", "Enumerations", "III.B.10, III.B.25", B, "error, warning",
     "MODE is a Mode value; a submode (USB, FT4) goes in SUBMODE with its MODE.",
     "A warning for a MODE value that was a mode and is now import-only (C4FM), an error for one that never was.", nullptr},
    {"subdivision", "Enumerations", "III.B.12, III.B.22", B, "warning",
     "STATE and CNTY (and MY_) are codes of the record's DXCC entity, for the entities ADIF lists them for.",
     "A warning: callbooks fill these from profiles. Other entities' values are not checked.", nullptr},
    {"region-dxcc", "Enumerations", "III.B.21", B, "warning", "REGION is a region of the record's DXCC entity.", "", nullptr},
    {"subdivision-alt", "Enumerations", "III.B.23", B, "warning, note",
     "CNTY_ALT's codes are from ADIF's table for the enumeration-name, for the entity it belongs to.",
     "A note for an enumeration-name ADIF lists no codes for.", nullptr},

    // ── Field definitions (§III.C.1.b) ──
    {"range", "Field definitions", "III.C.1.b, IV.A.5, IV.B.3", B, "error",
     "A value is within its field's minimum and maximum (CQZ 1-40, AGE 0-120...), and a user field's within its RANGE.", "", nullptr},
    {"normalize", "Field definitions", "ANT_AZ, ANT_EL", B, "warning", "ANT_AZ is 0 to 360 and ANT_EL -90 to 90: values outside are import-only.",
     "The repair writes the normalized value (370 as 10).", nullptr},
    {"vucc-grids", "Field definitions", "VUCC_GRIDS, III.A.1", B, "error, warning",
     "VUCC_GRIDS and MY_VUCC_GRIDS hold two or four adjacent locators, all 4 or all 6 characters.",
     "An error for a locator that is not 4 or 6 characters, a warning for the count, mixed sizes or squares that do not touch.", nullptr},
    {"grid-ext-length", "Field definitions", "GRIDSQUARE_EXT", B, "warning",
     "GRIDSQUARE_EXT is written 2 or 4 characters long; importers ignore the rest.", "The repair keeps the first four.", nullptr},
    {"grid-ext-base", "Field definitions", "GRIDSQUARE_EXT", B, "warning",
     "GRIDSQUARE_EXT holds a locator's characters 9 and on, so GRIDSQUARE holds its first 8.", "", nullptr},
    {"lat-lon", "Field definitions", "LAT, LON, MY_LAT, MY_LON", B, "error",
     "LAT and MY_LAT are latitudes (N or S, at most 90 degrees); LON and MY_LON longitudes (E or W, at most 180).",
     "Read from the fields' meaning: the Location type allows any direction.", nullptr},
    {"qsl-date", "Field definitions", "QSLRDATE, QSLSDATE, LOTW_, EQSL_, DCL_...", B, "warning",
     "A QSL date is only valid with a status that allows it: received Y, I or V; sent Y, Q or I (a missing status is N).", "", nullptr},

    // ── Between fields ──
    {"submode-mode", "Between fields", "III.B.25", B, "error", "SUBMODE is a submode of the record's MODE.",
     "The repair sets MODE to the submode's.", nullptr},
    {"mode-missing", "Between fields", "III.B.25", B, "warning", "A record with SUBMODE has MODE too.", "The repair adds the submode's MODE.",
     nullptr},
    {"freq-band", "Between fields", "III.B.4", B, "warning", "FREQ lies within BAND, and FREQ_RX within BAND_RX (edges included).",
     "A repair is offered for a FREQ written in kHz.", nullptr},
    {"grid-agree", "Between fields", "III.A.1", B, "warning", "GRIDSQUARE agrees with VUCC_GRIDS, and MY_GRIDSQUARE with MY_VUCC_GRIDS.", "",
     nullptr},
    {"depends", "Between fields", "I.E", B, "note", "STATE and CNTY are exported with DXCC, MY_STATE and MY_CNTY with MY_DXCC.",
     "One note per file, counting the records.", nullptr},

    // ── User-defined fields (§IV.A.5, §IV.B.3) ──
    {"userdef-id", "User-defined fields", "IV.A.5, IV.B.3", B, "warning", "In USERDEFn (ADX: FIELDID), n is a positive integer.",
     "In ADX the schemas allow 0 (xs:unsignedInt); IV.B.3 does not.", nullptr},
    {"userdef-type", "User-defined fields", "IV.A.5", A, "warning", "A USERDEFn gives a data type indicator.",
     "A warning: IV.A.5's grammar has one while IV.A.3's sample header leaves it out. In ADX the schemas require TYPE.", nullptr},
    {"userdef-name", "User-defined fields", "III.C.1.a, IV.A.5", B, "error",
     "A user-defined field's name is not an ADIF field's, has no , : < > { }, and does not begin or end with a space.", "", nullptr},
    {"userdef-values", "User-defined fields", "IV.A.5, IV.B.3", B, "error",
     "A USERDEF's enumeration is {A,B,...} and its range {low:high}, both Numbers with low below high.", "", nullptr},
    {"userdef-dup", "User-defined fields", "IV.A.5", B, "error", "No user-defined field is defined twice.", "", nullptr},
    {"userdef-value", "User-defined fields", "IV.A.5, IV.B.3", B, "error", "A user-defined field's value is one of its enumeration's values.",
     "The schemas do not check a record's USERDEF against its definition; ADIF Lint does.", nullptr},
    {"userdef-enum-range", "User-defined fields", "IV.B.3", X, "error", "A USERDEF has ENUM or RANGE, not both.", "", nullptr},

    // ── Application-defined fields (§IV.A.4, §IV.B.2) ──
    {"app-name", "Application-defined fields", "IV.A.4, IV.B.2", B, "warning",
     "An application-defined field is APP_PROGRAMID_FIELDNAME, with no , : < > { } and no trailing space.",
     "In ADX, a PROGRAMID or FIELDNAME that ADI could not carry.", nullptr},
    {"app-type", "Application-defined fields", "IV.A.4, IV.B.2", B, "error",
     "An application-defined field keeps the data type of its first occurrence; without an indicator, that is MultilineString.", "", nullptr},

    // ── ADX schemas (§IV.B.5, §V.A) ──
    {"schema", "ADX schemas", "IV.B.5, V.A", X, "error",
     "An ADX file is valid against the XML Schemas published for its ADIF version: the generic one, and the export one except for what "
     "the specification makes import-only.",
     "Both run, from spec/adx/. The generic schema covers every version up to its own, so it leaves out ranges and types that changed.",
     nullptr},
    {"schema-export", "ADX schemas", "II.B, IV.B.5", X, "warning",
     "What the version's export schema rejects and the specification makes import-only is read, not written.", "", nullptr},
    {"schema-strict", "ADX schemas", "IV.B.3", X, "warning",
     "Where the schemas are stricter than the specification, a record's USERDEF may carry TYPE (ignored) and a FIELDNAME in mixed case.",
     "A warning, for programs that validate.", nullptr},
    {"schema-version", "ADX schemas", "V.A", X, "note",
     "The schemas are those of the version checked; 3.0.2 published none, so it and older use 3.0.3's.", "", nullptr},

    // ── Versions ──
    {"version-mismatch", "Versions", "II.A, III.C.1.a", B, "note", "The checks follow an older ADIF version than the one the file declares.",
     "Choose the version in Settings or Check Log, or the file's own.", nullptr},
    {"version-missing", "Versions", "III.C.1.a", B, "note",
     "The file's own version was asked for, but its ADIF_VER names none this build knows, so the version in use applies.", "", nullptr},

    // ── Practice: ADIF's guideline, and what services expect beyond the specification ──
    {"minimum-fields", "Practice", "I.E, Resources III.C", B, "note",
     "A QSO record has QSO_DATE, TIME_ON, CALL, BAND or FREQ, and MODE: ADIF's suggested minimum.", "", nullptr},
    {"placeholder", "Practice", "III.C.1.b", B, "warning",
     "A field without a value is left out, rather than holding a placeholder (none, n/a, -, ?, unknown) its type does not allow.",
     "A warning, with removal of the field as the repair.", nullptr},
    {"case", "Practice", "LoTW, POTA", B, "note", "CALL, STATION_CALLSIGN, OPERATOR, STATE and MY_STATE are written in upper case.",
     "Beyond the specification, which makes most values case-insensitive.", nullptr},
    {"band-missing", "Practice", "POTA", B, "note", "A record with FREQ has BAND too: POTA reads BAND only.", "", nullptr},
    {"future-date", "Practice", "POTA", B, "warning", "QSO_DATE is not after today (UTC).", "", nullptr},
    {"sat-name", "Practice", "LoTW", B, "note", "A satellite QSO (PROP_MODE SAT) names the satellite in SAT_NAME.", "", nullptr},
    {"sat-prop", "Practice", "LoTW", B, "warning", "A record with SAT_NAME has PROP_MODE SAT.", "", nullptr},
    {"pota-station", "Practice", "POTA", B, "note", "Each record of a POTA activation log has STATION_CALLSIGN or OPERATOR.", "", nullptr},
    {"field-day-class", "Practice", "III.B.2", B, "error", "ARRL_SECT holds a section, not a Field Day class such as 1D (which goes in CLASS).",
     "The ARRL_SECT enumeration error, with the repair that moves the class.", nullptr},

    // ── ADIF Lint itself ──
    {"adx-internal", "ADIF Lint itself", "", X, "error", "ADIF Lint could read the XML and apply the built-in schemas.", "",
     "Only when libxml2 cannot: a file over 2 GB, or a schema that does not compile (adx_tests compiles each one)."},
};

const Unchecked kUnchecked[] = {
    {"I.E", "Applications decide which fields to support; a dependent field should be exported with the field it depends on.",
     "Only STATE, CNTY and their MY_ forms name what they depend on (DXCC, MY_DXCC); they are checked (depends)."},
    {"II.A", "Each ADIF version is upward compatible with the earlier ones.", "A rule for the specification, not for a file."},
    {"III.A", "Digit, Character and IntlCharacter data types.", "No field has them and no type indicator names them."},
    {"III.A.1", "Locators are based on WGS-84; applications using other encodings convert them.", "Not visible in a file."},
    {"III.B.8", "Deleted DXCC entities.", "The specification marks them deleted but gives no dates (II.C needs the dates)."},
    {"III.B.22", "CNTY values for most entities (US counties, Japanese cities...), and deleted Alaska boroughs.",
     "Their lists are external, or have no dates; CNTY is checked for the entities ADIF lists codes for."},
    {"III.B.5", "Contest IDs that have ended.", "Their end dates are only in their descriptions."},
    {"III.C.1.b", "COUNTRY, MY_COUNTRY and DARC_DOK values.", "The specification refers to external lists without including them."},
    {"III.C.2", "The PROGRAMID register.", "It is voluntary."},
    {"IV.A.1", "Field definitions do not limit a data length.", "Nothing to check."},
    {"IV.A.4", "Application-defined fields should include a data type indicator.",
     "A recommendation; without one the field is a MultilineString, which is checked."},
    {"IV.A", "ADI files have the extension .adi; applications should accept .adif.", "A file name, not its content; the plugin checks both."},
    {"IV.B", "Element and attribute names are upper case.", "The schemas check it (schema); ADIF Lint adds a hint."},
    {"IV.B.1", "XML namespaces and processing instructions are ignored.", "ADIF Lint ignores them too: namespaces are removed before validation."},
};

}  // namespace

const Rule *ruleTable(size_t *count) {
    *count = sizeof kRules / sizeof kRules[0];
    return kRules;
}

const Rule *findRule(std::string_view code) {
    for (const Rule &r : kRules)
        if (code == r.code) return &r;
    return nullptr;
}

const char *const *ruleGroups(size_t *count) {
    *count = sizeof kGroups / sizeof kGroups[0];
    return kGroups;
}

const Unchecked *uncheckedTable(size_t *count) {
    *count = sizeof kUnchecked / sizeof kUnchecked[0];
    return kUnchecked;
}

}  // namespace adif
