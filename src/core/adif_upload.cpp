#include "adif_upload.h"
#include "adif_i18n.h"

#include "adif_spec.h"
#include "adif_tools.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>

namespace adif {
using i18n::tr;
using i18n::trf;
using i18n::trp;
namespace {

std::string upper(std::string_view s) {
    std::string o;
    for (char c : s) o.push_back((c >= 'a' && c <= 'z') ? (char)(c - 32) : c);
    return o;
}

std::string lower(std::string_view s) {
    std::string o;
    for (char c : s) o.push_back((c >= 'A' && c <= 'Z') ? (char)(c + 32) : c);
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
                          "CLUBLOG_QSO_UPLOAD_DATE", "LOTW_QSL_SENT", "LOTW_QSLSDATE", "EQSL_QSL_SENT", "EQSL_QSLSDATE",
                          "APP_ADIFLINT_WRL_QSO_UPLOAD_STATUS", "APP_ADIFLINT_WRL_QSO_UPLOAD_DATE", "HRDLOG_QSO_UPLOAD_STATUS",
                          "HRDLOG_QSO_UPLOAD_DATE", "HAMQTH_QSO_UPLOAD_STATUS", "HAMQTH_QSO_UPLOAD_DATE"})
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
        case UploadService::WRL: return {"APP_ADIFLINT_WRL_QSO_UPLOAD_STATUS", "APP_ADIFLINT_WRL_QSO_UPLOAD_DATE"};
        case UploadService::HRDLog: return {"HRDLOG_QSO_UPLOAD_STATUS", "HRDLOG_QSO_UPLOAD_DATE"};
        case UploadService::HamQTH: return {"HAMQTH_QSO_UPLOAD_STATUS", "HAMQTH_QSO_UPLOAD_DATE"};
    }
    return {"", ""};
}

