#include "adif_upload.h"

#include "adif_spec.h"
#include "adif_tools.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>

namespace adif {
namespace {

std::string upper(std::string_view s) {
    std::string o;
    for (char c : s) o.push_back((c >= 'a' && c <= 'z') ? (char)(c - 32) : c);
    return o;
}

std::string trim(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return std::string(s.substr(b, e - b));
}

bool isStatusField(std::string_view name) {
    for (const char *f : {"QRZCOM_QSO_UPLOAD_STATUS", "QRZCOM_QSO_UPLOAD_DATE", "CLUBLOG_QSO_UPLOAD_STATUS",
                          "CLUBLOG_QSO_UPLOAD_DATE", "LOTW_QSL_SENT", "LOTW_QSLSDATE", "EQSL_QSL_SENT", "EQSL_QSLSDATE"})
        if (equalsNoCase(name, f)) return true;
    return false;
}

// Text fields of a form part must not break out of their quotes or headers.
std::string headerSafe(std::string_view s) {
    std::string o;
    for (char c : s)
        if (c != '"' && c != '\r' && c != '\n') o.push_back(c);
    return o;
}

}  // namespace

UploadFields uploadFields(UploadService s) {
    switch (s) {
        case UploadService::QRZ: return {"QRZCOM_QSO_UPLOAD_STATUS", "QRZCOM_QSO_UPLOAD_DATE"};
        case UploadService::LoTW: return {"LOTW_QSL_SENT", "LOTW_QSLSDATE"};
        case UploadService::ClubLog: return {"CLUBLOG_QSO_UPLOAD_STATUS", "CLUBLOG_QSO_UPLOAD_DATE"};
        case UploadService::EQSL: return {"EQSL_QSL_SENT", "EQSL_QSLSDATE"};
    }
    return {"", ""};
}

const char *uploadServiceName(UploadService s) {
    switch (s) {
        case UploadService::QRZ: return "QRZ.com Logbook";
        case UploadService::LoTW: return "LoTW";
        case UploadService::ClubLog: return "Club Log";
        case UploadService::EQSL: return "eQSL";
    }
    return "";
}

std::vector<UploadItem> uploadItems(std::string_view text, const DocModel &m, UploadService s) {
    std::vector<UploadItem> out;
    UploadFields f = uploadFields(s);
    bool qslService = s == UploadService::LoTW || s == UploadService::EQSL;
    for (const Record &r : records(text, m)) {
        UploadItem i;
        i.group = r.group;
        i.record = r.number;
        i.call = upper(trim(r.get("CALL")));
        i.date = r.get("QSO_DATE");
        i.time = r.get("TIME_ON");
        i.band = effectiveBand(r);
        i.mode = effectiveMode(r);
        i.station = stationCall(r);
        i.status = upper(trim(r.get(f.status)));
        i.done = i.status == "Y";
        i.skip = qslService ? i.status == "I" : i.status == "N";
        i.replace = !qslService && i.status == "M";
        if (i.call.empty()) i.problem = "no CALL";
        else if (!parseAdifDate(i.date, nullptr)) i.problem = "no valid QSO_DATE";
        else if (!parseAdifTime(i.time, nullptr)) i.problem = "no valid TIME_ON";
        else if (i.band.empty()) i.problem = "no BAND or FREQ";
        else if (i.mode.empty()) i.problem = "no MODE";
        out.push_back(std::move(i));
    }
    return out;
}

std::string recordAdi(std::string_view text, const DocModel &m, int group) {
    if (group < 0 || (size_t)group >= m.groups.size()) return "";
    const ModelGroup &g = m.groups[(size_t)group];
    std::string out;
    for (size_t i = 0; i < g.fieldCount; ++i) {
        const ModelField &f = m.fields[g.firstField + i];
        std::string_view name = fieldName(text, f);
        if (isStatusField(name)) continue;
        char indicator = f.typePos == kNoPos ? 0 : text[f.typePos];
        out += makeSpecifier(name, fieldValue(text, f), LengthUnit::Bytes, true, indicator) + " ";
    }
    return out + "<EOR>";
}

std::string uploadFile(std::string_view text, const DocModel &m, const std::vector<int> &groups, std::string_view programVersion,
                       std::string_view utcTimestamp, std::string_view extraHeader) {
    std::string out = "ADIF Lint upload\n";
    out += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + "\n";
    out.append(extraHeader);
    out += "<EOH>\n";
    for (int gi : groups) out += recordAdi(text, m, gi) + "\n";
    return out;
}

std::string formEncode(std::string_view s) {
    static const char kHex[] = "0123456789ABCDEF";
    std::string o;
    for (unsigned char c : s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
            c == '~') {
            o.push_back((char)c);
        } else {
            o.push_back('%');
            o.push_back(kHex[c >> 4]);
            o.push_back(kHex[c & 15]);
        }
    }
    return o;
}

