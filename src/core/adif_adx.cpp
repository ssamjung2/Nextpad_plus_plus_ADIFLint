// ADX validation. libxml2 reads the XML and runs the published schemas; lint()
// (adif_lint.cpp) runs ADIF Lint's own rules on the records restated as ADI.
#include "adif_adx.h"

#include "adif_i18n.h"
#include "adif_spec.h"

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xmlerror.h>
#include <libxml/xmlschemas.h>

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace adif {
using i18n::tr;
using i18n::trf;
namespace {

constexpr size_t npos = std::string_view::npos;
constexpr size_t kMaxIssues = 20000;  // libxml2 reports per element, and a file can be wrong everywhere

// libxml2 2.12 made the error handlers' argument a pointer to const.
#if LIBXML_VERSION >= 21200
using XmlErrorArg = const xmlError *;
#else
using XmlErrorArg = xmlErrorPtr;
#endif

std::string_view str(const xmlChar *s) { return s ? std::string_view((const char *)s) : std::string_view(); }
bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

std::string_view trimmed(std::string_view s) {
    while (!s.empty() && isSpace(s.front())) s.remove_prefix(1);
    while (!s.empty() && isSpace(s.back())) s.remove_suffix(1);
    return s;
}

std::string upperAscii(std::string_view s) {
    std::string out(s);
    for (char &c : out)
        if (c >= 'a' && c <= 'z') c = char(c - 'a' + 'A');
    return out;
}

bool hasLower(std::string_view s) {
    return std::any_of(s.begin(), s.end(), [](char c) { return c >= 'a' && c <= 'z'; });
}

// ── What libxml2 reports ────────────────────────────────────────────────────

struct Issue {
    int domain = 0, code = 0, line = 0, column = 0;
    bool warning = false;
    const xmlNode *node = nullptr;
    std::string message, name;  // name: what it is about, such as an entity's (libxml2's str1)
};

void collect(void *list, XmlErrorArg e) {
    auto *out = static_cast<std::vector<Issue> *>(list);
    if (!e || out->size() >= kMaxIssues) return;
    Issue is;
    is.domain = e->domain;
    is.code = e->code;
    is.line = e->line;
    is.column = e->int2;
    is.warning = e->level == XML_ERR_WARNING;
    is.node = static_cast<const xmlNode *>(e->node);
    is.message = e->message ? e->message : "";
    is.name = e->str1 ? e->str1 : "";
    while (!is.message.empty() && isSpace(is.message.back())) is.message.pop_back();
    out->push_back(std::move(is));
}

// The parser passes its handler the parser context, which keeps our list in _private.
void collectParse(void *ctxt, XmlErrorArg e) { collect(static_cast<xmlParserCtxtPtr>(ctxt)->_private, e); }

// ── The built-in schemas, compiled once each ────────────────────────────────

struct Compiled {
    bool done = false;
    xmlSchemaPtr schema = nullptr;  // kept for the life of the process
    std::string problem;
};

Compiled &compiled(size_t index) {
    static std::mutex mutex;
    static std::vector<Compiled> cache = [] {
        size_t n = 0;
        adxSchemas(&n);
        return std::vector<Compiled>(n);
    }();
    std::lock_guard<std::mutex> lock(mutex);
    Compiled &c = cache[index];
    if (!c.done) {
        c.done = true;
        size_t n = 0;
        const AdxSchema &s = adxSchemas(&n)[index];
        std::vector<Issue> issues;
        if (xmlSchemaParserCtxtPtr pc = xmlSchemaNewMemParserCtxt(s.text, (int)s.size)) {
            xmlSchemaSetParserStructuredErrors(pc, collect, &issues);
            c.schema = xmlSchemaParse(pc);
            xmlSchemaFreeParserCtxt(pc);
        }
        if (!c.schema) c.problem = issues.empty() ? std::string("libxml2 could not compile it") : issues.front().message;
    }
    return c;
}

size_t schemaIndex(std::string_view version, bool generic) {
    size_t n = 0;
    const AdxSchema *s = adxSchemas(&n);
    for (size_t i = 0; i < n; ++i)
        if (version == s[i].version && s[i].generic == generic) return i;
    return npos;
}

void initLibxml() {
    static std::once_flag once;
    std::call_once(once, [] { xmlInitParser(); });
}

// "3.1.8" as numbers; false unless it is X.Y.Z.
bool versionNumbers(std::string_view v, int out[3]) {
    for (int i = 0; i < 3; ++i) {
        size_t j = 0;
        int n = 0;
        while (j < v.size() && j < 4 && v[j] >= '0' && v[j] <= '9') n = n * 10 + (v[j++] - '0');
        if (j == 0) return false;
        out[i] = n;
        v.remove_prefix(j);
        if (i < 2) {
            if (v.empty() || v.front() != '.') return false;
            v.remove_prefix(1);
        }
    }
    return v.empty();
}

// ── Elements as written ─────────────────────────────────────────────────────

// Where an element is in the text: libxml2 gives only line numbers.
struct RawElement {
    size_t b = 0;               // '<'
    size_t nameB = 0, nameE = 0;
    size_t startE = 0;          // after the start tag's '>'
    size_t endB = 0, endE = 0;  // the end tag; both startE for an empty-element tag
};

// The start tags of a well-formed document in document order, which is the order
// libxml2 builds its elements in. *doctype: where a <!DOCTYPE is, if there is one.
bool scanElements(std::string_view t, std::vector<RawElement> &out, std::pair<size_t, size_t> *doctype) {
    std::vector<size_t> open;
    size_t i = 0, n = t.size();
    auto skipTo = [&](size_t from, std::string_view end) {
        size_t e = t.find(end, from);
        return e == npos ? npos : e + end.size();
    };
    while ((i = t.find('<', i)) != npos) {
        std::string_view rest = t.substr(i);
        if (rest.compare(0, 4, "<!--") == 0) {
            i = skipTo(i + 4, "-->");
        } else if (rest.compare(0, 9, "<![CDATA[") == 0) {
            i = skipTo(i + 9, "]]>");
        } else if (rest.compare(0, 2, "<?") == 0) {
            i = skipTo(i + 2, "?>");
        } else if (rest.compare(0, 2, "<!") == 0) {  // <!DOCTYPE, with any internal subset
            int depth = 0;
            char quote = 0;
            size_t j = i + 2;
            for (; j < n; ++j) {
                char c = t[j];
                if (quote) {
                    if (c == quote) quote = 0;
                } else if (c == '"' || c == '\'') {
                    quote = c;
                } else if (c == '[') {
                    ++depth;
                } else if (c == ']') {
                    --depth;
                } else if (c == '>' && depth <= 0) {
                    break;
                }
            }
            if (doctype->first == npos) *doctype = {i, j < n ? j + 1 : n};
            i = j < n ? j + 1 : npos;
        } else if (rest.compare(0, 2, "</") == 0) {
            size_t gt = t.find('>', i);
            if (gt == npos || open.empty()) return false;
            RawElement &e = out[open.back()];
            open.pop_back();
            e.endB = i;
            e.endE = gt + 1;
            i = gt + 1;
        } else {
            RawElement e;
            e.b = i;
            size_t j = i + 1;
            e.nameB = j;
            while (j < n && !isSpace(t[j]) && t[j] != '/' && t[j] != '>') ++j;
            e.nameE = j;
            char quote = 0;
            for (; j < n; ++j) {
                char c = t[j];
                if (quote) {
                    if (c == quote) quote = 0;
                } else if (c == '"' || c == '\'') {
                    quote = c;
                } else if (c == '>') {
                    break;
                }
            }
            if (j >= n) return false;
            e.startE = e.endB = e.endE = j + 1;
            out.push_back(e);
            if (t[j - 1] != '/') open.push_back(out.size() - 1);
            i = j + 1;
        }
        if (i == npos) return false;
    }
    return open.empty();
}

// The name="value" of attribute `name` in an element's start tag, or {npos, npos}.
std::pair<size_t, size_t> attributeRange(std::string_view t, const RawElement &e, std::string_view name) {
    size_t j = e.nameE, end = e.startE;
    while (j < end) {
        while (j < end && (isSpace(t[j]) || t[j] == '/' || t[j] == '>')) ++j;
        size_t nb = j;
        while (j < end && !isSpace(t[j]) && t[j] != '=' && t[j] != '>' && t[j] != '/') ++j;
        size_t ne = j;
        while (j < end && isSpace(t[j])) ++j;
        if (j < end && t[j] == '=') {
            ++j;
            while (j < end && isSpace(t[j])) ++j;
            if (j < end && (t[j] == '"' || t[j] == '\'')) {
                size_t close = t.find(t[j], j + 1);
                j = close == npos || close >= end ? end : close + 1;
            }
        }
        if (ne > nb && t.substr(nb, ne - nb) == name) return {nb, j};
        if (ne == nb) ++j;
    }
    return {npos, npos};
}

// ── The document ────────────────────────────────────────────────────────────

bool isElement(const xmlNode *n, std::string_view name) {
    return n && n->type == XML_ELEMENT_NODE && equalsNoCase(str(n->name), name);
}

const xmlNode *child(const xmlNode *n, std::string_view name) {
    for (const xmlNode *c = n ? n->children : nullptr; c; c = c->next)
        if (isElement(c, name)) return c;
    return nullptr;
}

std::string attribute(const xmlNode *n, const char *name, bool *present = nullptr) {
    xmlChar *v = xmlGetNoNsProp(n, (const xmlChar *)name);
    if (present) *present = v != nullptr;
    std::string out = v ? (const char *)v : "";
    xmlFree(v);
    return out;
}

// An element's data: its own text and CDATA, never an entity's expansion (an
// entity can be made to expand to gigabytes, and ADX does not allow them anyway).
std::string textOf(const xmlNode *n) {
    std::string out;
    for (const xmlNode *c = n->children; c; c = c->next)
        if ((c->type == XML_TEXT_NODE || c->type == XML_CDATA_SECTION_NODE) && c->content) out += (const char *)c->content;
    return out;
}

// A field: a child of HEADER or RECORD.
bool isField(const xmlNode *n) {
    return n && n->type == XML_ELEMENT_NODE && (isElement(n->parent, "RECORD") || isElement(n->parent, "HEADER"));
}

// §IV.B.1: namespaces are ignored, so an ADX file in one validates like one without.
void dropNamespaces(xmlNodePtr n, bool definitions) {
    for (; n; n = n->next) {
        if (n->type != XML_ELEMENT_NODE) continue;
        if (definitions) {
            xmlFreeNsList(n->nsDef);
            n->nsDef = nullptr;
        } else {
            n->ns = nullptr;
            for (xmlAttrPtr a = n->properties; a;) {
                xmlAttrPtr next = a->next;
                if (a->ns) xmlRemoveProp(a);
                a = next;
            }
        }
        dropNamespaces(n->children, definitions);
    }
}

// An APP_ name part ADI can carry (§IV.A.4: no comma, colon, angle or curly bracket, no trailing space).
bool adiNamePart(std::string_view s) {
    return !s.empty() && s.find_first_of(",:<>{}") == npos && s.back() != ' ';
}

// The schema check's codes, as against ADIF Lint's own.
// The schema check's codes (xml, adx-..., schema...), as against ADIF Lint's own rules.
bool schemaCode(const std::string &code) { return code == "xml" || code.compare(0, 4, "adx-") == 0 || code.compare(0, 6, "schema") == 0; }

// lint()'s findings that are about ADI's own syntax, which ADX does not have.
bool adiOnly(const std::string &code) {
    return code == "length" || code == "intl-adi" || code == "line-break" || code == "no-records" || code == "bom" || code == "no-eor" ||
           code == "userdef-type";  // the schemas require TYPE on a header's USERDEF
}

// ── libxml2's schema messages, made readable ────────────────────────────────

// "'{value}' is not accepted by the pattern '{pattern}'": what the common patterns say.
std::string patternHint(std::string_view pattern) {
    if (pattern == "[ -~]*" || pattern == "[ -~]+") return tr("only ASCII characters 32 to 126");
    if (pattern == "([\\r\\n -~])*") return tr("only ASCII characters 32 to 126 and line breaks");
    if (pattern == "[^\\r\\n]*") return tr("no line breaks");
    return "";
}

// Text between the first `open` and the last `close`, or empty.
std::string_view between(std::string_view s, std::string_view open, std::string_view close) {
    size_t b = s.find(open);
    if (b == npos) return {};
    b += open.size();
    size_t e = s.rfind(close);
    return e == npos || e < b ? std::string_view() : s.substr(b, e - b);
}

// "Expected is one of ( A, B )." for a short list, else nothing: RECORD's runs to 180 names.
std::string expected(std::string_view m) {
    std::string_view list = trimmed(between(m, "Expected is one of (", ")"));
    if (list.empty()) list = trimmed(between(m, "Expected is (", ")"));
    if (list.empty() || std::count(list.begin(), list.end(), ',') > 5) return "";
    return " " + trf("Expected: {names}.", {{"names", std::string(list)}});
}

std::string explain(const Issue &is, std::string_view element, std::string_view attr) {
    std::string_view m = is.message;
    // "Element 'X': ..." or "Element 'X', attribute 'Y': ..."
    if (m.compare(0, 9, "Element '") == 0) {
        size_t colon = m.find("': ");
        if (colon != npos) m.remove_prefix(colon + 3);
    }
    std::string what = attr.empty() ? std::string(element) : std::string(element) + " " + std::string(attr);
    static const std::string_view kByPattern = "' is not accepted by the pattern '";
    std::string_view value = between(m, "The value '", kByPattern);
    bool emptyValue = m.find("The value '' ") != npos || m.compare(0, 3, "'' ") == 0;
    if (emptyValue && (m.find("[facet ") != npos || m.find(" is not a valid value of the ") != npos))
        return trf("{what} is empty, which its type does not allow.", {{"what", what}});
    if (m.find("[facet 'pattern']") != npos && m.find(kByPattern) != npos) {
        size_t p = m.rfind(kByPattern) + kByPattern.size();
        std::string_view pattern = m.substr(p, m.size() >= p + 2 ? m.size() - p - 2 : 0);  // without the closing "'."
        std::string hint = patternHint(pattern);
        return hint.empty() ? trf("{what} '{value}' is not allowed.", {{"what", what}, {"value", std::string(value)}})
                            : trf("{what} '{value}' is not allowed: {rule}.", {{"what", what}, {"value", std::string(value)}, {"rule", hint}});
    }
    if (m.find("[facet 'minInclusive']") != npos || m.find("[facet 'maxInclusive']") != npos) {
        value = between(m, "The value '", "' is ");
        std::string limit(between(m, "allowed ('", "')"));
        return m.find("minInclusive") != npos
                   ? trf("{what} {value} is less than {limit}, the least it may be.", {{"what", what}, {"value", std::string(value)}, {"limit", limit}})
                   : trf("{what} {value} is greater than {limit}, the most it may be.", {{"what", what}, {"value", std::string(value)}, {"limit", limit}});
    }
    if (m.find("[facet 'enumeration']") != npos) {
        value = between(m, "The value '", "' is not an element of the set");
        return trf("{what} '{value}' is not one of its values.", {{"what", what}, {"value", std::string(value)}});
    }
    if (m.find("' is not a valid value of the ") != npos) {
        value = between(m, "'", "' is not a valid value of the ");
        std::string_view type = between(m, "atomic type '", "'.");
        if (type.compare(0, 3, "xs:") == 0) type.remove_prefix(3);
        return type.empty() ? trf("{what} '{value}' is not valid here.", {{"what", what}, {"value", std::string(value)}})
                            : trf("{what} '{value}' is not a valid {type}.", {{"what", what}, {"value", std::string(value)}, {"type", std::string(type)}});
    }
    if (m.find("This element is not expected") != npos) {
        std::string out = trf("{element} is not allowed here.", {{"element", std::string(element)}}) + expected(m);
        if (hasLower(element)) out += " " + tr("Element and attribute names are upper case in ADX (§IV.B).");
        return out;
    }
    if (m.find("Missing child element") != npos)
        return trf("{element} is missing an element.", {{"element", std::string(element)}}) + expected(m);
    if (m.find("Element content is not allowed, because the type definition is simple") != npos)
        return trf("{element} may hold text but not elements.", {{"element", std::string(element)}});
    if (m.find("Character content other than whitespace is not allowed") != npos)
        return trf("{element} may hold elements but not text.", {{"element", std::string(element)}});
    if (m.find("is not allowed") != npos && m.find("The attribute '") == 0) {
        std::string out = trf("{element} may not have a {attribute} attribute.", {{"element", std::string(element)}, {"attribute", std::string(attr)}});
        if (hasLower(attr)) out += " " + tr("Element and attribute names are upper case in ADX (§IV.B).");
        return out;
    }
    if (m.find("is required but missing") != npos) {
        std::string_view need = between(m, "The attribute '", "' is required");
        return trf("{element} needs a {attribute} attribute.", {{"element", std::string(element)}, {"attribute", std::string(need)}});
    }
    if (m.find("No matching global declaration available for the validation root") != npos)
        return trf("The root element must be ADX (§IV.B), not {element}.", {{"element", std::string(element)}});
    // Anything else, in libxml2's words, without a long pattern or name list.
    std::string out = what + ": " + std::string(m);
    size_t p = out.find(" by the pattern '");
    if (p != npos && out.size() - p > 80) out = out.substr(0, p) + ".";
    p = out.find(" Expected is one of (");
    if (p != npos && std::count(out.begin() + (long)p, out.end(), ',') > 5) out = out.substr(0, p);
    return out;
}

// ── The check ───────────────────────────────────────────────────────────────

struct DocFree {
    void operator()(xmlDocPtr d) const { xmlFreeDoc(d); }
};

class Checker {
public:
    Checker(std::string_view text, const LintOptions &options) : t_(text), opt_(options) {}
    LintResult run();

private:
    using Range = std::pair<size_t, size_t>;

    void add(std::vector<Diagnostic> &to, Severity s, Range at, std::string message, const char *code, std::string field = {},
             bool structural = false);
    void addSchema(Severity s, Range at, std::string message, const char *code, std::string field = {}) {
        add(schema_, s, at, std::move(message), code, std::move(field));
    }

    // Positions.
    bool index(xmlDocPtr doc);
    const RawElement *raw(const xmlNode *n) const;
    size_t lineStart(long line);
    Range lineRange(long line);
    Range at(int line, int column, std::string_view entity = {});
    Range nameRange(const xmlNode *n);
    Range startTag(const xmlNode *n);
    Range content(const xmlNode *n);
    Range whole(const xmlNode *n);
    Range rootRange();
    std::string fieldOf(const xmlNode *n);

    void parseIssue(const Issue &is);
    void rules(xmlDocPtr doc);
    void validate(xmlDocPtr doc, const char *version);
    std::vector<Issue> runSchema(xmlDocPtr doc, size_t index, bool *ok);
    void schemaIssue(const Issue &is, const AdxSchema &s, const AdxSchema *generic);
    void settleExportOnly();
    void restate(const xmlNode *header, const xmlNode *records);
    LintResult finish();

    std::string_view t_;
    const LintOptions &opt_;
    LintResult r_;
    std::vector<Diagnostic> schema_, own_;  // the two checks' findings
    std::vector<RawElement> raw_;
    std::unordered_map<const xmlNode *, size_t> index_;
    const xmlNode *root_ = nullptr;
    Range doctype_{npos, npos};
    std::vector<size_t> lines_;
    std::set<const xmlNode *> schemaErrorAt_;  // elements the generic schema rejected
    struct ExportOnly {
        Range where;
        std::string problem, field;
        const xmlNode *node;
        const AdxSchema *schema, *generic;
    };
    std::vector<ExportOnly> exportOnly_;  // what only the export schema rejected, until lint() has run
    size_t version_ = 0;                  // the ADIF version checked, an index into specVersions()
    std::map<std::string, char> userTypes_;    // USERDEF names (upper case) and their TYPE
};

void Checker::add(std::vector<Diagnostic> &to, Severity s, Range at, std::string message, const char *code, std::string field,
                  bool structural) {
    if (t_.empty()) return;  // nothing to point at, as lint() has nothing to say about empty text
    Diagnostic d;
    d.start = std::min(at.first, t_.size() - 1);
    d.end = std::max(std::min(at.second, t_.size()), d.start + 1);
    d.severity = s;
    d.structural = structural;
    d.message = std::move(message);
    d.code = code;
    d.field = std::move(field);
    to.push_back(std::move(d));
}

// Pair libxml2's elements with the text's start tags, in document order.
bool Checker::index(xmlDocPtr doc) {
    if (!scanElements(t_, raw_, &doctype_)) return false;
    std::vector<const xmlNode *> nodes;
    // Depth first, as written; entities' content is not the document's own.
    for (const xmlNode *n = xmlDocGetRootElement(doc); n;) {
        nodes.push_back(n);
        const xmlNode *next = nullptr;
        for (const xmlNode *c = n->children; c && !next; c = c->next)
            if (c->type == XML_ELEMENT_NODE) next = c;
        for (const xmlNode *up = n; !next && up; up = up->parent) {
            for (const xmlNode *s = up->next; s && !next; s = s->next)
                if (s->type == XML_ELEMENT_NODE) next = s;
            if (up->parent && up->parent->type != XML_ELEMENT_NODE) break;
        }
        n = next;
    }
    if (nodes.size() != raw_.size()) return false;
    for (size_t i = 0; i < nodes.size(); ++i) {
        const xmlNode *n = nodes[i];
        std::string qname = n->ns && n->ns->prefix ? std::string(str(n->ns->prefix)) + ":" + std::string(str(n->name)) : std::string(str(n->name));
        if (t_.substr(raw_[i].nameB, raw_[i].nameE - raw_[i].nameB) != qname) return false;
        index_[n] = i;
    }
    return true;
}

const RawElement *Checker::raw(const xmlNode *n) const {
    if (n && n->type == XML_ATTRIBUTE_NODE) n = n->parent;
    auto it = index_.find(n);
    return it == index_.end() ? nullptr : &raw_[it->second];
}

size_t Checker::lineStart(long line) {
    if (lines_.empty()) {
        lines_.push_back(0);
        for (size_t i = 0; i < t_.size(); ++i)
            if (t_[i] == '\n') lines_.push_back(i + 1);
    }
    if (line < 1) return 0;
    return (size_t)line <= lines_.size() ? lines_[(size_t)line - 1] : t_.size();
}

Checker::Range Checker::lineRange(long line) {
    size_t b = lineStart(line), e = t_.find('\n', b);
    if (e == npos) e = t_.size();
    while (e > b && (t_[e - 1] == '\r' || t_[e - 1] == '\n')) --e;
    return {b, e};
}

// libxml2's line and column (in characters) for a parse error, which is where it
// had read to: the tag ending there, or `entity`'s reference before it, or to the next '>'.
Checker::Range Checker::at(int line, int column, std::string_view entity) {
    Range l = lineRange(line);
    size_t p = l.first;
    for (int c = 1; c < column && p < l.second; ++c) {
        ++p;
        while (p < l.second && ((unsigned char)t_[p] & 0xC0) == 0x80) ++p;
    }
    if (!entity.empty()) {
        size_t r = t_.rfind("&" + std::string(entity) + ";", p);
        if (r != npos && r >= l.first) return {r, r + entity.size() + 2};
    }
    if (p > l.first && t_[p - 1] == '>') {
        size_t lt = t_.rfind('<', p - 1);
        if (lt != npos && lt >= l.first) return {lt, p};
    }
    size_t gt = t_.find('>', p);
    size_t e = gt != npos && gt < l.second ? gt + 1 : l.second;
    return {p, e > p ? e : p + 1};
}

Checker::Range Checker::nameRange(const xmlNode *n) {
    if (const RawElement *e = raw(n)) return {e->nameB, e->nameE};
    return n ? lineRange(xmlGetLineNo(n)) : rootRange();
}

Checker::Range Checker::startTag(const xmlNode *n) {
    if (const RawElement *e = raw(n)) return {e->b, e->startE};
    return nameRange(n);
}

Checker::Range Checker::content(const xmlNode *n) {
    const RawElement *e = raw(n);
    if (e && e->endB > e->startE) return {e->startE, e->endB};
    return startTag(n);
}

Checker::Range Checker::whole(const xmlNode *n) {
    if (const RawElement *e = raw(n)) return {e->b, std::max(e->endE, e->startE)};
    return nameRange(n);
}

Checker::Range Checker::rootRange() {
    if (root_) return nameRange(root_);
    return {0, std::min<size_t>(t_.size(), 1)};
}

// The field a node is about, as lint() names fields.
std::string Checker::fieldOf(const xmlNode *n) {
    if (n && n->type == XML_ATTRIBUTE_NODE) n = n->parent;
    if (!isField(n)) return "";
    if (isElement(n, "APP")) return upperAscii("APP_" + attribute(n, "PROGRAMID") + "_" + attribute(n, "FIELDNAME"));
    if (isElement(n, "USERDEF")) return upperAscii(isElement(n->parent, "HEADER") ? textOf(n) : attribute(n, "FIELDNAME"));
    return upperAscii(str(n->name));
}

void Checker::parseIssue(const Issue &is) {
    if (is.domain == XML_FROM_NAMESPACE) return;  // §IV.B.1: namespaces are ignored
    bool entity = is.code == XML_ERR_UNDECLARED_ENTITY || is.code == XML_WAR_UNDECLARED_ENTITY;
    // Not is.node: a document that is not well formed is freed by now.
    Range where = at(is.line, is.column, entity ? std::string_view(is.name) : std::string_view());
    if (is.code == XML_ERR_ENTITY_LOOP) {
        // Its line is in an entity's text, not the file's: point at the declarations.
        std::vector<RawElement> ignored;
        Range doctype{npos, npos};
        scanElements(t_, ignored, &doctype);
        if (doctype.first != npos) where = doctype;
    }
    std::string problem = is.message;
    if (!problem.empty() && !strchr(".!?", problem.back())) problem += '.';
    std::string message = trf("Not well-formed XML: {problem}", {{"problem", problem}});
    if (entity)
        message += " " + tr("ADX allows only the entities XML predefines: &amp; &lt; &gt; &apos; &quot; (§IV.B.1).");
    else if (is.message.find("UTF-8") != npos)
        message += " " + tr("ADX files are UTF-8 (§IV.B).");
    add(schema_, is.warning ? Severity::Warning : Severity::Error, where, std::move(message), "xml", "", !is.warning);
}

// §IV.B and §IV.B.1: what the schemas cannot say.
void Checker::rules(xmlDocPtr doc) {
    std::vector<xmlNodePtr> refs;
    // UTF-8: libxml2 reads the declared encoding, so look at the declaration itself.
    size_t i = t_.compare(0, 3, "\xEF\xBB\xBF") == 0 ? 3 : 0;
    if (t_.compare(i, 5, "<?xml") == 0) {
        size_t end = t_.find("?>", i);
        RawElement decl;
        decl.nameB = i;
        decl.nameE = i + 5;
        decl.startE = end == npos ? t_.size() : end + 2;
        Range enc = attributeRange(t_, decl, "encoding");
        if (enc.first != npos) {
            std::string_view v = t_.substr(enc.first, enc.second - enc.first);
            v = trimmed(v.substr(std::min(v.size(), v.find('=') + 1)));
            if (v.size() >= 2 && (v.front() == '"' || v.front() == '\'')) v = v.substr(1, v.size() - 2);
            if (!equalsNoCase(v, "UTF-8") && !equalsNoCase(v, "UTF8"))
                addSchema(Severity::Error, enc, trf("ADX files are UTF-8 (§IV.B); this one declares {encoding}.", {{"encoding", std::string(v)}}),
                          "adx-encoding");
        }
    }
    if (doc->intSubset || doc->extSubset) {
        Range where = doctype_.first == npos ? rootRange() : doctype_;
        addSchema(Severity::Error, where, tr("ADX files may not have a document type declaration, <!DOCTYPE ...> (§IV.B.1)."), "adx-doctype");
    }
    // Entities and CDATA, anywhere in the document.
    std::vector<const xmlNode *> todo{xmlDocGetRootElement(doc)};
    while (!todo.empty()) {
        const xmlNode *n = todo.back();
        todo.pop_back();
        for (const xmlNode *c = n->children; c; c = c->next) {
            if (c->type == XML_ELEMENT_NODE) {
                todo.push_back(c);
            } else if (c->type == XML_ENTITY_REF_NODE) {
                Range where = content(n);
                std::string ref = "&" + std::string(str(c->name)) + ";";
                size_t p = t_.substr(where.first, where.second - where.first).find(ref);
                if (p != npos) where = {where.first + p, where.first + p + ref.size()};
                addSchema(Severity::Error, where,
                          trf("{entity} is not allowed: ADX allows only the entities XML predefines, such as &amp; (§IV.B.1).", {{"entity", ref}}),
                          "adx-entity", fieldOf(n));
                refs.push_back(const_cast<xmlNodePtr>(c));
            } else if (c->type == XML_CDATA_SECTION_NODE && isField(n)) {
                Range where = content(n);
                size_t p = t_.substr(where.first, where.second - where.first).find("<![CDATA[");
                if (p != npos) where = {where.first + p, where.first + p + 9};
                addSchema(Severity::Error, where,
                          trf("{field} uses a CDATA section, which ADX fields may not (§IV.B.1). Escape the text instead, e.g. &lt; for <.",
                              {{"field", fieldOf(n)}}),
                          "adx-cdata", fieldOf(n));
            }
        }
    }
    // libxml2 cannot validate a tree with entity references, and expanding them is
    // how an entity bomb goes off; validate the reference as written instead.
    for (xmlNodePtr ref : refs) {
        std::string literal = "&" + std::string(str(ref->name)) + ";";
        xmlNodePtr text = xmlNewDocText(doc, (const xmlChar *)literal.c_str());
        if (!text) continue;
        xmlReplaceNode(ref, text);
        xmlFreeNode(ref);
    }
}

std::vector<Issue> Checker::runSchema(xmlDocPtr doc, size_t index, bool *ok) {
    std::vector<Issue> issues;
    size_t n = 0;
    const AdxSchema &s = adxSchemas(&n)[index];
    Compiled &c = compiled(index);
    *ok = c.schema != nullptr;
    if (!c.schema) {
        addSchema(Severity::Error, rootRange(), trf("ADIF Lint could not load the schema {schema}: {problem}", {{"schema", s.file}, {"problem", c.problem}}),
                  "adx-internal");
        return issues;
    }
    xmlSchemaValidCtxtPtr v = xmlSchemaNewValidCtxt(c.schema);
    if (!v) {
        *ok = false;
        return issues;
    }
    xmlSchemaSetValidStructuredErrors(v, collect, &issues);
    int rc = xmlSchemaValidateDoc(v, doc);
    xmlSchemaFreeValidCtxt(v);
    if (rc < 0) {
        *ok = false;
        addSchema(Severity::Error, rootRange(), trf("The schema {schema} could not be applied (libxml2 error {code}).", {{"schema", s.file}, {"code", std::to_string(rc)}}),
                  "adx-internal");
    }
    return issues;
}

// `generic` is null for the generic schema's own findings, which are errors; the
// export schema's are warnings, and only where the generic one found nothing.
void Checker::schemaIssue(const Issue &is, const AdxSchema &s, const AdxSchema *generic) {
    const xmlNode *node = is.node;
    std::string attr;
    if (node && node->type == XML_ATTRIBUTE_NODE) {
        attr = std::string(str(node->name));
        node = node->parent;
    } else if (is.message.compare(0, 9, "Element '") == 0) {
        attr = std::string(between(is.message, "', attribute '", "': "));
    }
    if (generic && schemaErrorAt_.count(node)) return;
    std::string element = node ? std::string(str(node->name)) : std::string("ADX");
    if (isElement(node, "APP") || isElement(node, "USERDEF")) {
        std::string f = fieldOf(node);
        if (!f.empty() && f != "APP__") element += " " + f;
    }
    // Where: the value, the attribute, or the element's name.
    Range where;
    bool valueProblem = is.code >= XML_SCHEMAV_CVC_DATATYPE_VALID_1_2_1 && is.code <= XML_SCHEMAV_CVC_ENUMERATION_VALID;
    if (!attr.empty() && raw(node)) {
        where = attributeRange(t_, *raw(node), attr);
        if (where.first == npos) where = startTag(node);
    } else {
        where = valueProblem ? content(node) : node ? nameRange(node) : rootRange();
    }
    std::string problem = explain(is, element, attr);
    // §IV.B.3's own example has <USERDEF FIELDNAME="SweaterSize"> in a record, as field
    // names are case-insensitive (§III.C), but the schemas' pattern for it has no lower case.
    if (isElement(node, "USERDEF") && isElement(node->parent, "RECORD") && attr == "FIELDNAME" && is.message.find("[facet 'pattern']") != npos) {
        std::string v = attribute(node, "FIELDNAME"), up = upperAscii(v);
        if (hasLower(v) && up.size() >= 2 && up.find_first_of("<>,:{}") == npos && up.front() != ' ' && up.back() != ' ') {
            if (generic) return;
            addSchema(Severity::Warning, where,
                      trf("{schema} wants a record's USERDEF FIELDNAME in upper case, {upper}, though field names are case-insensitive "
                          "and the specification's own example has SweaterSize (§IV.B.3). Write it in upper case for programs that validate.",
                          {{"schema", s.file}, {"upper", up}}),
                      "schema-strict", fieldOf(node));
            return;
        }
    }
    // §IV.B.3: a record's USERDEF may carry a TYPE, which is ignored; the schemas reject it.
    if (isElement(node, "USERDEF") && isElement(node->parent, "RECORD") && attr == "TYPE" && is.message.find("is not allowed") != npos) {
        if (generic) return;
        addSchema(Severity::Warning, where,
                  trf("{schema} rejects TYPE on a record's USERDEF, though the specification says it is ignored there (§IV.B.3). "
                      "Leave it out for programs that validate.",
                      {{"schema", s.file}}),
                  "schema-strict", fieldOf(node));
        return;
    }
    if (!generic) {
        schemaErrorAt_.insert(node);
        addSchema(Severity::Error, where, trf("Schema: {problem} ({schema})", {{"problem", problem}, {"schema", s.file}}), "schema", fieldOf(node));
    } else {
        exportOnly_.push_back({where, std::move(problem), fieldOf(node), node, &s, generic});
    }
}

// What only the export schema rejects is not ADIF {version} either, but the generic
// schema is looser for two reasons: it allows what the version deprecates, and it
// leaves out what differs between versions (ranges, types that changed). Only the
// first is fine to read, and the spec tables, through lint()'s findings, say which.
void Checker::settleExportOnly() {
    for (ExportOnly &x : exportOnly_) {
        Range w = whole(x.node);
        // A MODE that is now a SUBMODE is import-only too (a warning; an error when it never was a MODE).
        bool deprecated = std::any_of(own_.begin(), own_.end(), [&](const Diagnostic &d) {
            return d.severity == Severity::Warning && (d.code == "import-only" || d.code == "normalize" || d.code == "mode-is-submode") &&
                   d.start >= w.first && d.start < w.second;
        });
        if (deprecated)
            addSchema(Severity::Warning, x.where,
                      trf("Import only in ADIF {version}: {problem} ({schema}, for writing, rejects it; {generic}, for reading, accepts it.)",
                          {{"version", x.schema->version}, {"problem", x.problem}, {"schema", x.schema->file}, {"generic", x.generic->file}}),
                      "schema-export", x.field);
        else
            addSchema(Severity::Error, x.where, trf("Schema: {problem} ({schema})", {{"problem", x.problem}, {"schema", x.schema->file}}), "schema",
                      x.field);
    }
    exportOnly_.clear();
}

void Checker::validate(xmlDocPtr doc, const char *version) {
    size_t gi = schemaIndex(version, true), ei = schemaIndex(version, false);
    if (gi == npos || ei == npos) return;
    size_t n = 0;
    const AdxSchema *s = adxSchemas(&n);
    bool ok = false;
    for (const Issue &is : runSchema(doc, gi, &ok)) schemaIssue(is, s[gi], nullptr);
    if (!ok) return;
    for (const Issue &is : runSchema(doc, ei, &ok)) schemaIssue(is, s[ei], &s[gi]);
}

// Each record as ADI, for lint(); its findings land on the elements they are about.
void Checker::restate(const xmlNode *header, const xmlNode *records) {
    enum Kind : unsigned char { Field, Tag, Eoh, Eor };
    struct Segment {
        size_t b, value;  // in the ADI text: the specifier's '<', and its data
        const xmlNode *node;
        Kind kind;
    };
    std::string adi;
    std::vector<Segment> segs;
    auto emit = [&](const std::string &name, char type, std::string_view value, const xmlNode *n, Kind kind) {
        size_t b = adi.size();
        adi += '<' + name + ':' + std::to_string(value.size());
        if (type) (adi += ':') += type;
        adi += '>';
        segs.push_back({b, adi.size(), n, kind});
        adi += value;
        adi += '\n';
    };
    auto indicator = [](const std::string &type) { return type.size() == 1 && isalpha((unsigned char)type[0]) ? type[0] : '\0'; };
    if (header) {
        adi += "ADX\n";  // header text, so that lint() sees a header
        size_t synthetic = 0;
        for (const xmlNode *c = header->children; c; c = c->next) {
            if (c->type != XML_ELEMENT_NODE) continue;
            if (!isElement(c, "USERDEF")) {
                emit(std::string(str(c->name)), 0, textOf(c), c, Field);
                continue;
            }
            bool hasEnum = false, hasRange = false;
            std::string id = attribute(c, "FIELDID"), type = attribute(c, "TYPE"), values = attribute(c, "ENUM", &hasEnum),
                        range = attribute(c, "RANGE", &hasRange), name = textOf(c);
            Range rangeAt = raw(c) ? attributeRange(t_, *raw(c), "RANGE") : Range{npos, npos};
            if (hasEnum && hasRange)
                add(own_, Severity::Error, rangeAt.first != npos ? rangeAt : startTag(c),
                    trf("USERDEF {field} has both ENUM and RANGE; it may have one or the other (§IV.B.3).", {{"field", name}}), "userdef-enum-range", upperAscii(name));
            // An unusable FIELDID is the schema's to report; restate the field anyway.
            if (id.empty() || id.size() > 9 || id.find_first_not_of("0123456789") != npos) id = std::to_string(900000000 + ++synthetic);
            userTypes_[upperAscii(trimmed(name))] = indicator(type) ? (char)toupper((unsigned char)indicator(type)) : '\0';
            std::string value = name + (hasEnum ? "," + values : hasRange ? "," + range : "");
            emit("USERDEF" + id, indicator(type), value, c, Field);
        }
        segs.push_back({adi.size(), adi.size(), header, Eoh});
        adi += "<EOH>\n";
    }
    for (const xmlNode *rec = records ? records->children : nullptr; rec; rec = rec->next) {
        if (!isElement(rec, "RECORD")) continue;
        ++r_.records;
        for (const xmlNode *c = rec->children; c; c = c->next) {
            if (c->type != XML_ELEMENT_NODE) continue;
            std::string value = textOf(c);
            char type = 0;
            std::string name;
            if (isElement(c, "APP")) {
                std::string program = attribute(c, "PROGRAMID"), field = attribute(c, "FIELDNAME");
                if (program.empty() || field.empty()) continue;  // the schema says which attribute is missing
                if (!adiNamePart(program) || !adiNamePart(field)) {
                    add(own_, Severity::Warning, startTag(c),
                        trf("APP_{program}_{field} cannot be written in ADI: application-defined field names may not contain a comma, "
                            "colon, < > { } or end with a space (§IV.A.4).",
                            {{"program", program}, {"field", field}}),
                        "app-name", fieldOf(c));
                    continue;
                }
                name = "APP_" + program + "_" + field;
                type = indicator(attribute(c, "TYPE"));
            } else if (isElement(c, "USERDEF")) {
                name = attribute(c, "FIELDNAME");
                if (name.empty() || !adiNamePart(name)) continue;  // the schema reports it
                auto it = userTypes_.find(upperAscii(name));
                if (it != userTypes_.end()) type = it->second;
            } else {
                name = std::string(str(c->name));
            }
            // lint() cannot look inside Intl types, as ADI cannot carry them; the one rule that is not about ADI.
            if ((type == 'I' || type == 'i') && value.find_first_of("\r\n") != npos)
                add(own_, Severity::Error, content(c),
                    trf("{field} is IntlString, which may not contain line breaks (§III.A); IntlMultilineString (G) may.", {{"field", fieldOf(c)}}),
                    "intl-line-break", fieldOf(c));
            emit(name, isElement(c, "USERDEF") ? 0 : type, value, c, isElement(c, "APP") || isElement(c, "USERDEF") ? Tag : Field);
        }
        segs.push_back({adi.size(), adi.size(), rec, Eor});
        adi += "<EOR>\n";
    }

    LintOptions o;
    o.lengthUnit = LengthUnit::Bytes;
    o.utf8 = true;
    o.maxDiagnostics = opt_.maxDiagnostics;
    o.today = opt_.today;
    o.specVersion = version_;  // the rules follow the version the schemas do
    LintResult lr = lint(adi, o);
    r_.truncated = lr.truncated;
    for (Diagnostic &d : lr.diagnostics) {
        if (adiOnly(d.code)) continue;
        auto it = std::upper_bound(segs.begin(), segs.end(), d.start, [](size_t p, const Segment &s) { return p < s.b; });
        Range where;
        const xmlNode *node = nullptr;
        if (it == segs.begin()) {
            where = header ? startTag(header) : rootRange();
        } else {
            const Segment &s = *(it - 1);
            node = s.node;
            if (s.kind == Eoh || s.kind == Eor) {
                const RawElement *e = raw(s.node);
                where = e && e->endE > e->endB && e->endB >= e->startE ? Range{e->endB, e->endE} : startTag(s.node);
            } else if (d.start >= s.value) {
                where = content(s.node);
            } else if (d.end > s.value) {
                where = whole(s.node);
            } else {
                // The tag: its type indicator is TYPE, a header USERDEF's number FIELDID.
                bool typed = d.code == "indicator";
                const RawElement *e = raw(s.node);
                Range a = !e ? Range{npos, npos}
                          : typed ? attributeRange(t_, *e, "TYPE")
                          : isElement(s.node, "USERDEF") && s.kind == Field ? attributeRange(t_, *e, "FIELDID") : Range{npos, npos};
                where = a.first != npos ? a : s.kind == Tag ? startTag(s.node) : nameRange(s.node);
            }
        }
        if (d.code == "userdef-id") {
            d.message = tr("FIELDID must be a positive integer (§IV.B.3).");
        } else if (d.code == "unknown-field") {
            d.message = isElement(node, "USERDEF")
                            ? trf("USERDEF {field} is not defined in the header (§IV.B.3).", {{"field", d.field}})
                            : trf("Unknown field {field}: not an ADIF {spec} field. Fields of your own are APP or USERDEF elements (§IV.B.2, §IV.B.3).",
                                  {{"field", d.field}, {"spec", specVersion()}});
        }
        if (d.code == "non-ascii") {
            // The schema rejects non-ASCII in its String types; the user fields it does not look at are lint()'s.
            if (schemaErrorAt_.count(node)) continue;
            d.severity = Severity::Error;
            d.message = trf("{field} has non-ASCII text, which only _INTL fields and the Intl types may carry (§III.A).", {{"field", d.field}});
        }
        d.start = where.first;
        d.end = std::max(where.second, where.first + 1);
        d.structural = false;
        d.fixes.clear();
        d.fixLabel.clear();
        d.dropsData = false;
        own_.push_back(std::move(d));
    }
}

LintResult Checker::run() {
    initLibxml();
    if (t_.size() > (size_t)INT_MAX) {
        add(schema_, Severity::Error, {0, 1}, tr("The file is too large to read as XML."), "adx-internal", "", true);
        return finish();
    }
    std::vector<Issue> issues;
    xmlParserCtxtPtr ctxt = xmlNewParserCtxt();
    if (!ctxt) return finish();
    ctxt->_private = &issues;
    ctxt->sax->serror = collectParse;
    // No network, no DTD loading, no entity substitution: §IV.B.1 allows none of them.
    std::unique_ptr<xmlDoc, DocFree> doc(xmlCtxtReadMemory(ctxt, t_.data(), (int)t_.size(), nullptr, nullptr, XML_PARSE_NONET | XML_PARSE_BIG_LINES));
    bool wellFormed = doc && ctxt->wellFormed;
    xmlFreeParserCtxt(ctxt);
    if (wellFormed) {
        root_ = xmlDocGetRootElement(doc.get());
        if (!index(doc.get())) {
            raw_.clear();
            index_.clear();
        }
    }
    for (const Issue &is : issues) {
        parseIssue(is);
        if (!wellFormed && !is.warning && is.domain != XML_FROM_NAMESPACE) break;  // what follows the first error mostly follows from it
    }
    if (!wellFormed || !root_) return finish();

    rules(doc.get());
    dropNamespaces(xmlDocGetRootElement(doc.get()), false);
    dropNamespaces(xmlDocGetRootElement(doc.get()), true);

    const xmlNode *adx = isElement(root_, "ADX") ? root_ : nullptr;
    const xmlNode *header = child(adx, "HEADER"), *records = child(adx, "RECORDS");
    r_.hasHeader = header != nullptr;
    const xmlNode *verNode = child(header, "ADIF_VER");
    std::string declared = verNode ? std::string(trimmed(textOf(verNode))) : std::string();
    r_.declaredVersion = declared;
    // One version for the rules and the schemas: the one asked for, or with fileVersion the file's own.
    version_ = opt_.specVersion != kNoPos ? opt_.specVersion : specVersionIndex();
    bool fromFile = false;
    if (opt_.fileVersion) {
        size_t v = findSpecVersion(declared);
        if (v != SIZE_MAX) version_ = v, fromFile = true;
    }
    size_t nv = 0;
    const SpecVersion *versions = specVersions(&nv);
    version_ = std::min(version_, nv - 1);
    const char *checked = versions[version_].name, *schemas = adxSchemaVersion(checked, checked);
    r_.checkedVersion = checked;
    r_.schemaVersion = schemas;
    Range verAt = verNode ? content(verNode) : header ? nameRange(header) : rootRange();
    int numbers[3];
    if (opt_.fileVersion && !fromFile && !(versionNumbers(declared, numbers) && compareNoCase(declared, versions[nv - 1].name) > 0))
        add(own_, Severity::Info, verAt,
            trf("The file declares no ADIF version this build knows, so these checks follow ADIF {spec}.", {{"spec", checked}}), "version-missing");
    if (std::string_view(schemas) != checked)
        addSchema(Severity::Info, verAt,
                  trf("ADIF {declared} has no ADX schemas of its own, so the ADIF {version} ones checked this file.", {{"declared", checked}, {"version", schemas}}),
                  "schema-version");
    validate(doc.get(), schemas);
    if (adx) restate(header, records);
    settleExportOnly();
    return finish();
}

LintResult Checker::finish() {
    std::vector<Diagnostic> &all = r_.diagnostics;
    all = std::move(schema_);
    all.insert(all.end(), std::make_move_iterator(own_.begin()), std::make_move_iterator(own_.end()));
    std::stable_sort(all.begin(), all.end(), [](const Diagnostic &a, const Diagnostic &b) { return a.start < b.start; });
    for (const Diagnostic &d : all) {
        bool mine = schemaCode(d.code);
        switch (d.severity) {
        case Severity::Error:
            ++r_.errors;
            r_.schemaErrors += mine;
            r_.structuralErrors += d.structural;
            break;
        case Severity::Warning:
            ++r_.warnings;
            r_.schemaWarnings += mine;
            break;
        case Severity::Info:
            ++r_.infos;
            r_.schemaInfos += mine;
            break;
        }
    }
    if (all.size() > opt_.maxDiagnostics) {
        all.resize(opt_.maxDiagnostics);
        r_.truncated = true;
    }
    return std::move(r_);
}

}  // namespace

bool isAdx(std::string_view t) {
    if (t.compare(0, 3, "\xEF\xBB\xBF") == 0) t.remove_prefix(3);
    for (;;) {
        while (!t.empty() && isSpace(t.front())) t.remove_prefix(1);
        if (t.compare(0, 4, "<!--") != 0) break;
        size_t e = t.find("-->");
        if (e == npos) return false;
        t.remove_prefix(e + 3);
    }
    if (t.compare(0, 5, "<?xml") == 0 || t.compare(0, 9, "<!DOCTYPE") == 0) return true;
    return t.size() >= 4 && equalsNoCase(t.substr(0, 4), "<ADX") && (t.size() == 4 || isSpace(t[4]) || t[4] == '>' || t[4] == '/');
}

const char *adxSchemaVersion(std::string_view declared, std::string_view fallback) {
    size_t n = 0;
    const AdxSchema *s = adxSchemas(&n);
    int want[3];
    if (!versionNumbers(trimmed(declared), want) && !versionNumbers(trimmed(fallback), want)) return s[n - 1].version;
    const char *best = s[0].version;
    for (size_t i = 0; i < n; ++i) {
        int v[3];
        if (versionNumbers(s[i].version, v) && std::lexicographical_compare(want, want + 3, v, v + 3) == false) best = s[i].version;
    }
    return best;
}

LintResult lintAdx(std::string_view text, const LintOptions &options) {
    Checker c(text, options);
    return c.run();
}

std::string adxSchemaProblem(const AdxSchema &schema) {
    initLibxml();
    size_t i = schemaIndex(schema.version, schema.generic);
    if (i == npos) return "not built in";
    return compiled(i).problem;
}

}  // namespace adif
