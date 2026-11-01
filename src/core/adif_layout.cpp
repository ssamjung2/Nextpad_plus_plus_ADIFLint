#include "adif_layout.h"

#include "adif_i18n.h"
#include "adif_json.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <set>

namespace adif::layout {
namespace {

bool same(double a, double b) { return std::fabs(a - b) < 1e-9; }

// Each stack of the tree, in order (left to right, top to bottom), with a visitor that may change it.
void eachStack(Node &n, const std::function<void(Node &)> &f) {
    if (n.kind == Node::Kind::Stack) return f(n);
    for (Node &c : n.children) eachStack(c, f);
}
void eachStack(const Node &n, const std::function<void(const Node &)> &f) {
    if (n.kind == Node::Kind::Stack) return f(n);
    for (const Node &c : n.children) eachStack(c, f);
}

Node *stackHolding(Node &n, std::string_view panel) {
    Node *found = nullptr;
    eachStack(n, [&](Node &s) {
        if (!found && std::find(s.panels.begin(), s.panels.end(), panel) != s.panels.end()) found = &s;
    });
    return found;
}

// The child indices down to the stack holding `panel`; false when none does.
bool pathTo(const Node &n, std::string_view panel, std::vector<size_t> &path) {
    if (n.kind == Node::Kind::Stack) return std::find(n.panels.begin(), n.panels.end(), panel) != n.panels.end();
    for (size_t i = 0; i < n.children.size(); ++i) {
        path.push_back(i);
        if (pathTo(n.children[i], panel, path)) return true;
        path.pop_back();
    }
    return false;
}

std::vector<std::string> panelsIn(const Node &n) {
    std::vector<std::string> out;
    eachStack(n, [&](const Node &s) { out.insert(out.end(), s.panels.begin(), s.panels.end()); });
    return out;
}

// The child indices down to the smallest node holding every one of `panels`.
std::vector<size_t> smallestHolding(const Node &root, const std::vector<std::string> &panels) {
    std::vector<size_t> path;
    const Node *n = &root;
    for (bool deeper = true; deeper && n->kind != Node::Kind::Stack;) {
        deeper = false;
        for (size_t i = 0; i < n->children.size() && !deeper; ++i) {
            std::vector<std::string> in = panelsIn(n->children[i]);
            if (std::all_of(panels.begin(), panels.end(), [&](const std::string &p) { return std::find(in.begin(), in.end(), p) != in.end(); })) {
                path.push_back(i);
                n = &n->children[i];
                deeper = true;
            }
        }
    }
    return path;
}

bool sideways(Side side) { return side == Side::Left || side == Side::Right; }  // a row's
bool leading(Side side) { return side == Side::Left || side == Side::Top; }

// `added` (a stack) on `side` of the stack holding `target` (which is in the console): in the split
// holding that stack when it is of the side's kind, the two halving its share; else the two in a
// split of their own, in its place.
void putBeside(Arrangement &a, Node added, std::string_view target, Side side) {
    std::vector<size_t> path;
    if (!pathTo(a.console, target, path)) return;
    Node *n = &a.console, *parent = nullptr;
    for (size_t i : path) parent = n, n = &n->children[i];
    Node::Kind kind = sideways(side) ? Node::Kind::Row : Node::Kind::Column;
    if (parent && parent->kind == kind) {
        n->share /= 2;
        added.share = n->share;
        parent->children.insert(parent->children.begin() + (long)(path.back() + (leading(side) ? 0 : 1)), std::move(added));
        return;
    }
    Node old = std::move(*n);
    double outer = old.share;
    old.share = added.share = 0.5;
    std::vector<Node> kids;
    if (leading(side)) kids.push_back(std::move(added));
    kids.push_back(std::move(old));
    if (!leading(side)) kids.push_back(std::move(added));
    *n = kind == Node::Kind::Row ? row(std::move(kids), outer) : column(std::move(kids), outer);
}

// Out of every stack and window (the tree tidied later).
void removeEverywhere(Arrangement &a, std::string_view panel) {
    eachStack(a.console, [&](Node &s) {
        auto it = std::find(s.panels.begin(), s.panels.end(), panel);
        if (it == s.panels.end()) return;
        size_t at = (size_t)(it - s.panels.begin());
        s.panels.erase(it);
        if (s.front > at || s.front >= s.panels.size()) s.front = s.front > 0 ? s.front - 1 : 0;
    });
    a.windows.erase(std::string(panel));
}

// Tidy one node: false when nothing of it is left.
bool tidyNode(Node &n, std::set<std::string> &seen, const std::vector<std::string> &known) {
    if (n.kind == Node::Kind::Stack) {
        std::string frontPanel = n.front < n.panels.size() ? n.panels[n.front] : std::string();
        std::vector<std::string> kept;
        for (const std::string &p : n.panels)
            if (std::find(known.begin(), known.end(), p) != known.end() && seen.insert(p).second) kept.push_back(p);
        n.panels = kept;
        n.children.clear();
        auto f = std::find(n.panels.begin(), n.panels.end(), frontPanel);
        n.front = f != n.panels.end() ? (size_t)(f - n.panels.begin()) : 0;
        return !n.panels.empty();
    }
    std::vector<Node> kids;
    for (Node &c : n.children) {
        if (!tidyNode(c, seen, known)) continue;
        if (c.kind == n.kind) {  // a row in a row: its children join this one, their shares scaled by its own
            double sum = 0;
            bool all = c.share > 0;
            for (const Node &g : c.children) sum += g.share, all = all && g.share > 0;
            for (Node &g : c.children) {
                g.share = all && sum > 0 ? g.share / sum * c.share : 0;
                kids.push_back(std::move(g));
            }
        } else {
            kids.push_back(std::move(c));
        }
    }
    n.panels.clear();
    n.front = 0;
    if (kids.empty()) return false;
    if (kids.size() == 1) {
        double share = n.share;
        n = std::move(kids[0]);
        n.share = share;
        return true;
    }
    bool all = std::all_of(kids.begin(), kids.end(), [](const Node &k) { return k.share > 0; });
    double sum = 0;
    for (const Node &k : kids) sum += k.share;
    for (Node &k : kids) k.share = all && sum > 0 ? k.share / sum : 0;
    n.children = std::move(kids);
    return true;
}

std::string quote(std::string_view s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out += '\\', out += (char)c;
        else if (c < 0x20) {
            char b[8];
            std::snprintf(b, sizeof b, "\\u%04x", c);
            out += b;
        } else out += (char)c;
    }
    return out + "\"";
}

std::string number(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.10g", v);  // shares worked out from others (a panel closed) read back the same
    return b;
}

void writeNode(const Node &n, std::string &out) {
    out += "{";
    if (n.kind == Node::Kind::Stack) {
        out += "\"stack\":[";
        for (size_t i = 0; i < n.panels.size(); ++i) out += (i ? "," : "") + quote(n.panels[i]);
        out += "]";
        if (n.front > 0) out += ",\"front\":" + std::to_string(n.front);
    } else {
        out += n.kind == Node::Kind::Row ? "\"row\":[" : "\"column\":[";
        for (size_t i = 0; i < n.children.size(); ++i) {
            if (i) out += ",";
            writeNode(n.children[i], out);
        }
        out += "]";
    }
    if (n.share > 0) out += ",\"share\":" + number(n.share);
    out += "}";
}

bool readNode(const json::Value &v, Node *out, int depth, std::string *why) {
    if (!v.isObject() || depth > 32) return *why = "a console node isn't an object (or nests too deep)", false;
    const json::Value *stackV = v.get("stack"), *rowV = v.get("row"), *colV = v.get("column");
    int kinds = (stackV != nullptr) + (rowV != nullptr) + (colV != nullptr);
    if (kinds != 1) return *why = "a console node needs one of stack, row or column", false;
    if (const json::Value *s = v.get("share")) {
        if (!s->isNumber() || !(s->number >= 0) || s->number > 1) return *why = "a share isn't a number from 0 to 1", false;
        out->share = s->number;
    }
    if (stackV) {
        if (!stackV->isArray() || stackV->stride) return *why = "a stack isn't a list of panel ids", false;
        out->kind = Node::Kind::Stack;
        for (const json::Value &p : stackV->items) {
            if (!p.isString()) return *why = "a stack holds something other than a panel id", false;
            out->panels.push_back(p.text);
        }
        if (const json::Value *f = v.get("front")) {
            if (!f->isNumber() || f->number < 0) return *why = "a stack's front isn't a number", false;
            out->front = (size_t)f->number;
        }
        return true;
    }
    const json::Value *list = rowV ? rowV : colV;
    out->kind = rowV ? Node::Kind::Row : Node::Kind::Column;
    if (!list->isArray() || list->stride) return *why = "a row or column isn't a list of nodes", false;
    for (const json::Value &c : list->items) {
        Node child;
        if (!readNode(c, &child, depth + 1, why)) return false;
        out->children.push_back(std::move(child));
    }
    return true;
}

// The built-in layouts, as the console had them: trees of five places ("0" to "4"), and what
// each place shows to begin with (a dock item: 0 none, 1 Map, 2 Log Table, 3 New QSO, 4 Spots,
// 5 Contact Map, 6 QSO Details).
struct LegacyPreset {
    const char *id, *name;
    Node tree;
    std::array<int, 5> items;
};
Node P(int place, double share = 0) { return stack({std::to_string(place)}, share); }

const std::vector<LegacyPreset> &legacyPresets() {
    static const std::vector<LegacyPreset> all = {
        {"qso-log-spots", N_("QSO, log and spots with map and details below"), row({column({P(0), P(1)}), column({P(2), row({P(3), P(4)})})}),
         {3, 2, 4, 5, 6}},
        {"qso-left", N_("QSO on the left, operating panels on the right"), row({P(0), column({P(1), row({P(2), P(3), P(4)})})}), {3, 2, 4, 5, 6}},
        {"log-qso-top", N_("Log and QSO across the top, operating panels below"), column({row({P(0), P(1)}), row({P(2), P(3), P(4)})}),
         {2, 3, 4, 5, 6}},
        {"map-details-right", N_("Map and details on the right"), row({column({P(0), P(1)}), column({P(2), row({P(3), P(4)})})}), {3, 2, 4, 5, 6}},
        {"spots-left", N_("Spots on the left, QSO and log on the right"), row({P(0), column({P(1), row({P(2), P(3), P(4)})})}), {4, 3, 2, 5, 6}},
        {"qso-log", N_("QSO and log only"), row({P(0), P(1), P(2), P(3), P(4)}), {3, 2, 0, 0, 0}},
        {"qso-spots-details", N_("QSO, spots and details"), row({P(0), P(1), P(2), P(3), P(4)}), {3, 4, 6, 0, 0}},
        {"activation", N_("Activation: QSO on the left, details, log and spots on the right"),
         row({P(0, 0.34), column({row({P(1, 0.6), P(2, 0.4)}, 0.29), P(3, 0.27), P(4, 0.44)}, 0.66)}), {3, 6, 5, 2, 4}},
        {"logging", N_("Map over the log, QSO on the right"), row({column({P(0), P(1)}), P(2)}), {1, 2, 3, 0, 0}},
    };
    return all;
}

const char *dockItemPanel(int item) {
    static const char *const kItems[] = {"", kMap, kLogTable, kNewQso, kSpots, kContactMap, kQsoDetails};
    return item > 0 && item < 7 ? kItems[item] : "";
}

// The tree with each place's panel (none: the place left out).
Arrangement fill(const Node &tree, const std::array<int, 5> &items) {
    Arrangement a;
    a.console = tree;
    eachStack(a.console, [&](Node &s) {
        for (std::string &p : s.panels) {
            int place = std::atoi(p.c_str());
            p = place >= 0 && place < 5 ? dockItemPanel(items[(size_t)place]) : "";
        }
    });
    return tidy(a);
}

}  // namespace