const char *uploadServiceName(UploadService s) {
    switch (s) {
        case UploadService::QRZ: return "QRZ.com Logbook";
        case UploadService::LoTW: return "LoTW";
        case UploadService::ClubLog: return "Club Log";
        case UploadService::EQSL: return "eQSL";
        case UploadService::WRL: return "World Radio League";
        case UploadService::HRDLog: return "HRDLog.net";
        case UploadService::HamQTH: return "HamQTH";
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
        if (i.call.empty()) i.problem = tr("no CALL");
        else if (!parseAdifDate(i.date, nullptr)) i.problem = tr("no valid QSO_DATE");
        else if (!parseAdifTime(i.time, nullptr)) i.problem = tr("no valid TIME_ON");
        else if (i.band.empty()) i.problem = tr("no BAND or FREQ");
        else if (i.mode.empty()) i.problem = tr("no MODE");
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
    out += makeSpecifier("ADIF_VER", specVersion(), LengthUnit::Bytes, false) + "\n";
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
            *error = e == std::string_view::npos ? tr("eQSL did not build the file") : std::string(trim(line.substr(0, end)));
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
    if (error) *error = tr("eQSL built the file but its link was not found");
    return "";
}

std::string tqslExitMeaning(int code) {
    switch (code) {
        case 0: return tr("all QSOs were signed and uploaded");
        case 1: return tr("cancelled");
        case 2: return tr("rejected by LoTW");
        case 3: return tr("unexpected response from the TQSL server");
        case 4: return tr("TQSL error (such as no valid certificate for that callsign and DXCC entity)");
        case 5: return tr("TQSLlib error");
        case 6: return tr("unable to open the input file");
        case 7: return tr("unable to open the output file");
        case 8: return tr("no QSOs were processed: they were duplicates or outside the certificate's date range");
        case 9: return tr("some QSOs were uploaded; others were ignored as duplicates or outside the date range");
        case 10: return tr("command syntax error");
        case 11: return tr("cannot reach LoTW (no network?)");
        // 12 to 15: TQSL's tqslapp.h (master, read 2026-10-25); ARRL's help page lists 0 to 11.
        case 12: return tr("unknown TQSL error");
        case 13: return tr("TQSL is busy: its uploads database is in use");
        case 14: return tr("the QSOs were already signed and uploaded");
        case 15: return tr("wrong certificate password");
        default: return trf("TQSL exit code {code}", {{"code", std::to_string(code)}});
    }
}

std::string hrdlogBody(std::string_view callsign, std::string_view code, std::string_view app, std::string_view adi, std::string_view key) {
    std::string out = "Callsign=" + formEncode(callsign) + "&Code=" + formEncode(code) + "&App=" + formEncode(app);
    if (!key.empty()) out += "&Cmd=UPDATE&ADIFKey=" + formEncode(key);
    return out + "&ADIFData=" + formEncode(adi);
}

std::string qsoKeyAdi(std::string_view text, const DocModel &m, int group) {
    if (group < 0 || (size_t)group >= m.groups.size()) return "";
    std::string out;
    for (const char *f : {"CALL", "QSO_DATE", "TIME_ON", "BAND", "MODE"}) {
        std::string v(groupValue(text, m, m.groups[(size_t)group], f));
        if (!v.empty()) out += makeSpecifier(f, v, LengthUnit::Bytes, true) + " ";
    }
    return out + "<EOR>";
}

HrdlogReply parseHrdlogReply(std::string_view xml) {
    // The text of the first element with this local name, whatever its namespace prefix.
    auto element = [&](std::string_view name, std::string *value) {
        for (size_t at = xml.find('<'); at != std::string_view::npos; at = xml.find('<', at + 1)) {
            size_t end = xml.find_first_of(" \t\r\n/>", at + 1);
            if (end == std::string_view::npos) return false;
            std::string_view tag = xml.substr(at + 1, end - at - 1);
            if (size_t colon = tag.find(':'); colon != std::string_view::npos) tag = tag.substr(colon + 1);
            if (tag != name) continue;
            size_t open = xml.find('>', end);
            if (open == std::string_view::npos) return false;
            if (xml[open - 1] == '/') {  // <insert/>
                value->clear();
                return true;
            }
            size_t close = xml.find('<', open + 1);
            *value = trim(xml.substr(open + 1, (close == std::string_view::npos ? xml.size() : close) - open - 1));
            return true;
        }
        return false;
    };
    HrdlogReply r;
    std::string v;
    if (element("error", &v)) {
        r.message = htmlDecode(v);
        r.unknownUser = r.message == "Unknown user" || r.message == "Invalid token";
        r.notFound = r.message.find("Unable to find QSO") != std::string::npos;
    } else if (element("insert", &v) || element("update", &v)) {
        long long n = std::atoll(v.c_str());
        r.ok = n > 0;
        r.duplicate = n == 0;
    }
    return r;
}

std::string jsonQuote(std::string_view s) {
    static const char kHex[] = "0123456789abcdef";
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out += '\\', out += (char)c;
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (c < 0x20) out += "\\u00", out += kHex[c >> 4], out += kHex[c & 15];
        else out += (char)c;
    }
    return out + "\"";
}

