#!/usr/bin/env python3
"""Read an ADIF 3 specification page (ADIF_3XX.htm) into the shape of the official JSON export.

ADIF publishes its tables as exports (all.json) only from 3.1.5 on (3.1.5 as XML), so for older
versions the tables are read from the specification itself: fields, data types and
enumerations, with the columns tools/gen_spec_tables.py uses. With --compare, the result is
checked against an official export of the same version, which is how this reader is tested
(3.1.6, 3.1.7 and 3.1.8 have both).

    python3 -I tools/adif_spec_html.py SPEC.htm [OUT.json]
    python3 -I tools/adif_spec_html.py SPEC.htm --compare all.json   (or all.xml, 3.1.5's export)
"""
import html
import json
import re
import sys
import xml.etree.ElementTree as ET

# Enumeration names as the export spells them, from a table's id (3.0.9 on), its class (3.0.4
# on) or its heading ("III.B.4. Band Enumeration").
CLASS_ENUMS = {
    "antpathenumerationtable": "Ant_Path",
    "arrlsectionenumerationtable": "ARRL_Section",
    "awardenumerationtable": "Award",
    "bandenumerationtable": "Band",
    "contestidenumerationtable": "Contest_ID",
    "continentenumerationtable": "Continent",
    "creditenumerationtable": "Credit",
    "countrycodesenumerationtable": "DXCC_Entity_Code",
    "modeenumerationtable": "Mode",
    "submodeenumerationtable": "Submode",
    "propagationmodeenumerationtable": "Propagation_Mode",
    "qslmediumenumerationtable": "QSL_Medium",
    "qslrcvdenumerationtable": "QSL_Rcvd",
    "qslsentenumerationtable": "QSL_Sent",
    "qslviaenumerationtable": "QSL_Via",
    "qsocompleteenumerationtable": "QSO_Complete",
    "qsouploadstatusenumerationtable": "QSO_Upload_Status",
    "sponsoredawardenumerationtable": "Award_Sponsor",
    "primaryadministrativesubdivisiontable": "Primary_Administrative_Subdivision",
    "usasecondaryadministrativesubdivisiontable": "Secondary_Administrative_Subdivision",
}
HEADING_ENUMS = {
    "Ant Path": "Ant_Path", "ARRL Section": "ARRL_Section", "Award": "Award", "Band": "Band",
    "Contest ID": "Contest_ID", "Continent": "Continent", "Credit": "Credit",
    "DXCC Entity Code": "DXCC_Entity_Code", "Country Code": "DXCC_Entity_Code", "EQSL_AG": "EQSL_AG",
    "Mode": "Mode", "Morse Key Type": "Morse_Key_Type", "Submode": "Submode",
    "Propagation Mode": "Propagation_Mode", "QSL Medium": "QSL_Medium", "QSL Rcvd": "QSL_Rcvd",
    "QSL Sent": "QSL_Sent", "QSL Via": "QSL_Via", "QSO Complete": "QSO_Complete",
    "QSO Download Status": "QSO_Download_Status", "QSO Upload Status": "QSO_Upload_Status",
    "Region": "Region", "Sponsored Award": "Award_Sponsor", "Propagation": "Propagation_Mode",
    "Country Codes and Names": "DXCC_Entity_Code",
    "Primary Administrative Subdivision": "Primary_Administrative_Subdivision",
    "Secondary Administrative Subdivision": "Secondary_Administrative_Subdivision",
    "Secondary Administrative Subdivision Alt": "Secondary_Administrative_Subdivision_Alt",
}
# Column headings that changed wording, as the export names them now.
COLUMN_NAMES = {
    "Country Code": "Entity Code", "SPONSOR_": "Sponsor", "Data Type": "Data Type Name", "Name": "Field Name",
}
# The column each enumeration's value is in (the first one, except where it isn't).
VALUE_COLUMNS = {
    "Ant_Path": "Abbreviation", "ARRL_Section": "Abbreviation", "Award": "Award", "Award_Sponsor": "Sponsor",
    "Band": "Band", "Contest_ID": "Contest-ID", "Continent": "Abbreviation", "Credit": "Credit For",
    "DXCC_Entity_Code": "Entity Code", "EQSL_AG": "Status", "Mode": "Mode", "Morse_Key_Type": "Abbreviation",
    "Primary_Administrative_Subdivision": "Code", "Propagation_Mode": "Enumeration", "QSL_Medium": "Medium",
    "QSL_Rcvd": "Status", "QSL_Sent": "Status", "QSL_Via": "Via", "QSO_Complete": "Abbreviation",
    "QSO_Download_Status": "Status", "QSO_Upload_Status": "Status", "Region": "Region Entity Code",
    "Secondary_Administrative_Subdivision": "Code", "Secondary_Administrative_Subdivision_Alt": "Code",
    "Submode": "Submode",
}
# Deprecated items are "import-only" from 3.0.6 on, "deprecated" before (section II.B either way:
# accepted on import, never exported).
IMPORT_ONLY = re.compile(r"\(?\s*(?:import[- ]only|deprecated)\s*\)?", re.I)