const std::vector<std::string> &knownPanels() {
    static const std::vector<std::string> all = {kMap,      kLogTable, kNewQso,      kSpots,   kContactMap, kQsoDetails,
                                                 kMapStyle, kAids,     kSpotSources, kStation, kClocks};
    return all;
}

Node stack(std::vector<std::string> panels, double share, size_t front) {
    Node n;
    n.panels = std::move(panels);
    n.share = share;
    n.front = front;
    return n;
}
Node row(std::vector<Node> children, double share) {
    Node n;
    n.kind = Node::Kind::Row;
    n.children = std::move(children);
    n.share = share;
    return n;
}
Node column(std::vector<Node> children, double share) {
    Node n = row(std::move(children), share);
    n.kind = Node::Kind::Column;
    return n;
}

bool operator==(const Node &a, const Node &b) {
    return a.kind == b.kind && same(a.share, b.share) && a.children == b.children && a.panels == b.panels && a.front == b.front;
}
bool operator==(const Frame &a, const Frame &b) { return same(a.x, b.x) && same(a.y, b.y) && same(a.w, b.w) && same(a.h, b.h); }
bool operator==(const Place &a, const Place &b) {
    return a.tab == b.tab && a.beside == b.beside && a.tabAt == b.tabAt && a.next == b.next && a.split == b.split && a.before == b.before && same(a.share, b.share);
}
bool operator==(const Arrangement &a, const Arrangement &b) {
    return a.console == b.console && a.windows == b.windows && a.panes == b.panes && a.closed == b.closed;
}