std::string hamqthQsoJson(std::string_view text, const DocModel &m, int group, bool replace) {
    if (group < 0 || (size_t)group >= m.groups.size()) return "";
    const ModelGroup &g = m.groups[(size_t)group];
    auto value = [&](const char *f) { return trim(groupValue(text, m, g, f)); };
    // The fields HamQTH stores (its developers page), the band in capitals as its examples write it.
    static const char *const kStored[] = {"CALL", "QSO_DATE", "TIME_ON", "TIME_OFF", "BAND", "FREQ", "MODE", "SUBMODE", "RST_SENT",
                                          "RST_RCVD", "NAME", "QTH", "QSL_SENT", "QSL_RCVD", "QSL_VIA", "QSLSDATE", "QSLRDATE", "IOTA",
                                          "TX_PWR", "GRIDSQUARE", "MY_GRIDSQUARE", "CQZ", "ITUZ", "CONT", "DXCC", "STATE", "CNTY",
                                          "LOTW_QSL_SENT", "LOTW_QSL_RCVD", "LOTW_QSLSDATE", "LOTW_QSLRDATE", "EQSL_QSL_SENT",
                                          "EQSL_QSL_RCVD", "EQSL_QSLSDATE", "EQSL_QSLRDATE"};
    auto object = [&](std::initializer_list<const char *> names) {
        std::string out;
        for (const char *f : names) {
            std::string v = value(f);
            if (v.empty()) continue;
            if (!std::strcmp(f, "BAND")) v = upper(v);
            out += (out.empty() ? "" : ",") + jsonQuote(lower(f)) + ":" + jsonQuote(v);
        }
        return "{" + out + "}";
    };
    std::string qso;
    for (const char *f : kStored) {
        std::string v = value(f);
        if (v.empty()) continue;
        if (!std::strcmp(f, "BAND")) v = upper(v);
        qso += (qso.empty() ? "" : ",") + jsonQuote(lower(f)) + ":" + jsonQuote(v);
    }
    std::string out = "{";
    std::string station = upper(value("STATION_CALLSIGN"));
    if (!station.empty()) out += "\"callsign\":" + jsonQuote(station) + ",";
    out += "\"qso\":{" + qso + "}";
    if (replace) {
        std::string original = object({"CALL", "QSO_DATE", "TIME_ON", "BAND"});
        std::string mode = upper(value("MODE"));
        if (mode == "USB" || mode == "LSB") mode = "SSB";  // "USB and LSB are stored as SSB"
        if (!mode.empty()) original.insert(original.size() - 1, std::string(original.size() > 2 ? "," : "") + "\"mode\":" + jsonQuote(mode));
        out += ",\"original\":" + original;
    }
    return out + "}";
}

bool wrlImportFinished(std::string_view status) {
    for (const char *s : {"complete", "complete_with_errors", "failed", "rejected", "expired", "cancelled"})
        if (status == s) return true;
    return false;
}

std::string wrlImportSummary(const WrlImport &imp) {
    auto n = [](long long v) { return std::to_string(v < 0 ? 0 : v); };
    const std::string &s = imp.status, &e = imp.errorCode;
    if (s == "complete" || s == "complete_with_errors") {
        std::string out = trp("World Radio League imported {imported} of {n} QSO", "World Radio League imported {imported} of {n} QSOs",
                                    std::max(imp.total, 0LL), {{"imported", n(imp.imported)}});
        if (imp.duplicates > 0) out += "; " + trp("{n} was already there", "{n} were already there", imp.duplicates);
        if (imp.failed > 0)
            out += "; " + trp("{n} could not be imported, and it doesn't say which", "{n} could not be imported, and it doesn't say which",
                                    imp.failed);
        return out + ".";
    }
    if (s == "rejected") {
        // The codes the Import schema lists for a rejected file.
        std::string why = e == "FILE_TOO_LARGE"           ? tr("the file is over 10 MB")
                          : e == "NO_RECORDS"             ? tr("it found no records in the file")
                          : e == "EXCEEDS_DAILY_LIMIT"    ? tr("the file holds more QSOs than your whole daily import allowance: send fewer at a time")
                          : e == "IMPORT_QUOTA_EXHAUSTED" ? tr("today's import allowance is used up: upload again after 00:00 UTC")
                          : e == "KEY_REVOKED"            ? tr("the API key was revoked: make a new one in World Radio League and save it in Settings")
                          : e == "LOGBOOK_DELETED"        ? tr("the logbook was deleted before the file was imported")
                          : e == "INTERNAL"               ? tr("it could not read the file after several tries")
                          : e.empty()                     ? tr("no reason given")
                                                          : e;
        return trf("World Radio League refused the file ({why}). Nothing was imported or charged.", {{"why", why}});
    }
    if (s == "failed")
        return e == "QUOTA_EXCEEDED" ? tr("The import stopped: your membership's import allowance was reached during it.")
                                     : trf("The import failed ({why}).", {{"why", e.empty() ? tr("no reason given") : e}});
    if (s == "expired") return tr("The import expired: World Radio League got no file within two hours.");
    if (s == "cancelled") return tr("The import was cancelled in World Radio League.");
    if (s == "awaiting_upload") return tr("World Radio League is waiting for the file...");
    if (s == "uploaded") return tr("World Radio League has the file and is checking it...");
    if (s == "queued") return tr("World Radio League has queued the import...");
    if (s == "processing")
        return imp.progress >= 0 ? trf("World Radio League is importing ({percent} done)...", {{"percent", std::to_string((int)imp.progress) + "%"}})
                                 : tr("World Radio League is importing...");
    return trf("World Radio League: {status}", {{"status", s}});
}

