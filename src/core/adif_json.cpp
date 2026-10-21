#include "adif_json.h"

#include <cmath>
#include <cstring>

namespace adif::json {

const Value *Value::get(std::string_view key) const {
    if (type != Type::Object) return nullptr;
    for (const auto &m : members)
        if (m.first == key) return &m.second;
    return nullptr;
}

std::string Value::str(std::string_view key) const {
    const Value *v = get(key);
    return v && v->type == Type::String ? v->text : std::string();
}

namespace {

constexpr int kMaxDepth = 64;

struct Reader {
    std::string_view s;
    size_t at = 0;
    size_t values = 0, maxValues = 0;
    std::string why;

    bool fail(const char *what) {
        if (why.empty()) why = std::string(what) + " at byte " + std::to_string(at);
        return false;
    }
    void space() {
        while (at < s.size() && (s[at] == ' ' || s[at] == '\t' || s[at] == '\n' || s[at] == '\r')) ++at;
    }
    bool eat(char c) {
        space();
        if (at < s.size() && s[at] == c) return ++at, true;
        return false;
    }
    bool literal(const char *word) {
        size_t n = std::strlen(word);
        if (s.compare(at, n, word) != 0) return fail("a bad literal");
        at += n;
        return true;
    }

    static void utf8(std::string &out, uint32_t c) {
        if (c < 0x80) out.push_back((char)c);
        else if (c < 0x800) out.push_back((char)(0xC0 | (c >> 6))), out.push_back((char)(0x80 | (c & 0x3F)));
        else if (c < 0x10000)
            out.push_back((char)(0xE0 | (c >> 12))), out.push_back((char)(0x80 | ((c >> 6) & 0x3F))), out.push_back((char)(0x80 | (c & 0x3F)));
        else
            out.push_back((char)(0xF0 | (c >> 18))), out.push_back((char)(0x80 | ((c >> 12) & 0x3F))),
                out.push_back((char)(0x80 | ((c >> 6) & 0x3F))), out.push_back((char)(0x80 | (c & 0x3F)));
    }
    bool hex4(uint32_t *out) {
        if (at + 4 > s.size()) return fail("a short \\u escape");
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) {
            char c = s[at++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
            else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
            else return fail("a bad \\u escape");
        }
        *out = v;
        return true;
    }
    bool string(std::string *out) {
        if (at >= s.size() || s[at] != '"') return fail("a string expected");
        ++at;
        out->clear();
        while (true) {
            if (at >= s.size()) return fail("an unfinished string");
            unsigned char c = (unsigned char)s[at++];
            if (c == '"') return true;
            if (c < 0x20) return fail("a control character in a string");
            if (c != '\\') {
                out->push_back((char)c);
                continue;
            }
            if (at >= s.size()) return fail("an unfinished escape");
            char e = s[at++];
            switch (e) {
                case '"': out->push_back('"'); break;
                case '\\': out->push_back('\\'); break;
                case '/': out->push_back('/'); break;
                case 'b': out->push_back('\b'); break;
                case 'f': out->push_back('\f'); break;
                case 'n': out->push_back('\n'); break;
                case 'r': out->push_back('\r'); break;
                case 't': out->push_back('\t'); break;
                case 'u': {
                    uint32_t c1;
                    if (!hex4(&c1)) return false;
                    if (c1 >= 0xD800 && c1 < 0xDC00) {  // a surrogate pair
                        uint32_t c2;
                        if (at + 2 > s.size() || s[at] != '\\' || s[at + 1] != 'u') {
                            utf8(*out, 0xFFFD);
                            break;
                        }
                        at += 2;
                        if (!hex4(&c2)) return false;
                        if (c2 >= 0xDC00 && c2 < 0xE000) utf8(*out, 0x10000 + ((c1 - 0xD800) << 10) + (c2 - 0xDC00));
                        else utf8(*out, 0xFFFD), utf8(*out, c2 >= 0xD800 && c2 < 0xE000 ? 0xFFFD : c2);
                    } else {
                        utf8(*out, c1 >= 0xDC00 && c1 < 0xE000 ? 0xFFFD : c1);
                    }
                    break;
                }
                default: return fail("a bad escape");
            }
        }
    }
    // The JSON number grammar, read without the C library's locale.
    bool number(double *out) {
        size_t start = at;
        bool negative = false;
        if (at < s.size() && s[at] == '-') negative = true, ++at;
        if (at >= s.size() || !(s[at] >= '0' && s[at] <= '9')) return fail("a bad number");
        uint64_t mantissa = 0;
        int digits = 0, exp10 = 0;
        auto digit = [&](char c, bool fraction) {
            if (digits < 19) mantissa = mantissa * 10 + (uint64_t)(c - '0'), ++digits, exp10 -= fraction;
            else if (!fraction) ++exp10;  // beyond 19 digits: the integer part's magnitude only
        };
        if (s[at] == '0') ++at;
        else
            while (at < s.size() && s[at] >= '0' && s[at] <= '9') digit(s[at++], false);
        if (at < s.size() && s[at] == '.') {
            ++at;
            if (at >= s.size() || !(s[at] >= '0' && s[at] <= '9')) return fail("a bad fraction");
            while (at < s.size() && s[at] >= '0' && s[at] <= '9') digit(s[at++], true);
        }
        if (at < s.size() && (s[at] == 'e' || s[at] == 'E')) {
            ++at;
            int sign = 1, e = 0;
            if (at < s.size() && (s[at] == '+' || s[at] == '-')) sign = s[at] == '-' ? -1 : 1, ++at;
            if (at >= s.size() || !(s[at] >= '0' && s[at] <= '9')) return fail("a bad exponent");
            while (at < s.size() && s[at] >= '0' && s[at] <= '9') e = std::min(e * 10 + (s[at++] - '0'), 100000);
            exp10 += sign * e;
        }
        (void)start;
        long double v = (long double)mantissa;
        if (exp10 > 400) v = mantissa ? HUGE_VALL : 0;
        else if (exp10 < -400) v = 0;
        else if (exp10) v *= std::pow(10.0L, (long double)exp10);
        *out = (double)(negative ? -v : v);
        return true;
    }