def text(cell):
    """A cell's text: tags dropped, entities decoded, spaces collapsed."""
    cell = re.sub(r"(?i)<br\s*/?>", " ", cell)
    cell = re.sub(r"(?is)<span[^>]*class=\"exportOnlyText\"[^>]*>.*?</span>", " ", cell)
    return " ".join(html.unescape(re.sub(r"(?s)<[^>]+>", " ", cell)).replace(" ", " ").split())


def cells(row):
    return re.findall(r"(?is)<t([dh])\b[^>]*>(.*?)</t[dh]>", row)


def table_end(page, at):
    """Where the table opened at `at` closes, counting the tables inside it."""
    depth = 0
    for m in re.finditer(r"(?i)<(/?)table\b", page[at:]):
        depth += -1 if m.group(1) else 1
        if depth == 0:
            return at + m.start()
    return len(page)


def own_rows(body):
    """The table's own rows, not those of tables inside its cells."""
    flat, depth, last = [], 0, 0
    for m in re.finditer(r"(?i)<(/?)table\b[^>]*>", body):
        if depth == 0:
            flat.append(body[last:m.start()])
        depth += -1 if m.group(1) else 1
        last = m.end()
    if depth == 0:
        flat.append(body[last:])
    return re.findall(r"(?is)<tr\b.*?</tr>", "".join(flat))


def tables(page):
    """Each table: its attributes, rows, and the last heading with words before it."""
    out = []
    headings = [(h.start(), text(h.group(1))) for h in re.finditer(r"(?is)<h[2-6]\b[^>]*>(.*?)</h[2-6]>", page)]
    headings = [(at, h) for at, h in headings if h]
    for m in re.finditer(r"(?is)<table\b([^>]*)>", page):
        end = table_end(page, m.start())
        body = page[m.end():end]
        before = [h for at, h in headings if at < m.start()]
        heading = before[-1] if before else ""
        cls = re.search(r'class="([^"]+)"', m.group(1))
        ident = re.search(r'id="([^"]+)"', m.group(1))
        out.append({"class": cls.group(1) if cls else "", "id": ident.group(1) if ident else "", "heading": heading,
                    "rows": own_rows(body), "start": m.start()})
    return out


def column_name(h):
    h = re.sub(r"\(\s*M\s*Hz\s*\)", "(MHz)", h)  # 3.0.3's "Lower Freq ( M Hz)"
    return COLUMN_NAMES.get(h, h)


def heading_enum(heading):
    h = re.sub(r"^[IVX]+\.[A-Z]\.\d+(\.[a-z])?\.?\s*", "", heading)
    h = IMPORT_ONLY.sub("", h).strip()
    h = re.sub(r"\s*Enumeration\s*$", "", h).strip()
    return HEADING_ENUMS.get(h)


def enum_of(t):
    if t["id"].startswith("Enumeration_"):
        name = t["id"][len("Enumeration_"):]
        name = re.sub(r"_\d+$", "", name)  # Primary_Administrative_Subdivision_1, ..._Alt_170
        return name
    if t["class"] in CLASS_ENUMS:
        return CLASS_ENUMS[t["class"]]
    return heading_enum(t["heading"])