std::string wrlKeySummary(std::string_view tier, long long importPerDay, std::string_view resolution) {
    std::string out = tier.empty() ? tr("World Radio League accepted the key.")
                                   : trf("World Radio League accepted the key (membership: {tier}).", {{"tier", std::string(tier)}});
    if (importPerDay == 0) out += " " + tr("This membership can't import ADIF files, which Upload needs.");
    else if (importPerDay > 0) out += " " + trf("Uploads of up to {n} QSOs a day.", {{"n", std::to_string(importPerDay)}});
    if (resolution == "ambiguous")
        out += " " + tr("You have several logbooks and none is the default: choose one in World Radio League, as uploads go to the default.");
    else if (resolution == "none") out += " " + tr("You have no logbook yet: create one in World Radio League first.");
    else out += " " + tr("Uploads go to your default logbook.");
    return out;
}

bool wrlImportAllIn(const WrlImport &imp, size_t sent) {
    return imp.status == "complete" && imp.failed <= 0 && imp.imported >= 0 &&
           (size_t)(imp.imported + std::max(imp.duplicates, 0LL)) == sent;
}

std::string wrlErrorText(int httpStatus, std::string_view code, std::string_view message, std::string_view hint, long long retryAfter) {
    // The codes of the API's Error schema.
    std::string out = code == "MISSING_CREDENTIALS" || code == "INVALID_KEY"
                          ? tr("World Radio League did not accept the API key: check it in Settings.")
                      : code == "KEY_REVOKED"
                          ? tr("The API key was revoked: make a new one in World Radio League (Integrations, Developer API) and save it in Settings.")
                      : code == "MEMBERSHIP_REQUIRED" ? tr("Your World Radio League membership doesn't include the API.")
                      : code == "INSUFFICIENT_SCOPE"  ? tr("The API key isn't allowed to do this.")
                      : code == "IP_NOT_ALLOWED"      ? tr("The API key isn't allowed from this network address.")
                      : code == "CONFLICT"
                          ? tr("Another import is running or waiting for its file in your account (one at a time), or the logbook is locked: "
                               "try again when it's done.")
                      : code == "RATE_LIMITED"
                          ? (retryAfter > 0 ? trf("Too many requests: try again in {seconds} seconds.", {{"seconds", std::to_string(retryAfter)}})
                                            : tr("Too many requests: try again later."))
                      : code == "VALIDATION_ERROR" ? tr("World Radio League refused the request.")
                      : code == "API_DISABLED" || code == "POLICY_UNAVAILABLE" || code == "INTERNAL_ERROR"
                          ? tr("World Radio League's API isn't working just now: try again later.")
                          : trf("World Radio League answered HTTP {status}.", {{"status", std::to_string(httpStatus)}});
    std::string said(message);
    if (!hint.empty()) said += (said.empty() ? "" : " ") + std::string(hint);
    if (!said.empty()) out += " " + trf("It says: {text}", {{"text", said}});
    return out;
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
            if ((equalsNoCase(name, "QRZCOM_QSO_UPLOAD_STATUS") || equalsNoCase(name, "CLUBLOG_QSO_UPLOAD_STATUS") ||
                 equalsNoCase(name, "HRDLOG_QSO_UPLOAD_STATUS") || equalsNoCase(name, "HAMQTH_QSO_UPLOAD_STATUS")) &&
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