std::vector<std::string> shown(const Arrangement &a) {
    std::vector<std::string> out;
    eachStack(a.console, [&](const Node &s) { out.insert(out.end(), s.panels.begin(), s.panels.end()); });
    for (const auto &kv : a.windows) out.push_back(kv.first);
    return out;
}

bool shows(const Arrangement &a, std::string_view panel) {
    std::vector<std::string> all = shown(a);
    return std::find(all.begin(), all.end(), panel) != all.end();
}

bool inConsole(const Arrangement &a, std::string_view panel) {
    bool found = false;
    eachStack(a.console, [&](const Node &s) { found = found || std::find(s.panels.begin(), s.panels.end(), panel) != s.panels.end(); });
    return found;
}

bool paneShown(const Arrangement &a, std::string_view panel, std::string_view pane) {
    auto p = a.panes.find(std::string(panel));
    if (p == a.panes.end()) return true;
    auto q = p->second.find(std::string(pane));
    return q == p->second.end() || q->second;
}

Arrangement showInConsole(Arrangement a, std::string_view panel, std::string_view beside) {
    if (inConsole(a, panel)) return tidy(a);
    a.windows.erase(std::string(panel));
    if (Node *s = beside.empty() ? nullptr : stackHolding(a.console, beside)) {
        s->panels.emplace_back(panel);
        s->front = s->panels.size() - 1;
        return tidy(a);
    }
    if (a.console.kind == Node::Kind::Stack && a.console.panels.empty()) {
        a.console = stack({std::string(panel)});
    } else if (a.console.kind == Node::Kind::Row) {
        bool all = std::all_of(a.console.children.begin(), a.console.children.end(), [](const Node &k) { return k.share > 0; });
        double n = (double)a.console.children.size();
        for (Node &k : a.console.children) k.share = all ? k.share * n / (n + 1) : 0;
        a.console.children.push_back(stack({std::string(panel)}, all ? 1 / (n + 1) : 0));
    } else {
        Node old = std::move(a.console);
        old.share = 0;
        a.console = row({std::move(old), stack({std::string(panel)})});
    }
    return tidy(a);
}

