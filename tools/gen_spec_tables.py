#!/usr/bin/env python3
"""Generate src/core/adif_spec_tables.cpp from the newest ADIF JSON export and the version history.

The input is all.json from the official ADIF 3.1.8 resources archive
(https://adif.org.uk/318/resources, ADIF spec section V.C "Data Files Exported
from ADIF Specification Tables"), and spec/adif-history.json (tools/adif_history.py),
which says which ADIF 3 versions (3.0.2 to 3.1.8) have each field, enumeration value,
data type and band edge. Nothing in the generated tables is typed by hand.

Usage:  python3 tools/gen_spec_tables.py [spec/adif-3.1.8/all.json] [src/core/adif_spec_tables.cpp]
"""
import collections
import datetime
import html
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "spec/adif-3.1.8/all.json"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "src/core/adif_spec_tables.cpp"
# The specification itself: its field tables keep each description's first
# paragraph apart from the notes that the JSON export runs together.
SPEC_HTML = ROOT / "spec/adif-3.1.8/ADIF_318.htm"
HISTORY = ROOT / "spec/adif-history.json"
# The column scoping each enumeration's values, as tools/adif_history.py keys them.
HISTORY_SCOPES = {"Submode": "Mode", "Primary_Administrative_Subdivision": "DXCC Entity Code", "Region": "DXCC Entity Code",
                  "Secondary_Administrative_Subdivision": "DXCC Entity Code",
                  "Secondary_Administrative_Subdivision_Alt": "DXCC Entity Code"}

# DataType enumerators in src/core/adif_spec.h, keyed by the spec's type name.
DATA_TYPES = [
    "AwardList", "CreditList", "SponsoredAwardList", "Boolean", "Digit", "Integer",
    "Number", "PositiveInteger", "Character", "IntlCharacter", "Date", "Time",
    "IOTARefNo", "String", "IntlString", "MultilineString", "IntlMultilineString",
    "Enumeration", "GridSquare", "GridSquareExt", "GridSquareList", "Location",
    "POTARef", "POTARefList", "SecondarySubdivisionList",
    "SecondaryAdministrativeSubdivisionListAlt", "SOTARef", "WWFFRef",
]

# For each enumeration: the column holding the value, and the column (if any)
# that scopes it (Submode -> its Mode, subdivisions -> their DXCC entity).
ENUM_COLUMNS = {
    "Ant_Path": ("Abbreviation", None),
    "ARRL_Section": ("Abbreviation", None),
    "Award": ("Award", None),
    "Award_Sponsor": ("Sponsor", None),
    "Band": ("Band", None),
    "Contest_ID": ("Contest-ID", None),
    "Continent": ("Abbreviation", None),
    "Credit": ("Credit For", None),
    "DXCC_Entity_Code": ("Entity Code", None),
    "EQSL_AG": ("Status", None),
    "Mode": ("Mode", None),
    "Morse_Key_Type": ("Abbreviation", None),
    "Primary_Administrative_Subdivision": ("Code", "DXCC Entity Code"),
    "Propagation_Mode": ("Enumeration", None),
    "QSL_Medium": ("Medium", None),
    "QSL_Rcvd": ("Status", None),
    "QSL_Sent": ("Status", None),
    "QSL_Via": ("Via", None),
    "QSO_Complete": ("Abbreviation", None),
    "QSO_Download_Status": ("Status", None),
    "QSO_Upload_Status": ("Status", None),
    "Region": ("Region Entity Code", "DXCC Entity Code"),
    "Secondary_Administrative_Subdivision": ("Code", "DXCC Entity Code"),
    "Secondary_Administrative_Subdivision_Alt": ("Code", "DXCC Entity Code"),
    "Submode": ("Submode", "Mode"),
}


def cstr(s):
    if s is None:
        return "nullptr"
    s = " ".join(str(s).split())  # collapse the spec's embedded line breaks
    out = []
    for ch in s:
        o = ord(ch)
        if ch in '\\"':
            out.append("\\" + ch)
        elif 32 <= o < 127:
            out.append(ch)
        else:  # keep the generated file ASCII; emit UTF-8 bytes as octal escapes
            out.extend("\\%03o" % b for b in ch.encode("utf-8"))
    return '"' + "".join(out) + '"'


def aupper(s):
    """ASCII-only upper case, matching the C++ comparator (bytes >= 0x80 unchanged)."""
    return "".join(c.upper() if "a" <= c <= "z" else c for c in s)


def sort_key(s):
    return aupper(s).encode("utf-8")