std::string formDecode(std::string_view s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '+') o.push_back(' ');
        else if (s[i] == '%' && i + 2 < s.size() && std::isxdigit((unsigned char)s[i + 1]) && std::isxdigit((unsigned char)s[i + 2])) {
            o.push_back((char)std::strtol(std::string(s.substr(i + 1, 2)).c_str(), nullptr, 16));
            i += 2;
        } else {
            o.push_back(s[i]);
        }
    }
    return o;
}

std::string qrzInsertBody(std::string_view key, std::string_view adi, bool replace) {
    return "KEY=" + formEncode(key) + "&ACTION=INSERT&ADIF=" + formEncode(adi) + (replace ? "&OPTION=REPLACE" : "");
}

std::string qrzStatusBody(std::string_view key) { return "KEY=" + formEncode(key) + "&ACTION=STATUS"; }

bool QrzReply::duplicate() const { return result == "FAIL" && upper(reason).find("DUPLICATE") != std::string::npos; }

QrzReply parseQrzReply(std::string_view body) {
    QrzReply r;
    std::string b = trim(body);
    size_t start = 0;
    while (start <= b.size()) {
        size_t amp = b.find('&', start);
        std::string pair = b.substr(start, amp == std::string::npos ? std::string::npos : amp - start);
        size_t eq = pair.find('=');
        if (eq != std::string::npos) {
            std::string k = upper(trim(pair.substr(0, eq))), v = formDecode(pair.substr(eq + 1));
            if (k == "RESULT") r.result = upper(trim(v));
            else if (k == "LOGID") r.logid = v;
            else if (k == "REASON") r.reason = v;
            else if (k == "COUNT") r.count = v;
        }
        if (amp == std::string::npos) break;
        start = amp + 1;
    }
    return r;
}

EqslReply parseEqslReply(std::string_view html) {
    EqslReply r;
    // Messages end with <BR>; drop the other tags.
    std::string t;
    for (size_t i = 0; i < html.size(); ++i) {
        if (html[i] == '<') {
            size_t gt = html.find('>', i);
            if (gt == std::string_view::npos) break;
            std::string tag = upper(html.substr(i + 1, gt - i - 1));
            if (tag == "BR" || tag == "BR/" || tag == "BR /" || tag == "P" || tag == "/P") t.push_back('\n');
            i = gt;
            continue;
        }
        t.push_back(html[i]);
    }
    size_t start = 0;
    while (start < t.size()) {
        size_t nl = t.find('\n', start);
        std::string line = trim(t.substr(start, nl == std::string::npos ? std::string::npos : nl - start));
        start = nl == std::string::npos ? t.size() : nl + 1;
        if (line.empty()) continue;
        auto after = [&](size_t n) { return trim(line.substr(n)); };
        if (line.rfind("Result:", 0) == 0) {
            int x = -1, y = -1;
            if (std::sscanf(line.c_str(), "Result: %d out of %d", &x, &y) == 2) {
                r.added = x;
                r.total = y;
            }
        } else if (line.rfind("Error:", 0) == 0) {
            r.errors.push_back(after(6));
        } else if (line.rfind("Warning:", 0) == 0) {
            r.warnings.push_back(after(8));
            if (upper(line).find("DUPLICATE") != std::string::npos) r.duplicate = true;
        } else if (line.rfind("Information:", 0) == 0 || line.rfind("Caution:", 0) == 0) {
            r.info.push_back(line);
        }
    }
    return r;
}