Arrangement showInWindow(Arrangement a, std::string_view panel, Frame frame) {
    removeEverywhere(a, panel);
    a.windows[std::string(panel)] = frame;
    return tidy(a);
}

Arrangement hide(Arrangement a, std::string_view panel) {
    removeEverywhere(a, panel);
    return tidy(a);
}

std::optional<Place> placeOf(const Arrangement &a, std::string_view panel) {
    std::vector<size_t> path;
    if (!pathTo(a.console, panel, path)) return std::nullopt;
    const Node *s = &a.console, *parent = nullptr;
    for (size_t i : path) parent = s, s = &s->children[i];
    Place p;
    size_t at = (size_t)(std::find(s->panels.begin(), s->panels.end(), panel) - s->panels.begin());
    if (s->panels.size() > 1) {  // a tab: beside the one before it (the next, when it is first)
        p.tab = true, p.tabAt = at, p.beside = s->panels[at > 0 ? at - 1 : 1];
        return p;
    }
    if (!parent) return std::nullopt;
    size_t i = path.back();
    p.next = panelsIn(parent->children[i > 0 ? i - 1 : i + 1]);  // after the frame before it (before the next, when it is first)
    p.split = parent->kind, p.before = i == 0, p.share = s->share;
    return p;
}

Arrangement showAt(Arrangement a, std::string_view panel, const Place &place) {
    if (inConsole(a, panel)) return tidy(a);
    if (place.tab) {
        Node *s = place.beside.empty() ? nullptr : stackHolding(a.console, place.beside);
        if (!s) return showInConsole(std::move(a), panel);
        a.windows.erase(std::string(panel));
        size_t at = std::min(place.tabAt, s->panels.size());
        s->panels.insert(s->panels.begin() + (long)at, std::string(panel));
        s->front = at;
        return tidy(a);
    }
    std::vector<std::string> next;
    for (const std::string &p : place.next)
        if (inConsole(a, p)) next.push_back(p);
    if (next.empty() || place.split == Node::Kind::Stack) return showInConsole(std::move(a), panel);
    a.windows.erase(std::string(panel));
    std::vector<size_t> path = smallestHolding(a.console, next);
    Node *n = &a.console, *parent = nullptr;
    for (size_t i : path) parent = n, n = &n->children[i];
    double share = place.share > 0 && place.share < 1 ? place.share : 0;
    Node added = stack({std::string(panel)}, share);
    if (parent && parent->kind == place.split) {  // into that split again, the others giving up its share
        bool all = share > 0 && std::all_of(parent->children.begin(), parent->children.end(), [](const Node &k) { return k.share > 0; });
        for (Node &k : parent->children) k.share = all ? k.share * (1 - share) : 0;
        if (!all) added.share = 0;
        parent->children.insert(parent->children.begin() + (long)(path.back() + (place.before ? 0 : 1)), std::move(added));
    } else {  // the split it was in had only that part left: made again
        Node old = std::move(*n);
        double outer = old.share;
        old.share = share > 0 ? 1 - share : 0;
        std::vector<Node> kids;
        if (place.before) kids.push_back(std::move(added));
        kids.push_back(std::move(old));
        if (!place.before) kids.push_back(std::move(added));
        *n = place.split == Node::Kind::Row ? row(std::move(kids), outer) : column(std::move(kids), outer);
    }
    return tidy(a);
}

Arrangement closePanel(Arrangement a, std::string_view panel) {
    std::optional<Place> p = placeOf(a, panel);
    a = hide(std::move(a), panel);
    if (p) a.closed[std::string(panel)] = *p;
    return a;
}