def field_enum(cell):
    """A field's Enumeration cell as the export writes it: "Ant_Path", "Credit,Award",
    "Submode[MODE]" (a function of MODE's value)."""
    names, key = [], None
    for href, label in re.findall(r'(?is)<a[^>]*href="#([^"]*)"[^>]*>(.*?)</a>', cell):
        label = text(label)
        if href.startswith(("QSO_Field_", "Header_Field_")) or href.endswith("_field"):
            key = label
        elif "Enumeration" in href or href.endswith("Subdivision") or href.endswith("Subdivision_Alt"):
            names.append(label.replace(" ", "_"))
    if not names:  # an enumeration named without a link, as some older pages do
        plain = text(cell)
        return HEADING_ENUMS.get(plain, "") if plain else ""
    out = ",".join(names)
    if key and re.search(r"(?i)function of", text(cell)):
        out += f"[{key}]"
    return out


def ymd(s):
    m = re.search(r"(\d{4})[-/](\d{2})[-/](\d{2})", s or "")
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}T00:00:00Z" if m else None


def parse(page):
    page = re.sub(r"(?s)<!--.*?-->", "", page)  # rows left out of the spec as comments
    adif = {"DataTypes": {"Records": {}}, "Fields": {"Records": {}}, "Enumerations": {}}
    v = re.search(r"(?i)ADIF\s+(?:Version|V)\s*(3\.\d\.\d)", page)
    adif["Version"] = v.group(1) if v else ""
    all_tables = tables(page)
    classless = not any(t["class"] for t in all_tables)  # 3.0.2 and 3.0.3: tables known by their headings
    for t in all_tables:
        rows = t["rows"]
        if not rows:
            continue
        kind = t["class"] or ("" if not classless else "datatypetable" if t["heading"].startswith("III.A. Data Types") else
                              "fieldtable" if t["heading"].startswith("III.C.1") else "")
        if kind == "datatypetable":
            for r in rows:
                c = cells(r)
                if not c or c[0][0] == "h" or text(c[0][1]) in ("Data Type", "Data Type Name"):
                    continue
                anchor = re.search(r'(?i)<a[^>]*id="([^"]+)"', c[0][1])
                name = anchor.group(1) if anchor else IMPORT_ONLY.sub("", text(c[0][1])).replace(" ", "")
                if not name:
                    continue
                rec = {"Data Type Name": name}
                if IMPORT_ONLY.search(text(c[0][1])):
                    rec["Import-only"] = "true"
                adif["DataTypes"]["Records"][name] = rec
            continue
        if kind == "fieldtable":
            header = "Header" in t["id"] or "Header" in t["heading"] or not adif["Fields"]["Records"]
            for r in rows:
                c = cells(r)
                if len(c) < 4 or c[0][0] == "h" or text(c[0][1]) in ("Name", "Field Name"):
                    continue
                name = html.unescape(re.sub(r"(?s)<[^>]+>", "", c[0][1])).split()  # USERDEF<i>n</i> is one word
                name = name[0] if name else ""
                if not name:
                    continue
                types = [h for h in re.findall(r'(?i)<a[^>]*href="#([^"]+)"', c[1][1]) if h != "Deprecation"] or \
                        [x for x in re.split(r"[,\s]+", IMPORT_ONLY.sub(" ", text(c[1][1]))) if x]
                enum = field_enum(c[2][1])
                desc = c[3][1]
                rec = {"Field Name": name, "Data Type": ",".join(types)}
                if enum:
                    rec["Enumeration"] = enum
                rec["Description"] = text(desc)
                lo = re.search(r'(?is)<span[^>]*title="Minimum"[^>]*>(.*?)</span>', desc)
                hi = re.search(r'(?is)<span[^>]*title="Maximum"[^>]*>(.*?)</span>', desc)
                above = re.search(r'(?is)<span[^>]*title="GreaterThan"[^>]*>(.*?)</span>', desc)
                if lo:
                    rec["Minimum Value"] = text(lo.group(1))
                elif above and re.fullmatch(r"-?\d+", text(above.group(1))) and "Integer" in rec["Data Type"]:
                    rec["Minimum Value"] = str(int(text(above.group(1))) + 1)  # "greater than 0": a whole number from 1
                if hi:
                    rec["Maximum Value"] = text(hi.group(1))
                if re.match(r"(?i)\s*(?:import[- ]only|deprecated)", text(desc)):
                    rec["Import-only"] = "true"
                if header:
                    rec["Header Field"] = "true"
                adif["Fields"]["Records"][name] = rec
            continue
        ename = enum_of(t)
        if not ename:
            continue
        enum = adif["Enumerations"].setdefault(ename, {"Records": {}})
        columns = None
        dxcc = re.search(r"_(\d+)$", t["id"]).group(1) if re.search(r"Subdivision(?:_Alt)?_\d+$", t["id"]) else None
        for r in rows:
            c = cells(r)
            if not c:
                continue
            title = re.search(r"Enumeration for .*?(?:Country Code|DXCC Entity Code)\s+(\d+)", text(c[0][1])) if len(c) == 1 else None
            if title:
                dxcc = title.group(1)
                continue
            if columns is None and text(c[0][1]) == "Secondary Subdivision":  # the summary of the lists, not values
                break
            if all(k == "h" for k, _ in c):
                heads = [text(x) for _, x in c]
                if len(heads) == 1 and columns:  # a subtitle within the table (Japan's "Kanto")
                    continue
                columns = [column_name(h) for h in heads]
                if ename == "QSO_Upload_Status" and columns[:1] == ["Via"]:  # 3.0.4's heading slip
                    columns[0] = "Status"
                continue
            vals = [x for _, x in c]
            if len(vals) == 1 and columns and len(columns) > 1:  # a subtitle written as a cell (3.0.3's regions)
                continue
            if columns is None:  # tables whose first row holds the headings in td cells
                first = column_name(text(vals[0]))
                if first == VALUE_COLUMNS.get(ename) or first in ("Code", "Abbreviation", "Status", "Enumeration", "Entity Code"):
                    columns = [column_name(text(x)) for x in vals]
                    if ename == "QSO_Upload_Status" and columns[:1] == ["Via"]:
                        columns[0] = "Status"
                    continue
                columns = [VALUE_COLUMNS.get(ename, "Value")] + [f"Column {i}" for i in range(2, len(vals) + 1)]  # 3.0.3's Award list
            rec = {"Enumeration Name": ename}
            comments = []
            for col, raw in zip(columns, vals):
                s = text(raw)
                replaced = re.search(r"(?i)\(?\s*(?:import[- ]only\s*)?(replaced by [^)]*)\)?\s*$", s)
                if replaced and col != VALUE_COLUMNS.get(ename):
                    comments.append(replaced.group(1).strip())
                    s = s[:replaced.start()].strip()
                    if IMPORT_ONLY.search(replaced.group(0)):
                        rec["Import-only"] = "true"
                dated = re.search(r"(?i)\s*-\s*(for contacts made (?:before|on or after) \S+)\s*$", s)
                if dated and col != VALUE_COLUMNS.get(ename):
                    comments.append(dated.group(1))
                    s = s[:dated.start()].strip()
                if IMPORT_ONLY.search(s):
                    if col in (VALUE_COLUMNS.get(ename), "Primary Administrative Subdivision", "Secondary Administrative Subdivision", "Award"):
                        rec["Import-only"] = "true"
                        rest = IMPORT_ONLY.sub(" ", s)
                        replaced = re.search(r"(?i)(replaced by .*?)\)?\s*$", rest)
                        if replaced and col != VALUE_COLUMNS.get(ename):
                            comments.append(replaced.group(1).strip(" )"))
                            rest = rest[:rest.lower().find("replaced by")]
                        s = " ".join(rest.split()).strip(" ()")
                if col in ("From Date", "Deleted Date", "Start Date", "End Date"):
                    s = ymd(s) or ""
                if col == "DXCC Entity Code":
                    s = re.sub(r"\s*,\s*", ",", s)
                if col == "Contest-ID":
                    s = re.sub(r"-\s+", "-", s).upper()  # as the export writes them (case-insensitive); 3.0.3 breaks one line at a hyphen
                if col == "Deleted":
                    s = "true" if s.strip().lower() in ("y", "yes", "true", "deleted") else ""
                if s:
                    rec[col] = s
            value = rec.get(VALUE_COLUMNS.get(ename, columns[0]))
            if not value:
                continue
            if dxcc and "DXCC Entity Code" not in rec:
                rec["DXCC Entity Code"] = dxcc
            if comments:
                rec["Comments"] = "; ".join(comments)
            if ename == "Contest_ID" and "," in value:  # 3.0.2 lists aliases in one cell: "RAC, CANADA DAY, CANADA WINTER"
                for alias in [v.strip() for v in value.split(",") if v.strip()]:
                    enum["Records"][alias] = dict(rec, **{"Contest-ID": alias})
                continue
            key = value if ename not in ("Primary_Administrative_Subdivision", "Secondary_Administrative_Subdivision",
                                         "Secondary_Administrative_Subdivision_Alt", "Submode", "Region") else \
                f"{rec.get('DXCC Entity Code') or rec.get('Mode') or ''}:{value}:{len(enum['Records'])}"
            enum["Records"][key] = rec
    return {"Adif": adif}


