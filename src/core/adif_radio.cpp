#include "adif_radio.h"

#include <cstdlib>

namespace adif {
namespace {

std::string upper(std::string_view s) {
    std::string o;
    for (char c : s)
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') o.push_back((c >= 'a' && c <= 'z') ? (char)(c - 32) : c);
    return o;
}

std::string trim(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return std::string(s.substr(b, e - b));
}

bool startsWith(std::string_view s, std::string_view p) { return s.substr(0, p.size()) == p; }

std::string xmlUnescape(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '&') {
            out.push_back(s[i]);
            continue;
        }
        static const std::pair<const char *, char> kEntities[] = {
            {"&lt;", '<'}, {"&gt;", '>'}, {"&amp;", '&'}, {"&quot;", '"'}, {"&apos;", '\''}};
        bool done = false;
        for (const auto &e : kEntities) {
            std::string_view name(e.first);
            if (s.substr(i, name.size()) == name) {
                out.push_back(e.second);
                i += name.size() - 1;
                done = true;
                break;
            }
        }
        if (!done) out.push_back('&');
    }
    return out;
}

}  // namespace

std::string hzToMHz(std::string_view hz) {
    std::string d = trim(hz);
    size_t dot = d.find('.');
    bool roundUp = false;
    if (dot != std::string::npos) {  // "14074000.000000": a fraction of a hertz, rounded
        std::string frac = d.substr(dot + 1);
        for (char c : frac)
            if (c < '0' || c > '9') return "";
        roundUp = !frac.empty() && frac[0] >= '5';
        d.resize(dot);
    }
    if (d.empty() || d.size() > 15) return "";
    for (char c : d)
        if (c < '0' || c > '9') return "";
    unsigned long long v = std::strtoull(d.c_str(), nullptr, 10) + (roundUp ? 1 : 0);
    std::string whole = std::to_string(v / 1000000), frac = std::to_string(v % 1000000);
    frac = std::string(6 - frac.size(), '0') + frac;
    while (frac.size() > 3 && frac.back() == '0') frac.pop_back();
    return whole + "." + frac;
}

RigMode mapRigMode(std::string_view rigMode) {
    std::string m = upper(rigMode);
    RigMode r;
    if (m.empty()) return r;
    auto any = [&](std::initializer_list<const char *> names) {
        for (const char *n : names)
            if (m == n) return true;
        return false;
    };
    // Digital voice names first ("D-STAR" would look like data below).
    if (any({"DV", "DSTAR", "D-STAR"})) return {"DIGITALVOICE", "DSTAR", false};
    if (any({"C4FM"})) return {"DIGITALVOICE", "C4FM", false};  // Yaesu System Fusion
    // Data: "USB-D", "DATA-U", "PKTUSB", "D-FM", "PSK-U"... sideband or FM carrying a sound-card mode.
    if (startsWith(m, "PKT") || startsWith(m, "DATA") || startsWith(m, "DIG") || startsWith(m, "D-") ||
        startsWith(m, "PSK") || m.find("-D") != std::string::npos || any({"USBD", "LSBD"})) {
        r.data = true;
        return r;
    }
    if (any({"USB"})) return {"SSB", "USB", false};
    if (any({"LSB"})) return {"SSB", "LSB", false};
    if (startsWith(m, "CW")) return {"CW", "", false};
    if (startsWith(m, "RTTY") || startsWith(m, "FSK")) return {"RTTY", "", false};
    if (any({"DMR"})) return {"DIGITALVOICE", "DMR", false};
    if (any({"FREEDV"})) return {"DIGITALVOICE", "FREEDV", false};
    if (any({"M17"})) return {"DIGITALVOICE", "M17", false};
    if (startsWith(m, "AM") || any({"SAM", "SAL", "SAH", "DSB", "ECSSUSB", "ECSSLSB"})) return {"AM", "", false};
    if (startsWith(m, "FM") || any({"WFM", "NFM"})) return {"FM", "", false};
    if (any({"FA", "FAX"})) return {"FAX", "", false};
    return r;  // unknown: leave MODE to the operator
}