Arrangement reopenPanel(Arrangement a, std::string_view panel) {
    auto it = a.closed.find(std::string(panel));
    if (it == a.closed.end()) return showInConsole(std::move(a), panel);
    Place p = it->second;
    a.closed.erase(it);
    return showAt(std::move(a), panel, p);
}

Arrangement splitBeside(Arrangement a, std::string_view panel, std::string_view target, Side side) {
    if (panel == target || !inConsole(a, target)) return tidy(a);
    removeEverywhere(a, panel);
    a = tidy(a);
    putBeside(a, stack({std::string(panel)}), target, side);
    return tidy(a);
}

Arrangement moveFrame(Arrangement a, std::string_view panel, std::string_view target, Side side, double share) {
    Node *s = stackHolding(a.console, panel);
    if (!s || (!target.empty() && (!inConsole(a, target) || std::find(s->panels.begin(), s->panels.end(), target) != s->panels.end())))
        return tidy(a);
    Node moved = stack(s->panels, 0, s->front);
    s->panels.clear();
    a = tidy(a);
    if (a.console.kind == Node::Kind::Stack && a.console.panels.empty()) {  // it was the whole console
        a.console = std::move(moved);
        return tidy(a);
    }
    if (!target.empty()) {
        putBeside(a, std::move(moved), target, side);
        return tidy(a);
    }
    Node::Kind kind = sideways(side) ? Node::Kind::Row : Node::Kind::Column;
    double part = share > 0 && share < 1 ? share : 0;
    Node old = std::move(a.console);
    if (old.kind == kind) {  // the console is a split of that kind already: one more at its end
        bool all = part > 0 && std::all_of(old.children.begin(), old.children.end(), [](const Node &k) { return k.share > 0; });
        for (Node &k : old.children) k.share = all ? k.share * (1 - part) : 0;
        moved.share = all ? part : 0;
        old.children.insert(leading(side) ? old.children.begin() : old.children.end(), std::move(moved));
        a.console = std::move(old);
        return tidy(a);
    }
    old.share = part > 0 ? 1 - part : 0;
    moved.share = part;
    std::vector<Node> kids;
    if (leading(side)) kids.push_back(std::move(moved));
    kids.push_back(std::move(old));
    if (!leading(side)) kids.push_back(std::move(moved));
    a.console = kind == Node::Kind::Row ? row(std::move(kids)) : column(std::move(kids));
    return tidy(a);
}

Node::Kind splitOf(const Arrangement &a, std::string_view panel) {
    std::vector<size_t> path;
    if (!pathTo(a.console, panel, path) || path.empty()) return Node::Kind::Stack;
    const Node *parent = &a.console;
    for (size_t k = 0; k + 1 < path.size(); ++k) parent = &parent->children[path[k]];
    return parent->kind;
}

Arrangement alignSplit(Arrangement a, std::string_view panel, Node::Kind kind) {
    std::vector<size_t> path;
    if (kind == Node::Kind::Stack || !pathTo(a.console, panel, path) || path.empty()) return tidy(a);
    Node *parent = &a.console;
    for (size_t k = 0; k + 1 < path.size(); ++k) parent = &parent->children[path[k]];
    parent->kind = kind;  // tidied: merged into a split around it of the same kind
    return tidy(a);
}

Arrangement moveToTab(Arrangement a, std::string_view panel, std::string_view target) {
    if (panel == target || !inConsole(a, target)) return tidy(a);
    removeEverywhere(a, panel);
    Node *s = stackHolding(a.console, target);
    s->panels.emplace_back(panel);
    s->front = s->panels.size() - 1;
    return tidy(a);
}

Arrangement swap(Arrangement a, std::string_view first, std::string_view second) {
    if (first == second || !shows(a, first) || !shows(a, second)) return tidy(a);
    const std::string f(first), s(second), mark = "\x01";
    eachStack(a.console, [&](Node &st) {
        for (std::string &p : st.panels) p = p == f ? mark : p == s ? f : p;
        for (std::string &p : st.panels)
            if (p == mark) p = s;
    });
    auto fw = a.windows.find(f), sw = a.windows.find(s);
    std::optional<Frame> fFrame = fw != a.windows.end() ? std::optional<Frame>(fw->second) : std::nullopt;
    std::optional<Frame> sFrame = sw != a.windows.end() ? std::optional<Frame>(sw->second) : std::nullopt;
    a.windows.erase(f), a.windows.erase(s);
    if (fFrame) a.windows[s] = *fFrame;
    if (sFrame) a.windows[f] = *sFrame;
    return tidy(a);
}

Arrangement bringToFront(Arrangement a, std::string_view panel) {
    if (Node *s = stackHolding(a.console, panel))
        s->front = (size_t)(std::find(s->panels.begin(), s->panels.end(), panel) - s->panels.begin());
    return tidy(a);
}

Arrangement setPane(Arrangement a, std::string_view panel, std::string_view pane, bool shown) {
    a.panes[std::string(panel)][std::string(pane)] = shown;
    return tidy(a);
}