# ── Comparison with an official export ────────────────────────────────────────

def summary(adif):
    """What the generator uses, as sets that can be compared."""
    out = {}
    out["datatypes"] = {(n, r.get("Import-only") == "true") for n, r in adif["DataTypes"]["Records"].items()}
    out["fields"] = {(n, r.get("Data Type"), r.get("Enumeration"), r.get("Header Field") == "true", r.get("Import-only") == "true",
                      r.get("Minimum Value"), r.get("Maximum Value")) for n, r in adif["Fields"]["Records"].items()}
    scope = {"Submode": "Mode"}
    for ename, e in adif["Enumerations"].items():
        vcol = VALUE_COLUMNS.get(ename)
        rows = set()
        for r in e["Records"].values():
            s = r.get(scope.get(ename, "DXCC Entity Code"))
            extra = ()
            day = lambda d: (ymd(d) or "")[:10] or None
            if ename == "ARRL_Section":
                extra = (day(r.get("From Date")), day(r.get("Deleted Date")))
            elif ename == "Region":
                extra = (day(r.get("Start Date")), day(r.get("End Date")))
            elif ename == "Band":
                extra = (float(r["Lower Freq (MHz)"]), float(r["Upper Freq (MHz)"]))
            elif ename == "DXCC_Entity_Code":
                extra = (r.get("Entity Name"), r.get("Deleted") == "true")
            comment = r.get("Comments") or ""
            dates = tuple(d.rstrip(";,.") for d in re.findall(r"for contacts made (?:before|on or after) \S+", comment))
            replaced = comment if comment.lower().startswith("replaced by") else ""
            rows.add((r.get(vcol), s, r.get("Import-only") == "true", replaced, dates) + extra)
        out["enum " + ename] = rows
    return out


