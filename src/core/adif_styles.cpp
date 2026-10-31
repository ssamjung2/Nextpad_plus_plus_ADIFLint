#include "adif_styles.h"

#include "adif_i18n.h"

#include <algorithm>
#include <array>
#include <set>

namespace adif::styles {
namespace {

struct Style {
    OperatingStyle style;
    const char *id, *title, *savedId;
};
const std::array<Style, kStyleCount> kStyles = {{
    {OperatingStyle::Social, "social", N_("Social"), "Social"},
    {OperatingStyle::Chasing, "chasing", N_("Chasing"), "Chasing"},
    {OperatingStyle::Contest, "contest", N_("Contest"), "Contest"},
    {OperatingStyle::Portable, "portable", N_("Portable"), "Portable"},
}};

const Style &find(OperatingStyle s) { return kStyles[(size_t)s]; }

// The Map's workflows (mapWorkflow): 0 History, 1 Live, 2 DX Chase, 3 POTA. Quick Views
// (mapQuickView): History's 10 is Contacts; Live's 0 is All spots, 1 Needed on its band.
// Palettes (mapPalette): 0 Standard, 2 High contrast. See docs/OPERATING_STYLES_PLAN.md,
// "Stage 0 definition".
const Settings kSocial = {
    {"mapWorkflow", "0"}, {"mapQuickView", "10"}, {"mapShowSpots", "0"}, {"mapPalette", "0"},
};
const Settings kChasing = {
    {"mapWorkflow", "2"}, {"mapQuickView", "1"}, {"mapGreyLine", "1"}, {"mapPalette", "0"},
};
// Nothing moves by itself: the beacons, which take turns every 10 seconds, off.
const Settings kContest = {
    {"mapWorkflow", "1"}, {"mapQuickView", "0"}, {"mapShowSpots", "1"}, {"mapSpotLabels", "1"}, {"mapShowCq", "1"},
    {"mapCqZones", "1"},  {"mapDxcc", "0"},      {"mapBeacons", "0"},   {"mapPalette", "2"},
};
// No feed starts by itself: no spots, solar data or aurora; and no grid over the contacts.
const Settings kPortable = {
    {"mapWorkflow", "0"}, {"mapQuickView", "10"}, {"mapShowSpots", "0"}, {"mapGreyLine", "0"}, {"mapDayNight", "0"}, {"mapSolar", "0"},
    {"mapAurora", "0"},   {"mapGrid", "0"},       {"mapPalette", "2"},   {"mapTextSize", "1"}, {"mapRings", "1"},
};

}  // namespace

std::string_view id(OperatingStyle s) { return find(s).id; }

std::optional<OperatingStyle> parse(std::string_view id) {
    for (const Style &s : kStyles)
        if (id == s.id) return s.style;
    return std::nullopt;
}

const char *title(OperatingStyle s) { return find(s).title; }

const Settings &defaults(OperatingStyle s) {
    switch (s) {
        case OperatingStyle::Social: return kSocial;
        case OperatingStyle::Chasing: return kChasing;
        case OperatingStyle::Contest: return kContest;
        case OperatingStyle::Portable: break;
    }
    return kPortable;
}

std::vector<std::string> ownedKeys(const std::vector<std::string> &workflowKeys) {
    std::set<std::string> keys(workflowKeys.begin(), workflowKeys.end());
    for (const Style &s : kStyles)
        for (const auto &kv : defaults(s.style)) keys.insert(kv.first);
    return {keys.begin(), keys.end()};
}

std::string savedKey(OperatingStyle s, std::string_view key) { return std::string("mapStyle") + find(s).savedId + std::string(key); }

bool hasSaved(OperatingStyle s, const Getter &get) { return get(savedKey(s, "Saved")) == "1"; }

void save(OperatingStyle s, const std::vector<std::string> &owned, const Getter &get, const Setter &set) {
    for (const std::string &k : owned) set(savedKey(s, k), get(k));
    set(savedKey(s, "Saved"), "1");
}

void forget(OperatingStyle s, const std::vector<std::string> &owned, const Setter &set) {
    for (const std::string &k : owned) set(savedKey(s, k), "");
    set(savedKey(s, "Saved"), "");
}

Settings target(OperatingStyle s, const std::vector<std::string> &owned, const Getter &get) {
    if (!hasSaved(s, get)) return defaults(s);
    Settings out;
    for (const std::string &k : owned) out[k] = get(savedKey(s, k));
    return out;
}

Settings snapshot(const std::vector<std::string> &owned, const Getter &get) {
    Settings out;
    for (const std::string &k : owned) out[k] = get(k);
    return out;
}

Transition diff(std::optional<OperatingStyle> from, std::optional<OperatingStyle> to, const Settings &before, const Settings &after) {
    Transition t{from, to, {}};
    std::set<std::string> keys;
    for (const auto &kv : before) keys.insert(kv.first);
    for (const auto &kv : after) keys.insert(kv.first);
    auto value = [](const Settings &m, const std::string &k) {
        auto it = m.find(k);
        return it == m.end() ? std::string() : it->second;
    };
    for (const std::string &k : keys)
        if (value(before, k) != value(after, k)) t.changes.push_back({k, value(before, k), value(after, k)});
    return t;
}

Transition reversed(const Transition &t) {
    Transition r{t.to, t.from, {}};
    for (const Change &c : t.changes) r.changes.push_back({c.key, c.after, c.before});
    return r;
}

bool customized(OperatingStyle s, const Getter &get) {
    const Settings &d = defaults(s);
    return std::any_of(d.begin(), d.end(), [&](const auto &kv) { return get(kv.first) != kv.second; });
}

}  // namespace adif::styles
