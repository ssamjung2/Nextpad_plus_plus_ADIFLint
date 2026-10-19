#include "adif_i18n.h"

#include <atomic>
#include <cctype>
#include <cstdint>

namespace adif::i18n {
namespace {

std::shared_ptr<const Table> gTable;  // read and written with std::atomic_load/store

std::shared_ptr<const Table> current() { return std::atomic_load(&gTable); }

// A small JSON reader: objects of strings and objects, as the tables use; nothing else.
struct Json {
    std::string_view s;
    size_t at = 0;
    std::string why;
    void space() {
        while (at < s.size() && (s[at] == ' ' || s[at] == '\t' || s[at] == '\n' || s[at] == '\r')) ++at;
    }
    bool fail(const char *what) {
        if (why.empty()) why = std::string(what) + " at byte " + std::to_string(at);
        return false;
    }
    bool eat(char c) {
        space();
        if (at < s.size() && s[at] == c) return ++at, true;
        return false;
    }
    static void utf8(std::string &out, uint32_t cp) {
        if (cp < 0x80) out += (char)cp;
        else if (cp < 0x800) out += (char)(0xC0 | (cp >> 6)), out += (char)(0x80 | (cp & 0x3F));
        else if (cp < 0x10000) out += (char)(0xE0 | (cp >> 12)), out += (char)(0x80 | ((cp >> 6) & 0x3F)), out += (char)(0x80 | (cp & 0x3F));
        else
            out += (char)(0xF0 | (cp >> 18)), out += (char)(0x80 | ((cp >> 12) & 0x3F)), out += (char)(0x80 | ((cp >> 6) & 0x3F)),
                out += (char)(0x80 | (cp & 0x3F));
    }
    bool hex4(uint32_t *v) {
        if (s.size() - at < 4) return false;
        uint32_t r = 0;
        for (int i = 0; i < 4; ++i) {
            char c = s[at++];
            r <<= 4;
            if (c >= '0' && c <= '9') r |= (uint32_t)(c - '0');
            else if (c >= 'a' && c <= 'f') r |= (uint32_t)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') r |= (uint32_t)(c - 'A' + 10);
            else return false;
        }
        *v = r;
        return true;
    }
    bool string(std::string *out) {
        space();
        if (at >= s.size() || s[at] != '"') return fail("expected a string");
        ++at;
        out->clear();
        while (at < s.size()) {
            char c = s[at++];
            if (c == '"') return true;
            if ((unsigned char)c < 0x20) return fail("a control character in a string");
            if (c != '\\') {
                *out += c;
                continue;
            }
            if (at >= s.size()) break;
            char e = s[at++];
            switch (e) {
                case '"': *out += '"'; break;
                case '\\': *out += '\\'; break;
                case '/': *out += '/'; break;
                case 'b': *out += '\b'; break;
                case 'f': *out += '\f'; break;
                case 'n': *out += '\n'; break;
                case 'r': *out += '\r'; break;
                case 't': *out += '\t'; break;
                case 'u': {
                    uint32_t cp = 0, lo = 0;
                    if (!hex4(&cp)) return fail("a bad \\u escape");
                    if (cp >= 0xD800 && cp < 0xDC00) {  // a surrogate pair
                        if (s.size() - at < 6 || s[at] != '\\' || s[at + 1] != 'u') return fail("half a surrogate pair");
                        at += 2;
                        if (!hex4(&lo) || lo < 0xDC00 || lo > 0xDFFF) return fail("half a surrogate pair");
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        return fail("half a surrogate pair");
                    }
                    utf8(*out, cp);
                    break;
                }
                default: return fail("a bad escape");
            }
        }
        return fail("an unterminated string");
    }
    // An object of string values; with `nested`, a value may be an object of strings too.
    bool object(std::vector<std::pair<std::string, std::string>> *flat, std::vector<std::pair<std::string, std::map<std::string, std::string>>> *nested,
                int depth) {
        if (depth > 4) return fail("nested too deep");
        if (!eat('{')) return fail("expected an object");
        if (eat('}')) return true;
        do {
            std::string key, value;
            if (!string(&key) || !eat(':')) return fail("expected a key");
            space();
            if (at < s.size() && s[at] == '{') {
                if (!nested) return fail("an object where a string belongs");
                std::vector<std::pair<std::string, std::string>> inner;
                if (!object(&inner, nullptr, depth + 1)) return false;
                nested->push_back({key, std::map<std::string, std::string>(inner.begin(), inner.end())});
            } else {
                if (!string(&value)) return false;
                flat->push_back({key, value});
            }
        } while (eat(','));
        if (!eat('}')) return fail("expected , or }");
        return true;
    }
};

bool isPrintfFlag(char c) { return c == '-' || c == '+' || c == ' ' || c == '#' || c == '0' || c == '\''; }

}  // namespace

bool parseTable(std::string_view json, Table *out, std::string *why) {
    Json j;
    j.s = json;
    Table t;
    auto bad = [&](std::string w) {
        if (why) *why = std::move(w);
        return false;
    };
    if (!j.eat('{')) return bad("not a JSON object");
    bool strings = false;
    if (!j.eat('}')) do {
            std::string key;
            if (!j.string(&key) || !j.eat(':')) return bad(j.why.empty() ? "expected a key" : j.why);
            std::vector<std::pair<std::string, std::string>> flat;
            std::vector<std::pair<std::string, std::map<std::string, std::string>>> nested;
            if (key == "meta") {
                if (!j.object(&flat, nullptr, 1)) return bad(j.why);
                for (const auto &[k, v] : flat) {
                    if (k == "language") t.language = v;
                    else if (k == "name") t.name = v;
                    else if (k == "note") t.note = v;
                }
            } else if (key == "strings") {
                if (!j.object(&flat, &nested, 1)) return bad(j.why);
                for (auto &[k, v] : flat) t.strings[k] = std::move(v);
                for (auto &[k, v] : nested) t.plurals[k] = std::move(v);
                strings = true;
            } else {
                return bad("an unknown section: " + key);
            }
        } while (j.eat(','));
    if (!j.eat('}')) return bad(j.why.empty() ? "expected , or }" : j.why);
    j.space();
    if (j.at != json.size()) return bad("text after the table");
    if (!strings || t.language.empty()) return bad("a table needs meta.language and strings");
    *out = std::move(t);
    return true;
}

void use(std::shared_ptr<const Table> table) { std::atomic_store(&gTable, std::move(table)); }

std::string language() {
    auto t = current();
    return t ? t->language : "en";
}

std::string tr(std::string_view english) {
    auto t = current();
    if (t) {
        auto it = t->strings.find(std::string(english));
        if (it != t->strings.end() && !it->second.empty()) return it->second;
    }
    return std::string(english.substr(0, english.find("##")));  // a context ("Solid##line") isn't shown
}

namespace {

template <class Pairs>
std::string fillFrom(std::string_view text, const Pairs &args) {
    std::string out;
    out.reserve(text.size() + 16);
    for (size_t i = 0; i < text.size();) {
        if (text[i] == '{') {
            size_t close = text.find('}', i + 1);
            if (close != std::string_view::npos) {
                std::string_view name = text.substr(i + 1, close - i - 1);
                bool done = false;
                for (const auto &[k, v] : args)
                    if (std::string_view(k) == name) {
                        out += v, done = true;
                        break;
                    }
                if (done) {
                    i = close + 1;
                    continue;
                }
            }
        }
        out += text[i++];
    }
    return out;
}

}  // namespace

std::string fill(std::string_view text, Args args) { return fillFrom(text, args); }

std::string fill(std::string_view text, const std::vector<std::pair<std::string, std::string>> &args) { return fillFrom(text, args); }

std::string trf(std::string_view english, Args args) { return fill(tr(english), args); }

const char *pluralCategory(std::string_view lang, long long n) {
    long long a = n < 0 ? -n : n;
    std::string_view l = lang.substr(0, lang.find_first_of("-_"));
    if (l == "ko" || l == "ja" || l == "zh") return "other";
    if (l == "fr") return a == 0 || a == 1 ? "one" : a % 1000000 == 0 ? "many" : "other";
    if (l == "es") return a == 1 ? "one" : a != 0 && a % 1000000 == 0 ? "many" : "other";
    return a == 1 ? "one" : "other";  // en, de
}

std::string trp(std::string_view one, std::string_view other, long long n, Args args) {
    std::string text;
    auto t = current();
    const char *cat = pluralCategory(t ? t->language : "en", n);
    if (t) {
        auto it = t->plurals.find(std::string(one) + "|" + std::string(other));
        if (it != t->plurals.end()) {
            auto f = it->second.find(cat);
            if (f == it->second.end()) f = it->second.find("other");
            if (f != it->second.end()) text = f->second;
        }
    }
    if (text.empty()) text = std::string(n == 1 ? one : other);
    std::string count = std::to_string(n);
    std::string out = fill(text, {{"n", count}});
    return args.size() ? fill(out, args) : out;
}

std::vector<std::string> placeholders(std::string_view text) {
    std::vector<std::string> out;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '{') {
            size_t close = text.find('}', i + 1);
            if (close != std::string_view::npos && close > i + 1) {
                std::string_view name = text.substr(i + 1, close - i - 1);
                bool word = true;
                for (char c : name) word = word && (std::isalnum((unsigned char)c) || c == '_');
                if (word) {
                    out.emplace_back(text.substr(i, close - i + 1));
                    i = close;
                }
            }
        } else if (text[i] == '%' && i + 1 < text.size()) {
            if (text[i + 1] == '%') {
                ++i;
                continue;
            }
            size_t j = i + 1;
            while (j < text.size() && std::isdigit((unsigned char)text[j])) ++j;
            if (j < text.size() && text[j] == '$') ++j;
            else j = i + 1;  // not positional
            while (j < text.size() && isPrintfFlag(text[j])) ++j;
            while (j < text.size() && (std::isdigit((unsigned char)text[j]) || text[j] == '*')) ++j;
            if (j < text.size() && text[j] == '.') {
                ++j;
                while (j < text.size() && (std::isdigit((unsigned char)text[j]) || text[j] == '*')) ++j;
            }
            while (j < text.size() && std::string_view("hlzjtLq").find(text[j]) != std::string_view::npos) ++j;
            if (j < text.size() && std::string_view("@diouxXeEfFgGcsp").find(text[j]) != std::string_view::npos) {
                out.emplace_back(text.substr(i, j - i + 1));
                i = j;
            }
        }
    }
    return out;
}

}  // namespace adif::i18n
