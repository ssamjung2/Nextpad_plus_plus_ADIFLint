#!/usr/bin/env python3
"""Build spec/adif-history.json: which ADIF 3 versions have each field, data type, enumeration,
enumeration value and band edge, so ADIF Lint can check a log against any of them.

The input is a folder of the specification pages, ADIF_302.htm to ADIF_318.htm (adif.org.uk; see
spec/adif-history.md for where each came from), read by tools/adif_spec_html.py. 3.0.0 and 3.0.1
were never published. What each version holds is recorded as a bit mask over VERSIONS (bit 0 is
3.0.2), so the generated tables stay small; tools/gen_spec_tables.py joins it to the newest
version's export.

    python3 -I tools/adif_history.py PAGES_DIR [spec/adif-history.json]
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adif_spec_html as spec  # noqa: E402

VERSIONS = ["3.0.2", "3.0.3", "3.0.4", "3.0.5", "3.0.6", "3.0.7", "3.0.8", "3.0.9", "3.1.0", "3.1.1", "3.1.2", "3.1.3",
            "3.1.4", "3.1.5", "3.1.6", "3.1.7", "3.1.8"]
# The column that scopes an enumeration's values (as tools/gen_spec_tables.py has it).
SCOPES = {"Submode": "Mode", "Primary_Administrative_Subdivision": "DXCC Entity Code", "Region": "DXCC Entity Code",
          "Secondary_Administrative_Subdivision": "DXCC Entity Code", "Secondary_Administrative_Subdivision_Alt": "DXCC Entity Code"}
DATA_TYPES = {
    "AwardList", "CreditList", "SponsoredAwardList", "Boolean", "Digit", "Integer", "Number", "PositiveInteger", "Character",
    "IntlCharacter", "Date", "Time", "IOTARefNo", "String", "IntlString", "MultilineString", "IntlMultilineString", "Enumeration",
    "GridSquare", "GridSquareExt", "GridSquareList", "Location", "POTARef", "POTARefList", "SecondarySubdivisionList",
    "SecondaryAdministrativeSubdivisionListAlt", "SOTARef", "WWFFRef",
}


def page(path):
    raw = open(path, "rb").read()
    charset = re.search(rb'charset=["\']?([A-Za-z0-9_-]+)', raw[:2000])
    return raw.decode(charset.group(1).decode() if charset else "utf-8", errors="replace")


def page_date(text):
    m = re.search(r"(?i)ADIF Version 3\.\d\.\d,\s*updated\s+(\d{4})[-/](\d{2})[-/](\d{2})", " ".join(re.sub(r"<[^>]+>", " ", text[:40000]).split()))
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else ""


def dates_key(comment):
    """A value's validity note, as part of what identifies it ("BM" before 2013 and from 2013 are two)."""
    found = re.findall(r"for contacts made (before|on or after) (\d{4})[-/](\d{2})[-/](\d{2})", comment or "")
    return ";".join(f"{w} {y}{m}{d}" for w, y, m, d in found)


def number(s):
    return float(str(s).replace(",", ""))


def first_type(types):
    for t in (types or "").split(","):
        t = t.strip()
        if t in DATA_TYPES:
            return t
    return None


def main():
    folder = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                                   "spec", "adif-history.json")
    versions, data = [], []
    for v in VERSIONS:
        text = page(os.path.join(folder, f"ADIF_{v.replace('.', '')}.htm"))
        adif = spec.parse(text)["Adif"]
        if adif["Version"] != v:
            sys.exit(f"ADIF_{v.replace('.', '')}.htm says it is ADIF {adif['Version']!r}")
        versions.append({"version": v, "date": page_date(text)})
        data.append(adif)

    def masks(items):
        """{key: mask} from one iterable of keys per version."""
        out = {}
        for i, keys in enumerate(items):
            for k in keys:
                out[k] = out.get(k, 0) | (1 << i)
        return out

    history = {"versions": versions}
    history["dataTypes"] = {name: {"in": m, "importOnly": masks(
        [n for n, r in a["DataTypes"]["Records"].items() if r.get("Import-only") == "true"] for a in data).get(name, 0)}
        for name, m in masks(a["DataTypes"]["Records"].keys() for a in data).items()}

    newest = data[-1]["Fields"]["Records"]
    fields = {}
    for i, a in enumerate(data):
        for name, r in a["Fields"]["Records"].items():
            f = fields.setdefault(name, {"in": 0, "importOnly": 0, "types": {}})
            f["in"] |= 1 << i
            if r.get("Import-only") == "true":
                f["importOnly"] |= 1 << i
            t = first_type(r.get("Data Type"))
            want = first_type(newest.get(name, {}).get("Data Type"))
            if t and t != want:  # a type the field had then (older pages name no type for some: those keep the newest)
                f["types"][t] = f["types"].get(t, 0) | (1 << i)
    history["fields"] = {n: {"in": f["in"], "importOnly": f["importOnly"],
                             **({"types": [[t, m] for t, m in sorted(f["types"].items())]} if f["types"] else {})}
                         for n, f in sorted(fields.items())}

    enums = {}
    for i, a in enumerate(data):
        for ename, e in a["Enumerations"].items():
            if not e["Records"]:
                continue
            en = enums.setdefault(ename, {"in": 0, "values": {}})
            en["in"] |= 1 << i
            vcol, scol = spec.VALUE_COLUMNS[ename], SCOPES.get(ename)
            for r in e["Records"].values():
                value = r.get(vcol)
                if not value:
                    continue
                key = (spec_upper(value), (r.get(scol) or "") if scol else "", dates_key(r.get("Comments")))
                v = en["values"].setdefault(key, {"value": value, "in": 0, "importOnly": 0})
                v["in"] |= 1 << i
                if r.get("Import-only") == "true":
                    v["importOnly"] |= 1 << i
                if ename == "Band":
                    edges = (number(r["Lower Freq (MHz)"]), number(r["Upper Freq (MHz)"]))
                    v.setdefault("edges", {})
                    v["edges"][edges] = v["edges"].get(edges, 0) | (1 << i)
    history["enumerations"] = {}
    for ename, en in sorted(enums.items()):
        rows = []
        for (_, scope, dates), v in sorted(en["values"].items()):
            row = {"value": v["value"], "in": v["in"]}
            if scope:
                row["scope"] = scope
            if dates:
                row["dates"] = dates
            if v["importOnly"]:
                row["importOnly"] = v["importOnly"]
            if "edges" in v:
                row["edges"] = [[lo, hi, m] for (lo, hi), m in sorted(v["edges"].items(), key=lambda x: x[1])]
            rows.append(row)
        history["enumerations"][ename] = {"in": en["in"], "values": rows}

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=0, sort_keys=False)
        f.write("\n")
    print(f"wrote {out_path}: {len(versions)} versions, {len(history['fields'])} fields, "
          f"{sum(len(e['values']) for e in history['enumerations'].values())} enumeration values")


def spec_upper(s):
    return "".join(c.upper() if "a" <= c <= "z" else c for c in s)


if __name__ == "__main__":
    main()