Arrangement tidy(Arrangement a, const std::vector<std::string> &known) {
    std::set<std::string> seen;
    if (!tidyNode(a.console, seen, known)) a.console = Node();
    a.console.share = 0;
    for (auto it = a.windows.begin(); it != a.windows.end();) {
        bool keep = std::find(known.begin(), known.end(), it->first) != known.end() && seen.insert(it->first).second;
        it = keep ? std::next(it) : a.windows.erase(it);
    }
    for (auto it = a.panes.begin(); it != a.panes.end();)
        it = std::find(known.begin(), known.end(), it->first) != known.end() && !it->second.empty() ? std::next(it) : a.panes.erase(it);
    for (auto it = a.closed.begin(); it != a.closed.end();)
        it = std::find(known.begin(), known.end(), it->first) != known.end() && !seen.count(it->first) ? std::next(it) : a.closed.erase(it);
    return a;
}

std::vector<std::string> problems(const Arrangement &a, const std::vector<std::string> &known) {
    std::vector<std::string> out;
    std::set<std::string> seen;
    std::function<void(const Node &, bool)> check = [&](const Node &n, bool root) {
        if (n.kind == Node::Kind::Stack) {
            if (n.panels.empty() && !root) out.push_back("an empty stack");
            if (!n.panels.empty() && n.front >= n.panels.size()) out.push_back("a stack's front is past its tabs");
            for (const std::string &p : n.panels) {
                if (std::find(known.begin(), known.end(), p) == known.end()) out.push_back("an unknown panel: " + p);
                if (!seen.insert(p).second) out.push_back("a panel shown twice: " + p);
            }
            return;
        }
        if (n.children.size() < 2) out.push_back("a split of fewer than two");
        double sum = 0;
        bool all = true, any = false;
        for (const Node &c : n.children) sum += c.share, all = all && c.share > 0, any = any || c.share > 0;
        if (all && std::fabs(sum - 1) > 1e-6) out.push_back("shares that don't sum to 1");
        if (any && !all) out.push_back("shares on some siblings only");
        for (const Node &c : n.children) {
            if (c.kind == n.kind) out.push_back("a split inside one of its own kind");
            check(c, false);
        }
    };
    check(a.console, true);
    for (const auto &kv : a.windows) {
        if (std::find(known.begin(), known.end(), kv.first) == known.end()) out.push_back("an unknown panel: " + kv.first);
        if (!seen.insert(kv.first).second) out.push_back("a panel shown twice: " + kv.first);
    }
    return out;
}

std::string write(const Arrangement &a) {
    std::string out = "{\"v\":" + std::to_string(kVersion) + ",\"console\":";
    writeNode(a.console, out);
    out += ",\"windows\":{";
    bool first = true;
    for (const auto &kv : a.windows) {
        out += (first ? "" : ",") + quote(kv.first) + ":{\"x\":" + number(kv.second.x) + ",\"y\":" + number(kv.second.y) + ",\"w\":" + number(kv.second.w) +
               ",\"h\":" + number(kv.second.h) + "}";
        first = false;
    }
    out += "},\"panes\":{";
    first = true;
    for (const auto &kv : a.panes) {
        out += (first ? "" : ",") + quote(kv.first) + ":{";
        bool firstPane = true;
        for (const auto &pane : kv.second) {
            out += (firstPane ? "" : ",") + quote(pane.first) + ":" + (pane.second ? "true" : "false");
            firstPane = false;
        }
        out += "}";
        first = false;
    }
    out += "}";
    if (!a.closed.empty()) {
        out += ",\"closed\":{";
        first = true;
        for (const auto &[panel, p] : a.closed) {
            out += (first ? "" : ",") + quote(panel) + ":{";
            if (p.tab) {
                out += "\"tab\":" + quote(p.beside) + ",\"at\":" + std::to_string(p.tabAt);
            } else {
                out += "\"next\":[";
                for (size_t i = 0; i < p.next.size(); ++i) out += (i ? "," : "") + quote(p.next[i]);
                out += std::string("],\"split\":") + (p.split == Node::Kind::Column ? "\"column\"" : "\"row\"") + ",\"before\":" + (p.before ? "true" : "false");
                if (p.share > 0) out += ",\"share\":" + number(p.share);
            }
            out += "}";
            first = false;
        }
        out += "}";
    }
    return out + "}";
}