def html_descriptions(path):
    """Field name -> first paragraph of its description in the HTML spec."""
    if not path.exists():
        return {}
    page = path.read_text(encoding="utf-8", errors="replace")
    out = {}
    for m in re.finditer(r'id="(?:QSO|Header)_Field_([A-Za-z0-9_]+)"', page):
        end = page.find("</tr>", m.end())
        cells = re.findall(r"(?is)<td[^>]*>(.*?)</td>", page[m.start():end])
        if len(cells) < 4:
            continue
        first = re.split(r"(?i)<br\s*/?>\s*<br\s*/?>", cells[3])[0]
        text = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", first)).split())
        text = re.sub(r"\s+([,.)])", r"\1", text).replace("( ", "(").rstrip(" .:")
        if text:
            name = m.group(1).upper()
            out["USERDEFn" if name == "USERDEF" else name] = text[0].upper() + text[1:]
    return out


def short_description(text, limit=160):
    """First sentence of a field description, for hints; the full text is in the spec."""
    if not text:
        return None
    text = " ".join(text.replace("\u25cf", " ").split())
    for end in (". ", "; "):
        cut = text.find(end)
        if 0 < cut < limit:
            return text[:cut + 1].rstrip(";") if end == ". " else text[:cut]
    return text if len(text) <= limit else text[:limit - 3].rstrip() + "..."


def truthy(v):
    return str(v).strip().lower() == "true"


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def ymd(v, days=0):
    """'2012-09-11T00:00:00Z' or '2012/01/01' -> '20120911' (plus `days`); None when absent."""
    m = re.match(r"(\d{4})[-/](\d{2})[-/](\d{2})", v or "")
    if not m:
        return None
    d = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3))) + datetime.timedelta(days=days)
    return d.strftime("%Y%m%d")


def name_key(name):
    """A subdivision name for comparison: no accents, case or punctuation ("Nuevo León" = "Nuevo Leon")."""
    n = unicodedata.normalize("NFKD", name or "")
    n = "".join(c for c in n if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]", "", n)


def current_codes_by_name(enum):
    """(DXCC, name key) -> codes of the subdivisions that are neither import-only nor deleted."""
    out = collections.defaultdict(list)
    for rec in enum["Records"].values():
        if not truthy(rec.get("Import-only")) and not truthy(rec.get("Deleted")):
            out[(rec.get("DXCC Entity Code"), name_key(rec.get("Primary Administrative Subdivision")))].append(rec["Code"])
    return out


def validity(ename, rec):
    """The QSO dates a value is valid for (spec II.C "Deletion"), as (from, before):
    from inclusive, before exclusive, YYYYMMDD or None. ARRL_Section has From and
    Deleted Date columns, Region Start and End Date (End inclusive), and subdivisions
    say "for contacts made before D" or "for contacts made on or after D"."""
    if ename == "ARRL_Section":
        return ymd(rec.get("From Date")), ymd(rec.get("Deleted Date"))
    if ename == "Region":
        end = rec.get("End Date")
        return ymd(rec.get("Start Date")), ymd(end, 1) if end else None
    comment = rec.get("Comments") or ""
    before = re.search(r"for contacts made before (\S+)", comment)
    after = re.search(r"for contacts made on or after (\S+)", comment)
    return (ymd(after.group(1)) if after else None), (ymd(before.group(1)) if before else None)


def dates_key(comment):
    """As tools/adif_history.py tells values apart by their validity notes."""
    found = re.findall(r"for contacts made (before|on or after) (\d{4})[-/](\d{2})[-/](\d{2})", comment or "")
    return ";".join(f"{w} {y}{m}{d}" for w, y, m, d in found)