std::vector<RigctldBlock> parseRigctld(std::string_view reply) {
    std::vector<RigctldBlock> out;
    RigctldBlock cur;
    bool open = false;
    size_t start = 0;
    while (start < reply.size()) {
        size_t nl = reply.find('\n', start);
        std::string line = trim(reply.substr(start, nl == std::string_view::npos ? std::string_view::npos : nl - start));
        start = nl == std::string_view::npos ? reply.size() : nl + 1;
        if (line.empty()) continue;
        if (startsWith(line, "RPRT ")) {
            cur.result = std::atoi(line.c_str() + 5);
            out.push_back(cur);
            cur = RigctldBlock();
            open = false;
            continue;
        }
        size_t colon = line.find(':');
        if (!open && colon != std::string::npos && colon + 1 == line.size()) {  // "get_mode:" echo
            cur.command = line.substr(0, colon);
            open = true;
            continue;
        }
        if (colon == std::string::npos) continue;
        std::string key = trim(line.substr(0, colon)), value = trim(line.substr(colon + 1));
        if (!open) {  // "get_freq: 14074000" style echo with a value: the echo of the command and its arguments
            cur.command = key;
            open = true;
            continue;
        }
        cur.values[key] = value;
    }
    return out;
}

std::string rigctldQuery(bool vfoMode) {
    return vfoMode ? "+\\get_freq currVFO\n+\\get_mode currVFO\n" : "+\\get_freq\n+\\get_mode\n";
}

std::string xmlRpcRequest(std::string_view method) {
    return "<?xml version=\"1.0\"?>\r\n<methodCall><methodName>" + std::string(method) +
           "</methodName>\r\n<params></params></methodCall>\r\n";
}

bool xmlRpcValue(std::string_view body, std::string *value, std::string *fault) {
    if (body.find("<fault>") != std::string_view::npos) {
        size_t s = body.find("<string>"), e = body.find("</string>");
        if (fault) *fault = s != std::string_view::npos && e > s ? xmlUnescape(body.substr(s + 8, e - s - 8)) : "XML-RPC fault";
        return false;
    }
    size_t param = body.find("<param>");
    size_t vb = param == std::string_view::npos ? std::string_view::npos : body.find("<value>", param);
    size_t ve = vb == std::string_view::npos ? std::string_view::npos : body.find("</value>", vb);
    if (vb == std::string_view::npos || ve == std::string_view::npos) {
        if (fault) *fault = "unreadable XML-RPC response";
        return false;
    }
    std::string inner = trim(body.substr(vb + 7, ve - vb - 7));
    // <string>x</string>, <i4>n</i4>, <int>n</int>, <double>f</double>, or bare text (a string).
    if (!inner.empty() && inner[0] == '<') {
        size_t gt = inner.find('>');
        size_t close = inner.rfind("</");
        if (gt == std::string::npos || close == std::string::npos || close < gt) {
            if (inner == "<string/>") inner.clear();
            else {
                if (fault) *fault = "unreadable XML-RPC value";
                return false;
            }
        } else {
            inner = inner.substr(gt + 1, close - gt - 1);
        }
    }
    if (value) *value = xmlUnescape(inner);
    return true;
}

std::string httpPost(std::string_view host, int port, std::string_view body) {
    std::string r = "POST /RPC2 HTTP/1.1\r\nHost: " + std::string(host) + ":" + std::to_string(port) +
                    "\r\nUser-Agent: ADIF Lint\r\nContent-Type: text/xml\r\nContent-Length: " + std::to_string(body.size()) +
                    "\r\nConnection: close\r\n\r\n";
    r.append(body);
    return r;
}

bool httpResponse(std::string_view raw, int *status, std::string *body) {
    size_t end = raw.find("\r\n\r\n");
    if (end == std::string_view::npos) return false;
    std::string_view head = raw.substr(0, end);
    if (!startsWith(head, "HTTP/")) return false;
    size_t sp = head.find(' ');
    if (status) *status = sp == std::string_view::npos ? 0 : std::atoi(std::string(head.substr(sp + 1, 3)).c_str());
    long length = -1;
    size_t at = 0;
    while (at < head.size()) {
        size_t nl = head.find("\r\n", at);
        std::string line(head.substr(at, nl == std::string_view::npos ? std::string_view::npos : nl - at));
        at = nl == std::string_view::npos ? head.size() : nl + 2;
        std::string key = upper(line.substr(0, line.find(':')));
        if (key == "CONTENT-LENGTH" && line.find(':') != std::string::npos) length = std::atol(line.c_str() + line.find(':') + 1);
    }
    std::string_view rest = raw.substr(end + 4);
    if (length < 0) return false;  // flrig's server always sends Content-Length; without it, wait for the close
    if ((long)rest.size() < length) return false;
    if (body) *body = std::string(rest.substr(0, (size_t)length));
    return true;
}

}  // namespace adif