def compare(mine, theirs):
    a, b = summary(mine["Adif"]), summary(theirs["Adif"])
    problems = 0
    for k in sorted(set(a) | set(b)):
        only_a, only_b = a.get(k, set()) - b.get(k, set()), b.get(k, set()) - a.get(k, set())
        if only_a or only_b:
            problems += 1
            print(f"{k}: {len(a.get(k, ()))} read, {len(b.get(k, ()))} in the export")
            for x in sorted(only_a, key=str)[:6]:
                print("   read only:  ", x)
            for x in sorted(only_b, key=str)[:6]:
                print("   export only:", x)
    print("same" if not problems else f"{problems} tables differ")
    return problems


def from_xml(path):
    """An all.xml export in the JSON export's shape."""
    root = ET.parse(path).getroot()

    def records(node):
        return [{v.get("name"): (v.text or "") for v in r.findall("value")} for r in node.findall("record")]

    adif = {"Version": root.get("version"), "DataTypes": {"Records": {}}, "Fields": {"Records": {}}, "Enumerations": {}}
    for r in records(root.find("dataTypes")):
        adif["DataTypes"]["Records"][r["Data Type Name"]] = r
    for r in records(root.find("fields")):
        adif["Fields"]["Records"][r["Field Name"]] = r
    for e in root.find("enumerations").findall("enumeration"):
        adif["Enumerations"][e.get("name")] = {"Records": {str(i): r for i, r in enumerate(records(e))}}
    return {"Adif": adif}


def main():
    raw = open(sys.argv[1], "rb").read()
    charset = re.search(rb'charset=["\']?([A-Za-z0-9_-]+)', raw[:2000])
    page = raw.decode(charset.group(1).decode() if charset else "utf-8", errors="replace")
    mine = parse(page)
    if len(sys.argv) > 3 and sys.argv[2] == "--compare":
        theirs = from_xml(sys.argv[3]) if sys.argv[3].endswith(".xml") else json.load(open(sys.argv[3], encoding="utf-8-sig"))
        sys.exit(1 if compare(mine, theirs) else 0)
    out = json.dumps(mine, ensure_ascii=False, indent=1)
    if len(sys.argv) > 2:
        open(sys.argv[2], "w", encoding="utf-8").write(out)
    else:
        print(out)


if __name__ == "__main__":
    main()