std::string htmlDecode(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '&') {
            out.push_back(s[i]);
            continue;
        }
        size_t semi = s.find(';', i);
        if (semi == std::string_view::npos || semi - i > 8) {
            out.push_back('&');
            continue;
        }
        std::string name(s.substr(i + 1, semi - i - 1));
        std::string rep;
        if (name == "lt") rep = "<";
        else if (name == "gt") rep = ">";
        else if (name == "amp") rep = "&";
        else if (name == "quot") rep = "\"";
        else if (name == "apos") rep = "'";
        else if (name.size() > 1 && name[0] == '#') {
            long code = name[1] == 'x' || name[1] == 'X' ? std::strtol(name.c_str() + 2, nullptr, 16) : std::strtol(name.c_str() + 1, nullptr, 10);
            if (code > 0 && code < 128) rep = std::string(1, (char)code);
        }
        if (rep.empty()) {
            out.push_back('&');
            continue;
        }
        out += rep;
        i = semi;
    }
    return out;
}

bool parseQrzFetch(std::string_view body, QrzReply *reply, std::string *adif) {
    size_t at = body.find("ADIF=");
    std::string_view head = at == std::string_view::npos ? body : body.substr(0, at);
    QrzReply r = parseQrzReply(head);
    if (reply) *reply = r;
    if (adif) {
        adif->clear();
        if (at != std::string_view::npos) {
            std::string a = htmlDecode(body.substr(at + 5));
            if (a.find("%3C") != std::string::npos || a.find("%3c") != std::string::npos) a = formDecode(a);
            *adif = a;
        }
    }
    return !r.result.empty();
}

std::string qrzFetchBody(std::string_view key, long long afterLogid, int max, std::string_view between) {
    std::string option = between.empty() ? std::string() : "BETWEEN:" + std::string(between) + ",";
    option += "MAX:" + std::to_string(max) + ",AFTERLOGID:" + std::to_string(afterLogid);
    return "KEY=" + formEncode(key) + "&ACTION=FETCH&OPTION=" + formEncode(option);
}

std::string eqslInboxLink(std::string_view html, std::string *error) {
    size_t built = html.find("Your ADIF log file has been built");
    if (built == std::string_view::npos) {
        size_t e = html.find("Error:");
        if (error) {
            std::string line(html.substr(e == std::string_view::npos ? 0 : e + 6));
            size_t end = line.find_first_of("<\r\n");
            *error = e == std::string_view::npos ? "eQSL did not build the file" : std::string(trim(line.substr(0, end)));
        }
        return "";
    }
    for (size_t at = html.find("HREF=", built), alt = html.find("href=", built);;) {
        size_t p = std::min(at, alt);
        if (p == std::string_view::npos) break;
        size_t q = p + 5;
        char quote = q < html.size() && (html[q] == '"' || html[q] == '\'') ? html[q++] : 0;
        size_t end = quote ? html.find(quote, q) : html.find_first_of(" >", q);
        if (end == std::string_view::npos) break;
        std::string link(html.substr(q, end - q));
        std::string lower = link;
        for (char &c : lower) c = (char)std::tolower((unsigned char)c);
        if (lower.size() > 4 && lower.substr(lower.size() - 4) == ".adi") return link;
        if (p == at) at = html.find("HREF=", p + 5);
        else alt = html.find("href=", p + 5);
    }
    if (error) *error = "eQSL built the file but its link was not found";
    return "";
}

std::string tqslExitMeaning(int code) {
    switch (code) {
        case 0: return "all QSOs were signed and uploaded";
        case 1: return "cancelled";
        case 2: return "rejected by LoTW";
        case 3: return "unexpected response from the TQSL server";
        case 4: return "TQSL error";
        case 5: return "TQSLlib error";
        case 6: return "unable to open the input file";
        case 7: return "unable to open the output file";
        case 8: return "no QSOs were processed: they were duplicates or outside the certificate's date range";
        case 9: return "some QSOs were uploaded; others were ignored as duplicates or outside the date range";
        case 10: return "command syntax error";
        case 11: return "cannot reach LoTW (no network?)";
        default: return "TQSL exit code " + std::to_string(code);
    }
}