namespace {

std::optional<Arrangement> readValue(const json::Value &v, std::string &w) {
    if (!v.isObject()) return w = "not an object", std::nullopt;
    const json::Value *version = v.get("v");
    if (!version || !version->isNumber() || version->number != kVersion) return w = "another version", std::nullopt;
    Arrangement a;
    if (const json::Value *c = v.get("console")) {
        if (!readNode(*c, &a.console, 0, &w)) return std::nullopt;
    }
    if (const json::Value *ws = v.get("windows")) {
        if (!ws->isObject()) return w = "windows isn't an object", std::nullopt;
        for (const auto &[id, f] : ws->members) {
            if (!f.isObject()) return w = "a window's frame isn't an object", std::nullopt;
            Frame frame;
            for (auto [key, field] : {std::pair<const char *, double *>{"x", &frame.x}, {"y", &frame.y}, {"w", &frame.w}, {"h", &frame.h}})
                if (const json::Value *n = f.get(key); n && n->isNumber()) *field = n->number;
            a.windows[id] = frame;
        }
    }
    if (const json::Value *ps = v.get("panes")) {
        if (!ps->isObject()) return w = "panes isn't an object", std::nullopt;
        for (const auto &[id, panes] : ps->members) {
            if (!panes.isObject()) return w = "a panel's panes aren't an object", std::nullopt;
            for (const auto &[pane, on] : panes.members)
                if (on.type == json::Value::Type::Bool) a.panes[id][pane] = on.boolean;
        }
    }
    if (const json::Value *cs = v.get("closed"); cs && cs->isObject())  // a place that can't be read is left out
        for (const auto &[id, c] : cs->members) {
            if (!c.isObject()) continue;
            Place p;
            if (const json::Value *tab = c.get("tab")) {
                const json::Value *at = c.get("at");
                if (!tab->isString() || !at || !at->isNumber() || at->number < 0) continue;
                p.tab = true, p.beside = tab->text, p.tabAt = (size_t)at->number;
            } else {
                const json::Value *next = c.get("next"), *split = c.get("split"), *before = c.get("before"), *share = c.get("share");
                if (!next || !next->isArray() || next->stride || !split || !split->isString() || (split->text != "row" && split->text != "column")) continue;
                for (const json::Value &n : next->items)
                    if (n.isString()) p.next.push_back(n.text);
                p.split = split->text == "column" ? Node::Kind::Column : Node::Kind::Row;
                p.before = before && before->type == json::Value::Type::Bool && before->boolean;
                p.share = share && share->isNumber() && share->number > 0 && share->number < 1 ? share->number : 0;
            }
            a.closed[id] = p;
        }
    return tidy(a);
}

}  // namespace

std::optional<Arrangement> read(std::string_view text, std::string *why) {
    std::string ignored;
    std::string &w = why ? *why : ignored;
    json::Value v;
    if (!json::parse(text, &v, &w, 100'000)) return std::nullopt;
    return readValue(v, w);
}

std::string cleanName(std::string_view name) {
    std::string out;
    for (char c : name) out += c == '\n' || c == '\r' || c == '\t' ? ' ' : c;
    size_t a = out.find_first_not_of(' '), b = out.find_last_not_of(' ');
    out = a == std::string::npos ? std::string() : out.substr(a, b - a + 1);
    size_t chars = 0, at = 0;
    for (; at < out.size(); ++at) {
        if (((unsigned char)out[at] & 0xC0) == 0x80) continue;  // a UTF-8 character's continuation
        if (++chars > 60) break;
    }
    out.resize(at);
    b = out.find_last_not_of(' ');
    return b == std::string::npos ? std::string() : out.substr(0, b + 1);
}

bool sameName(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i])) return false;
    return true;
}

std::string writeAdjusted(const std::map<std::string, Arrangement> &layouts) {
    std::string out = "{\"v\":" + std::to_string(kVersion) + ",\"adjusted\":{";
    bool first = true;
    for (const auto &[id, a] : layouts) {
        out += (first ? "" : ",") + quote(id) + ":" + write(a);
        first = false;
    }
    return out + "}}";
}

std::map<std::string, Arrangement> readAdjusted(std::string_view text) {
    std::map<std::string, Arrangement> out;
    json::Value v;
    std::string why;
    if (!json::parse(text, &v, &why, 2'000'000) || !v.isObject()) return out;
    const json::Value *version = v.get("v"), *all = v.get("adjusted");
    if (!version || !version->isNumber() || version->number != kVersion || !all || !all->isObject()) return out;
    for (const auto &[id, layout] : all->members)
        if (std::optional<Arrangement> a = readValue(layout, why); a && !id.empty()) out[id] = *a;
    return out;
}

std::string writeNamed(const std::vector<Named> &list) {
    std::string out = "{\"v\":" + std::to_string(kVersion) + ",\"layouts\":[";
    for (size_t i = 0; i < list.size(); ++i) out += std::string(i ? "," : "") + "{\"name\":" + quote(list[i].name) + ",\"layout\":" + write(list[i].arrangement) + "}";
    return out + "]}";
}