def main():
    adif = json.loads(SRC.read_text(encoding="utf-8-sig"))["Adif"]
    history = json.loads(HISTORY.read_text(encoding="utf-8"))
    briefs = html_descriptions(SPEC_HTML)
    version, date = adif["Version"], adif["Date"][:10]
    fields = adif["Fields"]["Records"]
    enums = adif["Enumerations"]
    versions = history["versions"]
    if versions[-1]["version"] != version:
        sys.exit(f"the history ends at {versions[-1]['version']}, the export is {version}")
    newest = 1 << (len(versions) - 1)

    lines = [
        "// GENERATED by tools/gen_spec_tables.py from spec/adif-3.1.8/all.json and spec/adif-history.json.",
        f"// ADIF {version} ({date}), and which of ADIF 3.0.2 to {version} has what. Do not edit by hand.",
        '#include "adif_spec.h"',
        "",
        "namespace adif {",
        "",
        "static const SpecVersion kVersions[] = {",
    ]
    for v in versions:
        lines.append(f"    {{{cstr(v['version'])}, {cstr(v['date'] or None)}}},")
    lines += ["};", ""]

    # ── Fields, sorted by upper-case name for binary search ──────────────────
    rows = []
    for name, f in fields.items():
        if name == "USERDEFn":  # a pattern, handled in code (USERDEF1, USERDEF2, ...)
            continue
        types = [t.strip() for t in f["Data Type"].split(",")]
        for t in types:
            if t not in DATA_TYPES:
                sys.exit(f"unknown data type {t!r} for field {name}")
        enum, key = f.get("Enumeration"), None
        if enum:
            enum = enum.split(",")[0].strip()  # "Credit,Award" -> Credit (Award is import-only)
            m = re.fullmatch(r"(\w+)\[(\w+)\]", enum)
            if m:
                enum, key = m.group(1), m.group(2)
        lo, hi = num(f.get("Minimum Value")), num(f.get("Maximum Value"))
        full = " ".join((f.get("Description") or "").split())
        brief = briefs.get(name) or short_description(full)
        h = history["fields"].get(name, {"in": newest, "importOnly": newest if truthy(f.get("Import-only")) else 0})
        rows.append((aupper(name), types[0], enum, key, truthy(f.get("Header Field")),
                     truthy(f.get("Import-only")), lo, hi, brief, full[:700] or None, h["in"], h["importOnly"]))
    rows.sort(key=lambda r: sort_key(r[0]))
    lines.append("static const FieldDef kFields[] = {")
    for name, t, enum, key, header, imp, lo, hi, desc, details, mask, io in rows:
        lines.append(
            f"    {{{cstr(name)}, DataType::{t}, {cstr(enum)}, {cstr(key)}, "
            f"{str(header).lower()}, {str(imp).lower()}, "
            f"{str(lo is not None).lower()}, {str(hi is not None).lower()}, "
            f"{lo if lo is not None else 0}, {hi if hi is not None else 0}, {cstr(desc)}, {cstr(details)}, {mask}u, {io}u}},")
    lines += ["};", ""]
    # The types older versions gave fields.
    lines.append("static const FieldTypeVariant kFieldTypes[] = {")
    variants = 0
    for name, h in sorted(history["fields"].items()):
        for t, mask in h.get("types", []):
            if t not in DATA_TYPES:
                sys.exit(f"unknown data type {t!r} in the history of {name}")
            lines.append(f"    {{{cstr(aupper(name))}, DataType::{t}, {mask}u}},")
            variants += 1
    if not variants:
        lines.append('    {"", DataType::Unknown, 0u},')
    lines += ["};", ""]
    # Data types by version.
    lines.append("static const DataTypeVersions kDataTypeVersions[] = {")
    for t in DATA_TYPES:
        h = history["dataTypes"].get(t, {"in": newest, "importOnly": 0})
        lines.append(f"    {{DataType::{t}, {h['in']}u, {h['importOnly']}u}},")
    lines += ["};", ""]

    # ── Enumerations, values sorted by ASCII-upper-cased value bytes ─────────
    enum_names = []
    for ename in sorted(enums):
        if ename not in ENUM_COLUMNS:
            sys.exit(f"enumeration {ename!r} has no column mapping")
        vcol, scol = ENUM_COLUMNS[ename]
        vals = []
        # An import-only subdivision code whose subdivision is listed again under a new code
        # (Mexico's NL is now NLE, "Nuevo León"): that code is its replacement.
        by_name = current_codes_by_name(enums[ename]) if ename == "Primary_Administrative_Subdivision" else {}
        past = {(aupper(r["value"]), r.get("scope", ""), r.get("dates", "")): r
                for r in history["enumerations"].get(ename, {}).get("values", [])}
        for rec in enums[ename]["Records"].values():
            value = rec[vcol]
            scope = rec.get(scol) if scol else None
            imp = truthy(rec.get("Import-only"))
            # Keep the description only where it tells the user what to do instead; subdivision
            # tables put that in Comments ("replaced by CMX"), beside other notes such as local names.
            comment = rec.get("Comments") or ""
            replaced = comment if comment.lower().startswith("replaced by ") else None
            since, before = validity(ename, rec)
            if imp and not replaced and by_name:
                same = by_name.get((rec.get("DXCC Entity Code"), name_key(rec.get("Primary Administrative Subdivision"))), [])
                if len(same) == 1:
                    replaced = "replaced by " + same[0]
            note = (rec.get("Description") or replaced) if imp else replaced if before else None
            hkey = (aupper(value), (rec.get(HISTORY_SCOPES[ename]) or "") if ename in HISTORY_SCOPES else "", dates_key(rec.get("Comments")))
            row = past.pop(hkey, None)
            mask, io = (row["in"], row.get("importOnly", 0)) if row else (newest, newest if imp else 0)
            vals.append((sort_key(value), scope, value, note, imp, since, before, mask, io))
        # Values only older versions have.
        for (v, sc, _), row in past.items():
            if row["in"] & newest:
                sys.exit(f"{ename} {v} ({sc}): in the history's {version} but not in the export")
            vals.append((sort_key(row["value"]), sc or None, row["value"], None, False, None, None, row["in"], row.get("importOnly", 0)))
        vals.sort(key=lambda v: v[0])
        ident = "kEnum_" + ename
        lines.append(f"static const EnumValue {ident}[] = {{")
        for _, scope, value, note, imp, since, before, mask, io in vals:
            lines.append(f"    {{{cstr(value)}, {cstr(scope)}, {cstr(note)}, {str(imp).lower()}, {cstr(since)}, {cstr(before)}, {mask}u, {io}u}},")
        lines += ["};", ""]
        enum_names.append((ename, ident, history["enumerations"].get(ename, {}).get("in", newest)))
    lines.append("static const EnumDef kEnums[] = {")
    for ename, ident, mask in enum_names:  # looked up by linear scan, so order is cosmetic
        lines.append(f"    {{{cstr(ename)}, {ident}, sizeof({ident}) / sizeof({ident}[0]), {mask}u}},")
    lines += ["};", ""]

    # ── Band edges (MHz) by version, in spec order ────────────────────────────
    order = [rec["Band"] for rec in enums["Band"]["Records"].values()]
    past = {r["value"]: r for r in history["enumerations"]["Band"]["values"]}
    order += sorted(set(past) - set(order), key=lambda b: past[b]["edges"][0][0])
    for i, v in enumerate(versions):
        lines.append(f"static const BandDef kBands{i}[] = {{  // ADIF {v['version']}")
        for band in order:
            for lo, hi, mask in past[band]["edges"]:
                if mask & (1 << i):
                    lines.append(f"    {{{cstr(band)}, {lo}, {hi}}},")
        lines += ["};", ""]
    lines.append("static const BandTable kBandTables[] = {")
    for i in range(len(versions)):
        lines.append(f"    {{kBands{i}, sizeof(kBands{i}) / sizeof(kBands{i}[0])}},")
    lines += ["};", ""]

    # ── DXCC entity names (for COUNTRY), by entity code ──────────────────────
    lines.append("static const DxccName kDxccNames[] = {")
    dx = sorted(enums["DXCC_Entity_Code"]["Records"].values(), key=lambda r: int(r["Entity Code"]))
    for rec in dx:
        lines.append(f"    {{{int(rec['Entity Code'])}, {cstr(rec['Entity Name'])}, {str(truthy(rec.get('Deleted'))).lower()}}},")
    lines += ["};", ""]

    lines += [
        "const DxccName *dxccTable(size_t *count) {",
        "    *count = sizeof(kDxccNames) / sizeof(kDxccNames[0]);",
        "    return kDxccNames;",
        "}",
        "",
        "const FieldDef *fieldTable(size_t *count) {",
        "    *count = sizeof(kFields) / sizeof(kFields[0]);",
        "    return kFields;",
        "}",
        "",
        "const EnumDef *enumTable(size_t *count) {",
        "    *count = sizeof(kEnums) / sizeof(kEnums[0]);",
        "    return kEnums;",
        "}",
        "",
        "const BandDef *bandTable(size_t *count) {",
        "    const BandTable &t = kBandTables[specVersionIndex()];",
        "    *count = t.count;",
        "    return t.bands;",
        "}",
        "",
        "const SpecVersion *specVersions(size_t *count) {",
        "    *count = sizeof(kVersions) / sizeof(kVersions[0]);",
        "    return kVersions;",
        "}",
        "",
        "const FieldTypeVariant *fieldTypeVariants(size_t *count) {",
        "    *count = sizeof(kFieldTypes) / sizeof(kFieldTypes[0]);",
        "    return kFieldTypes;",
        "}",
        "",
        "const DataTypeVersions *dataTypeVersions(size_t *count) {",
        "    *count = sizeof(kDataTypeVersions) / sizeof(kDataTypeVersions[0]);",
        "    return kDataTypeVersions;",
        "}",
        "",
        "}  // namespace adif",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="ascii")
    print(f"descriptions from the HTML spec: {sum(1 for r in rows if briefs.get(r[0]))} of {len(rows)} fields")
    print(f"wrote {OUT}: {len(rows)} fields, {len(enum_names)} enumerations, "
          f"{len(enums['Band']['Records'])} bands (ADIF {version}, {date}), {len(versions)} versions, {variants} older field types")


if __name__ == "__main__":
    main()