std::vector<TextEdit> markUploaded(std::string_view text, const DocModel &m, const std::vector<int> &groups, UploadService s,
                                   std::string_view today, LengthUnit unit, bool utf8) {
    UploadFields f = uploadFields(s);
    std::vector<PlannedChange> changes;
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        const ModelGroup &g = m.groups[(size_t)gi];
        for (const auto &want : {std::make_pair(f.status, std::string("Y")), std::make_pair(f.date, std::string(today))}) {
            PlannedChange c;
            c.group = gi;
            c.field = want.first;
            c.after = want.second;
            bool found = false;
            for (size_t i = 0; i < g.fieldCount && !found; ++i) {
                const ModelField &fld = m.fields[g.firstField + i];
                if (!equalsNoCase(fieldName(text, fld), want.first)) continue;
                found = true;
                if (fieldValue(text, fld) == want.second) break;
                c.kind = PlannedChange::Change;
                c.fieldIndex = g.firstField + i;
                changes.push_back(c);
            }
            if (!found) {
                c.kind = PlannedChange::Add;
                changes.push_back(c);
            }
        }
    }
    return planEdits(text, m, changes, unit, utf8);
}

bool isTrackingField(std::string_view name) {
    std::string n = upper(trim(name));
    for (const char *f : {"QSL_RCVD", "QSL_SENT", "QSLRDATE", "QSLSDATE", "QSL_RCVD_VIA", "QSL_SENT_VIA"})
        if (n == f) return true;
    for (const char *p : {"LOTW_", "EQSL_", "DCL_", "QRZCOM_", "CLUBLOG_", "HRDLOG_", "HAMLOGEU_", "HAMQTH_", "APP_"})
        if (n.rfind(p, 0) == 0) return true;
    return false;
}

std::vector<TextEdit> markModified(std::string_view text, const DocModel &m, const std::vector<int> &groups,
                                   LengthUnit unit, bool utf8) {
    std::vector<TextEdit> out;
    std::vector<int> seen;
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        if (std::find(seen.begin(), seen.end(), gi) != seen.end()) continue;
        seen.push_back(gi);
        const ModelGroup &g = m.groups[(size_t)gi];
        for (size_t i = 0; i < g.fieldCount; ++i) {
            const ModelField &f = m.fields[g.firstField + i];
            std::string_view name = fieldName(text, f);
            if ((equalsNoCase(name, "QRZCOM_QSO_UPLOAD_STATUS") || equalsNoCase(name, "CLUBLOG_QSO_UPLOAD_STATUS")) &&
                upper(trim(fieldValue(text, f))) == "Y")
                out.push_back(setFieldValue(text, f, "M", unit, utf8));
        }
    }
    std::sort(out.begin(), out.end(), [](const TextEdit &a, const TextEdit &b) { return a.start < b.start; });
    return out;
}

std::vector<TextEdit> mergeEdits(std::vector<TextEdit> edits, const std::vector<TextEdit> &extra) {
    // Two insertions at one place, or ranges sharing a byte (an insertion inside a replaced range counts).
    auto overlap = [](const TextEdit &a, const TextEdit &b) {
        if (a.start == a.end && b.start == b.end) return a.start == b.start;
        return a.start < b.end && b.start < a.end;
    };
    size_t base = edits.size();
    for (const TextEdit &e : extra) {
        bool clash = false;
        for (size_t i = 0; i < base && !clash; ++i) clash = overlap(edits[i], e);
        if (!clash) edits.push_back(e);
    }
    std::stable_sort(edits.begin(), edits.end(),
                     [](const TextEdit &a, const TextEdit &b) { return a.start != b.start ? a.start < b.start : a.end < b.end; });
    return edits;
}

std::string multipartBody(const std::vector<MultipartPart> &parts, std::string_view boundary) {
    std::string out;
    for (const MultipartPart &p : parts) {
        out += "--" + std::string(boundary) + "\r\n";
        out += "Content-Disposition: form-data; name=\"" + headerSafe(p.name) + "\"";
        if (!p.filename.empty())
            out += "; filename=\"" + headerSafe(p.filename) + "\"\r\nContent-Type: application/octet-stream";
        out += "\r\n\r\n" + p.value + "\r\n";
    }
    out += "--" + std::string(boundary) + "--\r\n";
    return out;
}

}  // namespace adif