std::vector<Named> readNamed(std::string_view text) {
    std::vector<Named> out;
    json::Value v;
    std::string why;
    if (!json::parse(text, &v, &why, 1'000'000) || !v.isObject()) return out;
    const json::Value *version = v.get("v"), *list = v.get("layouts");
    if (!version || !version->isNumber() || version->number != kVersion || !list || !list->isArray() || list->stride) return out;
    for (const json::Value &e : list->items) {
        const json::Value *name = e.isObject() ? e.get("name") : nullptr, *layout = e.isObject() ? e.get("layout") : nullptr;
        if (!name || !name->isString() || !layout) continue;
        std::string clean = cleanName(name->text);
        std::optional<Arrangement> a = readValue(*layout, why);
        if (clean.empty() || !a || findNamed(out, clean)) continue;
        out.push_back({clean, *a});
    }
    return out;
}

const Named *findNamed(const std::vector<Named> &list, std::string_view name) {
    for (const Named &n : list)
        if (sameName(n.name, name)) return &n;
    return nullptr;
}

std::vector<Named> saveNamed(std::vector<Named> list, std::string_view name, const Arrangement &a) {
    std::string clean = cleanName(name);
    if (clean.empty()) return list;
    for (Named &n : list)
        if (sameName(n.name, clean)) {
            n = {clean, tidy(a)};
            return list;
        }
    list.push_back({clean, tidy(a)});
    return list;
}

std::vector<Named> removeNamed(std::vector<Named> list, std::string_view name) {
    list.erase(std::remove_if(list.begin(), list.end(), [&](const Named &n) { return sameName(n.name, name); }), list.end());
    return list;
}

const std::vector<Preset> &presets() {
    static const std::vector<Preset> all = [] {
        std::vector<Preset> out;
        for (const LegacyPreset &l : legacyPresets()) out.push_back({l.id, l.name, fill(l.tree, l.items)});
        // The operating styles' layouts (OPERATING_STYLES_PLAN.md, Stage 6), by the styles' ids.
        auto add = [&](const char *id, const char *name, Node console) {
            Arrangement a;
            a.console = std::move(console);
            out.push_back({id, name, tidy(a)});
        };
        add("social", N_("Social: the Map, with New QSO, Operating Aids and QSO Details beside it"),
            row({stack({kMap}, 0.6), column({stack({kNewQso}, 0.5), stack({kAids}, 0.2), stack({kQsoDetails}, 0.3)}, 0.4)}));
        add("chasing", N_("Chasing: the Map over the spots, New QSO and Operating Aids beside them"),
            row({column({stack({kMap}, 0.62), stack({kSpots}, 0.38)}, 0.64), column({stack({kNewQso}, 0.7), stack({kAids}, 0.3)}, 0.36)}));
        add("contest", N_("Contest: New QSO over the log, the Map beside them"),
            row({column({stack({kNewQso}, 0.55), stack({kLogTable}, 0.45)}, 0.4), stack({kMap}, 0.6)}));
        add("portable", N_("Portable: New QSO over Operating Aids, with the Map over the log beside them"),
            row({column({stack({kNewQso}, 0.7), stack({kAids}, 0.3)}, 0.36), column({stack({kMap}, 0.6), stack({kLogTable}, 0.4)}, 0.64)}));
        return out;
    }();
    return all;
}

const Preset *preset(std::string_view id) {
    for (const Preset &p : presets())
        if (p.id == id) return &p;
    return nullptr;
}

Arrangement migrate(const Getter &get) {
    const std::vector<LegacyPreset> &legacy = legacyPresets();
    std::string index = get("layoutPreset");
    size_t which = index.empty() ? 0 : (size_t)std::clamp(std::atoi(index.c_str()), 0, (int)legacy.size() - 1);
    std::array<int, 5> items = legacy[which].items;
    // What each place showed, when it was saved whole and sound (each a known item, none twice).
    std::string saved = get("layoutItemsV3");
    std::vector<int> got;
    for (size_t at = 0; !saved.empty() && at <= saved.size();) {
        size_t comma = saved.find(',', at);
        got.push_back(std::atoi(saved.substr(at, comma == std::string::npos ? std::string::npos : comma - at).c_str()));
        if (comma == std::string::npos) break;
        at = comma + 1;
    }
    bool ok = got.size() == 5;
    for (size_t p = 0; ok && p < 5; ++p) {
        ok = got[p] >= 0 && got[p] < 7;
        for (size_t q = 0; ok && q < p; ++q) ok = got[p] == 0 || got[p] != got[q];
    }
    if (ok) std::copy(got.begin(), got.end(), items.begin());
    Arrangement a = fill(legacy[which].tree, items);
    static const std::pair<const char *, const char *> kPanes[] = {{"mapSidebar", "sidebar"}, {"mapList", "list"}, {"mapSelected", "selected"}};
    for (const auto &[key, pane] : kPanes) {
        std::string v = get(key);
        if (v == "0" || v == "1") a.panes[kMap][pane] = v == "1";
    }
    return tidy(a);
}

}  // namespace adif::layout