    // An array whose elements allow it, packed (see the header).
    static void pack(Value &a) {
        if (a.items.empty()) return;
        auto all = [&](auto test) {
            for (const Value &v : a.items)
                if (!test(v)) return false;
            return true;
        };
        if (all([](const Value &v) { return v.type == Value::Type::Number; })) {
            a.stride = 1;
            a.packed.reserve(a.items.size());
            for (const Value &v : a.items) a.packed.push_back(v.number);
        } else if (size_t n = a.items[0].type == Value::Type::Array && a.items[0].stride == 1 ? a.items[0].packed.size() : 0;
                   (n == 2 || n == 3) &&
                   all([&](const Value &v) { return v.type == Value::Type::Array && v.stride == 1 && v.packed.size() == n; })) {
            a.stride = (uint8_t)n;
            a.packed.reserve(a.items.size() * n);
            for (const Value &v : a.items) a.packed.insert(a.packed.end(), v.packed.begin(), v.packed.end());
        } else if (all([](const Value &v) {
                       if (v.type != Value::Type::Object || v.members.size() != 2) return false;
                       const Value *lat = v.get("lat"), *lon = v.get("lon");
                       return lat && lon && lat->isNumber() && lon->isNumber();
                   })) {
            a.stride = 2;
            a.packed.reserve(a.items.size() * 2);
            for (const Value &v : a.items) a.packed.push_back(v.get("lon")->number), a.packed.push_back(v.get("lat")->number);
        } else {
            return;
        }
        std::vector<Value>().swap(a.items);
    }

    bool value(Value *out, int depth) {
        if (++values > maxValues) return fail("too many values");
        if (depth > kMaxDepth) return fail("nested too deeply");
        space();
        if (at >= s.size()) return fail("a value expected");
        char c = s[at];
        if (c == '{') {
            ++at;
            out->type = Value::Type::Object;
            if (eat('}')) return true;
            while (true) {
                space();
                std::string key;
                if (!string(&key)) return false;
                if (!eat(':')) return fail("':' expected");
                out->members.emplace_back(std::move(key), Value());
                if (!value(&out->members.back().second, depth + 1)) return false;
                if (eat(',')) continue;
                if (eat('}')) return true;
                return fail("',' or '}' expected");
            }
        }
        if (c == '[') {
            ++at;
            out->type = Value::Type::Array;
            if (eat(']')) return true;
            while (true) {
                out->items.emplace_back();
                if (!value(&out->items.back(), depth + 1)) return false;
                if (eat(',')) continue;
                if (eat(']')) return pack(*out), true;
                return fail("',' or ']' expected");
            }
        }
        if (c == '"') return out->type = Value::Type::String, string(&out->text);
        if (c == 't') return out->type = Value::Type::Bool, out->boolean = true, literal("true");
        if (c == 'f') return out->type = Value::Type::Bool, literal("false");
        if (c == 'n') return out->type = Value::Type::Null, literal("null");
        return out->type = Value::Type::Number, number(&out->number);
    }
};

}  // namespace

bool parse(std::string_view text, Value *out, std::string *why, size_t maxValues) {
    Reader r;
    r.s = text;
    r.maxValues = maxValues;
    if (text.size() >= 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB && (unsigned char)text[2] == 0xBF) r.at = 3;  // a BOM
    Value v;
    bool ok = r.value(&v, 0);
    if (ok) {
        r.space();
        if (r.at != text.size()) ok = r.fail("text after the value");
    }
    if (!ok) {
        if (why) *why = r.why;
        return false;
    }
    *out = std::move(v);
    return true;
}

}  // namespace adif::json
